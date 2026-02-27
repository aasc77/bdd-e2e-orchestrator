# MCP Bridge Setup Guide

## What is the MCP Bridge?

The MCP bridge is a small Node.js server that gives both Claude Code agents
shared tools for communication:

- `check_messages` -- Check mailbox for new messages (role: "writer" or "executor")
- `send_to_executor` -- Writer sends feature files to Executor for testing
- `send_executor_results` -- Executor reports test results back
- `list_workspace` / `read_workspace_file` -- Shared workspace access

It uses a file-based mailbox system -- messages are JSON files written to
`shared/<project>/mailbox/to_writer/` and `shared/<project>/mailbox/to_executor/`.

## Adding MCP to Claude Code

### Option 1: CLI (Recommended)
```bash
claude mcp add agent-bridge node /path/to/my-bdd/mcp-bridge/index.js
```

### Option 2: Config File
Add to `~/.claude/claude_code_config.json`:
```json
{
  "mcpServers": {
    "agent-bridge": {
      "command": "node",
      "args": ["/absolute/path/to/my-bdd/mcp-bridge/index.js"]
    }
  }
}
```

### Option 3: Per-session flag
```bash
claude --mcp-config /path/to/my-bdd/claude-code-mcp-config.json
```

## Verifying It Works

1. Start Claude Code with the MCP config
2. Ask Claude: "What MCP tools do you have?"
3. You should see: check_messages, send_to_executor, send_executor_results, list_workspace, read_workspace_file

## Troubleshooting

- **"No MCP tools found"**: Check the path in your config is absolute and correct
- **"Cannot find module"**: Run `npm install` in the mcp-bridge/ directory
- **Messages not appearing**: Check permissions on shared/<project>/mailbox/ directories
