import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { Bot, BotManager } from "../src/bots.ts";
import type { BotEnvironmentAdapter } from "../src/env.ts";
import { ForumError, nextScheduledAt } from "../src/forum.ts";
import { FORUM_SPEAKER, MemoryExtractor } from "../src/memory.ts";
import { RuntimeOperations } from "../src/operations.ts";
import type { ForumSchedule } from "../src/storage/forum.ts";
import { type ForumTest, type Move, openForumTest, type Turn } from "./forum-helpers.ts";
import { tempDir } from "./helpers.ts";

const ctx = BACKGROUND_CONTEXT;

/** Posts when the newest input holds `trigger`, once per turn; otherwise answers privately. */
const postsOn =
  (rules: Record<string, { on: string; post: string }>, otherwise = "noted") =>
  (turn: Turn): Move => {
    const rule = rules[turn.bot];
    if (rule && !turn.afterTool && turn.user.includes(rule.on)) return { post: rule.post };
    return { say: turn.afterTool ? "done" : otherwise };
  };

describe("the Forum", () => {
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

  it("seats every bot but Admin Bot, and a post reaches each of them once", async () => {
    await start();
    const admin = await t.manager.admin();
    const state = await t.forum.state();
    expect(Object.fromEntries(state.bots.map((bot) => [bot.botId, bot.active]))).toEqual({
      [admin?.id ?? ""]: false,
      [ada.id]: true,
      [max.id]: true,
    });
    expect(state.paused).toBe(false);

    const post = await t.forum.postAsUser({ text: "Good morning" });
    await t.settle();
    expect(post).toMatchObject({ id: 1, author: "user", text: "Good morning", name: "" });
    expect(await t.heard(ada)).toEqual(["[Forum] New posts:\n#1 The user: Good morning"]);
    expect(await t.heard(max)).toEqual(["[Forum] New posts:\n#1 The user: Good morning"]);
    // What a bot answers in its seat without forum_post stays there.
    expect(await t.log()).toEqual(["user: Good morning"]);
    expect(t.turns.map((turn) => turn.bot).sort()).toEqual(["Ada", "Max"]);
    // Admin Bot is out: it has no seat and heard nothing.
    expect(await t.forum.store.seatsOf(admin?.id ?? "")).toEqual([]);
  });

  it("tells a seat what the room is, with the user's name and the other bots", async () => {
    await start();
    await t.platform.setUserName?.("Trey");
    await t.forum.postAsUser({ text: "hello" });
    await t.settle();
    const adaTurn = t.turns.find((turn) => turn.bot === "Ada");
    expect(adaTurn?.json).toContain(
      "This conversation is your seat in the Forum: a group chat with Trey and one other bot: Max.",
    );
    expect(adaTurn?.json).toContain("staying quiet is fine");
    expect(adaTurn?.json).toContain("When Trey @mentions you, reply with forum_post.");
    expect(adaTurn?.json).toContain("The user's name is Trey.");
    expect(adaTurn?.user).toBe("[Forum] New posts:\n#1 Trey: hello");
    expect((await t.forum.store.post(1))?.name).toBe("Trey");
  });

  it("carries a bot's forum_post to everyone but its own seat", async () => {
    await start({ brain: postsOn({ Ada: { on: "anyone there", post: "Ada here." } }) });
    await t.forum.postAsUser({ text: "anyone there?" });
    await t.settle();
    expect(await t.log()).toEqual(["user: anyone there?", "Ada: Ada here."]);
    expect(await t.heard(ada)).toEqual(["[Forum] New posts:\n#1 The user: anyone there?"]);
    expect(await t.heard(max)).toEqual([
      "[Forum] New posts:\n#1 The user: anyone there?",
      "[Forum] New posts:\n#2 Ada: Ada here.",
    ]);
    expect(t.posts.map((post) => post.id)).toEqual([1, 2]);
    expect(t.posts[1]).toMatchObject({ author: "bot", botId: ada.id, name: "Ada" });
    expect(t.posts[1]?.auto).toBeUndefined();
  });

  it("posts a mentioned bot's final message when it did not post itself", async () => {
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

  it("does not repeat a mentioned bot that answered with forum_post", async () => {
    await start({ brain: postsOn({ Ada: { on: "status", post: "On it." } }, "private note") });
    await t.forum.postAsUser({ text: "@everyone status?", everyone: true });
    await t.settle();
    // Ada posted; Max's final message was posted for it.
    expect((await t.log()).sort()).toEqual(["Ada: On it.", "Max: private note", "user: @everyone status?"]);
    const autos = (await t.forum.store.postsAfter(1, 0)).filter((post) => post.auto);
    expect(autos.map((post) => post.name)).toEqual(["Max"]);
    expect([...((await t.forum.store.post(1))?.mentions ?? [])].sort()).toEqual([ada.id, max.id].sort());
  });

  it("notes on the user's post why a mentioned bot did not answer", async () => {
    await start({
      brain: (turn) =>
        turn.bot === "Ada" ? { error: "You have hit your ChatGPT usage limit." } : { say: "ok" },
    });
    await t.forum.postAsUser({ text: "@Ada?", mentions: [ada.id] });
    await t.settle();
    expect(await t.log()).toEqual(["user: @Ada?"]);
    const noted = t.posts.at(-1);
    expect(noted).toMatchObject({
      id: 1,
      unanswered: [
        { botId: ada.id, name: "Ada", reason: "You have hit your ChatGPT usage limit.", issue: "limit" },
      ],
    });
    expect(await t.forum.store.owed(1, ada.id)).toEqual([]);
    expect((await t.forum.snapshot()).posts[0]?.unanswered).toHaveLength(1);
  });

  it("posts the answer to the turn that was shown the mention, not a later turn's", async () => {
    // Each bot answers its first input in text, slowly, and has nothing to add after that.
    await start({
      tokensPerSecond: 40,
      brain: (turn) => ({
        say:
          turn.users.length === 1
            ? `${turn.bot}'s real answer, long enough to still be streaming when more arrives`
            : `${turn.bot} has nothing to add`,
      }),
    });
    await t.forum.postAsUser({ text: "@everyone status?", everyone: true });
    await t.forum.idle();
    // Arrives while both still answer: it starts a second turn in each seat.
    await t.forum.postAsUser({ text: "also: lunch?" });
    await t.settle();
    const log = await t.log();
    expect(log.filter((line) => line.includes("real answer")).sort()).toEqual([
      "Ada: Ada's real answer, long enough to still be streaming when more arrives",
      "Max: Max's real answer, long enough to still be streaming when more arrives",
    ]);
    expect(log.filter((line) => line.includes("nothing to add"))).toEqual([]);
    expect((await t.forum.snapshot()).posts[0]?.unanswered).toBeUndefined();
    expect(await t.forum.store.owed(1, ada.id)).toEqual([]);
  });

  it("settles a failed turn that left a later post queued, and hands that post out again", async () => {
    let fail!: () => void;
    const gate = new Promise<void>((resolve) => {
      fail = resolve;
    });
    await start({
      brain: (turn) =>
        turn.bot === "Ada" && turn.users.length === 1
          ? { error: "You have hit your ChatGPT usage limit.", after: gate }
          : { say: `${turn.bot} is fine` },
    });
    await t.forum.postAsUser({ text: "@Ada?", mentions: [ada.id] });
    await t.forum.idle();
    // Queued behind Ada's request, which then fails.
    await t.forum.postAsUser({ text: "second" });
    await t.forum.idle();
    fail();
    await t.settle();
    expect((await t.forum.snapshot()).posts[0]?.unanswered).toEqual([
      { botId: ada.id, name: "Ada", reason: "You have hit your ChatGPT usage limit.", issue: "limit" },
    ]);
    expect(await t.forum.store.owed(1, ada.id)).toEqual([]);
    expect(t.forum.thinking(1)).toEqual([]);
    expect((await ada.harness.inspect(ctx)).submissions).toEqual([]);
    // The post that was stuck behind the failure reached Ada in a turn of its own.
    expect((await t.heard(ada)).at(-1)).toBe("[Forum] New posts:\n#2 The user: second");
    expect(await t.log()).toEqual(["user: @Ada?", "user: second"]);
  });

  it("tells every client when a post changes the newest post", async () => {
    await start();
    await t.settle();
    const before = t.changes;
    await t.forum.postAsUser({ text: "hello" });
    expect(t.changes).toBe(before + 1);
    expect((await t.forum.state()).latestPostId).toBe(1);
    await t.settle();
  });

  it("drops mentions of bots that are not in the Forum", async () => {
    await start();
    const admin = await t.manager.admin();
    const post = await t.forum.postAsUser({
      text: "@Admin Bot and @Ada",
      mentions: [admin?.id ?? "", ada.id, "00000000-0000-4000-8000-000000000000"],
    });
    expect(post.mentions).toEqual([ada.id]);
    await t.settle();
  });

  it("gives a working bot the posts that queued together, at its next step", async () => {
    // Slow answers: two more posts arrive while each bot is still on the first.
    await start({ tokensPerSecond: 40, brain: () => ({ say: "a long enough answer to still be streaming" }) });
    await t.forum.postAsUser({ text: "one" });
    await t.forum.idle();
    await t.forum.postAsUser({ text: "two" });
    await t.forum.postAsUser({ text: "three" });
    await t.settle();
    const adaTurns = t.turns.filter((turn) => turn.bot === "Ada");
    // The second request saw both later posts: they were placed at one step, not one per turn.
    expect(adaTurns).toHaveLength(2);
    expect(adaTurns[1]?.users.slice(-2)).toEqual([
      "[Forum] New posts:\n#2 The user: two",
      "[Forum] New posts:\n#3 The user: three",
    ]);
    expect((await t.forum.store.seat(1, ada.id))?.cursor).toBe(3);
  });

  it("reports who is working in a room", async () => {
    await start();
    await t.forum.postAsUser({ text: "hello" });
    await t.settle();
    const rooms = new Set(t.thinking.map((event) => event.roomId));
    expect([...rooms]).toEqual([1]);
    expect(t.thinking.some((event) => event.botIds.includes(ada.id))).toBe(true);
    expect(t.thinking.at(-1)?.botIds).toEqual([]);
    expect(t.forum.thinking(1)).toEqual([]);
  });

  it("holds everything while paused and catches bots up on resume", async () => {
    await start();
    await t.forum.postAsUser({ text: "before" });
    await t.settle();
    expect((await t.forum.setPaused(true)).paused).toBe(true);
    await t.forum.postAsUser({ text: "during one" });
    await t.forum.postAsUser({ text: "@Ada during two", mentions: [ada.id] });
    await t.settle();
    expect(await t.heard(ada)).toHaveLength(1);
    await expect(
      t.forum.postAsBot(ada.id, { text: "hi", conversationId: (await ada.main()).id }),
    ).rejects.toThrow(ForumError);

    expect((await t.forum.setPaused(false)).paused).toBe(false);
    await t.settle();
    expect((await t.heard(ada)).at(-1)).toBe(
      "[Forum] While the Forum was paused you missed these posts:\n#2 The user: during one\n#3 The user: @Ada during two\n\nThe user mentioned you in #3: reply with forum_post.",
    );
    // One catch-up turn each, and Ada's owed reply was posted for it.
    expect((await t.log()).at(-1)).toBe("Ada: noted");
    expect((await t.heard(max)).slice(1)).toEqual([
      "[Forum] While the Forum was paused you missed these posts:\n#2 The user: during one\n#3 The user: @Ada during two",
      "[Forum] New posts:\n#4 Ada: noted",
    ]);
  });

  it("stops a running turn on pause and reminds the bot of the mention on resume", async () => {
    await start({ tokensPerSecond: 20, brain: () => ({ say: "a very long answer that will be cut off by the pause" }) });
    await t.forum.postAsUser({ text: "@Ada go", mentions: [ada.id] });
    await t.forum.idle();
    await t.forum.setPaused(true);
    await t.settle();
    // Stopped, not settled: nothing was posted for it and the reply is still owed.
    expect(await t.log()).toEqual(["user: @Ada go"]);
    expect(await t.forum.store.owed(1, ada.id)).toEqual([1]);
    expect(t.forum.thinking(1)).toEqual([]);

    t.setBrain(() => ({ say: "back now" }));
    await t.forum.setPaused(false);
    await t.settle();
    expect((await t.heard(ada)).at(-1)).toBe(
      "[Forum] You have not replied to the user's mention in #1 yet: reply with forum_post.",
    );
    expect(await t.log()).toEqual(["user: @Ada go", "Ada: back now"]);
    // Max owed nothing and missed nothing: no catch-up turn, only Ada's reply.
    expect((await t.heard(max)).slice(1)).toEqual(["[Forum] New posts:\n#2 Ada: back now"]);
  });

  it("holds a bot's seats during an environment update and tells the stopped one afterwards", async () => {
    await start({ tokensPerSecond: 20, brain: () => ({ say: "a very long answer that the update will cut off" }) });
    await t.forum.postAsUser({ text: "@Ada go", mentions: [ada.id] });
    await t.forum.idle();
    await t.forum.hold(ada.id);
    await t.forum.postAsUser({ text: "meanwhile" });
    await t.settle();
    // Held: its stopped turn is not settled, and the new post waits.
    expect(await t.heard(ada)).toHaveLength(1);
    expect(await t.forum.store.owed(1, ada.id)).toEqual([1]);
    expect((await t.heard(max)).at(-1)).toBe("[Forum] New posts:\n#2 The user: meanwhile");

    t.setBrain(() => ({ say: "picking it back up" }));
    await t.forum.release(ada.id, "[Your environment was updated.]");
    await t.settle();
    expect((await t.heard(ada)).at(-1)).toBe(
      "[Forum] [Your environment was updated.]\n\nNew posts:\n#2 The user: meanwhile\n\nYou have not replied to the user's mention in #1 yet: reply with forum_post.",
    );
    expect((await t.log()).at(-1)).toBe("Ada: picking it back up");
    // Max was not stopped: releasing it says nothing.
    await t.forum.hold(max.id);
    await t.forum.release(max.id, "[Your environment was updated.]");
    await t.settle();
    expect((await t.heard(max)).filter((input) => input.includes("environment was updated"))).toEqual([]);
  });

  it("releases every bot when an update fails part-way, and settles a turn that ended as it began", async () => {
    let answer!: () => void;
    const gate = new Promise<void>((resolve) => {
      answer = resolve;
    });
    await start({
      brain: (turn) => (turn.bot === "Ada" ? { say: "Ada's answer", after: gate } : { say: "ok" }),
    });
    const updated: string[] = [];
    const env = {
      kind: "none",
      updateBot: async (botId: string) => {
        updated.push(botId);
        return { botId, ok: true };
      },
    } as unknown as BotEnvironmentAdapter;
    const operations = new RuntimeOperations({ manager: t.manager, env, forum: t.forum });
    await t.forum.postAsUser({ text: "@Ada?", mentions: [ada.id] });
    await t.forum.idle();
    // The hold begins while Ada's turn is ending: its answer lands, but is not settled yet.
    const held = t.forum.hold(ada.id);
    answer();
    await held;
    await t.forum.release(ada.id, "[Updated.]");
    await t.settle();
    expect(await t.log()).toEqual(["user: @Ada?", "Ada: Ada's answer"]);

    // An update naming a bot that is gone fails after Ada was held: she must hear again.
    await expect(
      operations.update([ada.id, "00000000-0000-4000-8000-000000000000"]),
    ).rejects.toThrow("no bot");
    expect(updated).toEqual([]);
    await t.forum.postAsUser({ text: "still there?" });
    await t.settle();
    expect((await t.heard(ada)).at(-1)).toBe("[Forum] New posts:\n#3 The user: still there?");
    // And a whole update holds, updates and releases.
    await operations.update([ada.id]);
    expect(updated).toEqual([ada.id]);
    await t.forum.postAsUser({ text: "after the update" });
    await t.settle();
    expect((await t.heard(ada)).at(-1)).toBe("[Forum] New posts:\n#4 The user: after the update");
  });

  it("tells bots the user's name and that they are in the Forum, and Admin Bot asks for the name", async () => {
    await start({
      brain: (turn) =>
        turn.bot === "Admin Bot" && !turn.afterTool && turn.user.includes("call me")
          ? { tool: "set_user_name", args: { name: "Trey" } }
          : { say: "ok" },
    });
    const admin = await t.manager.get((await t.manager.admin())?.id ?? "");
    await (await ada.send("hi")).submission.wait(ctx);
    const first = t.turns.at(-1);
    expect(first?.json).toContain("You are in the Forum, a group chat the user and every bot here share.");
    expect(first?.json).not.toContain("The user's name is");
    expect(first?.json).not.toContain("forum_schedule");

    await (await admin.send("call me Trey")).submission.wait(ctx);
    const asked = t.turns.find((turn) => turn.bot === "Admin Bot");
    expect(asked?.json).toContain("You do not know the user's name yet. Ask what they would like to be called");
    // Admin Bot is out of the Forum: it is not told it is in it.
    expect(asked?.json).not.toContain("You are in the Forum");
    expect(await t.forum.userName()).toBe("Trey");
    await (await ada.send("hi again")).submission.wait(ctx);
    expect(t.turns.at(-1)?.json).toContain("The user's name is Trey.");
    expect(t.turns.at(-1)?.json).toContain("a group chat Trey and every bot here share");
  });

  it("switches a bot out and back in from the next post", async () => {
    await start();
    await t.forum.postAsUser({ text: "one" });
    await t.settle();
    const state = await t.forum.setBotActive(max.id, false);
    expect(state.bots.find((bot) => bot.botId === max.id)?.active).toBe(false);
    await t.forum.postAsUser({ text: "two", mentions: [max.id] });
    await t.settle();
    expect(await t.heard(max)).toHaveLength(1);
    expect((await t.forum.store.post(2))?.mentions).toEqual([]);
    await expect(
      t.forum.postAsBot(max.id, { text: "hi", conversationId: (await max.main()).id }),
    ).rejects.toThrow("You are not in the Forum");

    await t.forum.setBotActive(max.id, true);
    await t.forum.postAsUser({ text: "three" });
    await t.settle();
    // It starts from the next post: "two" is not delivered, and the same seat goes on.
    expect((await t.heard(max)).at(-1)).toBe("[Forum] New posts:\n#3 The user: three");
    expect(await t.heard(max)).toHaveLength(2);
    expect((await t.heard(ada)).at(-1)).toBe("[Forum] New posts:\n#3 The user: three");
  });

  it("lets the user switch Admin Bot in", async () => {
    await start();
    const admin = await t.manager.get((await t.manager.admin())?.id ?? "");
    await t.forum.setBotActive(admin.id, true);
    await t.forum.postAsUser({ text: "hello all" });
    await t.settle();
    expect(await t.heard(admin)).toEqual(["[Forum] New posts:\n#1 The user: hello all"]);
    const turn = t.turns.find((item) => item.bot === "Admin Bot");
    expect(turn?.json).toContain("forum_schedule");
    expect(turn?.json).toContain("these bots: Ada and Max");
  });

  it("starts a thread from a post with its author, and a mention adds a bot", async () => {
    await start({
      // Ada answers in the Forum only: a thread seat's first input repeats the Forum's posts.
      brain: postsOn({
        Ada: { on: "[Forum] New posts:\n#1 The user: plan?", post: "Ship Friday." },
        Max: { on: "@Max agree", post: "Agreed." },
      }),
      titles: { generate: async (text) => `About: ${text.slice(0, 12)}` },
    });
    await t.forum.postAsUser({ text: "plan?" });
    await t.settle();
    const thread = await t.forum.createThread(2);
    expect(thread).toMatchObject({ parentPostId: 2, replies: 0, botIds: [ada.id], preview: "Ship Friday." });
    // One thread per post.
    expect((await t.forum.createThread(2)).roomId).toBe(thread.roomId);
    await expect(t.forum.createThread(999)).rejects.toThrow("no Forum post");

    await t.forum.postAsUser({ roomId: thread.roomId, text: "why Friday?" });
    await t.settle();
    expect(await t.heard(ada, thread.roomId)).toEqual([
      `[Forum thread ${thread.roomId}] The user started this thread from a Forum post:\n#2 You: Ship Friday.\n\nForum posts just before it:\n#1 The user: plan?\n\nPosts in this thread:\n#3 The user: why Friday?`,
    ]);
    // Max is not in the thread and the Forum itself did not get the post.
    expect(await t.heard(max, thread.roomId)).toEqual([]);
    expect(await t.log()).toEqual(["user: plan?", "Ada: Ship Friday."]);
    expect((await t.forum.snapshot()).posts[1]?.thread).toEqual({ roomId: thread.roomId, replies: 1 });

    await t.forum.postAsUser({ roomId: thread.roomId, text: "@Max agree?", mentions: [max.id] });
    await t.settle();
    expect(await t.log(thread.roomId)).toEqual(["user: why Friday?", "user: @Max agree?", "Max: Agreed."]);
    expect((await t.heard(max, thread.roomId))[0]).toContain("Posts in this thread:\n#3 The user: why Friday?\n#4 The user: @Max agree?");
    const state = await t.forum.state();
    expect(state.threads).toHaveLength(1);
    expect(state.threads[0]).toMatchObject({
      roomId: thread.roomId,
      title: "About: why Friday?",
      preview: "why Friday?",
      replies: 3,
    });
    expect(state.threads[0]?.botIds.sort()).toEqual([ada.id, max.id].sort());
    const snapshot = await t.forum.snapshot(thread.roomId);
    expect(snapshot.parent).toMatchObject({ id: 2, name: "Ada" });
    expect(snapshot.posts.map((post) => post.id)).toEqual([3, 4, 5]);

    expect((await t.forum.setThreadPinned(thread.roomId, true)).pinned).toBe(true);
    await expect(t.forum.createThread(3)).rejects.toThrow("threads start from a Forum post");
    // Switched out, a bot leaves its threads.
    await t.forum.setBotActive(max.id, false);
    expect((await t.forum.state()).threads[0]?.botIds).toEqual([ada.id]);
  });

  it("posts from another conversation of the bot to the Forum and shows its seat later", async () => {
    await start({
      brain: (turn) =>
        turn.bot === "Ada" && !turn.afterTool && turn.user.includes("start the standup")
          ? { post: "Standup time." }
          : { say: "ok" },
    });
    const sent = await ada.send("start the standup in the Forum");
    await sent.submission.wait(ctx);
    await t.settle();
    expect(await t.log()).toEqual(["Ada: Standup time."]);
    expect(await t.heard(max)).toEqual(["[Forum] New posts:\n#1 Ada: Standup time."]);
    // Its own seat is not woken by its own post; it sees it with the next one.
    expect(await t.heard(ada)).toEqual([]);
    await t.forum.postAsUser({ text: "thanks" });
    await t.settle();
    expect(await t.heard(ada)).toEqual([
      "[Forum] New posts:\n#1 You (from another of your conversations): Standup time.\n#2 The user: thanks",
    ]);
  });

  it("reads a room back for a bot and refuses threads it is not in", async () => {
    await start({ brain: postsOn({ Ada: { on: "plan?", post: "Ship Friday." } }) });
    await t.forum.postAsUser({ text: "plan?" });
    await t.settle();
    const thread = await t.forum.createThread(2);
    const main = (await max.main()).id;
    const read = await t.forum.read(max.id, { conversationId: main });
    expect(read).toMatch(/^The Forum, posts #1 to #2:\n#1 The user \(.*\): plan\?\n#2 Ada \(.*\): Ship Friday\.$/);
    expect(await t.forum.read(ada.id, { conversationId: main, limit: 1 })).toMatch(
      /^The Forum, posts #2 to #2 \(earlier ones: forum_read with before 2\):\n#2 You /,
    );
    await expect(t.forum.read(max.id, { conversationId: main, threadId: thread.roomId })).rejects.toThrow(
      "You are not in that thread",
    );
    expect(await t.forum.read(ada.id, { conversationId: main, threadId: thread.roomId })).toBe(
      `Forum thread ${thread.roomId} has no posts.`,
    );
  });

  it("shows a bot that fell far behind the newest posts and a count", async () => {
    await start();
    await t.forum.setPaused(true);
    for (let index = 1; index <= 53; index += 1) await t.forum.postAsUser({ text: `post ${index}` });
    await t.forum.setPaused(false);
    await t.settle();
    const [input] = await t.heard(ada);
    expect(input).toContain(
      "[Forum] While the Forum was paused you missed these posts (the newest 50; 3 earlier ones are not shown, forum_read shows them):\n#4 The user: post 4\n",
    );
    expect(input?.split("\n")).toHaveLength(51);
    expect((await t.forum.store.seat(1, ada.id))?.cursor).toBe(53);
  });

  it("neither loses nor repeats posts across a restart", async () => {
    await start();
    await t.forum.postAsUser({ text: "one" });
    await t.settle();
    // As after a crash between handing the input over and recording it.
    await t.forum.store.setSeatCursor(1, ada.id, 0);
    // And a post that was stored but never handed out.
    await t.forum.setPaused(true);
    await t.forum.postAsUser({ text: "two" });
    await t.db.run("UPDATE pibot_notes SET text = '' WHERE name = 'forum.paused'");
    await t.reopen();
    ada = await t.manager.get(ada.id);
    max = await t.manager.get(max.id);
    await t.settle();
    expect(await t.heard(ada)).toEqual([
      "[Forum] New posts:\n#1 The user: one",
      "[Forum] New posts:\n#2 The user: two",
    ]);
    expect(await t.heard(max)).toEqual([
      "[Forum] New posts:\n#1 The user: one",
      "[Forum] New posts:\n#2 The user: two",
    ]);
    expect((await t.forum.state()).latestPostId).toBe(2);
  });

  it("keeps a deleted bot's posts, and a restored bot starts from the next post", async () => {
    await start({ brain: postsOn({ Max: { on: "one", post: "Max was here." } }) });
    await t.forum.postAsUser({ text: "one" });
    await t.settle();
    await t.manager.delete(max.id);
    await t.forum.postAsUser({ text: "two" });
    await t.settle();
    expect(await t.log()).toEqual(["user: one", "Max: Max was here.", "user: two"]);
    expect((await t.forum.state()).bots.map((bot) => bot.botId)).not.toContain(max.id);

    await t.manager.restore(max.id);
    max = await t.manager.get(max.id);
    await t.settle();
    await t.forum.postAsUser({ text: "three" });
    await t.settle();
    expect((await t.heard(max)).at(-1)).toBe("[Forum] New posts:\n#4 The user: three");
    expect(await t.heard(max)).toHaveLength(2);

    await t.manager.delete(max.id);
    await t.manager.purge(max.id);
    expect(await t.forum.store.seatsOf(max.id)).toEqual([]);
    expect((await t.forum.snapshot()).posts[1]).toMatchObject({ name: "Max", text: "Max was here." });
  });

  it("does not let a deleted bot's stopped turn finish after it is restored", async () => {
    let answer!: () => void;
    const gate = new Promise<void>((resolve) => {
      answer = resolve;
    });
    await start({
      brain: (turn) =>
        turn.bot === "Max" && !turn.afterTool && turn.user.includes("@Max one")
          ? { post: "late reply from Max", after: gate }
          : { say: "ok" },
    });
    await t.forum.postAsUser({ text: "@Max one", mentions: [max.id] });
    await t.forum.idle();
    await t.manager.delete(max.id);
    await t.forum.postAsUser({ text: "two" });
    await t.manager.restore(max.id);
    max = await t.manager.get(max.id);
    answer();
    await t.settle();
    expect(await t.log()).toEqual(["user: @Max one", "user: two"]);
    await t.forum.postAsUser({ text: "three" });
    await t.settle();
    expect((await t.heard(max)).at(-1)).toBe("[Forum] New posts:\n#3 The user: three");
  });

  it("says a mentioned bot has no model, and catches it up once it has one", async () => {
    let main = "";
    await start({ main: () => main });
    await t.forum.postAsUser({ text: "@Ada hello", mentions: [ada.id] });
    await t.settle();
    expect(t.turns).toEqual([]);
    expect((await t.forum.snapshot()).posts[0]?.unanswered).toEqual([
      { botId: ada.id, name: "Ada", reason: "No model selected yet. Choose one with Admin Bot or in Bot settings → Profiles." },
    ]);
    main = "faux/faux-1";
    // The seat follows the bot's model like its other conversations.
    expect(await ada.applyModel({ provider: "faux", modelId: "faux-1" })).toBe(2);
    await max.applyModel({ provider: "faux", modelId: "faux-1" });
    await t.forum.postAsUser({ text: "now?" });
    await t.settle();
    expect(await t.heard(ada)).toEqual([
      "[Forum] New posts:\n#1 The user: @Ada hello\n#2 The user: now?",
    ]);
  });

  it("counts a seat among the bot's own conversations for memory and bot messages", async () => {
    await start({
      brain: (turn) =>
        turn.bot === "Ada" && !turn.afterTool && turn.user.includes("ping max")
          ? { tool: "message_bot", args: { botId: max.id, text: "ping" } }
          : { say: "ok" },
    });
    await t.forum.postAsUser({ text: "ping max directly" });
    await t.settle();
    const seat = await t.forum.store.seat(1, ada.id);
    expect((await ada.memoryConversations()).map((item) => item.conversationId)).toContain(seat?.conversationId);
    expect((await ada.conversations()).map((item) => item.conversationId)).not.toContain(seat?.conversationId);
    // Memory extraction reads the seat, with its input marked as the group's, not the user's.
    const prompts: string[] = [];
    t.setBrain((turn) => {
      prompts.push(turn.user);
      return { say: "NONE" };
    });
    // The test manager has no profiles: name the extraction model directly.
    const manager = {
      get: (id: string) => t.manager.get(id),
      list: () => t.manager.list(),
      registry: t.manager.registry,
      memoryModels: () => ["faux/faux-1"],
    } as unknown as BotManager;
    const extractor = new MemoryExtractor({ manager, models: t.models, idleMs: 0 });
    await extractor.extract(ada.id);
    await extractor.close();
    expect(prompts.at(-1)).toContain(`${FORUM_SPEAKER}: [Forum] New posts:\n#1 The user: ping max directly`);
    // message_bot works from a seat: the direct message reached Max's main channel.
    const received: string[] = [];
    for await (const entry of max.ownEntries((await max.main()).id)) {
      const text = entry.model?.find((item) => item.role === "user")?.content;
      if (typeof text === "string") received.push(text);
    }
    expect(received).toEqual([`[Message from bot "Ada" (id ${ada.id})]\nping`]);
  });

  describe("scheduled posts", () => {
    const at = (iso: string) => Date.parse(iso);

    it("posts as the user at its time, once per day, with its mentions", async () => {
      let now = at("2026-11-18T14:59:30Z");
      await start({ now: () => now });
      const [saved] = await t.forum.saveSchedule({
        text: "Standup: what is everyone on?",
        everyone: true,
        repeat: "weekdays",
        time: "09:00",
        timeZone: "America/Chicago",
      });
      expect(saved).toMatchObject({ repeat: "weekdays", time: "09:00", everyone: true, nextAt: at("2026-11-18T15:00:00Z") });
      await t.forum.tick();
      expect(await t.log()).toEqual([]);
      now = at("2026-11-18T15:00:10Z");
      await t.forum.tick();
      await t.forum.tick();
      await t.settle();
      const posts = await t.forum.store.postsAfter(1, 0);
      expect(posts.filter((post) => post.author === "user")).toHaveLength(1);
      expect(posts[0]).toMatchObject({ scheduled: true, text: "Standup: what is everyone on?" });
      expect([...(posts[0]?.mentions ?? [])].sort()).toEqual([ada.id, max.id].sort());
      expect((await t.heard(ada))[0]).toContain("#1 The user (scheduled post): Standup");
      // Saturday: a weekday post does not fire. Monday: it does again.
      now = at("2026-11-21T15:00:10Z");
      await t.forum.tick();
      expect((await t.forum.store.postsAfter(1, 0)).filter((post) => post.scheduled)).toHaveLength(1);
      expect((await t.forum.schedules())[0]?.nextAt).toBe(at("2026-11-23T15:00:00Z"));
      now = at("2026-11-23T15:04:00Z");
      await t.forum.tick();
      await t.settle();
      expect((await t.forum.store.postsAfter(1, 0)).filter((post) => post.scheduled)).toHaveLength(2);
    });

    it("skips a repeating post missed by more than the grace period, and fires a one-time post late", async () => {
      let now = at("2026-11-18T10:00:00Z");
      await start({ now: () => now });
      await t.forum.saveSchedule({ text: "daily", repeat: "daily", time: "11:00", timeZone: "UTC" });
      await t.forum.saveSchedule({ text: "once", repeat: "once", at: at("2026-11-18T11:00:00Z"), timeZone: "UTC" });
      now = at("2026-11-18T13:00:00Z");
      await t.forum.tick();
      await t.settle();
      expect(await t.log()).toEqual(["user: once"]);
      // The one-time post is gone; the daily one waits for tomorrow.
      expect((await t.forum.schedules()).map((item) => item.text)).toEqual(["daily"]);
      await t.forum.saveSchedule({ text: "late night", repeat: "daily", time: "23:59", timeZone: "UTC" });
      now = at("2026-11-19T00:02:00Z");
      await t.forum.tick();
      await t.settle();
      // Due a minute before midnight, checked just after it: still fired.
      expect(await t.log()).toEqual(["user: once", "user: late night"]);
    });

    it("waits for the next day when saved or edited just after its time", async () => {
      let now = at("2026-11-18T09:03:00Z");
      await start({ now: () => now });
      const [saved] = await t.forum.saveSchedule({ text: "standup", repeat: "daily", time: "09:00", timeZone: "UTC" });
      expect(saved?.nextAt).toBe(at("2026-11-19T09:00:00Z"));
      await t.forum.tick();
      now = at("2026-11-18T09:04:00Z");
      await t.forum.saveSchedule({ id: saved?.id ?? "", text: "standup!", repeat: "daily", time: "09:00", timeZone: "UTC" });
      await t.forum.tick();
      expect(await t.log()).toEqual([]);
      now = at("2026-11-19T09:00:30Z");
      await t.forum.tick();
      await t.settle();
      expect(await t.log()).toEqual(["user: standup!"]);
    });

    it("fires a daily post once on the days clocks change", async () => {
      // 02:30 New York: skipped on 8 March 2026, shown twice on 1 November 2026.
      let now = at("2026-03-07T12:00:00Z");
      await start({ now: () => now });
      await t.forum.saveSchedule({ text: "night", repeat: "daily", time: "02:30", timeZone: "America/New_York" });
      const fired = async (from: string, to: string) => {
        const before = (await t.forum.store.postsAfter(1, 0)).length;
        for (now = at(from); now <= at(to); now += 60_000) await t.forum.tick();
        return (await t.forum.store.postsAfter(1, 0)).length - before;
      };
      expect(await fired("2026-03-08T05:00:00Z", "2026-03-08T09:00:00Z")).toBe(1);
      expect(await fired("2026-11-01T04:00:00Z", "2026-11-01T09:00:00Z")).toBe(1);
      await t.settle();
    });

    it("refuses schedules it could never fire, and removes them", async () => {
      await start();
      const base = { text: "x", timeZone: "UTC" } as const;
      await expect(t.forum.saveSchedule({ ...base, repeat: "daily" })).rejects.toThrow("HH:MM");
      await expect(t.forum.saveSchedule({ ...base, repeat: "daily", time: "25:00" })).rejects.toThrow("HH:MM");
      await expect(t.forum.saveSchedule({ ...base, repeat: "weekly", time: "09:00" })).rejects.toThrow("day of the week");
      await expect(t.forum.saveSchedule({ ...base, repeat: "once" })).rejects.toThrow("date and time");
      await expect(t.forum.saveSchedule({ ...base, repeat: "daily", time: "09:00", timeZone: "Mars/Olympus" })).rejects.toThrow("time zone");
      await expect(t.forum.saveSchedule({ ...base, id: "nope", repeat: "daily", time: "09:00" })).rejects.toThrow("no such scheduled post");
      const [saved] = await t.forum.saveSchedule({ ...base, repeat: "weekly", time: "09:00", weekday: 1 });
      const [edited] = await t.forum.saveSchedule({ ...base, id: saved?.id ?? "", text: "y", repeat: "daily", time: "10:30" });
      expect(edited).toMatchObject({ id: saved?.id, text: "y", repeat: "daily", time: "10:30" });
      expect(edited?.weekday).toBeUndefined();
      expect(await t.forum.deleteSchedule(saved?.id ?? "")).toEqual([]);
      await expect(t.forum.deleteSchedule("nope")).rejects.toThrow("no such scheduled post");
    });

    it("finds the next occurrence across a daylight-saving change", () => {
      const schedule: ForumSchedule = {
        id: "s",
        text: "x",
        mentions: [],
        everyone: false,
        repeat: "weekly",
        time: "09:00",
        weekday: 1,
        timeZone: "America/Chicago",
        createdAt: "",
      };
      // Monday 9:00 Central is 15:00 UTC in winter and 14:00 UTC in summer.
      expect(nextScheduledAt(schedule, at("2026-11-17T00:00:00Z"))).toBe(at("2026-11-23T15:00:00Z"));
      expect(nextScheduledAt(schedule, at("2026-03-07T00:00:00Z"))).toBe(at("2026-03-09T14:00:00Z"));
      expect(nextScheduledAt({ ...schedule, repeat: "once", at: 5 }, 10)).toBe(5);
    });

    it("lets Admin Bot manage them only while it is in the Forum", async () => {
      await start({
        brain: (turn) => {
          if (turn.bot !== "Admin Bot" || turn.afterTool) return { say: "ok" };
          if (turn.user.includes("schedule it")) {
            return {
              tool: "forum_schedule",
              args: { action: "add", text: "Weekly review", repeat: "weekly", time: "16:30", weekday: "Friday", timeZone: "UTC", mention: ["ada"] },
            };
          }
          return { say: "ok" };
        },
      });
      const admin = await t.manager.get((await t.manager.admin())?.id ?? "");
      const ask = async () => (await admin.send("schedule it")).submission.wait(ctx);
      await ask();
      expect(await t.forum.schedules()).toEqual([]);
      expect(t.turns.at(-1)?.json).toContain("You are not in the Forum");
      await t.forum.setBotActive(admin.id, true);
      await ask();
      expect(await t.forum.schedules()).toMatchObject([
        { text: "Weekly review", repeat: "weekly", time: "16:30", weekday: 5, timeZone: "UTC", mentions: [ada.id] },
      ]);
    });
  });
});
