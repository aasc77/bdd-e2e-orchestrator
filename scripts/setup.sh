#!/bin/bash
set -e

echo "BDD E2E Orchestrator Setup"
echo "==========================="

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Check prerequisites
echo ""
echo "Checking prerequisites..."

command -v tmux >/dev/null 2>&1 || { echo "tmux not found. Install: brew install tmux"; exit 1; }
echo "  tmux OK"

command -v node >/dev/null 2>&1 || { echo "Node.js not found. Install: brew install node"; exit 1; }
echo "  Node.js $(node --version) OK"

command -v python3 >/dev/null 2>&1 || { echo "Python3 not found."; exit 1; }
echo "  Python3 $(python3 --version 2>&1) OK"

command -v claude >/dev/null 2>&1 || { echo "Claude Code not found. Install: npm install -g @anthropic-ai/claude-code"; exit 1; }
echo "  Claude Code OK"

command -v ollama >/dev/null 2>&1 || { echo "Ollama not found. Install: brew install ollama"; exit 1; }
echo "  Ollama OK"

# Pull orchestrator model
echo ""
echo "Pulling orchestrator LLM model..."
ollama pull qwen3:8b

# Install MCP bridge dependencies
echo ""
echo "Installing MCP bridge dependencies..."
npm install --prefix "$PROJECT_DIR/mcp-bridge"

# Install orchestrator dependencies
echo ""
echo "Installing orchestrator dependencies..."
pip install -r "$PROJECT_DIR/orchestrator/requirements.txt" --break-system-packages 2>/dev/null || pip install -r "$PROJECT_DIR/orchestrator/requirements.txt"

# Update MCP config with actual path
echo ""
echo "Configuring MCP bridge..."
MCP_CONFIG="$PROJECT_DIR/claude-code-mcp-config.json"
if grep -q "REPLACE_WITH_ABSOLUTE_PATH" "$MCP_CONFIG" 2>/dev/null; then
    sed -i '' "s|REPLACE_WITH_ABSOLUTE_PATH_TO_ORCHESTRATOR|$PROJECT_DIR|g" "$MCP_CONFIG"
    echo "  MCP config updated with absolute path"
fi

echo ""
echo "MCP Config:"
cat "$MCP_CONFIG"

# Test MCP bridge
echo ""
echo "Testing MCP bridge..."
node "$PROJECT_DIR/mcp-bridge/test.js"

echo ""
echo "Setup complete!"
echo ""

# Offer to run the project wizard
read -r -p "Create a project now? [Y/n]: " CREATE_PROJECT
CREATE_PROJECT="${CREATE_PROJECT:-Y}"

if [[ "$CREATE_PROJECT" =~ ^[Yy]$ ]]; then
    exec "$PROJECT_DIR/scripts/new-project.sh"
else
    echo ""
    echo "Next steps:"
    echo "  1. Create a project:"
    echo "     $PROJECT_DIR/scripts/new-project.sh"
    echo ""
    echo "  2. Customize tasks and agent instructions:"
    echo "     vi $PROJECT_DIR/projects/<name>/tasks.json"
    echo "     vi <your-repo>/.worktrees/writer/CLAUDE.md"
    echo "     vi <your-repo>/.worktrees/executor/CLAUDE.md"
    echo ""
    echo "  3. Launch:"
    echo "     $PROJECT_DIR/scripts/start.sh <name>"
fi
