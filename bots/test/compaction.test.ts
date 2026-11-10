import { dirname, join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Models, MutableModels } from "@earendil-works/pi-ai";
import type { Conversation, EntryRecord } from "@earendil-works/pi-durable";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createBotHarnessOptions } from "../src/agent.ts";
import { type Bot, BotManager } from "../src/bots.ts";
import { NATIVE_COMPACTION_KIND, NativeContextDoc } from "../src/compaction/context.ts";
import { ANTHROPIC_COMPACTION_BETA } from "../src/compaction/native.ts";
import { type ModelRef, settingsSchema } from "../src/config.ts";
import { type BeforeCompactInput, noopBeforeCompact } from "../src/memory.ts";
import { createBotModels } from "../src/models.ts";
import { openSharedDatabase } from "../src/storage/database.ts";
import {
  CLAUDE_QUERY_URL,
  FakeProviders,
  fakeCredentials,
  frameText,
  type RecordedRequest,
} from "./fake-providers.ts";
import { echoModels, FAUX_MODEL, profileOf, tempDir } from "./helpers.ts";

/**
 * One suite, run against the main channel and against a thread: both use the same compaction
 * code. Provider HTTP is faked (no real keys exist in CI); Pi Durable runs for real on SQLite.
 */

const ctx = BACKGROUND_CONTEXT;

const defaults = settingsSchema.parse({
  profiles: { default: { name: "Default", main: "faux/faux-1" } },
}).compaction;
// Keep only the newest turn so a manual compaction always has something to cover.
const compaction = { ...defaults, keep_recent_tokens: 1 };

type Setup = {
  readonly fake: FakeProviders;
  readonly manager: BotManager;
  readonly memory: BeforeCompactInput[];
  readonly reports: unknown[];
  close(): Promise<void>;
};

function combinedModels(fake: FakeProviders, directory: string): MutableModels {
  const models = createBotModels(fakeCredentials(), {
    claude: { directory, query: fake.claudeQuery },
  });
  models.setProvider(echoModels().faux.provider);
  return models;
}

async function open(
  path: string,
  orchestrator: ModelRef,
  fake = new FakeProviders(),
  models?: Models,
): Promise<Setup> {
  const db = await openSharedDatabase(path);
  const memory: BeforeCompactInput[] = [];
  const reports: unknown[] = [];
  const shared = models ?? combinedModels(fake, join(dirname(path), "claude-agent"));
  const manager = await BotManager.open({
    db,
    harnessOptions: (bot) =>
      createBotHarnessOptions({
        bot,
        models: shared,
        profile: profileOf(orchestrator),
        compaction,
        fetch: fake.fetch,
        onBeforeCompact: async (input) => {
          memory.push(input);
        },
        onReport: (error) => reports.push(error),
      }),
  });
  return {
    fake,
    manager,
    memory,
    reports,
    close: async () => {
      await manager.close();
      await db.close();
    },
  };
}

