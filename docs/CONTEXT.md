# Architecture Context

High-level overview of how the BDD E2E orchestrator is built. Use this as a reference when contributing or debugging.

## System Components

```
scripts/new-project.sh            Interactive BDD setup wizard
scripts/start.sh                  Launches 3-pane tmux session + orchestrator + 2 Claude Code agents
scripts/stop.sh                   Sends /exit to agents, kills tmux session, cleans up branches
orchestrator/orchestrator.py      Main event loop (polls mailbox, manages git merges)
orchestrator/llm_client.py        Ollama API client (Qwen3 8B default)
orchestrator/mailbox_watcher.py   File watcher for JSON messages in shared/<project>/mailbox/
mcp-bridge/index.js               MCP server exposing mailbox tools to Claude Code agents
```

## Setup Wizard

The wizard (`new-project.sh`) launches an agentic session that collects testing surface, staging URL, pages, test credentials, and environment setup commands via conversation. Two testing surfaces:

- **`browser`** (default) -- Playwright + Cucumber (TypeScript). Writer creates `.feature` files + step defs + Page Objects, Executor runs `npx cucumber-js`.
- **`python`** -- pytest-bdd (Python). Writer creates `.feature` files + pytest-bdd step defs, Executor runs `pytest`.

Agent prompts loaded from `docs/BDD PROMPTS.md`, wizard prompt from `docs/wizard_agent.md`.

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
│   │   └── yaml-refs/              # YAML page objects from source repo (existing mode)
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
testing_surface: "browser"  # "browser" or "python"

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

features_mode: "new"  # "new" (write features from scratch) or "existing" (reuse .feature files)

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
