import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { Bot } from "../src/bots.ts";
import {
  FORUM_OWED_TABLE,
  FORUM_POSTS_TABLE,
  FORUM_ROOMS_TABLE,
  FORUM_SEATS_TABLE,
  FORUM_UNANSWERED_TABLE,
} from "../src/storage/forum.ts";
import { type ForumTest, type Move, openForumTest, type Turn } from "./forum-helpers.ts";
import { tempDir } from "./helpers.ts";

/** Posts when the newest input holds `trigger`, once per turn; otherwise answers privately. */
const postsOn =
  (rules: Record<string, { on: string; post: string }>, otherwise = "noted") =>
  (turn: Turn): Move => {
    const rule = rules[turn.bot];
    if (rule && !turn.afterTool && turn.user.includes(rule.on)) return { post: rule.post };
    return { say: turn.afterTool ? "done" : otherwise };
  };

describe("a Forum reply a mentioned bot owes", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let t: ForumTest;
  let ada: Bot;
  let max: Bot;

  const start = async (options: Parameters<typeof openForumTest>[1] = {}) => {
    t = await openForumTest(dir.path, options);
    ada = await t.bot("Ada");
    max = await t.bot("Max");
  };

  beforeEach(async () => {
    dir = await tempDir();
  });

  afterEach(async () => {
    await t.close();
    await dir.cleanup();
  });

  it("is posted from its final message when it did not post itself", async () => {
    await start({
      brain: (turn) => ({ say: turn.bot === "Ada" ? "I am fixing the build." : "nothing to add" }),
    });
    const post = await t.forum.postAsUser({ text: "@Ada status?", mentions: [ada.id] });
    await t.settle();
    expect(post.mentions).toEqual([ada.id]);
    expect((await t.heard(ada))[0]).toBe(
      "[Forum] New posts:\n#1 The user: @Ada status?\n\nThe user mentioned you in #1: reply with forum_post.",
    );
    // Max was not mentioned: its answer stays private.
    expect(await t.log()).toEqual(["user: @Ada status?", "Ada: I am fixing the build."]);
    expect(t.posts.at(-1)).toMatchObject({ botId: ada.id, auto: true });
    expect(await t.forum.store.owed(1, ada.id)).toEqual([]);
    // The reply reached Max like any post.
    expect((await t.heard(max)).at(-1)).toBe("[Forum] New posts:\n#2 Ada: I am fixing the build.");
  });

  it("is settled without a repeat when it answered with forum_post", async () => {
    await start({ brain: postsOn({ Ada: { on: "status", post: "On it." } }, "private note") });
    await t.forum.postAsUser({ text: "@everyone status?", everyone: true });
    await t.settle();
    // Ada posted; Max's final message was posted for it.
    expect((await t.log()).sort()).toEqual(["Ada: On it.", "Max: private note", "user: @everyone status?"]);
    const autos = (await t.forum.store.postsAfter(1, 0)).filter((post) => post.auto);
    expect(autos.map((post) => post.name)).toEqual(["Max"]);
    expect([...((await t.forum.store.post(1))?.mentions ?? [])].sort()).toEqual([ada.id, max.id].sort());
  });

  it("is never posted once its thread is deleted, and the thread leaves nothing behind", async () => {
    // Ada takes a moment over the thread's question, so its turn is running at the delete.
    await start({
      brain: (turn) =>
        turn.user.includes("deep question")
          ? { say: "a late answer", after: new Promise((resolve) => setTimeout(resolve, 500)) }
          : { say: "noted" },
    });
    const root = await t.forum.postAsUser({ text: "a topic" });
    await t.settle();
    const thread = await t.forum.createThread(root.id);
    await t.forum.postAsUser({ roomId: thread.roomId, text: "@Ada deep question", mentions: [ada.id] });
    for (let tries = 0; !t.forum.thinking(thread.roomId).includes(ada.id); tries += 1) {
      if (tries > 200) throw new Error("Ada never started");
      await new Promise((resolve) => setTimeout(resolve, 10));
    }

    const main = await t.forum.store.mainRoom();
    await expect(t.forum.deleteThread(main.id)).rejects.toThrow("only threads can be deleted");
    await t.forum.deleteThread(thread.roomId);
    await t.settle();

    for (const [table, column] of [
      [FORUM_ROOMS_TABLE, "id"],
      [FORUM_POSTS_TABLE, "room_id"],
      [FORUM_SEATS_TABLE, "room_id"],
      [FORUM_OWED_TABLE, "room_id"],
    ] as const) {
      expect(await t.db.all(`SELECT * FROM ${table} WHERE ${column} = ?`, thread.roomId)).toEqual([]);
    }
    expect(await t.db.all(`SELECT * FROM ${FORUM_UNANSWERED_TABLE}`)).toEqual([]);
    expect(t.forum.thinking(thread.roomId)).toEqual([]);
    expect((await t.forum.state()).threads).toEqual([]);
    // The parent post stays in the Forum and can start a thread again.
    expect(await t.log()).toEqual(["user: a topic"]);
    expect((await t.forum.createThread(root.id)).roomId).not.toBe(thread.roomId);
    await expect(t.forum.deleteThread(thread.roomId)).rejects.toThrow(`no Forum room ${thread.roomId}`);
  });
});
