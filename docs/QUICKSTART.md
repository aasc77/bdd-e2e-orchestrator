# Quickstart Guide

Get up and running in 5 minutes. See the [README](../README.md) for architecture details and configuration reference.

## 1. Install

```bash
brew install tmux node python3 ollama
npm install -g @anthropic-ai/claude-code
ollama serve   # leave running
```

## 2. Setup

```bash
git clone https://github.com/aasc77/bdd-e2e-orchestrator.git my-bdd
my-bdd/scripts/setup.sh
```

Setup installs dependencies, pulls the Qwen3 8B model, configures the MCP bridge, and prompts you to create your first project.

## 3. Create a Project

The setup wizard runs automatically at the end of step 2. To run it again later:

```bash
my-bdd/scripts/new-project.sh           # interactive
my-bdd/scripts/new-project.sh my-app    # skip folder prompt
```

The wizard asks you to pick a mode:
1. **PM Pre-Flight** -- generate a PRD from a vague idea (exits after, run wizard again for mode 2)
2. **BDD E2E Testing** -- write & run Playwright+Cucumber tests against a staging URL

For mode 2, an agentic wizard launches and guides you through:
- **Staging URL** -- the base URL to test against
- **Existing features** -- auto-discovers `.feature` files and YAML page objects in the repo; offers to reuse them (generates "implement step defs" tasks) or start fresh
- **Pages** -- which routes to test (can auto-discover from repo; skipped if reusing existing features)
- **Test credentials** -- email/password for auth (stored in `e2e/support/test-data.yaml`)
- **Environment setup/teardown** -- commands to run before/after tests
- **PRD import** -- optionally read a PRD to extract pages and acceptance criteria

The wizard creates worktrees, config, tasks, Playwright+Cucumber scaffolding (`e2e/` directory, `cucumber.js`, `tsconfig.json`), test data files, and agent `CLAUDE.md` files.

## 4. Customize

Edit the generated files before launching:

```bash
vi my-bdd/projects/<name>/tasks.json                 # adjust task descriptions
vi <your-repo>/.worktrees/writer/CLAUDE.md           # Writer: selectors, patterns
vi <your-repo>/.worktrees/executor/CLAUDE.md         # Executor: test environment
vi <your-repo>/e2e/support/test-data.yaml            # test credentials and per-page data
vi <your-repo>/e2e/support/env-setup.sh              # pre-test environment setup
vi <your-repo>/e2e/support/env-teardown.sh           # post-test cleanup
```

To update test credentials securely:
```bash
my-bdd/scripts/manage-test-data.sh <name>            # view credentials
my-bdd/scripts/manage-test-data.sh <name> --set      # update interactively
```

The more project context you add to each `CLAUDE.md`, the better the agents perform.

## 5. Launch

```bash
my-bdd/scripts/start.sh <name>             # with confirmation prompts
my-bdd/scripts/start.sh <name> --yolo      # fully autonomous (no prompts)
```

You'll see a 3-pane tmux layout:

```
+--------------------+--------------------+
|  WRITER            | EXECUTOR           |
+--------------------+--------------------+
|        ORCHESTRATOR                      |
+-----------------------------------------+
```

The orchestrator starts the BDD cycle automatically. Type `status`, `tasks`, or `help` in the ORCH pane to interact. See [README > Interactive Commands](../README.md#interactive-commands) for the full command list.

## 6. Stop

```bash
my-bdd/scripts/stop.sh <name>
```
