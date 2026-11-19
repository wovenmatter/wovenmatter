import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxToolCall,
} from "@earendil-works/pi-ai/providers/faux";
import { createBotHarnessOptions } from "../src/agent.ts";
import { type Bot, BotManager } from "../src/bots.ts";
import { DELIVERY_KIND, type Forum, type ForumEvents, openForum, USER_NAME } from "../src/forum.ts";
import { conversationId } from "../src/ids.ts";
import type { ForumPost } from "../src/protocol.ts";
import { openSharedDatabase } from "../src/storage/database.ts";
import { ForumStore } from "../src/storage/forum.ts";
import { BotRegistry } from "../src/storage/registry.ts";
import type { TitleGenerator } from "../src/titles.ts";
import type { BotPlatform } from "../src/tools.ts";
import { FAUX_MODEL, profileOf } from "./helpers.ts";

const ctx = BACKGROUND_CONTEXT;

/** What one model request looks like to a scripted bot. */
export type Turn = {
  /** The bot's name, from its preamble. */
  readonly bot: string;
  /** The newest user message. */
  readonly user: string;
  /** Every user message of the request, oldest first. */
  readonly users: readonly string[];
  /** The request follows a tool result (the bot already acted this turn). */
  readonly afterTool: boolean;
  /** The whole request as JSON: the prompt and tool declarations ride in system messages. */
  readonly json: string;
};

/** What a scripted bot does with a request: call a tool, fail, or answer (privately in a seat). */
export type Move =
  | { readonly post: string; readonly threadId?: number }
  | { readonly tool: string; readonly args: Record<string, string | number | boolean | string[]> }
  | { readonly error: string }
  | { readonly say: string };

type ContextLike = { messages?: readonly { role: string; content: unknown }[] };

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((block): block is { type: "text"; text: string } => block?.type === "text")
    .map((block) => block.text)
    .join("");
}

