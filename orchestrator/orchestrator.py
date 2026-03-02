#!/usr/bin/env python3
"""
BDD E2E Orchestrator (tmux + MCP/Mailbox + Git Worktrees)

Coordinates two Claude Code agents through a shared mailbox and git worktrees:
  - Writer: creates .feature files, step definitions, and Page Objects in .worktrees/writer
  - Executor: runs Playwright+Cucumber tests in .worktrees/executor

Git flow:
  main --> writer/<task> --> executor/<task> --> merge into main

Usage:
  python3 orchestrator.py <project>

  where <project> matches a directory under projects/ (e.g., example).
"""

import argparse
import csv
import json
import subprocess
import threading
import queue
import time
import logging
import sys
import yaml
from pathlib import Path

from llm_client import OllamaClient
from mailbox_watcher import MailboxWatcher

from enum import Enum

class BddState(Enum):
    IDLE = "idle"
    WAITING_WRITER = "waiting_writer"
    WAITING_EXECUTOR = "waiting_executor"
    BLOCKED = "blocked"

# --- Parse CLI args ---
parser = argparse.ArgumentParser(description="BDD E2E Orchestrator")
parser.add_argument("project", help="Project name (matches projects/<name>/)")
args = parser.parse_args()

# --- Resolve paths ---
orchestrator_dir = Path(__file__).parent
root_dir = orchestrator_dir.parent
project_dir = root_dir / "projects" / args.project

if not project_dir.is_dir():
    print(f"Error: Project '{args.project}' not found at {project_dir}")
    print(f"Available projects: {', '.join(p.name for p in (root_dir / 'projects').iterdir() if p.is_dir())}")
    sys.exit(1)

# --- Load & merge configs ---
with open(orchestrator_dir / "config.yaml") as f:
    config = yaml.safe_load(f)

with open(project_dir / "config.yaml") as f:
    project_config = yaml.safe_load(f)

# Deep-merge: project overrides shared (two levels deep so that e.g.
# agents.writer from project config merges with agents.writer defaults rather
# than replacing the entire agents.writer dict).
for key, val in project_config.items():
    if isinstance(val, dict) and key in config and isinstance(config[key], dict):
        merged = {**config[key]}
        for k2, v2 in val.items():
            if isinstance(v2, dict) and k2 in merged and isinstance(merged[k2], dict):
                merged[k2] = {**merged[k2], **v2}
            else:
                merged[k2] = v2
        config[key] = merged
    else:
        config[key] = val

# --- Resolve per-project paths ---
mailbox_dir = str(root_dir / "shared" / args.project / "mailbox")
tasks_path = project_dir / "tasks.json"
repo_dir = config.get("repo_dir", "")
features_mode = config.get("features_mode", "new")

# --- Setup Logging ---
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler("orchestrator.log"),
        logging.StreamHandler(sys.stdout),
    ],
)
logger = logging.getLogger(__name__)

# --- Initialize Components ---
llm = OllamaClient(
    base_url=config["llm"]["base_url"],
    model=config["llm"]["model"],
    disable_thinking=config["llm"].get("disable_thinking", False),
)

mailbox = MailboxWatcher(mailbox_dir=mailbox_dir)

# --- Session Report ---
session_report_path = project_dir / "session-report.md"


def log_to_report(entry: str):
    """Append a timestamped entry to the session report."""
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(session_report_path, "a") as f:
        f.write(f"\n### [{timestamp}] {entry}\n")


# --- CSV Change Log ---
changes_csv_path = project_dir / "changes.csv"


def log_file_changes(task_id: str, phase: str, repo_path: str, source_branch: str):
    """Log files changed by a merge to the CSV change log."""
    success, output = run_git_command(
        repo_path, "diff", "--name-status", f"{default_branch}..{source_branch}"
    )
    if not success or not output.strip():
        return

    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    write_header = not changes_csv_path.exists()

    with open(changes_csv_path, "a", newline="") as f:
        writer = csv.writer(f)
        if write_header:
            writer.writerow(["timestamp", "task_id", "phase", "action", "file"])
        for line in output.strip().splitlines():
            parts = line.split("\t", 1)
            if len(parts) == 2:
                action, filepath = parts
                writer.writerow([timestamp, task_id, phase, action.strip(), filepath.strip()])

    logger.info(f"Logged file changes for {task_id} ({phase}) to {changes_csv_path}")


# --- Load Tasks ---
with open(tasks_path) as f:
    tasks_data = json.load(f)

tasks = tasks_data["tasks"]

