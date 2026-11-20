import { z } from "zod";
import { MAX_EDITED_FACT_CHARS } from "./memory.ts";
import type { DisplayEntry } from "./transcript.ts";

const botId = z.string().uuid();
const conversationId = z.number().int().nonnegative();
const modelRefText = z.string().min(3).max(200);
const requestId = z.union([z.string().max(64), z.number().int()]);
const roomId = z.number().int().positive();
const postId = z.number().int().positive();
const factText = z.string().min(1).max(MAX_EDITED_FACT_CHARS);

/** Client → server requests. Every request carries an `id` echoed in its result or error. */
export const requestSchema = z.discriminatedUnion("type", [
  z.strictObject({ id: requestId, type: z.literal("groups.list") }),
  z.strictObject({
    id: requestId,
    type: z.literal("groups.create"),
    name: z.string().trim().min(1).max(80),
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("groups.rename"),
    groupId: botId,
    name: z.string().trim().min(1).max(80),
  }),
  z.strictObject({ id: requestId, type: z.literal("groups.delete"), groupId: botId }),
  z.strictObject({
    id: requestId,
    type: z.literal("groups.reorder"),
    groupIds: z.array(botId).max(1000),
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("bots.setGroup"),
    botId,
    groupId: botId.nullable(),
  }),
  z.object({ id: requestId, type: z.literal("bots.list") }),
  z.object({
    id: requestId,
    type: z.literal("bots.create"),
    name: z.string().min(1).max(80),
    managerId: botId.optional(),
  }),
  // The Admin Bot is rejected: it cannot be deleted.
  z.object({ id: requestId, type: z.literal("bots.delete"), botId }),
  // User-only, from Settings → Bots → Deleted bots. Never exposed to agent tools.
  z.object({ id: requestId, type: z.literal("bots.listDeleted") }),
  z.object({ id: requestId, type: z.literal("bots.restore"), botId }),
  // User-only "Delete permanently": a soft-deleted bot's data, container and workspace volume.
  // Live bots and the Admin Bot are refused. Never exposed to agent tools.
  z.strictObject({ id: requestId, type: z.literal("bots.purge"), botId }),
  // Rename any bot but Admin Bot (its name is fixed).
  z.strictObject({
    id: requestId,
    type: z.literal("bots.rename"),
    botId,
    name: z.string().min(1).max(80),
  }),
  // Teams (Settings → Bots). One level: managers have no manager; Admin Bot is never on a team.
  z.strictObject({
    id: requestId,
    type: z.literal("bots.setManager"),
    botId,
    manager: z.boolean(),
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("bots.setTeam"),
    botId,
    managerId: botId.nullable(),
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("bots.replaceManager"),
    managerId: botId,
    newManagerId: botId,
  }),
  // The optional orchestrator (at most one, above every team; never Admin Bot). null clears it.
  z.strictObject({
    id: requestId,
    type: z.literal("bots.setOrchestrator"),
    botId: botId.nullable(),
  }),
  // First-run onboarding: sign in to a provider, then (if Admin Bot's profile's main model is
  // not available) pick that main model; Admin Bot then sets up profiles in chat.
  z.strictObject({ id: requestId, type: z.literal("onboarding.status") }),
  z.strictObject({
    id: requestId,
    type: z.literal("onboarding.setMainModel"),
    model: modelRefText,
  }),
  // Model profiles (live, no restart).
  z.strictObject({ id: requestId, type: z.literal("profiles.list") }),
  z.strictObject({
    id: requestId,
    type: z.literal("profiles.save"),
    create: z.boolean().optional(),
    profile: z.strictObject({
      id: z.string().max(40),
      name: z.string().max(80),
      main: modelRefText,
      fallbacks: z.array(modelRefText).max(5).optional(),
      /** Memory extraction model; omitted or null: the active main model. */
      memoryModel: modelRefText.nullable().optional(),
      /** Model preferences. */
      guidance: z.string().max(4000).optional(),
      pool: z
        .array(z.strictObject({ model: modelRefText, useFor: z.string().max(500).optional() }))
        .max(50),
    }),
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("profiles.delete"),
    profileId: z.string().max(40),
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("profiles.setDefault"),
    profileId: z.string().max(40),
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("bots.setProfile"),
    botId: z.string(),
    profileId: z.string().max(40).nullable(),
  }),
  // A bot's memory (Settings → Bots → Memory), user-only. Facts are named by their current text;
  // each change pushes `memory.changed`. Results are the bot's facts after the change.
  z.strictObject({ id: requestId, type: z.literal("memory.list"), botId }),
  z.strictObject({ id: requestId, type: z.literal("memory.add"), botId, text: factText }),
  z.strictObject({
    id: requestId,
    type: z.literal("memory.update"),
    botId,
    fact: factText,
    text: factText,
  }),
  z.strictObject({ id: requestId, type: z.literal("memory.delete"), botId, fact: factText }),
  z.strictObject({ id: requestId, type: z.literal("account.notes") }),
  z.strictObject({
    id: requestId,
    type: z.literal("account.setNotes"),
    notes: z.string().max(8000),
  }),
  z.object({
    id: requestId,
    type: z.literal("conversation.open"),
    botId,
    conversationId: conversationId.optional(),
  }),
  z.object({
    id: requestId,
    type: z.literal("conversation.close"),
    botId,
    conversationId,
    subscriptionId: requestId.optional(),
  }),
  // Stop the conversation's reply (the main channel when `conversationId` is omitted) and drop
  // its queued follow-ups. The partial reply stays, marked `stopped`.
  z.strictObject({
    id: requestId,
    type: z.literal("conversation.abort"),
    botId,
    conversationId: conversationId.optional(),
  }),
  z.object({
    id: requestId,
    type: z.literal("message.send"),
    botId,
    conversationId: conversationId.optional(),
    /** Starts a new thread for this message instead of using `conversationId`. */
    newThread: z.literal(true).optional(),
    text: z.string().min(1).max(100_000),
    context: z.string().max(4000).optional(),
    /** Set by the server: a retry with the same id is accepted without submitting again. */
    deliveryId: z.string().min(1).max(128).optional(),
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("thread.fork"),
    botId,
    conversationId: conversationId.optional(),
    entryId: z.number().int().nonnegative(),
    // Strict: a fork takes no title (`thread.setTitle` names a thread).
  }),
  // A title the person gives a thread in Woven; it replaces the generated one.
  z.strictObject({
    id: requestId,
    type: z.literal("thread.setTitle"),
    botId,
    conversationId,
    title: z.string().trim().min(1).max(200),
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("thread.setPinned"),
    botId,
    conversationId,
    pinned: z.boolean(),
  }),
  // Delete a thread at the source, stopping its turn first; the main channel is refused.
  z.strictObject({ id: requestId, type: z.literal("thread.delete"), botId, conversationId }),
  z.object({
    id: requestId,
    type: z.literal("threads.list"),
    botId,
    /** Search thread titles (every term must match). */
    query: z.string().max(200).optional(),
  }),
  // Read-only connection status: provider connections live in Woven settings.
  z.strictObject({ id: requestId, type: z.literal("settings.accounts") }),
  z.strictObject({ id: requestId, type: z.literal("models.catalog") }),
  z.strictObject({
    id: requestId,
    type: z.literal("models.setRoles"),
    titles: modelRefText.optional(),
    titlesReasoning: z.string().max(16).optional(),
  }),
  // A bot's container: state, idle status and restart list.
  z.strictObject({ id: requestId, type: z.literal("bots.environment"), botId }),
  // Recreate a bot's container from a clean image, keeping its storage.
  z.strictObject({ id: requestId, type: z.literal("bots.rebuild"), botId }),
  // Stop a bot's container now (it starts again on the next tool call).
  z.strictObject({ id: requestId, type: z.literal("bots.stop"), botId }),
  // Update bots in place (all, or the listed ones): stop running work, snapshot, update,
  // health-check, roll back on failure. Progress arrives as `runtime.update` pushes.
  z.strictObject({
    id: requestId,
    type: z.literal("runtime.update"),
    botIds: z.array(botId).max(1000).optional(),
  }),
  z.strictObject({ id: requestId, type: z.literal("runtime.status") }),
  // The Forum: one group chat of the user and every bot, with threads (`forum.ts`).
  z.strictObject({ id: requestId, type: z.literal("forum.get") }),
  z.strictObject({ id: requestId, type: z.literal("forum.open"), roomId: roomId.optional() }),
  z.strictObject({
    id: requestId,
    type: z.literal("forum.close"),
    roomId,
    subscriptionId: requestId.optional(),
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("forum.posts"),
    roomId,
    before: postId,
    limit: z.number().int().min(1).max(200).optional(),
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("forum.post"),
    /** The Forum itself when omitted, otherwise a thread. */
    roomId: roomId.optional(),
    text: z.string().min(1).max(100_000),
    /** Bots the user asks for a reply. */
    mentions: z.array(botId).max(1000).optional(),
    /** Ask every bot in the room. */
    everyone: z.boolean().optional(),
    /** Set by the server: an agent session posts for the user, by its name. */
    agent: z.string().trim().min(1).max(200).optional(),
    deliveryId: z.string().min(1).max(128).optional(),
  }),
  z.strictObject({ id: requestId, type: z.literal("forum.thread.create"), postId }),
  z.strictObject({
    id: requestId,
    type: z.literal("forum.thread.setTitle"),
    roomId,
    title: z.string().trim().min(1).max(200),
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("forum.thread.setPinned"),
    roomId,
    pinned: z.boolean(),
  }),
  // Delete a Forum thread with its posts, stopping its turns first; the Forum itself is refused.
  z.strictObject({ id: requestId, type: z.literal("forum.thread.delete"), roomId }),
  z.strictObject({ id: requestId, type: z.literal("forum.setPaused"), paused: z.boolean() }),
  z.strictObject({
    id: requestId,
    type: z.literal("forum.setBotActive"),
    botId,
    active: z.boolean(),
  }),
  z.strictObject({ id: requestId, type: z.literal("forum.schedules.list") }),
  z.strictObject({
    id: requestId,
    type: z.literal("forum.schedules.save"),
    schedule: z.strictObject({
      id: z.string().min(1).max(64).optional(),
      text: z.string().min(1).max(100_000),
      mentions: z.array(botId).max(1000).optional(),
      everyone: z.boolean().optional(),
      repeat: z.enum(["once", "daily", "weekdays", "weekly"]),
      /** `HH:MM` in `timeZone`, for a repeating post. */
      time: z.string().max(5).optional(),
      weekday: z.number().int().min(0).max(6).optional(),
      /** Epoch ms, for `once`. */
      at: z.number().int().positive().optional(),
      timeZone: z.string().min(1).max(64),
    }),
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("forum.schedules.delete"),
    scheduleId: z.string().min(1).max(64),
  }),
  // What bots call the user ("" clears it).
  z.strictObject({ id: requestId, type: z.literal("user.get") }),
  z.strictObject({ id: requestId, type: z.literal("user.setName"), name: z.string().max(80) }),
]);

