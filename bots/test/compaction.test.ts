import type { Models } from "@earendil-works/pi-ai";
import { describe, expect, it } from "vitest";
import { NativeCompaction } from "../src/compaction/context.ts";

describe("compaction hook", () => {
  it("declines in the shape Pi Durable reads, so a compaction already done is not summarized again", async () => {
    const native = new NativeCompaction(() => ({}) as Models);
    const api = {
      conversationId: 1,
      taskId: 7,
      snapshot: async () => ({ covered: [], receipt: { taskId: 7, entryId: 3 } }),
    };
    const compaction = { reason: "manual", entries: [], messages: [], firstKept: 3 };
    // biome-ignore lint/suspicious/noExplicitAny: the hook's API and context, stood in for.
    const decision = await native.beforeCompact(compaction as any, api as any, {} as any);
    expect(decision).toEqual({ kind: "decline" });
  });
});
