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
import { BotManager, effectiveModel } from "../src/bots.ts";
import {
  classifyLimit,
  claudeLimit,
  fallbackNote,
  hasFallbackNote,
  LIMIT_COOLDOWN_MS,
  ModelAvailability,
  observingFetch,
  stripFallbackNote,
} from "../src/limits.ts";
import { ProfileStore } from "../src/profiles.ts";
import { openSharedDatabase } from "../src/storage/database.ts";
import { BotRegistry } from "../src/storage/registry.ts";
import { displayEntry } from "../src/transcript.ts";
import { parseTestSettings, tempDir } from "./helpers.ts";

const ctx = BACKGROUND_CONTEXT;
const NOW = 1_800_000_000_000;
const error = (errorMessage: string) => ({ stopReason: "error" as const, errorMessage });

describe("classifyLimit", () => {
  it("reads the window and reset only from what the provider returned", () => {
    // Codex: body resets_at, the used-up window from headers.
    expect(
      classifyLimit(
        error("You have hit your ChatGPT usage limit (plus plan)."),
        {
          status: 429,
          headers: {
            "x-codex-primary-used-percent": "100",
            "x-codex-primary-window-minutes": "300",
          },
          body: JSON.stringify({
            error: { type: "usage_limit_reached", resets_at: 1_800_003_600 },
          }),
        },
        NOW,
      ),
    ).toEqual({ kind: "five_hour", resetsAt: 1_800_003_600_000 });
    expect(
      classifyLimit(
        error("usage_limit_reached"),
        {
          status: 429,
          headers: {
            "x-codex-secondary-used-percent": "100",
            "x-codex-secondary-window-minutes": "10080",
            "x-codex-secondary-reset-after-seconds": "7200",
          },
          body: "",
        },
        NOW,
      ),
    ).toEqual({ kind: "weekly", resetsAt: NOW + 7_200_000 });
    // Anthropic unified headers.
    expect(
      classifyLimit(
        error("429 rate_limit_error: usage limit"),
        {
          status: 429,
          headers: {
            "anthropic-ratelimit-unified-representative-claim": "seven_day",
            "anthropic-ratelimit-unified-reset": "1800090000",
          },
          body: "",
        },
        NOW,
      ),
    ).toEqual({ kind: "weekly", resetsAt: 1_800_090_000_000 });
    // Codex's own friendly text carries the reset it computed from resets_at.
    expect(
      classifyLimit(
        error("You have hit your ChatGPT usage limit. Try again in ~42 min."),
        undefined,
        NOW,
      ),
    ).toEqual({ kind: "usage", resetsAt: NOW + 42 * 60_000 });
  });

  it("never invents a window or reset", () => {
    expect(classifyLimit(error("You've hit your limit"), undefined, NOW)).toEqual({
      kind: "usage",
    });
    expect(
      classifyLimit(error("402 Insufficient credits"), { status: 402, headers: {}, body: "" }, NOW),
    ).toEqual({ kind: "credits" });
    expect(
      classifyLimit(
        error("429 You exceeded your current quota (insufficient_quota)"),
        undefined,
        NOW,
      ),
    ).toEqual({ kind: "credits" });
    expect(classifyLimit(error("GoUsageLimitError: Monthly usage limit reached"))).toEqual({
      kind: "usage",
    });
  });

  it("leaves transient rate limits and ordinary errors to the normal retry", () => {
    expect(classifyLimit(error("429 Too Many Requests"))).toEqual({ kind: "rate" });
    expect(classifyLimit(error("Overloaded"))).toEqual({ kind: "rate" });
    expect(classifyLimit(error("500 Internal server error"))).toBeUndefined();
    expect(classifyLimit({ stopReason: "stop" })).toBeUndefined();
    expect(classifyLimit({ ...error("x"), pibotLimit: { kind: "weekly" } })).toEqual({
      kind: "weekly",
    });
  });

  it("maps Claude Code rate-limit events", () => {
    expect(
      claudeLimit(
        { status: "rejected", rateLimitType: "five_hour", resetsAt: 1_800_001_000 },
        "rate_limit",
        "",
        NOW,
      ),
    ).toEqual({ kind: "five_hour", resetsAt: 1_800_001_000_000 });
    expect(
      claudeLimit({ status: "rejected", rateLimitType: "seven_day_opus" }, undefined, "", NOW),
    ).toEqual({
      kind: "weekly",
    });
    expect(claudeLimit({ status: "rejected" }, undefined, "", NOW)).toEqual({ kind: "usage" });
    expect(claudeLimit(undefined, "billing_error", "", NOW)).toEqual({ kind: "usage" });
    expect(claudeLimit({ status: "allowed" }, "rate_limit", "API Error: 429", NOW)).toEqual({
      kind: "rate",
    });
    expect(claudeLimit({ status: "allowed" }, undefined, "boom", NOW)).toBeUndefined();
  });
});