export type Request = z.infer<typeof requestSchema>;
export type RequestType = Request["type"];

export type BotSummary = {
  id: string;
  name: string;
  createdAt: string;
  kind: "admin" | "bot";
  manager: boolean;
  managerId?: string;
  groupId?: string;
  /** The one optional orchestrator, above every team. */
  orchestrator: boolean;
  /** The profile this bot runs (its own or the default). */
  profileId: string;
  profileName: string;
  /** Runs the default profile (no profile of its own). */
  defaultProfile: boolean;
  /** Set while the main model is out (fallback or paused), and briefly after it returns. */
  modelStatus?: ModelStatusSummary;
};

/** A limited main model: only what the provider said (kind, and reset when it gave one). */
export type ModelLimitSummary = {
  model: string;
  /** e.g. "ChatGPT account", "OpenRouter key". */
  account: string;
  kind: "five_hour" | "weekly" | "usage" | "credits";
  /** Epoch ms, only when the provider returned it. */
  resetsAt?: number;
  /** Epoch ms: when it is tried again (the reset, or a cooldown when unknown). */
  retryAt: number;
};
export type ModelStatusSummary = {
  kind: "fallback" | "paused" | "returned";
  /** Epoch ms of the change. */
  at: number;
  primary: string;
  active: string;
  limits: ModelLimitSummary[];
};

