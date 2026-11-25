import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxToolCall,
} from "@earendil-works/pi-ai/providers/faux";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createBotHarnessOptions } from "../src/agent.ts";
import { BotManager } from "../src/bots.ts";
import { ProfileStore } from "../src/profiles.ts";
import { openSharedDatabase } from "../src/storage/database.ts";
import { tempDir } from "./helpers.ts";

const ctx = BACKGROUND_CONTEXT;

/** A faux provider with a reasoning model ("think", minimal…high). */
function models() {
  const faux = fauxProvider({
    tokensPerSecond: 5000,
    models: [{ id: "think", reasoning: true }],
  });
  const registry = createModels();
  registry.setProvider(faux.provider);
  return { faux, registry };
}

describe("reasoning levels", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  beforeEach(async () => {
    dir = await tempDir();
  });
  afterEach(async () => {
    await dir.cleanup();
  });

  it("follows profile edits, profile switches and default changes", async () => {
    const { registry } = models();
    const profiles = new ProfileStore({
      defaultId: "a",
      profiles: [
        { id: "a", name: "A", main: "faux/think", reasoning: "high", pool: [] },
        { id: "b", name: "B", main: "faux/think", reasoning: "low", pool: [] },
      ],
    });
    const db = await openSharedDatabase(join(dir.path, "bots.sqlite"));
    const manager = await BotManager.open({
      db,
      profiles,
      harnessOptions: (bot, self) =>
        createBotHarnessOptions({
          bot,
          models: registry,
          profile: () => profiles.resolve(self.assignedProfile(bot.id)),
        }),
    });
    const level = async (id: string) =>
      (await (await (await manager.get(id)).main()).agent(ctx)).thinkingLevel;
    try {
      const alpha = await manager.create("Alpha");
      const beta = await manager.create("Beta");
      expect(await level(alpha.id)).toBe("high");

      await profiles.save({ id: "a", name: "A", main: "faux/think", reasoning: "medium" });
      expect(await level(alpha.id)).toBe("medium");
      // A save without a level keeps the profile's level.
      await profiles.save({ id: "a", name: "A", main: "faux/think" });
      expect(profiles.get("a")?.reasoning).toBe("medium");

      await manager.setProfile(alpha.id, "b");
      expect(await level(alpha.id)).toBe("low");

      await profiles.setDefault("b");
      expect(await level(beta.id)).toBe("low");
    } finally {
      await manager.close();
      await db.close();
    }
  });

  it("runs the main model at the profile level and a subagent at the level it chose", async () => {
    const { faux, registry } = models();
    const seen: (string | undefined)[] = [];
    faux.setResponses([
      (_context, options) => {
        seen.push(options?.reasoning);
        return fauxAssistantMessage(
          [fauxToolCall("run_subagent", { model: "self", reasoning: "max", task: "Add 2 and 2." })],
          { stopReason: "toolUse" },
        );
      },
      (_context, options) => {
        seen.push(options?.reasoning);
        return fauxAssistantMessage([fauxText("4")]);
      },
      (_context, options) => {
        seen.push(options?.reasoning);
        return fauxAssistantMessage([fauxText("It is 4.")]);
      },
    ]);
    const profiles = new ProfileStore({
      defaultId: "a",
      profiles: [{ id: "a", name: "A", main: "faux/think", reasoning: "medium", pool: [] }],
    });
    const db = await openSharedDatabase(join(dir.path, "bots.sqlite"));
    const subagents: (string | undefined)[] = [];
    const manager = await BotManager.open({
      db,
      profiles,
      harnessOptions: (bot) =>
        createBotHarnessOptions({
          bot,
          models: registry,
          profile: () => profiles.resolve(undefined),
          onSubagent: (event) => {
            if (event.phase === "start") subagents.push(event.reasoning);
          },
        }),
    });
    try {
      const bot = await manager.get((await manager.create("Alpha")).id);
      const sent = await bot.send("What is 2 + 2?");
      await expect(sent.submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
      // Main turn, the subagent, the main turn's follow-up.
      expect(seen).toEqual(["medium", "max", "medium"]);
      expect(subagents).toEqual(["max"]);
    } finally {
      await manager.close();
      await db.close();
    }
  });
});