describe("ModelAvailability", () => {
  it("keeps a model out until its reset, or a cooldown when unknown; credits cover the account", () => {
    let now = NOW;
    const availability = new ModelAvailability({ now: () => now });
    const changes: number[] = [];
    availability.onChange(() => changes.push(now));
    const unknown = availability.mark("openai-codex/gpt-6-sol", { kind: "usage" });
    expect(unknown).toMatchObject({ account: "ChatGPT account", retryAt: NOW + LIMIT_COOLDOWN_MS });
    expect(unknown.resetsAt).toBeUndefined();
    availability.mark("openrouter/a/b", { kind: "credits" });
    expect(availability.available("openrouter/c/d")).toBe(false);
    expect(availability.limit("openrouter/c/d")?.account).toBe("OpenRouter key");
    expect(availability.available("openai-codex/gpt-6-luna")).toBe(true);
    now += LIMIT_COOLDOWN_MS;
    expect(availability.available("openai-codex/gpt-6-sol")).toBe(true);
    availability.clear("openrouter");
    expect(availability.available("openrouter/a/b")).toBe(true);
    expect(changes).toHaveLength(3);
    availability.close();
  });

  it("orders fallbacks and pauses when the whole chain is out", () => {
    const availability = new ModelAvailability();
    const profile = {
      id: "p",
      name: "P",
      main: "faux/a",
      fallbacks: ["faux/b", "faux/c"],
      pool: [],
    };
    expect(effectiveModel(profile, availability)).toMatchObject({ model: "faux/a", paused: false });
    availability.mark("faux/a", { kind: "weekly", resetsAt: Date.now() + 60_000 });
    availability.mark("faux/b", { kind: "usage" });
    const picked = effectiveModel(profile, availability);
    expect(picked.model).toBe("faux/c");
    expect(picked.limits.map((limit) => limit.model)).toEqual(["faux/a", "faux/b"]);
    availability.mark("faux/c", { kind: "usage" });
    expect(effectiveModel(profile, availability)).toMatchObject({ model: "faux/a", paused: true });
    expect(effectiveModel({ ...profile, fallbacks: [] }, new ModelAvailability()).paused).toBe(
      false,
    );
    availability.close();
  });

  it("persists marked limits; a new instance restores the live ones and drops the rest", async () => {
    const dir = await tempDir();
    const db = await openSharedDatabase(join(dir.path, "db.sqlite"));
    try {
      const registry = new BotRegistry(db);
      await registry.migrate();
      let now = NOW;
      const first = new ModelAvailability({ now: () => now, store: registry });
      first.mark("openai-codex/gpt-6-sol", { kind: "weekly", resetsAt: NOW + 86_400_000 });
      first.mark("openrouter/a/b", { kind: "credits" });
      first.mark("faux/x", { kind: "usage" });
      first.clear("faux");
      await first.flushed();
      first.close();
      expect((await registry.limits()).map((row) => row.key)).toEqual([
        "openai-codex/gpt-6-sol",
        "openrouter/*",
      ]);
      await db.run("INSERT INTO pibot_limits (key, entry) VALUES ('broken', 'not json')");

      // After the restart the credits cooldown (no reset given) is over; the weekly limit is not.
      now = NOW + LIMIT_COOLDOWN_MS;
      const second = new ModelAvailability({ now: () => now, store: registry });
      expect((await second.load()).map((entry) => entry.model)).toEqual(["openai-codex/gpt-6-sol"]);
      expect(second.limit("openai-codex/gpt-6-sol")).toMatchObject({
        kind: "weekly",
        resetsAt: NOW + 86_400_000,
        account: "ChatGPT account",
      });
      expect(second.available("openrouter/c/d")).toBe(true);
      expect((await registry.limits()).map((row) => row.key)).toEqual(["openai-codex/gpt-6-sol"]);
      second.close();
    } finally {
      await db.close();
      await dir.cleanup();
    }
  });

  it("observes HTTP error responses without consuming them", async () => {
    const seen: unknown[] = [];
    const fetch = observingFetch(
      async () =>
        new Response('{"error":{"resets_in_seconds":60}}', {
          status: 429,
          headers: {
            "x-codex-primary-used-percent": "100",
            authorization: "secret",
            "retry-after": "5",
          },
        }),
      (response) => seen.push(response),
    );
    const response = await fetch("https://example.invalid");
    expect(await response.text()).toContain("resets_in_seconds");
    expect(seen).toEqual([
      {
        status: 429,
        headers: { "x-codex-primary-used-percent": "100", "retry-after": "5" },
        body: '{"error":{"resets_in_seconds":60}}',
      },
    ]);
  });
});

