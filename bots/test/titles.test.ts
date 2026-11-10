// Thread titles, the Woven Matter way (CodexConversationTitleGenerator.swift). No real model
// keys: the title model is a faux provider registered as openai-codex/gpt-6-luna.
import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider, fauxText } from "@earendil-works/pi-ai/providers/faux";
import { describe, expect, it } from "vitest";
import { createBotHarnessOptions } from "../src/agent.ts";
import { type Bot, BotManager } from "../src/bots.ts";
import { ProfileStore } from "../src/profiles.ts";
import { openSharedDatabase } from "../src/storage/database.ts";
import {
  sanitizeTitle,
  TITLE_INSTRUCTIONS,
  TitleError,
  TitleGenerator,
  titlePrompt,
} from "../src/titles.ts";
import { echoModels, openTestManager, parseTestSettings, tempDir } from "./helpers.ts";

type Seen = { prompt: string; reasoning: unknown };

function titleModels(reply: (prompt: string) => string = () => '{"title":"Fixing the build"}') {
  const faux = fauxProvider({
    provider: "openai-codex",
    models: [{ id: "gpt-6-luna", reasoning: true }],
    tokensPerSecond: 100000,
  });
  const seen: Seen[] = [];
  faux.setResponses(
    Array.from({ length: 20 }, () => (context, options) => {
      const message = context.messages.at(-1);
      const prompt =
        typeof message?.content === "string"
          ? message.content
          : (message?.content ?? []).map((block) => ("text" in block ? block.text : "")).join("");
      seen.push({ prompt, reasoning: options?.reasoning });
      return fauxAssistantMessage([fauxText(reply(prompt))]);
    }),
  );
  const models = createModels();
  models.setProvider(faux.provider);
  return { models, seen };
}

const LUNA = { provider: "openai-codex", modelId: "gpt-6-luna" } as const;

describe("title sanitizer (Woven's sanitize)", () => {
  it.each([
    ['{"title": "Plan the trip"}', "Plan the trip"],
    ['Sure! {"title":"Quarterly numbers"} hope that helps', "Quarterly numbers"],
    ['"Debugging the parser."', "Debugging the parser"],
    ["  First line\nsecond line", "First line"],
    ["`Weekend   plans`", "Weekend plans"],
    ["", ""],
  ])("%j -> %j", (raw, title) => {
    expect(sanitizeTitle(raw)).toBe(title);
  });

  it("caps titles at 50 characters with an ellipsis", () => {
    const title = sanitizeTitle("word ".repeat(30));
    expect(title.length).toBeLessThanOrEqual(48);
    expect(title.endsWith("…")).toBe(true);
  });
});

describe("TitleGenerator", () => {
  it("defaults to openai-codex/gpt-6-luna at high reasoning", () => {
    const config = parseTestSettings({ profiles: { default: { name: "D", main: "a/b" } } });
    expect(config.roles.titles).toEqual(LUNA);
    expect(config.titles.reasoning).toBe("high");
  });

  it("sends Woven's prompt with the configured reasoning level", async () => {
    const { models, seen } = titleModels();
    const generator = new TitleGenerator({ models, model: LUNA, reasoning: "high" });
    await expect(generator.generate("  why does the build fail?  ")).resolves.toBe(
      "Fixing the build",
    );
    expect(seen).toEqual([{ prompt: titlePrompt("why does the build fail?"), reasoning: "high" }]);
    expect(seen[0]?.prompt.startsWith(TITLE_INSTRUCTIONS)).toBe(true);
    expect(seen[0]?.prompt.endsWith("First message:\nwhy does the build fail?")).toBe(true);
  });

  it("fails on an unknown model or an empty title", async () => {
    const { models } = titleModels(() => '""');
    await expect(
      new TitleGenerator({
        models,
        model: { provider: "x", modelId: "y" },
        reasoning: "high",
      }).generate("hi"),
    ).rejects.toBeInstanceOf(TitleError);
    await expect(
      new TitleGenerator({ models, model: LUNA, reasoning: "high" }).generate("hi"),
    ).rejects.toBeInstanceOf(TitleError);
  });
});

