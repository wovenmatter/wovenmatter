import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxProvider } from "@earendil-works/pi-ai/providers/faux";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createBotHarnessOptions } from "../src/agent.ts";
import { BotManager, NO_MODEL_MESSAGE } from "../src/bots.ts";
import { normalizeProfiles, profilesToRaw } from "../src/config.ts";
import { ProfileError, ProfileStore } from "../src/profiles.ts";
import { parseSettings, SettingsStore } from "../src/settings/store.ts";
import { openSharedDatabase } from "../src/storage/database.ts";
import { parseTestSettings, tempDir } from "./helpers.ts";

const ctx = BACKGROUND_CONTEXT;
const legacy = {
  profiles: { default: { name: "Default", main: "faux/faux-1", memoryModel: "faux/faux-2" } },
  titles: { model: "faux/faux-2" },
};

describe("ProfileStore", () => {
  const store = () =>
    new ProfileStore(parseTestSettings(legacy).modelProfiles, {
      checkModel: (ref) => {
        if (!ref.startsWith("faux/")) throw new Error(`unknown model ${ref}`);
      },
    });

  it("validates, saves, removes and sets the default", async () => {
    const profiles = store();
    const changes: string[] = [];
    profiles.onChange((previous) => {
      changes.push(`${previous.profiles.length}->${profiles.list().length}`);
    });
    await expect(profiles.save({ id: "Bad Id", name: "x", main: "faux/faux-1" })).rejects.toThrow(
      ProfileError,
    );
    await expect(profiles.save({ id: "x", name: "x", main: "openai/gpt" })).rejects.toThrow(
      /unknown model/,
    );
    await expect(
      profiles.save({ id: "x", name: "x", main: "faux/faux-1", memoryModel: "openai/gpt" }),
    ).rejects.toThrow(/unknown model/);
    await expect(
      profiles.save({ id: "x", name: "x", main: "faux/faux-1", memoryModel: "nope" }),
    ).rejects.toThrow(/invalid model/);
    await expect(
      profiles.save({
        id: "x",
        name: "x",
        main: "faux/faux-1",
        pool: [{ model: "faux/faux-2" }, { model: "faux/faux-2" }],
      }),
    ).rejects.toThrow(/twice|duplicate/i);
    await profiles.save(
      { id: "fast", name: "Fast", main: "faux/faux-2", pool: [{ model: "faux/faux-1" }] },
      { create: true },
    );
    await expect(
      profiles.save({ id: "fast", name: "Fast", main: "faux/faux-2" }, { create: true }),
    ).rejects.toThrow(/already exists/);
    expect(profiles.get("fast")?.pool).toEqual([{ model: "faux/faux-1", useFor: "" }]);
    // No memory model: the active main model extracts. "" and null mean the same.
    expect(profiles.get("fast")?.memoryModel).toBeUndefined();
    const memory = await profiles.save({
      id: "fast",
      name: "Fast",
      main: "faux/faux-2",
      memoryModel: "faux/faux-3",
      pool: [{ model: "faux/faux-1" }],
    });
    expect(memory.memoryModel).toBe("faux/faux-3");
    // The memory model is never a pool model and never a subagent alias.
    expect(memory.pool).toEqual([{ model: "faux/faux-1", useFor: "" }]);
    for (const cleared of ["", null]) {
      expect(
        (
          await profiles.save({
            id: "fast",
            name: "Fast",
            main: "faux/faux-2",
            memoryModel: cleared,
          })
        ).memoryModel,
      ).toBeUndefined();
    }
    expect(profiles.resolve("missing").id).toBe("default");
    await expect(profiles.remove("default")).rejects.toThrow(/cannot be deleted/);
    await profiles.setDefault("fast");
    expect(profiles.resolve(undefined).id).toBe("fast");
    await profiles.remove("default");
    expect(profiles.list().map((profile) => profile.id)).toEqual(["fast"]);
    expect(changes).toEqual(["1->2", "2->2", "2->2", "2->2", "2->2", "2->1"]);
  });

  it("validates main-model fallbacks", async () => {
    const profiles = store();
    const save = (fallbacks: string[]) =>
      profiles.save({ id: "default", name: "Default", main: "faux/faux-1", fallbacks });
    await expect(save(["faux/faux-1"])).rejects.toThrow(/main model/);
    await expect(save(["faux/faux-2", "faux/faux-2"])).rejects.toThrow(/twice/);
    await expect(save(["openai/gpt"])).rejects.toThrow(/unknown model/);
    await expect(
      save(["faux/a", "faux/b", "faux/c", "faux/d", "faux/e", "faux/f"]),
    ).rejects.toThrow(/at most 5/);
    expect((await save(["faux/faux-2"])).fallbacks).toEqual(["faux/faux-2"]);
    expect((await save([])).fallbacks).toBeUndefined();
    expect(() =>
      parseTestSettings({ profiles: { p: { name: "P", main: "faux/a", fallbacks: ["faux/a"] } } }),
    ).toThrow(/fallbacks/);
  });

  it("persists profile changes to settings.json, keeping the other settings", async () => {
    const dir = await tempDir();
    try {
      const path = join(dir.path, "settings.json");
      const settings = await SettingsStore.open(path);
      await settings.update(() => parseSettings(legacy));
      const profiles = new ProfileStore(normalizeProfiles(settings.current), {
        persist: (set) =>
          settings.update((current) => ({ ...current, ...profilesToRaw(set) })).then(() => {}),
      });
      await profiles.save({
        id: "default",
        name: "Default",
        main: "faux/faux-1",
        fallbacks: ["faux/faux-3", "faux/faux-2"],
        memoryModel: "faux/faux-2",
        guidance: 'Say "hi"\nthen work.',
        pool: [{ model: "faux/faux-2", useFor: "Lookups" }],
      });
      await profiles.save({ id: "fast", name: "Fast", main: "faux/faux-2" }, { create: true });
      await profiles.setDefault("fast");
      const reopened = await SettingsStore.open(path);
      expect(normalizeProfiles(reopened.current)).toEqual(profiles.snapshot());
      expect(reopened.current.titles.model).toBe("faux/faux-2");
      expect(JSON.parse(await readFile(path, "utf8")).defaultProfile).toBe("fast");
      expect((await stat(path)).mode & 0o777).toBe(0o600);
    } finally {
      await dir.cleanup();
    }
  });
});

