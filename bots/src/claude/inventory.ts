// Inventory only: Claude Code sees the bot's tools through this stdio MCP server, but never runs
// them. Pi owns the agent loop; a tool call ends the SDK turn and Pi executes it (Woven Matter's
// `default-agent/src/claude-inventory.mjs`). Run as `node inventory.(ts|js) <tools.json>`.
import { readFile } from "node:fs/promises";
import { createInterface } from "node:readline";

const file = process.argv[2];
if (!file) throw new Error("usage: inventory <tools.json>");
const tools = JSON.parse(await readFile(file, "utf8"));
for await (const line of createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  if (message.id === undefined) continue;
  let result = {};
  if (message.method === "initialize") {
    result = {
      protocolVersion: "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "woven-bot-inventory", version: "1" },
    };
  } else if (message.method === "tools/list") {
    result = { tools };
  } else if (message.method === "tools/call") {
    result = {
      isError: true,
      content: [{ type: "text", text: "Only the Woven bots runtime executes this tool." }],
    };
  }
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, result })}\n`);
}
