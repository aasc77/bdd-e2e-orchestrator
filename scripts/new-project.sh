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

# ─── Load prompts ────────────────────────────────────────────────────────────
PROMPT_FILE="$ROOT_DIR/docs/BDD PROMPTS.md"

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

# ─── Phase 2b: Agentic wizard ──────────────────────────────────────────────
WIZARD_PROMPT_FILE="$ROOT_DIR/docs/wizard_agent.md"
if [[ ! -f "$WIZARD_PROMPT_FILE" ]]; then
    error "Wizard prompt file not found: $WIZARD_PROMPT_FILE"
    exit 1
fi

WIZARD_PROMPT=$(extract_prompt "$WIZARD_PROMPT_FILE" "wizard_agent/CLAUDE.md")

WIZARD_TMPDIR=$(mktemp -d)
cat > "$WIZARD_TMPDIR/CLAUDE.md" <<WIZEOF
$WIZARD_PROMPT

---

## Project Context
- Project: $PROJECT_NAME
- Repo dir: $REPO_DIR
- Repo has files: $(ls "$REPO_DIR" 2>/dev/null | head -20 | tr '\n' ', ')

## Output
Write the setup data to a file called \`wizard-output.json\` in this directory.
WIZEOF

# Give the agent read access to the repo
ln -sf "$REPO_DIR" "$WIZARD_TMPDIR/repo"

info "Launching setup wizard..."
echo ""
echo "  ${YELLOW}Type 'go' to start the wizard${RESET}"
echo ""

(cd "$WIZARD_TMPDIR" && claude --dangerously-skip-permissions) || true

# Read wizard output
WIZARD_OUTPUT="$WIZARD_TMPDIR/wizard-output.json"
if [[ ! -f "$WIZARD_OUTPUT" ]]; then
    error "Wizard did not produce wizard-output.json. Aborting."
    exit 1
fi

# Parse wizard output into variables
UI_BASE_URL=$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d.get('base_url',''))")
UI_BASE_URL="${UI_BASE_URL%/}"

if [[ -z "$UI_BASE_URL" && "$TESTING_SURFACE" == "browser" ]]; then
    error "No base URL in wizard output."
    exit 1
fi

# Parse pages into arrays
PAGE_COUNT=$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(len(d.get('pages',[])))")
UI_PAGES=()
UI_FOCUS=()
UI_CRITERIA=()
UI_TEST_DATA=()
for (( idx=0; idx<PAGE_COUNT; idx++ )); do
    UI_PAGES+=("$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d['pages'][$idx]['path'])")")
    UI_FOCUS+=("$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d['pages'][$idx].get('test_focus',''))")")
    UI_TEST_DATA+=("$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d['pages'][$idx].get('test_data',''))")")
    CRITERIA=$(python3 -c "import json,sys; d=json.load(open('$WIZARD_OUTPUT')); print(json.dumps(d['pages'][$idx].get('acceptance_criteria',[])))")
    UI_CRITERIA+=("$CRITERIA")
done

# Parse credentials
TEST_USER_EMAIL=$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d.get('credentials',{}).get('email',''))")
TEST_USER_PASSWORD=$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d.get('credentials',{}).get('password',''))")

# Parse env setup
ENV_SETUP_CMD=$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d.get('env_setup',{}).get('setup_command',''))")
ENV_TEARDOWN_CMD=$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d.get('env_setup',{}).get('teardown_command',''))")

# Parse PRD path
PRD_PATH=$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d.get('prd_path',''))")

# Parse testing surface
TESTING_SURFACE=$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d.get('testing_surface','browser'))")
TEST_COMMAND=$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d.get('test_command','pytest tests/ -v --tb=short'))")
PROJECT_ROOT=$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d.get('project_root',''))")

# Parse features mode
FEATURES_MODE=$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d.get('features_mode','new'))")
FEATURES_DIR=$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d.get('features_dir',''))")

# Parse feature files array
FEATURE_FILE_COUNT=$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(len(d.get('feature_files',[])))")
FEATURE_SOURCE_PATHS=()
FEATURE_NAMES=()
FEATURE_SCENARIO_COUNTS=()
for (( idx=0; idx<FEATURE_FILE_COUNT; idx++ )); do
    FEATURE_SOURCE_PATHS+=("$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d['feature_files'][$idx]['source_path'])")")
    FEATURE_NAMES+=("$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d['feature_files'][$idx]['feature_name'])")")
    FEATURE_SCENARIO_COUNTS+=("$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d['feature_files'][$idx].get('scenario_count',0))")")
done

# Parse page object files
PO_FILE_COUNT=$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(len(d.get('page_object_files',[])))")
PO_FILES=()
for (( idx=0; idx<PO_FILE_COUNT; idx++ )); do
    PO_FILES+=("$(python3 -c "import json; d=json.load(open('$WIZARD_OUTPUT')); print(d['page_object_files'][$idx])")")
done

if [[ "$FEATURES_MODE" != "existing" ]] && [[ ${#UI_PAGES[@]} -eq 0 ]]; then
    warn "No pages in wizard output. Adding default / page."
    UI_PAGES=("/")
    UI_FOCUS=("")
    UI_CRITERIA=("[]")
    UI_TEST_DATA=("")
fi

info "Testing surface: $TESTING_SURFACE"
info "Base URL: ${UI_BASE_URL:-(none)}"
info "Features mode: $FEATURES_MODE"
if [[ "$FEATURES_MODE" == "existing" ]]; then
    info "Found ${#FEATURE_SOURCE_PATHS[@]} existing .feature file(s)"
    info "Found ${#PO_FILES[@]} YAML page object file(s)"
    info "Will create ${#FEATURE_SOURCE_PATHS[@]} BDD task(s)"
else
    info "Pages: ${UI_PAGES[*]}"
    info "Will create ${#UI_PAGES[@]} BDD task(s)"
fi
info "Credentials: ${TEST_USER_EMAIL:-(none)}"
info "Env setup: ${ENV_SETUP_CMD:-(none)}"

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

# ─── Phase 4b: Test framework bootstrap ──────────────────────────────────────
echo ""
if [[ "$TESTING_SURFACE" == "python" ]]; then
    # --- Python / pytest-bdd bootstrap ---
    if [[ ! -f "$REPO_DIR/tests/conftest.py" ]]; then
        echo "  ${BOLD}pytest-bdd Setup${RESET}"
        echo ""
        read -r -p "  Initialize pytest-bdd scaffolding? [Y/n]: " SCAFFOLD_CHOICE
        SCAFFOLD_CHOICE="${SCAFFOLD_CHOICE:-Y}"

        if [[ "$SCAFFOLD_CHOICE" =~ ^[Yy]$ ]]; then
            info "Bootstrapping pytest-bdd..."

            # Create directory structure
            mkdir -p "$REPO_DIR/tests/features"
            mkdir -p "$REPO_DIR/tests/step_defs"
            info "Created tests/ directory structure"

            # Create conftest.py with pytest-bdd scenario discovery
            cat > "$REPO_DIR/tests/conftest.py" <<'CONFEOF'
"""pytest-bdd conftest -- auto-discovers .feature files and provides shared fixtures."""
import pytest


@pytest.fixture
def project_root(tmp_path):
    """Provide a temporary directory for test isolation."""
    return tmp_path
CONFEOF
            info "Created tests/conftest.py"

            # Create requirements.txt
            cat > "$REPO_DIR/requirements.txt" <<'REQEOF'
pytest>=7.0
pytest-bdd>=7.0
httpx>=0.27
REQEOF
            info "Created requirements.txt"

            # Install dependencies
            (cd "$REPO_DIR" && pip install -r requirements.txt --quiet 2>/dev/null) || true
            info "Installed pytest, pytest-bdd, httpx"

            # Add Python cache dirs to .gitignore
            GITIGNORE_ADDITIONS=""
            if ! grep -q '^__pycache__/' "$REPO_DIR/.gitignore" 2>/dev/null; then
                GITIGNORE_ADDITIONS+="\n# Python\n__pycache__/\n*.pyc"
            fi
            if ! grep -q '^\\.pytest_cache/' "$REPO_DIR/.gitignore" 2>/dev/null; then
                GITIGNORE_ADDITIONS+="\n.pytest_cache/"
            fi
            if [[ -n "$GITIGNORE_ADDITIONS" ]]; then
                echo -e "$GITIGNORE_ADDITIONS" >> "$REPO_DIR/.gitignore"
            fi

            # Commit scaffolding
            git -C "$REPO_DIR" add -A
            git -C "$REPO_DIR" commit --quiet -m "chore: add pytest-bdd test scaffolding"
            info "Committed scaffolding to git"
        else
            info "Skipping scaffolding -- you can set it up manually later"
        fi
    else
        info "tests/conftest.py already exists -- skipping scaffolding"
    fi
elif [[ ! -f "$REPO_DIR/playwright.config.ts" && ! -f "$REPO_DIR/cucumber.js" ]]; then
    # --- Browser / Playwright+Cucumber bootstrap ---
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

        # Create page inspection script
        cat > "$REPO_DIR/e2e/support/inspect.ts" <<'INSPEOF'
// Page inspector -- run with: npx ts-node e2e/support/inspect.ts <url>
// Outputs interactive elements to help Writer agent discover selectors
import { chromium } from '@playwright/test';

const url = process.argv[2];
if (!url) {
  console.error('Usage: npx ts-node e2e/support/inspect.ts <url>');
  process.exit(1);
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });

  const elements = await page.$$eval(
    '[data-testid], button, input, select, textarea, a, form, [role]',
    els => els.map(e => ({
      tag: e.tagName.toLowerCase(),
      testid: e.getAttribute('data-testid'),
      role: e.getAttribute('role'),
      type: e.getAttribute('type'),
      name: e.getAttribute('name'),
      placeholder: e.getAttribute('placeholder'),
      href: e.tagName === 'A' ? e.getAttribute('href') : undefined,
      text: e.textContent?.trim().slice(0, 60) || undefined,
    })).filter(el => el.testid || el.role || el.tag !== 'a' || el.href)
  );

  console.log(JSON.stringify(elements, null, 2));
  await browser.close();
})();
INSPEOF
        info "Created e2e/support/inspect.ts (page inspector)"

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

# ─── Phase 4c: Test data + env scripts (browser surface only) ────────────────
if [[ "$TESTING_SURFACE" == "browser" ]]; then
mkdir -p "$REPO_DIR/e2e/support"

# Create test-data.yaml (skip if exists)
if [[ ! -f "$REPO_DIR/e2e/support/test-data.yaml" ]]; then
    PAGE_YAML=""
    for i in "${!UI_PAGES[@]}"; do
        page="${UI_PAGES[$i]}"
        data="${UI_TEST_DATA[$i]:-}"
        PAGE_YAML+="  \"${page}\":\n    test_data: \"${data}\"\n"
    done

    cat > "$REPO_DIR/e2e/support/test-data.yaml" <<TDEOF
global:
  credentials:
    email: "${TEST_USER_EMAIL:-}"
    password: "${TEST_USER_PASSWORD:-}"
pages:
$(echo -e "$PAGE_YAML")
TDEOF
    info "Created e2e/support/test-data.yaml"
else
    info "e2e/support/test-data.yaml already exists -- skipped"
fi

# Create env-setup.sh (skip if exists)
if [[ ! -f "$REPO_DIR/e2e/support/env-setup.sh" ]]; then
    cat > "$REPO_DIR/e2e/support/env-setup.sh" <<'ENVEOF'
#!/bin/bash
set -e
echo "Running environment setup..."
# Customize: reset accounts, seed data, call APIs
echo "Environment setup complete."
ENVEOF
    chmod +x "$REPO_DIR/e2e/support/env-setup.sh"

    if [[ -n "${ENV_SETUP_CMD:-}" ]]; then
        sed -i '' "s|# Customize:.*|$ENV_SETUP_CMD|" "$REPO_DIR/e2e/support/env-setup.sh"
    fi
    info "Created e2e/support/env-setup.sh"
else
    info "e2e/support/env-setup.sh already exists -- skipped"
fi

# Create env-teardown.sh (skip if exists)
if [[ ! -f "$REPO_DIR/e2e/support/env-teardown.sh" ]]; then
    cat > "$REPO_DIR/e2e/support/env-teardown.sh" <<'ENVTDEOF'
#!/bin/bash
set -e
echo "Running environment teardown..."
# Customize: cleanup test artifacts
echo "Environment teardown complete."
ENVTDEOF
    chmod +x "$REPO_DIR/e2e/support/env-teardown.sh"
    if [[ -n "${ENV_TEARDOWN_CMD:-}" ]]; then
        sed -i '' "s|# Customize:.*|$ENV_TEARDOWN_CMD|" "$REPO_DIR/e2e/support/env-teardown.sh"
    fi
    info "Created e2e/support/env-teardown.sh"
else
    info "e2e/support/env-teardown.sh already exists -- skipped"
fi

# Commit test data files if any were created
if [[ -n "$(git -C "$REPO_DIR" status --porcelain e2e/support/ 2>/dev/null)" ]]; then
    git -C "$REPO_DIR" add e2e/support/test-data.yaml e2e/support/env-setup.sh e2e/support/env-teardown.sh 2>/dev/null || true
    git -C "$REPO_DIR" commit --quiet -m "chore: add test data and env setup files" 2>/dev/null || true
fi
fi  # end TESTING_SURFACE == browser

# ─── Phase 4d: Copy existing features + page objects ─────────────────────────
if [[ "$FEATURES_MODE" == "existing" ]]; then
    if [[ "$TESTING_SURFACE" == "python" ]]; then
        FEATURES_DEST="tests/features"
    else
        FEATURES_DEST="e2e/features"
    fi

    mkdir -p "$REPO_DIR/$FEATURES_DEST"
    if [[ "$TESTING_SURFACE" == "browser" ]]; then
        mkdir -p "$REPO_DIR/e2e/pages/yaml-refs"
    fi

    for src in "${FEATURE_SOURCE_PATHS[@]}"; do
        if [[ -f "$REPO_DIR/$src" ]]; then
            cp "$REPO_DIR/$src" "$REPO_DIR/$FEATURES_DEST/"
            info "Copied $src -> $FEATURES_DEST/"
        else
            warn "Feature file not found: $src"
        fi
    done

    if [[ "$TESTING_SURFACE" == "browser" ]]; then
        for po in "${PO_FILES[@]}"; do
            if [[ -f "$REPO_DIR/$po" ]]; then
                cp "$REPO_DIR/$po" "$REPO_DIR/e2e/pages/yaml-refs/"
                info "Copied $po -> e2e/pages/yaml-refs/"
            else
                warn "Page object file not found: $po"
            fi
        done
    fi

    # Commit copied files
    if [[ -n "$(git -C "$REPO_DIR" status --porcelain "$FEATURES_DEST" 2>/dev/null)" ]]; then
        git -C "$REPO_DIR" add "$FEATURES_DEST/" 2>/dev/null || true
        if [[ "$TESTING_SURFACE" == "browser" ]]; then
            git -C "$REPO_DIR" add e2e/pages/yaml-refs/ 2>/dev/null || true
        fi
        git -C "$REPO_DIR" commit --quiet -m "chore: copy existing feature files to $FEATURES_DEST/" 2>/dev/null || true
    fi
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
testing_surface: "$TESTING_SURFACE"

ui:
  base_url: "${UI_BASE_URL:-}"

test_credentials:
  email: "${TEST_USER_EMAIL:-}"
  password: "${TEST_USER_PASSWORD:-}"

env_setup:
  setup_script: e2e/support/env-setup.sh
  teardown_script: e2e/support/env-teardown.sh
  setup_command: "${ENV_SETUP_CMD:-}"
  teardown_command: "${ENV_TEARDOWN_CMD:-}"

features_mode: "$FEATURES_MODE"
$(if [[ "$TESTING_SURFACE" == "python" ]]; then echo "test_command: \"$TEST_COMMAND\""; fi)

agents:
  writer:
    working_dir: $WRITER_DIR
    pane: writer.0
  executor:
    working_dir: $EXECUTOR_DIR
    pane: writer.1
EOF
info "Created projects/$PROJECT_KEY/config.yaml"

# --- tasks.json ---
{
    echo "{"
    echo "  \"project\": \"$PROJECT_NAME\","
    echo "  \"features_mode\": \"$FEATURES_MODE\","
    echo "  \"tasks\": ["

    if [[ "$FEATURES_MODE" == "existing" ]]; then
        if [[ "$TESTING_SURFACE" == "python" ]]; then
            FEATURE_DEST_DIR="tests/features"
            STEP_FRAMEWORK="pytest-bdd"
        else
            FEATURE_DEST_DIR="e2e/features"
            STEP_FRAMEWORK="Cucumber"
        fi
        TASK_NUM=0
        LAST_IDX=$(( ${#FEATURE_SOURCE_PATHS[@]} - 1 ))
        for i in "${!FEATURE_SOURCE_PATHS[@]}"; do
            TASK_NUM=$((TASK_NUM + 1))
            SRC="${FEATURE_SOURCE_PATHS[$i]}"
            FNAME="${FEATURE_NAMES[$i]}"
            BASENAME=$(basename "$SRC")
            SCOUNT="${FEATURE_SCENARIO_COUNTS[$i]:-0}"
            COMMA=","
            [[ $((TASK_NUM - 1)) -eq $LAST_IDX ]] && COMMA=""
            cat <<TASKEOF
    {
      "id": "bdd-$TASK_NUM",
      "title": "Implement step defs for $FNAME",
      "description": "Implement $STEP_FRAMEWORK step definitions for existing feature file: $FEATURE_DEST_DIR/$BASENAME ($SCOUNT scenarios)",
      "feature_file": "$FEATURE_DEST_DIR/$BASENAME",
      "source_feature": "$SRC",
      "base_url": "${UI_BASE_URL:-}",
      "scenario_count": $SCOUNT,
      "status": "pending",
      "attempts": 0,
      "max_attempts": 5
    }$COMMA
TASKEOF
        done
    else
        TASK_NUM=0
        LAST_IDX=$(( ${#UI_PAGES[@]} - 1 ))
        for i in "${!UI_PAGES[@]}"; do
            page_path="${UI_PAGES[$i]}"
            TASK_NUM=$((TASK_NUM + 1))
            # Derive a clean title from the path
            PAGE_LABEL="${page_path#/}"
            PAGE_LABEL="${PAGE_LABEL:-home}"
            COMMA=","
            if [[ $((TASK_NUM - 1)) -eq $LAST_IDX ]]; then
                COMMA=""
            fi
            # Build test_focus from wizard input or PRD
            TASK_FOCUS="${UI_FOCUS[$i]:-}"
            # Build acceptance_criteria JSON array
            TASK_CRITERIA="[]"
            if [[ -n "${UI_CRITERIA[$i]:-}" ]]; then
                TASK_CRITERIA="${UI_CRITERIA[$i]}"
            fi
            cat <<TASKEOF
    {
      "id": "bdd-$TASK_NUM",
      "title": "E2E tests for $page_path",
      "description": "Write BDD feature files and step definitions for the $page_path page at $UI_BASE_URL$page_path",
      "page_url": "$page_path",
      "base_url": "$UI_BASE_URL",
      "test_focus": "$TASK_FOCUS",
      "test_data": "${UI_TEST_DATA[$i]:-}",
      "acceptance_criteria": $TASK_CRITERIA,
      "status": "pending",
      "attempts": 0,
      "max_attempts": 5
    }$COMMA
TASKEOF
        done
    fi

    echo "  ]"
    echo "}"
} > "$PROJECT_DIR/tasks.json"

if [[ "$FEATURES_MODE" == "existing" ]]; then
    info "Created projects/$PROJECT_KEY/tasks.json (${#FEATURE_SOURCE_PATHS[@]} BDD tasks, existing features)"
else
    info "Created projects/$PROJECT_KEY/tasks.json (${#UI_PAGES[@]} BDD tasks)"
fi

# --- Copy PRD if imported ---
if [[ -n "${PRD_PATH:-}" && -f "${PRD_PATH:-}" ]]; then
    cp "$PRD_PATH" "$PROJECT_DIR/prd.md"
    info "Copied PRD to projects/$PROJECT_KEY/prd.md"
fi

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
2. Inspect the target page: `npx ts-node e2e/support/inspect.ts <staging_url><page_path>`
3. Review the output to identify forms, buttons, data-testid attributes, and key elements
4. Create .feature files in `e2e/features/`
5. Create step definitions in `e2e/steps/`
6. Create or update Page Objects in `e2e/pages/`
7. Validate syntax: `npx cucumber-js --dry-run`
8. **Commit your work**: `git add . && git commit -m "feat: add e2e tests for <page>"`
9. Call `send_to_executor` with summary and files changed
10. Wait -- periodically call `check_messages` with role `"writer"` to get feedback

### Rules
- ALWAYS commit your code BEFORE calling send_to_executor
- Read e2e/support/test-data.yaml for test credentials and form values
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
3. Run environment setup if specified: `bash e2e/support/env-setup.sh`
4. Run: `npx cucumber-js --format progress --format json:reports/results.json`
5. Run environment teardown if specified: `bash e2e/support/env-teardown.sh`
6. Analyze results and capture any failure screenshots
7. Call `send_executor_results` with status, summary, and failure details

### Rules
- If e2e/support/env-setup.sh exists, ALWAYS run it before tests
- If setup script fails, report failure (do not run tests)
- Run teardown after tests regardless of pass/fail
- Read e2e/support/test-data.yaml for auth credentials if tests need login
- Do NOT modify feature files, step definitions, or Page Objects
- Always verify staging URL is reachable before running tests
- Capture screenshots on failure
- Provide actionable failure details so Writer can fix issues
- If tests pass, report success with scenario counts
EXECMCP

# --- Python surface MCP sections ---
IFS= read -r -d '' WRITER_MCP_SECTION_PYTHON <<'WRITERMCPPY' || true

---

## Communication Protocol (MCP-Based)

You are the **WRITER** agent in an automated BDD testing workflow with an AI orchestrator.

### MCP Tools Available
You have these tools from the `agent-bridge` MCP server:

- **`send_to_executor`** -- Notify Executor that step definitions are ready to run
  - `summary`: What you wrote/changed
  - `files_changed`: List of files created or modified
  - `feature_files`: List of .feature files to test
  - `dry_run_output`: Output from pytest --collect-only

- **`check_messages`** -- Check your mailbox for orchestrator tasks and Executor feedback
  - `role`: Always use `"writer"`

- **`list_workspace`** -- See all files in the shared workspace

- **`read_workspace_file`** -- Read a specific file from workspace

### Workflow
1. Receive a task via `check_messages` (role: `"writer"`)
2. Read the .feature file to understand all scenarios and steps
3. Create step definitions in `tests/step_defs/` using pytest-bdd decorators
4. Add any needed fixtures in `tests/conftest.py`
5. Validate: `pytest --collect-only`
6. **Commit your work**: `git add . && git commit -m "feat: add step defs for <feature>"`
7. Call `send_to_executor` with summary and files changed
8. Wait -- periodically call `check_messages` with role `"writer"` to get feedback

### Rules
- ALWAYS commit your code BEFORE calling send_to_executor
- Use subprocess.run() for CLI testing, direct imports for modules, httpx for APIs
- Write clear pytest-bdd step definitions matching the Gherkin steps exactly
- If a task is ambiguous, make reasonable assumptions and document them
WRITERMCPPY

IFS= read -r -d '' EXECUTOR_MCP_SECTION_PYTHON <<'EXECMCPPY' || true

---

## Communication Protocol (MCP-Based)

You are the **EXECUTOR** agent in an automated BDD testing workflow with an AI orchestrator.

### MCP Tools Available
You have these tools from the `agent-bridge` MCP server:

- **`send_executor_results`** -- Report test execution results
  - `status`: `"pass"` or `"fail"`
  - `summary`: Summary of test results
  - `scenarios_passed`: Number of scenarios that passed
  - `scenarios_failed`: Number of scenarios that failed
  - `failures`: Array of failure details (scenario, step, error, traceback)

- **`check_messages`** -- Check your mailbox for run requests
  - `role`: Always use `"executor"`

- **`list_workspace`** -- See all files in the shared workspace

- **`read_workspace_file`** -- Read a specific file from workspace

### Workflow
1. Receive a run request via `check_messages` (role: `"executor"`)
2. Step definitions are already in your worktree (merged by orchestrator)
3. Run environment setup if specified
4. Run: `pytest tests/ -v --tb=short`
5. Run environment teardown if specified
6. Analyze results
7. Call `send_executor_results` with status, summary, and failure details

### Rules
- Do NOT modify feature files, step definitions, or fixtures
- If tests fail due to test code bugs (wrong imports, bad assertions): report to Writer
- If tests fail due to application bugs: report as application issue
- If tests pass, report success with scenario counts
- Provide actionable failure details so Writer can fix issues
EXECMCPPY

# Extract role prompts from BDD prompt file
# Select Writer prompt based on testing_surface x features_mode
if [[ "$TESTING_SURFACE" == "python" ]]; then
    if [[ "$FEATURES_MODE" == "existing" ]]; then
        WRITER_ROLE_PROMPT=$(extract_prompt "$PROMPT_FILE" "writer_agent_python_existing/CLAUDE.md")
    else
        WRITER_ROLE_PROMPT=$(extract_prompt "$PROMPT_FILE" "writer_agent_python/CLAUDE.md")
    fi
    EXECUTOR_ROLE_PROMPT=$(extract_prompt "$PROMPT_FILE" "executor_agent_python/CLAUDE.md")
else
    if [[ "$FEATURES_MODE" == "existing" ]]; then
        WRITER_ROLE_PROMPT=$(extract_prompt "$PROMPT_FILE" "writer_agent_existing/CLAUDE.md")
    else
        WRITER_ROLE_PROMPT=$(extract_prompt "$PROMPT_FILE" "writer_agent/CLAUDE.md")
    fi
    EXECUTOR_ROLE_PROMPT=$(extract_prompt "$PROMPT_FILE" "executor_agent/CLAUDE.md")
fi

# Select MCP sections based on testing surface
if [[ "$TESTING_SURFACE" == "python" ]]; then
    ACTIVE_WRITER_MCP="$WRITER_MCP_SECTION_PYTHON"
    ACTIVE_EXECUTOR_MCP="$EXECUTOR_MCP_SECTION_PYTHON"
else
    ACTIVE_WRITER_MCP="$WRITER_MCP_SECTION"
    ACTIVE_EXECUTOR_MCP="$EXECUTOR_MCP_SECTION"
fi

# --- Writer CLAUDE.md ---
if [[ -f "$WRITER_DIR/CLAUDE.md" ]]; then
    if grep -q "agent-bridge" "$WRITER_DIR/CLAUDE.md" 2>/dev/null; then
        info "Writer CLAUDE.md already has MCP protocol -- skipped"
    else
        echo "$ACTIVE_WRITER_MCP" >> "$WRITER_DIR/CLAUDE.md"
        success "Appended MCP protocol to existing $WRITER_DIR/CLAUDE.md"
    fi
else
    {
        printf '%s\n\n' "# Writer Agent -- $PROJECT_NAME"
        printf '%s\n' "$WRITER_ROLE_PROMPT"
        printf '%s\n' "$ACTIVE_WRITER_MCP"
    } > "$WRITER_DIR/CLAUDE.md"
    info "Created $WRITER_DIR/CLAUDE.md"
fi

# --- Executor CLAUDE.md ---
if [[ -f "$EXECUTOR_DIR/CLAUDE.md" ]]; then
    if grep -q "agent-bridge" "$EXECUTOR_DIR/CLAUDE.md" 2>/dev/null; then
        info "Executor CLAUDE.md already has MCP protocol -- skipped"
    else
        echo "$ACTIVE_EXECUTOR_MCP" >> "$EXECUTOR_DIR/CLAUDE.md"
        success "Appended MCP protocol to existing $EXECUTOR_DIR/CLAUDE.md"
    fi
else
    {
        printf '%s\n\n' "# Executor Agent -- $PROJECT_NAME"
        printf '%s\n' "$EXECUTOR_ROLE_PROMPT"
        printf '%s\n' "$ACTIVE_EXECUTOR_MCP"
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
