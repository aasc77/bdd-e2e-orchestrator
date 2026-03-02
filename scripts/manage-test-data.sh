#!/bin/bash
set -e

# ─── manage-test-data.sh ─────────────────────────────────────────────────────
# View and update test credentials and per-page test data for a BDD project.
#
# Usage:
#   manage-test-data.sh <project-key>            # View credentials
#   manage-test-data.sh <project-key> --set      # Update interactively
#
# Reads the project's config.yaml for repo_dir, then reads/writes
# e2e/support/test-data.yaml in that repo.
# ──────────────────────────────────────────────────────────────────────────────

# ─── Color helpers ───────────────────────────────────────────────────────────
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

# ─── Args ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${1:-}" ]]; then
    echo ""
    echo "  ${BOLD}Usage:${RESET} manage-test-data.sh <project-key> [--set]"
    echo ""
    echo "  Available projects:"
    for d in "$ROOT_DIR"/projects/*/; do
        [[ -d "$d" ]] && echo "    $(basename "$d")"
    done
    echo ""
    exit 1
fi

PROJECT_KEY="$1"
ACTION="${2:-view}"
PROJECT_DIR="$ROOT_DIR/projects/$PROJECT_KEY"

if [[ ! -d "$PROJECT_DIR" ]]; then
    error "Project '$PROJECT_KEY' not found at $PROJECT_DIR"
    exit 1
fi

# ─── Resolve repo dir from config ────────────────────────────────────────────
REPO_DIR=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_DIR/config.yaml')).get('repo_dir',''))")

if [[ -z "$REPO_DIR" ]]; then
    error "No repo_dir in $PROJECT_DIR/config.yaml"
    exit 1
fi

TEST_DATA_FILE="$REPO_DIR/e2e/support/test-data.yaml"

# ─── View mode ───────────────────────────────────────────────────────────────
if [[ "$ACTION" == "view" || "$ACTION" == "--view" ]]; then
    echo ""
    echo "  ${BOLD}Test Data: $PROJECT_KEY${RESET}"
    echo "  File: $TEST_DATA_FILE"
    echo ""

    if [[ ! -f "$TEST_DATA_FILE" ]]; then
        warn "No test-data.yaml found. Run with --set to create one."
        exit 0
    fi

    # Show credentials (mask password)
    EMAIL=$(python3 -c "import yaml; d=yaml.safe_load(open('$TEST_DATA_FILE')); print(d.get('global',{}).get('credentials',{}).get('email','(not set)'))")
    PASSWORD=$(python3 -c "import yaml; d=yaml.safe_load(open('$TEST_DATA_FILE')); p=d.get('global',{}).get('credentials',{}).get('password',''); print('****' if p else '(not set)')")

    echo "  ${BOLD}Credentials:${RESET}"
    echo "    Email:    $EMAIL"
    echo "    Password: $PASSWORD"
    echo ""

    # Show per-page data
    PAGE_COUNT=$(python3 -c "import yaml; d=yaml.safe_load(open('$TEST_DATA_FILE')); print(len(d.get('pages',{})))")
    if [[ "$PAGE_COUNT" -gt 0 ]]; then
        echo "  ${BOLD}Per-page test data:${RESET}"
        python3 -c "
import yaml
d = yaml.safe_load(open('$TEST_DATA_FILE'))
for page, data in d.get('pages', {}).items():
    td = data.get('test_data', '(none)')
    print(f'    {page}: {td}')
"
    else
        echo "  ${DIM}No per-page test data${RESET}"
    fi
    echo ""
    exit 0
fi

# ─── Set mode ────────────────────────────────────────────────────────────────
if [[ "$ACTION" == "--set" ]]; then
    echo ""
    echo "  ${BOLD}Update Test Data: $PROJECT_KEY${RESET}"
    echo ""

    # Load existing values
    EXISTING_EMAIL=""
    EXISTING_PASSWORD=""
    if [[ -f "$TEST_DATA_FILE" ]]; then
        EXISTING_EMAIL=$(python3 -c "import yaml; d=yaml.safe_load(open('$TEST_DATA_FILE')); print(d.get('global',{}).get('credentials',{}).get('email',''))")
        EXISTING_PASSWORD=$(python3 -c "import yaml; d=yaml.safe_load(open('$TEST_DATA_FILE')); print(d.get('global',{}).get('credentials',{}).get('password',''))")
    fi

    # Prompt for email
    if [[ -n "$EXISTING_EMAIL" ]]; then
        read -r -p "  Email [$EXISTING_EMAIL]: " NEW_EMAIL
        NEW_EMAIL="${NEW_EMAIL:-$EXISTING_EMAIL}"
    else
        read -r -p "  Email: " NEW_EMAIL
    fi

    # Prompt for password (masked)
    if [[ -n "$EXISTING_PASSWORD" ]]; then
        read -r -s -p "  Password [****]: " NEW_PASSWORD
        echo ""
        NEW_PASSWORD="${NEW_PASSWORD:-$EXISTING_PASSWORD}"
    else
        read -r -s -p "  Password: " NEW_PASSWORD
        echo ""
    fi

    # Preserve existing pages section
    PAGES_YAML=""
    if [[ -f "$TEST_DATA_FILE" ]]; then
        PAGES_YAML=$(python3 -c "
import yaml
d = yaml.safe_load(open('$TEST_DATA_FILE'))
pages = d.get('pages', {})
if pages:
    print(yaml.dump({'pages': pages}, default_flow_style=False).rstrip())
else:
    print('pages: {}')
")
    else
        PAGES_YAML="pages: {}"
    fi

    # Write updated file
    mkdir -p "$(dirname "$TEST_DATA_FILE")"
    cat > "$TEST_DATA_FILE" <<TDEOF
global:
  credentials:
    email: "${NEW_EMAIL}"
    password: "${NEW_PASSWORD}"
${PAGES_YAML}
TDEOF

    success "Updated $TEST_DATA_FILE"
    echo ""
    exit 0
fi

error "Unknown action: $ACTION"
echo "  Use --set to update, or no flag to view."
exit 1
