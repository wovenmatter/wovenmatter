import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ROOT_CONVERSATION_ID } from "@earendil-works/pi-durable";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { type Bot, BotRuleError, NotFoundError } from "../src/bots.ts";
import {
  BOTS_TABLE,
  MEMORY_TABLE,
  NOTES_TABLE,
  prefixedObjects,
  THREADS_TABLE,
} from "../src/storage/registry.ts";
import { displayEntry } from "../src/transcript.ts";
import { FAUX_MODEL, openTestManager, tempDir } from "./helpers.ts";

const ctx = BACKGROUND_CONTEXT;

describe("bot lifecycle", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  beforeEach(async () => {
    dir = await tempDir();
  });
  afterEach(async () => {
    await dir.cleanup();
  });

  it("creates and lists bots, each with a main-channel conversation", async () => {
    const t = await openTestManager(join(dir.path, "bots.sqlite"));
    try {
      expect(await t.manager.list()).toEqual([]);
      const alpha = await t.manager.create("  Alpha ");
      const beta = await t.manager.create("Beta");
      expect(alpha.name).toBe("Alpha");
      expect((await t.manager.list()).map((bot) => bot.name)).toEqual(["Alpha", "Beta"]);
      expect(beta.id).not.toBe(alpha.id);

      const main = await (await t.manager.get(alpha.id)).main();
      expect(main.id).toBe(ROOT_CONVERSATION_ID);
      // The default agent comes from the default profile's main model.
      expect((await main.agent(ctx)).model).toMatchObject(FAUX_MODEL);
    } finally {
      await t.close();
    }
  });

  it("soft-deletes: closes and evicts the harness, releases the env once, refuses messages", async () => {
    const released: string[] = [];
    const t = await openTestManager(join(dir.path, "bots.sqlite"), {
      onBotDeleted: async (record) => {
        released.push(record.id);
      },
    });
    try {
      const record = await t.manager.create("Alpha");
      const bot = await t.manager.get(record.id);
      expect(await t.manager.delete(record.id)).toBe(true);
      await expect(bot.harness.closed).resolves.toBeDefined();
      expect(released).toEqual([record.id]);
      await expect(t.manager.get(record.id)).rejects.toThrow(NotFoundError);
      await expect(t.manager.get(record.id)).rejects.toThrow(`bot ${record.id} was deleted`);
      expect(await t.manager.list()).toEqual([]);
      expect(await t.manager.delete(record.id)).toBe(false);
      expect(released).toEqual([record.id]);
      // Unknown bots keep their own error.
      await expect(t.manager.get("00000000-0000-4000-8000-000000000000")).rejects.toThrow(/no bot/);
    } finally {
      await t.close();
    }
  });

  it("restores a soft-deleted bot with its history and threads, ready to message", async () => {
    const path = join(dir.path, "bots.sqlite");
    const t = await openTestManager(path);
    let alphaId: string;
    let threadId: number;
    try {
      const alpha = await t.manager.create("Alpha");
      const beta = await t.manager.create("Beta");
      alphaId = alpha.id;
      const bot = await t.manager.get(alpha.id);
      const hello = await bot.send("hello");
      await expect(hello.submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
      const main = await bot.main();
      const last = (await main.entries({ order: "descending" }, 1, undefined, ctx)).items[0];
      if (!last) throw new Error("empty main");
      threadId = (await bot.fork({ entryId: last.id as unknown as number })).conversationId;
      const inThread = await bot.send("side note", threadId);
      await inThread.submission.wait(ctx);

      // Live bots are not restorable and never listed as deleted.
      expect(await t.manager.listDeleted()).toEqual([]);
      expect(await t.manager.restore(beta.id)).toBeUndefined();
      expect(await t.manager.restore("00000000-0000-4000-8000-000000000000")).toBeUndefined();

      expect(await t.manager.delete(alpha.id)).toBe(true);
      const deleted = await t.manager.listDeleted();
      expect(deleted).toEqual([expect.objectContaining({ id: alpha.id, name: "Alpha" })]);
      expect(deleted[0]?.deletedAt).toMatch(/^\d{4}-/);

      expect(await t.manager.restore(alpha.id)).toMatchObject({ id: alpha.id, name: "Alpha" });
      expect(await t.manager.restore(alpha.id)).toBeUndefined();
      expect(await t.manager.listDeleted()).toEqual([]);
      expect((await t.manager.list()).map((record) => record.name)).toEqual(["Alpha", "Beta"]);

      const restored = await t.manager.get(alpha.id);
      expect(restored.harness).not.toBe(bot.harness);
      expect(await texts(restored)).toEqual(["hello", "echo: hello (n1)"]);
      expect((await restored.threads()).map((thread) => thread.conversationId)).toEqual([threadId]);
      expect(await texts(restored, threadId)).toEqual([
        "hello",
        "echo: hello (n1)",
        "side note",
        "echo: side note (n2)",
      ]);
      const again = await restored.send("welcome back");
      await expect(again.submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
      expect((await texts(restored)).at(-1)).toBe("echo: welcome back (n2)");
    } finally {
      await t.close();
    }
    // A restored bot loads at startup like any other.
    const reopened = await openTestManager(path);
    try {
      expect((await reopened.manager.list()).map((record) => record.id)).toContain(alphaId);
      const bot = await reopened.manager.get(alphaId);
      expect((await texts(bot)).at(-1)).toBe("echo: welcome back (n2)");
      expect(await texts(bot, threadId)).toHaveLength(4);
    } finally {
      await reopened.close();
    }
  });

  it("deletes a thread at the source: its turn stops and a restart does not bring it back", async () => {
    const path = join(dir.path, "bots.sqlite");
    // 2 tokens/s: the thread's reply is still running when it is deleted.
    const t = await openTestManager(path, { tokensPerSecond: 2 });
    let botId: string;
    let threadId: number;
    try {
      const record = await t.manager.create("Alpha");
      botId = record.id;
      const bot = await t.manager.get(record.id);
      const main = await bot.main();
      await bot.send("hello");
      await bot.abort();
      const last = (await main.entries({ order: "descending" }, 1, undefined, ctx)).items[0];
      if (!last) throw new Error("empty main");
      threadId = (await bot.fork({ entryId: last.id as unknown as number })).conversationId;
      const sent = await bot.send("side note", threadId);
      for (let tries = 0; ; tries += 1) {
        const live = await bot.harness.inspect(ctx);
        if (live.tasks.some((task) => task.record.conversationId === threadId)) break;
        if (tries > 200) throw new Error("the thread's turn never started");
        await new Promise((resolve) => setTimeout(resolve, 20));
      }

      await expect(bot.deleteThread(main.id)).rejects.toThrow(BotRuleError);
      await bot.deleteThread(threadId);
      await expect(sent.submission.wait(ctx)).resolves.toMatchObject({ status: "unanswered" });
      expect(await bot.threads()).toEqual([]);
      await expect(bot.conversation(threadId)).rejects.toThrow(NotFoundError);
      await expect(bot.deleteThread(threadId)).rejects.toThrow(NotFoundError);
    } finally {
      await t.close();
    }
    // Pi Durable still holds the fork; startup reconciliation must not adopt it again.
    const reopened = await openTestManager(path);
    try {
      const bot = await reopened.manager.get(botId);
      expect(await bot.threads()).toEqual([]);
      await expect(bot.conversation(threadId)).rejects.toThrow(NotFoundError);
    } finally {
      await reopened.close();
    }
  });

  it("purges only a deleted bot, never Admin Bot: every row and table of it, nothing of the others", async () => {
    const purged: string[] = [];
    const t = await openTestManager(join(dir.path, "bots.sqlite"), {
      ensureAdmin: true,
      onBotPurged: async (botId) => {
        purged.push(botId);
        return { removed: true };
      },
    });
    try {
      const a = await t.manager.create("Alpha");
      const b = await t.manager.create("Beta");
      await t.manager.setManager(a.id, true);
      await t.manager.setTeam(b.id, a.id);
      const alpha = await t.manager.get(a.id);
      const sent = await alpha.send("remember me");
      await expect(sent.submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
      const main = await alpha.main();
      const last = (await main.entries({ order: "descending" }, 1, undefined, ctx)).items[0];
      if (!last) throw new Error("empty main");
      await alpha.fork({ entryId: last.id as unknown as number });
      const beta = await t.manager.get(b.id);
      await (await beta.send("hi")).submission.wait(ctx);
      await t.manager.registry.setNote("account", "plans");
      await t.manager.registry.updateMemory(a.id, () => ({
        facts: ["Alpha memory"],
        checkpoint: 1,
      }));
      await t.manager.registry.updateMemory(b.id, () => ({
        facts: ["Beta memory"],
        checkpoint: 2,
      }));
      const betaObjects = await prefixedObjects(t.db, b.prefix);
      const betaThreads = await t.manager.registry.listThreads(b.id);

      // Live bots and Admin Bot are refused; nothing is touched.
      await expect(t.manager.purge(a.id)).rejects.toThrow(BotRuleError);
      const admin = await t.manager.admin();
      if (!admin) throw new Error("no admin");
      await expect(t.manager.purge(admin.id)).rejects.toThrow(BotRuleError);
      expect((await prefixedObjects(t.db, a.prefix)).length).toBeGreaterThan(0);

      await t.manager.delete(a.id);
      await alpha.harness.closed;
      expect(await t.manager.purge(a.id)).toEqual({
        tables: expect.any(Number),
        environment: { removed: true },
      });
      expect(purged).toEqual([a.id]);
      expect(await t.db.all(`SELECT * FROM ${MEMORY_TABLE} WHERE bot_id = ?`, a.id)).toEqual([]);
      expect((await t.manager.registry.memory(b.id)).facts).toEqual(["Beta memory"]);

      // Every table under its prefix, its thread rows and its registry row are gone.
      expect(await prefixedObjects(t.db, a.prefix)).toEqual([]);
      expect(await t.db.all(`SELECT * FROM ${THREADS_TABLE} WHERE bot_id = ?`, a.id)).toEqual([]);
      expect(await t.db.all(`SELECT * FROM ${BOTS_TABLE} WHERE id = ?`, a.id)).toEqual([]);
      expect(await t.db.all(`SELECT id FROM ${BOTS_TABLE} WHERE manager_id = ?`, a.id)).toEqual([]);
      expect(await t.manager.listDeleted()).toEqual([]);
      await expect(t.manager.get(a.id)).rejects.toThrow(NotFoundError);
      expect(await t.manager.restore(a.id)).toBeUndefined();
      await expect(t.manager.purge(a.id)).rejects.toThrow(NotFoundError);

      // Other bots and shared tables are untouched, and Beta still works.
      expect(await prefixedObjects(t.db, b.prefix)).toEqual(betaObjects);
      expect(await t.manager.registry.listThreads(b.id)).toEqual(betaThreads);
      expect((await t.manager.list()).map((bot) => bot.name)).toEqual(["Admin Bot", "Beta"]);
      expect(await t.manager.registry.note("account")).toMatchObject({ text: "plans" });
      expect(await t.db.get(`SELECT count(*) AS n FROM ${NOTES_TABLE}`)).toEqual({ n: 1 });
      const again = await beta.send("still here?");
      await expect(again.submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
    } finally {
      await t.close();
    }
  });
});

async function texts(bot: Bot, conversationId?: number): Promise<string[]> {
  const conversation = await bot.conversation(conversationId);
  const page = await conversation.entries({ order: "ascending" }, 200, undefined, ctx);
  return page.items.flatMap((entry) => {
    const shown = displayEntry(entry);
    return shown ? [shown.text] : [];
  });
}
