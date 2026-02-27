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

PROJECT=${1:?"Usage: $0 <project> [--nuke]"}
NUKE=false
if [[ "${2:-}" == "--nuke" ]]; then
    NUKE=true
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_CONFIG="$ROOT_DIR/projects/$PROJECT/config.yaml"

if [[ ! -f "$PROJECT_CONFIG" ]]; then
    error "Project '$PROJECT' not found at $PROJECT_CONFIG"
    exit 1
fi

# Read config
SESSION=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['tmux']['session_name'])")
REPO_DIR=$(python3 -c "import yaml; c=yaml.safe_load(open('$PROJECT_CONFIG')); print(c.get('repo_dir', ''))")
WRITER_DIR=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['agents']['writer']['working_dir'])")
EXECUTOR_DIR=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['agents']['executor']['working_dir'])")

echo ""
echo "  ${BOLD}Reset Project: $PROJECT${RESET}"
echo "  ========================"
echo ""

if $NUKE; then
    warn "NUKE mode: will delete the repo, project config, and shared dir entirely"
else
    info "Soft reset: stop session, reset branches, clear mailbox, reset tasks"
fi
echo ""

# ─── Step 1: Stop tmux session ───────────────────────────────────────────────
if tmux has-session -t "$SESSION" 2>/dev/null; then
    info "Killing tmux session '$SESSION'..."
    # Send /exit to agents first
    for pane in 0 1; do
        tmux send-keys -t "$SESSION:qa.$pane" "/exit" Enter 2>/dev/null || true
    done
    sleep 2
    tmux send-keys -t "$SESSION:qa.2" C-c 2>/dev/null || true
    sleep 1
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    success "Session killed"
else
    info "No tmux session running"
fi

# Kill orphaned orchestrator
pkill -fx "python3 orchestrator.py $PROJECT" 2>/dev/null || true

# ─── Step 2: Clear mailbox ───────────────────────────────────────────────────
MAILBOX_DIR="$ROOT_DIR/shared/$PROJECT/mailbox"
if [[ -d "$MAILBOX_DIR" ]]; then
    rm -f "$MAILBOX_DIR/to_writer/"*.json 2>/dev/null || true
    rm -f "$MAILBOX_DIR/to_executor/"*.json 2>/dev/null || true
    success "Mailboxes cleared"
fi

# ─── Step 3: Reset tasks ─────────────────────────────────────────────────────
TASKS_FILE="$ROOT_DIR/projects/$PROJECT/tasks.json"
if [[ -f "$TASKS_FILE" ]]; then
    python3 -c "
import json
with open('$TASKS_FILE') as f:
    data = json.load(f)
for t in data['tasks']:
    t['status'] = 'pending'
    t['attempts'] = 0
with open('$TASKS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"
    success "Tasks reset to pending"
fi

# ─── Step 4: Clear orchestrator log and change log ──────────────────────────
ORCH_LOG="$ROOT_DIR/orchestrator/orchestrator.log"
if [[ -f "$ORCH_LOG" ]]; then
    > "$ORCH_LOG"
    success "Orchestrator log cleared"
fi

CHANGES_CSV="$ROOT_DIR/projects/$PROJECT/changes.csv"
if [[ -f "$CHANGES_CSV" ]]; then
    rm -f "$CHANGES_CSV"
    success "Changes CSV cleared"
fi

if $NUKE; then
    # ─── NUKE: Delete everything ──────────────────────────────────────────────
    echo ""
    warn "Nuking project..."

    # Remove worktrees properly (git worktree remove)
    if [[ -n "$REPO_DIR" && -d "$REPO_DIR/.git" ]]; then
        for wt in writer executor; do
            wt_path="$REPO_DIR/.worktrees/$wt"
            if [[ -d "$wt_path" ]]; then
                git -C "$REPO_DIR" worktree remove "$wt_path" --force 2>/dev/null || true
            fi
        done
        success "Worktrees removed"
    fi

    # Delete repo
    if [[ -n "$REPO_DIR" && -d "$REPO_DIR" ]]; then
        rm -rf "$REPO_DIR"
        success "Deleted repo: $REPO_DIR"
    fi

    # Delete project config
    rm -rf "$ROOT_DIR/projects/$PROJECT"
    success "Deleted projects/$PROJECT/"

    # Delete shared dir
    rm -rf "$ROOT_DIR/shared/$PROJECT"
    success "Deleted shared/$PROJECT/"

    echo ""
    success "Project '$PROJECT' nuked completely."
    echo "  Run ${CYAN}bash scripts/new-project.sh${RESET} to start fresh."

else
    # ─── SOFT RESET: Reset git branches ───────────────────────────────────────
    if [[ -n "$REPO_DIR" && -d "$REPO_DIR/.git" ]]; then
        # Detect default branch (main, master, etc.)
        DEFAULT_BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")
        INITIAL_COMMIT=$(git -C "$REPO_DIR" rev-list --max-parents=0 "$DEFAULT_BRANCH" 2>/dev/null | head -1)

        if [[ -n "$INITIAL_COMMIT" ]]; then
            info "Resetting branches to initial commit ($INITIAL_COMMIT)..."

            # Reset default branch
            git -C "$REPO_DIR" checkout "$DEFAULT_BRANCH" --quiet 2>/dev/null || true
            git -C "$REPO_DIR" reset --hard "$INITIAL_COMMIT" --quiet
            success "$DEFAULT_BRANCH reset"

            # Reset worktree branches
            for wt_name in writer executor; do
                wt_path="$REPO_DIR/.worktrees/$wt_name"

                if [[ -d "$wt_path" ]]; then
                    current_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
                    git -C "$wt_path" reset --hard "$INITIAL_COMMIT" --quiet
                    success "$wt_name worktree reset ($current_branch)"

                    # Delete task branches for this prefix
                    branches=$(git -C "$REPO_DIR" branch --list "${wt_name}/*" 2>/dev/null | sed 's/^[ *]*//')
                    for branch in $branches; do
                        if [[ "$branch" != "$current_branch" ]]; then
                            git -C "$REPO_DIR" branch -D "$branch" --quiet 2>/dev/null || true
                        fi
                    done
                fi
            done

            # Clean up any remaining task branches
            for prefix in writer executor; do
                branches=$(git -C "$REPO_DIR" branch --list "${prefix}/*" 2>/dev/null | sed 's/^[ *]*//')
                for branch in $branches; do
                    git -C "$REPO_DIR" branch -D "$branch" --quiet 2>/dev/null || true
                done
            done
            success "Task branches cleaned"
        else
            warn "Could not find initial commit -- skip branch reset"
        fi
    else
        warn "No repo_dir or not a git repo -- skip branch reset"
    fi

    echo ""
    success "Project '$PROJECT' reset. Ready for a fresh run."
    echo "  Launch with: ${CYAN}bash scripts/start.sh $PROJECT --yolo${RESET}"
fi
echo ""
