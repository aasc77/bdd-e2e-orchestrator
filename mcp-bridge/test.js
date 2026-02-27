// Quick test to verify MCP bridge file operations work
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ORCH_PROJECT = process.env.ORCH_PROJECT;
const MAILBOX_DIR = ORCH_PROJECT
  ? path.resolve(__dirname, `../shared/${ORCH_PROJECT}/mailbox`)
  : path.resolve(__dirname, "../shared/mailbox");

// Test creating a message
const testMsg = {
  id: "test-msg-001",
  from: "writer",
  to: "executor",
  type: "features_ready",
  content: {
    summary: "Test message",
    files_changed: ["e2e/features/test.feature"],
    feature_files: ["e2e/features/test.feature"],
  },
  timestamp: new Date().toISOString(),
  read: false,
};

const dir = `${MAILBOX_DIR}/to_executor`;
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(`${dir}/${testMsg.id}.json`, JSON.stringify(testMsg, null, 2));
console.log("  Created test message in to_executor/");

// Read it back
const files = fs.readdirSync(dir);
console.log(`  Found ${files.length} message(s) in to_executor/`);

// Clean up
fs.unlinkSync(`${dir}/${testMsg.id}.json`);
console.log("  Cleaned up test message");
console.log("\n  MCP Bridge file operations working!");
