# Architecture Context

High-level overview of how the BDD E2E orchestrator is built. Use this as a reference when contributing or debugging.

## System Components

```
scripts/new-project.sh            Interactive wizard (PM Pre-Flight or BDD E2E setup)
scripts/start.sh                  Launches 3-pane tmux session + orchestrator + 2 Claude Code agents
scripts/stop.sh                   Sends /exit to agents, kills tmux session, cleans up branches
orchestrator/orchestrator.py      Main event loop (polls mailbox, manages git merges)
orchestrator/llm_client.py        Ollama API client (Qwen3 8B default)
orchestrator/mailbox_watcher.py   File watcher for JSON messages in shared/<project>/mailbox/
mcp-bridge/index.js               MCP server exposing mailbox tools to Claude Code agents
```

## Two Modes

The wizard (`new-project.sh`) presents two options:

1. **PM Pre-Flight** -- Launches Claude Code as a PM agent to generate a PRD from a vague idea. Standalone step that exits after generating `prd.md`. Does not start the BDD pipeline. Prompt template: `docs/pm_agent.md`.

2. **BDD E2E Testing (`mode: bdd`)** -- Launches an agentic setup wizard that collects staging URL, pages, test credentials, and environment setup commands via conversation. Writer creates Gherkin feature files + step definitions + Page Objects, Executor runs Playwright+Cucumber tests against the staging URL. Agent prompts loaded from `docs/BDD PROMPTS.md`, wizard prompt from `docs/wizard_agent.md`.

## Git Worktree Layout

Each project uses a single repo with two worktrees:

```
<your-repo>/                        # Main repo (default branch, merge target)
├── .worktrees/
│   ├── writer/                     # Writer worktree (writer/<task> branches)
│   └── executor/                   # Executor worktree (executor/<task> branches)
├── e2e/                            # BDD test code
│   ├── features/                   # .feature files (Gherkin)
│   ├── steps/                      # Step definitions (TypeScript)
│   ├── pages/                      # Page Object Models
│   └── support/                    # World class, hooks, test-data.yaml, env scripts
```

Each worktree has its own `CLAUDE.md` with agent-specific instructions and MCP communication protocol.

## BDD State Machine

The orchestrator cycles through these states per task:

```
IDLE --> WAITING_WRITER --> WAITING_EXECUTOR --> IDLE (next task)
                                             └--> BLOCKED (merge conflict)
```

Git merges happen between phases (bash subprocess, not LLM):
- `writer/<task>` merges into Executor's worktree before execution
- `executor/<task>` merges into the default branch (main) after passing

On test failure, the orchestrator routes failure details back to the Writer (up to max_attempts retries). Merge conflicts set state to BLOCKED and flag human review.

## Communication (MCP Bridge)

Agents communicate through JSON files in `shared/<project>/mailbox/`:

```
shared/<project>/mailbox/
├── to_writer/       # Messages for Writer agent
└── to_executor/     # Messages for Executor agent
```

MCP tools available to agents:
- `check_messages` -- Poll mailbox (with role: writer/executor)
- `send_to_executor` -- Writer notifies Executor that feature files are ready
- `send_executor_results` -- Executor sends test results back
- `list_workspace` / `read_workspace_file` -- Shared workspace access

The orchestrator polls the mailbox independently via `mailbox_watcher.py`, routes messages, and writes instructions to agent mailboxes.

## Configuration

```yaml
# projects/<name>/config.yaml
project: my_app
mode: bdd
repo_dir: /path/to/your-repo

tmux:
  session_name: my-app

ui:
  base_url: https://staging.example.com

test_credentials:
  email: test@example.com
  password: ""

env_setup:
  setup_script: e2e/support/env-setup.sh
  teardown_script: e2e/support/env-teardown.sh
  setup_command: ""
  teardown_command: ""

agents:
  writer:
    working_dir: /path/to/your-repo/.worktrees/writer
    pane: qa.0
  executor:
    working_dir: /path/to/your-repo/.worktrees/executor
    pane: qa.1
```

Shared defaults in `orchestrator/config.yaml` (LLM model, polling interval, max retries, nudge cooldown). Project configs are deep-merged with shared defaults.

## tmux Layout

```
+--------------------+--------------------+
|  WRITER [project]  | EXECUTOR [project] |
|  (Claude Code)     | (Claude Code)      |
+--------------------+--------------------+
|        ORCHESTRATOR [project]            |
+-----------------------------------------+
```

3 panes: Writer (top-left, pane 0), Executor (top-right, pane 1), Orchestrator (bottom full-width, pane 2).
