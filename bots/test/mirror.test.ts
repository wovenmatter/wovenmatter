import type { EntryRecord } from "@earendil-works/pi-durable";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mirrorItems } from "../src/mirror.ts";
import type { BotSummary, MirrorBot, MirrorForum } from "../src/protocol.ts";
import { echoModels, tempDir } from "./helpers.ts";
import { startTestRuntime, type TestRuntime } from "./runtime.ts";
import { FakeServer, type HostHandlers } from "./ws-client.ts";

/** The server's side of the library copy: what it stored, and its checkpoints. */
class Library {
  readonly bots = new Map<string, MirrorBot[]>();
  readonly forum: MirrorForum[] = [];
  readonly purged: string[] = [];
  checkpoints: { bots: Record<string, number>; forum: number } = { bots: {}, forum: 0 };
  failPurge = false;

  handlers(): HostHandlers {
    return {
      credentials: () => ({ credential: null }),
      "tools.access": () => ({ allowed: false }),
      "mirror.checkpoints": () => structuredClone(this.checkpoints),
      "mirror.bot": (push) => {
        this.bots.set(push.bot.id, [...(this.bots.get(push.bot.id) ?? []), push]);
        this.checkpoints.bots[push.bot.id] = push.upTo;
        return {};
      },
      "mirror.forum": (push) => {
        this.forum.push(push);
        this.checkpoints.forum = push.upTo;
        return {};
      },
      "mirror.purge": ({ botId }) => {
        if (this.failPurge) throw new Error("library busy");
        this.purged.push(botId);
        delete this.checkpoints.bots[botId];
        return {};
      },
    };
  }

  /** Every item pushed for a bot, in push order. */
  items(botId: string) {
    return (this.bots.get(botId) ?? []).flatMap((push) => push.items);
  }
}

describe("the library copy", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let app: TestRuntime;
  let library: Library;
  let server: FakeServer;
  beforeEach(async () => {
    dir = await tempDir();
    library = new Library();
    app = await startTestRuntime(dir.path, {
      models: echoModels().models,
      mirror: { debounceMs: 10, sweepMs: 60_000 },
    });
    server = await FakeServer.open(app.socket, library.handlers());
  });
  afterEach(async () => {
    await server.close();
    await app.close();
    await dir.cleanup();
  });

  const say = async (botId: string, text: string, answer: string) => {
    await server.request("message.send", { botId, text });
    await server.until(() => library.items(botId).some((item) => item.text === answer));
  };

  it("pushes a bot's finished items once, above the server's checkpoint, and resends the same keys", async () => {
    const { bot } = await server.request<{ bot: BotSummary }>("bots.create", { name: "Ada" });
    await say(bot.id, "hello", "echo: hello (n1)");
    await say(bot.id, "again", "echo: again (n2)");
    const items = library.items(bot.id);
    expect(items.map((item) => [item.kind, item.text])).toEqual([
      ["user", "hello"],
      ["assistant", "echo: hello (n1)"],
      ["user", "again"],
      ["assistant", "echo: again (n2)"],
    ]);
    expect(new Set(items.map((item) => item.key)).size).toBe(4);
    const last = library.bots.get(bot.id)?.at(-1);
    expect(last).toMatchObject({
      bot: { id: bot.id, name: "Ada", kind: "bot", deleted: false },
      conversations: [{ conversationId: 1, kind: "main" }],
    });

    // A new connection asks for the checkpoints again: nothing above them, nothing sent.
    await server.close();
    server = await FakeServer.open(app.socket, library.handlers());
    await server.until(() => server.calls("mirror.checkpoints").length > 0);
    await app.mirror.sweep();
    expect(library.items(bot.id)).toHaveLength(4);

    // A server that lost its copy gets everything again, under the same keys.
    library.checkpoints.bots = {};
    await server.close();
    server = await FakeServer.open(app.socket, library.handlers());
    await server.until(() => library.items(bot.id).length === 8);
    expect(library.items(bot.id).slice(4).map((item) => item.key)).toEqual(items.map((item) => item.key));
  });

  it("pushes Forum posts above the Forum checkpoint, with the rooms", async () => {
    await server.request("forum.post", { text: "Good morning" });
    await server.until(() => library.forum.some((push) => push.posts.length > 0));
    await server.request("forum.post", { text: "Still there?" });
    await server.until(() => library.forum.flatMap((push) => push.posts).length === 2);
    const posts = library.forum.flatMap((push) => push.posts);
    expect(posts.map((post) => [post.id, post.author, post.text])).toEqual([
      [1, "user", "Good morning"],
      [2, "user", "Still there?"],
    ]);
    expect(library.forum.at(-1)).toMatchObject({ rooms: [{ roomId: 1 }], upTo: 2 });
  });

  it("drops a purged bot's copy, again on the next connection when the server could not", async () => {
    const { bot } = await server.request<{ bot: BotSummary }>("bots.create", { name: "Gone" });
    await say(bot.id, "hello", "echo: hello (n1)");
    await server.request("bots.delete", { botId: bot.id });
    await server.until(() => library.bots.get(bot.id)?.at(-1)?.bot.deleted === true);

    library.failPurge = true;
    await server.request("bots.purge", { botId: bot.id });
    expect(library.purged).toEqual([]);
    library.failPurge = false;
    await server.close();
    server = await FakeServer.open(app.socket, library.handlers());
    await server.until(() => library.purged.length === 1);
    expect(library.purged).toEqual([bot.id]);
  });
});

