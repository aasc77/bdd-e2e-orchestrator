# BDD E2E Orchestrator

Automated BDD testing with two Claude Code agents: Writer creates Gherkin feature files + step definitions, Executor runs them. Supports two testing surfaces: **browser** (Playwright + Cucumber) for web UI testing, and **python** (pytest-bdd) for CLI, API, and module testing. A local AI orchestrator routes tasks and manages git merges.

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

1. Orchestrator assigns a task to Writer
2. **Writer** creates `.feature` file + step definitions (+ Page Objects for browser surface)
3. Writer validates (`npx cucumber-js --dry-run` or `pytest --collect-only`), commits, calls `send_to_executor`
4. Orchestrator merges `writer/<task>` into Executor's worktree
5. **Executor** runs tests (`npx cucumber-js` for browser, `pytest` for python)
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

## Testing Surfaces

| Surface | Framework | Language | Use Case |
|---------|-----------|----------|----------|
| `browser` (default) | Playwright + Cucumber | TypeScript | Web UI E2E testing |
| `python` | pytest-bdd | Python | CLI, API, module, agent testing |

The wizard asks which surface to use. Browser projects get `e2e/` with Playwright scaffolding. Python projects get `tests/` with pytest-bdd scaffolding. The orchestrator automatically adapts instructions and test commands to the selected surface.

## Two Modes

The wizard (`new-project.sh`) presents two options:

1. **PM Pre-Flight** -- Launches Claude Code as a PM agent to generate a PRD from a vague idea. Standalone step that exits after generating `prd.md`.

2. **BDD E2E Testing** -- Launches an agentic setup wizard that guides you through staging URL, pages, test credentials, and environment setup via conversation. Creates worktrees, config, tasks, Playwright+Cucumber scaffolding, and agent CLAUDE.md files.

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
testing_surface: "browser"  # "browser" (Playwright+Cucumber) or "python" (pytest-bdd)

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

features_mode: "new"  # "new" (write features from scratch) or "existing" (reuse .feature files)
# test_command: "pytest tests/ -v --tb=short"  # python surface only

agents:
  writer:
    working_dir: ~/Repositories/my-app/.worktrees/writer
    pane: qa.0
  executor:
    working_dir: ~/Repositories/my-app/.worktrees/executor
    pane: qa.1
```

### Tasks (`projects/<name>/tasks.json`)

New mode (write features from scratch):
```json
{
  "project": "my_app",
  "features_mode": "new",
  "tasks": [
    {
      "id": "bdd-1",
      "title": "E2E tests for /login",
      "description": "Write BDD feature files for the /login page",
      "page_url": "/login",
      "base_url": "https://staging.example.com",
      "test_focus": "Login form, OAuth, error messages",
      "test_data": "email: test@example.com",
      "acceptance_criteria": ["User can log in with valid credentials"],
      "status": "pending",
      "attempts": 0,
      "max_attempts": 5
    }
  ]
}
```

Existing mode (reuse `.feature` files from the repo):
```json
{
  "project": "my_app",
  "features_mode": "existing",
  "tasks": [
    {
      "id": "bdd-1",
      "title": "Implement step defs for Login Flow",
      "description": "Implement Cucumber step definitions and Playwright Page Objects for existing feature file: e2e/features/login.feature (8 scenarios)",
      "feature_file": "e2e/features/login.feature",
      "source_feature": "tests/features/login.feature",
      "base_url": "https://staging.example.com",
      "scenario_count": 8,
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
│   ├── stop.sh                # Graceful shutdown
│   ├── reset.sh               # Reset project state
│   ├── manage-test-data.sh    # View/update test credentials
│   └── setup-iterm-profiles.sh # iTerm2 RGR profile setup
├── docs/
│   ├── BDD PROMPTS.md         # Writer + Executor agent role prompts
│   ├── CONTEXT.md             # Architecture reference
│   ├── QUICKSTART.md          # 5-minute setup guide
│   ├── pm_agent.md            # PM Pre-Flight prompt
│   ├── wizard_agent.md        # BDD setup wizard agent prompt
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
