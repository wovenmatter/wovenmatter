// Crash recovery, with faux models only: a run interrupted by a shutdown finishes after reopen
// without a new submit. Closing the manager mid-run stands in for a crash: Pi Durable keeps the
// live task in storage either way, and a hard kill loses no more than the in-flight request.
import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { describe, expect, it } from "vitest";
import type { Bot, RecoveryReport } from "../src/bots.ts";
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
});
