#!/bin/bash
set -e

PROJECT=""
YOLO_FLAG=""

for arg in "$@"; do
    case "$arg" in
        --yolo) YOLO_FLAG="--dangerously-skip-permissions" ;;
        *) PROJECT="$arg" ;;
    esac
done

if [[ -z "$PROJECT" ]]; then
    echo "Usage: $0 <project> [--yolo]  (e.g., example)"
    echo "  --yolo      Skip Claude Code permission prompts"
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_CONFIG="$PROJECT_DIR/projects/$PROJECT/config.yaml"
MCP_CONFIG="$PROJECT_DIR/claude-code-mcp-config.json"

# Validate project exists
if [ ! -f "$PROJECT_CONFIG" ]; then
    echo "Error: Project '$PROJECT' not found at $PROJECT_CONFIG"
    echo "Available projects:"
    ls -1 "$PROJECT_DIR/projects/"
    exit 1
fi

# Read project config values via Python/YAML
SESSION=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['tmux']['session_name'])")
WRITER_DIR=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['agents']['writer']['working_dir'])")
EXECUTOR_DIR=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['agents']['executor']['working_dir'])")
PROJECT_NAME=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['project'])")
REPO_DIR=$(python3 -c "import yaml; c=yaml.safe_load(open('$PROJECT_CONFIG')); print(c.get('repo_dir', ''))")
BASE_URL=$(python3 -c "import yaml; c=yaml.safe_load(open('$PROJECT_CONFIG')); print(c.get('ui', {}).get('base_url', ''))")

# System prompts for agents
WRITER_PROMPT="You are the Writer agent. Your ONLY communication channel is the agent-bridge MCP server. Do NOT search for config files or explore the filesystem for messages. To get tasks: call the check_messages MCP tool with role 'writer'. To send feature files to Executor: call send_to_executor. IMPORTANT: Always git add and commit your code BEFORE calling send_to_executor. Start by calling check_messages now."

EXECUTOR_PROMPT="You are the Executor agent. Your ONLY communication channel is the agent-bridge MCP server. Do NOT search for config files or explore the filesystem for messages. To get tasks: call the check_messages MCP tool with role 'executor'. To send test results: call send_executor_results. Start by calling check_messages now."

echo "BDD E2E Orchestrator"
echo "================================"
echo "Project: $PROJECT ($PROJECT_NAME)"
echo ""

# --- Pre-flight checks ---
echo "Pre-flight checks..."

command -v tmux >/dev/null 2>&1 || { echo "tmux not found. Install: brew install tmux"; exit 1; }
echo "  tmux OK"

command -v claude >/dev/null 2>&1 || { echo "Claude Code not found. Install: npm install -g @anthropic-ai/claude-code"; exit 1; }
echo "  claude OK"

command -v ollama >/dev/null 2>&1 || { echo "Ollama not found. Install: brew install ollama"; exit 1; }
echo "  ollama OK"

command -v python3 >/dev/null 2>&1 || { echo "Python3 not found."; exit 1; }
echo "  python3 OK"

command -v git >/dev/null 2>&1 || { echo "git not found."; exit 1; }
echo "  git OK"

# Check Ollama is running (with timeout), auto-start if needed
if ! curl -sf --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "  ollama server not responding -- starting it..."
    if [[ -d "/Applications/Ollama.app" ]]; then
        open -a Ollama
    else
        ollama serve &>/dev/null &
    fi
    for i in $(seq 1 15); do
        sleep 2
        if curl -sf --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
            break
        fi
        echo "  waiting for ollama... (${i}/15)"
    done
    if ! curl -sf --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
        echo ""
        echo "Ollama failed to start after 30s. Run manually: ollama serve"
        exit 1
    fi
fi
echo "  ollama server OK"

# Check MCP config exists
if [ ! -f "$MCP_CONFIG" ]; then
    echo "MCP config not found at $MCP_CONFIG"
    echo "Run $PROJECT_DIR/scripts/setup.sh first"
    exit 1
fi
echo "  MCP config OK"

# Ensure MCP bridge dependencies are installed
if [ ! -d "$PROJECT_DIR/mcp-bridge/node_modules" ]; then
    echo "  Installing MCP bridge dependencies..."
    (cd "$PROJECT_DIR/mcp-bridge" && npm install --silent)
fi
echo "  MCP bridge deps OK"

# Check agent working dirs exist (worktrees)
for agent_label_dir in "Writer:$WRITER_DIR" "Executor:$EXECUTOR_DIR"; do
    label="${agent_label_dir%%:*}"
    dir="${agent_label_dir#*:}"
    if [ ! -d "$dir" ]; then
        echo "$label working dir not found: $dir"
        echo "Run new-project.sh to set up worktrees, or update $PROJECT_CONFIG"
        exit 1
    fi
    echo "  $label dir OK ($dir)"
done

# Check repo_dir is a git repo (if configured)
if [[ -n "$REPO_DIR" ]]; then
    if [ ! -d "$REPO_DIR/.git" ]; then
        echo "Warning: repo_dir ($REPO_DIR) is not a git repository"
    else
        echo "  Repo dir OK ($REPO_DIR)"
    fi