export function turnOf(context: unknown): Turn {
  const messages = (context as ContextLike).messages ?? [];
  const json = JSON.stringify(context);
  const users = messages.filter((message) => message.role === "user").map((m) => textOf(m.content));
  return {
    bot: /You are ([^,"\\]+), (?:a personal assistant bot|the setup bot)/.exec(json)?.[1] ?? "",
    user: users.at(-1) ?? "",
    users,
    afterTool: messages.at(-1)?.role === "toolResult",
    json,
  };
}

export type ForumTestOptions = {
  /** Decides each model request. Default: every bot answers privately. */
  readonly brain?: (turn: Turn) => Move;
  readonly titles?: Pick<TitleGenerator, "generate">;
  readonly now?: () => number;
  readonly tokensPerSecond?: number;
  /** The profile's main model, read live ("" for none yet). */
  readonly main?: () => string;
};

/**
 * A manager with Admin Bot and the Forum over one database, on scripted models. `reopen()` closes
 * and opens both again, as a restart does.
 */
export async function openForumTest(dir: string, options: ForumTestOptions = {}) {
  const faux = fauxProvider({ tokensPerSecond: options.tokensPerSecond ?? 5000 });
  const turns: Turn[] = [];
  let brain = options.brain ?? (() => ({ say: "noted" }) as Move);
  const step = (context: unknown) => {
    const turn = turnOf(context);
    turns.push(turn);
    const move = brain(turn);
    if ("post" in move) {
      return fauxAssistantMessage(
        [
          fauxToolCall("forum_post", {
            text: move.post,
            ...(move.threadId !== undefined ? { threadId: move.threadId } : {}),
          }),
        ],
        { stopReason: "toolUse" },
      );
    }
    if ("tool" in move) {
      return fauxAssistantMessage([fauxToolCall(move.tool, move.args)], { stopReason: "toolUse" });
    }
    if ("error" in move) {
      return fauxAssistantMessage([], { stopReason: "error", errorMessage: move.error });
    }
    return fauxAssistantMessage([fauxText(move.say)]);
  };
  faux.setResponses(Array.from({ length: 2000 }, () => step));
  const models = createModels();
  models.setProvider(faux.provider);
  const db = await openSharedDatabase(join(dir, "db.sqlite"));
  const posts: ForumPost[] = [];
  const thinking: { roomId: number; botIds: string[] }[] = [];
  let changes = 0;
  const events: ForumEvents = {
    post: (post) => posts.push(post),
    thinking: (roomId, botIds) => thinking.push({ roomId, botIds }),
    changed: () => {
      changes += 1;
    },
  };
  let manager!: BotManager;
  let forum!: Forum;
  const platform: BotPlatform = {
    manager: () => manager,
    forum: () => forum,
    userName: async () => (await manager.registry.note(USER_NAME))?.text.trim() || undefined,
    setUserName: async (name) => {
      await manager.registry.setNote(USER_NAME, name.trim());
      return name.trim();
    },
  };
  const registry = new BotRegistry(db);
  await registry.migrate();
  const open = async () => {
    const store = new ForumStore(db);
    forum = await openForum({
      store,
      registry,
      manager: () => manager,
      ...(options.titles ? { titles: options.titles as TitleGenerator } : {}),
      events,
      ...(options.now ? { now: options.now } : {}),
    });
    const room = forum;
    manager = await BotManager.open({
      db,
      ensureAdmin: true,
      harnessOptions: (bot) =>
        createBotHarnessOptions({
          bot,
          models,
          profile: () =>
            options.main
              ? { id: "default", name: "Default", main: options.main(), pool: [] }
              : profileOf(FAUX_MODEL),
          platform,
        }),
      onBotOpened: (bot) => void room.botOpened(bot),
      onBotDeleted: (bot) => room.botDeleted(bot.id),
      onBotPurged: async (botId) => {
        await room.botPurged(botId);
        return undefined;
      },
      forumConversations: (botId) => room.conversationsOf(botId),
    });
    // The scheduled posts' clock is driven by the tests (`forum.tick()`).
    await forum.start({ scheduleCheckMs: 3_600_000 });
  };
  await open();

  const working = async () => {
    for (const record of await manager.list()) {
      const live = await (await manager.get(record.id)).harness.inspect(ctx);
      if (live.submissions.length || live.tasks.length) return true;
    }
    return false;
  };
  /** Every turn has ended, every delivery and owed reply is settled, and nothing new started. */
  const settle = async () => {
    for (let pass = 0; pass < 500; pass += 1) {
      const before = turns.length;
      await forum.idle();
      for (const record of await manager.list()) {
        await (await manager.get(record.id)).harness.waitForIdle(ctx);
      }
      // A turn's end reaches the Forum a moment later (its wait resolves, then it settles).
      await new Promise((resolve) => setTimeout(resolve, 10));
      await forum.idle();
      if (turns.length === before && !(await working())) return;
    }
    throw new Error("the Forum did not become idle");
  };

  /** What a bot's seat was given, oldest first (the Forum's unless `roomId` names a thread). */
  const heard = async (bot: Bot, roomId?: number): Promise<string[]> => {
    const main = await forum.store.mainRoom();
    const seat = await forum.store.seat(roomId ?? main.id, bot.id);
    if (seat?.conversationId === undefined) return [];
    const inputs: string[] = [];
    for await (const entry of bot.ownEntries(seat.conversationId)) {
      if (entry.kind !== DELIVERY_KIND) continue;
      const message = entry.model?.find((item) => item.role === "user");
      if (message) inputs.push(textOf(message.content));
    }
    return inputs;
  };

  const seatConversation = async (bot: Bot, roomId?: number) => {
    const main = await forum.store.mainRoom();
    const seat = await forum.store.seat(roomId ?? main.id, bot.id);
    return seat?.conversationId === undefined
      ? undefined
      : bot.harness.conversation(conversationId(seat.conversationId), ctx);
  };

  return {
    db,
    faux,
    turns,
    posts,
    thinking,
    platform,
    get changes() {
      return changes;
    },
    get manager() {
      return manager;
    },
    get forum() {
      return forum;
    },
    setBrain(next: (turn: Turn) => Move) {
      brain = next;
    },
    settle,
    heard,
    seatConversation,
    /** A new bot, opened. */
    async bot(name: string): Promise<Bot> {
      return manager.get((await manager.create(name)).id);
    },
    /** The Forum's posts (or a thread's), oldest first, as `author: text`. */
    async log(roomId?: number): Promise<string[]> {
      const main = await forum.store.mainRoom();
      return (await forum.store.postsAfter(roomId ?? main.id, 0)).map(
        (post) => `${post.author === "user" ? "user" : post.name}: ${post.text}`,
      );
    },
    async reopen() {
      await forum.close();
      await manager.close();
      await open();
    },
    async close() {
      await forum.close();
      await manager.close();
      await db.close();
    },
  };
}

export type ForumTest = Awaited<ReturnType<typeof openForumTest>>;
