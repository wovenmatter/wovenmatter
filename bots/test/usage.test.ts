import { join } from "node:path";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider, fauxText } from "@earendil-works/pi-ai/providers/faux";
import { describe, expect, it } from "vitest";
import { openSharedDatabase } from "../src/storage/database.ts";
import { BotRegistry, USAGE_TABLE } from "../src/storage/registry.ts";
import { TitleGenerator } from "../src/titles.ts";
import type { Api, Model, Models } from "@earendil-works/pi-ai";
import { claudeAgentProvider } from "../src/claude/provider.ts";
import type { ClaudeSdkQuery } from "../src/claude/runtime.ts";
import { CLAUDE_AGENT_API, codexCompact, compactNative } from "../src/compaction/native.ts";
import { NATIVE_KEY } from "../src/host/credentials.ts";
import { providerUsage, replyUsage } from "../src/usage.ts";
import { FAUX_MODEL, tempDir } from "./helpers.ts";

describe("usage outside a conversation", () => {
  it("saves a title call's usage once, with its conversation, and nothing for a call that used nothing", async () => {
    const dir = await tempDir();
    const db = await openSharedDatabase(join(dir.path, "bots.sqlite"));
    try {
      const registry = new BotRegistry(db);
      await registry.createTables();
      const faux = fauxProvider();
      faux.setResponses([fauxAssistantMessage([fauxText("Moving day")])]);
      const models = createModels();
      models.setProvider(faux.provider);
      const titles = new TitleGenerator({ models, model: FAUX_MODEL, reasoning: "low" });
      const title = await titles.generate("Help me move house", undefined, (reply) => {
        void registry.recordUsage("b1", 3, "title", { ...replyUsage(reply), input: 12, output: 3 });
      });
      expect(title).toBe("Moving day");
      await registry.recordUsage("b1", 1, "memory", { provider: "p", model: "m", at: 1, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0 });
      const rows = await db.all<{ bot_id: string; conversation_id: number; purpose: string; provider: string; input: number }>(
        `SELECT bot_id, conversation_id, purpose, provider, input FROM ${USAGE_TABLE}`,
      );
      expect(rows).toEqual([{ bot_id: "b1", conversation_id: 3, purpose: "title", provider: "faux", input: 12 }]);
    } finally {
      await db.close();
      await dir.cleanup();
    }
  });

  it("reads a compaction endpoint's usage in each provider's shape", () => {
    expect(providerUsage({ input_tokens: 100, input_tokens_details: { cached_tokens: 40 }, output_tokens: 5 }, "openai", "g", 1)).toMatchObject({
      input: 60,
      cacheRead: 40,
      cacheWrite: 0,
      output: 5,
    });
    expect(
      providerUsage({ input_tokens: 10, cache_read_input_tokens: 70, cache_creation_input_tokens: 20, output_tokens: 3 }, "anthropic", "c", 1),
    ).toMatchObject({ input: 10, cacheRead: 70, cacheWrite: 20, output: 3 });
    expect(providerUsage({ input: 4, output: 2, cacheRead: 1, cacheWrite: 0, cost: { total: 0.5 } }, "p", "m", 1)).toMatchObject({
      input: 4,
      cost: 0.5,
    });
    expect(providerUsage(undefined, "p", "m", 1)).toBeUndefined();
  });

  it("reports a compaction call's usage before its answer is refused", async () => {
    const used: unknown[] = [];
    const models = {
      stream: () => ({ result: async () => ({ stopReason: "stop", usage: { input: 9, output: 2, cacheRead: 0, cacheWrite: 0 } }) }),
    } as unknown as Models;
    const model = { provider: "claude", id: "c", api: CLAUDE_AGENT_API } as unknown as Model<Api>;
    await expect(compactNative({ models, model, messages: [], onUsage: (usage) => used.push(usage) })).rejects.toThrow();
    expect(used).toEqual([{ input: 9, output: 2, cacheRead: 0, cacheWrite: 0 }]);
  });

  it("reports a Codex compaction's usage from its end, past a created response with none, before its item is refused", async () => {
    const used: unknown[] = [];
    const frames = [
      { type: "response.created", response: { id: "r", usage: null } },
      { type: "response.output_item.done", item: { type: "compaction", encrypted_content: "" } },
      { type: "response.completed", response: { id: "r", usage: { input_tokens: 50, output_tokens: 4 } } },
    ];
    const fetch = async () =>
      new Response(frames.map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join(""), {
        headers: { "content-type": "text/event-stream" },
      });
    const route = { provider: "openai-codex", modelId: "g", api: "openai-codex-responses", strategy: "codex", endpoint: "https://codex.invalid/responses" };
    const captured = { url: route.endpoint, headers: new Headers(), payload: { model: "g", input: [] } };
    const request = { models: {} as Models, model: {} as Model<Api>, messages: [], onUsage: (usage: unknown) => used.push(usage) };
    await expect(codexCompact(route as never, captured, request, fetch as never)).rejects.toThrow(/no content/);
    expect(used).toEqual([{ input_tokens: 50, output_tokens: 4 }]);
  });

  it("keeps a Claude reply's usage when a stop lands after its frame", async () => {
    const dir = await tempDir();
    try {
      const controller = new AbortController();
      const query: ClaudeSdkQuery = () =>
        (async function* () {
          yield {
            type: "assistant",
            parent_tool_use_id: null,
            message: { id: "msg_1", stop_reason: "end_turn", content: [{ type: "text", text: "Hi" }], usage: { input_tokens: 7, output_tokens: 2 } },
          };
          controller.abort();
        })();
      const { provider } = claudeAgentProvider({ directory: join(dir.path, "claude"), query });
      const model = { id: "opus", api: "claude-agent-sdk", provider: "claude-subscription" } as never;
      const reply = await provider
        .stream(model, { messages: [{ role: "user", content: "hi", timestamp: 0 }] } as never, { apiKey: NATIVE_KEY, signal: controller.signal } as never)
        .result();
      expect(reply.stopReason).toBe("aborted");
      expect(reply.usage).toMatchObject({ input: 7, output: 2 });
    } finally {
      await dir.cleanup();
    }
  });

  it("saves a call's usage once under its own identifier, trying again after a failed save, before the store closes", async () => {
    const dir = await tempDir();
    const db = await openSharedDatabase(join(dir.path, "bots.sqlite"));
    try {
      let failures = 1;
      const flaky = new Proxy(db, {
        get(target, key) {
          const value = Reflect.get(target, key, target);
          if (key !== "run") return typeof value === "function" ? value.bind(target) : value;
          return async (sql: string, ...values: unknown[]) => {
            if (sql.includes(USAGE_TABLE) && failures-- > 0) throw new Error("disk I/O error");
            return (value as (...args: unknown[]) => unknown).call(target, sql, ...values);
          };
        },
      });
      const registry = new BotRegistry(flaky);
      await registry.createTables();
      void registry.recordUsage("b1", 1, "memory", { provider: "p", model: "m", at: 1, input: 3, output: 1, cacheRead: 0, cacheWrite: 0, cost: 0 });
      await registry.usageSaved();
      const rows = await db.all<{ n: number; ids: number }>(`SELECT COUNT(*) AS n, COUNT(DISTINCT call_id) AS ids FROM ${USAGE_TABLE}`);
      expect(rows).toEqual([{ n: 1, ids: 1 }]);
    } finally {
      await db.close();
      await dir.cleanup();
    }
  });
});
