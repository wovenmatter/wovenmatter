import { z } from "zod";
import { MAX_EDITED_FACT_CHARS } from "./memory.ts";
import type { DisplayEntry } from "./transcript.ts";

const botId = z.string().uuid();
const conversationId = z.number().int().nonnegative();
const modelRefText = z.string().min(3).max(200);
const requestId = z.union([z.string().max(64), z.number().int()]);
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
  // Per-bot Woven MCP status (keys come from the host API; nothing to connect by hand).
  z.strictObject({ id: requestId, type: z.literal("woven.status") }),
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
    text: z.string().min(1).max(100_000),
    context: z.string().max(4000).optional(),
    /** Set by the host: a retry with the same id is accepted without submitting again. */
    deliveryId: z.string().min(1).max(128).optional(),
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("thread.fork"),
    botId,
    conversationId: conversationId.optional(),
    entryId: z.number().int().nonnegative(),
    // Strict: threads cannot be named or renamed (`title` is rejected).
  }),
  z.strictObject({
    id: requestId,
    type: z.literal("thread.setPinned"),
    botId,
    conversationId,
    pinned: z.boolean(),
  }),
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
  // Runtime additions. A bot's container: state, idle status, restart list and previews.
  z.strictObject({ id: requestId, type: z.literal("bots.environment"), botId }),
  // Recreate a bot's container from a clean image, keeping its storage.
  z.strictObject({ id: requestId, type: z.literal("bots.rebuild"), botId }),
  // Stop a bot's container now (it starts again on the next tool call).
  z.strictObject({ id: requestId, type: z.literal("bots.stop"), botId }),
  z.strictObject({ id: requestId, type: z.literal("previews.list"), botId: botId.optional() }),
  z.strictObject({
    id: requestId,
    type: z.literal("previews.stop"),
    botId,
    port: z.number().int().min(1).max(65535),
  }),
  // Update bots in place (all, or the listed ones): stop running work, snapshot, update,
  // health-check, roll back on failure. Progress arrives as `runtime.update` pushes.
  z.strictObject({
    id: requestId,
    type: z.literal("runtime.update"),
    botIds: z.array(botId).max(1000).optional(),
  }),
  z.strictObject({ id: requestId, type: z.literal("runtime.status") }),
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

/** Server → client messages. */
export type ServerMessage =
  | {
      type: "hello";
      version: string;
      protocol: number;
      installationId: string;
      capabilities: string[];
    }
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
  /** A bot's container changed state (started, stopped, updated, rebuilt). */
  | { type: "bots.environment.changed"; botId: string; state: EnvironmentState }
  /** Progress of `runtime.update`, per bot, then `phase: "done"` once for the whole run. */
  | {
      type: "runtime.update";
      botId?: string;
      phase: "stopping" | "updating" | "updated" | "rolledBack" | "skipped" | "done";
      error?: string;
    };

export type EnvironmentState = "missing" | "running" | "stopped" | "unavailable";

export type EnvironmentSummary = {
  botId: string;
  state: EnvironmentState;
  /** Why the bot is not idle now (shown while running), if known. */
  busy?: string;
  /** Epoch ms of the last activity the runtime saw. */
  lastActivity?: number;
  services?: unknown[];
  previews: { port: number; url: string }[];
};