async function say(conversation: Conversation, content: string): Promise<void> {
  const submission = await conversation.submit({ type: "input", content }, ctx);
  await expect(submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
}

async function lastEntryId(conversation: Conversation): Promise<number> {
  const page = await conversation.entries({ order: "descending" }, 1, undefined, ctx);
  const entry = page.items[0];
  if (!entry) throw new Error("empty conversation");
  return entry.id as unknown as number;
}

const variants = [
  { name: "main channel", thread: false },
  { name: "thread", thread: true },
] as const;

/** The conversation under test: the main channel, or a thread forked off a main-channel reply. */
async function target(bot: Bot, thread: boolean): Promise<Conversation> {
  const main = await bot.main();
  if (!thread) return main;
  await say(main, "parent-msg");
  const record = await bot.fork({ entryId: await lastEntryId(main) });
  return bot.conversation(record.conversationId);
}

async function compactNow(bot: Bot, conversation: Conversation) {
  const taskId = await conversation.compact(undefined, ctx);
  return bot.harness.waitForTask(taskId, ctx);
}

async function history(conversation: Conversation): Promise<readonly EntryRecord[]> {
  return (await conversation.entries({ order: "ascending" }, 500, undefined, ctx)).items;
}

type ProviderCase = {
  readonly name: string;
  readonly model: ModelRef;
  /** The native compaction call among the recorded requests. */
  readonly isCompact: (request: RecordedRequest) => boolean;
  /** Assertions on the compaction request body. */
  readonly compactBody: (request: RecordedRequest) => void;
  /** Assertions that the next generation request starts from the native window. */
  readonly windowed: (request: RecordedRequest) => void;
};

// biome-ignore lint/suspicious/noExplicitAny: provider JSON.
const hasItem = (items: any[] | undefined, type: string) =>
  (items ?? []).some((item) => item?.type === type);

const providers: readonly ProviderCase[] = [
  {
    name: "OpenAI Responses (POST /v1/responses/compact)",
    model: { provider: "openai", modelId: "gpt-4.1" },
    isCompact: (r) => r.url === "https://api.openai.com/v1/responses/compact",
    compactBody: (r) => {
      expect(r.body.model).toBe("gpt-4.1");
      expect(Array.isArray(r.body.input)).toBe(true);
    },
    windowed: (r) => {
      expect(r.url).toBe("https://api.openai.com/v1/responses");
      expect(r.body.input[0]).toMatchObject({
        type: "compaction",
        encrypted_content: expect.stringMatching(/^api\.openai\.com-window-/),
      });
    },
  },
  {
    name: "xAI Responses (POST /v1/responses/compact)",
    model: { provider: "xai", modelId: "grok-4.3" },
    isCompact: (r) => r.url === "https://api.x.ai/v1/responses/compact",
    compactBody: (r) => {
      expect(r.body.model).toBe("grok-4.3");
      expect(r.headers.get("authorization")).toBe("Bearer test-xai-key");
    },
    windowed: (r) => {
      expect(r.url).toBe("https://api.x.ai/v1/responses");
      expect(r.body.input[0]).toMatchObject({
        type: "compaction",
        encrypted_content: expect.stringMatching(/^api\.x\.ai-window-/),
      });
    },
  },
  {
    name: "ChatGPT Codex (compaction_trigger)",
    model: { provider: "openai-codex", modelId: "gpt-6-luna" },
    isCompact: (r) =>
      r.url === "https://chatgpt.com/backend-api/codex/responses" &&
      hasItem(r.body?.input, "compaction_trigger"),
    compactBody: (r) => {
      expect(r.body.input.at(-1)).toEqual({ type: "compaction_trigger" });
      expect(r.headers.get("openai-beta")).toBe("responses=experimental");
      expect(r.headers.get("chatgpt-account-id")).toBe("acct-test");
    },
    windowed: (r) => {
      expect(r.url).toBe("https://chatgpt.com/backend-api/codex/responses");
      expect(hasItem(r.body.input, "compaction")).toBe(true);
      expect(hasItem(r.body.input, "compaction_trigger")).toBe(false);
    },
  },
  {
    name: `Anthropic Messages (anthropic-beta: ${ANTHROPIC_COMPACTION_BETA})`,
    model: { provider: "anthropic", modelId: "claude-haiku-4-5" },
    isCompact: (r) => r.path === "/v1/messages" && r.body?.compaction !== undefined,
    compactBody: (r) => {
      expect(r.body.compaction).toEqual({ type: "summarize" });
      expect(r.body.stream).toBeUndefined();
      expect(r.headers.get("anthropic-beta")).toContain(ANTHROPIC_COMPACTION_BETA);
    },
    windowed: (r) => {
      // The block leads the first assistant turn (merged when the kept tail starts with one).
      expect(r.body.messages[0].role).toBe("assistant");
      expect(r.body.messages[0].content[0]).toMatchObject({
        type: "compaction",
        signature: expect.stringMatching(/^anthropic-signature-/),
      });
      expect(r.headers.get("anthropic-beta")).toContain(ANTHROPIC_COMPACTION_BETA);
    },
  },
  {
    name: "Claude Agent SDK (/compact, PostCompact compact_summary)",
    model: { provider: "claude-subscription", modelId: "claude-haiku-4-5" },
    isCompact: (r) =>
      r.url === CLAUDE_QUERY_URL && frameText(r.body.frames.at(-1)).startsWith("/compact"),
    compactBody: (r) => {
      expect(r.body.env.CLAUDE_CODE_OAUTH_TOKEN).toBe("sk-ant-oat01-test-claude");
      expect(r.body.options).toMatchObject({
        model: "claude-haiku-4-5",
        maxTurns: 1,
        persistSession: false,
        tools: [],
        settingSources: [],
      });
      // Every covered user frame is replayed into the transcript without a model turn.
      const replayed = r.body.frames.slice(0, -1);
      // biome-ignore lint/suspicious/noExplicitAny: SDK frames.
      for (const frame of replayed.filter((f: any) => f.type === "user"))
        expect(frame.shouldQuery).toBe(false);
    },
    windowed: (r) => {
      expect(r.url).toBe(CLAUDE_QUERY_URL);
      expect(frameText(r.body.frames[0])).toMatch(/<summary>\nclaude-sdk summary \d+\n<\/summary>/);
    },
  },
];

describe.each(variants)("compaction: $name", ({ thread }) => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  beforeEach(async () => {
    dir = await tempDir();
  });
  afterEach(async () => {
    await dir.cleanup();
  });

  describe.each(providers)("$name", (provider) => {
    it("compacts natively, replays the window, and keeps the full history in SQLite", async () => {
      const t = await open(join(dir.path, "pi-bot.sqlite"), provider.model);
      try {
        const bot = await t.manager.get((await t.manager.create("Alpha")).id);
        const conversation = await target(bot, thread);
        await say(conversation, "alpha-msg");
        await say(conversation, "beta-msg");
        await say(conversation, "gamma-msg");

        const settled = await compactNow(bot, conversation);
        expect(settled.state.outcome).toMatchObject({ status: "completed" });
        expect(t.reports).toEqual([]);

        const compacts = t.fake.requests.filter(provider.isCompact);
        expect(compacts).toHaveLength(1);
        const [request] = compacts;
        if (!request) throw new Error("no compaction request");
        provider.compactBody(request);
        const covered = JSON.stringify(request.body);
        expect(covered).toContain("alpha-msg");
        expect(covered).toContain("beta-msg");
        if (thread) expect(covered).toContain("parent-msg");

        // The head marker moved the model context; Pi Durable's summarizer never ran.
        const view = await conversation.context(ctx);
        expect(view.head?.kind).toBe(NATIVE_COMPACTION_KIND);
        expect((settled.state.outcome as { result?: { entryId?: unknown } }).result?.entryId).toBe(
          view.head?.id,
        );
        const doc = await bot.harness.snapshot(NativeContextDoc, conversation.id, ctx);
        expect(doc?.active?.route).toMatchObject({
          provider: provider.model.provider,
          modelId: provider.model.modelId,
        });
        expect(doc?.receipt?.entryId).toBe(view.head?.id);
        expect(doc?.covered.length).toBeGreaterThan(0);

        // The memory-extraction hook saw what is being compacted.
        expect(t.memory).toHaveLength(1);
        expect(t.memory[0]?.conversationId).toBe(conversation.id);
        expect(JSON.stringify(t.memory[0]?.messages)).toContain("alpha-msg");

        // The next request starts from the provider's window instead of the covered turns.
        const before = t.fake.requests.length;
        await say(conversation, "delta-msg");
        const next = t.fake.requests
          .slice(before)
          .filter((r) => !provider.isCompact(r))
          .at(-1);
        if (!next) throw new Error("no generation request");
        provider.windowed(next);
        const sent = JSON.stringify(next.body);
        expect(sent).toContain("delta-msg");
        expect(sent).not.toMatch(/: alpha-msg/);

        // Nothing was deleted: search and read_thread still see every turn.
        const all = JSON.stringify(await history(conversation));
        for (const text of ["alpha-msg", "beta-msg", "gamma-msg", "delta-msg"])
          expect(all).toContain(text);
      } finally {
        await t.close();
      }
    });

    it("falls back to Pi Durable's summarizer when the provider has no native compaction", async () => {
      const fake = new FakeProviders({ unsupported: true });
      const t = await open(join(dir.path, "pi-bot.sqlite"), provider.model, fake);
      try {
        const bot = await t.manager.get((await t.manager.create("Alpha")).id);
        const conversation = await target(bot, thread);
        await say(conversation, "alpha-msg");
        await say(conversation, "beta-msg");
        const settled = await compactNow(bot, conversation);
        expect(settled.state.outcome).toMatchObject({ status: "completed" });
        expect(t.fake.requests.filter(provider.isCompact)).toHaveLength(1);
        expect(t.reports).toHaveLength(1);
        const view = await conversation.context(ctx);
        expect(view.head?.kind).toBe("pi.compaction");
        expect(t.memory).toHaveLength(1);
        await say(conversation, "gamma-msg");
        expect(JSON.stringify(await history(conversation))).toContain("alpha-msg");
      } finally {
        await t.close();
      }
    });
  });

  it("uses Pi Durable's summarizer for providers without native compaction (faux)", async () => {
    const t = await open(join(dir.path, "pi-bot.sqlite"), FAUX_MODEL);
    try {
      const bot = await t.manager.get((await t.manager.create("Alpha")).id);
      const conversation = await target(bot, thread);
      await say(conversation, "alpha-msg");
      await say(conversation, "beta-msg");
      await say(conversation, "gamma-msg");
      const settled = await compactNow(bot, conversation);
      expect(settled.state.outcome).toMatchObject({ status: "completed" });
      expect(t.fake.requests).toEqual([]);
      expect(t.reports).toEqual([]);
      expect(t.memory).toHaveLength(1);
      expect(t.memory[0]?.conversationId).toBe(conversation.id);
      const view = await conversation.context(ctx);
      expect(view.head?.kind).toBe("pi.compaction");
      const doc = await bot.harness.snapshot(NativeContextDoc, conversation.id, ctx);
      expect(doc?.covered ?? []).toEqual([]);
      expect(doc?.active).toBeUndefined();
      await say(conversation, "delta-msg");
      const all = JSON.stringify(await history(conversation));
      for (const text of ["alpha-msg", "beta-msg", "gamma-msg", "delta-msg"])
        expect(all).toContain(text);
    } finally {
      await t.close();
    }
  });

  it("re-projects the window when the model changes: native on the new route, else a summary", async () => {
    const t = await open(join(dir.path, "pi-bot.sqlite"), {
      provider: "openai",
      modelId: "gpt-4.1",
    });
    try {
      const bot = await t.manager.get((await t.manager.create("Alpha")).id);
      const conversation = await target(bot, thread);
      await say(conversation, "alpha-msg");
      await say(conversation, "beta-msg");
      await compactNow(bot, conversation);
      expect(t.fake.to("/responses/compact")).toHaveLength(1);

      // OpenAI's encrypted window means nothing to Anthropic: recompact the original turns there.
      await conversation.configure(
        { model: { provider: "anthropic", modelId: "claude-haiku-4-5" } },
        ctx,
      );
      await say(conversation, "gamma-msg");
      const anthropic = t.fake.requests.filter((r) => r.path === "/v1/messages");
      const recompact = anthropic.find((r) => r.body?.compaction !== undefined);
      expect(JSON.stringify(recompact?.body)).toContain("alpha-msg");
      expect(JSON.stringify(recompact?.body)).not.toContain("api.openai.com-window");
      const turn = anthropic.filter((r) => r.body?.compaction === undefined).at(-1);
      expect(turn?.body.messages[0].content[0]).toMatchObject({ type: "compaction" });
      let doc = await bot.harness.snapshot(NativeContextDoc, conversation.id, ctx);
      expect(doc?.active?.route).toMatchObject({
        provider: "anthropic",
        strategy: "anthropic-compaction",
      });

      // A provider without native compaction gets a portable summary of the same original turns.
      await conversation.configure({ model: FAUX_MODEL }, ctx);
      await say(conversation, "delta-msg");
      doc = await bot.harness.snapshot(NativeContextDoc, conversation.id, ctx);
      expect(doc?.active?.summary).toContain("echo:");
      expect(doc?.active?.window).toBeUndefined();
      expect(t.reports).toEqual([]);
      const all = JSON.stringify(await history(conversation));
      for (const text of ["alpha-msg", "beta-msg", "gamma-msg", "delta-msg"])
        expect(all).toContain(text);
    } finally {
      await t.close();
    }
  });

  it("compacts natively on its own once the context passes the configured threshold", async () => {
    const model = { provider: "openai", modelId: "gpt-4.1" } as const;
    const fake = new FakeProviders();
    const models = combinedModels(fake, join(dir.path, "claude-agent"));
    const window = models.getModel(model.provider, model.modelId)?.contextWindow ?? 0;
    const db = await openSharedDatabase(join(dir.path, "pi-bot.sqlite"));
    const reports: unknown[] = [];
    const manager = await BotManager.open({
      db,
      harnessOptions: (bot) =>
        createBotHarnessOptions({
          bot,
          models,
          profile: profileOf(model),
          // Fake usage reports ~110 tokens per turn; leave 50 before the threshold.
          compaction: {
            ...compaction,
            models: { "openai/gpt-4.1": { reserve_tokens: window - 50 } },
          },
          fetch: fake.fetch,
          onReport: (error) => reports.push(error),
        }),
    });
    try {
      const bot = await manager.get((await manager.create("Alpha")).id);
      const conversation = await target(bot, thread);
      await say(conversation, "alpha-msg");
      await say(conversation, "beta-msg");
      await say(conversation, "gamma-msg");
      expect(fake.to("/responses/compact").length).toBeGreaterThan(0);
      expect((await conversation.context(ctx)).head?.kind).toBe(NATIVE_COMPACTION_KIND);
      expect(reports).toEqual([]);
    } finally {
      await manager.close();
      await db.close();
    }
  });

  it("compacts again on the same route from the previous window", async () => {
    const t = await open(join(dir.path, "pi-bot.sqlite"), {
      provider: "openai",
      modelId: "gpt-4.1",
    });
    try {
      const bot = await t.manager.get((await t.manager.create("Alpha")).id);
      const conversation = await target(bot, thread);
      await say(conversation, "alpha-msg");
      await say(conversation, "beta-msg");
      await compactNow(bot, conversation);
      await say(conversation, "gamma-msg");
      await say(conversation, "delta-msg");
      await compactNow(bot, conversation);
      const compacts = t.fake.to("/responses/compact");
      expect(compacts).toHaveLength(2);
      const second = compacts[1]?.body;
      expect(second.input[0]).toMatchObject({ type: "compaction" });
      expect(JSON.stringify(second)).not.toMatch(/: alpha-msg/);
      expect(JSON.stringify(second)).toContain("gamma-msg");
      expect(t.reports).toEqual([]);
    } finally {
      await t.close();
    }
  });
});

