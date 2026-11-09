import { createModels } from "@earendil-works/pi-ai/models";
import {
  type FauxResponseStep,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
} from "@earendil-works/pi-ai/providers/faux";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { BotEnvironmentAdapter } from "../src/env.ts";
import type { UpdateResult } from "../src/environment/container.ts";
import { INTERRUPTED_NOTE } from "../src/operations.ts";
import type { ConversationSnapshot, ServerMessage } from "../src/protocol.ts";
import { echoModels, tempDir } from "./helpers.ts";
import { openClient, startTestRuntime, type TestRuntime } from "./runtime.ts";
import type { Client } from "./ws-client.ts";

const LONG = Array.from({ length: 400 }, (_, i) => `word${i}`).join(" ");

function slowModels() {
  const faux = fauxProvider({ tokensPerSecond: 40, tokenSize: { min: 1, max: 1 } });
  const reply: FauxResponseStep = (context) => {
    const users = context.messages.filter((message) => message.role === "user");
    const content = users.at(-1)?.content;
    const text =
      typeof content === "string"
        ? content
        : (content ?? []).map((block) => (block.type === "text" ? block.text : "")).join("");
    return fauxAssistantMessage([fauxText(text.startsWith("long") ? LONG : `echo: ${text.slice(0, 40)}`)]);
  };
  faux.setResponses(Array.from({ length: 50 }, () => reply));
  const models = createModels();
  models.setProvider(faux.provider);
  return models;
}

/** An environment that records what the runtime asks of it (no containers). */
class StubEnvironment implements BotEnvironmentAdapter {
  readonly kind = "linux-dockerd";
  readonly calls: string[] = [];
  readonly touched: string[] = [];
  result: (botId: string) => UpdateResult = (botId) => ({ botId, ok: true });
  harnessEnv() {
    return (() => {
      throw new Error("no tools in this test");
    }) as never;
  }
  async dispose(botId: string) {
    this.calls.push(`dispose ${botId}`);
  }
  async purge(botId: string) {
    this.calls.push(`purge ${botId}`);
  }
  touch(botId: string) {
    this.touched.push(botId);
  }
  async state() {
    return "stopped" as const;
  }
  async stop(botId: string) {
    this.calls.push(`stop ${botId}`);
  }
  async rebuild(botId: string) {
    this.calls.push(`rebuild ${botId}`);
  }
  async updateBot(botId: string) {
    this.calls.push(`update ${botId}`);
    return this.result(botId);
  }
}

describe("runtime operations over the protocol", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let app: TestRuntime;
  let client: Client;
  let env: StubEnvironment;
  beforeEach(async () => {
    dir = await tempDir();
    env = new StubEnvironment();
    app = await startTestRuntime(dir.path, { models: slowModels(), env });
    client = await openClient(app.url);
  });
  afterEach(async () => {
    client.close();
    await app.close();
    await dir.cleanup();
  });

  it("stops running work, updates each bot, reports progress and tells the bot its turn was interrupted", async () => {
    const { bot } = await client.request<{ bot: { id: string } }>("bots.create", { name: "Busy" });
    const main = await client.request<ConversationSnapshot>("conversation.open", { botId: bot.id });
    await client.request("message.send", { botId: bot.id, text: "long story please" });
    await client.waitFor((m) => m.type === "event" && m.event.kind === "delta", 10_000);
    env.result = (botId) =>
      botId === bot.id ? { botId, ok: false, rolledBack: true, error: "forced" } : { botId, ok: true };
    expect(await client.request("runtime.update", { botIds: [bot.id] })).toEqual({ started: true });
    const done = await client.waitFor(
      (m) => m.type === "runtime.update" && m.phase === "done",
      20_000,
    );
    expect(done).toMatchObject({ type: "runtime.update", phase: "done" });
    const phases = client.messages
      .filter((m): m is Extract<ServerMessage, { type: "runtime.update" }> => m.type === "runtime.update")
      .map((m) => `${m.phase}${m.error ? `:${m.error}` : ""}`);
    expect(phases).toEqual(["stopping", "updating", "rolledBack:forced", "done"]);
    expect(env.calls).toEqual([`update ${bot.id}`]);
    // The interrupted reply is marked stopped; the bot then gets the note and answers it.
    await client.waitFor(
      (m) =>
        m.type === "event" &&
        m.conversationId === main.conversationId &&
        m.event.kind === "entry" &&
        m.event.entry.role === "assistant" &&
        m.event.entry.text.startsWith("echo: [Woven Matter"),
      20_000,
    );
    const snapshot = await client.request<ConversationSnapshot>("conversation.open", { botId: bot.id });
    expect(snapshot.entries.some((entry) => entry.stopped)).toBe(true);
    expect(snapshot.entries.some((entry) => entry.role === "user" && entry.text === INTERRUPTED_NOTE)).toBe(true);
  });

  it("reports, stops and rebuilds a bot's environment, and counts an open chat as activity", async () => {
    const { bot } = await client.request<{ bot: { id: string } }>("bots.create", { name: "Env" });
    expect(await client.request("bots.environment", { botId: bot.id })).toEqual({
      environment: { botId: bot.id, state: "stopped", previews: [] },
    });
    await client.request("bots.stop", { botId: bot.id });
    await client.request("bots.rebuild", { botId: bot.id });
    expect(env.calls).toEqual([`stop ${bot.id}`, `rebuild ${bot.id}`]);
    await client.request("conversation.open", { botId: bot.id });
    expect(env.touched).toContain(bot.id);
    expect(app.server.viewing(bot.id)).toBe(true);
    expect(await client.request("previews.list", { botId: bot.id })).toEqual({ previews: [] });
  });
});

describe("conversation mirror", () => {
  it("mirrors chat entries and thread metadata to the host once, by entry id", async () => {
    const dir = await tempDir();
    const app = await startTestRuntime(dir.path, { models: echoModels(2000).models });
    try {
      const bot = await app.manager.get((await app.manager.create("Mirrored")).id);
      const { submission } = await bot.send("hello there");
      await submission.wait(undefined as never).catch(() => {});
      await bot.harness.waitForIdle((await import("@earendil-works/chord/context")).BACKGROUND_CONTEXT);
      await app.mirror.flush(bot.id);
      const sent = app.host.mirrored.filter((call) => call.botID === bot.id);
      const entries = sent.flatMap((call) => call.batch.entries);
      expect(entries.map((entry) => [entry.role, entry.text])).toEqual([
        ["user", "hello there"],
        ["assistant", "echo: hello there (n1)"],
      ]);
      expect(new Set(entries.map((entry) => entry.id)).size).toBe(2);
      expect(sent[0]?.batch.bot).toEqual({ id: bot.id, name: "Mirrored" });
      expect(sent[0]?.batch.conversations).toEqual([
        { conversationId: (await bot.main()).id, kind: "main" },
      ]);
      // Nothing new: nothing sent.
      const before = app.host.mirrored.length;
      await app.mirror.flush(bot.id);
      expect(app.host.mirrored.length).toBe(before);
      // A thread: its metadata goes along.
      const first = entries[1];
      if (!first) throw new Error("no reply");
      const thread = await bot.fork({ entryId: first.id });
      await app.mirror.flush(bot.id);
      const last = app.host.mirrored.at(-1)?.batch;
      expect(last?.conversations).toContainEqual(
        expect.objectContaining({ conversationId: thread.conversationId, kind: "thread", forkedAt: first.id }),
      );
      expect(last?.entries).toEqual([]);
    } finally {
      await app.close();
      await dir.cleanup();
    }
  });
});
