import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import {
  type FauxResponseFactory,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxToolCall,
} from "@earendil-works/pi-ai/providers/faux";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createBotHarnessOptions } from "../src/agent.ts";
import { BotManager } from "../src/bots.ts";
import type { Profile } from "../src/config.ts";
import { ModelAvailability } from "../src/limits.ts";
import { ProfileStore } from "../src/profiles.ts";
import { openSharedDatabase } from "../src/storage/database.ts";
import {
  allowedModels,
  childToolsText,
  poolSection,
  SELF,
  subagentModel,
} from "../src/subagent.ts";
import { tempDir } from "./helpers.ts";

const ctx = BACKGROUND_CONTEXT;

const profile: Profile = {
  id: "default",
  name: "Default",
  main: "faux/faux-1",
  fallbacks: ["faux/faux-4"],
  memoryModel: "faux/faux-2",
  guidance: "Faux-2 is fine for lookups. Check faux-3's claims.",
  pool: [
    { model: "faux/faux-2", useFor: "Cheap lookups" },
    { model: "faux/faux-3", useFor: "" },
  ],
};
const emptyPool: Profile = { ...profile, pool: [], guidance: "Prefer doing it yourself." };

const LISTED = { input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5 };

const SUBAGENT = "You are a subagent";

describe("run_subagent", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let db: Awaited<ReturnType<typeof openSharedDatabase>>;
  let manager: BotManager;
  let availability: ModelAvailability;
  let profiles: ProfileStore;
  const events: string[] = [];
  const contexts: { model: string; child: boolean; json: string }[] = [];
  const faux = fauxProvider({
    tokensPerSecond: 5000,
    models: [
      {
        id: "faux-1",
        name: "Faux One",
        reasoning: true,
        input: ["text", "image"],
        cost: LISTED,
        contextWindow: 272_000,
        maxTokens: 128_000,
      },
      { id: "faux-2", cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } },
      { id: "faux-3", cost: { input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25 } },
      { id: "faux-4", cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 } },
    ],
  });

  /**
   * Main conversations ask for `calls` in order, then reply with every tool result they saw. A
   * subagent child (on any model, the main one included) answers with its model id; faux-3 fails.
   */
  const script =
    (calls: Record<string, string>[]): FauxResponseFactory =>
    (context, _options, _state, model) => {
      const json = JSON.stringify(context);
      const child = json.includes(SUBAGENT);
      contexts.push({ model: model.id, child, json });
      if (child) {
        if (model.id === "faux-3") {
          return fauxAssistantMessage([], {
            stopReason: "error",
            errorMessage: "400 broken on purpose",
          });
        }
        return fauxAssistantMessage([fauxText(`child answer from ${model.id}`)]);
      }
      const results = json.split('"role":"toolResult"').length - 1;
      const next = calls[results];
      if (next) {
        return fauxAssistantMessage([fauxToolCall("run_subagent", next)], {
          stopReason: "toolUse",
        });
      }
      return fauxAssistantMessage([fauxText("main done")]);
    };

  const open = async (initial: Profile) => {
    const models = createModels();
    models.setProvider(faux.provider);
    profiles = new ProfileStore({ defaultId: "default", profiles: [initial] });
    availability = new ModelAvailability();
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
          modelLimit: (ref) => availability.limit(ref),
          onSubagent: (event) =>
            events.push(`${event.phase} ${event.model}${event.self ? " self" : ""}`),
        }),
    });
  };

  beforeEach(async () => {
    dir = await tempDir();
    events.length = 0;
    contexts.length = 0;
    db = await openSharedDatabase(join(dir.path, "db.sqlite"));
  });

  afterEach(async () => {
    await manager.close();
    availability.close();
    await db.close();
    await dir.cleanup();
  });

  const run = async (calls: Record<string, string>[], before?: () => Promise<void>) => {
    faux.setResponses(Array.from({ length: 20 }, () => script(calls)));
    const bot = await manager.get((await manager.create("Worker")).id);
    await before?.();
    const sent = await bot.send("go");
    await expect(sent.submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
    const main = contexts.filter((context) => !context.child);
    return { first: main[0]?.json ?? "", last: main.at(-1)?.json ?? "" };
  };

  it("runs a task on a pool model in a separate conversation and returns its answer", async () => {
    await open(profile);
    const { first, last } = await run([
      { model: "faux/faux-2", reasoning: "low", task: "find the answer" },
    ]);
    expect(last).toContain("child answer from faux-2");
    expect(events).toEqual(["start faux/faux-2", "done faux/faux-2"]);
    // The main model sees self and its pool, with notes and the user's model preferences.
    expect(first).toContain('\\"self\\" = faux/faux-1, the model you run on now');
    expect(first).toContain('- \\"faux/faux-2\\"');
    expect(first).toContain("User's notes: Cheap lookups");
    expect(first).toContain("Faux-2 is fine for lookups. Check faux-3's claims.");
    expect(first).not.toContain("background");
    // The child got only the task, none of the bot's tools or conversation, and no run_subagent.
    const child = contexts.find((context) => context.child)?.json ?? "";
    expect(child).toContain("find the answer");
    expect(child).not.toContain('"content":"go"');
    expect(child).not.toContain('"name":"run_subagent"');
    expect(child).not.toContain("model_pool");
  });

  it('runs "self" on the main model with an empty pool, and shows the guidance', async () => {
    await open(emptyPool);
    const { first, last } = await run([{ model: SELF, task: "summarize this" }]);
    expect(last).toContain("child answer from faux-1");
    expect(events).toEqual(["start faux/faux-1 self", "done faux/faux-1 self"]);
    expect(first).toContain("run_subagent");
    expect(first).toContain('\\"self\\" = faux/faux-1');
    expect(first).toContain("model pool is empty");
    expect(first).toContain("Prefer doing it yourself.");
    // The main model's own ref works the same as "self".
    events.length = 0;
    await run([{ model: "faux/faux-1", task: "again" }]);
    expect(events).toEqual(["start faux/faux-1 self", "done faux/faux-1 self"]);
  });

  it('runs "self" on the active fallback, not the limited profile main model', async () => {
    await open(emptyPool);
    const { first, last } = await run(
      [
        { model: SELF, task: "on the fallback" },
        { model: "faux/faux-1", task: "the limited main model" },
      ],
      async () => {
        availability.mark("faux/faux-1", { kind: "weekly" });
        await new Promise((resolve) => setTimeout(resolve, 20));
      },
    );
    expect(last).toContain("child answer from faux-4");
    // The limited main model is not self any more and not in the pool: refused.
    expect(last).toContain("faux/faux-1 is not available for subagents");
    expect(last).toContain('Use \\"self\\" (faux/faux-4)');
    expect(events).toEqual(["start faux/faux-4 self", "done faux/faux-4 self"]);
    expect(first).toContain('\\"self\\" = faux/faux-4, the model you run on now');
    expect(contexts.filter((context) => context.child).map((context) => context.model)).toEqual([
      "faux-4",
    ]);
  });

  it('rejects models outside self and the pool, and the removed "background" alias', async () => {
    await open(profile);
    const { last } = await run([
      { model: "openai/not-in-pool", task: "x" },
      { model: "background", task: "x" },
      { model: "faux/faux-4", task: "a fallback is not a pool model" },
      { model: "faux/faux-3", task: "x" },
    ]);
    expect(last).toContain("openai/not-in-pool is not available for subagents");
    expect(last).toContain("background is not available for subagents");
    expect(last).toContain("faux/faux-4 is not available for subagents");
    expect(last).toContain("or a pool model: faux/faux-2, faux/faux-3");
    expect(last).toContain("Subagent on faux/faux-3 failed:");
    expect(last).toContain("400 broken on purpose");
    expect(last).toContain("Pick another listed model or do it yourself");
    expect(events).toEqual(["start faux/faux-3", expect.stringMatching(/^failed faux\/faux-3/)]);
    expect(contexts.filter((context) => context.child).map((context) => context.model)).toEqual([
      "faux-3",
    ]);
  });

  it("keeps the user's pool notes on self when the current model is in the pool", async () => {
    const text = await poolSection(profile, "faux/faux-2");
    const lines = text.split("\n");
    expect(lines.filter((line) => line.includes("faux/faux-2"))).toEqual([
      expect.stringMatching(
        /^- "self" = faux\/faux-2, the model you run on now: .*User's notes: Cheap lookups$/,
      ),
    ]);
  });

  it("says exactly which tools a subagent keeps, and that bot tools stay behind", async () => {
    expect(childToolsText(["bash", "read", "web_search", "fetch_url"])).toBe(
      "It keeps these tools of yours: bash, read, web_search, fetch_url. It gets none of your bot tools (messaging or managing bots, teams, settings and config, account notes, searching or reading your history), your identity, your memory or this conversation, so put everything it needs in the task.",
    );
    expect(childToolsText([])).toMatch(/^It has no tools\. It gets none of your bot tools/);
    expect(childToolsText(undefined)).toMatch(
      /^It keeps your coding and web tools, when you have them\./,
    );
    // The bot here has neither a container nor web tools: the prompt and tool say so.
    await open(emptyPool);
    const { first } = await run([]);
    expect(first).toContain("It has no tools. It gets none of your bot tools");
    expect(first).not.toContain("with your tools");
    expect(first.split("It gets none of your bot tools").length - 1).toBe(2);
  });

  it("resolves the allowlist: self first, then the pool, nothing else", () => {
    expect(allowedModels(profile, "faux/faux-1").map((choice) => choice.model)).toEqual([
      "faux/faux-1",
      "faux/faux-2",
      "faux/faux-3",
    ]);
    // A pool model that is the current model is listed once, as self, keeping the user's notes.
    expect(allowedModels(profile, "faux/faux-2")).toEqual([
      { model: "faux/faux-2", self: true, useFor: "Cheap lookups" },
      { model: "faux/faux-3", self: false, useFor: "" },
    ]);
    expect(subagentModel(profile, "faux/faux-2", SELF)?.useFor).toBe("Cheap lookups");
    expect(subagentModel(profile, "faux/faux-4", SELF)).toEqual({
      model: "faux/faux-4",
      self: true,
      useFor: "",
    });
    expect(subagentModel(profile, "faux/faux-4", "faux/faux-1")).toBeUndefined();
    expect(subagentModel(profile, "faux/faux-1", "faux/faux-3")?.self).toBe(false);
    expect(subagentModel(profile, "faux/faux-1", "background")).toBeUndefined();
    // The memory model is no subagent model unless it is in the pool.
    expect(
      subagentModel({ ...profile, memoryModel: "faux/faux-9" }, "faux/faux-1", "faux/faux-9"),
    ).toBeUndefined();
    expect(subagentModel(emptyPool, undefined, SELF)).toBeUndefined();
  });

  it("describes models truthfully: listed, $0 and unknown prices, limits, provenance", async () => {
    await open(profile);
    const models = createModels();
    models.setProvider(faux.provider);
    availability.mark("faux/faux-3", { kind: "five_hour", resetsAt: Date.UTC(2030, 0, 1, 5) });
    const text = await poolSection(
      { ...profile, pool: [...profile.pool, { model: "faux/faux-9", useFor: "" }] },
      "faux/faux-1",
      { models: () => models, limit: (ref) => availability.limit(ref) },
    );
    const line = (needle: string) => text.split("\n").find((entry) => entry.includes(needle)) ?? "";
    expect(line('"self"')).toContain(
      "API list price per 1M tokens: $2 input, $10 output, $0.2 cache read, $2.5 cache write",
    );
    expect(line('"self"')).toContain("272k context, 128k max output, input text+image, reasoning");
    // All-zero catalog prices are not presented as free, and never as "$0 input".
    expect(line('"faux/faux-2"')).toContain(
      "API price listed as $0 (free or unpriced; unverified)",
    );
    expect(line('"faux/faux-2"')).not.toContain("$0 input");
    expect(line('"faux/faux-3"')).toContain(
      "$1 input, $5 output, $0.1 cache read, $1.25 cache write",
    );
    expect(line('"faux/faux-3"')).toContain(
      "usage limit: 5-hour limit (faux account), resets 2030-01-01T05:00:00Z",
    );
    expect(line('"faux/faux-9"')).toContain("not in the model catalog");
    expect(line('"faux/faux-9"')).toContain("API price unknown (not in the catalog)");
    expect(line('"faux/faux-9"')).not.toContain("$");
    // Honest provenance: faux prices come from the provider, not a verified price list.
    expect(text).toContain("faux provider's own model list (not a verified price list)");
    expect(text).toContain(
      "Use them as a relative cost signal, also when comparing models you reach through a subscription; they are not an exact conversion to a subscription's allowance or charges.",
    );
    expect(text).not.toContain("say nothing about subscription");
    expect(text).not.toMatch(/quality|score/i);
  });
});