export type PoolModelSummary = { model: string; useFor: string };
export type ProfileSummary = {
  id: string;
  name: string;
  main: string;
  /** Ordered main-model fallbacks for usage limits (absent: none). */
  fallbacks?: string[];
  /** Memory extraction model (absent: the active main model). */
  memoryModel?: string;
  /** Model preferences. */
  guidance?: string;
  pool: PoolModelSummary[];
  default?: boolean;
};
export type ProfilesList = { defaultId: string; profiles: ProfileSummary[] };

export type OnboardingStatus = {
  adminId: string;
  /** Admin Bot's profile and its main model ("" until one is chosen). */
  profileId: string;
  mainModel: string;
  /** The main model belongs to a signed-in (or keyed) provider. */
  mainModelAvailable: boolean;
  /** Any model provider account is configured. */
  signedIn: boolean;
  /** Show onboarding: nothing is signed in, or Admin Bot's main model is not available. */
  needed: boolean;
};
export type DeletedBotSummary = BotSummary & { deletedAt: string };
export type ThreadSummary = {
  pinned?: true;
  conversationId: number;
  parentConversationId: number;
  forkedAt: number;
  /** Generated from the first message (empty until then); shown in the sidebar and header. */
  title?: string;
  createdAt: string;
};

/** One Forum post, in the Forum itself or in a thread. */
export type ForumPost = {
  /** Grows across every room; a post never changes its id or text. */
  id: number;
  roomId: number;
  /** `agent`: an agent session posted for the user through the Woven tools. */
  author: "user" | "bot" | "agent";
  botId?: string;
  /** The author's name when it posted ("" for a user without one); an agent session's name. */
  name: string;
  text: string;
  /** Bots the user asked for a reply. */
  mentions?: string[];
  /** Posted by the runtime at a time the user set. */
  scheduled?: true;
  /** A bot's final message, posted for it because it owed the user a reply. */
  auto?: true;
  createdAt: string;
  /** A Forum post's thread and how many posts it holds. */
  thread?: { roomId: number; replies: number };
  /** Mentioned bots that could not answer, and why. */
  unanswered?: { botId: string; name: string; reason: string; issue?: "signIn" | "limit" }[];
};

