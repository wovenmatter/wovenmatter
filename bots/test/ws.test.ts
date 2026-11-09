import { fauxAssistantMessage, fauxProvider, fauxText } from "@earendil-works/pi-ai/providers/faux";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { ConversationSnapshot, ServerMessage } from "../src/protocol.ts";
import { echoModels, tempDir } from "./helpers.ts";
import { openClient, startTestRuntime, TEST_TOKEN, type TestRuntime, testSettings } from "./runtime.ts";
import { Client } from "./ws-client.ts";

const isFinalEntry = (conversationId: number, text: string) => (message: ServerMessage) =>
  message.type === "event" &&
  message.conversationId === conversationId &&
  message.event.kind === "entry" &&
  message.event.entry.role === "assistant" &&
  message.event.entry.text === text;

describe("websocket server", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let app: TestRuntime;
  let wsUrl: string;

  beforeEach(async () => {
    dir = await tempDir();
    app = await startTestRuntime(dir.path, { models: echoModels(15).models });
    wsUrl = app.url;
  });

  afterEach(async () => {
    await app.close();
    await dir.cleanup();
  });

  it("replaces overlapping watches without duplicating streamed text", async () => {
    const client = await openClient(wsUrl);
    try {
      const { bot } = await client.request<{ bot: { id: string } }>("bots.create", {
        name: "Concurrent",
      });
      const opened = await Promise.all(
        Array.from({ length: 4 }, () =>
          client.request<ConversationSnapshot>("conversation.open", { botId: bot.id }),
        ),
      );
      const id = opened[0]?.conversationId;
      if (id === undefined) throw new Error("no conversation");
      const latest = await client.request<ConversationSnapshot>("conversation.open", {
        botId: bot.id,
      });
      expect(
        await client.request("conversation.close", {
          botId: bot.id,
          conversationId: id,
          subscriptionId: opened[0]?.subscriptionId,
        }),
      ).toEqual({ closed: false });
      expect(latest.subscriptionId).toBeDefined();
      await client.request("message.send", { botId: bot.id, text: "one reply" });
      await client.waitFor(isFinalEntry(id, "echo: one reply (n1)"));
      const text = client
        .events(id)
        .flatMap((event) =>
          event.kind === "assistant_start" || event.kind === "delta" ? [event.text] : [],
        )
        .join("");
      expect(text.length).toBeGreaterThan(0);
      expect("echo: one reply (n1)".startsWith(text)).toBe(true);
    } finally {
      client.close();
    }
  });

  it("keeps Main and a thread subscribed independently, and broadcasts persistent pin changes", async () => {
    const client = await openClient(wsUrl);
    const other = await openClient(wsUrl);
    try {
      const { bot } = await client.request<{ bot: { id: string } }>("bots.create", {
        name: "Two panes",
      });
      const main = await client.request<ConversationSnapshot>("conversation.open", {
        botId: bot.id,
      });
      await client.request("message.send", { botId: bot.id, text: "root" });
      await client.waitFor(isFinalEntry(main.conversationId, "echo: root (n1)"));
      const loaded = await client.request<ConversationSnapshot>("conversation.open", {
        botId: bot.id,
      });
      const root = loaded.entries[1];
      if (!root) throw new Error("missing root");
      const { thread } = await client.request<{ thread: { conversationId: number } }>(
        "thread.fork",
        { botId: bot.id, entryId: root.id },
      );
      const opened = await client.request<ConversationSnapshot>("conversation.open", {
        botId: bot.id,
        conversationId: thread.conversationId,
      });
      expect(opened.threadOrigin).toEqual(root);
      await client.request("message.send", { botId: bot.id, text: "main live" });
      await client.waitFor(isFinalEntry(main.conversationId, "echo: main live (n2)"));
      await client.request("message.send", {
        botId: bot.id,
        conversationId: thread.conversationId,
        text: "thread live",
      });
      await client.waitFor(isFinalEntry(thread.conversationId, "echo: thread live (n2)"));
      expect(
        await client.request("thread.setPinned", {
          botId: bot.id,
          conversationId: thread.conversationId,
          pinned: true,
        }),
      ).toMatchObject({ thread: { pinned: true } });
      await other.waitFor(
        (message) => message.type === "threads.changed" && message.botId === bot.id,
      );
      expect(await other.request("threads.list", { botId: bot.id })).toMatchObject({
        threads: [{ conversationId: thread.conversationId, pinned: true }],
      });
      await expect(
        client.request("thread.setPinned", {
          botId: bot.id,
          conversationId: main.conversationId,
          pinned: true,
        }),
      ).rejects.toThrow("Thread not found");
      await client.request("conversation.close", {
        botId: bot.id,
        conversationId: thread.conversationId,
        subscriptionId: opened.subscriptionId,
      });
      await client.request("message.send", { botId: bot.id, text: "main still live" });
      await client.waitFor(isFinalEntry(main.conversationId, "echo: main still live (n3)"));
    } finally {
      client.close();
      other.close();
    }
  });

  it("streams replies, reloads history, and forks threads", async () => {
    const client = await openClient(wsUrl);
    await client.waitFor((message) => message.type === "hello");

    const { bot } = await client.request<{ bot: { id: string; name: string; createdAt: string } }>(
      "bots.create",
      {
        name: "Scout",
      },
    );
    // Admin Bot always exists and is listed first (oldest).
    expect((await client.request<{ bots: { id: string }[] }>("bots.list")).bots).toEqual([
      expect.objectContaining({ name: "Admin Bot", kind: "admin", manager: false }),
      expect.objectContaining({ id: bot.id, name: "Scout", kind: "bot", manager: false }),
    ]);

    const main = await client.request<ConversationSnapshot>("conversation.open", {
      botId: bot.id,
    });
    expect(main.entries).toEqual([]);
    expect(main.conversationId).toBe(main.mainConversationId);

    await client.request("message.send", { botId: bot.id, text: "hello" });
    await client.waitFor(isFinalEntry(main.conversationId, "echo: hello (n1)"));
    const events = client.events(main.conversationId);
    const kinds = events.map((event) => event.kind);
    expect(kinds).toContain("assistant_start");
    expect(kinds).toContain("delta");
    const streamed = events.flatMap((event) =>
      event.kind === "delta" || event.kind === "assistant_start" ? [event.text] : [],
    );
    // Partials are published every 100 ms; the final entry is authoritative.
    expect(streamed.join("").length).toBeGreaterThan(0);
    expect("echo: hello (n1)".startsWith(streamed.join(""))).toBe(true);

    await client.request("message.send", { botId: bot.id, text: "second" });
    await client.waitFor(isFinalEntry(main.conversationId, "echo: second (n2)"));

    // A fresh connection sees the persisted history.
    const other = await openClient(wsUrl);
    const reloaded = await other.request<ConversationSnapshot>("conversation.open", {
      botId: bot.id,
    });
    expect(reloaded.entries.map((entry) => [entry.role, entry.text])).toEqual([
      ["user", "hello"],
      ["assistant", "echo: hello (n1)"],
      ["user", "second"],
      ["assistant", "echo: second (n2)"],
    ]);

    // Fork off the first reply: the thread inherits context up to it, not after.
    const firstReply = reloaded.entries[1];
    if (!firstReply) throw new Error("missing first reply");
    const { thread } = await other.request<{ thread: { conversationId: number; title?: string } }>(
      "thread.fork",
      { botId: bot.id, entryId: firstReply.id },
    );
    // Threads have no name of their own; a title is generated later as metadata.
    expect(thread.title).toBeUndefined();
    expect(thread.conversationId).not.toBe(main.conversationId);

    const opened = await other.request<ConversationSnapshot>("conversation.open", {
      botId: bot.id,
      conversationId: thread.conversationId,
    });
    expect(opened.entries.map((entry) => entry.text)).toEqual(["hello", "echo: hello (n1)"]);
    expect(opened.entries.every((entry) => entry.conversationId === main.conversationId)).toBe(
      true,
    );

    await other.request("message.send", {
      botId: bot.id,
      conversationId: thread.conversationId,
      text: "branch",
    });
    // n2: the thread saw "hello" and "branch", not "second".
    await other.waitFor(isFinalEntry(thread.conversationId, "echo: branch (n2)"));

    const { threads } = await other.request<{
      threads: { conversationId: number; title?: string }[];
    }>("threads.list", { botId: bot.id });
    expect(threads).toEqual([
      expect.objectContaining({
        conversationId: thread.conversationId,
        parentConversationId: main.conversationId,
        forkedAt: firstReply.id,
      }),
    ]);
    // Renaming is not part of the protocol.
    await expect(
      other.request("thread.fork", { botId: bot.id, entryId: firstReply.id, title: "Side quest" }),
    ).rejects.toThrow();

    // Main is untouched by the thread.
    const mainAgain = await other.request<ConversationSnapshot>("conversation.open", {
      botId: bot.id,
    });
    expect(mainAgain.entries).toHaveLength(4);

    expect(await other.request("bots.delete", { botId: bot.id })).toEqual({ deleted: true });
    expect((await other.request<{ bots: { name: string }[] }>("bots.list")).bots).toEqual([
      expect.objectContaining({ name: "Admin Bot" }),
    ]);
    // Soft-deleted: it cannot be opened or messaged any more.
    await expect(other.request("conversation.open", { botId: bot.id })).rejects.toThrow(
      /was deleted/,
    );
    // Restorable only through the user's Deleted bots requests.
    const deleted = await other.request<{ bots: { id: string; deletedAt: string }[] }>(
      "bots.listDeleted",
    );
    expect(deleted.bots).toEqual([
      {
        id: bot.id,
        name: bot.name,
        createdAt: bot.createdAt,
        kind: "bot",
        manager: false,
        orchestrator: false,
        profileId: "default",
        profileName: "Default",
        defaultProfile: true,
        deletedAt: expect.any(String),
      },
    ]);
    expect(await other.request("bots.restore", { botId: bot.id })).toEqual({
      restored: true,
      bot: {
        id: bot.id,
        name: bot.name,
        createdAt: bot.createdAt,
        kind: "bot",
        manager: false,
        orchestrator: false,
        profileId: "default",
        profileName: "Default",
        defaultProfile: true,
      },
    });
    expect(await other.request("bots.restore", { botId: bot.id })).toEqual({ restored: false });
    expect((await other.request<{ bots: unknown[] }>("bots.listDeleted")).bots).toEqual([]);
    expect((await other.request<{ bots: { id: string }[] }>("bots.list")).bots).toEqual([
      expect.objectContaining({ name: "Admin Bot" }),
      expect.objectContaining({ id: bot.id }),
    ]);
    const reopened = await other.request<ConversationSnapshot>("conversation.open", {
      botId: bot.id,
    });
    expect(reopened.entries).toHaveLength(4);
    client.close();
    other.close();
  });

  it("manages one-level teams, keeps Admin Bot off them, and pushes bot changes", async () => {
    type Summary = { id: string; name: string; kind: string; manager: boolean; managerId?: string };
    const client = await openClient(wsUrl);
    const watcher = await openClient(wsUrl);
    const create = async (name: string, managerId?: string) =>
      (
        await client.request<{ bot: Summary }>("bots.create", {
          name,
          ...(managerId ? { managerId } : {}),
        })
      ).bot;
    const list = async () => (await client.request<{ bots: Summary[] }>("bots.list")).bots;
    const admin = (await list())[0];
    if (!admin) throw new Error("no Admin Bot");

    const lead = await create("Lead");
    await watcher.waitFor((message) => message.type === "bots.changed");
    await expect(create("Early", lead.id)).rejects.toThrow(/not a manager/);
    expect(
      (await client.request<{ bot: Summary }>("bots.setManager", { botId: lead.id, manager: true }))
        .bot,
    ).toMatchObject({ manager: true });
    const member = await create("Member", lead.id);
    expect(member.managerId).toBe(lead.id);
    const loose = await create("Loose");
    await client.request("bots.setTeam", { botId: loose.id, managerId: lead.id });

    // Admin Bot is not deletable and never on a team; managers have no manager.
    await expect(client.request("bots.delete", { botId: admin.id })).rejects.toThrow(/Admin Bot/);
    await expect(
      client.request("bots.setManager", { botId: admin.id, manager: true }),
    ).rejects.toThrow(/Admin Bot/);
    await expect(
      client.request("bots.setTeam", { botId: admin.id, managerId: lead.id }),
    ).rejects.toThrow(/Admin Bot/);
    await expect(
      client.request("bots.setTeam", { botId: lead.id, managerId: lead.id }),
    ).rejects.toThrow();

    // A member takes over the team; the old manager becomes a member.
    await client.request("bots.replaceManager", { managerId: lead.id, newManagerId: member.id });
    let bots = await list();
    expect(bots.find((entry) => entry.id === member.id)).toMatchObject({ manager: true });
    expect(bots.find((entry) => entry.id === member.id)?.managerId).toBeUndefined();
    expect(bots.find((entry) => entry.id === lead.id)).toMatchObject({
      manager: false,
      managerId: member.id,
    });
    expect(bots.find((entry) => entry.id === loose.id)?.managerId).toBe(member.id);

    // Deleting a manager ungroups its team; restored, it comes back without one.
    await client.request("bots.delete", { botId: member.id });
    bots = await list();
    expect(bots.filter((entry) => entry.managerId)).toEqual([]);
    const restored = await client.request<{ bot: Summary }>("bots.restore", { botId: member.id });
    expect(restored.bot).toMatchObject({ manager: false });
    expect((await list()).filter((entry) => entry.managerId)).toEqual([]);
    client.close();
    watcher.close();
  });

  it("keeps at most one orchestrator, never Admin Bot, and clears it on delete", async () => {
    type Summary = {
      id: string;
      name: string;
      manager: boolean;
      managerId?: string;
      orchestrator: boolean;
    };
    const client = await openClient(wsUrl);
    const create = async (name: string) =>
      (await client.request<{ bot: Summary }>("bots.create", { name })).bot;
    const list = async () => (await client.request<{ bots: Summary[] }>("bots.list")).bots;
    const byId = async (id: string) => (await list()).find((entry) => entry.id === id);
    const orchestrators = async () =>
      (await list()).filter((entry) => entry.orchestrator).map((entry) => entry.id);
    const admin = (await list())[0];
    if (!admin) throw new Error("no Admin Bot");
    expect(admin).toMatchObject({ orchestrator: false });
    await expect(client.request("bots.setOrchestrator", { botId: admin.id })).rejects.toThrow(
      /Admin Bot/,
    );

    const chief = await create("Chief");
    const lead = await create("Lead");
    await client.request("bots.setManager", { botId: lead.id, manager: true });
    const member = await create("Member");
    await client.request("bots.setTeam", { botId: member.id, managerId: lead.id });

    const set = await client.request<{ bot: Summary | null }>("bots.setOrchestrator", {
      botId: chief.id,
    });
    expect(set.bot).toMatchObject({ id: chief.id, orchestrator: true });
    expect(await orchestrators()).toEqual([chief.id]);
    // The orchestrator is above every team: it can't join one.
    await expect(
      client.request("bots.setTeam", { botId: chief.id, managerId: lead.id }),
    ).rejects.toThrow(/orchestrator/);

    // A new orchestrator replaces the old one; a manager keeps its team, and the old one keeps its.
    await client.request("bots.setManager", { botId: chief.id, manager: true });
    await client.request("bots.setOrchestrator", { botId: lead.id });
    expect(await orchestrators()).toEqual([lead.id]);
    expect(await byId(chief.id)).toMatchObject({ orchestrator: false, manager: true });
    expect(await byId(member.id)).toMatchObject({ managerId: lead.id });

    // A team member made orchestrator leaves its team.
    await client.request("bots.setOrchestrator", { botId: member.id });
    expect(await orchestrators()).toEqual([member.id]);
    expect((await byId(member.id))?.managerId).toBeUndefined();

    // Handing the orchestrator's team to a member: the orchestrator stays orchestrator and off the team.
    await client.request("bots.setOrchestrator", { botId: lead.id });
    await client.request("bots.setTeam", { botId: member.id, managerId: lead.id });
    await client.request("bots.replaceManager", { managerId: lead.id, newManagerId: member.id });
    expect(await byId(lead.id)).toMatchObject({ orchestrator: true, manager: false });
    expect((await byId(lead.id))?.managerId).toBeUndefined();
    expect(await byId(member.id)).toMatchObject({ manager: true });

    // Clearing and deleting both empty the slot; a restored orchestrator comes back as a normal bot.
    expect(
      (await client.request<{ bot: Summary | null }>("bots.setOrchestrator", { botId: null })).bot,
    ).toBeNull();
    expect(await orchestrators()).toEqual([]);
    await client.request("bots.setOrchestrator", { botId: chief.id });
    await client.request("bots.delete", { botId: chief.id });
    expect(await orchestrators()).toEqual([]);
    const restored = await client.request<{ bot: Summary }>("bots.restore", { botId: chief.id });
    expect(restored.bot).toMatchObject({ orchestrator: false });
    expect(await orchestrators()).toEqual([]);
    expect(await byId(admin.id)).toMatchObject({ orchestrator: false });
    client.close();
  });

  it("renames any bot but Admin Bot and pushes bots.changed", async () => {
    type Summary = { id: string; name: string; kind: string; orchestrator: boolean };
    const client = await openClient(wsUrl);
    const list = async () => (await client.request<{ bots: Summary[] }>("bots.list")).bots;
    const admin = (await list()).find((entry) => entry.kind === "admin");
    if (!admin) throw new Error("no Admin Bot");
    await expect(client.request("bots.rename", { botId: admin.id, name: "Boss" })).rejects.toThrow(
      /Admin Bot/,
    );
    expect((await list()).find((entry) => entry.id === admin.id)?.name).toBe("Admin Bot");

    const scout = (await client.request<{ bot: Summary }>("bots.create", { name: "Scout" })).bot;
    await client.request("bots.setOrchestrator", { botId: scout.id });
    const watcher = await openClient(wsUrl);
    const renamed = await client.request<{ bot: Summary }>("bots.rename", {
      botId: scout.id,
      name: "  Ranger  ",
    });
    // Roles stay; the name is trimmed; every client is told to refresh.
    expect(renamed.bot).toMatchObject({ id: scout.id, name: "Ranger", orchestrator: true });
    await watcher.waitFor((message) => message.type === "bots.changed");
    expect((await list()).find((entry) => entry.id === scout.id)?.name).toBe("Ranger");
    await expect(client.request("bots.rename", { botId: scout.id, name: "" })).rejects.toThrow();
    await expect(
      client.request("bots.rename", { botId: scout.id, name: "x".repeat(81) }),
    ).rejects.toThrow();
    await client.request("bots.setOrchestrator", { botId: null });
    expect((await list()).find((entry) => entry.id === scout.id)?.name).toBe("Ranger");
    client.close();
    watcher.close();
  });

  it("lists, adds, edits and deletes a bot's memory and pushes memory.changed", async () => {
    type Facts = { facts: string[] };
    const client = await openClient(wsUrl);
    const { bot } = await client.request<{ bot: { id: string } }>("bots.create", { name: "Ada" });
    const other = (await client.request<{ bot: { id: string } }>("bots.create", { name: "Bo" }))
      .bot;
    const botId = bot.id;
    expect(await client.request<Facts>("memory.list", { botId })).toEqual({ facts: [] });

    const watcher = await openClient(wsUrl);
    await watcher.waitFor((message) => message.type === "hello");
    const pushes = () =>
      watcher.messages.filter((message) => message.type === "memory.changed").length;
    expect(await client.request<Facts>("memory.add", { botId, text: " Likes  tea " })).toEqual({
      facts: ["Likes tea"],
    });
    await watcher.waitFor(
      (message) => message.type === "memory.changed" && message.botId === botId,
    );
    await client.request("memory.add", { botId, text: "Lives in Lisbon" });
    expect(
      await client.request<Facts>("memory.update", {
        botId,
        fact: "Likes tea",
        text: "Likes green tea",
      }),
    ).toEqual({ facts: ["Likes green tea", "Lives in Lisbon"] });
    expect(
      await client.request<Facts>("memory.delete", { botId, fact: "Lives in Lisbon" }),
    ).toEqual({ facts: ["Likes green tea"] });
    expect(await client.request<Facts>("memory.list", { botId })).toEqual({
      facts: ["Likes green tea"],
    });
    // Each bot has its own memory; the stored checkpoint is untouched by edits.
    expect(await client.request<Facts>("memory.list", { botId: other.id })).toEqual({ facts: [] });
    expect((await app.manager.registry.memory(botId)).checkpoint).toBe(0);
    await watcher.waitFor(() => pushes() === 4);

    // Refused changes leave memory as it was and push nothing.
    await expect(client.request("memory.add", { botId, text: "" })).rejects.toThrow(
      /invalid request/,
    );
    await expect(client.request("memory.add", { botId, text: "   " })).rejects.toThrow(
      /needs some text/,
    );
    await expect(client.request("memory.add", { botId, text: "x".repeat(1001) })).rejects.toThrow(
      /invalid request/,
    );
    await expect(client.request("memory.add", { botId, text: "likes GREEN tea." })).rejects.toThrow(
      /already in memory/,
    );
    await expect(
      client.request("memory.update", { botId, fact: "Gone", text: "New" }),
    ).rejects.toThrow(/no longer in this bot's memory/);
    await expect(client.request("memory.delete", { botId, fact: "Gone" })).rejects.toThrow(
      /no longer in this bot's memory/,
    );
    await expect(client.request("memory.add", { botId, text: "x", extra: true })).rejects.toThrow(
      /invalid request/,
    );
    const unknown = "00000000-0000-4000-8000-000000000000";
    await expect(client.request("memory.list", { botId: unknown })).rejects.toThrow(/no bot/);
    await expect(client.request("memory.add", { botId: unknown, text: "x" })).rejects.toThrow(
      /no bot/,
    );
    await client.request("bots.delete", { botId: other.id });
    await expect(client.request("memory.list", { botId: other.id })).rejects.toThrow(/no bot/);
    expect(await client.request<Facts>("memory.list", { botId })).toEqual({
      facts: ["Likes green tea"],
    });
    expect(pushes()).toBe(4);
    client.close();
    watcher.close();
  });

  it("rejects invalid requests and unknown bots", async () => {
    const client = await openClient(wsUrl);
    await expect(client.request("nope")).rejects.toThrow(/invalid request/);
    await expect(
      client.request("conversation.open", { botId: "00000000-0000-4000-8000-000000000000" }),
    ).rejects.toThrow(/no bot/);
    client.close();
  });

  it("refuses cross-site upgrades and clients without the runtime token", async () => {
    const auth = { authorization: `Bearer ${TEST_TOKEN}` };
    await expect(Client.open(wsUrl, { ...auth, origin: "https://evil.example" })).rejects.toThrow(/403/);
    await expect(Client.open(wsUrl, { ...auth, host: "evil.example" })).rejects.toThrow(/403/);
    await expect(Client.open(wsUrl, { host: "box.tailnet.ts.net" })).rejects.toThrow(/403/);
    await expect(Client.open(wsUrl)).rejects.toThrow(/401/);
    await expect(Client.open(wsUrl, { authorization: "Bearer wrong" })).rejects.toThrow(/401/);
    const ok = await Client.open(wsUrl, { ...auth, origin: "http://localhost:5173" });
    ok.close();
  });

  it("serves health on loopback to the token holder", async () => {
    expect((await fetch(`${app.server.url}/health`)).status).toBe(401);
    const response = await fetch(`${app.server.url}/health`, {
      headers: { authorization: `Bearer ${TEST_TOKEN}` },
    });
    expect(await response.json()).toMatchObject({
      ok: true,
      version: "0.1.0",
      protocol: 1,
      installationId: expect.any(String),
      capabilities: [
        "groups",
        "woven.mcp",
        "message.context",
        "bots.environment",
        "runtime.update",
        "previews",
      ],
    });
  });

  it("drops the removed settings requests", async () => {
    const client = await openClient(wsUrl);
    for (const type of ["credentials.set", "login.start", "config.get", "github.get", "server.restart", "woven.connect"]) {
      await expect(client.request(type, {})).rejects.toThrow(/invalid request/);
    }
    client.close();
  });
});

