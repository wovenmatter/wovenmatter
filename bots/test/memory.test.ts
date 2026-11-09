import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import {
  type FauxResponseFactory,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
} from "@earendil-works/pi-ai/providers/faux";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createBotHarnessOptions } from "../src/agent.ts";
import { BotManager } from "../src/bots.ts";
import { isCronExpression, parseCron } from "../src/cron.ts";
import { ModelAvailability } from "../src/limits.ts";
import {
  editFacts,
  MAX_EDITED_FACT_CHARS,
  MAX_FACTS,
  type MemoryEdit,
  MemoryEditError,
  MemoryExtractor,
  memorySection,
  mergeFacts,
  parseFacts,
} from "../src/memory.ts";
import { ProfileStore } from "../src/profiles.ts";
import { openSharedDatabase } from "../src/storage/database.ts";
import { parseTestSettings, tempDir } from "./helpers.ts";

const ctx = BACKGROUND_CONTEXT;

describe("cron schedule", () => {
  it("matches minutes in the configured time zone", () => {
    const nightly = parseCron("0 3 * * *");
    expect(nightly.matches(Date.UTC(2026, 9, 30, 3, 0, 30), "UTC")).toBe(true);
    expect(nightly.matches(Date.UTC(2026, 9, 30, 3, 1), "UTC")).toBe(false);
    // 03:00 in New York (EDT, UTC-4) is 07:00 UTC.
    expect(nightly.matches(Date.UTC(2026, 9, 30, 7, 0), "America/New_York")).toBe(true);
    expect(nightly.matches(Date.UTC(2026, 9, 30, 3, 0), "America/New_York")).toBe(false);
  });

  it("supports steps, ranges, lists and either day field", () => {
    const every15 = parseCron("*/15 9-17 * * 1-5");
    // 2026-10-30 is a Friday.
    expect(every15.matches(Date.UTC(2026, 9, 30, 9, 45), "UTC")).toBe(true);
    expect(every15.matches(Date.UTC(2026, 9, 30, 9, 50), "UTC")).toBe(false);
    expect(every15.matches(Date.UTC(2026, 9, 31, 9, 45), "UTC")).toBe(false); // Saturday
    const sunday = parseCron("0 0 * * 7");
    expect(sunday.matches(Date.UTC(2026, 10, 1, 0, 0), "UTC")).toBe(true);
    // Day of month 1 or Monday.
    const either = parseCron("0 0 1 * 1");
    expect(either.matches(Date.UTC(2026, 10, 2, 0, 0), "UTC")).toBe(true); // Monday
    expect(either.matches(Date.UTC(2026, 10, 1, 0, 0), "UTC")).toBe(true); // the 1st
    expect(either.matches(Date.UTC(2026, 10, 3, 0, 0), "UTC")).toBe(false);
    expect(parseCron("5,35 */2 * 1,6 *").matches(Date.UTC(2026, 5, 3, 4, 35), "UTC")).toBe(true);
  });

  it("rejects malformed or out-of-range expressions", () => {
    for (const bad of [
      "daily",
      "0 3 * *",
      "60 3 * * *",
      "0 24 * * *",
      "0 3 0 * *",
      "5-1 * * * *",
    ]) {
      expect(isCronExpression(bad)).toBe(false);
    }
    expect(isCronExpression("0 3 * * *")).toBe(true);
    expect(() =>
      parseTestSettings({
        profiles: { d: { name: "D", main: "a/b" } },
        extraction: { schedule: "99 3 * * *" },
      }),
    ).toThrow(/extraction/);
  });

  it("defaults [extraction] to on: nightly at 03:00 UTC plus 30 idle minutes", () => {
    const config = parseTestSettings({ profiles: { d: { name: "D", main: "a/b" } } });
    expect(config.extraction).toEqual({
      enabled: true,
      schedule: "0 3 * * *",
      timezone: "UTC",
      idle_minutes: 30,
    });
  });
});