describe("library items", () => {
  const usage = { input: 10, output: 5, cacheRead: 2, cacheWrite: 1, totalTokens: 18, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0.25 } };
  const assistant = (content: unknown[], extra: Record<string, unknown> = {}) => ({
    role: "assistant",
    content,
    api: "faux",
    provider: "openai",
    model: "gpt-test",
    usage,
    stopReason: "toolUse",
    timestamp: 2000,
    ...extra,
  });
  const entry = (id: number, model: unknown[]): EntryRecord =>
    ({ id, conversationId: 1, kind: "pi.message", model }) as unknown as EntryRecord;

  it("gives each tool call its result, puts a turn's usage on its text, and holds a call until its result", () => {
    const user = entry(1, [{ role: "user", content: "list files", timestamp: 1000 }]);
    const call = entry(2, [
      assistant([
        { type: "text", text: "Looking." },
        { type: "toolCall", id: "c1", name: "bash", arguments: { command: "ls" } },
      ]),
    ]);
    const result = entry(3, [
      { role: "toolResult", toolCallId: "c1", toolName: "bash", content: [{ type: "text", text: "a.txt" }], isError: false, timestamp: 2500 },
    ]);
    const failed = entry(4, [assistant([], { stopReason: "error", errorMessage: "overloaded" })]);
    const stopped = entry(5, [assistant([{ type: "text", text: "Partial" }], { stopReason: "aborted", usage: { ...usage, input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } })]);

    expect(mirrorItems([user, call]).heldAt).toBe(2);
    expect(mirrorItems([user, call]).items.map((built) => built.item.key)).toEqual(["1"]);

    const { items, heldAt } = mirrorItems([user, call, result, failed, stopped]);
    expect(heldAt).toBeUndefined();
    expect(items.map((built) => built.item)).toEqual([
      { key: "1", conversationId: 1, createdAt: 1000, kind: "user", text: "list files" },
      {
        key: "2",
        conversationId: 1,
        createdAt: 2000,
        kind: "assistant",
        text: "Looking.",
        usage: { model: "openai/gpt-test", input: 10, output: 5, cacheRead: 2, cacheWrite: 1, cost: 0.25 },
      },
      {
        key: "2.1",
        conversationId: 1,
        createdAt: 2000,
        kind: "tool",
        tool: { name: "bash", input: '{"command":"ls"}', output: "a.txt", failed: false },
      },
      {
        key: "4",
        conversationId: 1,
        createdAt: 2000,
        kind: "error",
        text: "overloaded",
        usage: { model: "openai/gpt-test", input: 10, output: 5, cacheRead: 2, cacheWrite: 1, cost: 0.25 },
      },
      { key: "5", conversationId: 1, createdAt: 2000, kind: "assistant", text: "Partial" },
      { key: "5.1", conversationId: 1, createdAt: 2000, kind: "stopped" },
    ]);

    // A call the conversation moved on from without a result is a failed call.
    const next = entry(6, [{ role: "user", content: "never mind", timestamp: 3000 }]);
    const orphan = mirrorItems([call, next]).items.find((built) => built.item.kind === "tool");
    expect(orphan?.item.tool).toEqual({ name: "bash", input: '{"command":"ls"}', failed: true });
  });
});