describe("bot profiles", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  beforeEach(async () => {
    dir = await tempDir();
  });
  afterEach(async () => {
    await dir.cleanup();
  });

  const open = async (path: string, profiles: ProfileStore) => {
    const faux = fauxProvider({ models: [{ id: "faux-1" }, { id: "faux-2" }] });
    const models = createModels();
    models.setProvider(faux.provider);
    const db = await openSharedDatabase(path);
    const manager = await BotManager.open({
      db,
      profiles,
      log: () => {},
      harnessOptions: (bot, self) =>
        createBotHarnessOptions({
          bot,
          models,
          profile: () => profiles.resolve(self.assignedProfile(bot.id)),
        }),
    });
    return {
      db,
      manager,
      close: async () => {
        await manager.close();
        await db.close();
      },
    };
  };
  const mainModel = async (manager: BotManager, id: string) =>
    (await (await (await manager.get(id)).main()).agent(ctx)).model;

  it("assigns profiles live, follows edits and falls back when a profile is deleted", async () => {
    const profiles = new ProfileStore(parseTestSettings(legacy).modelProfiles);
    const t = await open(join(dir.path, "db.sqlite"), profiles);
    try {
      const bot = await t.manager.create("Worker");
      expect(await mainModel(t.manager, bot.id)).toEqual({ provider: "faux", modelId: "faux-1" });
      await profiles.save({ id: "fast", name: "Fast", main: "faux/faux-2" }, { create: true });
      await t.manager.setProfile(bot.id, "fast");
      expect(t.manager.assignedProfile(bot.id)).toBe("fast");
      expect(await mainModel(t.manager, bot.id)).toEqual({ provider: "faux", modelId: "faux-2" });
      await expect(t.manager.setProfile(bot.id, "nope")).rejects.toThrow(/nope/);

      // Editing the default changes every bot on it.
      const other = await t.manager.create("Other");
      await profiles.save({ id: "default", name: "Default", main: "faux/faux-2" });
      expect(await mainModel(t.manager, other.id)).toEqual({ provider: "faux", modelId: "faux-2" });
      await profiles.save({ id: "default", name: "Default", main: "faux/faux-1" });

      const deleted = await t.manager.create("Deleted worker");
      await t.manager.setProfile(deleted.id, "fast");
      await t.manager.delete(deleted.id);
      await profiles.remove("fast");
      expect(
        (await t.manager.listDeleted()).find((item) => item.id === deleted.id)?.profile,
      ).toBeUndefined();
      await profiles.save(
        { id: "fast", name: "Replacement", main: "faux/faux-2" },
        { create: true },
      );
      await t.manager.restore(deleted.id);
      expect(await mainModel(t.manager, deleted.id)).toEqual({
        provider: "faux",
        modelId: "faux-1",
      });
      expect(t.manager.assignedProfile(bot.id)).toBeUndefined();
      expect((await t.manager.registry.get(bot.id))?.profile).toBeUndefined();
      expect(await mainModel(t.manager, bot.id)).toEqual({ provider: "faux", modelId: "faux-1" });
    } finally {
      await t.close();
    }
  });

  it("starts with no main model and refuses messages until one is chosen", async () => {
    const fresh = parseTestSettings({});
    expect(fresh.modelProfiles.profiles).toEqual([{ id: "default", name: "Default", pool: [] }]);
    expect(fresh.titles.model).toBeUndefined();
    expect(profilesToRaw(fresh.modelProfiles).profiles.default).not.toHaveProperty("main");
    const profiles = new ProfileStore(fresh.modelProfiles);
    await expect(
      profiles.save({ id: "default", name: "Default", fallbacks: ["faux/faux-2"] }),
    ).rejects.toThrow(/main model before/);
    const t = await open(join(dir.path, "db.sqlite"), profiles);
    try {
      const bot = await t.manager.get((await t.manager.create("Worker")).id);
      expect(await mainModel(t.manager, bot.id)).toBeUndefined();
      expect(t.manager.memoryModels(bot.id)).toEqual([]);
      await expect(bot.send("hello")).rejects.toThrow(NO_MODEL_MESSAGE);
      // Choosing one applies it to the bot's existing conversations.
      await profiles.save({ id: "default", name: "Default", main: "faux/faux-1" });
      expect(await mainModel(t.manager, bot.id)).toEqual({ provider: "faux", modelId: "faux-1" });
      await expect(bot.send("hello")).resolves.toBeDefined();
    } finally {
      await t.close();
    }
  });

  it("migrates a legacy per-bot model to a profile", async () => {
    const path = join(dir.path, "db.sqlite");
    const profiles = new ProfileStore(parseTestSettings(legacy).modelProfiles);
    const first = await open(path, profiles);
    const same = await first.manager.create("Same");
    const own = await first.manager.create("Admin Bot");
    await first.close();
    const db = await openSharedDatabase(path);
    await db.run("UPDATE pibot_bots SET model = 'faux/faux-1' WHERE id = ?", same.id);
    await db.run("UPDATE pibot_bots SET model = 'faux/faux-2' WHERE id = ?", own.id);
    await db.close();

    const second = await open(path, profiles);
    try {
      expect(profiles.list().map((profile) => profile.id)).toEqual(["default", "admin-bot"]);
      expect(profiles.get("default")?.memoryModel).toBe("faux/faux-2");
      expect(profiles.get("admin-bot")).toMatchObject({
        name: "Admin Bot",
        main: "faux/faux-2",
        memoryModel: "faux/faux-2",
        pool: profiles.get("default")?.pool,
      });
      expect(second.manager.assignedProfile(same.id)).toBeUndefined();
      expect(second.manager.assignedProfile(own.id)).toBe("admin-bot");
      expect((await second.manager.registry.get(own.id))?.legacyModel).toBeUndefined();
      expect(await mainModel(second.manager, own.id)).toEqual({
        provider: "faux",
        modelId: "faux-2",
      });
    } finally {
      await second.close();
    }
  });
});
