import { createModels } from "@earendil-works/pi-ai/models";
import {
  type FauxResponseStep,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
} from "@earendil-works/pi-ai/providers/faux";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { ConversationSnapshot, ServerMessage } from "../src/protocol.ts";
import { tempDir } from "./helpers.ts";
import { openClient, startTestRuntime, type TestRuntime } from "./runtime.ts";
import type { Client } from "./ws-client.ts";

const LONG = Array.from({ length: 400 }, (_, i) => `word${i}`).join(" ");

/** Faux models: "long …" streams a long reply slowly; anything else is echoed. */
function slowModels() {
  const faux = fauxProvider({ tokensPerSecond: 40, tokenSize: { min: 1, max: 1 } });
  const reply: FauxResponseStep = (context) => {
    const users = context.messages.filter((message) => message.role === "user");
    const content = users.at(-1)?.content;
    const text =
      typeof content === "string"
        ? content
        : (content ?? []).map((block) => (block.type === "text" ? block.text : "")).join("");
    return fauxAssistantMessage([fauxText(text.startsWith("long") ? LONG : `echo: ${text}`)]);
  };
  faux.setResponses(Array.from({ length: 50 }, () => reply));
  const models = createModels();
  models.setProvider(faux.provider);
  return models;
}

const assistantEntry = (conversationId: number, text: string) => (message: ServerMessage) =>
  message.type === "event" &&
  message.conversationId === conversationId &&
  message.event.kind === "entry" &&
  message.event.entry.role === "assistant" &&
  message.event.entry.text === text;

describe("conversation.abort", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let app: TestRuntime;
  let client: Client;

  beforeEach(async () => {
    dir = await tempDir();
    app = await startTestRuntime(dir.path, { models: slowModels() });
    client = await openClient(app.url);
  });

  afterEach(async () => {
    client.close();
    await app.close();
    await dir.cleanup();
  });

  /** Start a long reply in `conversationId`, queue a follow-up, stop it mid-stream, then chat on. */
  async function stopMidStream(botId: string, conversationId: number, mainId: number) {
    const target = conversationId === mainId ? {} : { conversationId };
    await client.request("message.send", { botId, ...target, text: "long please" });
    await client.waitFor(
      (message) =>
        message.type === "event" &&
        message.conversationId === conversationId &&
        message.event.kind === "delta",
    );
    // Queued behind the running reply; the stop withdraws it.
    await client.request("message.send", { botId, ...target, text: "queued follow-up" });
    const before = client.messages.length;
    expect(await client.request("conversation.abort", { botId, ...target })).toEqual({
      conversationId,
      stopped: true,
    });
    await client.waitFor(
      (message) =>
        client.messages.indexOf(message) >= before &&
        message.type === "event" &&
        message.conversationId === conversationId &&
        message.event.kind === "run" &&
        message.event.state === "end",
    );

    const snapshot = await client.request<ConversationSnapshot>("conversation.open", {
      botId,
      ...target,
    });
    expect(snapshot.running).toBe(false);
    const own = snapshot.entries.filter((entry) => entry.conversationId === conversationId);
    expect(own.map((entry) => entry.text)).not.toContain("queued follow-up");
    const partial = own.at(-1);
    expect(partial).toMatchObject({ role: "assistant", stopped: true });
    expect(partial?.error).toBeUndefined();
    expect(partial?.text.length).toBeGreaterThan(0);
    expect(LONG.startsWith(partial?.text ?? "x")).toBe(true);
    expect(partial?.text).not.toBe(LONG);

    // The conversation is usable again.
    await client.request("message.send", { botId, ...target, text: "next" });
    await client.waitFor(assistantEntry(conversationId, "echo: next"));
    // Stopping an idle conversation is a no-op.
    expect(await client.request("conversation.abort", { botId, ...target })).toEqual({
      conversationId,
      stopped: true,
    });
  }

  it("stops the main channel's reply, drops its queued follow-up, and takes the next message", async () => {
    const { bot } = await client.request<{ bot: { id: string } }>("bots.create", { name: "Scout" });
    const main = await client.request<ConversationSnapshot>("conversation.open", {
      botId: bot.id,
    });
    await stopMidStream(bot.id, main.conversationId, main.mainConversationId);
  });

  it("stops a thread's reply without touching the main channel", async () => {
    const { bot } = await client.request<{ bot: { id: string } }>("bots.create", { name: "Scout" });
    const main = await client.request<ConversationSnapshot>("conversation.open", {
      botId: bot.id,
    });
    await client.request("message.send", { botId: bot.id, text: "hi" });
    await client.waitFor(assistantEntry(main.conversationId, "echo: hi"));
    const reloaded = await client.request<ConversationSnapshot>("conversation.open", {
      botId: bot.id,
    });
    const reply = reloaded.entries.at(-1);
    if (!reply) throw new Error("no reply");
    const { thread } = await client.request<{ thread: { conversationId: number } }>("thread.fork", {
      botId: bot.id,
      entryId: reply.id,
    });
    await client.request("conversation.open", {
      botId: bot.id,
      conversationId: thread.conversationId,
    });
    await stopMidStream(bot.id, thread.conversationId, main.conversationId);

    const mainAgain = await client.request<ConversationSnapshot>("conversation.open", {
      botId: bot.id,
    });
    expect(mainAgain.entries.map((entry) => entry.text)).toEqual(["hi", "echo: hi"]);
  });

  it("refuses unknown threads and malformed requests", async () => {
    const { bot } = await client.request<{ bot: { id: string } }>("bots.create", { name: "Scout" });
    await expect(
      client.request("conversation.abort", { botId: bot.id, conversationId: 999 }),
    ).rejects.toThrow(/no thread/);
    await expect(
      client.request("conversation.abort", { botId: bot.id, extra: true }),
    ).rejects.toThrow(/invalid request/);
  });
});