export type ForumThreadSummary = {
  roomId: number;
  parentPostId: number;
  /** Generated from the thread's first post (absent until then). */
  title?: string;
  /** The start of the thread's first post, or of the post it came from while it is empty. */
  preview: string;
  createdAt: string;
  pinned?: true;
  replies: number;
  /** Bots that hear the thread. */
  botIds: string[];
};

export type ForumState = {
  mainRoomId: number;
  paused: boolean;
  latestPostId: number;
  /** Every live bot and whether it is in the Forum. */
  bots: { botId: string; active: boolean }[];
  threads: ForumThreadSummary[];
};

export type ForumRoomSnapshot = {
  subscriptionId?: string | number;
  roomId: number;
  mainRoomId: number;
  /** A thread's starting post. */
  parent?: ForumPost;
  /** The newest posts, oldest first. */
  posts: ForumPost[];
  hasEarlier: boolean;
  /** Bots with a turn running in this room. */
  thinking: string[];
};

export type ForumScheduleSummary = {
  id: string;
  text: string;
  mentions?: string[];
  everyone?: true;
  repeat: "once" | "daily" | "weekdays" | "weekly";
  time?: string;
  weekday?: number;
  at?: number;
  timeZone: string;
  /** Epoch ms of the next post, when there is one. */
  nextAt?: number;
};

export type ConversationSnapshot = {
  subscriptionId?: string | number;
  botId: string;
  conversationId: number;
  mainConversationId: number;
  /** The starting message, also included when it falls outside the recent history window. */
  threadOrigin?: DisplayEntry;
  /** Oldest first; inherited entries carry their parent's conversationId. */
  entries: DisplayEntry[];
  running: boolean;
  /** Text of an assistant message still being generated when the conversation was opened. */
  streaming?: string;
};

export type StreamEvent =
  | { kind: "run"; state: "start" | "end" }
  | { kind: "assistant_start"; text: string }
  | { kind: "delta"; text: string }
  | { kind: "entry"; entry: DisplayEntry }
  | { kind: "error"; message: string };