describe("facts", () => {
  it("parses bullet lines and ignores NONE", () => {
    expect(parseFacts("Here you go:\n- Likes tea\n* Lives in  Lisbon\n2. Has a cat\nNONE")).toEqual(
      ["Likes tea", "Lives in Lisbon", "Has a cat"],
    );
    expect(parseFacts("NONE")).toEqual([]);
    expect(parseFacts("- none")).toEqual([]);
  });

  it("dedupes against memory and caps its size", () => {
    expect(mergeFacts(["Likes tea"], ["likes TEA.", "Has a cat", "has a cat"])).toEqual({
      facts: ["Likes tea", "Has a cat"],
      added: 1,
    });
    const full = Array.from({ length: MAX_FACTS }, (_, n) => `fact ${n}`);
    const merged = mergeFacts(full, ["newest"]);
    expect(merged.facts).toHaveLength(MAX_FACTS);
    expect(merged.facts.at(-1)).toBe("newest");
    expect(merged.facts[0]).toBe("fact 1");
  });

  it("applies user edits: add, update in place, delete", () => {
    const facts = ["Likes tea", "Lives in Lisbon"];
    expect(editFacts(facts, { kind: "add", text: "  Has a\n cat  " })).toEqual([
      "Likes tea",
      "Lives in Lisbon",
      "Has a cat",
    ]);
    expect(
      editFacts(facts, { kind: "update", fact: "Likes tea", text: "Likes green tea" }),
    ).toEqual(["Likes green tea", "Lives in Lisbon"]);
    // Changing only case or punctuation of the same fact is fine.
    expect(editFacts(facts, { kind: "update", fact: "Likes tea", text: "likes tea." })).toEqual([
      "likes tea.",
      "Lives in Lisbon",
    ]);
    expect(editFacts(facts, { kind: "delete", fact: "Likes tea" })).toEqual(["Lives in Lisbon"]);
    expect(facts).toEqual(["Likes tea", "Lives in Lisbon"]);
  });

  it("refuses empty, too long, duplicate and unknown facts, and adding to a full memory", () => {
    const facts = ["Likes tea", "Lives in Lisbon"];
    const refused = (edit: MemoryEdit, message: RegExp) =>
      expect(() => editFacts(facts, edit)).toThrow(message);
    refused({ kind: "add", text: "   " }, /needs some text/);
    refused({ kind: "add", text: "..." }, /needs some text/);
    refused({ kind: "add", text: "x".repeat(MAX_EDITED_FACT_CHARS + 1) }, /at most/);
    refused({ kind: "add", text: "likes TEA!" }, /already in memory/);
    refused({ kind: "update", fact: "Likes tea", text: "Lives in Lisbon" }, /already in memory/);
    refused({ kind: "update", fact: "Gone", text: "New" }, /no longer in this bot's memory/);
    refused({ kind: "delete", fact: "Gone" }, /no longer in this bot's memory/);
    expect(() => editFacts(facts, { kind: "add", text: "x" })).not.toThrow(MemoryEditError);
    const full = Array.from({ length: MAX_FACTS }, (_, n) => `fact ${n}`);
    expect(() => editFacts(full, { kind: "add", text: "one more" })).toThrow(/memory is full/);
    expect(editFacts(full, { kind: "update", fact: "fact 0", text: "first" })[0]).toBe("first");
  });

  it("renders memory as a stable prompt section", () => {
    expect(memorySection([])).toBeUndefined();
    expect(memorySection(["Likes tea"])).toBe(
      "What you remember from earlier conversations with the user (durable facts and preferences):\n- Likes tea",
    );
  });
});

describe("MemoryExtractor", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let db: Awaited<ReturnType<typeof openSharedDatabase>>;
  let manager: BotManager;
  let extractor: MemoryExtractor | undefined;
  let now = Date.UTC(2026, 9, 30, 12, 0);
  const faux = fauxProvider({
    tokensPerSecond: 100000,
    models: [{ id: "faux-1" }, { id: "faux-2" }],
  });
  const models = createModels();
  models.setProvider(faux.provider);
  /** Extraction prompts by model, and the bots' system prompts. */
  const prompts: { model: string; text: string }[] = [];
  const systems: string[] = [];
  let facts = "- The user prefers tea\n- The user lives in Lisbon";
  const broken = new Set<string>();
  const respond: FauxResponseFactory = (context, _options, _state, model) => {
    const last = context.messages.at(-1);
    const text = typeof last?.content === "string" ? last.content : "";
    if (text.startsWith("You maintain the long-term memory")) {
      prompts.push({ model: model.id, text });
      if (broken.has(model.id)) {
        return fauxAssistantMessage([], { stopReason: "error", errorMessage: "usage limit" });
      }
      return fauxAssistantMessage([fauxText(facts)]);
    }
    systems.push(JSON.stringify(context));
    return fauxAssistantMessage([fauxText(`ok: ${text}`)]);
  };

  /**
   * `memory`: the profile's memory extraction model set as `memory_model = "faux/faux-2"`, as a
   * legacy pool `background = true` flag on faux-2, or not at all (the active main model).
   */
  const open = async (
    memory: "model" | "legacy" | "none",
    options: { fallbacks?: string; availability?: ModelAvailability } = {},
  ) => {
    const profiles = new ProfileStore(
      parseTestSettings({
        profiles: {
          default: {
            name: "Default",
            main: "faux/faux-1",
            ...(options.fallbacks ? { fallbacks: [options.fallbacks] } : {}),
            // The old pool background flag is now just the memory model.
            ...(memory !== "none" ? { memoryModel: "faux/faux-2" } : {}),
          },
        },
      }).modelProfiles,
    );
    manager = await BotManager.open({
      db,
      profiles,
      ...(options.availability ? { availability: options.availability } : {}),
      harnessOptions: (bot, self) =>
        createBotHarnessOptions({
          bot,
          models,
          profile: () => profiles.resolve(self.assignedProfile(bot.id)),
          memory: async () => memorySection((await self.registry.memory(bot.id)).facts),
        }),
    });
    return manager;
  };
  const say = async (botId: string, text: string, conversationId?: number) => {
    const { submission } = await (await manager.get(botId)).send(text, conversationId);
    await expect(submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
  };
  const extractorFor = (options: { schedule?: string; idleMs?: number } = {}) => {
    extractor = new MemoryExtractor({
      manager,
      models,
      idleMs: options.idleMs ?? 0,
      ...(options.schedule ? { schedule: options.schedule, timeZone: "UTC" } : {}),
      now: () => now,
    });
    return extractor;
  };

  beforeEach(async () => {
    dir = await tempDir();
    db = await openSharedDatabase(join(dir.path, "db.sqlite"));
    prompts.length = 0;
    systems.length = 0;
    broken.clear();
    facts = "- The user prefers tea\n- The user lives in Lisbon";
    now = Date.UTC(2026, 9, 30, 12, 0);
    faux.setResponses(Array.from({ length: 100 }, () => respond));
  });
  afterEach(async () => {
    await extractor?.close();
    extractor = undefined;
    await manager.close();
    await db.close();
    await dir.cleanup();
  });

  it("appends facts from new messages on the memory model; bots see them in their prompt", async () => {
    await open("model");
    const bot = await manager.create("Ada");
    await say(bot.id, "I always drink tea, and I moved to Lisbon");
    const memory = extractorFor();
    await expect(memory.extract(bot.id)).resolves.toBe(2);
    expect(prompts.map((prompt) => prompt.model)).toEqual(["faux-2"]);
    expect(prompts[0]?.text).toContain("user: I always drink tea, and I moved to Lisbon");
    expect(prompts[0]?.text).toContain("assistant: ok: I always drink tea");
    expect((await manager.registry.memory(bot.id)).facts).toEqual([
      "The user prefers tea",
      "The user lives in Lisbon",
    ]);

    // The bot's next turn has it in its prompt.
    expect(systems.at(-1)).not.toContain("The user prefers tea");
    await say(bot.id, "hello again");
    expect(systems.at(-1)).toContain("- The user prefers tea\\n- The user lives in Lisbon");
  });

  it("uses the checkpoint: nothing is re-sent, nothing runs without new messages", async () => {
    await open("model");
    const bot = await manager.create("Ada");
    await say(bot.id, "first message");
    const memory = extractorFor();
    await memory.extract(bot.id);
    const { checkpoint } = await manager.registry.memory(bot.id);
    expect(checkpoint).toBeGreaterThan(0);

    // No new messages: no request, no change.
    await expect(memory.extract(bot.id)).resolves.toBe(0);
    expect(prompts).toHaveLength(1);

    // A new message in a thread: only it is sent; known facts are not added twice.
    const main = await (await manager.get(bot.id)).main();
    const last = (await main.entries({ order: "descending" }, 1, undefined, ctx)).items[0];
    const thread = await (await manager.get(bot.id)).fork({ entryId: Number(last?.id) });
    await say(bot.id, "my cat is called Miso", thread.conversationId);
    facts = "- The user prefers tea.\n- The user has a cat called Miso";
    await expect(memory.extract(bot.id)).resolves.toBe(1);
    expect(prompts).toHaveLength(2);
    expect(prompts[1]?.text).toContain("user: my cat is called Miso");
    expect(prompts[1]?.text).not.toContain("first message");
    expect(prompts[1]?.text).toContain("Memory so far:\n- The user prefers tea");
    expect((await manager.registry.memory(bot.id)).facts).toEqual([
      "The user prefers tea",
      "The user lives in Lisbon",
      "The user has a cat called Miso",
    ]);
    expect((await manager.registry.memory(bot.id)).checkpoint).toBeGreaterThan(checkpoint);
  });

  it("puts the user's edits in the prompt the way extracted facts are", async () => {
    await open("model");
    const bot = await manager.create("Ada");
    await say(bot.id, "hello");
    expect(systems.at(-1)).not.toContain("What you remember");
    await manager.registry.updateMemory(bot.id, (memory) => ({
      facts: editFacts(memory.facts, { kind: "add", text: "The user is called Trey" }),
      checkpoint: memory.checkpoint,
    }));
    await say(bot.id, "hello again");
    expect(systems.at(-1)).toContain("What you remember");
    expect(systems.at(-1)).toContain("- The user is called Trey");
    await manager.registry.updateMemory(bot.id, (memory) => ({
      facts: editFacts(memory.facts, {
        kind: "update",
        fact: "The user is called Trey",
        text: "The user goes by T",
      }),
      checkpoint: memory.checkpoint,
    }));
    await say(bot.id, "and again");
    // A changed section is appended as a new system entry; the latest one has the edit only.
    const last = systems.at(-1) ?? "";
    const latest = last.slice(last.lastIndexOf('"memory":'));
    expect(latest).toContain("- The user goes by T");
    expect(latest).not.toContain("called Trey");
  });

  it("merges into the memory as it is when saving: edits made during an extraction stay", async () => {
    await open("model");
    const bot = await manager.create("Ada");
    await say(bot.id, "I drink tea in Lisbon");
    await manager.registry.updateMemory(bot.id, () => ({
      facts: ["The user likes jazz", "The user has a dog"],
      checkpoint: 0,
    }));
    // The user edits memory while the extraction model is answering.
    faux.setResponses([
      async (...args) => {
        await manager.registry.updateMemory(bot.id, (memory) => ({
          facts: editFacts(
            editFacts(memory.facts, { kind: "delete", fact: "The user has a dog" }),
            { kind: "add", text: "The user prefers tea" },
          ),
          checkpoint: memory.checkpoint,
        }));
        return respond(...args);
      },
    ]);
    const changed: string[] = [];
    extractor = new MemoryExtractor({
      manager,
      models,
      idleMs: 0,
      onChanged: (botId) => changed.push(botId),
    });
    await expect(extractor.extract(bot.id)).resolves.toBe(1);
    const memory = await manager.registry.memory(bot.id);
    // The deleted fact stays gone, the added one isn't doubled, the new one is appended.
    expect(memory.facts).toEqual([
      "The user likes jazz",
      "The user prefers tea",
      "The user lives in Lisbon",
    ]);
    expect(memory.checkpoint).toBeGreaterThan(0);
    expect(changed).toEqual([bot.id]);
  });

  it("falls back quietly to the main model; a total failure keeps the checkpoint", async () => {
    await open("model");
    const bot = await manager.create("Ada");
    await say(bot.id, "remember that I like jazz");
    broken.add("faux-2");
    const memory = extractorFor();
    await expect(memory.extract(bot.id)).resolves.toBe(2);
    expect(prompts.map((prompt) => prompt.model)).toEqual(["faux-2", "faux-1"]);

    await say(bot.id, "and blues");
    broken.add("faux-1");
    const before = await manager.registry.memory(bot.id);
    await expect(memory.extract(bot.id)).rejects.toThrow(/usage limit/);
    expect(await manager.registry.memory(bot.id)).toEqual(before);
  });

  it("reads a legacy pool background flag as the memory model", async () => {
    await open("legacy");
    const bot = await manager.create("Ada");
    await say(bot.id, "I drink tea");
    await expect(extractorFor().extract(bot.id)).resolves.toBe(2);
    expect(prompts.map((prompt) => prompt.model)).toEqual(["faux-2"]);
    expect(manager.memoryModels(bot.id)).toEqual(["faux/faux-2", "faux/faux-1"]);
  });

  it("keeps the memory model out of chat and delegation", async () => {
    await open("model");
    const bot = await manager.create("Ada");
    await say(bot.id, "hello");
    const system = systems.at(-1) ?? "";
    // Chat runs on the main model; the memory model is not offered for subagents.
    expect(system).toContain('\\"self\\" = faux/faux-1');
    expect(system).not.toContain("faux/faux-2");
    expect(manager.profileOf(bot.id)?.pool).toEqual([]);
  });

  it("uses the active main model by default, a fallback while main is limited", async () => {
    const availability = new ModelAvailability();
    try {
      await open("none", { fallbacks: "faux/faux-2", availability });
      const bot = await manager.create("Ada");
      await say(bot.id, "I drink tea");
      expect(manager.memoryModels(bot.id)).toEqual(["faux/faux-1"]);
      availability.mark("faux/faux-1", { kind: "weekly" });
      expect(manager.memoryModels(bot.id)).toEqual(["faux/faux-2"]);
      await expect(extractorFor().extract(bot.id)).resolves.toBe(2);
      expect(prompts.map((prompt) => prompt.model)).toEqual(["faux-2"]);
    } finally {
      availability.close();
    }
  });

  it("runs every bot with new messages when the schedule fires, one at a time", async () => {
    await open("none");
    const a = await manager.create("A");
    const b = await manager.create("B");
    const quiet = await manager.create("Quiet");
    await say(a.id, "hello from a");
    await say(b.id, "hello from b");
    const memory = extractorFor({ schedule: "0 3 * * *" });
    now = Date.UTC(2026, 9, 30, 2, 59);
    await memory.tick();
    await memory.idle();
    expect(prompts).toEqual([]);
    now = Date.UTC(2026, 9, 30, 3, 0, 10);
    await memory.tick();
    await memory.tick(); // the same minute fires once
    await memory.idle();
    // No memory model: the active main model extracts.
    expect(prompts.map((prompt) => prompt.model)).toEqual(["faux-1", "faux-1"]);
    expect((await manager.registry.memory(a.id)).facts).toHaveLength(2);
    expect((await manager.registry.memory(b.id)).facts).toHaveLength(2);
    expect((await manager.registry.memory(quiet.id)).facts).toEqual([]);
  });

  it("extracts a bot once it has been idle long enough after new messages", async () => {
    await open("model");
    const bot = await manager.create("Ada");
    const memory = extractorFor({ idleMs: 60_000 });
    await say(bot.id, "I work at Woven Matter");
    await memory.tick();
    now += 30_000;
    await memory.tick();
    await memory.idle();
    expect(prompts).toEqual([]);
    now += 31_000;
    await memory.tick();
    await memory.idle();
    expect(prompts).toHaveLength(1);
    // Nothing new since: later ticks do nothing.
    now += 120_000;
    await memory.tick();
    await memory.idle();
    expect(prompts).toHaveLength(1);
  });
});