describe("websocket thread titles", () => {
  it("pushes threads.changed when a thread is titled", async () => {
    const dir = await tempDir();
    // Replies echo; titles come from their own faux provider.
    const { models } = echoModels(2000);
    const titler = fauxProvider({ provider: "faux-titles", models: [{ id: "t1" }] });
    titler.setResponses([() => fauxAssistantMessage([fauxText('{"title":"Trip planning"}')])]);
    models.setProvider(titler.provider);
    const settings = testSettings("faux/faux-1", { titles: { model: "faux-titles/t1" } });
    const app = await startTestRuntime(dir.path, { models, settings });
    try {
      const client = await openClient(app.url);
      const { bot } = await client.request<{ bot: { id: string } }>("bots.create", { name: "T" });
      const main = await client.request<ConversationSnapshot>("conversation.open", {
        botId: bot.id,
      });
      await client.request("message.send", { botId: bot.id, text: "hello" });
      await client.waitFor(isFinalEntry(main.conversationId, "echo: hello (n1)"));
      const reply = (
        await client.request<ConversationSnapshot>("conversation.open", { botId: bot.id })
      ).entries[1];
      if (!reply) throw new Error("missing reply");
      const { thread } = await client.request<{ thread: { conversationId: number } }>(
        "thread.fork",
        { botId: bot.id, entryId: reply.id },
      );
      await client.request("message.send", {
        botId: bot.id,
        conversationId: thread.conversationId,
        text: "plan the trip",
      });
      await client.waitFor(
        (message) => message.type === "threads.changed" && message.botId === bot.id,
      );
      const { threads } = await client.request<{ threads: { title?: string }[] }>("threads.list", {
        botId: bot.id,
      });
      expect(threads[0]?.title).toBe("Trip planning");
      client.close();
    } finally {
      await app.close();
      await dir.cleanup();
    }
  });
});