/** Runtime → server messages on the one connection: replies, pushes and host requests. */
export type ServerMessage =
  | { type: "result"; id: string | number; data: unknown }
  | { type: "error"; id?: string | number; message: string }
  | { type: "event"; botId: string; conversationId: number; event: StreamEvent }
  /** The bot list changed (a bot created one, a team changed): clients refetch `bots.list`. */
  | { type: "bots.changed" }
  | { type: "groups.changed" }
  /** A bot's thread list changed (a title was generated): clients refetch `threads.list`. */
  | { type: "threads.changed"; botId: string }
  /** A bot's memory changed (a user edit or an extraction): clients refetch `memory.list`. */
  | { type: "memory.changed"; botId: string }
  /** A Forum post is new, or changed (a thread's reply count, an `unanswered` note). */
  | { type: "forum.post"; post: ForumPost }
  /** The bots with a turn running in a Forum room changed. */
  | { type: "forum.thinking"; roomId: number; botIds: string[] }
  /** What `forum.get` returns changed: clients refetch it. */
  | { type: "forum.changed" }
  /** The user's name changed: clients refetch `user.get`. */
  | { type: "user.changed" }
  /** A bot's container changed state (started, stopped, updated, rebuilt). */
  | { type: "bots.environment.changed"; botId: string; state: EnvironmentState }
  /** Progress of `runtime.update`, per bot, then `phase: "done"` once for the whole run. */
  | {
      type: "runtime.update";
      botId?: string;
      phase: "stopping" | "updating" | "updated" | "rolledBack" | "skipped" | "done";
      error?: string;
    }
  | HostRequest;

export type EnvironmentState = "missing" | "running" | "stopped" | "unavailable";

export type EnvironmentSummary = {
  botId: string;
  state: EnvironmentState;
  /** Why the bot is not idle now (shown while running), if known. */
  busy?: string;
  /** Epoch ms of the last activity the runtime saw. */
  lastActivity?: number;
  /** Its restart list (helper/supervisor.mjs), while it runs. */
  services?: ServiceSummary[];
};

/** One entry of a bot's restart list (`keep_running`). */
export type ServiceSummary = {
  name: string;
  command: string;
  cwd: string;
  running: boolean;
  pid?: number;
  /** ISO 8601: when the running process started. */
  since?: string;
  restarts: number;
  lastExit?: { code: number | null; signal: string | null; at: string };
};

// --- Replies -------------------------------------------------------------------------------------

export type SidebarGroup = { id: string; name: string; position: number };

export type AccountStatus = {
  id: string;
  label: string;
  group: string;
  method: "oauth" | "api_key";
  configured: boolean;
};
export type AccountsSummary = {
  accounts: AccountStatus[];
  search: { provider: string; providers: AccountStatus[] };
};

/** USD per million tokens. */
export type PriceRates = { input: number; output: number; cacheRead: number; cacheWrite: number };
/**
 * A model's raw API price. `listed`: the catalog gives per-token prices. `zero`: the catalog lists
 * $0 for everything, which pi-ai also uses for models it has no price for. `unknown`: no entry.
 */
export type ModelPricing =
  | {
      status: "listed";
      rates: PriceRates;
      /** Higher rates once a request's input passes `inputTokensAbove` tokens. */
      tiers?: (PriceRates & { inputTokensAbove: number })[];
      source: string;
    }
  | { status: "zero"; source: string }
  | { status: "unknown" };
/** How the provider is reached. */
export type ModelAccess = {
  kind: "subscription" | "api_key" | "unknown";
  /** e.g. "ChatGPT subscription", "OpenRouter API key". */
  label: string;
};
export type ModelOption = {
  id: string;
  name: string;
  reasoning: boolean;
  contextWindow: number;
  maxTokens?: number;
  input?: string[];
  unsupportedReasoning?: string[];
  pricing: ModelPricing;
  limit?: { kind: ModelLimitSummary["kind"]; label: string; account: string; resetsAt?: number };
};
export type ProviderModels = { id: string; name: string; access: ModelAccess; models: ModelOption[] };
/** The title model ("" when unset: the default profile's main model) and its reasoning level. */
export type Roles = { titles: string; titlesReasoning: string };
export type ModelCatalog = { providers: ProviderModels[]; roles: Roles; reasoningLevels: string[] };

export type RuntimeStatus = {
  /** Where bots' tools run: `none`, `linux-dockerd` or `mac-vm`. */
  environment: string;
  bots: number;
  /**
   * The tools every bot container gets, the bots an update moves to a new base image
   * (`staleBots`), and the bots an update changes at all (`outdatedBots`).
   */
  image?: {
    tag: string;
    base?: string;
    node?: string;
    playwright?: string;
    staleBots: number;
    outdatedBots: number;
  };
};

