#!/bin/bash
set -e

# ─── Color helpers ────────────────────────────────────────────────────────────
if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
    BOLD="" DIM="" RESET="" GREEN="" YELLOW="" RED="" CYAN=""
else
    BOLD=$(tput bold)    DIM=$(tput dim)     RESET=$(tput sgr0)
    GREEN=$(tput setaf 2) YELLOW=$(tput setaf 3) RED=$(tput setaf 1) CYAN=$(tput setaf 6)
fi

info()    { echo "  ${CYAN}>${RESET} $*"; }
warn()    { echo "  ${YELLOW}!${RESET} $*"; }
error()   { echo "  ${RED}ERROR:${RESET} $*" >&2; }
success() { echo "  ${GREEN}>${RESET} $*"; }

# ─── Resolve script location ─────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOS_DIR="$HOME/Repositories"

# ─── Prompt extraction helper ───────────────────────────────────────────────
extract_prompt() {
    local file="$1" target="$2"
    awk -v t="$target" '
        $0 == "## FILE_TARGET: " t { found=1; next }
        /^## FILE_TARGET:/ { found=0 }
        found { print }
    ' "$file"
}

# ─── Cleanup trap ─────────────────────────────────────────────────────────────
CLEANUP_PROJECT_DIR=""
CLEANUP_SHARED_DIR=""
CLEANUP_REPO_DIR=""

cleanup() {
    if [[ -n "$CLEANUP_PROJECT_DIR" && -d "$CLEANUP_PROJECT_DIR" ]]; then
        rm -rf "$CLEANUP_PROJECT_DIR"
        warn "Cleaned up partial project directory: $CLEANUP_PROJECT_DIR"
    fi
    if [[ -n "$CLEANUP_SHARED_DIR" && -d "$CLEANUP_SHARED_DIR" ]]; then
        rm -rf "$CLEANUP_SHARED_DIR"
        warn "Cleaned up partial shared directory: $CLEANUP_SHARED_DIR"
    fi
    if [[ -n "$CLEANUP_REPO_DIR" && -d "$CLEANUP_REPO_DIR" ]]; then
        rm -rf "$CLEANUP_REPO_DIR"
        warn "Cleaned up partial repo directory: $CLEANUP_REPO_DIR"
    fi
}

trap cleanup INT TERM ERR

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo "  ${BOLD}BDD E2E Project Wizard${RESET}"
echo "  ======================"
echo ""

# ─── Phase 0: Mode selection ────────────────────────────────────────────────
echo "  Select a mode:"
echo ""
echo "    1) PM Pre-Flight      -- Generate a PRD from a vague idea"
echo "    2) BDD E2E Testing    -- Write & run Playwright+Cucumber tests against staging"
echo ""
read -r -p "  Mode [1/2]: " MODE_CHOICE

case "$MODE_CHOICE" in
    1) PROJECT_MODE="pm" ;;
    2) PROJECT_MODE="bdd" ;;
    *)
        error "Invalid choice. Pick 1 or 2."
        exit 1
        ;;
esac
echo ""

# ─── PM Pre-Flight Mode ─────────────────────────────────────────────────────
if [[ "$PROJECT_MODE" == "pm" ]]; then
    info "PM Pre-Flight mode"
    echo ""
    echo "  Describe your idea (one paragraph):"
    read -r -p "  > " USER_IDEA

    if [[ -z "$USER_IDEA" ]]; then
        error "Idea cannot be empty."
        exit 1
    fi

    # Extract PM prompt from docs
    PM_PROMPT_FILE="$ROOT_DIR/docs/pm_agent.md"
    if [[ ! -f "$PM_PROMPT_FILE" ]]; then
        error "PM prompt file not found: $PM_PROMPT_FILE"
        exit 1
    fi

    PM_PROMPT=$(extract_prompt "$PM_PROMPT_FILE" "pm_agent/CLAUDE.md")
    PM_PROMPT="${PM_PROMPT//\{\{USER_IDEA\}\}/$USER_IDEA}"

    PM_TMPDIR=$(mktemp -d)
    cat > "$PM_TMPDIR/CLAUDE.md" <<PMEOF
