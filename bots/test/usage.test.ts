import { join } from "node:path";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider, fauxText } from "@earendil-works/pi-ai/providers/faux";
import { describe, expect, it } from "vitest";
import { openSharedDatabase } from "../src/storage/database.ts";
import { BotRegistry, USAGE_TABLE } from "../src/storage/registry.ts";
import { TitleGenerator } from "../src/titles.ts";
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
});