describe("thread titles", () => {
  it("titles a thread once from its first message; main is never titled; search finds it", async () => {
    const dir = await tempDir();
    const { models, seen } = titleModels((prompt) =>
      JSON.stringify({ title: prompt.includes("budget") ? "Budget review" : "Something else" }),
    );
    const reports: unknown[] = [];
    const changed: string[] = [];
    const harness = await openTestManager(join(dir.path, "db.sqlite"), {
      titles: new TitleGenerator({ models, model: LUNA, reasoning: "high" }),
      onReport: (error) => reports.push(error),
      onThreadsChanged: (botId) => changed.push(botId),
    });
    try {
      const bot = await harness.manager.get((await harness.manager.create("Ada")).id);
      await say(bot, "hello main");
      await harness.manager.titles?.idle();
      expect(seen).toEqual([]); // the main channel has no title

      const thread = await bot.fork({ entryId: await lastEntryId(bot) });
      expect(thread.title).toBe("");

      await say(bot, "let's go over the budget", thread.conversationId);
      await say(bot, "and the second message", thread.conversationId);
      await harness.manager.titles?.idle();
      await say(bot, "a third one", thread.conversationId);
      await harness.manager.titles?.idle();

      expect(seen.map((item) => item.prompt)).toEqual([titlePrompt("let's go over the budget")]);
      const [listed] = await bot.threads();
      expect(listed?.title).toBe("Budget review");
      // One live push for the one title written.
      expect(changed).toEqual([bot.id]);
      expect((await bot.threads("budget")).map((item) => item.conversationId)).toEqual([
        thread.conversationId,
      ]);
      expect(await bot.threads("REVIEW budget")).toHaveLength(1);
      expect(await bot.threads("groceries")).toEqual([]);
      expect(await bot.threads("%")).toEqual([]);
      // Compare-and-set: a title is never overwritten.
      expect(
        await harness.manager.registry.setThreadTitleIfUntitled(bot.id, thread.conversationId, "X"),
      ).toBe(false);
      expect(reports).toEqual([]);
    } finally {
      await harness.close();
      await dir.cleanup();
    }
  });

  it("keeps the thread untitled and reports when the title model fails", async () => {
    const dir = await tempDir();
    const { models } = titleModels(() => "   ");
    const reports: unknown[] = [];
    const changed: string[] = [];
    const harness = await openTestManager(join(dir.path, "db.sqlite"), {
      titles: new TitleGenerator({ models, model: LUNA, reasoning: "high" }),
      onReport: (error) => reports.push(error),
      onThreadsChanged: (botId) => changed.push(botId),
    });
    try {
      const bot = await harness.manager.get((await harness.manager.create("Ada")).id);
      await say(bot, "hello main");
      const thread = await bot.fork({ entryId: await lastEntryId(bot) });
      await say(bot, "first", thread.conversationId);
      await harness.manager.titles?.idle();
      expect((await bot.threads())[0]?.title).toBe("");
      expect(reports).toEqual([expect.any(TitleError)]);
      expect(changed).toEqual([]);
    } finally {
      await harness.close();
      await dir.cleanup();
    }
  });
});