$PM_PROMPT

---

## User's Idea
$USER_IDEA

## Output
Write the complete PRD to a file called \`prd.md\` in this directory.
PMEOF

    info "Launching Claude Code as PM agent..."
    echo "  Working dir: $PM_TMPDIR"
    echo ""

    (cd "$PM_TMPDIR" && claude --dangerously-skip-permissions) || true

    if [[ -f "$PM_TMPDIR/prd.md" ]]; then
        success "PRD generated: $PM_TMPDIR/prd.md"
        echo ""
        echo "  ${BOLD}Preview (first 20 lines):${RESET}"
        head -20 "$PM_TMPDIR/prd.md" | sed 's/^/    /'
        echo "    ..."
        echo ""
        read -r -p "  Save PRD to a project's Writer mailbox? [folder name or n]: " SAVE_TARGET
        if [[ -n "$SAVE_TARGET" && "$SAVE_TARGET" != "n" ]]; then
            SAVE_KEY="${SAVE_TARGET//_/-}"
            SAVE_MAILBOX="$ROOT_DIR/shared/$SAVE_KEY/mailbox/to_writer"
            if [[ -d "$SAVE_MAILBOX" ]]; then
                cp "$PM_TMPDIR/prd.md" "$SAVE_MAILBOX/prd.md"
                success "Saved PRD to $SAVE_MAILBOX/prd.md"
            else
                warn "Mailbox not found: $SAVE_MAILBOX"
                warn "PRD remains at: $PM_TMPDIR/prd.md"
            fi
        else
            info "PRD remains at: $PM_TMPDIR/prd.md"
        fi
    else
        warn "No prd.md generated. Check $PM_TMPDIR for output."
    fi

    exit 0
fi

# ─── BDD E2E Mode ────────────────────────────────────────────────────────────
PROMPT_FILE="$ROOT_DIR/docs/BDD PROMPTS.md"
info "Mode: BDD E2E Testing"

if [[ ! -f "$PROMPT_FILE" ]]; then
    error "Prompt file not found: $PROMPT_FILE"
    exit 1
fi
echo ""

# ─── Phase 1: Gather folder name ─────────────────────────────────────────────
FOLDER_NAME="${1:-}"

# Interactive picker: list git repos in ~/Repositories/
if [[ -z "$FOLDER_NAME" ]]; then
    REPO_DIRS=()
    while IFS= read -r d; do
        if [[ -d "$d/.git" ]]; then
            REPO_DIRS+=("$(basename "$d")")
        fi
    done < <(find "$REPOS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

    if [[ ${#REPO_DIRS[@]} -eq 0 ]]; then
        error "No git repos found in $REPOS_DIR"
        exit 1
    fi

    echo "  ${BOLD}Git repos in ~/Repositories/:${RESET}"
    echo ""
    for i in "${!REPO_DIRS[@]}"; do
        printf "    %3d) %s\n" "$((i + 1))" "${REPO_DIRS[$i]}"
    done
    echo ""
    read -r -p "  Select repo number (or type a new folder name): " REPO_SELECTION

    if [[ "$REPO_SELECTION" =~ ^[0-9]+$ ]] && (( REPO_SELECTION >= 1 && REPO_SELECTION <= ${#REPO_DIRS[@]} )); then
        FOLDER_NAME="${REPO_DIRS[$((REPO_SELECTION - 1))]}"
    else
        FOLDER_NAME="$REPO_SELECTION"
    fi
fi

while true; do
    if [[ -z "$FOLDER_NAME" ]]; then
        read -r -p "  Folder name (in ~/Repositories/): " FOLDER_NAME
    fi

    if [[ -z "$FOLDER_NAME" ]]; then
        warn "Folder name cannot be empty."
        FOLDER_NAME=""
        continue
    fi

    if [[ ! "$FOLDER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        warn "Invalid name: only letters, numbers, hyphens, and underscores allowed."
        FOLDER_NAME=""
        continue
    fi

    break
done

# ─── Phase 2: Derive project name + key ──────────────────────────────────────
REPO_DIR="$REPOS_DIR/$FOLDER_NAME"
PROJECT_NAME="${FOLDER_NAME//-/_}"
PROJECT_KEY="${FOLDER_NAME//_/-}"

# Worktree paths inside the repo
WRITER_DIR="$REPO_DIR/.worktrees/writer"
EXECUTOR_DIR="$REPO_DIR/.worktrees/executor"

echo ""
info "Project name: $PROJECT_NAME"
info "Project key:  $PROJECT_KEY"
info "Repo dir:     $REPO_DIR"

# Validate project key doesn't conflict with existing project
if [[ -d "$ROOT_DIR/projects/$PROJECT_KEY" ]]; then
    error "Project '$PROJECT_KEY' already exists at projects/$PROJECT_KEY/"
    echo "  Choose a different key or remove the existing project first."
    exit 1
fi

# ─── Phase 2b: Gather staging URL and pages ──────────────────────────────────
echo ""
echo "  ${BOLD}Staging URL${RESET}"
echo "  Enter the base URL of the staging environment to test against."
echo ""
read -r -p "  Base URL (e.g., https://staging.example.com): " UI_BASE_URL

if [[ -z "$UI_BASE_URL" ]]; then
    error "Base URL is required for BDD E2E testing."
    exit 1
fi

# Strip trailing slash
UI_BASE_URL="${UI_BASE_URL%/}"

echo ""
echo "  ${BOLD}Pages to test${RESET}"
echo "  Enter page paths to generate tasks (one per line, relative paths)."
echo "  Press Enter on an empty line when done."
echo ""

UI_PAGES=()
while true; do
    read -r -p "  Page path (e.g., /login): " PAGE_PATH
    if [[ -z "$PAGE_PATH" ]]; then
        break
    fi
    # Ensure leading slash
    if [[ "$PAGE_PATH" != /* ]]; then
        PAGE_PATH="/$PAGE_PATH"
    fi
    UI_PAGES+=("$PAGE_PATH")
done

if [[ ${#UI_PAGES[@]} -eq 0 ]]; then
    warn "No pages specified. Adding default /login page."
    UI_PAGES=("/")
fi

info "Will create ${#UI_PAGES[@]} BDD task(s) against $UI_BASE_URL"

# ─── Phase 3: Initialize git repo ────────────────────────────────────────────
if [[ -d "$REPO_DIR/.git" ]]; then
    info "Git repo already exists at $REPO_DIR"
else
    mkdir -p "$REPO_DIR"
    git -C "$REPO_DIR" init --quiet
    info "Initialized git repo: $REPO_DIR"

    cat > "$REPO_DIR/.gitignore" <<'GIEOF'
# Worktrees (agent-specific checkouts)
.worktrees/

# Node
node_modules/
reports/

# Python
__pycache__/
*.pyc

# IDE
.vscode/
.idea/

# OS
.DS_Store
GIEOF
    info "Created .gitignore"

    git -C "$REPO_DIR" add .gitignore
    git -C "$REPO_DIR" commit --quiet -m "chore: initial commit with .gitignore"
    info "Created initial commit on main"
fi

# Detect default branch name
DEFAULT_BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")

# Ensure .worktrees/ is in .gitignore
if [[ -f "$REPO_DIR/.gitignore" ]]; then
    if ! grep -q '^\.worktrees/' "$REPO_DIR/.gitignore"; then
        echo -e '\n# Worktrees (agent-specific checkouts)\n.worktrees/' >> "$REPO_DIR/.gitignore"
        git -C "$REPO_DIR" add .gitignore
        git -C "$REPO_DIR" commit --quiet -m "chore: add .worktrees/ to .gitignore"
        info "Added .worktrees/ to existing .gitignore"
    fi
else
    echo -e '# Worktrees (agent-specific checkouts)\n.worktrees/' > "$REPO_DIR/.gitignore"
    git -C "$REPO_DIR" add .gitignore
    git -C "$REPO_DIR" commit --quiet -m "chore: add .gitignore with .worktrees/"
    info "Created .gitignore with .worktrees/"
fi

# ─── Phase 4: Create worktrees ───────────────────────────────────────────────
for wt_name in writer executor; do
    wt_path="$REPO_DIR/.worktrees/$wt_name"
    wt_branch="${wt_name}-main"
    if [[ -d "$wt_path" ]]; then
        info "Worktree already exists: .worktrees/$wt_name"
    else
        git -C "$REPO_DIR" worktree add "$wt_path" -b "$wt_branch" --quiet
        info "Created worktree: .worktrees/$wt_name (branch: $wt_branch)"
    fi
done

# Clean up stale root-level files from old wizard runs
if [[ -f "$REPO_DIR/CLAUDE.md" ]]; then
    warn "Found stale CLAUDE.md at repo root (from old wizard run)"
    warn "Agents use .worktrees/*/CLAUDE.md now. Removing root copy."
    if git -C "$REPO_DIR" ls-files --error-unmatch CLAUDE.md 2>/dev/null; then
        git -C "$REPO_DIR" rm --quiet -f CLAUDE.md
        git -C "$REPO_DIR" commit --quiet -m "chore: remove stale root CLAUDE.md"
    else
        rm "$REPO_DIR/CLAUDE.md"
    fi
fi

# ─── Phase 4b: Playwright+Cucumber bootstrap ─────────────────────────────────
echo ""
if [[ ! -f "$REPO_DIR/playwright.config.ts" && ! -f "$REPO_DIR/cucumber.js" ]]; then
    echo "  ${BOLD}Playwright + Cucumber Setup${RESET}"
    echo ""
    read -r -p "  Initialize Playwright+Cucumber scaffolding? [Y/n]: " SCAFFOLD_CHOICE
    SCAFFOLD_CHOICE="${SCAFFOLD_CHOICE:-Y}"

    if [[ "$SCAFFOLD_CHOICE" =~ ^[Yy]$ ]]; then
        info "Bootstrapping Playwright+Cucumber..."

        # Initialize package.json if needed
        if [[ ! -f "$REPO_DIR/package.json" ]]; then
            (cd "$REPO_DIR" && npm init -y --silent 2>/dev/null)
            info "Created package.json"
        fi

        # Install dependencies
        (cd "$REPO_DIR" && npm install -D @playwright/test @cucumber/cucumber typescript ts-node --silent 2>/dev/null)
        info "Installed @playwright/test, @cucumber/cucumber, typescript, ts-node"

        # Install Chromium browser
        (cd "$REPO_DIR" && npx playwright install chromium 2>/dev/null)
        info "Installed Chromium browser"

        # Create cucumber.js config
        cat > "$REPO_DIR/cucumber.js" <<'CUCEOF'
module.exports = {
  default: {
    require: ['e2e/steps/**/*.ts', 'e2e/support/**/*.ts'],
    requireModule: ['ts-node/register'],
    format: ['progress', 'json:reports/results.json'],
    paths: ['e2e/features/**/*.feature'],
  },
};
CUCEOF
        info "Created cucumber.js config"

        # Create tsconfig.json for e2e
        cat > "$REPO_DIR/tsconfig.json" <<'TSEOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "moduleResolution": "node",
    "esModuleInterop": true,
    "strict": true,
    "outDir": "dist",
    "rootDir": ".",
    "resolveJsonModule": true,
    "skipLibCheck": true
  },
  "include": ["e2e/**/*.ts"]
}
TSEOF
        info "Created tsconfig.json"

        # Create directory structure
        mkdir -p "$REPO_DIR/e2e/features"
        mkdir -p "$REPO_DIR/e2e/steps"
        mkdir -p "$REPO_DIR/e2e/pages"
        mkdir -p "$REPO_DIR/e2e/support"
        mkdir -p "$REPO_DIR/reports"
        info "Created e2e/ directory structure"

        # Create custom World class
        cat > "$REPO_DIR/e2e/support/world.ts" <<'WORLDEOF'
import { World, IWorldOptions, setWorldConstructor } from '@cucumber/cucumber';
import { Browser, BrowserContext, Page, chromium } from '@playwright/test';

export class BddWorld extends World {
  browser!: Browser;
  context!: BrowserContext;
  page!: Page;

  constructor(options: IWorldOptions) {
    super(options);
  }

  async init() {
    this.browser = await chromium.launch({ headless: true });
    this.context = await this.browser.newContext();
    this.page = await this.context.newPage();
  }

  async cleanup() {
    await this.page?.close();
    await this.context?.close();
    await this.browser?.close();
  }
}

setWorldConstructor(BddWorld);
WORLDEOF
        info "Created e2e/support/world.ts (custom World class)"

        # Create hooks
        cat > "$REPO_DIR/e2e/support/hooks.ts" <<'HOOKEOF'
import { Before, After, AfterStep, Status } from '@cucumber/cucumber';
import { BddWorld } from './world';

Before(async function (this: BddWorld) {
  await this.init();
});

After(async function (this: BddWorld) {
  await this.cleanup();
});

AfterStep(async function (this: BddWorld, { result }) {
  if (result?.status === Status.FAILED) {
    const screenshot = await this.page.screenshot();
    this.attach(screenshot, 'image/png');
  }
});
HOOKEOF
        info "Created e2e/support/hooks.ts (Before/After/AfterStep)"

        # Add reports/ to .gitignore
        if ! grep -q '^reports/' "$REPO_DIR/.gitignore" 2>/dev/null; then
            echo -e '\n# Test reports\nreports/' >> "$REPO_DIR/.gitignore"
        fi

        # Commit scaffolding
        git -C "$REPO_DIR" add -A
        git -C "$REPO_DIR" commit --quiet -m "chore: add Playwright+Cucumber e2e scaffolding"
        info "Committed scaffolding to git"
    else
        info "Skipping scaffolding -- you can set it up manually later"
    fi
else
    info "Playwright/Cucumber config already exists -- skipping scaffolding"
fi

# ─── Phase 5: Confirmation summary ───────────────────────────────────────────
PROJECT_DIR="$ROOT_DIR/projects/$PROJECT_KEY"
SHARED_DIR="$ROOT_DIR/shared/$PROJECT_KEY"

echo ""
echo "  ${BOLD}=================================${RESET}"
echo "  ${BOLD}Project Setup Summary${RESET}"
echo "  ${BOLD}=================================${RESET}"
echo "  Project key:   ${CYAN}$PROJECT_KEY${RESET}"
echo "  Project name:  ${CYAN}$PROJECT_NAME${RESET}"
echo "  Repo dir:      $REPO_DIR"
echo "  Base URL:      $UI_BASE_URL"
echo "  Pages:         ${UI_PAGES[*]}"
echo "    .worktrees/writer/:    Writer agent"
echo "    .worktrees/executor/:  Executor agent"
echo ""
echo "  Will create:"
echo "    projects/$PROJECT_KEY/config.yaml"
echo "    projects/$PROJECT_KEY/tasks.json"
echo "    shared/$PROJECT_KEY/mailbox/{to_writer,to_executor}/"
echo "    shared/$PROJECT_KEY/workspace/"
for agent_name in writer executor; do
    agent_dir="$REPO_DIR/.worktrees/$agent_name"
    if [[ -f "$agent_dir/CLAUDE.md" ]]; then
        if grep -q "agent-bridge" "$agent_dir/CLAUDE.md" 2>/dev/null; then
            echo "    .worktrees/$agent_name/CLAUDE.md  ${DIM}(exists, MCP already present -- skip)${RESET}"
        else
            echo "    .worktrees/$agent_name/CLAUDE.md  ${YELLOW}(exists -- will append MCP section)${RESET}"
        fi
    else
        echo "    .worktrees/$agent_name/CLAUDE.md  ${DIM}(new)${RESET}"
    fi
done
echo "  ${BOLD}=================================${RESET}"
echo ""

echo ""

# ─── Phase 6: Create all files ───────────────────────────────────────────────

# Mark for cleanup on failure
CLEANUP_PROJECT_DIR="$PROJECT_DIR"
CLEANUP_SHARED_DIR="$SHARED_DIR"

# Create directory structure
mkdir -p "$PROJECT_DIR"
mkdir -p "$SHARED_DIR/mailbox/to_writer"
mkdir -p "$SHARED_DIR/mailbox/to_executor"
mkdir -p "$SHARED_DIR/workspace"

# --- config.yaml ---
cat > "$PROJECT_DIR/config.yaml" <<EOF
# Project: $PROJECT_NAME
project: $PROJECT_NAME
mode: bdd

tmux:
  session_name: $PROJECT_KEY

repo_dir: $REPO_DIR

ui:
  base_url: $UI_BASE_URL

agents:
  writer:
    working_dir: $WRITER_DIR
    pane: qa.0
  executor:
    working_dir: $EXECUTOR_DIR
    pane: qa.1
EOF
info "Created projects/$PROJECT_KEY/config.yaml"

# --- tasks.json ---
{
    echo "{"
    echo "  \"project\": \"$PROJECT_NAME\","
    echo "  \"tasks\": ["
    TASK_NUM=0
    LAST_IDX=$(( ${#UI_PAGES[@]} - 1 ))
    for page_path in "${UI_PAGES[@]}"; do
        TASK_NUM=$((TASK_NUM + 1))
        # Derive a clean title from the path
        PAGE_LABEL="${page_path#/}"
        PAGE_LABEL="${PAGE_LABEL:-home}"
        COMMA=","
        if [[ $((TASK_NUM - 1)) -eq $LAST_IDX ]]; then
            COMMA=""
        fi
        cat <<TASKEOF
    {
      "id": "bdd-$TASK_NUM",
      "title": "E2E tests for $page_path",
      "description": "Write BDD feature files and step definitions for the $page_path page at $UI_BASE_URL$page_path",
      "page_url": "$page_path",
      "base_url": "$UI_BASE_URL",
      "status": "pending",
      "attempts": 0,
      "max_attempts": 5
    }$COMMA
TASKEOF
    done
    echo "  ]"
    echo "}"
} > "$PROJECT_DIR/tasks.json"
info "Created projects/$PROJECT_KEY/tasks.json (${#UI_PAGES[@]} BDD tasks)"

# --- MCP protocol snippets ---

IFS= read -r -d '' WRITER_MCP_SECTION <<'WRITERMCP' || true

---

## Communication Protocol (MCP-Based)

You are the **WRITER** agent in an automated BDD E2E testing workflow with an AI orchestrator.

### MCP Tools Available
You have these tools from the `agent-bridge` MCP server:

- **`send_to_executor`** -- Notify Executor that feature files are ready to run
  - `summary`: What you wrote/changed
  - `files_changed`: List of files created or modified
  - `feature_files`: List of .feature files to test
  - `dry_run_output`: Output from npx cucumber-js --dry-run

- **`check_messages`** -- Check your mailbox for orchestrator tasks and Executor feedback
  - `role`: Always use `"writer"`

- **`list_workspace`** -- See all files in the shared workspace

- **`read_workspace_file`** -- Read a specific file from workspace

### Workflow
1. Receive a task via `check_messages` (role: `"writer"`)
2. Create .feature files in `e2e/features/`
3. Create step definitions in `e2e/steps/`
4. Create or update Page Objects in `e2e/pages/`
5. Validate syntax: `npx cucumber-js --dry-run`
6. **Commit your work**: `git add . && git commit -m "feat: add e2e tests for <page>"`
7. Call `send_to_executor` with summary and files changed
8. Wait -- periodically call `check_messages` with role `"writer"` to get feedback

### Rules
- ALWAYS commit your code BEFORE calling send_to_executor
- Use data-testid selectors in Page Objects when available
- Write clear, business-readable Gherkin scenarios
- Include @smoke or @regression tags as appropriate
- If a task is ambiguous, make reasonable assumptions and document them
WRITERMCP

IFS= read -r -d '' EXECUTOR_MCP_SECTION <<'EXECMCP' || true

---

## Communication Protocol (MCP-Based)

You are the **EXECUTOR** agent in an automated BDD E2E testing workflow with an AI orchestrator.

### MCP Tools Available
You have these tools from the `agent-bridge` MCP server:

- **`send_executor_results`** -- Report test execution results
  - `status`: `"pass"` or `"fail"`
  - `summary`: Summary of test results
  - `scenarios_passed`: Number of scenarios that passed
  - `scenarios_failed`: Number of scenarios that failed
  - `failures`: Array of failure details (scenario, step, error, screenshot)
  - `screenshots`: Paths to failure screenshots

- **`check_messages`** -- Check your mailbox for run requests
  - `role`: Always use `"executor"`

- **`list_workspace`** -- See all files in the shared workspace

- **`read_workspace_file`** -- Read a specific file from workspace

### Workflow
1. Receive a run request via `check_messages` (role: `"executor"`)
2. Feature files and step definitions are already in your worktree (merged by orchestrator)
3. Run: `npx cucumber-js --format progress --format json:reports/results.json`
4. Analyze results and capture any failure screenshots
5. Call `send_executor_results` with status, summary, and failure details

### Rules
- Do NOT modify feature files, step definitions, or Page Objects
- Always verify staging URL is reachable before running tests
- Capture screenshots on failure
- Provide actionable failure details so Writer can fix issues
- If tests pass, report success with scenario counts
EXECMCP

# Extract role prompts from BDD prompt file
WRITER_ROLE_PROMPT=$(extract_prompt "$PROMPT_FILE" "writer_agent/CLAUDE.md")
EXECUTOR_ROLE_PROMPT=$(extract_prompt "$PROMPT_FILE" "executor_agent/CLAUDE.md")

# --- Writer CLAUDE.md ---
if [[ -f "$WRITER_DIR/CLAUDE.md" ]]; then
    if grep -q "agent-bridge" "$WRITER_DIR/CLAUDE.md" 2>/dev/null; then
        info "Writer CLAUDE.md already has MCP protocol -- skipped"
    else
        echo "$WRITER_MCP_SECTION" >> "$WRITER_DIR/CLAUDE.md"
        success "Appended MCP protocol to existing $WRITER_DIR/CLAUDE.md"
    fi
else
    {
        printf '%s\n\n' "# Writer Agent -- $PROJECT_NAME"
        printf '%s\n' "$WRITER_ROLE_PROMPT"
        printf '%s\n' "$WRITER_MCP_SECTION"
    } > "$WRITER_DIR/CLAUDE.md"
    info "Created $WRITER_DIR/CLAUDE.md"
fi

# --- Executor CLAUDE.md ---
if [[ -f "$EXECUTOR_DIR/CLAUDE.md" ]]; then
    if grep -q "agent-bridge" "$EXECUTOR_DIR/CLAUDE.md" 2>/dev/null; then
        info "Executor CLAUDE.md already has MCP protocol -- skipped"
    else
        echo "$EXECUTOR_MCP_SECTION" >> "$EXECUTOR_DIR/CLAUDE.md"
        success "Appended MCP protocol to existing $EXECUTOR_DIR/CLAUDE.md"
    fi
else
    {
        printf '%s\n\n' "# Executor Agent -- $PROJECT_NAME"
        printf '%s\n' "$EXECUTOR_ROLE_PROMPT"
        printf '%s\n' "$EXECUTOR_MCP_SECTION"
    } > "$EXECUTOR_DIR/CLAUDE.md"
    info "Created $EXECUTOR_DIR/CLAUDE.md"
fi

# Clear cleanup markers on success
CLEANUP_PROJECT_DIR=""
CLEANUP_SHARED_DIR=""
CLEANUP_REPO_DIR=""

success "Created projects/$PROJECT_KEY/"
success "Created shared/$PROJECT_KEY/mailbox/"
success "Done!"

# ─── Phase 7: Launch ─────────────────────────────────────────────────────────
echo ""
read -r -p "  Auto-approve agent actions (--yolo)? [Y/n]: " YOLO_CHOICE
YOLO_CHOICE="${YOLO_CHOICE:-Y}"
YOLO_ARG=""
if [[ "$YOLO_CHOICE" =~ ^[Yy]$ ]]; then
    YOLO_ARG="--yolo"
fi
echo ""
exec "$ROOT_DIR/scripts/start.sh" "$PROJECT_KEY" $YOLO_ARG