describe("main-model fallbacks", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let manager: BotManager | undefined;
  let db: Awaited<ReturnType<typeof openSharedDatabase>> | undefined;
  let availability: ModelAvailability;
  const calls: string[] = [];
  const faux = fauxProvider({
    tokensPerSecond: 5000,
    models: [{ id: "faux-1" }, { id: "faux-2" }, { id: "faux-3" }],
  });
  /** Models in `limited` answer with a usage-limit error; the rest reply with their name. */
  const limited = new Set<string>();
  /** The last user message each request carried, by model. */
  const lastUser: { model: string; text: string }[] = [];
  const respond: FauxResponseFactory = (context, _options, _state, model) => {
    calls.push(model.id);
    const user = context.messages.filter((message) => message.role === "user").at(-1);
    const content = user?.content;
    lastUser.push({
      model: model.id,
      text:
        typeof content === "string"
          ? content
          : (content ?? []).map((block) => ("text" in block ? block.text : "")).join(""),
    });
    if (limited.has(model.id)) {
      return fauxAssistantMessage([], {
        stopReason: "error",
        errorMessage: "You have hit your ChatGPT usage limit (plus plan). Try again in ~30 min.",
      });
    }
    return fauxAssistantMessage([fauxText(`reply from ${model.id}`)]);
  };

  const open = async (fallbacks: string[], cooldownMs?: number, persist = false) => {
    const config = parseTestSettings({
      profiles: { default: { name: "Default", main: "faux/faux-1", fallbacks } },
    });
    const profiles = new ProfileStore(config.modelProfiles);
    const models = createModels();
    models.setProvider(faux.provider);
    db = await openSharedDatabase(join(dir.path, "db.sqlite"));
    // As the app does: stored limits are restored before any bot opens.
    const registry = new BotRegistry(db);
    await registry.migrate();
    availability = new ModelAvailability({
      ...(cooldownMs ? { cooldownMs } : {}),
      ...(persist ? { store: registry } : {}),
    });
    await availability.load();
    manager = await BotManager.open({
      db,
      profiles,
      availability,
      log: () => {},
      harnessOptions: (bot, self) =>
        createBotHarnessOptions({
          bot,
          models,
          profile: () => profiles.resolve(self.assignedProfile(bot.id)),
          onLimit: (conversationId, model, limit) =>
            self.reportLimit(bot.id, conversationId, model, limit),
          fallbackNote: (conversationId) => self.fallbackNote(bot.id, conversationId),
        }),
    });
    return manager;
  };
  const turn = async (botId: string, text: string) => {
    faux.setResponses(Array.from({ length: 10 }, () => respond));
    const bot = await manager?.get(botId);
    const sent = await bot?.send(text);
    return sent?.submission.wait(ctx);
  };
  const mainModel = async (botId: string) =>
    (await (await (await manager?.get(botId))?.main())?.agent(ctx))?.model;

  beforeEach(async () => {
    dir = await tempDir();
    calls.length = 0;
    lastUser.length = 0;
    limited.clear();
  });
  afterEach(async () => {
    await manager?.close();
    await db?.close();
    availability.close();
    manager = undefined;
    db = undefined;
    await dir.cleanup();
  });

  it("switches to the next available fallback mid-turn and reports it", async () => {
    const m = await open(["faux/faux-2", "faux/faux-3"]);
    const bot = await m.create("Worker");
    limited.add("faux-1");
    limited.add("faux-2");
    const done = await turn(bot.id, "hello");
    expect(done).toMatchObject({ status: "done" });
    // faux-1 fails, the retry runs on faux-2 (also out), then on faux-3.
    expect(calls).toEqual(["faux-1", "faux-2", "faux-3"]);
    expect(await mainModel(bot.id)).toEqual({ provider: "faux", modelId: "faux-3" });
    const status = m.modelStatus(bot.id);
    expect(status).toMatchObject({
      kind: "fallback",
      primary: "faux/faux-1",
      active: "faux/faux-3",
    });
    expect(status?.limits.map((limit) => [limit.model, limit.kind])).toEqual([
      ["faux/faux-1", "usage"],
      ["faux/faux-2", "usage"],
    ]);
    // The reset the provider stated (~30 min), not an invented one.
    expect(status?.limits[0]?.resetsAt).toBeGreaterThan(Date.now() + 29 * 60_000);
    // Other bots on the profile follow, and the next turn stays on the fallback.
    const other = await m.create("Other");
    expect(await mainModel(other.id)).toEqual({ provider: "faux", modelId: "faux-3" });
    calls.length = 0;
    await turn(bot.id, "again");
    expect(calls).toEqual(["faux-3"]);
  }, 30_000);

  it("pauses without fallbacks and returns to the primary after the cooldown", async () => {
    const m = await open([], 300);
    const bot = await m.create("Worker");
    limited.add("faux-1");
    // Ordinary limit text without a reset: the cooldown applies.
    faux.setResponses([
      () =>
        fauxAssistantMessage([], {
          stopReason: "error",
          errorMessage: "This account ran out of usage.",
        }),
    ]);
    const sent = await (await m.get(bot.id)).send("hello");
    const failed = await sent.submission.wait(ctx);
    expect(failed.status).not.toBe("done");
    expect(m.modelStatus(bot.id)).toMatchObject({ kind: "paused", active: "faux/faux-1" });
    expect(m.modelStatus(bot.id)?.limits[0]?.resetsAt).toBeUndefined();
    limited.clear();
    await new Promise((resolve) => setTimeout(resolve, 600));
    expect(m.modelStatus(bot.id)).toMatchObject({ kind: "returned", active: "faux/faux-1" });
    expect(await turn(bot.id, "again")).toMatchObject({ status: "done" });
  }, 30_000);

  it("returns to the primary from a fallback once it resets", async () => {
    const m = await open(["faux/faux-2"]);
    const bot = await m.create("Worker");
    availability.mark("faux/faux-1", { kind: "five_hour", resetsAt: Date.now() + 300 });
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(await mainModel(bot.id)).toEqual({ provider: "faux", modelId: "faux-2" });
    expect(m.modelStatus(bot.id)?.limits[0]).toMatchObject({ kind: "five_hour" });
    await new Promise((resolve) => setTimeout(resolve, 600));
    expect(await mainModel(bot.id)).toEqual({ provider: "faux", modelId: "faux-1" });
    expect(m.modelStatus(bot.id)).toMatchObject({ kind: "returned", primary: "faux/faux-1" });
    calls.length = 0;
    await turn(bot.id, "hi");
    expect(calls).toEqual(["faux-1"]);
  }, 30_000);

  it("keeps a marked limit across a restart; clearing the account's limits returns to main", async () => {
    const m = await open(["faux/faux-2"], undefined, true);
    const bot = await m.create("Worker");
    const resetsAt = Date.now() + 3_600_000;
    availability.mark("faux/faux-1", { kind: "weekly", resetsAt });
    await availability.flushed();
    await until(async () => (await mainModel(bot.id))?.modelId === "faux-2");

    // Restart: a new manager and availability on the same database.
    await manager?.close();
    availability.close();
    await db?.close();
    const again = await open(["faux/faux-2"], undefined, true);
    expect(availability.limit("faux/faux-1")).toMatchObject({ kind: "weekly", resetsAt });
    expect(await mainModel(bot.id)).toEqual({ provider: "faux", modelId: "faux-2" });
    expect(again.modelStatus(bot.id)).toMatchObject({ kind: "fallback", active: "faux/faux-2" });
    calls.length = 0;
    await turn(bot.id, "still out?");
    expect(calls).toEqual(["faux-2"]);

    // New credentials for the account (Settings calls `clear(provider)`): back on main.
    availability.clear("faux");
    await until(async () => (await mainModel(bot.id))?.modelId === "faux-1");
    expect(again.modelStatus(bot.id)).toMatchObject({ kind: "returned", active: "faux/faux-1" });
    await availability.flushed();
    expect(await new BotRegistry(db as NonNullable<typeof db>).limits()).toEqual([]);
  }, 30_000);

  it("tells the fallback model to mention the switch, in the turn's input only", async () => {
    const m = await open(["faux/faux-2"]);
    const bot = await m.create("Worker");
    limited.add("faux-1");
    const note = fallbackNote("faux/faux-1", "usage", "faux/faux-2");
    expect(note).toBe(
      "[Note: faux/faux-1 is unavailable (usage limit); you are faux/faux-2. Mention this briefly in your reply.]",
    );

    // Switched mid-turn: the retry on the fallback carries the note for that request.
    expect(await turn(bot.id, "hello")).toMatchObject({ status: "done" });
    expect(lastUser).toEqual([
      { model: "faux-1", text: "hello" },
      { model: "faux-2", text: `${note}\n\nhello` },
    ]);
    expect(await m.fallbackNote(bot.id)).toBe(note);

    // Later turns store it in their input; the chat shows only what the user wrote.
    lastUser.length = 0;
    faux.setResponses(Array.from({ length: 10 }, () => respond));
    const sent = await (await m.get(bot.id)).send("again");
    await sent.submission.wait(ctx);
    expect(lastUser).toEqual([{ model: "faux-2", text: `${note}\n\nagain` }]);
    const page = await sent.conversation.entries({ order: "descending" }, 10, undefined, ctx);
    const shown = page.items.map(displayEntry).filter((entry) => entry?.role === "user");
    expect(shown.map((entry) => entry?.text)).toEqual(["again", "hello"]);

    // The system prompt never changes for it, and no note once main is back.
    expect(hasFallbackNote(`${note}\n\nx`)).toBe(true);
    expect(stripFallbackNote(`${note}\n\nx`)).toBe("x");
    availability.clear("faux");
    limited.clear();
    await until(async () => (await mainModel(bot.id))?.modelId === "faux-1");
    expect(await m.fallbackNote(bot.id)).toBeUndefined();
    lastUser.length = 0;
    await turn(bot.id, "back");
    expect(lastUser).toEqual([{ model: "faux-1", text: "back" }]);
  }, 30_000);
});

async function until(check: () => Promise<boolean>): Promise<void> {
  for (let tries = 0; tries < 200; tries++) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("timed out");
}
