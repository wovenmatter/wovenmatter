import { randomUUID } from "node:crypto";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import {
  type Conversation,
  type ConversationRecord,
  configure,
  type EntryRecord,
  Harness,
} from "@earendil-works/pi-durable";
import { type SqliteDatabase, SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { type BotHarnessOptions, defaultAgent } from "./agent.ts";
import { type ModelRef, type Profile, parseModelRef } from "./config.ts";
import { conversationId as toConversationId, entryId as toEntryId } from "./ids.ts";
import { fallbackNote, type Limit, type LimitEntry, type ModelAvailability } from "./limits.ts";
import { contextNote } from "./message-context.ts";
import type { ProfileStore } from "./profiles.ts";
import { sharedDatabaseView } from "./storage/database.ts";
import {
  type BotRecord,
  BotRegistry,
  botPrefix,
  type DeletedBotRecord,
  type ThreadRecord,
} from "./storage/registry.ts";
import type { TitleGenerator } from "./titles.ts";
import { displayEntry } from "./transcript.ts";

const ctx = BACKGROUND_CONTEXT;

/** What `BotManager` found and repaired when it opened a bot after a restart or crash. */
export type RecoveryReport = {
  /** Forks found in the Pi Durable store but missing from the thread registry, now registered. */
  readonly adoptedThreads: readonly number[];
  /** Registered threads whose conversation is missing from the store (left as is, reported). */
  readonly missingThreads: readonly number[];
  /** Conversations with live runs or queued input at open; scheduling resumed them. */
  readonly resumedConversations: readonly number[];
  /** Untitled threads with a first message whose title generation was restarted. */
  readonly retitledThreads: readonly number[];
};

export class NotFoundError extends Error {
  override name = "NotFoundError";
}

/** A request that breaks a bot rule (Admin Bot is locked; teams are one level deep). */
export class BotRuleError extends Error {
  override name = "BotRuleError";
}

export const ADMIN_NAME = "Admin Bot";

/** A bot name: trimmed, 1-80 characters. */
function checkName(name: string): string {
  const trimmed = name.trim();
  if (!trimmed) throw new Error("bot name is required");
  if (trimmed.length > 80) throw new Error("bot name is too long");
  return trimmed;
}

/** One bot: one Pi Durable session (Harness) over its prefixed tables in the shared database. */
export class Bot {
  /** The record as of opening, with the name kept current on rename. */
  record: BotRecord;
  readonly harness: Harness;
  readonly #registry: BotRegistry;
  readonly #titles: ThreadTitles | undefined;
  readonly #note: () => string | undefined;
  readonly #hasModel: () => boolean;

  constructor(
    record: BotRecord,
    harness: Harness,
    registry: BotRegistry,
    titles?: ThreadTitles,
    /** The fallback note for new turns while the bot runs a fallback main model. */
    note: () => string | undefined = () => undefined,
    /** False while the bot's profile has no main model: messages are refused. */
    hasModel: () => boolean = () => true,
  ) {
    this.record = record;
    this.harness = harness;
    this.#registry = registry;
    this.#titles = titles;
    this.#note = note;
    this.#hasModel = hasModel;
  }

  get id(): string {
    return this.record.id;
  }

  /** The main channel: the session's root conversation, one long-lived conversation. */
  main(): Promise<Conversation> {
    return this.harness.root(ctx);
  }

  /**
   * Point the main channel and every thread at `model` (a profile's main model). Conversations
   * already on it are left alone; a change applies from each one's next request. Returns how many
   * conversations changed.
   */
  async applyModel(model: ModelRef): Promise<number> {
    const ids = [(await this.main()).id];
    for (const thread of await this.#registry.listThreads(this.id)) {
      ids.push(toConversationId(thread.conversationId));
    }
    let changed = 0;
    for (const id of ids) {
      const conversation = await this.harness.conversation(id, ctx);
      if (!conversation) continue;
      const current = (await conversation.agent(ctx)).model;
      if (current?.provider === model.provider && current.modelId === model.modelId) continue;
      await this.harness.commit((tx) => configure(tx, id, defaultAgent(model)), ctx);
      changed += 1;
    }
    return changed;
  }

  /** The main channel when `conversationId` is omitted, otherwise one of this bot's threads. */
  async conversation(conversationId?: number): Promise<Conversation> {
    const main = await this.main();
    if (conversationId === undefined || conversationId === main.id) return main;
    const thread = await this.#registry.getThread(this.id, conversationId);
    if (!thread) throw new NotFoundError(`no thread ${conversationId} on bot ${this.id}`);
    const conversation = await this.harness.conversation(toConversationId(conversationId), ctx);
    if (!conversation) throw new NotFoundError(`thread ${conversationId} has no conversation`);
    return conversation;
  }

  /** Round metadata belongs to the placed input, not a later queued follow-up. */
  async round(conversationId: number): Promise<number> {
    const conversation = await this.conversation(conversationId);
    let cursor: import("@earendil-works/pi-durable").Cursor | undefined;
    do {
      const page = await conversation.entries({ order: "descending" }, 100, cursor, ctx);
      for (const entry of page.items) {
        if (!entry.model?.some((message) => message.role === "user")) continue;
        const data = entry.data;
        const round =
          data && typeof data === "object" && !Array.isArray(data) ? data.round : undefined;
        return entry.kind === "pibot.input" &&
          typeof round === "number" &&
          Number.isInteger(round) &&
          round >= 0
          ? round
          : 0;
      }
      cursor = page.next;
    } while (cursor !== undefined);
    return 0;
  }

  /**
   * Send a message to the main channel or a thread: a user message (round 0), or with `round` a
   * bot-to-bot message. The first message of an untitled thread also starts its title generation,
   * as Woven titles a conversation from its first prompt. While the bot runs a fallback main model,
   * the stored input starts with the fallback note (the chat hides it).
   */
  async send(
    text: string,
    conversationId?: number,
    round = 0,
    context?: string,
    options: { readonly hidden?: boolean } = {},
  ) {
    if (!this.#hasModel()) throw new Error(NO_MODEL_MESSAGE);
    const conversation = await this.conversation(conversationId);
    const note = this.#note();
    const submission = await conversation.submit(
      {
        type: "input",
        content: [note, round === 0 && context ? contextNote(context) : undefined, text]
          .filter(Boolean)
          .join("\n\n"),
        whenBusy: "followUp",
        // Hidden inputs reach the model but never the chat (transcript.ts).
        entry: { kind: "pibot.input", data: options.hidden ? { round, hidden: true } : { round } },
      },
      ctx,
    );
    const main = await this.main();
    if (conversation.id !== main.id) this.#titles?.request(this.id, conversation.id, text);
    return { conversation, submission };
  }

  /**
   * Stop the main channel's or a thread's reply with Pi Durable's `Conversation.abort()`: queued
   * follow-ups are withdrawn (settled unanswered, never placed), the run and its tools and
   * subagents are aborted, and this resolves once the conversation is idle. A committed partial
   * reply stays in the transcript as an aborted assistant entry. Background work (compaction) is
   * left alone. A no-op on an idle conversation.
   */
  async abort(conversationId?: number): Promise<Conversation> {
    const conversation = await this.conversation(conversationId);
    await conversation.abort(ctx);
    return conversation;
  }

  /**
   * Fork a thread off any message of the main channel or another thread. The fork inherits the
   * context up to and including `entryId` as is: no compaction, no rewriting. Threads have no
   * user-visible name and cannot be renamed; a title is generated later from the first message.
   */
  async fork(options: {
    readonly fromConversationId?: number;
    readonly entryId: number;
  }): Promise<ThreadRecord> {
    const parent = await this.conversation(options.fromConversationId);
    const thread = await parent.fork(
      toEntryId(options.entryId),
      { ownership: { kind: "ownerless" } },
      ctx,
    );
    const record: ThreadRecord = {
      botId: this.id,
      conversationId: thread.id,
      parentConversationId: parent.id,
      forkedAt: options.entryId,
      title: "",
      createdAt: new Date().toISOString(),
    };
    await this.#registry.addThread(record);
    return record;
  }

  /**
   * Startup reconciliation, run before scheduling resumes. The Pi Durable store is the source of
   * truth, as in Woven Matter: a fork's parent edge is committed with the fork itself, so a crash
   * between `fork()` and the registry write leaves an ownerless fork that only the registry lacks.
   * Such forks are adopted as threads. Task-owned conversations (subagents) are not threads.
   */
  async reconcileThreads(): Promise<Pick<RecoveryReport, "adoptedThreads" | "missingThreads">> {
    const main = await this.main();
    const registered = new Map(
      (await this.#registry.listThreads(this.id)).map((thread) => [thread.conversationId, thread]),
    );
    // Read every conversation record in one read-only transaction; Session has no scan of its own.
    const records = await this.harness.commit(async (tx) => {
      const all: ConversationRecord[] = [];
      let cursor: Parameters<typeof tx.scanConversations>[2];
      do {
        const page = await tx.scanConversations({ order: "ascending" }, 200, cursor);
        all.push(...page.items);
        cursor = page.next;
      } while (cursor !== undefined);
      return all;
    }, ctx);
    const stored = new Set<number>(records.map((record) => record.id));
    const adoptedThreads: number[] = [];
    for (const conversation of records) {
      if (!isThreadFork(conversation, main.id) || registered.has(conversation.id)) continue;
      await this.#registry.addThread({
        botId: this.id,
        conversationId: conversation.id,
        parentConversationId: conversation.parent.conversationId,
        forkedAt: conversation.parent.at,
        title: "",
        createdAt: new Date().toISOString(),
      });
      adoptedThreads.push(conversation.id);
    }
    const missingThreads = [...registered.keys()].filter((id) => !stored.has(id));
    return { adoptedThreads, missingThreads };
  }

  /** The text of a thread's first own user message, or undefined before it has one. */
  async firstUserText(conversationId: number): Promise<string | undefined> {
    for await (const entry of this.ownEntries(conversationId)) {
      const shown = displayEntry(entry);
      if (shown?.role === "user" && shown.text.trim()) return shown.text;
    }
    return undefined;
  }

  /** The bot's own history: the main channel, then every thread (newest first) with its title. */
  async conversations(): Promise<{ readonly conversationId: number; readonly title: string }[]> {
    const main = await this.main();
    return [
      { conversationId: main.id, title: "" },
      ...(await this.#registry.listThreads(this.id)).map((thread) => ({
        conversationId: thread.conversationId,
        title: thread.title,
      })),
    ];
  }

  /**
   * A conversation's own entries, oldest first (`order: "descending"`: newest first), after entry
   * `afterId`. Entries a thread inherited from its parent are skipped: they belong to the parent.
   */
  async *ownEntries(
    conversationId: number,
    afterId = 0,
    order: "ascending" | "descending" = "ascending",
  ): AsyncGenerator<EntryRecord> {
    const conversation = await this.harness.conversation(toConversationId(conversationId), ctx);
    if (!conversation) return;
    let cursor: Parameters<Conversation["entries"]>[2];
    do {
      const page = await conversation.entries(
        { order, ...(afterId > 0 ? { minEntryId: toEntryId(afterId + 1) } : {}) },
        200,
        cursor,
        ctx,
      );
      for (const entry of page.items) {
        if (entry.conversationId === conversationId) yield entry;
      }
      cursor = page.next;
    } while (cursor !== undefined);
  }

  /**
   * Admin Bot's first turn right after the user picks its model in first-run setup, so its
   * greeting arrives without the user writing first. Only while its main channel is empty: it
   * happens once, never for other bots. Returns whether it started.
   */
  async greet(): Promise<boolean> {
    if (this.record.kind !== "admin") return false;
    const main = await this.main();
    const page = await main.entries({ order: "descending" }, 1, undefined, ctx);
    if (page.items.length > 0) return false;
    await this.send(GREETING_PROMPT, undefined, 0, undefined, { hidden: true });
    return true;
  }

  /** The newest entry id across the main channel and threads (0 for an empty bot). */
  async latestEntryId(): Promise<number> {
    let latest = 0;
    for (const { conversationId } of await this.conversations()) {
      const conversation = await this.harness.conversation(toConversationId(conversationId), ctx);
      const page = await conversation?.entries({ order: "descending" }, 1, undefined, ctx);
      latest = Math.max(latest, page?.items[0]?.id ?? 0);
    }
    return latest;
  }

  /** Every thread, newest first; with `query`, only threads whose title matches every term. */
  threads(query?: string): Promise<ThreadRecord[]> {
    return query?.trim()
      ? this.#registry.searchThreads(this.id, query)
      : this.#registry.listThreads(this.id);
  }
}