/** What each request returns in its `result`. */
export type Replies = {
  "groups.list": { groups: SidebarGroup[] };
  "groups.create": { group: SidebarGroup };
  "groups.rename": { group: SidebarGroup };
  "groups.delete": { deleted: true };
  "groups.reorder": { groups: SidebarGroup[] };
  "bots.setGroup": { bot: BotSummary };
  "bots.list": { bots: BotSummary[] };
  "bots.create": { bot: BotSummary };
  "bots.delete": { deleted: boolean };
  "bots.listDeleted": { bots: DeletedBotSummary[] };
  "bots.restore": { restored: boolean; bot?: BotSummary };
  "bots.purge": {
    purged: true;
    /** Tables of the bot's Pi Durable session that were dropped. */
    tables: number;
    /** Whether its container and files were removed (absent without a container engine). */
    environment?: { removed: boolean; error?: string };
  };
  "bots.rename": { bot: BotSummary };
  "bots.setManager": { bot: BotSummary };
  "bots.setTeam": { bot: BotSummary };
  "bots.replaceManager": { bot: BotSummary };
  "bots.setOrchestrator": { bot: BotSummary | null };
  "onboarding.status": OnboardingStatus;
  "onboarding.setMainModel": { profile: ProfileSummary };
  "profiles.list": ProfilesList;
  "profiles.save": ProfilesList;
  "profiles.delete": ProfilesList;
  "profiles.setDefault": ProfilesList;
  "bots.setProfile": { bot: BotSummary };
  "memory.list": { facts: string[] };
  "memory.add": { facts: string[] };
  "memory.update": { facts: string[] };
  "memory.delete": { facts: string[] };
  "account.notes": { notes: string; updatedAt?: string };
  "account.setNotes": { saved: true };
  "conversation.open": ConversationSnapshot;
  "conversation.close": { closed: boolean };
  "conversation.abort": { conversationId: number; stopped: true };
  /** `duplicate`: a retry of a delivery id already accepted. */
  "message.send": { conversationId: number; submissionId: number } | { duplicate: true };
  "thread.fork": { thread: ThreadSummary };
  "thread.setTitle": { thread: ThreadSummary };
  "thread.setPinned": { thread: ThreadSummary };
  "thread.delete": { deleted: true };
  "threads.list": { threads: ThreadSummary[] };
  "settings.accounts": AccountsSummary;
  "models.catalog": ModelCatalog;
  "models.setRoles": { roles: Roles; restartRequired: false };
  "bots.environment": { environment: EnvironmentSummary };
  "bots.rebuild": { rebuilt: true };
  "bots.stop": { stopped: true };
  "runtime.update": { started: true };
  "runtime.status": RuntimeStatus;
  "forum.get": ForumState;
  "forum.open": ForumRoomSnapshot;
  "forum.close": { closed: boolean };
  "forum.posts": { posts: ForumPost[]; hasEarlier: boolean };
  "forum.post": { post: ForumPost } | { duplicate: true };
  "forum.thread.create": { thread: ForumThreadSummary };
  "forum.thread.setTitle": { thread: ForumThreadSummary };
  "forum.thread.setPinned": { thread: ForumThreadSummary };
  "forum.thread.delete": { deleted: true };
  "forum.setPaused": ForumState;
  "forum.setBotActive": ForumState;
  "forum.schedules.list": { schedules: ForumScheduleSummary[] };
  "forum.schedules.save": { schedules: ForumScheduleSummary[] };
  "forum.schedules.delete": { schedules: ForumScheduleSummary[] };
  "user.get": { name: string };
  "user.setName": { name: string };
};

// --- The host interface: runtime → server, on the same connection --------------------------------

/**
 * A provider credential as the server stores it for Pi Durable: an API key, a subscription's OAuth
 * credential (Pi Durable's JSON, renewed here and reported back with `credentials.update`), or
 * `native`: Claude Code's own sign-in on this machine, used with its default configuration.
 */
export type HostCredential =
  | { type: "apiKey"; key: string }
  | { type: "oauth"; access: string; refresh: string; expires: number; [field: string]: unknown }
  | { type: "native" };

export type SearchProviderId = "exa" | "brave" | "firecrawl";

/** Settings → GitHub for one bot: the public half of the key while the bot may use it, and the commit identity. */
export type GitSetup = {
  readonly publicKey: string | null;
  readonly identity: { readonly name: string; readonly email: string } | null;
};

