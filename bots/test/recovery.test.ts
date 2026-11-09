// Crash recovery, tested with faux models only (no real model keys): a run interrupted by a
// shutdown finishes after reopen without a new submit, and a fork the registry never recorded is
// adopted as a thread. Closing the manager mid-run stands in for a crash: Pi Durable keeps the
// live task in storage either way, and a hard kill loses no more than the in-flight request.
import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { fauxAssistantMessage, fauxProvider, fauxText } from "@earendil-works/pi-ai/providers/faux";
import { describe, expect, it } from "vitest";
import type { Bot, RecoveryReport } from "../src/bots.ts";
import { prefixedObjects } from "../src/storage/registry.ts";
import { TitleGenerator } from "../src/titles.ts";
import { displayEntry } from "../src/transcript.ts";
import { openTestManager, tempDir } from "./helpers.ts";

const ctx = BACKGROUND_CONTEXT;

async function transcript(bot: Bot, conversationId?: number) {
  const conversation = await bot.conversation(conversationId);
  const page = await conversation.entries({ order: "ascending" }, 200, undefined, ctx);
  return page.items.flatMap((entry) => {
    const shown = displayEntry(entry);
    return shown ? [`${shown.role}: ${shown.text}`] : [];
  });
}

async function until(check: () => Promise<boolean>, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!(await check())) {
    if (Date.now() > deadline) throw new Error("timed out");
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

describe("crash recovery", () => {
  it("preserves active bot-message rounds across queued inputs and restart", async () => {
    const dir = await tempDir();
    const path = join(dir.path, "rounds.sqlite");
    const first = await openTestManager(path, { tokensPerSecond: 2 });
    let second: Awaited<ReturnType<typeof openTestManager>> | undefined;
    try {
      const record = await first.manager.create("Round guard");
      const bot = await first.manager.get(record.id);
      const sent = await bot.send("active round", undefined, 4);
      await until(async () => (await sent.submission.status(ctx)).status === "placed");
      await bot.send("queued user reset", undefined, 0);
      expect(await bot.round(sent.conversation.id)).toBe(4);
      await first.close();
      second = await openTestManager(path, { tokensPerSecond: 2 });
      const reopened = await second.manager.get(record.id);
      expect(await reopened.round(sent.conversation.id)).toBe(4);
    } finally {
      await (second ?? first).close();
      await dir.cleanup();
    }
  });

  it("resumes an interrupted run on startup without a new submit", async () => {
    const dir = await tempDir();
    try {
      const path = join(dir.path, "bots.sqlite");
      // 2 tokens/s: the reply takes seconds, so the close lands mid-stream.
      const first = await openTestManager(path, { tokensPerSecond: 2 });
      const created = await first.manager.create("Ada");
      const bot = await first.manager.get(created.id);
      await bot.send("are you there");
      await until(async () => {
        const live = await bot.harness.inspect(ctx);
        return live.tasks.some((task) => task.state.kind === "running");
      });
      await first.close();

      const reports: RecoveryReport[] = [];
      const second = await openTestManager(path, {
        onRecovered: (_bot, report) => reports.push(report),
      });
      try {
        const reopened = await second.manager.get(created.id);
        const main = await reopened.main();
        expect(reports).toHaveLength(1);
        expect(reports[0]?.resumedConversations).toContain(main.id);
        // No submit and no wait call: startup resumed scheduling on its own.
        await until(async () => (await transcript(reopened)).length === 2);
        expect(await transcript(reopened)).toEqual([
          "user: are you there",
          "assistant: echo: are you there (n1)",
        ]);
        expect((await reopened.harness.inspect(ctx)).tasks).toHaveLength(0);
      } finally {
        await second.close();
      }
    } finally {
      await dir.cleanup();
    }
  });

  it("adopts a fork the registry never recorded as a thread", async () => {
    const dir = await tempDir();
    try {
      const path = join(dir.path, "bots.sqlite");
      const first = await openTestManager(path);
      const created = await first.manager.create("Ada");
      const bot = await first.manager.get(created.id);
      const { submission } = await bot.send("hello");
      await expect(submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
      const main = await bot.main();
      const last = (await main.entries({ order: "descending" }, 1, undefined, ctx)).items[0];
      if (!last) throw new Error("empty main");
      // The crash window: the fork is committed, the registry row is not.
      const orphan = await main.fork(last.id, { ownership: { kind: "ownerless" } }, ctx);
      const registered = await bot.fork({ entryId: last.id as unknown as number });
      expect((await bot.threads()).map((thread) => thread.conversationId)).toEqual([
        registered.conversationId,
      ]);
      await first.close();

      const reports: RecoveryReport[] = [];
      const second = await openTestManager(path, {
        onRecovered: (_bot, report) => reports.push(report),
      });
      try {
        const reopened = await second.manager.get(created.id);
        expect(reports[0]?.adoptedThreads).toEqual([orphan.id]);
        expect(reports[0]?.missingThreads).toEqual([]);
        const adopted = (await reopened.threads()).find(
          (thread) => thread.conversationId === orphan.id,
        );
        expect(adopted).toMatchObject({
          parentConversationId: main.id,
          forkedAt: last.id,
          title: "",
        });
        expect(await reopened.threads()).toHaveLength(2);
        // The adopted thread is a working thread: it inherits main and takes messages.
        const reply = await reopened.send("in the thread", orphan.id);
        await expect(reply.submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
        expect(await transcript(reopened, orphan.id)).toEqual([
          "user: hello",
          "assistant: echo: hello (n1)",
          "user: in the thread",
          "assistant: echo: in the thread (n2)",
        ]);
        await second.close();
        // Idempotent: a third open adopts nothing.
        const third = await openTestManager(path, {
          onRecovered: (_bot, report) => reports.push(report),
        });
        await third.manager.get(created.id);
        expect(reports[1]?.adoptedThreads).toEqual([]);
        await third.close();
      } catch (error) {
        await second.close().catch(() => {});
        throw error;
      }
    } finally {
      await dir.cleanup();
    }
  });

  it("restarts title generation for an untitled thread that has a first message", async () => {
    const dir = await tempDir();
    try {
      const path = join(dir.path, "bots.sqlite");
      // First run without a title model: the title request is lost, as in a crash.
      const first = await openTestManager(path);
      const created = await first.manager.create("Ada");
      const bot = await first.manager.get(created.id);
      const hello = await bot.send("hello");
      await hello.submission.wait(ctx);
      const main = await bot.main();
      const last = (await main.entries({ order: "descending" }, 1, undefined, ctx)).items[0];
      if (!last) throw new Error("empty main");
      const thread = await bot.fork({ entryId: last.id as unknown as number });
      const untitled = await bot.fork({ entryId: last.id as unknown as number });
      const sent = await bot.send("plan the trip to Lisbon", thread.conversationId);
      await sent.submission.wait(ctx);
      await first.close();

      const faux = fauxProvider({
        provider: "openai-codex",
        models: [{ id: "gpt-6-luna", reasoning: true }],
        tokensPerSecond: 100000,
      });
      const prompts: string[] = [];
      faux.setResponses(
        Array.from({ length: 5 }, () => (context) => {
          const message = context.messages.at(-1);
          prompts.push(typeof message?.content === "string" ? message.content : "");
          return fauxAssistantMessage([fauxText('{"title":"Lisbon trip"}')]);
        }),
      );
      const models = createModels();
      models.setProvider(faux.provider);
      const titles = new TitleGenerator({
        models,
        model: { provider: "openai-codex", modelId: "gpt-6-luna" },
        reasoning: "high",
      });
      const reports: RecoveryReport[] = [];
      const second = await openTestManager(path, {
        titles,
        onRecovered: (_bot, report) => reports.push(report),
      });
      try {
        await second.manager.get(created.id);
        expect(reports[0]?.retitledThreads).toEqual([thread.conversationId]);
        await second.manager.titles?.idle();
        const stored = await second.manager.registry.getThread(created.id, thread.conversationId);
        expect(stored?.title).toBe("Lisbon trip");
        expect(prompts).toHaveLength(1);
        expect(prompts[0]).toContain("plan the trip to Lisbon");
        // A thread without its own message stays untitled; nothing to title it from.
        const empty = await second.manager.registry.getThread(created.id, untitled.conversationId);
        expect(empty?.title).toBe("");
      } finally {
        await second.close();
      }
    } finally {
      await dir.cleanup();
    }
  });

  it("does not load or recover a deleted bot on restart, and keeps its tables", async () => {
    const dir = await tempDir();
    try {
      const path = join(dir.path, "bots.sqlite");
      const first = await openTestManager(path);
      const kept = await first.manager.create("Kept");
      const gone = await first.manager.create("Gone");
      const bot = await first.manager.get(gone.id);
      const sent = await bot.send("before delete");
      await sent.submission.wait(ctx);
      const tables = await prefixedObjects(first.db, gone.prefix);
      expect(await first.manager.delete(gone.id)).toBe(true);
      await first.close();

      const recovered: string[] = [];
      const second = await openTestManager(path, {
        onRecovered: (record) => recovered.push(record.id),
      });
      try {
        expect(recovered).toEqual([kept.id]);
        expect((await second.manager.list()).map((record) => record.id)).toEqual([kept.id]);
        await expect(second.manager.get(gone.id)).rejects.toThrow(/was deleted/);
        expect(recovered).toEqual([kept.id]);
        expect(await second.manager.delete(gone.id)).toBe(false);
        expect(await prefixedObjects(second.db, gone.prefix)).toEqual(tables);
      } finally {
        await second.close();
      }
    } finally {
      await dir.cleanup();
    }
  });
});