function isThreadFork(
  conversation: ConversationRecord,
  mainId: number,
): conversation is ConversationRecord & { parent: NonNullable<ConversationRecord["parent"]> } {
  return conversation.id !== mainId && conversation.parent !== undefined && !conversation.owner;
}

/**
 * Background thread titling. At most one request per thread at a time; the title is written only
 * while the thread is still untitled, so a late or repeated request never overwrites one.
 */
export class ThreadTitles {
  readonly #generator: TitleGenerator;
  readonly #registry: BotRegistry;
  readonly #onReport: (error: unknown) => void;
  readonly #onTitled: (botId: string, conversationId: number) => void;
  readonly #inFlight = new Map<string, Promise<void>>();
  readonly #abort = new AbortController();

  constructor(
    generator: TitleGenerator,
    registry: BotRegistry,
    onReport: (error: unknown) => void = () => {},
    onTitled: (botId: string, conversationId: number) => void = () => {},
  ) {
    this.#generator = generator;
    this.#registry = registry;
    this.#onReport = onReport;
    this.#onTitled = onTitled;
  }

  /** Title the thread from `firstPrompt` unless it already has a title or a request running. */
  request(botId: string, conversationId: number, firstPrompt: string): void {
    const key = `${botId}:${conversationId}`;
    if (this.#abort.signal.aborted || this.#inFlight.has(key) || !firstPrompt.trim()) return;
    const run = (async () => {
      const thread = await this.#registry.getThread(botId, conversationId);
      if (!thread || thread.title) return;
      const title = await this.#generator.generate(firstPrompt, this.#abort.signal);
      if (await this.#registry.setThreadTitleIfUntitled(botId, conversationId, title)) {
        this.#onTitled(botId, conversationId);
      }
    })()
      .catch((error: unknown) => {
        if (!this.#abort.signal.aborted) this.#onReport(error);
      })
      .finally(() => this.#inFlight.delete(key));
    this.#inFlight.set(key, run);
  }

  /** Resolves once every running title request has settled (tests, shutdown). */
  async idle(): Promise<void> {
    while (this.#inFlight.size) await Promise.all(this.#inFlight.values());
  }

  async close(): Promise<void> {
    this.#abort.abort();
    await this.idle();
  }
}

export type BotManagerOptions = {
  /** The shared database. The manager never closes it. */
  readonly db: SqliteDatabase;
  /** Harness options for one bot (models, registry, default agent). */
  readonly harnessOptions: (bot: BotRecord, manager: BotManager) => BotHarnessOptions;
  readonly onBotClosed?: (bot: BotRecord, reason: string) => void;
  /** A bot's harness opened (at startup, on creation, after a restore or a reopen). */
  readonly onBotOpened?: (bot: Bot) => void;
  /** After a soft delete: release runtime resources (containers). Never delete bot data. */
  readonly onBotDeleted?: (bot: BotRecord) => Promise<void>;
  /**
   * After a purge: forget the bot elsewhere and remove its runtime environment and data (container,
   * workspace volume). Returns undefined without an environment; a throw is reported as not removed.
   */
  readonly onBotPurged?: (botId: string) => Promise<EnvironmentPurge | undefined>;
  /** After a restore: bring the bot's runtime environment (container) back up. */
  readonly onBotRestored?: (bot: BotRecord) => Promise<void>;
  /** Thread title generation (`[models.titles]`); threads stay untitled without it. */
  readonly titles?: TitleGenerator;
  readonly onReport?: (error: unknown) => void;
  /** Called once per opened bot with what startup recovery found. */
  readonly onRecovered?: (bot: BotRecord, report: RecoveryReport) => void;
  /** Create the Admin Bot on open when there is none (the app does; most tests do not). */
  readonly ensureAdmin?: boolean;
  /** A bot was created, deleted, restored or moved between teams (pushes a refresh to clients). */
  readonly onBotsChanged?: () => void;
  readonly onGroupsChanged?: () => void;
  /** A thread of this bot was titled (pushes a thread-list refresh to clients). */
  readonly onThreadsChanged?: (botId: string) => void;
  /**
   * Model profiles. With them, each open bot's main channel and threads follow its profile's main
   * model (on open, on `setProfile`, and on every profile change), and legacy per-bot model
   * overrides are migrated to profiles on open.
   */
  readonly profiles?: ProfileStore;
  /** Server-side log lines (model changes, migrations). */
  readonly log?: (message: string) => void;
  /**
   * Main-model usage limits shared by every bot. With it (and profiles), a bot whose main model is
   * out runs its profile's first available fallback, and goes back once the main model resets.
   */
  readonly availability?: ModelAvailability;
  /** A bot's main-model status changed (fallback, paused, returned). */
  readonly onModelStatus?: (botId: string, status: ModelStatus | undefined) => void;
};

/**
 * A bot's main-model status, for the chat banner. `fallback`: the profile's main model (and maybe
 * earlier fallbacks) is out and `active` runs instead; `paused`: every model in the chain is out;
 * `returned`: back on the main model after a fallback or pause (shown briefly).
 */
export type ModelStatus = {
  readonly kind: "fallback" | "paused" | "returned";
  readonly at: number;
  readonly primary: string;
  readonly active: string;
  /** The limited models, in fallback order (empty for `returned`). */
  readonly limits: readonly LimitEntry[];
};

/** Whether a purge removed the bot's environment (container and workspace volume). */
export type EnvironmentPurge = { readonly removed: boolean; readonly error?: string };

export type PurgeResult = {
  /** Tables of the bot's Pi Durable session that were dropped. */
  readonly tables: number;
  /** Undefined when bots have no environment backend. */
  readonly environment?: EnvironmentPurge;
};

/** How long a `returned` status is reported after the switch back. */
export const RETURNED_STATUS_MS = 10 * 60_000;

/** The hidden input that starts Admin Bot's first conversation (`Bot.greet`). */
export const GREETING_PROMPT =
  "[Automatic message from Woven Matter, not written by the user] The user just chose your model in first-run setup and opened this chat. Start your first conversation now, as your instructions describe.";

/** Why a bot can't take a message: its profile has no main model yet. */
export const NO_MODEL_MESSAGE =
  "No model selected yet. Choose one with Admin Bot or in Bot settings → Profiles.";

/** The model a profile runs right now: the first available of main and its fallbacks. */
export function effectiveModel(
  profile: Profile & { readonly main: string },
  availability: ModelAvailability | undefined,
): { readonly model: string; readonly limits: LimitEntry[]; readonly paused: boolean } {
  const limits: LimitEntry[] = [];
  for (const ref of [profile.main, ...(profile.fallbacks ?? [])]) {
    const limit = availability?.limit(ref);
    if (!limit) return { model: ref, limits, paused: false };
    limits.push(limit);
  }
  return { model: profile.main, limits, paused: true };
}

const hasMain = (profile: Profile): profile is Profile & { readonly main: string } =>
  typeof profile.main === "string" && profile.main.length > 0;

/**
 * Hosts every bot in this process. Each opened Harness has scheduling enabled (`resume()`), so
 * its own timers drive sleeping and retried tasks; this replaces Durable Object alarms.
 */
export class BotManager {
  readonly registry: BotRegistry;
  readonly titles: ThreadTitles | undefined;
  readonly #bots = new Map<string, Promise<Bot>>();
  /** Each live bot's assigned profile id (undefined: the default), kept in step with the registry. */
  readonly #assigned = new Map<string, string | undefined>();
  readonly #status = new Map<string, ModelStatus>();
  /** Serializes re-applying every bot's model after a limit is marked or ends. */
  #reapplying: Promise<void> = Promise.resolve();
  #closed = false;

  readonly #options: BotManagerOptions;

  private constructor(options: BotManagerOptions) {
    this.#options = options;
    this.registry = new BotRegistry(options.db);
    this.titles = options.titles
      ? new ThreadTitles(options.titles, this.registry, options.onReport, (botId) =>
          options.onThreadsChanged?.(botId),
        )
      : undefined;
  }

  static async open(options: BotManagerOptions): Promise<BotManager> {
    const manager = new BotManager(options);
    await manager.registry.migrate();
    await manager.#migrateLegacyModels();
    if (options.ensureAdmin) {
      if (await manager.registry.admin()) await manager.registry.renameAdmin(ADMIN_NAME);
      else await manager.#insert(ADMIN_NAME, { kind: "admin", manager: false });
    }
    options.profiles?.onChange(() => manager.#profilesChanged());
    options.availability?.onChange(() => void manager.#reapplyAll());
    // Live bots only: soft-deleted bots are neither loaded nor recovered.
    for (const record of await manager.registry.list()) await manager.get(record.id);
    return manager;
  }

  list(): Promise<BotRecord[]> {
    return this.registry.list();
  }

  get profiles(): ProfileStore | undefined {
    return this.#options.profiles;
  }

  /** The profile id a bot is assigned (undefined: the default profile). */
  assignedProfile(id: string): string | undefined {
    return this.#assigned.get(id);
  }

  /**
   * Assign a bot a profile (`undefined`: the default). Its main channel and threads switch to the
   * profile's main model from their next request.
   */
  async setProfile(id: string, profileId: string | undefined): Promise<BotRecord> {
    const profiles = this.#options.profiles;
    if (!profiles) throw new Error("model profiles are not available");
    await this.record(id);
    if (profileId !== undefined && !profiles.get(profileId)) {
      throw new NotFoundError(`no profile "${profileId}"`);
    }
    await this.registry.setProfile(id, profileId);
    this.#assigned.set(id, profileId);
    await this.#applyProfile(await this.get(id));
    this.#options.onBotsChanged?.();
    return this.record(id);
  }

  /** The profile a bot runs (undefined without profiles). */
  profileOf(id: string): Profile | undefined {
    return this.#options.profiles?.resolve(this.#assigned.get(id));
  }

  /**
   * Models for a bot's memory extraction, in order: its profile's memory extraction model, then the
   * main model it runs now (a fallback while main is limited), which is also the default when no
   * memory model is set. Limited models are skipped; the extractor tries the next one quietly.
   * Only memory extraction uses this: never chat, subagents or thread titles.
   */
  memoryModels(id: string): string[] {
    const profile = this.profileOf(id);
    if (!profile || !hasMain(profile)) return [];
    const availability = this.#options.availability;
    const candidates = [profile.memoryModel, effectiveModel(profile, availability).model].filter(
      (ref): ref is string => ref !== undefined && availability?.limit(ref) === undefined,
    );
    return [...new Set(candidates)];
  }

  /**
   * The note in front of a turn while a bot answers on a fallback main model because main is
   * limited (`fallbackNote`). With `conversationId`, only when that conversation runs the fallback
   * (subagent children do not).
   */
  async fallbackNote(id: string, conversationId?: number): Promise<string | undefined> {
    const note = this.#noteFor(id);
    if (!note || conversationId === undefined) return note;
    const bot = await this.#bots.get(id)?.catch(() => undefined);
    const conversation = await bot?.harness.conversation(toConversationId(conversationId), ctx);
    const model = conversation ? (await conversation.agent(ctx)).model : undefined;
    const active = this.#status.get(id)?.active;
    return model && `${model.provider}/${model.modelId}` === active ? note : undefined;
  }

  #hasModel(id: string): boolean {
    const profiles = this.#options.profiles;
    return !profiles || hasMain(profiles.resolve(this.#assigned.get(id)));
  }

  #noteFor(id: string): string | undefined {
    const status = this.#status.get(id);
    const limit = status?.limits[0];
    if (status?.kind !== "fallback" || !limit) return undefined;
    return fallbackNote(status.primary, limit.kind, status.active);
  }

  /** A bot's main-model status (fallback, paused, or recently returned); undefined: normal. */
  modelStatus(id: string): ModelStatus | undefined {
    const status = this.#status.get(id);
    if (status?.kind === "returned" && Date.now() - status.at > RETURNED_STATUS_MS)
      return undefined;
    return status;
  }

  /**
   * A request on `ref` hit a usage limit: mark it (for every bot) and move bots running it to their
   * next available fallback. Returns the model `conversationId` runs now when that changed, so the
   * failed request can be retried on it.
   */
  async reportLimit(
    botId: string,
    conversationId: number,
    ref: ModelRef,
    limit: Limit,
  ): Promise<string | undefined> {
    const availability = this.#options.availability;
    if (!availability) return undefined;
    const entry = availability.mark(ref, limit);
    this.#options.log?.(
      `usage limit: ${entry.model} (${entry.account}): ${entry.kind}${entry.resetsAt ? `, resets ${new Date(entry.resetsAt).toISOString()}` : ", reset unknown"}`,
    );
    await this.#reapplyAll();
    const bot = await this.#bots.get(botId)?.catch(() => undefined);
    const conversation = await bot?.harness.conversation(toConversationId(conversationId), ctx);
    const now = conversation ? (await conversation.agent(ctx)).model : undefined;
    if (!now || (now.provider === ref.provider && now.modelId === ref.modelId)) return undefined;
    return `${now.provider}/${now.modelId}`;
  }

  #reapplyAll(): Promise<void> {
    const run = async () => {
      if (this.#closed) return;
      for (const pending of [...this.#bots.values()]) {
        const bot = await pending.catch(() => undefined);
        if (bot) await this.#applyProfile(bot).catch((error) => this.#options.onReport?.(error));
      }
    };
    this.#reapplying = this.#reapplying.then(run, run);
    return this.#reapplying;
  }

  async #applyProfile(bot: Bot): Promise<void> {
    const profiles = this.#options.profiles;
    if (!profiles) return;
    const profile = profiles.resolve(this.#assigned.get(bot.id));
    // No main model yet: nothing to apply until the user picks one.
    if (!hasMain(profile)) return;
    const effective = effectiveModel(profile, this.#options.availability);
    const changed = await bot.applyModel(parseModelRef(effective.model));
    if (changed) {
      this.#options.log?.(
        `bot "${bot.record.name}": profile "${profile.id}", main model ${effective.model}${effective.model === profile.main ? "" : ` (fallback for ${profile.main})`} (${changed} conversation(s) updated)`,
      );
    }
    this.#updateStatus(bot, profile, effective);
  }

  #updateStatus(
    bot: Bot,
    profile: Profile & { readonly main: string },
    effective: ReturnType<typeof effectiveModel>,
  ): void {
    const previous = this.#status.get(bot.id);
    const kind = effective.paused
      ? "paused"
      : effective.model !== profile.main
        ? "fallback"
        : previous && previous.kind !== "returned"
          ? "returned"
          : undefined;
    if (!kind) return;
    const key = (status: Pick<ModelStatus, "kind" | "active" | "limits">) =>
      `${status.kind} ${status.active} ${status.limits.map((limit) => `${limit.model}@${limit.at}`).join(",")}`;
    const next: ModelStatus = {
      kind,
      at: Date.now(),
      primary: profile.main,
      active: effective.model,
      limits: kind === "returned" ? [] : effective.limits,
    };
    if (previous && key(previous) === key(next)) return;
    if (kind === "returned" && previous?.kind === "returned") return;
    this.#status.set(bot.id, next);
    this.#options.log?.(
      `bot "${bot.record.name}": ${kind === "paused" ? `paused (${profile.main} and every fallback are out)` : kind === "fallback" ? `on fallback ${effective.model} (${profile.main} is out)` : `back on ${profile.main}`}`,
    );
    this.#options.onModelStatus?.(bot.id, next);
  }

  /** After any profile change: deleted profiles fall back to the default, then models re-apply. */
  async #profilesChanged(): Promise<void> {
    const profiles = this.#options.profiles;
    if (!profiles || this.#closed) return;
    for (const [id, profileId] of this.#assigned) {
      if (profileId !== undefined && !profiles.get(profileId)) this.#assigned.set(id, undefined);
    }
    for (const record of [
      ...(await this.registry.list()),
      ...(await this.registry.listDeleted()),
    ]) {
      if (record.profile && !profiles.get(record.profile)) {
        await this.registry.clearProfile(record.profile);
      }
    }
    for (const pending of [...this.#bots.values()]) {
      const bot = await pending.catch(() => undefined);
      if (bot) await this.#applyProfile(bot).catch((error) => this.#options.onReport?.(error));
    }
    this.#options.onBotsChanged?.();
  }

  /**
   * Before profiles, a bot could have its own model. Turn each such override into a profile
   * assignment: a profile whose main model it is, or a new one copying the default's pool.
   */
  async #migrateLegacyModels(): Promise<void> {
    const profiles = this.#options.profiles;
    if (!profiles) return;
    for (const record of await this.registry.list()) {
      const legacy = record.legacyModel;
      if (!legacy) continue;
      try {
        await this.#migrateLegacyModel(profiles, record, legacy);
      } catch (error) {
        // Left as is (the bot runs the default profile meanwhile); retried on the next open.
        this.#options.log?.(
          `could not migrate bot "${record.name}" model ${legacy}: ${(error as Error).message}`,
        );
      }
    }
  }

  async #migrateLegacyModel(
    profiles: ProfileStore,
    record: BotRecord,
    legacy: string,
  ): Promise<void> {
    if (!record.profile) {
      const fallback = profiles.resolve(undefined);
      let target =
        fallback.main === legacy ? fallback : profiles.list().find((p) => p.main === legacy);
      if (!target) {
        const base = record.name
          .toLowerCase()
          .replace(/[^a-z0-9]+/g, "-")
          .replace(/^-+|-+$/g, "");
        let id = (base || "bot").slice(0, 32);
        for (let n = 2; profiles.get(id); n += 1) id = `${(base || "bot").slice(0, 32)}-${n}`;
        target = await profiles.save(
          {
            id,
            name: record.name,
            main: legacy,
            pool: fallback.pool.map((entry) => ({ ...entry })),
            ...(fallback.memoryModel ? { memoryModel: fallback.memoryModel } : {}),
            ...(fallback.guidance ? { guidance: fallback.guidance } : {}),
          },
          { create: true },
        );
      }
      if (target.id !== profiles.defaultId) await this.registry.setProfile(record.id, target.id);
      this.#options.log?.(
        `migrated bot "${record.name}" model ${legacy} to profile "${target.id}"`,
      );
    }
    await this.registry.clearLegacyModel(record.id);
  }

  /** The Admin Bot (undefined only without `ensureAdmin`). */
  admin(): Promise<BotRecord | undefined> {
    return this.registry.admin();
  }

  /** A live bot's record, or a NotFoundError. */
  async record(id: string): Promise<BotRecord> {
    const record = await this.registry.get(id);
    if (!record) throw new NotFoundError(`no bot ${id}`);
    return record;
  }

  /**
   * Create a bot. With `managerId` it joins that manager's team. `createdBy` is the bot that
   * asked for it (an agent tool): a bot created by a manager or a team member joins that team.
   */
  async create(
    name: string,
    options: { readonly managerId?: string; readonly createdBy?: string } = {},
  ): Promise<BotRecord> {
    let managerId = options.managerId;
    if (managerId === undefined && options.createdBy) {
      const creator = await this.record(options.createdBy);
      managerId = creator.manager ? creator.id : creator.managerId;
    }
    if (managerId !== undefined) await this.#requireManager(managerId);
    const record = await this.#insert(name, {
      kind: "bot",
      manager: false,
      ...(managerId ? { managerId } : {}),
    });
    this.#options.onBotsChanged?.();
    return record;
  }

  async #insert(
    name: string,
    team: Pick<BotRecord, "kind" | "manager" | "managerId">,
  ): Promise<BotRecord> {
    const trimmed = checkName(name);
    const id = randomUUID();
    const record: BotRecord = {
      id,
      name: trimmed,
      prefix: botPrefix(id),
      createdAt: new Date().toISOString(),
      orchestrator: false,
      ...team,
    };
    await this.registry.insert(record);
    try {
      const bot = await this.get(id);
      await bot.main();
    } catch (error) {
      // A half-created bot is soft-deleted like any other; its tables stay until the user purges it.
      await this.delete(id).catch(() => {});
      throw error;
    }
    return record;
  }

  /** The open bot, opening (or reopening after a failure) its Harness on demand. */
  get(id: string): Promise<Bot> {
    if (this.#closed) return Promise.reject(new Error("bot manager is closed"));
    let bot = this.#bots.get(id);
    if (!bot) {
      bot = this.#open(id);
      this.#bots.set(id, bot);
      bot.catch(() => this.#bots.delete(id));
    }
    return bot;
  }

  async #open(id: string): Promise<Bot> {
    const record = await this.registry.get(id);
    if (!record) {
      // Soft-deleted bots are never opened, so never recovered or messaged.
      if (await this.registry.deletedAt(id)) throw new NotFoundError(`bot ${id} was deleted`);
      throw new NotFoundError(`no bot ${id}`);
    }
    const storage = await SqliteStorage.open(sharedDatabaseView(this.#options.db), {
      prefix: record.prefix,
    });
    this.#assigned.set(id, record.profile);
    const { attach, ...options } = this.#options.harnessOptions(record, this);
    const harness = await Harness.open(storage, options, ctx);
    attach?.(harness);
    const bot = new Bot(
      record,
      harness,
      this.registry,
      this.titles,
      () => this.#noteFor(id),
      () => this.#hasModel(id),
    );
    let report: RecoveryReport;
    try {
      report = await this.#recover(bot);
      await this.#applyProfile(bot);
    } catch (error) {
      await harness.close(ctx).catch(() => {});
      throw error;
    }
    void harness.closed.then((end) => {
      const current = this.#bots.get(id);
      void current?.then((bot) => {
        if (bot.harness === harness) this.#bots.delete(id);
      });
      this.#options.onBotClosed?.(record, end.kind);
    });
    this.#options.onRecovered?.(record, report);
    this.#options.onBotOpened?.(bot);
    return bot;
  }

  /**
   * Woven Matter's load path (`engine.mjs` `create`): reinstall the host around committed work,
   * inspect it, then resume scheduling so interrupted runs and queued input continue. Pi Durable's
   * open already reconciled interrupted invocations; `resume()` lets them run again.
   */
  async #recover(bot: Bot): Promise<RecoveryReport> {
    // `#open` rejects soft-deleted bots before a harness exists, so they never reach recovery.
    const { harness } = bot;
    const threads = await bot.reconcileThreads();
    const live = await harness.inspect(ctx);
    const resumed = new Set<number>();
    for (const submission of live.submissions) resumed.add(submission.conversationId);
    for (const task of live.tasks) resumed.add(task.record.conversationId);
    harness.resume();
    const retitledThreads: number[] = [];
    if (this.titles) {
      for (const thread of await this.registry.listThreads(bot.id)) {
        if (thread.title || threads.missingThreads.includes(thread.conversationId)) continue;
        const first = await bot.firstUserText(thread.conversationId);
        if (!first) continue;
        this.titles.request(bot.id, thread.conversationId, first);
        retitledThreads.push(thread.conversationId);
      }
    }
    return { ...threads, resumedConversations: [...resumed], retitledThreads };
  }

  /**
   * Soft-delete a bot. Only the user deletes bots (the WebSocket `bots.delete` request); no agent
   * or orchestrator tool may call this. The registry row is marked deleted first, so no new open
   * can start, then the in-memory harness is closed and evicted and the bot's runtime environment
   * released. Its tables, threads and data stay in the database, so `restore()` can bring it back
   * (from Settings → Bots → Deleted bots); only the user's explicit `purge()` removes it for good.
   */
  async delete(id: string): Promise<boolean> {
    const record = await this.registry.get(id);
    if (!record) return false;
    if (record.kind === "admin") throw new BotRuleError("the Admin Bot cannot be deleted");
    if (!(await this.registry.markDeleted(id))) return false;
    // Deleting a manager ungroups its team; a deleted bot comes back on no team. Deleting the orchestrator
    // bot just clears the slot.
    if (record.manager) await this.registry.moveMembers(id, undefined);
    await this.registry.setTeam(id, { manager: false });
    if (record.orchestrator) await this.registry.setOrchestrator(undefined);
    this.#options.onBotsChanged?.();
    const open = this.#bots.get(id);
    this.#bots.delete(id);
    if (open) {
      const bot = await open.catch(() => undefined);
      if (bot) await bot.harness.close(ctx);
    }
    await this.#options.onBotDeleted?.(record).catch((error: unknown) => {
      this.#options.log?.(`bot ${id}: deleted; environment stop failed: ${String(error)}`);
    });
    return true;
  }

  /** Soft-deleted bots, for the user's Settings → Bots → Deleted bots. User-only, like `delete`. */
  listDeleted(): Promise<DeletedBotRecord[]> {
    return this.registry.listDeleted();
  }

  /**
   * Permanently remove a soft-deleted bot: the user's explicit "Delete permanently" in Settings →
   * Bots → Deleted bots (`bots.purge`); no agent or orchestrator tool may call this. Live bots and
   * the Admin Bot are refused. The database part (registry row, threads, every table of its Pi
   * Durable session) is one transaction; then `onBotPurged` removes its container and workspace
   * volume. An environment failure does not undo the data purge; it is reported in the result.
   */
  async purge(id: string): Promise<PurgeResult> {
    if (this.#closed) throw new Error("bot manager is closed");
    if ((await this.registry.admin())?.id === id) {
      throw new BotRuleError("the Admin Bot cannot be deleted");
    }
    if (await this.registry.get(id)) {
      throw new BotRuleError("only deleted bots can be deleted permanently; delete it first");
    }
    const tables = await this.registry.purge(id);
    if (!tables) throw new NotFoundError(`no deleted bot ${id}`);
    this.#bots.delete(id);
    this.#assigned.delete(id);
    this.#status.delete(id);
    let environment: EnvironmentPurge | undefined;
    try {
      environment = await this.#options.onBotPurged?.(id);
    } catch (error) {
      environment = {
        removed: false,
        error: error instanceof Error ? error.message : String(error),
      };
    }
    this.#options.log?.(
      `bot ${id}: purged (${tables.length} tables)${environment && !environment.removed ? `; environment not removed: ${environment.error}` : ""}`,
    );
    this.#options.onBotsChanged?.();
    this.#options.onGroupsChanged?.();
    return { tables: tables.length, ...(environment ? { environment } : {}) };
  }

  /**
   * Restore a soft-deleted bot (user-only: no agent or orchestrator tool may call this). Clears
   * `deleted_at`, then opens the bot as on a normal load: its history and threads are intact, it
   * goes through startup recovery, and its environment is re-acquired lazily through
   * `harnessOptions`. Returns undefined for an unknown or live bot.
   */
  async restore(id: string): Promise<BotRecord | undefined> {
    if (this.#closed) throw new Error("bot manager is closed");
    if (!(await this.registry.restore(id))) return undefined;
    const bot = await this.get(id);
    await this.#options.onBotRestored?.(bot.record);
    this.#options.onBotsChanged?.();
    return this.record(id);
  }

  async #requireManager(id: string): Promise<BotRecord> {
    const manager = await this.registry.get(id);
    if (!manager) throw new NotFoundError(`no bot ${id}`);
    if (!manager.manager) throw new BotRuleError(`${manager.name} is not a manager`);
    return manager;
  }

  async #requireTeamable(id: string): Promise<BotRecord> {
    const record = await this.record(id);
    if (record.kind === "admin") throw new BotRuleError("the Admin Bot is never on a team");
    return record;
  }

  /**
   * Promote a bot to manager (it leaves any team it was on: managers have no manager) or demote
   * it (its team is ungrouped).
   */
  async setManager(id: string, manager: boolean): Promise<BotRecord> {
    const record = await this.#requireTeamable(id);
    if (manager) {
      await this.registry.setTeam(id, { manager: true });
    } else if (record.manager) {
      await this.registry.moveMembers(id, undefined);
      await this.registry.setTeam(id, { manager: false });
    }
    this.#options.onBotsChanged?.();
    return this.record(id);
  }

  /** Put a bot on `managerId`'s team, or off any team with `undefined`. */
  async setTeam(id: string, managerId: string | undefined): Promise<BotRecord> {
    const record = await this.#requireTeamable(id);
    if (managerId !== undefined) {
      if (record.manager) throw new BotRuleError(`${record.name} is a manager; demote it first`);
      if (record.orchestrator) {
        throw new BotRuleError(
          `${record.name} is the orchestrator, above every team; clear it first`,
        );
      }
      if (managerId === id) throw new BotRuleError("a bot cannot manage itself");
      await this.#requireManager(managerId);
    }
    await this.registry.setTeam(id, {
      manager: record.manager,
      ...(managerId ? { managerId } : {}),
    });
    this.#options.onBotsChanged?.();
    return this.record(id);
  }

  /**
   * Give a team a new manager: `newManagerId` is promoted and takes over every member, and the old
   * manager stays on the team as a member (unless it is the orchestrator, which is never on a team).
   */
  async replaceManager(managerId: string, newManagerId: string): Promise<BotRecord> {
    const old = await this.#requireManager(managerId);
    const next = await this.#requireTeamable(newManagerId);
    if (next.id === old.id) return old;
    if (next.manager) throw new BotRuleError(`${next.name} already manages a team`);
    await this.registry.setTeam(next.id, { manager: true });
    await this.registry.moveMembers(old.id, next.id, next.id);
    await this.registry.setTeam(old.id, {
      manager: false,
      ...(old.orchestrator ? {} : { managerId: next.id }),
    });
    this.#options.onBotsChanged?.();
    return this.record(next.id);
  }

  /**
   * Make a bot the orchestrator (it leaves any team it was on; a team it manages stays), replacing the
   * current one, which becomes a normal bot and keeps its team. `undefined` clears the slot.
   * Returns the new orchestrator.
   */
  async setOrchestrator(id: string | undefined): Promise<BotRecord | undefined> {
    if (id !== undefined) {
      const record = await this.record(id);
      if (record.kind === "admin")
        throw new BotRuleError("the Admin Bot can't be the orchestrator");
    }
    await this.registry.setOrchestrator(id);
    this.#options.onBotsChanged?.();
    return id === undefined ? undefined : this.record(id);
  }

  listGroups() {
    return this.registry.listGroups();
  }

  async createGroup(name: string) {
    const group = await this.registry.createGroup(checkName(name));
    this.#options.onGroupsChanged?.();
    return group;
  }

  async renameGroup(id: string, name: string) {
    const group = await this.registry.renameGroup(id, checkName(name));
    this.#options.onGroupsChanged?.();
    return group;
  }

  async deleteGroup(id: string) {
    await this.registry.deleteGroup(id);
    this.#options.onGroupsChanged?.();
    this.#options.onBotsChanged?.();
  }

  async reorderGroups(ids: readonly string[]) {
    const groups = await this.registry.reorderGroups(ids);
    this.#options.onGroupsChanged?.();
    return groups;
  }

  async setGroup(id: string, groupId: string | null): Promise<BotRecord> {
    const record = await this.record(id);
    if (record.kind === "admin") throw new BotRuleError("the Admin Bot cannot be grouped");
    if (
      groupId !== null &&
      !(await this.registry.listGroups()).some((group) => group.id === groupId)
    )
      throw new NotFoundError("no such group");
    await this.registry.setGroup(id, groupId);
    this.#options.onGroupsChanged?.();
    this.#options.onBotsChanged?.();
    return this.record(id);
  }

  /**
   * Rename a bot. Admin Bot keeps its fixed name; every other bot (the orchestrator and managers
   * included) can be renamed freely. Roles never change a name.
   */
  async rename(id: string, name: string): Promise<BotRecord> {
    const record = await this.record(id);
    if (record.kind === "admin") throw new BotRuleError(`the Admin Bot is always "${ADMIN_NAME}"`);
    const trimmed = checkName(name);
    if (trimmed !== record.name) {
      await this.registry.rename(id, trimmed);
      const open = await this.#bots.get(id)?.catch(() => undefined);
      if (open) open.record = { ...open.record, name: trimmed };
      this.#options.onBotsChanged?.();
    }
    return this.record(id);
  }

  /**
   * Live runs across every open bot: queued submissions plus running tasks, from Pi Durable's
   * inspection. A graceful restart waits for this to reach zero (bounded), and Pi Durable resumes
   * whatever is still live when the next process opens the bots.
   */
  async activeWork(): Promise<number> {
    let count = 0;
    for (const pending of [...this.#bots.values()]) {
      const bot = await pending.catch(() => undefined);
      if (!bot) continue;
      const live = await bot.harness.inspect(ctx).catch(() => undefined);
      if (live) count += live.submissions.length + live.tasks.length;
    }
    return count;
  }

  async close(): Promise<void> {
    this.#closed = true;
    await this.titles?.close();
    const bots = [...this.#bots.values()];
    this.#bots.clear();
    for (const pending of bots) {
      const bot = await pending.catch(() => undefined);
      if (bot) await bot.harness.close(ctx);
    }
  }
}
