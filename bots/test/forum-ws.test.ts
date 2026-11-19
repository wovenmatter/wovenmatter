import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type {
  ForumPost,
  ForumRoomSnapshot,
  ForumScheduleSummary,
  ForumState,
  ForumThreadSummary,
  ServerMessage,
} from "../src/protocol.ts";
import { echoModels, tempDir } from "./helpers.ts";
import { openClient, startTestRuntime, type TestRuntime } from "./runtime.ts";
import type { Client } from "./ws-client.ts";

const isPost = (id: number, check: (post: ForumPost) => boolean = () => true) =>
  (message: ServerMessage) => message.type === "forum.post" && message.post.id === id && check(message.post);

describe("the Forum over the websocket", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let app: TestRuntime;
  let client: Client;
  let other: Client;
  let botId: string;

  beforeEach(async () => {
    dir = await tempDir();
    app = await startTestRuntime(dir.path, { models: echoModels().models });
    client = await openClient(app.url);
    other = await openClient(app.url);
    botId = (await client.request<{ bot: { id: string } }>("bots.create", { name: "Ada" })).bot.id;
  });

  afterEach(async () => {
    client.close();
    other.close();
    await app.close();
    await dir.cleanup();
  });

  it("announces the Forum and serves its state", async () => {
    const hello = await client.waitFor<Extract<ServerMessage, { type: "hello" }>>(
      (message) => message.type === "hello",
    );
    expect(hello.capabilities).toEqual(expect.arrayContaining(["forum", "user.name"]));
    const state = await client.request<ForumState>("forum.get");
    const admin = (await app.manager.admin())?.id;
    expect(state).toEqual({
      mainRoomId: 1,
      paused: false,
      latestPostId: 0,
      bots: expect.arrayContaining([
        { botId: admin, active: false },
        { botId, active: true },
      ]),
      threads: [],
    });
  });

  it("pushes posts, who is working and forced replies to a room's subscribers only", async () => {
    const opened = await client.request<ForumRoomSnapshot>("forum.open");
    expect(opened).toMatchObject({ roomId: 1, mainRoomId: 1, posts: [], hasEarlier: false, thinking: [] });
    expect(opened.subscriptionId).toBeDefined();

    const { post } = await client.request<{ post: ForumPost }>("forum.post", {
      text: "@Ada hello",
      mentions: [botId],
    });
    expect(post).toMatchObject({ id: 1, roomId: 1, author: "user", mentions: [botId] });
    await client.waitFor(isPost(1));
    await client.waitFor(
      (message) => message.type === "forum.thinking" && message.roomId === 1 && message.botIds.includes(botId),
    );
    // The echo model answers in its seat without posting; the mention makes that its reply.
    const reply = await client.waitFor<Extract<ServerMessage, { type: "forum.post" }>>(isPost(2));
    expect(reply.post).toMatchObject({ author: "bot", botId, name: "Ada", auto: true });
    expect(reply.post.text).toContain("echo: [Forum] New posts:\n#1 The user: @Ada hello");
    await client.waitFor(
      (message) => message.type === "forum.thinking" && message.roomId === 1 && message.botIds.length === 0,
    );
    // A client that did not open the room gets none of it.
    expect(
      other.messages.filter((message) => message.type === "forum.post" || message.type === "forum.thinking"),
    ).toEqual([]);

    expect(await client.request("forum.posts", { roomId: 1, before: 2 })).toMatchObject({
      posts: [{ id: 1 }],
      hasEarlier: false,
    });
    expect(await client.request("forum.posts", { roomId: 1, before: 3, limit: 1 })).toMatchObject({
      posts: [{ id: 2 }],
      hasEarlier: true,
    });
    const reopened = await other.request<ForumRoomSnapshot>("forum.open", { roomId: 1 });
    expect(reopened.posts.map((item) => item.id)).toEqual([1, 2]);

    expect(await client.request("forum.close", { roomId: 1, subscriptionId: "stale" })).toEqual({ closed: false });
    expect(await client.request("forum.close", { roomId: 1, subscriptionId: opened.subscriptionId })).toEqual({
      closed: true,
    });
    await client.request("forum.post", { text: "after close" });
    await other.waitFor(isPost(3));
    expect(client.messages.some(isPost(3))).toBe(false);
  });

  it("accepts a retried post once", async () => {
    const first = await client.request<{ post: ForumPost }>("forum.post", { text: "once", deliveryId: "d-1" });
    expect(first.post.id).toBe(1);
    expect(await client.request("forum.post", { text: "once", deliveryId: "d-1" })).toEqual({ duplicate: true });
    expect((await client.request<ForumState>("forum.get")).latestPostId).toBe(1);
  });

  it("starts, pins and lists threads, and tells every client the state changed", async () => {
    await client.request("forum.open");
    await client.request("forum.post", { text: "topic" });
    const { thread } = await client.request<{ thread: ForumThreadSummary }>("forum.thread.create", { postId: 1 });
    expect(thread).toMatchObject({ roomId: 2, parentPostId: 1, replies: 0, preview: "topic", botIds: [] });
    await other.waitFor((message) => message.type === "forum.changed");
    // The parent post now names its thread.
    await client.waitFor(isPost(1, (item) => item.thread?.roomId === 2));

    const room = await other.request<ForumRoomSnapshot>("forum.open", { roomId: 2 });
    expect(room).toMatchObject({ roomId: 2, mainRoomId: 1, parent: { id: 1, text: "topic" }, posts: [] });
    await client.request("forum.post", { roomId: 2, text: "@Ada join", mentions: [botId] });
    await other.waitFor(isPost(2));
    await client.waitFor(isPost(1, (item) => item.thread?.replies === 1));
    const pinned = await client.request<{ thread: ForumThreadSummary }>("forum.thread.setPinned", {
      roomId: 2,
      pinned: true,
    });
    expect(pinned.thread).toMatchObject({ pinned: true, botIds: [botId] });
    await expect(client.request("forum.open", { roomId: 99 })).rejects.toThrow("no Forum room 99");
    await expect(client.request("forum.thread.setPinned", { roomId: 1, pinned: true })).rejects.toThrow(
      "only threads can be pinned",
    );
  });

  it("pauses, switches bots and keeps scheduled posts", async () => {
    expect((await client.request<ForumState>("forum.setPaused", { paused: true })).paused).toBe(true);
    await other.waitFor((message) => message.type === "forum.changed");
    expect((await client.request<ForumState>("forum.setPaused", { paused: false })).paused).toBe(false);
    const state = await client.request<ForumState>("forum.setBotActive", { botId, active: false });
    expect(state.bots.find((bot) => bot.botId === botId)?.active).toBe(false);

    const saved = await client.request<{ schedules: ForumScheduleSummary[] }>("forum.schedules.save", {
      schedule: { text: "Morning", repeat: "daily", time: "08:30", timeZone: "Europe/Berlin", everyone: true },
    });
    expect(saved.schedules).toMatchObject([
      { text: "Morning", repeat: "daily", time: "08:30", timeZone: "Europe/Berlin", everyone: true },
    ]);
    expect(saved.schedules[0]?.nextAt).toBeGreaterThan(Date.now());
    expect(await client.request("forum.schedules.list")).toEqual(saved);
    expect(await client.request("forum.schedules.delete", { scheduleId: saved.schedules[0]?.id })).toEqual({
      schedules: [],
    });
    await expect(
      client.request("forum.schedules.save", { schedule: { text: "x", repeat: "daily", timeZone: "UTC" } }),
    ).rejects.toThrow("HH:MM");
  });

  it("saves the user's name and tells every client", async () => {
    expect(await client.request("user.get")).toEqual({ name: "" });
    expect(await client.request("user.setName", { name: "  Trey  " })).toEqual({ name: "Trey" });
    await other.waitFor((message) => message.type === "user.changed");
    expect(await other.request("user.get")).toEqual({ name: "Trey" });
    const { post } = await client.request<{ post: ForumPost }>("forum.post", { text: "hi" });
    expect(post.name).toBe("Trey");
    expect(await client.request("user.setName", { name: "" })).toEqual({ name: "" });
  });
});
