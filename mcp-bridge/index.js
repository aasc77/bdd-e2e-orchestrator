import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
// Resolve per-project mailbox paths via ORCH_PROJECT env var
// Falls back to legacy shared/mailbox for backwards compatibility
const ORCH_PROJECT = process.env.ORCH_PROJECT;
if (ORCH_PROJECT && (ORCH_PROJECT.includes("..") || ORCH_PROJECT.includes("/"))) {
  console.error("Invalid ORCH_PROJECT value — must be a plain name, not a path");
  process.exit(1);
}
const MAILBOX_DIR = process.env.MAILBOX_DIR ||
  (ORCH_PROJECT
    ? path.resolve(__dirname, `../shared/${ORCH_PROJECT}/mailbox`)
    : path.resolve(__dirname, "../shared/mailbox"));
const WORKSPACE_DIR = process.env.WORKSPACE_DIR ||
  (ORCH_PROJECT
    ? path.resolve(__dirname, `../shared/${ORCH_PROJECT}/workspace`)
    : path.resolve(__dirname, "../shared/workspace"));

// Ensure directories exist
for (const dir of [
  `${MAILBOX_DIR}/to_writer`,
  `${MAILBOX_DIR}/to_executor`,
  WORKSPACE_DIR,
]) {
  fs.mkdirSync(dir, { recursive: true });
}

function createMessage(from, to, type, content) {
  const timestamp = new Date().toISOString();
  const id = `msg-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const message = {
    id,
    from,
    to,
    type,
    content,
    timestamp,
    read: false,
  };

  const targetDir = `${MAILBOX_DIR}/to_${to}`;
  const filePath = `${targetDir}/${id}.json`;
  fs.writeFileSync(filePath, JSON.stringify(message, null, 2));
  return message;
}

function getMessages(recipient, unreadOnly = true) {
  const dir = `${MAILBOX_DIR}/to_${recipient}`;
  if (!fs.existsSync(dir)) return [];

  const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json"));
  const messages = files.map((f) => {
    const content = JSON.parse(fs.readFileSync(`${dir}/${f}`, "utf-8"));
    return content;
  });

  if (unreadOnly) {
    return messages.filter((m) => !m.read);
  }
  return messages;
}

function markAsRead(recipient, messageId) {
  const dir = `${MAILBOX_DIR}/to_${recipient}`;
  const filePath = `${dir}/${messageId}.json`;
  if (fs.existsSync(filePath)) {
    const msg = JSON.parse(fs.readFileSync(filePath, "utf-8"));
    msg.read = true;
    fs.writeFileSync(filePath, JSON.stringify(msg, null, 2));
  }
}

function listWorkspaceFiles() {
  if (!fs.existsSync(WORKSPACE_DIR)) return [];
  const walk = (dir, prefix = "") => {
    let results = [];
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const relPath = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.name === "node_modules" || entry.name === ".git") continue;
      if (entry.isDirectory()) {
        results = results.concat(walk(`${dir}/${entry.name}`, relPath));
      } else {
        results.push(relPath);
      }
    }
    return results;
  };
  return walk(WORKSPACE_DIR);
}

// --- MCP Server ---

const server = new Server(
  { name: "agent-mcp-bridge", version: "2.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "send_to_executor",
      description:
        "Send feature files to the Executor agent for testing. Use after writing .feature files, step definitions, and Page Objects. Include what you wrote, files changed, and dry-run output. IMPORTANT: Commit your work with git before calling this.",
      inputSchema: {
        type: "object",
        properties: {
          summary: {
            type: "string",
            description: "What was written/changed",
          },
          files_changed: {
            type: "array",
            items: { type: "string" },
            description: "List of files that were created or modified",
          },
          feature_files: {
            type: "array",
            items: { type: "string" },
            description: "List of .feature files to test",
          },
          dry_run_output: {
            type: "string",
            description: "Output from npx cucumber-js --dry-run (syntax validation)",
          },
        },
        required: ["summary", "files_changed"],
      },
    },
    {
      name: "send_executor_results",
      description:
        "Send test execution results back to the Writer agent. Include pass/fail status, scenario counts, and failure details. IMPORTANT: This is for the Executor to report results after running tests.",
      inputSchema: {
        type: "object",
        properties: {
          status: {
            type: "string",
            enum: ["pass", "fail"],
            description: "Overall test result",
          },
          summary: {
            type: "string",
            description: "Summary of test execution results",
          },
          scenarios_passed: {
            type: "number",
            description: "Number of scenarios that passed",
          },
          scenarios_failed: {
            type: "number",
            description: "Number of scenarios that failed",
          },
          failures: {
            type: "array",
            items: {
              type: "object",
              properties: {
                scenario: { type: "string" },
                step: { type: "string" },
                error: { type: "string" },
                screenshot: { type: "string" },
              },
            },
            description: "Detailed failure information (empty if pass)",
          },
          screenshots: {
            type: "array",
            items: { type: "string" },
            description: "Paths to failure screenshots",
          },
        },
        required: ["status", "summary"],
      },
    },
    {
      name: "check_messages",
      description:
        "Check your mailbox for new messages from the other agent.",
      inputSchema: {
        type: "object",
        properties: {
          role: {
            type: "string",
            enum: ["writer", "executor"],
            description: "Your role (writer or executor)",
          },
        },
        required: ["role"],
      },
    },
    {
      name: "list_workspace",
      description:
        "List all files in the shared workspace directory where code and tests live.",
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "read_workspace_file",
      description: "Read a file from the shared workspace.",
      inputSchema: {
        type: "object",
        properties: {
          filepath: {
            type: "string",
            description: "Relative path within the workspace",
          },
        },
        required: ["filepath"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "send_to_executor": {
      const msg = createMessage("writer", "executor", "features_ready", args);
      return {
        content: [
          {
            type: "text",
            text: `Feature files sent to Executor (${msg.id}). Executor will run the tests.`,
          },
        ],
      };
    }

    case "send_executor_results": {
      const msg = createMessage("executor", "writer", "executor_results", args);
      return {
        content: [
          {
            type: "text",
            text: `Test results sent to Writer (${msg.id}). Status: ${args.status}`,
          },
        ],
      };
    }

    case "check_messages": {
      const messages = getMessages(args.role);
      if (messages.length === 0) {
        return {
          content: [
            { type: "text", text: "No new messages in your mailbox." },
          ],
        };
      }
      messages.forEach((m) => markAsRead(args.role, m.id));
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(messages, null, 2),
          },
        ],
      };
    }

    case "list_workspace": {
      const files = listWorkspaceFiles();
      return {
        content: [
          {
            type: "text",
            text:
              files.length > 0
                ? `Workspace files:\n${files.join("\n")}`
                : "Workspace is empty.",
          },
        ],
      };
    }

    case "read_workspace_file": {
      const fullPath = path.join(WORKSPACE_DIR, args.filepath);
      if (!fs.existsSync(fullPath)) {
        return {
          content: [
            { type: "text", text: `File not found: ${args.filepath}` },
          ],
        };
      }
      const content = fs.readFileSync(fullPath, "utf-8");
      return { content: [{ type: "text", text: content }] };
    }

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Agent MCP Bridge running on stdio");
}

main().catch(console.error);