fi

# BDD pre-flight: verify e2e directory and staging URL
if [[ -n "$REPO_DIR" && -d "$REPO_DIR/e2e" ]]; then
    echo "  e2e/ directory OK"
else
    echo "  Warning: e2e/ directory not found in repo (will be created by Writer)"
fi

if [[ -n "$BASE_URL" ]]; then
    if curl -sf --max-time 5 -o /dev/null "$BASE_URL" 2>/dev/null; then
        echo "  Staging URL OK ($BASE_URL)"
    else
        echo "  Warning: Staging URL not reachable ($BASE_URL) -- tests may fail"
    fi
fi

echo ""

# --- Determine task ID for branch names ---
TASKS_FILE="$PROJECT_DIR/projects/$PROJECT/tasks.json"
TASK_ID=""
if [[ -f "$TASKS_FILE" ]]; then
    TASK_ID=$(python3 -c "
import json
with open('$TASKS_FILE') as f:
    data = json.load(f)
for t in data['tasks']:
    if t['status'] in ('pending', 'in_progress'):
        print(t['id'])
        break
" 2>/dev/null || true)
fi
TASK_ID="${TASK_ID:-bdd-1}"
echo "Task branch suffix: $TASK_ID"

# --- Create task branches in worktrees ---
if [[ -n "$REPO_DIR" && -d "$REPO_DIR/.git" ]]; then
    echo "Creating task branches..."

    # Writer worktree: writer/<task-id>
    if git -C "$WRITER_DIR" rev-parse --verify "writer/$TASK_ID" >/dev/null 2>&1; then
        git -C "$WRITER_DIR" checkout "writer/$TASK_ID" --quiet
        echo "  Writer: checked out existing writer/$TASK_ID"
    else
        git -C "$WRITER_DIR" checkout -b "writer/$TASK_ID" --quiet
        echo "  Writer: created writer/$TASK_ID"
    fi

    # Executor worktree: executor/<task-id>
    if git -C "$EXECUTOR_DIR" rev-parse --verify "executor/$TASK_ID" >/dev/null 2>&1; then
        git -C "$EXECUTOR_DIR" checkout "executor/$TASK_ID" --quiet
        echo "  Executor: checked out existing executor/$TASK_ID"
    else
        git -C "$EXECUTOR_DIR" checkout -b "executor/$TASK_ID" --quiet
        echo "  Executor: created executor/$TASK_ID"
    fi

    echo ""
fi

# --- Kill existing session ---
if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Existing '$SESSION' tmux session found."
    read -r -p "Kill it and start fresh? [y/N] " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        tmux kill-session -t "$SESSION"
        echo "  Killed existing session"
        sleep 1
    else
        echo "Aborting. Attach with: tmux attach -t $SESSION"
        exit 0
    fi
fi

# --- Generate per-project MCP config (bakes in ORCH_PROJECT for the bridge) ---
PROJECT_MCP_CONFIG="$PROJECT_DIR/shared/$PROJECT/mcp-config.json"
mkdir -p "$(dirname "$PROJECT_MCP_CONFIG")"
cat > "$PROJECT_MCP_CONFIG" <<MCPEOF
{
  "mcpServers": {
    "agent-bridge": {
      "command": "node",
      "args": ["$PROJECT_DIR/mcp-bridge/index.js"],
      "env": {
        "ORCH_PROJECT": "$PROJECT"
      }
    }
  }
}
MCPEOF
MCP_CONFIG="$PROJECT_MCP_CONFIG"
echo "  MCP config generated ($MCP_CONFIG)"

# --- Clear old mailbox messages ---
echo "Clearing old mailbox messages..."
MAILBOX_DIR="$PROJECT_DIR/shared/$PROJECT/mailbox"
mkdir -p "$MAILBOX_DIR/to_writer" "$MAILBOX_DIR/to_executor"
rm -f "$MAILBOX_DIR/to_writer/"*.json 2>/dev/null || true
rm -f "$MAILBOX_DIR/to_executor/"*.json 2>/dev/null || true
echo "  Mailboxes cleared ($MAILBOX_DIR)"

# --- Create tmux session ---
echo ""
echo "Creating tmux session '$SESSION'..."

# Layout (after tiled):
# +--------------------+--------------------+
# |  WRITER (pane 0)   | EXECUTOR (pane 1)  |
# +--------------------+--------------------+
# |   (empty, pane 2)  |    ORCH (pane 3)   |
# +--------------------+--------------------+

# Create separate windows first (deterministic pane order with join-pane)
tmux new-session -d -s "$SESSION" -n "writer" -c "$WRITER_DIR"
echo "  Window 'writer' created"

tmux new-window -t "$SESSION" -n "executor" -c "$EXECUTOR_DIR"
echo "  Window 'executor' created"

tmux new-window -t "$SESSION" -n "orch" -c "$PROJECT_DIR/orchestrator"
echo "  Window 'orch' created"

# --- Launch processes in their own windows before joining ---
echo ""
echo "Launching agents..."

# Start Writer agent
tmux send-keys -t "$SESSION:writer" "unset CLAUDECODE && ORCH_PROJECT=$PROJECT claude --mcp-config $MCP_CONFIG --system-prompt \"$WRITER_PROMPT\" $YOLO_FLAG" Enter
echo "  Writer agent started"

# Start Executor agent
tmux send-keys -t "$SESSION:executor" "unset CLAUDECODE && ORCH_PROJECT=$PROJECT claude --mcp-config $MCP_CONFIG --system-prompt \"$EXECUTOR_PROMPT\" $YOLO_FLAG" Enter
echo "  Executor agent started"

# Start orchestrator
tmux send-keys -t "$SESSION:orch" "python3 orchestrator.py $PROJECT" Enter
echo "  Orchestrator started (project: $PROJECT)"

# --- Merge into single window with 2x2 tiled layout ---
echo ""
echo "Merging into 2x2 layout..."
tmux join-pane -s "$SESSION:executor" -t "$SESSION:writer"
tmux join-pane -s "$SESSION:orch" -t "$SESSION:writer"
tmux select-layout -t "$SESSION:writer" tiled

# Pane indices after tiled: 0=writer(top-left), 1=executor(top-right), 2=orch(bottom-right)
# With 3 panes, tiled gives: top-left(0), top-right(1), bottom(2)
# We want orch bottom-right, so this works.
WRITER_PANE=0
EXECUTOR_PANE=1
ORCH_PANE=2

# --- Pane styling ---
echo ""
echo "Applying pane styling..."

# Enable pane border labels
tmux set-option -t "$SESSION" pane-border-status top
tmux set-option -t "$SESSION" pane-border-format " #{?pane_active,#[bold],#[dim]}#{pane_title} "

# Set pane titles
tmux select-pane -t "$SESSION:writer.$WRITER_PANE" -T "WRITER [$PROJECT]"
tmux select-pane -t "$SESSION:writer.$EXECUTOR_PANE" -T "EXECUTOR [$PROJECT]"
tmux select-pane -t "$SESSION:writer.$ORCH_PANE" -T "ORCH [$PROJECT]"

# Check if a composite background image exists
COMPOSITE_IMG="$HOME/.config/bdd-e2e-orchestrator/images/bdd_composite.png"
if [ -f "$COMPOSITE_IMG" ]; then
    USE_COMPOSITE=true
else
    USE_COMPOSITE=false
fi

# Always use transparent backgrounds
tmux select-pane -t "$SESSION:writer.$WRITER_PANE" -P 'bg=default'
tmux select-pane -t "$SESSION:writer.$EXECUTOR_PANE" -P 'bg=default'
tmux select-pane -t "$SESSION:writer.$ORCH_PANE" -P 'bg=default'
tmux set-option -t "$SESSION" window-style 'bg=default'
tmux set-option -t "$SESSION" window-active-style 'bg=default'
echo "  Transparent pane backgrounds"

# Border colors
tmux set-option -t "$SESSION" pane-border-style "fg=colour240"
tmux set-option -t "$SESSION" pane-active-border-style "fg=colour75,bold"

# Enable mouse mode
tmux set-option -t "$SESSION" mouse on
echo "  Pane styling applied"

# --- Initial nudge ---
echo ""
echo "Waiting for agents to initialize..."
sleep 5

# Nudge Writer to pick up first task
tmux send-keys -t "$SESSION:writer.$WRITER_PANE" -l "You have new messages. Use the check_messages MCP tool with role 'writer' to read and act on them."
sleep 0.2
tmux send-keys -t "$SESSION:writer.$WRITER_PANE" Enter
echo "  Nudged Writer to pick up first task"

# --- Attach ---
echo ""
echo "================================"
echo "BDD E2E Session '$SESSION' is running! (project: $PROJECT)"
echo ""
echo "Panes:"
echo "  0: WRITER    - Writer agent (top-left)"
echo "  1: EXECUTOR  - Executor agent (top-right)"
echo "  2: ORCH      - Orchestrator (bottom)"
echo ""
echo "Git branches:"
echo "  Writer:   writer/$TASK_ID"
echo "  Executor: executor/$TASK_ID"
echo ""
echo "Navigation:"
echo "  Ctrl-b q       - Show pane numbers"
echo "  Ctrl-b o       - Cycle to next pane"
echo "  Ctrl-b ;       - Toggle last active pane"
echo "  Ctrl-b d       - Detach (session keeps running)"
echo "  $PROJECT_DIR/scripts/stop.sh $PROJECT - Graceful shutdown"
echo "================================"
echo ""

# Select the orchestrator pane
tmux select-pane -t "$SESSION:writer.$ORCH_PANE"

# If composite image exists, switch iTerm2 to the BDD profile before attaching
if $USE_COMPOSITE; then
    printf '\033]1337;SetProfile=BDD\007'
    echo "  iTerm2 profile set to 'BDD' (composite background)"
fi

tmux attach -t "$SESSION"
