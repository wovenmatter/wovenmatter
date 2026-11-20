import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { Bot } from "../src/bots.ts";
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
});
