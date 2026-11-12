import { spawn } from "node:child_process";
import { readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Api, Context, Message, Model, MutableModels } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { CLAUDE_SUBSCRIPTION_PROVIDER } from "../src/claude/provider.ts";
import { NATIVE_PREFIX } from "../src/host/credentials.ts";
import { ClaudeAgentRuntime, claudeCredentialEnv } from "../src/claude/runtime.ts";
import { CLAUDE_AGENT_API } from "../src/compaction/native.ts";
import { createBotModels } from "../src/models.ts";
import { FakeProviders, frameText, MemoryCredentials } from "./fake-providers.ts";
import { tempDir } from "./helpers.ts";

/** The Claude Agent SDK provider against a fake `query()`: no Claude Code process, no real token. */

const MODEL_ID = "claude-haiku-4-5";

describe("Claude Agent SDK provider", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let fake: FakeProviders;
  beforeEach(async () => {
    dir = await tempDir();
    fake = new FakeProviders();
  });
  afterEach(async () => {
    await dir.cleanup();
  });

  function models(key: string | null = "sk-ant-oat01-test-claude"): MutableModels {
    const credentials = new MemoryCredentials(
      key ? { [CLAUDE_SUBSCRIPTION_PROVIDER]: { type: "api_key", key } } : {},
    );
    return createBotModels(credentials, {
      claude: { directory: join(dir.path, "claude"), query: fake.claudeQuery },
    });
  }

  function model(all: MutableModels): Model<Api> {
    const found = all.getModel(CLAUDE_SUBSCRIPTION_PROVIDER, MODEL_ID);
    if (!found) throw new Error("no Claude Agent SDK model");
    return found as Model<Api>;
  }

  const user = (text: string): Message => ({ role: "user", content: text, timestamp: 1 });

  it("registers Anthropic's catalog on the Claude Agent SDK api", () => {
    const m = model(models());
    expect(m.api).toBe(CLAUDE_AGENT_API);
    expect(m.baseUrl).toBe("process://claude-agent-sdk");
  });

  it("runs one isolated Claude Code turn with the stored subscription token", async () => {
    const all = models();
    const events: string[] = [];
    const stream = all.stream(model(all), {
      systemPrompt: "You are Alpha.",
      messages: [
        user("first"),
        {
          role: "assistant",
          content: [{ type: "text", text: "claude: first" }],
          api: CLAUDE_AGENT_API,
          provider: CLAUDE_SUBSCRIPTION_PROVIDER,
          model: MODEL_ID,
          usage: {
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 0,
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
          },
          stopReason: "stop",
          timestamp: 2,
        },
        user("second"),
      ],
    });
    for await (const event of stream) events.push(event.type);
    const result = await stream.result();
    expect(result.stopReason).toBe("stop");
    expect(result.content).toEqual([{ type: "text", text: "claude: second" }]);
    expect(result.usage).toMatchObject({ input: 10, output: 5, totalTokens: 15 });
    expect(events).toEqual(["start", "text_start", "text_delta", "text_end", "done"]);

    const [request] = fake.requests;
    if (!request) throw new Error("no SDK query");
    const { env, options, frames } = request.body;
    expect(env.CLAUDE_CODE_OAUTH_TOKEN).toBe("sk-ant-oat01-test-claude");
    expect(env.ANTHROPIC_API_KEY).toBeUndefined();
    expect(env.CLAUDE_CONFIG_DIR).toBe(join(dir.path, "claude", "config"));
    expect(env.CLAUDE_CODE_MAX_RETRIES).toBe("0");
    expect(options).toMatchObject({
      model: MODEL_ID,
      cwd: join(dir.path, "claude", "workspace"),
      tools: [],
      skills: [],
      settingSources: [],
      strictMcpConfig: true,
      maxTurns: 1,
      permissionMode: "dontAsk",
      persistSession: false,
      includePartialMessages: true,
      systemPrompt: { type: "custom", prompt: "You are Alpha.", snapshot: false },
    });
    // History replays without model turns; only the last user frame queries.
    expect(
      frames.map((f: { type: string; shouldQuery?: boolean }) => [f.type, f.shouldQuery]),
    ).toEqual([
      ["user", false],
      ["assistant", undefined],
      ["user", undefined],
    ]);
    expect(
      frames.every(
        (f: { type: string; client_composed?: boolean }) =>
          f.type === "assistant" || f.client_composed,
      ),
    ).toBe(true);
    for (const path of ["", "config", "workspace"]) {
      expect((await stat(join(dir.path, "claude", path))).mode & 0o777).toBe(0o700);
    }
  });

  it("maps credentials: OAuth tokens to CLAUDE_CODE_OAUTH_TOKEN, keys to ANTHROPIC_API_KEY", () => {
    expect(claudeCredentialEnv("sk-ant-oat01-x")).toEqual({
      CLAUDE_CODE_OAUTH_TOKEN: "sk-ant-oat01-x",
    });
    expect(claudeCredentialEnv("sk-ant-api03-x")).toEqual({ ANTHROPIC_API_KEY: "sk-ant-api03-x" });
    const runtime = new ClaudeAgentRuntime({ directory: dir.path });
    const env = runtime.environment("/cfg", { key: "sk-ant-api03-x" }, {
      PATH: "/bin",
      ANTHROPIC_BASE_URL: "https://elsewhere.example",
      CLAUDE_CODE_OAUTH_TOKEN: "inherited",
      CLAUDECODE: "1",
    });
    expect(env.PATH).toBe("/bin");
    expect(env.ANTHROPIC_BASE_URL).toBeUndefined();
    expect(env.CLAUDE_CODE_OAUTH_TOKEN).toBeUndefined();
    expect(env.CLAUDECODE).toBeUndefined();
    expect(env.ANTHROPIC_API_KEY).toBe("sk-ant-api03-x");
    expect(env.CLAUDE_CONFIG_DIR).toBe("/cfg");
  });

  it("runs a native Claude subscription in the host's Claude directories without a token", async () => {
    const native = join(dir.path, "native-config");
    const all = models(
      `${NATIVE_PREFIX}${JSON.stringify({ configDir: native, secureStorageDir: "/secure" })}`,
    );
    const result = await all.stream(model(all), { messages: [user("hello")] }).result();
    expect(result.stopReason).toBe("stop");
    const env = (fake.requests.at(-1)?.body as { env: Record<string, string> }).env;
    expect(env.CLAUDE_CONFIG_DIR).toBe(native);
    expect(env.CLAUDE_SECURESTORAGE_CONFIG_DIR).toBe("/secure");
    expect(env.CLAUDE_CODE_OAUTH_TOKEN).toBeUndefined();
    expect(env.ANTHROPIC_API_KEY).toBeUndefined();
    expect(JSON.stringify(fake.requests)).not.toContain(NATIVE_PREFIX);
  });

  it("fails clearly without a stored credential", async () => {
    const all = models(null);
    const prior = process.env.CLAUDE_CODE_OAUTH_TOKEN;
    delete process.env.CLAUDE_CODE_OAUTH_TOKEN;
    try {
      const result = await all
        .stream(model(all), { messages: [user("hi")] })
        .result()
        .catch((error: Error) => ({ stopReason: "error", errorMessage: error.message }));
      expect(result.stopReason).toBe("error");
      expect(result.errorMessage).toMatch(/claude-subscription|Claude/);
      expect(fake.requests).toEqual([]);
    } finally {
      if (prior !== undefined) process.env.CLAUDE_CODE_OAUTH_TOKEN = prior;
    }
  });

  it("stops the Claude Code turn when Pi aborts the request", async () => {
    let sdkAbort: AbortController | undefined;
    let closed = false;
    const all = createBotModels(
      new MemoryCredentials({
        [CLAUDE_SUBSCRIPTION_PROVIDER]: { type: "api_key", key: "sk-ant-oat01-test-claude" },
      }),
      {
        claude: {
          directory: join(dir.path, "claude"),
          // A turn that never finishes on its own: it only ends when its abort controller fires.
          query: ({ options }) => {
            sdkAbort = options.abortController as AbortController;
            const signal = sdkAbort.signal;
            return {
              async *[Symbol.asyncIterator]() {
                yield {
                  type: "stream_event",
                  parent_tool_use_id: null,
                  event: { type: "message_start", message: { id: "msg_long" } },
                };
                await new Promise((resolve) =>
                  signal.addEventListener("abort", resolve, { once: true }),
                );
                throw new Error("Claude Code process aborted");
              },
              close: () => {
                closed = true;
              },
            };
          },
        },
      },
    );
    const controller = new AbortController();
    const stream = all.stream(model(all), { messages: [user("hi")] }, {
      signal: controller.signal,
    } as never);
    while (!sdkAbort) await new Promise((resolve) => setTimeout(resolve, 5));
    controller.abort();
    const result = await stream.result();
    expect(sdkAbort.signal.aborted).toBe(true);
    expect(closed).toBe(true);
    expect(result.stopReason).toBe("aborted");
  });

  const lookup = {
    name: "lookup",
    description: "Look something up.",
    parameters: Type.Object({ query: Type.String() }),
  };

  it("returns tool calls to Pi from the inventory-only MCP server; Claude Code never runs them", async () => {
    let inventory: unknown;
    fake.options = {
      claudeReply: () => [
        { type: "text", text: "Looking." },
        { type: "tool_use", id: "toolu_1", name: "mcp__pibot__lookup", input: { query: "x" } },
      ],
    };
    const all = models();
    const context: Context = { systemPrompt: "sys", messages: [user("find x")], tools: [lookup] };
    const original = fake.claudeQuery;
    const query: typeof original = (params) => {
      const server = (
        params.options.mcpServers as Record<string, { command: string; args: string[] }>
      ).pibot;
      inventory = readFile(server?.args[1] ?? "", "utf8").then(JSON.parse);
      return original(params);
    };
    const withSpy = createBotModels(
      new MemoryCredentials({
        [CLAUDE_SUBSCRIPTION_PROVIDER]: { type: "api_key", key: "sk-ant-oat01-t" },
      }),
      { claude: { directory: join(dir.path, "claude"), query } },
    );
    const result = await withSpy.stream(model(all), context).result();
    expect(result.stopReason).toBe("toolUse");
    expect(result.content).toEqual([
      { type: "text", text: "Looking." },
      { type: "toolCall", id: "toolu_1", name: "lookup", arguments: { query: "x" } },
    ]);
    expect(await inventory).toEqual([
      {
        name: "lookup",
        description: "Look something up.",
        inputSchema: expect.objectContaining({ type: "object" }),
      },
    ]);

    // The tool result goes back as a replayed tool_use / tool_result pair.
    const next = await withSpy
      .stream(model(all), {
        ...context,
        messages: [
          ...context.messages,
          result,
          {
            role: "toolResult",
            toolCallId: "toolu_1",
            toolName: "lookup",
            content: [{ type: "text", text: "found" }],
            isError: false,
            timestamp: 3,
          },
        ],
      })
      .result();
    expect(next.stopReason).toBe("toolUse");
    const frames = fake.requests.at(-1)?.body.frames;
    expect(frames[1].message.content).toContainEqual({
      type: "tool_use",
      id: "toolu_1",
      name: "mcp__pibot__lookup",
      input: { query: "x" },
    });
    expect(frames[2].message.content[0]).toMatchObject({
      type: "tool_result",
      tool_use_id: "toolu_1",
      is_error: false,
    });
  });

  it("rejects a tool outside the active inventory", async () => {
    fake.options = {
      claudeReply: () => [
        { type: "tool_use", id: "toolu_2", name: "Bash", input: { command: "ls" } },
      ],
    };
    const all = models();
    const result = await all
      .stream(model(all), { messages: [user("go")], tools: [lookup] })
      .result();
    expect(result.stopReason).toBe("error");
    expect(result.errorMessage).toMatch(/outside the active tool inventory/);
  });

  it("reports Claude Code's sign-in failure as not logged in, without /login", async () => {
    fake.options = {
      claudeError: { error: "authentication_failed", text: "Not logged in · Please run /login" },
    };
    const all = models();
    const result = (await all.stream(model(all), { messages: [user("hey")] }).result()) as {
      stopReason: string;
      errorMessage?: string;
      pibotIssue?: string;
    };
    expect(result.stopReason).toBe("error");
    expect(result.errorMessage).toBe("Not logged in to Claude.");
    expect(result.pibotIssue).toBe("signIn");
  });

  it("compacts with Claude Code's /compact and returns the PostCompact summary", async () => {
    const all = models();
    const result = (await all
      .stream(model(all), { messages: [user("alpha"), user("beta")] }, {
        pibotCompact: { instructions: "keep names" },
      } as object)
      .result()) as { stopReason: string; pibotCompaction?: { summary: string } };
    expect(result.stopReason).toBe("stop");
    expect(result.pibotCompaction?.summary).toMatch(/^claude-sdk summary/);
    const frames = fake.requests[0]?.body.frames;
    expect(frames[0].shouldQuery).toBe(false);
    expect(frameText(frames.at(-1))).toBe("/compact keep names");
  });
});

