# BDD E2E Orchestrator

Automated BDD end-to-end testing with two Claude Code agents: Writer creates Gherkin feature files + Playwright step definitions, Executor runs them against a staging URL. A local AI orchestrator routes tasks and manages git merges.

## Architecture

```
+--------------------------------------+
|     Orchestrator (Qwen3 8B local)    |
|     Polls mailbox, makes decisions,  |
|     manages git merges between phases|
+-----------+--------------------------+
            | reads/writes
      +-----+-----+
      |  Mailbox  |  (shared/<project>/mailbox/)
      +-----+-----+
            | MCP tools: check_messages,
            |   send_to_executor, send_executor_results
      +-----+-----+
      |           |
+-----v----+ +---v--------+
| Writer   | | Executor   |
| Agent    | | Agent      |
| Claude   | | Claude     |
| Code     | | Code       |
+----------+ +------------+
```

### BDD Cycle (per task)

1. Orchestrator assigns a page to Writer
2. **Writer** creates `.feature` file + step definitions + Page Objects
3. Writer validates with `npx cucumber-js --dry-run`, commits, calls `send_to_executor`
4. Orchestrator merges `writer/<task>` into Executor's worktree
5. **Executor** runs `npx cucumber-js` against the staging URL
6. Executor reports pass/fail via `send_executor_results`
7. **Pass**: Orchestrator merges `executor/<task>` into main, advances to next task
8. **Fail**: Orchestrator routes failure details back to Writer for fixes (up to 5 retries)

### State Machine

```
IDLE -> WAITING_WRITER -> WAITING_EXECUTOR -> IDLE (next task)
                                           -> BLOCKED (merge conflict)
```

### Git Flow

```
main -> writer/<task> -> merge into executor -> executor/<task> -> merge into main
```

## Two Modes

The wizard (`new-project.sh`) presents two options:

1. **PM Pre-Flight** -- Launches Claude Code as a PM agent to generate a PRD from a vague idea. Standalone step that exits after generating `prd.md`.

2. **BDD E2E Testing** -- Interactive setup: enter staging URL and pages to test. Creates worktrees, config, tasks, Playwright+Cucumber scaffolding, and agent CLAUDE.md files.

## Prerequisites

- [tmux](https://github.com/tmux/tmux)
- [Node.js](https://nodejs.org/) (18+)
- [Python 3](https://www.python.org/) with `pyyaml`, `requests`
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- [Ollama](https://ollama.com/) with `qwen3:8b` model

## Quick Start

```bash
# 1. Clone
git clone https://github.com/aasc77/bdd-e2e-orchestrator.git my-bdd
cd my-bdd

# 2. Setup
scripts/setup.sh

# 3. Create a project (interactive wizard)
scripts/new-project.sh

# 4. Launch
scripts/start.sh <project-name>          # with prompts
scripts/start.sh <project-name> --yolo   # fully autonomous

# 5. Stop
scripts/stop.sh <project-name>
```

## Configuration

### Project Config (`projects/<name>/config.yaml`)

```yaml
project: my_app
mode: bdd

tmux:
  session_name: my-app

repo_dir: ~/Repositories/my-app

ui:
  base_url: https://staging.example.com

agents:
  writer:
    working_dir: ~/Repositories/my-app/.worktrees/writer
    pane: qa.0
  executor:
    working_dir: ~/Repositories/my-app/.worktrees/executor
    pane: qa.1
```

### Tasks (`projects/<name>/tasks.json`)

```json
{
  "project": "my_app",
  "tasks": [
    {
      "id": "bdd-1",
      "title": "E2E tests for /login",
      "description": "Write BDD feature files for the /login page",
      "page_url": "/login",
      "base_url": "https://staging.example.com",
      "status": "pending",
      "attempts": 0,
      "max_attempts": 5
    }
  ]
}
```

### Shared Defaults (`orchestrator/config.yaml`)

LLM model, polling interval, max retries, nudge cooldown. Project configs are deep-merged with shared defaults.

## File Structure

```
bdd-e2e-orchestrator/
├── orchestrator/
│   ├── orchestrator.py        # Main event loop (BddState, 2-agent handlers)
│   ├── llm_client.py          # Ollama API client
│   ├── mailbox_watcher.py     # File-based mailbox watcher
│   └── config.yaml            # Shared defaults
├── mcp-bridge/
│   └── index.js               # MCP server (send_to_executor, send_executor_results, check_messages)
├── scripts/
│   ├── setup.sh               # Dependency installer
│   ├── new-project.sh         # Interactive wizard (PM Pre-Flight, BDD E2E)
│   ├── start.sh               # Launch 3-pane tmux session
│   └── stop.sh                # Graceful shutdown
├── docs/
│   ├── BDD PROMPTS.md         # Writer + Executor agent role prompts
│   ├── CONTEXT.md             # Architecture reference
│   ├── QUICKSTART.md          # 5-minute setup guide
│   ├── pm_agent.md            # PM Pre-Flight prompt
│   └── MCP Bridge Setup Guide.md
├── projects/<name>/           # Per-project config and tasks
│   ├── config.yaml
│   └── tasks.json
└── shared/<name>/             # Runtime shared data
    ├── mailbox/
    │   ├── to_writer/
    │   └── to_executor/
    └── workspace/
```

## Interactive Commands

Type in the ORCH pane while running:

| Command | Description |
|---------|-------------|
| `status` | Current task and progress |
| `tasks` | List all tasks with status |
| `skip` | Skip current stuck task |
| `nudge writer\|executor` | Remind agent to check messages |
| `msg writer\|executor TEXT` | Send text to an agent's pane |
| `pause` / `resume` | Pause/resume mailbox polling |
| `log` | Show last 10 log entries |
| `help` | Show all commands |

Natural language input is also supported -- the orchestrator interprets it via LLM.

## tmux Layout

```
+--------------------+--------------------+
|  WRITER [project]  | EXECUTOR [project] |
|  (Claude Code)     | (Claude Code)      |
+--------------------+--------------------+
|        ORCHESTRATOR [project]            |
+-----------------------------------------+
```
