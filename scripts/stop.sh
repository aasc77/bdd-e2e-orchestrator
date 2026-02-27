#!/bin/bash

PROJECT=${1:?"Usage: $0 <project>  (e.g., example)"}

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_CONFIG="$PROJECT_DIR/projects/$PROJECT/config.yaml"

# Read session name from project config
if [ -f "$PROJECT_CONFIG" ]; then
    SESSION=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['tmux']['session_name'])")
    REPO_DIR=$(python3 -c "import yaml; c=yaml.safe_load(open('$PROJECT_CONFIG')); print(c.get('repo_dir', ''))" 2>/dev/null || true)
else
    echo "Warning: Project config not found at $PROJECT_CONFIG, using '$PROJECT' as session name"
    SESSION="$PROJECT"
    REPO_DIR=""
fi

echo "Stopping BDD E2E Orchestrator (project: $PROJECT)"
echo "============================"
echo ""

# Check if session exists
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "No '$SESSION' tmux session found."
    # Clean up any orphaned processes anyway
    pkill -fx "python3 orchestrator.py $PROJECT" 2>/dev/null && echo "Killed orphaned orchestrator process" || true
    exit 0
fi

# Step 1: Send /exit to Claude Code agents (panes in merged layout)
echo "Sending /exit to Writer agent..."
tmux send-keys -t "$SESSION:qa.0" "/exit" Enter 2>/dev/null || true

echo "Sending /exit to Executor agent..."
tmux send-keys -t "$SESSION:qa.1" "/exit" Enter 2>/dev/null || true

# Step 2: Wait for agents to exit gracefully
echo "Waiting 5s for agents to shut down..."
sleep 5

# Step 3: Stop orchestrator with Ctrl-C
echo "Stopping orchestrator..."
tmux send-keys -t "$SESSION:qa.2" C-c 2>/dev/null || true
sleep 2

# Step 4: Kill the tmux session
echo "Killing tmux session '$SESSION'..."
tmux kill-session -t "$SESSION" 2>/dev/null && echo "  Session killed" || echo "  Session already gone"

# Step 5: Clean up any orphaned processes
pkill -fx "python3 orchestrator.py $PROJECT" 2>/dev/null && echo "  Killed orphaned orchestrator" || true

# Step 6: Reset iTerm2 profile back to Default
printf '\033]1337;SetProfile=Default\007' 2>/dev/null || true

# Step 7: Optional branch cleanup
if [[ -n "$REPO_DIR" && -d "$REPO_DIR/.git" ]]; then
    echo ""
    read -r -p "Clean up task branches? [y/N] " cleanup_response
    if [[ "$cleanup_response" =~ ^[Yy]$ ]]; then
        echo "Cleaning up task branches..."
        for prefix in writer executor; do
            branches=$(git -C "$REPO_DIR" branch --list "${prefix}/*" 2>/dev/null | sed 's/^[ *]*//')
            for branch in $branches; do
                git -C "$REPO_DIR" branch -d "$branch" 2>/dev/null \
                    && echo "  Deleted $branch" \
                    || echo "  Skipped $branch (not fully merged)"
            done
        done
    else
        echo "Task branches preserved for history."
    fi
fi

echo ""
echo "Shutdown complete."