describe("Claude inventory MCP server", () => {
  it("lists the tools and refuses to run them", async () => {
    const dir = await tempDir();
    try {
      const file = join(dir.path, "tools.json");
      await writeFile(
        file,
        JSON.stringify([{ name: "lookup", description: "d", inputSchema: { type: "object" } }]),
      );
      const script = fileURLToPath(new URL("../src/claude/inventory.ts", import.meta.url));
      const child = spawn(process.execPath, [script, file], { stdio: ["pipe", "pipe", "inherit"] });
      const lines: string[] = [];
      let buffer = "";
      const done = new Promise<void>((resolve) => {
        child.stdout.on("data", (chunk: Buffer) => {
          buffer += chunk.toString("utf8");
          const parts = buffer.split("\n");
          buffer = parts.pop() ?? "";
          lines.push(...parts);
          if (lines.length >= 3) resolve();
        });
      });
      for (const [id, method] of [
        [1, "initialize"],
        [2, "tools/list"],
        [3, "tools/call"],
      ] as const) {
        child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params: {} })}\n`);
      }
      await done;
      child.kill();
      const [init, list, call] = lines.map((line) => JSON.parse(line));
      expect(init.result.capabilities).toEqual({ tools: {} });
      expect(list.result.tools).toEqual([
        { name: "lookup", description: "d", inputSchema: { type: "object" } },
      ]);
      expect(call.result.isError).toBe(true);
    } finally {
      await dir.cleanup();
    }
  });
});