bdd_state = BddState.IDLE

# --- Track current task branch suffix ---
current_task_id = None

# --- tmux nudge config ---
tmux_session = config.get("tmux", {}).get("session_name", "bdd")
tmux_nudge_prompt = config.get("tmux", {}).get(
    "nudge_prompt",
    "You have new messages. Use the check_messages MCP tool with your role to read and act on them.",
)
tmux_nudge_cooldown = config.get("tmux", {}).get("nudge_cooldown_seconds", 30)
# Build agent -> pane target mapping from config
_agent_pane_targets = {}
for agent_name, agent_cfg in config.get("agents", {}).items():
    pane = agent_cfg.get("pane")
    if pane:
        _agent_pane_targets[agent_name] = f"{tmux_session}:{pane}"
_last_nudge = {}


# --- Git helpers ---
def run_git_command(cwd: str, *git_args) -> tuple[bool, str]:
    """Run a git command in the given directory."""
    cmd = ["git", "-C", cwd] + list(git_args)
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30,
        )
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            logger.warning(f"Git command failed: {' '.join(cmd)}\n  {output}")
            return False, output
        return True, output
    except subprocess.TimeoutExpired:
        logger.error(f"Git command timed out: {' '.join(cmd)}")
        return False, "Command timed out"
    except subprocess.SubprocessError as e:
        logger.error(f"Git command error: {e}")
        return False, str(e)


def get_default_branch(repo_path: str) -> str:
    """Detect the default branch name (main, master, etc.)."""
    success, output = run_git_command(repo_path, "symbolic-ref", "--short", "HEAD")
    return output.strip() if success else "main"


# Resolve default branch at startup (used by merge operations)
default_branch = get_default_branch(repo_dir) if repo_dir else "main"


def git_merge_branch(worktree_path: str, source_branch: str) -> tuple[bool, str]:
    """Merge a source branch into the current branch of a worktree."""
    success, output = run_git_command(worktree_path, "merge", source_branch, "--no-edit")
    if not success:
        if "CONFLICT" in output or "conflict" in output.lower():
            logger.error(f"Merge conflict merging {source_branch} into {worktree_path}")
            run_git_command(worktree_path, "merge", "--abort")
            return False, f"MERGE CONFLICT: {output}"
        return False, output
    return True, output


def git_merge_into_default(repo_path: str, source_branch: str) -> tuple[bool, str]:
    """Merge a branch into the default branch in the main repo directory."""
    stashed = False
    _, status_output = run_git_command(repo_path, "status", "--porcelain")
    if status_output.strip():
        success, stash_output = run_git_command(repo_path, "stash", "push", "--include-untracked", "-m", f"orchestrator-auto-stash-before-{source_branch}")
        if success and "No local changes" not in stash_output:
            stashed = True
            logger.info(f"Stashed uncommitted changes in {repo_path}")

    success, output = run_git_command(repo_path, "checkout", default_branch)
    if not success:
        if stashed:
            run_git_command(repo_path, "stash", "pop")
        return False, f"Failed to checkout {default_branch}: {output}"

    success, output = run_git_command(repo_path, "merge", source_branch, "--no-edit")
    if not success:
        if "CONFLICT" in output or "conflict" in output.lower():
            logger.error(f"Merge conflict merging {source_branch} into {default_branch}")
            run_git_command(repo_path, "merge", "--abort")
            if stashed:
                run_git_command(repo_path, "stash", "pop")
            return False, f"MERGE CONFLICT: {output}"
        if stashed:
            run_git_command(repo_path, "stash", "pop")
        return False, output

    if stashed:
        run_git_command(repo_path, "stash", "drop")
        logger.info("Dropped auto-stash after successful merge")

    return True, output


def tmux_clear(agent: str):
    """Send /clear to an agent's tmux pane to reset context."""
    target = _agent_pane_targets.get(agent, f"{tmux_session}:{agent}")
    try:
        subprocess.run(
            ["tmux", "send-keys", "-t", target, "-l", "/clear"],
            capture_output=True, text=True, timeout=5,
        )
        time.sleep(0.2)
        subprocess.run(
            ["tmux", "send-keys", "-t", target, "Enter"],
            capture_output=True, text=True, timeout=5,
        )
        logger.info(f"Sent /clear to {agent} (target={target})")
        time.sleep(1)
    except subprocess.SubprocessError as e:
        logger.warning(f"Failed to send /clear to {agent}: {e}")