export type MirrorConversation = {
  conversationId: number;
  kind: "main" | "thread";
  parentConversationId?: number;
  title?: string;
  pinned?: boolean;
  /** ISO 8601. */
  createdAt: string;
};

export type MirrorItem = {
  /** Stable forever, unique within the bot: `<entryId>` or `<entryId>.<n>`. */
  key: string;
  conversationId: number;
  /** Epoch ms. */
  createdAt: number;
  kind: "user" | "assistant" | "tool" | "error" | "stopped";
  /** user, assistant, error. */
  text?: string;
  tool?: { name: string; input: string; output?: string; failed: boolean };
  /** One model turn's usage, on the first item of that turn (its text when it has any). */
  usage?: {
    /** `provider/model`. */
    model: string;
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
    /** USD. */
    cost: number;
  };
};

/** One bot's conversations and the finished items above the server's checkpoint. */
export type MirrorBot = {
  bot: {
    id: string;
    name: string;
    kind: "admin" | "bot";
    manager: boolean;
    managerId?: string;
    orchestrator: boolean;
    deleted: boolean;
    /** ISO 8601. */
    createdAt: string;
  };
  /** The main channel and every thread (Forum seats and subagents are never mirrored). */
  conversations: MirrorConversation[];
  /** Sorted by entry, then n. At most 200. */
  items: MirrorItem[];
  /**
   * The usage of the bot's model turns in its Forum seats, whose conversations are not mirrored:
   * one per assistant message, keyed like items (`<entryId>` or `<entryId>.<n>`).
   */
  forumUsage?: { key: string; roomId: number; createdAt: number; usage: NonNullable<MirrorItem["usage"]> }[];
  /** Entries through this id are covered. */
  upTo: number;
};

export type MirrorForum = {
  rooms: { roomId: number; parentPostId?: number; title?: string; pinned?: boolean; createdAt: string }[];
  /** Sorted by id. At most 200. */
  posts: {
    id: number;
    roomId: number;
    author: "user" | "bot" | "agent";
    botId?: string;
    name: string;
    text: string;
    /** Epoch ms. */
    createdAt: number;
  }[];
  /** Posts through this id are covered. */
  upTo: number;
};

/** The server's checkpoints: what it already holds of each bot and of the Forum. */
export type MirrorCheckpoints = { bots: Record<string, number>; forum: number };

type Empty = Record<string, never>;

/** Each host method's params and the `data` of its reply. */
export type HostMethods = {
  credentials: {
    params: { provider: string };
    /** `searchProvider` only for `provider: "web-search"`. */
    data: { credential: HostCredential | null; searchProvider?: SearchProviderId };
  };
  "credentials.update": { params: { provider: string; credential: HostCredential }; data: Empty };
  "git.setup": { params: { botId: string }; data: GitSetup };
  /** One SSH agent request from the bot's container, answered by the machine's signing agent. */
  "git.agent": { params: { botId: string; message: string }; data: { message: string } };
  /** Whether the bot may use Woven tools (`bots.wovenTools`). */
  "tools.access": { params: { botId: string }; data: { allowed: boolean } };
  /** The Woven tool catalog and instructions, when the bot may use them; asked on every connection. */
  "tools.list": {
    params: { botId: string };
    data:
      | { allowed: false }
      | {
          allowed: true;
          tools: {
            name: string;
            description: string;
            inputSchema: Record<string, unknown>;
            annotations?: { readOnlyHint?: boolean };
          }[];
          instructions: string;
        };
  };
  /** One Woven tool call, carried out by the server (which checks access again). */
  "tools.call": {
    params: { botId: string; name: string; arguments: Record<string, unknown> };
    data: {
      content: ({ type: "text"; text: string } | { type: "image"; data: string; mimeType: string })[];
      isError: boolean;
    };
  };
  "mirror.checkpoints": { params: Empty; data: MirrorCheckpoints };
  "mirror.bot": { params: MirrorBot; data: Empty };
  "mirror.forum": { params: MirrorForum; data: Empty };
  "mirror.purge": { params: { botId: string }; data: Empty };
};
export type HostMethod = keyof HostMethods;

export type HostRequest = {
  [M in HostMethod]: { type: "host"; id: string; method: M; params: HostMethods[M]["params"] };
}[HostMethod];

export type HostReply =
  | { type: "host.result"; id: string; data: unknown }
  | { type: "host.error"; id: string; message: string };