describe("beforeCompact memory hook", () => {
  it("is a no-op by default", async () => {
    expect(
      await noopBeforeCompact(
        { conversationId: 1, reason: "manual", entries: [], messages: [] },
        ctx,
      ),
    ).toBeUndefined();
  });

  it("reports a failing extractor and still compacts", async () => {
    const dir = await tempDir();
    const db = await openSharedDatabase(join(dir.path, "pi-bot.sqlite"));
    const reports: unknown[] = [];
    const manager = await BotManager.open({
      db,
      harnessOptions: (bot) =>
        createBotHarnessOptions({
          bot,
          models: combinedModels(new FakeProviders(), join(dir.path, "claude-agent")),
          profile: profileOf(FAUX_MODEL),
          compaction,
          onBeforeCompact: () => {
            throw new Error("extractor down");
          },
          onReport: (error) => reports.push(error),
        }),
    });
    try {
      const bot = await manager.get((await manager.create("Alpha")).id);
      const main = await bot.main();
      await say(main, "alpha-msg");
      await say(main, "beta-msg");
      const settled = await compactNow(bot, main);
      expect(settled.state.outcome).toMatchObject({ status: "completed" });
      expect((await main.context(ctx)).head?.kind).toBe("pi.compaction");
      expect(String(reports[0])).toContain("extractor down");
    } finally {
      await manager.close();
      await db.close();
      await dir.cleanup();
    }
  });
});

describe("compaction policy", () => {
  it("maps [compaction] onto Pi Durable settings with per-model overrides", async () => {
    const { compactionSettings } = await import("../src/agent.ts");
    expect(
      compactionSettings({ ...defaults, models: { "openai/gpt-4.1": { reserve_tokens: 1 } } }),
    ).toEqual({
      enabled: true,
      reserveTokens: defaults.reserve_tokens,
      keepRecentTokens: defaults.keep_recent_tokens,
      backgroundTokens: 0,
      modelOverrides: { "openai/gpt-4.1": { reserveTokens: 1 } },
    });
    expect(defaults.native).toBe("auto");
  });
});
