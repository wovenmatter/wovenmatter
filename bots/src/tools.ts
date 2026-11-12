import { defineExtension, defineTool, type Extension } from "@earendil-works/pi-durable";
import { Type } from "typebox";
import type { BotManager } from "./bots.ts";
import { describeProfile, type ProfileStore } from "./profiles.ts";
import type { SettingsService } from "./settings/service.ts";
import type { BotRecord } from "./storage/registry.ts";
import { displayEntry } from "./transcript.ts";

/**
 * What bot tools reach: the bot manager, and (for Admin Bot) settings. Late-bound, because the
 * app opens the manager before settings exist.
 */
export type BotPlatform = {
  readonly manager: () => BotManager;
  readonly settings?: () => SettingsService | undefined;
  /** `[bot_to_bot] max_messages_per_hour_per_pair`: a guard against runaway bot loops. */
  readonly maxMessagesPerHourPerPair?: number;
  /** `[bot_to_bot] max_rounds_per_request`: bot-to-bot hops after one user message. */
  readonly maxRoundsPerRequest?: number;
};

type Result = { output: { type: "text"; text: string }[]; isError?: boolean };

const text = (value: unknown): Result => ({
  output: [
    { type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) },
  ],
});

/** A tool result from `body`'s value; a throw becomes an error result with its message. */
export async function run(body: () => Promise<unknown>): Promise<Result> {
  try {
    return text(await body());
  } catch (error) {
    return { ...text(error instanceof Error ? error.message : String(error)), isError: true };
  }
}

/** How a bot appears to other bots. */
export function describeBot(record: BotRecord) {
  return {
    id: record.id,
    name: record.name,
    ...(record.kind === "admin" ? { admin: true } : {}),
    ...(record.manager ? { manager: true } : {}),
    ...(record.managerId ? { managerId: record.managerId } : {}),
    ...(record.orchestrator ? { orchestrator: true } : {}),
  };
}

/** Sliding one-hour window of bot-to-bot messages per (sender, target) pair. */
export class MessageLimiter {
  readonly #sent = new Map<string, number[]>();
  readonly #limit: number;
  readonly #now: () => number;

  constructor(limit: number, now: () => number = Date.now) {
    this.#limit = limit;
    this.#now = now;
  }