def tmux_nudge(agent: str):
    """Send a nudge to an agent's tmux window via send-keys."""
    now = time.time()
    last = _last_nudge.get(agent, 0)
    if now - last < tmux_nudge_cooldown:
        logger.debug(
            f"Skipping nudge to {agent} (cooldown: {int(tmux_nudge_cooldown - (now - last))}s remaining)"
        )
        return

    target = _agent_pane_targets.get(agent, f"{tmux_session}:{agent}")
    try:
        result = subprocess.run(
            ["tmux", "send-keys", "-t", target, "-l", tmux_nudge_prompt],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            logger.warning(f"tmux send-keys to {agent} failed (target={target}): {result.stderr.strip()}")
            return
        time.sleep(0.2)
        subprocess.run(
            ["tmux", "send-keys", "-t", target, "Enter"],
            capture_output=True, text=True, timeout=5,
        )
        _last_nudge[agent] = now
        logger.info(f"Nudged {agent} via tmux send-keys (target={target})")
    except FileNotFoundError:
        logger.warning("tmux not found — nudge skipped (agents must poll manually)")
    except subprocess.TimeoutExpired:
        logger.warning(f"tmux send-keys to {agent} timed out")
    except subprocess.SubprocessError as e:
        logger.warning(f"tmux nudge to {agent} failed: {e}")


def check_tmux_session() -> bool:
    """Check if the tmux session exists."""
    try:
        result = subprocess.run(
            ["tmux", "has-session", "-t", tmux_session],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.SubprocessError):
        return False


# --- Interactive command interface ---
_cmd_queue = queue.Queue()
_paused = False


def _stdin_reader():
    """Background thread that reads stdin and queues commands."""
    while True:
        try:
            line = input()
            if line.strip():
                _cmd_queue.put(line.strip())
        except EOFError:
            break


def send_to_pane(agent: str, text: str):
    """Send arbitrary text to an agent's tmux pane and press Enter."""
    target = _agent_pane_targets.get(agent, f"{tmux_session}:{agent}")
    try:
        subprocess.run(
            ["tmux", "send-keys", "-t", target, "-l", text],
            capture_output=True, text=True, timeout=5,
        )
        time.sleep(0.2)
        subprocess.run(
            ["tmux", "send-keys", "-t", target, "Enter"],
            capture_output=True, text=True, timeout=5,
        )
        print(f"  Sent to {agent}: {text[:80]}")
    except subprocess.SubprocessError as e:
        print(f"  Failed to send to {agent}: {e}")


def interpret_natural_command(text: str):
    """Use the LLM to interpret a natural language command."""
    idx, task = get_current_task()
    completed = sum(1 for t in tasks if t["status"] == "completed")
    stuck = sum(1 for t in tasks if t["status"] == "stuck")
    pending = sum(1 for t in tasks if t["status"] == "pending")

    system = """You are the orchestrator's command interpreter. The human typed a message in the orchestrator console.
Interpret their intent and respond with JSON only:
{
  "action": "msg_writer" | "msg_executor" | "nudge_writer" | "nudge_executor" | "skip" | "pause" | "resume" | "status" | "reply",
  "text": "text to send to agent (for msg_writer/msg_executor) or reply to show the human (for reply/status)",
  "reasoning": "brief explanation"
}

Actions:
- msg_writer: send text to Writer agent's terminal
- msg_executor: send text to Executor agent's terminal
- nudge_writer/nudge_executor: remind agent to check messages
- skip: skip current task
- pause/resume: pause/resume polling
- status: show current state (put a summary in "text")
- reply: just respond to the human (for questions, chitchat, etc.)

Keep "text" concise and actionable."""

    context = f"""## Current State
- Current task: {json.dumps(task, indent=2) if task else "None"}
- Completed: {completed}, Pending: {pending}, Stuck: {stuck}, Paused: {_paused}

## Human said:
{text}"""

    decision = llm.decide_with_system(system, context)
    action = decision.get("action", "reply")
    reply_text = decision.get("text", "")

    if action == "msg_writer":
        send_to_pane("writer", reply_text)
    elif action == "msg_executor":
        send_to_pane("executor", reply_text)
    elif action == "nudge_writer":
        _last_nudge.pop("writer", None)
        tmux_nudge("writer")
    elif action == "nudge_executor":
        _last_nudge.pop("executor", None)
        tmux_nudge("executor")
    elif action == "skip":
        handle_command("skip")
    elif action == "pause":
        handle_command("pause")
    elif action == "resume":
        handle_command("resume")
    elif action == "status":
        if reply_text:
            print(f"\n  {reply_text}\n")
        else:
            handle_command("status")
    elif action == "reply":
        print(f"\n  {reply_text}\n")
    else:
        fallback = "Sorry, I didn't understand that."
        print(f"\n  {reply_text or fallback}\n")


def handle_command(cmd: str):
    """Process an interactive command."""
    global _paused
    parts = cmd.split(None, 2)
    command = parts[0].lower()

    if command == "help":
        print("\n--- BDD E2E Orchestrator Commands ---")
        print("  status                     - Current task and progress")
        print("  tasks                      - List all tasks with status")
        print("  skip                       - Skip current stuck/in-progress task")
        print("  nudge writer|executor      - Manually nudge an agent")
        print("  msg writer|executor TEXT   - Send text to an agent's pane")
        print("  pause                      - Pause mailbox polling")
        print("  resume                     - Resume mailbox polling")
        print("  log                        - Show last 10 log entries")
        print("  help                       - Show this help")
        print("--------------------------------------\n")

    elif command == "status":
        idx, task = get_current_task()
        completed = sum(1 for t in tasks if t["status"] == "completed")
        stuck = sum(1 for t in tasks if t["status"] == "stuck")
        pending = sum(1 for t in tasks if t["status"] == "pending")
        print(f"\n--- Status ({args.project}) ---")
        print(f"  Completed: {completed}  In-progress: {1 if task else 0}  Pending: {pending}  Stuck: {stuck}")
        if task:
            print(f"  Current: [{task['id']}] {task['title']}")
            print(f"  Attempts: {task['attempts']}/{config['tasks']['max_attempts_per_task']}")
        else:
            print("  No active task")
        print(f"  Paused: {_paused}")
        print(f"  BDD State: {bdd_state.value}")
        print(f"  Default branch: {default_branch}")
        if current_task_id:
            print(f"  Branches: writer/{current_task_id}, executor/{current_task_id}")
        print(f"--------------\n")

    elif command == "tasks":
        print("\n--- Tasks ---")
        for t in tasks:
            marker = {"completed": "+", "in_progress": ">", "pending": " ", "stuck": "!"}
            m = marker.get(t["status"], "?")
            print(f"  [{m}] {t['id']}: {t['title']} ({t['status']}, attempts: {t['attempts']})")
        print(f"-------------\n")

    elif command == "skip":
        idx, task = get_current_task()
        if task:
            task["status"] = "stuck"
            save_tasks()
            print(f"  Skipped task {task['id']}: {task['title']}")
            next_idx, next_task = get_current_task()
            if next_task:
                print(f"  Next task: {next_task['id']}: {next_task['title']}")
                assign_task_to_writer(next_task)
            else:
                print("  No more tasks")
        else:
            print("  No active task to skip")

    elif command == "nudge":
        if len(parts) < 2 or parts[1] not in ("writer", "executor"):
            print("  Usage: nudge writer|executor")
        else:
            agent = parts[1]
            _last_nudge.pop(agent, None)
            tmux_nudge(agent)

    elif command == "msg":
        if len(parts) < 3 or parts[1] not in ("writer", "executor"):
            print("  Usage: msg writer|executor <text to send>")
        else:
            send_to_pane(parts[1], parts[2])

    elif command == "pause":
        _paused = True
        print("  Polling paused. Type 'resume' to continue.")

    elif command == "resume":
        _paused = False
        print("  Polling resumed.")

    elif command == "log":
        try:
            log_path = Path(__file__).parent / "orchestrator.log"
            lines = log_path.read_text().strip().split("\n")
            print("\n--- Last 10 log entries ---")
            for line in lines[-10:]:
                print(f"  {line}")
            print(f"---------------------------\n")
        except Exception as e:
            print(f"  Could not read log: {e}")

    else:
        # Natural language -- route through LLM
        interpret_natural_command(cmd)


def save_tasks():
    """Persist task state back to file."""
    with open(tasks_path, "w") as f:
        json.dump(tasks_data, f, indent=2)


def get_current_task():
    """Get the current pending or in-progress task."""
    for i, task in enumerate(tasks):
        if task["status"] in ("pending", "in_progress"):
            return i, task
    return None, None


def write_to_mailbox(recipient: str, msg_type: str, content: dict):
    """Write a message directly to an agent's mailbox folder."""
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    msg_id = f"orch-{int(time.time())}-{msg_type}"
    message = {
        "id": msg_id,
        "from": "orchestrator",
        "to": recipient,
        "type": msg_type,
        "content": content,
        "timestamp": timestamp,
        "read": False,
    }

    target_dir = Path(mailbox_dir) / f"to_{recipient}"
    target_dir.mkdir(parents=True, exist_ok=True)
    filepath = target_dir / f"{msg_id}.json"
    filepath.write_text(json.dumps(message, indent=2))
    logger.info(f"Wrote {msg_type} to {recipient}'s mailbox ({msg_id})")
    return message


def build_context(event_type: str, event_data: dict) -> str:
    """Build context string for the LLM decision."""
    idx, current_task = get_current_task()
    remaining = sum(1 for t in tasks if t["status"] == "pending")
    completed = sum(1 for t in tasks if t["status"] == "completed")
    history = mailbox.get_conversation_history()
    recent_history = history[-6:]

    context = f"""## Current State
- Current task: {json.dumps(current_task, indent=2) if current_task else "None"}
- Tasks remaining: {remaining}
- Tasks completed: {completed}
- Task attempts: {current_task['attempts'] if current_task else 0}/{config['tasks']['max_attempts_per_task']}

## Event
Type: {event_type}
Data: {json.dumps(event_data, indent=2)}

## Recent Message History
{json.dumps(recent_history, indent=2) if recent_history else "No messages yet."}

## What should happen next?"""

    return context


def create_task_branches(task_id: str):
    """Create writer/executor branches for a new task in each worktree.

    Always branches from the default branch (main) to ensure a clean start.
    Deletes stale branches from previous runs before creating.
    """
    if not repo_dir:
        return
    agents_cfg = config.get("agents", {})
    branch_map = {
        "writer": f"writer/{task_id}",
        "executor": f"executor/{task_id}",
    }
    for agent, branch in branch_map.items():
        wt_dir = agents_cfg.get(agent, {}).get("working_dir", "")
        if not wt_dir:
            continue
        run_git_command(wt_dir, "checkout", default_branch)
        exists, _ = run_git_command(wt_dir, "rev-parse", "--verify", branch)
        if exists:
            run_git_command(wt_dir, "branch", "-D", branch)
            logger.info(f"Deleted stale {branch} in {agent} worktree")
        success, output = run_git_command(wt_dir, "checkout", "-b", branch)
        if success:
            logger.info(f"Created {branch} from {default_branch} in {agent} worktree")
        else:
            logger.warning(f"Failed to create {branch} in {agent}: {output}")


def assign_task_to_writer(task: dict):
    """Write a task assignment to Writer's mailbox."""
    global bdd_state, current_task_id

    # Clear agent contexts and create task branches for new tasks
    if current_task_id is not None and current_task_id != task["id"]:
        for agent in ("writer", "executor"):
            tmux_clear(agent)

    current_task_id = task["id"]
    create_task_branches(task["id"])

    base_url = config.get("ui", {}).get("base_url", "")
    page_url = task.get("page_url", "")
    test_focus = task.get("test_focus", "")
    acceptance_criteria = task.get("acceptance_criteria", [])

    # Load test data if available
    test_data = {}
    if repo_dir:
        test_data_path = Path(repo_dir) / "e2e" / "support" / "test-data.yaml"
        if test_data_path.exists():
            with open(test_data_path) as f:
                test_data = yaml.safe_load(f) or {}

    global_creds = test_data.get("global", {}).get("credentials", {})
    page_test_data = test_data.get("pages", {}).get(page_url, {})

    if features_mode == "existing":
        feature_file = task.get("feature_file", "")
        instructions = (
            f"Implement Cucumber step definitions and Playwright Page Objects for the existing "
            f"feature file: {feature_file}. "
            f"The staging URL is {base_url}. "
            f"FIRST: Read the feature file to understand all scenarios and steps. "
            f"SECOND: Inspect the page structure by running: npx ts-node e2e/support/inspect.ts {base_url} "
            "to discover available selectors and elements. "
            "If YAML page object references exist in e2e/pages/yaml-refs/, read them for selector hints. "
        )
        if global_creds.get("email"):
            instructions += (
                f"Test credentials are in e2e/support/test-data.yaml "
                f"(email: {global_creds['email']}). Use them for auth steps. "
            )
        instructions += (
            "Create: (1) step definitions in e2e/steps/ matching every step in the feature file, "
            "(2) Page Objects in e2e/pages/ using Playwright selectors. "
            "Do NOT modify the existing .feature file. "
            "Validate syntax with: npx cucumber-js --dry-run. "
            "When ready, commit and use send_to_executor to hand off."
        )

        content = {
            "task_id": task["id"],
            "title": task["title"],
            "description": task["description"],
            "feature_file": feature_file,
            "base_url": base_url,
            "test_data": {"credentials": global_creds},
            "instructions": instructions,
        }
    else:
        instructions = (
            f"Write BDD feature files and step definitions for the {page_url} page. "
            f"The staging URL is {base_url}{page_url}. "
            f"FIRST: Inspect the page structure by running: npx ts-node e2e/support/inspect.ts {base_url}{page_url} "
            "to discover available selectors and elements. "
        )
        if test_focus:
            instructions += f"Focus on testing: {test_focus}. "
        if acceptance_criteria:
            instructions += "Acceptance criteria:\n" + "\n".join(f"- {ac}" for ac in acceptance_criteria) + "\n"
        if global_creds.get("email"):
            instructions += (
                f"Test credentials are available in e2e/support/test-data.yaml "
                f"(email: {global_creds['email']}). Use them for auth steps. "
            )
        instructions += (
            "Create: (1) a .feature file in e2e/features/, (2) step definitions in e2e/steps/, "
            "(3) any needed Page Objects in e2e/pages/. "
            "Validate syntax with: npx cucumber-js --dry-run. "
            "When ready, commit with: git add . && git commit -m 'feat: add e2e tests for <page>' "
            "then use the send_to_executor MCP tool to hand off."
        )

        content = {
            "task_id": task["id"],
            "title": task["title"],
            "description": task["description"],
            "page_url": page_url,
            "base_url": base_url,
            "test_focus": test_focus,
            "acceptance_criteria": acceptance_criteria,
            "test_data": {"credentials": global_creds, "page_data": page_test_data},
            "instructions": instructions,
        }

    write_to_mailbox("writer", "task_assignment", content)
    tmux_nudge("writer")
    task["status"] = "in_progress"
    save_tasks()
    bdd_state = BddState.WAITING_WRITER
    logger.info(f"Assigned task {task['id']} to Writer")
    log_to_report(f"**Task assigned: {task['id']}** -- {task['title']}")


def handle_writer_message(message: dict):
    """Handle message from Writer: feature files ready -> merge into Executor, nudge Executor."""
    global bdd_state
    idx, task = get_current_task()
    if not task:
        logger.warning("Received Writer message but no active task")
        return

    content = message.get("content", {})
    task_id = current_task_id or task["id"]

    # Merge writer/<task> branch into Executor worktree
    executor_dir = config.get("agents", {}).get("executor", {}).get("working_dir", "")
    if repo_dir and executor_dir:
        writer_branch = f"writer/{task_id}"
        logger.info(f"Merging {writer_branch} into Executor worktree...")
        success, output = git_merge_branch(executor_dir, writer_branch)
        if not success:
            bdd_state = BddState.BLOCKED
            logger.error(f"Failed to merge {writer_branch} into Executor: {output}")
            print(f"\nBLOCKED: Git merge failed ({writer_branch} -> Executor)")
            print(f"  {output}")
            print(f"  Resolve manually in {executor_dir} then type 'resume'\n")
            return
        logger.info(f"Merged {writer_branch} into Executor worktree successfully")
        log_file_changes(task_id, "writer", executor_dir, writer_branch)

    base_url = config.get("ui", {}).get("base_url", "")
    env_setup = config.get("env_setup", {})
    setup_cmd = env_setup.get("setup_command") or (f"bash {env_setup.get('setup_script', '')}" if env_setup.get("setup_script") else "")
    teardown_cmd = env_setup.get("teardown_command") or (f"bash {env_setup.get('teardown_script', '')}" if env_setup.get("teardown_script") else "")

    # Load test data for executor
    test_data = {}
    if repo_dir:
        test_data_path = Path(repo_dir) / "e2e" / "support" / "test-data.yaml"
        if test_data_path.exists():
            with open(test_data_path) as f:
                test_data = yaml.safe_load(f) or {}

    executor_instructions = (
        "Feature files and step definitions have been merged into your worktree. "
    )
    if setup_cmd.strip():
        executor_instructions += f"BEFORE running tests, execute environment setup: {setup_cmd}. If setup fails, report failure immediately. "
    executor_instructions += (
        f"Run the Cucumber tests against the staging URL ({base_url}): "
        "npx cucumber-js --format progress --format json:reports/results.json. "
    )
    if teardown_cmd.strip():
        executor_instructions += f"AFTER tests (regardless of pass/fail), run teardown: {teardown_cmd}. "
    executor_instructions += "Report results using the send_executor_results MCP tool."

    executor_content = {
        "task_id": task["id"],
        "summary": content.get("summary", ""),
        "files_changed": content.get("files_changed", []),
        "feature_files": content.get("feature_files", []),
        "branch": f"writer/{task_id}",
        "env_setup": env_setup,
        "test_data": test_data.get("global", {}),
        "instructions": executor_instructions,
    }

    write_to_mailbox("executor", "run_request", executor_content)
    tmux_nudge("executor")
    bdd_state = BddState.WAITING_EXECUTOR
    logger.info(f"Writer done for task {task['id']} -> merged into Executor, forwarded")
    log_to_report(f"**Writer complete: {task['id']}**\n\n{content.get('summary', 'No summary')}\n")


def handle_executor_message(message: dict):
    """Handle message from Executor: test results -> pass (merge to main) or fail (back to Writer)."""
    global bdd_state
    idx, task = get_current_task()
    if not task:
        logger.warning("Received Executor message but no active task")
        return

    task["attempts"] += 1
    content = message.get("content", {})
    status = content.get("status", "unknown")

    if status == "pass":
        task_id = current_task_id or task["id"]

        # Merge executor/<task> into default branch
        if repo_dir:
            executor_branch = f"executor/{task_id}"
            log_file_changes(task_id, "executor", repo_dir, executor_branch)
            logger.info(f"Merging {executor_branch} into {default_branch}...")
            success, output = git_merge_into_default(repo_dir, executor_branch)
            if not success:
                bdd_state = BddState.BLOCKED
                logger.error(f"Failed to merge {executor_branch} into {default_branch}: {output}")
                print(f"\nBLOCKED: Git merge into {default_branch} failed ({executor_branch})")
                print(f"  {output}")
                print(f"  Resolve manually in {repo_dir} then type 'resume'\n")
                return
            logger.info(f"Merged {executor_branch} into {default_branch} successfully")

        # Tests passed -- task complete
        task["status"] = "completed"
        save_tasks()
        bdd_state = BddState.IDLE
        logger.info(f"Task {task['id']} COMPLETED (BDD cycle done)")
        log_to_report(f"**Executor PASS: {task['id']}**\n\n{content.get('summary', 'No summary')}\n")
        log_to_report(f"**TASK COMPLETED: {task['id']}** -- {task['title']}\n")

        next_idx, next_task = get_current_task()
        if next_task:
            assign_task_to_writer(next_task)
        else:
            logger.info("ALL TASKS COMPLETED!")
            for agent in ("writer", "executor"):
                write_to_mailbox(agent, "all_done", {"message": "All tasks complete! Great work."})
                tmux_nudge(agent)

    elif status == "fail":
        # Tests failed -- send back to Writer with failure details
        if task["attempts"] >= config["tasks"]["max_attempts_per_task"]:
            logger.warning(f"Task {task['id']} exceeded max attempts")
            task["status"] = "stuck"
            save_tasks()
            bdd_state = BddState.IDLE
            print(f"\nHUMAN REVIEW NEEDED: Task {task['id']} - {task['title']}")
            print(f"   Failed {task['attempts']} times. Check orchestrator.log.\n")
            log_to_report(f"**TASK STUCK: {task['id']}** -- exceeded max attempts ({task['attempts']})\n")
        else:
            if features_mode == "existing":
                fix_instructions = (
                    "The Executor reported test failures. Review the failure details, "
                    "fix the step definitions or Page Objects (do NOT modify the .feature file), "
                    "then commit and use send_to_executor to hand off again."
                )
                fix_message = "Tests failed. Fix the step definitions or Page Objects and re-send."
            else:
                fix_instructions = (
                    "The Executor reported test failures. Review the failure details, "
                    "fix the issues in feature files, step definitions, or Page Objects, "
                    "then commit and use send_to_executor to hand off again."
                )
                fix_message = "Tests failed. Fix the feature files, step definitions, or Page Objects and re-send."

            write_to_mailbox("writer", "fix_required", {
                "task_id": task["id"],
                "message": fix_message,
                "failures": content.get("failures", []),
                "scenarios_failed": content.get("scenarios_failed", 0),
                "summary": content.get("summary", ""),
                "instructions": fix_instructions,
            })
            tmux_nudge("writer")
            bdd_state = BddState.WAITING_WRITER
            logger.info(f"Task {task['id']} attempt {task['attempts']} - tests failed, back to Writer")

    else:
        # Unknown status -- ask LLM
        context = build_context("executor_results", {
            "status": status,
            "summary": content.get("summary", ""),
        })
        decision = llm.decide(context)
        action = decision.get("action", "flag_human")

        if action == "flag_human":
            task["status"] = "stuck"
            save_tasks()
            bdd_state = BddState.IDLE
            msg = decision.get("message", "Unknown issue")
            print(f"\nHUMAN REVIEW NEEDED: {msg}\n")
            logger.warning(f"Flagged for human: {msg}")


def main():
    """Main orchestrator loop."""
    logger.info("=" * 60)
    logger.info(f"BDD E2E Orchestrator Starting — project: {args.project}")
    logger.info("=" * 60)

    # Pre-flight: check LLM
    if not llm.health_check():
        logger.error("Ollama is not running or model not available!")
        logger.error(f"   Run: ollama pull {config['llm']['model']}")
        sys.exit(1)
    logger.info(f"LLM ready ({config['llm']['model']})")
    logger.info(f"Mailbox dir: {mailbox_dir}")

    # Initialize session report
    with open(session_report_path, "a") as f:
        f.write(f"\n---\n\n# Session: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"- **Project:** {args.project}\n")
        f.write(f"- **Mode:** bdd\n")
        f.write(f"- **Tasks:** {len(tasks)}\n\n")
    logger.info(f"Tasks file: {tasks_path}")
    if repo_dir:
        logger.info(f"Repo dir: {repo_dir}")
        logger.info(f"Default branch: {default_branch}")
    else:
        logger.warning("No repo_dir configured — git operations disabled")

    # Pre-flight: check tmux session
    if check_tmux_session():
        logger.info(f"tmux session '{tmux_session}' detected — nudges enabled")
    else:
        logger.warning(f"tmux session '{tmux_session}' not found — nudges will be skipped")

    # Assign first task (if any)
    idx, first_task = get_current_task()
    if first_task:
        logger.info(f"Starting with task: {first_task['title']}")
        assign_task_to_writer(first_task)
    else:
        logger.info("No pending tasks found — waiting for new tasks or commands")

    # Start interactive command reader
    cmd_thread = threading.Thread(target=_stdin_reader, daemon=True)
    cmd_thread.start()

    # Main polling loop
    poll_interval = config["polling"]["interval_seconds"]
    logger.info(f"Polling mailbox every {poll_interval}s...")
    logger.info("Agents will be nudged via tmux when new messages arrive.")
    logger.info("Type 'help' for interactive commands.")
    logger.info("")

    try:
        while True:
            # Process any queued commands
            while not _cmd_queue.empty():
                try:
                    cmd = _cmd_queue.get_nowait()
                    handle_command(cmd)
                except queue.Empty:
                    break

            # Skip mailbox polling if paused
            if not _paused:
                # Check Writer's mailbox -- messages from Executor (fix results)
                for writer_msg in mailbox.check_new_messages("writer"):
                    sender = writer_msg.get("from", "")
                    if sender == "orchestrator":
                        continue
                    elif sender == "executor":
                        logger.info(f"Executor sent results: {writer_msg['type']}")
                        handle_executor_message(writer_msg)
                    else:
                        logger.info(f"Unknown sender '{sender}' in Writer mailbox: {writer_msg['type']}")

                # Check Executor's mailbox -- messages from Writer (feature files)
                for exec_msg in mailbox.check_new_messages("executor"):
                    sender = exec_msg.get("from", "")
                    if sender == "orchestrator":
                        continue
                    elif sender == "writer":
                        logger.info(f"Writer sent features: {exec_msg['type']}")
                        handle_writer_message(exec_msg)
                    else:
                        logger.info(f"Unknown sender '{sender}' in Executor mailbox: {exec_msg['type']}")

                # Check if all tasks done
                all_done = all(
                    t["status"] in ("completed", "stuck") for t in tasks
                )
                if all_done and any(t["status"] == "completed" for t in tasks):
                    completed = sum(1 for t in tasks if t["status"] == "completed")
                    stuck = sum(1 for t in tasks if t["status"] == "stuck")
                    logger.info(f"All tasks processed: {completed} completed, {stuck} stuck -- still polling")

            time.sleep(poll_interval)

    except KeyboardInterrupt:
        logger.info("Orchestrator stopped by user")
    except Exception as e:
        logger.error(f"Orchestrator crashed: {e}", exc_info=True)


if __name__ == "__main__":
    main()