describe("title model selection", () => {
  const POOL = { provider: "openai-codex", modelId: "gpt-6-pool" } as const;

  /** Luna and a pool model; models in `broken` fail. Records which model answered. */
  function twoModels(broken: Set<string> = new Set()) {
    const faux = fauxProvider({
      provider: "openai-codex",
      models: [{ id: "gpt-6-luna" }, { id: "gpt-6-pool" }],
      tokensPerSecond: 100000,
    });
    const used: string[] = [];
    faux.setResponses(
      Array.from({ length: 20 }, () => (_context, _options, _state, model) => {
        used.push(model.id);
        return broken.has(model.id)
          ? fauxAssistantMessage([], { stopReason: "error", errorMessage: "usage limit reached" })
          : fauxAssistantMessage([fauxText(`{"title":"From ${model.id}"}`)]);
      }),
    );
    const models = createModels();
    models.setProvider(faux.provider);
    return { models, used, faux };
  }

  it("reads only [models.titles] (or its default), whatever the profiles say", () => {
    const profiles = {
      default: {
        name: "D",
        main: "openai-codex/gpt-6-main",
        memoryModel: "openai-codex/gpt-6-pool",
        pool: [{ model: "openai-codex/gpt-6-pool" }],
      },
    };
    expect(parseTestSettings({ profiles }).roles.titles).toEqual(LUNA);
    expect(parseTestSettings({ profiles, titles: { reasoning: "low" } }).roles.titles).toEqual(
      LUNA,
    );
    expect(
      parseTestSettings({ profiles, titles: { model: "openai-codex/gpt-6-pool" } }).roles.titles,
    ).toEqual(POOL);
  });

  it("generates on its one model, with no profile fallback", async () => {
    const { models, used } = twoModels(new Set(["gpt-6-luna"]));
    const generator = new TitleGenerator({ models, model: LUNA, reasoning: "low" });
    await expect(generator.generate("hi")).rejects.toBeInstanceOf(TitleError);
    expect(used).toEqual(["gpt-6-luna"]);
  });

  it.each([
    ["the default title model", "", "gpt-6-luna"],
    ["a configured title model", "openai-codex/gpt-6-pool", "gpt-6-pool"],
  ])("titles every thread with %s, never a profile model", async (_name, titles, expected) => {
    const dir = await tempDir();
    const { models: titleSource, used } = twoModels();
    const { models: botModels } = echoModels();
    // The profile's pool, memory model and a legacy background flag all name other models.
    const config = parseTestSettings({
      ...(titles ? { titles: { model: titles } } : {}),
      profiles: {
        default: {
          name: "Default",
          main: "faux/faux-1",
          memoryModel: "openai-codex/gpt-6-mem",
          pool: [{ model: "openai-codex/gpt-6-other" }, { model: "openai-codex/gpt-6-pool" }],
        },
      },
    });
    const profiles = new ProfileStore(config.modelProfiles);
    const db = await openSharedDatabase(join(dir.path, "db.sqlite"));
    const reports: unknown[] = [];
    const manager = await BotManager.open({
      db,
      profiles,
      titles: new TitleGenerator({
        models: titleSource,
        model: config.roles.titles,
        reasoning: config.titles.reasoning,
      }),
      onReport: (error) => reports.push(error),
      harnessOptions: (bot, self) =>
        createBotHarnessOptions({
          bot,
          models: botModels,
          profile: () => profiles.resolve(self.assignedProfile(bot.id)),
        }),
    });
    try {
      const bot = await manager.get((await manager.create("Ada")).id);
      await say(bot, "hello main");
      const thread = await bot.fork({ entryId: await lastEntryId(bot) });
      await say(bot, "plan the trip", thread.conversationId);
      await manager.titles?.idle();
      expect(used).toEqual([expected]);
      expect((await bot.threads())[0]?.title).toBe(`From ${expected}`);
      expect(reports).toEqual([]);
    } finally {
      await manager.close();
      await db.close();
      await dir.cleanup();
    }
  });
});

const ctx = BACKGROUND_CONTEXT;

async function say(bot: Bot, text: string, conversationId?: number): Promise<void> {
  const { submission } = await bot.send(text, conversationId);
  await expect(submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
}

async function lastEntryId(bot: Bot): Promise<number> {
  const main = await bot.main();
  const page = await main.entries({ order: "descending" }, 1, undefined, ctx);
  const entry = page.items[0];
  if (!entry) throw new Error("empty conversation");
  return entry.id as unknown as number;
}