  take(from: string, to: string): boolean {
    const key = `${from}>${to}`;
    const now = this.#now();
    const recent = (this.#sent.get(key) ?? []).filter((at) => now - at < 3_600_000);
    if (recent.length >= this.#limit) {
      this.#sent.set(key, recent);
      return false;
    }
    recent.push(now);
    this.#sent.set(key, recent);
    return true;
  }

  /** Drop every pair a purged bot was part of. */
  forget(botId: string): void {
    for (const key of [...this.#sent.keys()]) {
      const [from, to] = key.split(">");
      if (from === botId || to === botId) this.#sent.delete(key);
    }
  }

  get size(): number {
    return this.#sent.size;
  }
}

const limiters = new WeakMap<BotPlatform, MessageLimiter>();

/** A bot was purged: forget its bot-to-bot message counts. */
export function forgetBotMessages(platform: BotPlatform, botId: string): void {
  limiters.get(platform)?.forget(botId);
}

function limiter(platform: BotPlatform): MessageLimiter {
  let found = limiters.get(platform);
  if (!found) {
    found = new MessageLimiter(platform.maxMessagesPerHourPerPair ?? 30);
    limiters.set(platform, found);
  }
  return found;
}

/** Tools every bot has: list bots, create a bot, message a bot. */
function commonTools(botId: string, platform: BotPlatform) {
  return [
    defineTool({
      name: "list_bots",
      description:
        "List every bot on this machine: id, name, whether it is Admin Bot, the orchestrator or a team manager, and its manager.",
      parameters: Type.Object({}),
      replay: "safe",
      execute: () => run(async () => (await platform.manager().list()).map(describeBot)),
    }),
    defineTool({
      name: "create_bot",
      description:
        "Create a new bot when the user asks for one. A bot created by a team manager or a team member joins that team automatically.",
      parameters: Type.Object({
        name: Type.String({ description: "Name of the new bot (1-80 characters)" }),
      }),
      execute: (args) =>
        run(async () =>
          describeBot(await platform.manager().create(args.name, { createdBy: botId })),
        ),
    }),
    defineTool({
      name: "message_bot",
      description:
        "Send a message to another bot's main channel. It is queued if that bot is busy and does not wait for a reply; the other bot can answer with message_bot.",
      parameters: Type.Object({
        botId: Type.String({ description: "Target bot id (from list_bots)" }),
        text: Type.String({ description: "The message" }),
      }),
      execute: (args, api) =>
        run(async () => {
          if (args.botId === botId) throw new Error("a bot cannot message itself");
          const manager = platform.manager();
          const sender = await manager.record(botId);
          const target = await manager.get(args.botId);
          // A request is the chain of bot-to-bot messages after one user message.
          const round = (await (await manager.get(botId)).round(api.conversationId)) + 1;
          const maxRounds = platform.maxRoundsPerRequest ?? 5;
          if (round > maxRounds) {
            throw new Error(
              `bot-to-bot round limit reached (${maxRounds} per request); reply to the user instead`,
            );
          }
          if (!limiter(platform).take(botId, args.botId)) {
            throw new Error(
              `message limit reached: at most ${platform.maxMessagesPerHourPerPair ?? 30} messages per hour to ${target.record.name}`,
            );
          }
          await target.send(
            `[Message from bot "${sender.name}" (id ${sender.id})]\n${args.text}`,
            undefined,
            round,
          );
          return `Delivered to ${(await manager.record(args.botId)).name}.`;
        }),
    }),
  ];
}

const MAX_SHOWN_CHARS = 2000;
const SNIPPET_CHARS = 80;

const clip = (text: string, max: number) => (text.length > max ? `${text.slice(0, max)}…` : text);

/** A snippet of `text` around the first `needle` (lowercase), on one line. */
function snippet(text: string, needle: string): string {
  const flat = text.replace(/\s+/g, " ");
  const at = flat.toLowerCase().indexOf(needle);
  const start = Math.max(0, at - SNIPPET_CHARS);
  const end = Math.min(flat.length, at + needle.length + SNIPPET_CHARS);
  return `${start > 0 ? "…" : ""}${flat.slice(start, end)}${end < flat.length ? "…" : ""}`;
}

/** Every bot: read and search its own main channel and threads (never another bot's). */
function historyTools(botId: string, platform: BotPlatform) {
  return [
    defineTool({
      name: "read_thread",
      description:
        "Read one of your own threads (or your main channel) as a compact transcript: its own messages, newest last. Thread ids come from search_history.",
      parameters: Type.Object({
        threadId: Type.Integer({ description: "Conversation id of your thread or main channel" }),
        limit: Type.Optional(
          Type.Integer({ minimum: 1, maximum: 200, description: "Newest messages (default 40)" }),
        ),
      }),
      replay: "safe",
      execute: (args) =>
        run(async () => {
          const bot = await platform.manager().get(botId);
          const conversation = await bot.conversation(args.threadId);
          const thread = (await bot.conversations()).find(
            (item) => item.conversationId === conversation.id,
          );
          const limit = Math.min(Math.max(args.limit ?? 40, 1), 200);
          const lines: string[] = [];
          for await (const entry of bot.ownEntries(conversation.id, 0, "descending")) {
            const shown = displayEntry(entry);
            if (!shown || (!shown.text.trim() && !shown.error)) continue;
            const body = shown.text.trim() || `(error: ${shown.error})`;
            lines.push(`[${shown.id}] ${shown.role}: ${clip(body, MAX_SHOWN_CHARS)}`);
            if (lines.length >= limit) break;
          }
          const main = (await bot.main()).id === conversation.id;
          const header = main
            ? `Main channel (conversation ${conversation.id})`
            : `Thread ${conversation.id}: ${thread?.title || "Untitled thread"}`;
          return [header, ...(lines.length ? lines.reverse() : ["(no messages yet)"])].join("\n");
        }),
    }),
    defineTool({
      name: "search_history",
      description:
        "Search your own main channel and threads for text (case-insensitive substring). Returns snippets with the conversation id and thread title, newest first; open one with read_thread.",
      parameters: Type.Object({
        query: Type.String({ description: "Text to look for" }),
        limit: Type.Optional(
          Type.Integer({ minimum: 1, maximum: 50, description: "Most results (default 10)" }),
        ),
      }),
      replay: "safe",
      execute: (args) =>
        run(async () => {
          const needle = args.query.trim().toLowerCase();
          if (!needle) throw new Error("query is empty");
          const limit = Math.min(Math.max(args.limit ?? 10, 1), 50);
          const bot = await platform.manager().get(botId);
          const hits: {
            conversationId: number;
            title: string;
            entryId: number;
            role: string;
            snippet: string;
          }[] = [];
          for (const { conversationId, title } of await bot.conversations()) {
            let found = 0;
            for await (const entry of bot.ownEntries(conversationId, 0, "descending")) {
              const shown = displayEntry(entry);
              if (!shown?.text.toLowerCase().includes(needle)) continue;
              hits.push({
                conversationId,
                title,
                entryId: shown.id,
                role: shown.role,
                snippet: snippet(shown.text, needle),
              });
              if (++found >= limit) break;
            }
          }
          const main = (await bot.main()).id;
          const results = hits
            .sort((a, b) => b.entryId - a.entryId)
            .slice(0, limit)
            .map((hit) => ({
              ...hit,
              title: hit.conversationId === main ? "Main channel" : hit.title || "Untitled thread",
            }));
          return results.length ? results : `No messages contain "${args.query.trim()}".`;
        }),
    }),
  ];
}

/** Non-Admin Bots: rename themselves, start a team under themselves and add or remove members. */
function teamTools(botId: string, platform: BotPlatform) {
  return [
    defineTool({
      name: "rename_me",
      description:
        "Change your own name when the user asks. Your role (orchestrator, manager or bot) stays as it is.",
      parameters: Type.Object({
        name: Type.String({ description: "Your new name (1-80 characters)" }),
      }),
      execute: (args) =>
        run(async () => describeBot(await platform.manager().rename(botId, args.name))),
    }),
    defineTool({
      name: "my_team",
      description:
        "Manage your own team or role when the user asks. start: become a team manager (you leave any team you are on). add/remove: put another bot on or off your team (you must be a manager). stop: stop managing (your team is ungrouped). become_orchestrator: become the orchestrator, which oversees every bot and team (replaces the current orchestrator; you leave any team you are on, a team you manage stays). stop_orchestrator: stop being the orchestrator.",
      parameters: Type.Object({
        action: Type.Union([
          Type.Literal("start"),
          Type.Literal("add"),
          Type.Literal("remove"),
          Type.Literal("stop"),
          Type.Literal("become_orchestrator"),
          Type.Literal("stop_orchestrator"),
        ]),
        botId: Type.Optional(Type.String({ description: "The bot to add or remove" })),
      }),
      execute: (args) =>
        run(async () => {
          const manager = platform.manager();
          if (args.action === "start") return describeBot(await manager.setManager(botId, true));
          if (args.action === "stop") return describeBot(await manager.setManager(botId, false));
          if (args.action === "become_orchestrator") {
            await manager.setOrchestrator(botId);
            return describeBot(await manager.record(botId));
          }
          if (args.action === "stop_orchestrator") {
            if (!(await manager.record(botId)).orchestrator)
              throw new Error("you are not the orchestrator");
            await manager.setOrchestrator(undefined);
            return describeBot(await manager.record(botId));
          }
          if (!args.botId) throw new Error("botId is required");
          const self = await manager.record(botId);
          if (!self.manager) throw new Error("you are not a team manager; start a team first");
          if (args.action === "add") return describeBot(await manager.setTeam(args.botId, botId));
          const member = await manager.record(args.botId);
          if (member.managerId !== botId) throw new Error(`${member.name} is not on your team`);
          return describeBot(await manager.setTeam(args.botId, undefined));
        }),
    }),
  ];
}

/** Admin Bot only: teams on the user's behalf, model profiles, and account/config management. */
function adminTools(platform: BotPlatform) {
  const settings = () => {
    const found = platform.settings?.();
    if (!found) throw new Error("settings are not available on this server");
    return found;
  };
  return [
    defineTool({
      name: "rename_bot",
      description:
        "Rename a bot (id from list_bots) when the user asks. Any bot but Admin Bot, whose name is fixed; roles stay as they are.",
      parameters: Type.Object({
        botId: Type.String(),
        name: Type.String({ description: "The new name (1-80 characters)" }),
      }),
      execute: (args) =>
        run(async () => describeBot(await platform.manager().rename(args.botId, args.name))),
    }),
    defineTool({
      name: "set_team",
      description:
        "Organize teams for the user. promote/demote: make a bot a team manager or not (demoting ungroups its team). join: put botId on managerId's team. leave: take botId off its team. replace_manager: make botId the new manager of managerId's team (the old manager stays as a member). make_orchestrator: make botId the one optional orchestrator, which oversees every bot and team (replaces the current one, which keeps its team; the new one leaves any team it is on and keeps a team it manages). clear_orchestrator: no orchestrator (botId is ignored).",
      parameters: Type.Object({
        action: Type.Union([
          Type.Literal("promote"),
          Type.Literal("demote"),
          Type.Literal("join"),
          Type.Literal("leave"),
          Type.Literal("replace_manager"),
          Type.Literal("make_orchestrator"),
          Type.Literal("clear_orchestrator"),
        ]),
        botId: Type.Optional(Type.String()),
        managerId: Type.Optional(Type.String()),
      }),
      execute: (args) =>
        run(async () => {
          const manager = platform.manager();
          if (args.action === "clear_orchestrator") {
            await manager.setOrchestrator(undefined);
            return "There is no orchestrator now.";
          }
          if (!args.botId) throw new Error("botId is required");
          switch (args.action) {
            case "make_orchestrator":
              await manager.setOrchestrator(args.botId);
              return describeBot(await manager.record(args.botId));
            case "promote":
              return describeBot(await manager.setManager(args.botId, true));
            case "demote":
              return describeBot(await manager.setManager(args.botId, false));
            case "leave":
              return describeBot(await manager.setTeam(args.botId, undefined));
            case "join":
            case "replace_manager": {
              if (!args.managerId) throw new Error("managerId is required");
              return describeBot(
                args.action === "join"
                  ? await manager.setTeam(args.botId, args.managerId)
                  : await manager.replaceManager(args.managerId, args.botId),
              );
            }
          }
        }),
    }),
    defineTool({
      name: "settings_status",
      description:
        "Read the current setup: which Woven Matter provider connections and search keys are available to bots (never the secrets), the thread-title model and every available model. Model profiles: list_profiles.",
      parameters: Type.Object({}),
      replay: "safe",
      execute: () =>
        run(async () => {
          const service = settings();
          const [accounts, catalog] = await Promise.all([service.accounts(), service.modelCatalog()]);
          return {
            connections: accounts.accounts.map((a) => ({
              id: a.id,
              label: a.label,
              configured: a.configured,
            })),
            search: {
              provider: accounts.search.provider,
              configured: accounts.search.providers.filter((p) => p.configured).map((p) => p.id),
            },
            titles: { model: catalog.roles.titles, reasoning: catalog.roles.titlesReasoning },
            models: catalog.providers.map((p) => ({
              provider: p.id,
              models: p.models.map((m) => `${p.id}/${m.id}`),
            })),
          };
        }),
    }),
    ...profileTools(platform, settings),
  ];
}

const poolEntry = Type.Object({
  model: Type.String({ description: "provider/model-id" }),
  useFor: Type.Optional(
    Type.String({ description: "Optional notes on this model, shown to the main model" }),
  ),
});

/** Admin Bot: model profiles, which bot runs which, and the user's account notes. */
function profileTools(platform: BotPlatform, settings: () => SettingsService) {
  const store = (): ProfileStore => {
    const found = platform.manager().profiles;
    if (!found) throw new Error("model profiles are not available on this server");
    return found;
  };
  const confirm = "Confirm with the user first unless they asked for this change.";
  return [
    defineTool({
      name: "list_profiles",
      description:
        "List the model profiles (main model, its ordered fallbacks, memory extraction model, model pool with optional notes, model preferences), which is the default, and which profile each bot runs.",
      parameters: Type.Object({}),
      replay: "safe",
      execute: () =>
        run(async () => {
          const profiles = store();
          const manager = platform.manager();
          return {
            defaultProfile: profiles.defaultId,
            profiles: profiles.list().map((p) => describeProfile(p, profiles.defaultId)),
            bots: (await manager.list()).map((bot) => ({
              id: bot.id,
              name: bot.name,
              profile: profiles.resolve(bot.profile).id,
              ...(bot.profile ? {} : { usesDefault: true }),
            })),
          };
        }),
    }),
    defineTool({
      name: "save_profile",
      description: `Create (create: true) or replace a model profile. main runs the main channel and threads of every bot on it; fallbacks (optional, ordered, at most 5) are main models to switch to when main hits a usage limit or runs out of credits (none: the bot pauses until the limit resets); pool lists additional models for subagents (run_subagent; the main model can always run subagents on itself, so pool may be empty); guidance is the model preferences: the user's own words about the models (e.g. "Opus writes nicer code", "double-check Astra"), weighed by the main model, never enforced; memoryModel (optional) is the memory extraction model, which reviews new conversation messages and saves useful facts into the bot's memory on the extraction schedule and when idle; omit it to use the active main model. It never affects chat or subagents. Models must be listed by settings_status. Changes apply from each bot's next reply. ${confirm}`,
      parameters: Type.Object({
        id: Type.String({ description: "lowercase letters, digits, - and _" }),
        name: Type.String(),
        main: Type.String({ description: "provider/model-id" }),
        fallbacks: Type.Optional(
          Type.Array(Type.String({ description: "provider/model-id" }), {
            maxItems: 5,
            description: "Ordered main-model fallbacks for usage limits; omit or [] for none",
          }),
        ),
        pool: Type.Array(poolEntry),
        guidance: Type.Optional(
          Type.String({
            description:
              "Model preferences: the user's preferences and experiences with the models",
          }),
        ),
        memoryModel: Type.Optional(
          Type.String({
            description:
              "Memory extraction model, provider/model-id; omit for the active main model",
          }),
        ),
        create: Type.Optional(Type.Boolean()),
      }),
      execute: (args) =>
        run(async () => {
          const service = settings();
          service.checkModel(args.main);
          for (const ref of args.fallbacks ?? []) service.checkModel(ref);
          for (const entry of args.pool) service.checkModel(entry.model);
          if (args.memoryModel) service.checkModel(args.memoryModel);
          const profiles = store();
          const saved = await profiles.save(
            {
              id: args.id,
              name: args.name,
              main: args.main,
              ...(args.fallbacks ? { fallbacks: args.fallbacks } : {}),
              pool: args.pool,
              ...(args.memoryModel ? { memoryModel: args.memoryModel } : {}),
              ...(args.guidance !== undefined ? { guidance: args.guidance } : {}),
            },
            { create: args.create === true },
          );
          return describeProfile(saved, profiles.defaultId);
        }),
    }),
    defineTool({
      name: "delete_profile",
      description: `Delete a model profile (not the default). Bots on it go back to the default profile. ${confirm}`,
      parameters: Type.Object({ id: Type.String() }),
      execute: (args) =>
        run(async () => {
          await store().remove(args.id);
          return `Deleted profile "${args.id}".`;
        }),
    }),
    defineTool({
      name: "set_default_profile",
      description: `Make a profile the default: every bot without its own profile, and every new bot, runs it. ${confirm}`,
      parameters: Type.Object({ id: Type.String() }),
      execute: (args) =>
        run(async () => {
          await store().setDefault(args.id);
          return `"${args.id}" is now the default profile.`;
        }),
    }),
    defineTool({
      name: "set_bot_profile",
      description: `Choose which profile a bot runs (bot ids from list_bots); omit profileId for the default. Applies from the bot's next reply. ${confirm}`,
      parameters: Type.Object({
        botId: Type.String(),
        profileId: Type.Optional(Type.String()),
      }),
      execute: (args) =>
        run(async () => {
          const record = await platform.manager().setProfile(args.botId, args.profileId);
          return `${record.name} now runs profile "${store().resolve(record.profile).id}".`;
        }),
    }),
    defineTool({
      name: "read_account_notes",
      description:
        "Read the account notes: the user's subscriptions and tiers, API keys, and rough monthly comfort spend (guidance for model choices, not hard caps).",
      parameters: Type.Object({}),
      replay: "safe",
      execute: () =>
        run(async () => {
          const note = await platform.manager().registry.note(ACCOUNT_NOTES);
          return note ? { notes: note.text, updatedAt: note.updatedAt } : "No account notes yet.";
        }),
    }),
    defineTool({
      name: "write_account_notes",
      description:
        "Replace the account notes with the full text (plans and tiers, API keys by name only, comfort spend). Never include secrets.",
      parameters: Type.Object({ notes: Type.String() }),
      execute: (args) =>
        run(async () => {
          if (args.notes.length > 8000) throw new Error("account notes are too long (max 8000)");
          await platform.manager().registry.setNote(ACCOUNT_NOTES, args.notes);
          return "Saved the account notes.";
        }),
    }),
  ];
}

/** The account notes record (`pibot_notes`). */
export const ACCOUNT_NOTES = "account";

/** The `pi-bot-tools` extension for one bot. */
export function botTools(record: BotRecord, platform: BotPlatform): Extension {
  return defineExtension({
    name: "pi-bot-tools",
    tools: [
      ...commonTools(record.id, platform),
      ...historyTools(record.id, platform),
      ...(record.kind === "admin" ? adminTools(platform) : teamTools(record.id, platform)),
    ],
  });
}
