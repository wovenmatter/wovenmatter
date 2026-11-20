// One example of each shape the UI decodes, typed against protocol.ts so tsc breaks when they
// drift. Run `node test/wire-fixtures.ts` to write test/fixtures/wire.json, which the server's
// Swift test decodes with its copies of these types; wire.test.ts fails when the committed file
// differs from what this writes. Every optional field is filled in at least one example.
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { DisplayEntry } from "../src/transcript.ts";
import type {
  AccountsSummary,
  BotSummary,
  ConversationSnapshot,
  DeletedBotSummary,
  EnvironmentSummary,
  ForumPost,
  ForumRoomSnapshot,
  ForumScheduleSummary,
  ForumState,
  ForumThreadSummary,
  HostMethod,
  HostMethods,
  HostReply,
  HostRequest,
  ModelCatalog,
  OnboardingStatus,
  ProfileSummary,
  ProfilesList,
  Replies,
  RequestType,
  RuntimeStatus,
  ServerMessage,
  SidebarGroup,
  StreamEvent,
  ThreadSummary,
} from "../src/protocol.ts";

export const FIXTURES = fileURLToPath(new URL("./fixtures/wire.json", import.meta.url));

const ADA = "6f1d2c3b-4a59-4e8f-9a0b-1c2d3e4f5a6b";
const ADMIN = "0b9e1c2d-3f4a-4b5c-8d6e-7f8091a2b3c4";
const MAX = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d";
const GROUP = "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f";
const AT = "2026-11-19T09:30:00.000Z";
const MS = 1_795_080_600_000;

const group = { id: GROUP, name: "Research", position: 0 } satisfies SidebarGroup;

const bot = {
  id: ADA,
  name: "Ada",
  createdAt: AT,
  kind: "bot",
  manager: false,
  managerId: MAX,
  groupId: GROUP,
  orchestrator: false,
  profileId: "default",
  profileName: "Default",
  defaultProfile: true,
  modelStatus: {
    kind: "fallback",
    at: MS,
    primary: "openai-codex/gpt-6-sol",
    active: "anthropic/claude-opus-5",
    limits: [
      {
        model: "openai-codex/gpt-6-sol",
        account: "ChatGPT account",
        kind: "five_hour",
        resetsAt: MS + 3_600_000,
        retryAt: MS + 3_600_000,
      },
    ],
  },
} satisfies BotSummary;

const admin = {
  id: ADMIN,
  name: "Admin Bot",
  createdAt: AT,
  kind: "admin",
  manager: false,
  orchestrator: false,
  profileId: "default",
  profileName: "Default",
  defaultProfile: true,
} satisfies BotSummary;

const deleted = { ...bot, id: MAX, name: "Max", deletedAt: AT } satisfies DeletedBotSummary;

const thread = {
  pinned: true,
  conversationId: 4,
  parentConversationId: 1,
  forkedAt: 12,
  title: "Build failures",
  createdAt: AT,
} satisfies ThreadSummary;

const userEntry = { id: 12, conversationId: 1, role: "user", text: "Why does the build fail?" } satisfies DisplayEntry;
const failedEntry = {
  id: 13,
  conversationId: 4,
  role: "assistant",
  text: "Partial answer",
  error: "openai-codex/gpt-6-sol hit its 5-hour usage limit.",
  issue: "limit",
  stopped: true,
} satisfies DisplayEntry;

const snapshot = {
  subscriptionId: "s-1",
  botId: ADA,
  conversationId: 4,
  mainConversationId: 1,
  threadOrigin: userEntry,
  entries: [userEntry, failedEntry],
  running: true,
  streaming: "Looking at the log",
} satisfies ConversationSnapshot;

const post = {
  id: 7,
  roomId: 1,
  author: "bot",
  botId: ADA,
  name: "Ada",
  text: "The build is fixed.",
  mentions: [MAX],
  scheduled: true,
  auto: true,
  createdAt: AT,
  thread: { roomId: 3, replies: 2 },
  unanswered: [{ botId: MAX, name: "Max", reason: "No model selected yet.", issue: "signIn" }],
} satisfies ForumPost;

const forumThread = {
  roomId: 3,
  parentPostId: 7,
  title: "The build",
  preview: "The build is fixed.",
  createdAt: AT,
  pinned: true,
  replies: 2,
  botIds: [ADA, MAX],
} satisfies ForumThreadSummary;

const forumState = {
  mainRoomId: 1,
  paused: false,
  latestPostId: 7,
  bots: [
    { botId: ADA, active: true },
    { botId: ADMIN, active: false },
  ],
  threads: [forumThread],
} satisfies ForumState;

const room = {
  subscriptionId: 2,
  roomId: 3,
  mainRoomId: 1,
  parent: post,
  posts: [{ id: 8, roomId: 3, author: "user", name: "", text: "Thanks", createdAt: AT }],
  hasEarlier: false,
  thinking: [ADA],
} satisfies ForumRoomSnapshot;

const schedule = {
  id: "standup",
  text: "Standup: what are you working on?",
  mentions: [ADA],
  everyone: true,
  repeat: "weekly",
  time: "09:00",
  weekday: 1,
  at: MS,
  timeZone: "Europe/Berlin",
  nextAt: MS + 86_400_000,
} satisfies ForumScheduleSummary;

const profile = {
  id: "default",
  name: "Default",
  main: "openai-codex/gpt-6-sol",
  fallbacks: ["anthropic/claude-opus-5"],
  memoryModel: "openai/gpt-6-mini",
  guidance: "Prefer the cheaper model for research.",
  pool: [{ model: "openrouter/qwen-4", useFor: "bulk summaries" }],
  default: true,
} satisfies ProfileSummary;

const profiles = { defaultId: "default", profiles: [profile] } satisfies ProfilesList;

const onboarding = {
  adminId: ADMIN,
  profileId: "default",
  mainModel: "openai-codex/gpt-6-sol",
  mainModelAvailable: true,
  signedIn: true,
  needed: false,
} satisfies OnboardingStatus;

const environment = {
  botId: ADA,
  state: "running",
  busy: "a turn is running",
  lastActivity: MS,
  services: [
    {
      name: "dev-server",
      command: "npm run dev",
      cwd: "/workspace/app",
      running: true,
      pid: 412,
      since: AT,
      restarts: 1,
      lastExit: { code: 1, signal: null, at: AT },
    },
  ],
} satisfies EnvironmentSummary;

const catalog = {
  providers: [
    {
      id: "openai-codex",
      name: "OpenAI (ChatGPT)",
      access: { kind: "subscription", label: "ChatGPT subscription" },
      models: [
        {
          id: "gpt-6-sol",
          name: "GPT-6 Sol",
          reasoning: true,
          contextWindow: 400_000,
          maxTokens: 128_000,
          input: ["text", "image"],
          unsupportedReasoning: ["minimal"],
          pricing: {
            status: "listed",
            rates: { input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0 },
            tiers: [{ input: 2.5, output: 20, cacheRead: 0.25, cacheWrite: 0, inputTokensAbove: 272_000 }],
            source: "pi-ai catalog",
          },
          limit: { kind: "five_hour", label: "5-hour limit", account: "ChatGPT account", resetsAt: MS },
        },
        {
          id: "gpt-6-mini",
          name: "GPT-6 Mini",
          reasoning: false,
          contextWindow: 200_000,
          pricing: { status: "zero", source: "pi-ai catalog" },
        },
        { id: "codex-x", name: "Codex X", reasoning: true, contextWindow: 200_000, pricing: { status: "unknown" } },
      ],
    },
  ],
  roles: { titles: "openai/gpt-6-mini", titlesReasoning: "high" },
  reasoningLevels: ["minimal", "low", "medium", "high"],
} satisfies ModelCatalog;

const accounts = {
  accounts: [{ id: "openai-codex", label: "OpenAI · ChatGPT subscription", group: "OpenAI", method: "oauth", configured: true }],
  search: { provider: "exa", providers: [{ id: "exa", label: "Exa", group: "Search", method: "api_key", configured: false }] },
} satisfies AccountsSummary;

const runtimeStatus = {
  environment: "mac-vm",
  bots: 3,
  image: { tag: "wovenmatter-bots:0123456789abcdef", base: "ubuntu:26.04", node: "26.13.1", playwright: "1.65.1", staleBots: 1, outdatedBots: 2 },
} satisfies RuntimeStatus;

const event = (stream: StreamEvent) => ({ type: "event", botId: ADA, conversationId: 4, event: stream }) satisfies ServerMessage;

const pushes = {
  "message.event.run": event({ kind: "run", state: "start" }),
  "message.event.assistant_start": event({ kind: "assistant_start", text: "Looking" }),
  "message.event.delta": event({ kind: "delta", text: " at the log" }),
  "message.event.entry": event({ kind: "entry", entry: failedEntry }),
  "message.event.error": event({ kind: "error", message: "retrying: overloaded" }),
  "message.bots.changed": { type: "bots.changed" },
  "message.groups.changed": { type: "groups.changed" },
  "message.threads.changed": { type: "threads.changed", botId: ADA },
  "message.memory.changed": { type: "memory.changed", botId: ADA },
  "message.forum.post": { type: "forum.post", post },
  "message.forum.thinking": { type: "forum.thinking", roomId: 1, botIds: [ADA] },
  "message.forum.changed": { type: "forum.changed" },
  "message.user.changed": { type: "user.changed" },
  "message.bots.environment.changed": { type: "bots.environment.changed", botId: ADA, state: "stopped" },
  "message.runtime.update": { type: "runtime.update", botId: ADA, phase: "rolledBack", error: "health check failed" },
} satisfies Record<string, ServerMessage>;

const replies = {
  "groups.list": { groups: [group] },
  "groups.create": { group },
  "groups.rename": { group },
  "groups.delete": { deleted: true },
  "groups.reorder": { groups: [group] },
  "bots.setGroup": { bot },
  "bots.list": { bots: [admin, bot] },
  "bots.create": { bot },
  "bots.delete": { deleted: true },
  "bots.listDeleted": { bots: [deleted] },
  "bots.restore": { restored: true, bot },
  "bots.purge": { purged: true, tables: 9, environment: { removed: false, error: "the engine is unavailable" } },
  "bots.rename": { bot },
  "bots.setManager": { bot },
  "bots.setTeam": { bot },
  "bots.replaceManager": { bot },
  "bots.setOrchestrator": { bot: null },
  "onboarding.status": onboarding,
  "onboarding.setMainModel": { profile },
  "profiles.list": profiles,
  "profiles.save": profiles,
  "profiles.delete": profiles,
  "profiles.setDefault": profiles,
  "bots.setProfile": { bot },
  "memory.list": { facts: ["Prefers short answers."] },
  "memory.add": { facts: ["Prefers short answers."] },
  "memory.update": { facts: ["Prefers short answers."] },
  "memory.delete": { facts: [] },
  "account.notes": { notes: "ChatGPT Pro; keep API spend under $20 a month.", updatedAt: AT },
  "account.setNotes": { saved: true },
  "conversation.open": snapshot,
  "conversation.close": { closed: true },
  "conversation.abort": { conversationId: 1, stopped: true },
  "message.send": { conversationId: 4, submissionId: 31 },
  "thread.fork": { thread },
  "thread.setTitle": { thread },
  "thread.setPinned": { thread },
  "threads.list": { threads: [thread] },
  "settings.accounts": accounts,
  "models.catalog": catalog,
  "models.setRoles": { roles: catalog.roles, restartRequired: false },
  "bots.environment": { environment },
  "bots.rebuild": { rebuilt: true },
  "bots.stop": { stopped: true },
  "runtime.update": { started: true },
  "runtime.status": runtimeStatus,
  "forum.get": forumState,
  "forum.open": room,
  "forum.close": { closed: true },
  "forum.posts": { posts: [post], hasEarlier: true },
  "forum.post": { post },
  "forum.thread.create": { thread: forumThread },
  "forum.thread.setTitle": { thread: forumThread },
  "forum.thread.setPinned": { thread: forumThread },
  "forum.setPaused": forumState,
  "forum.setBotActive": forumState,
  "forum.schedules.list": { schedules: [schedule] },
  "forum.schedules.save": { schedules: [schedule] },
  "forum.schedules.delete": { schedules: [] },
  "user.get": { name: "Sam" },
  "user.setName": { name: "Sam" },
} satisfies Replies;

/** The other variants of replies that have two. */
const replyVariants = {
  "reply.message.send.duplicate": { duplicate: true },
  "reply.forum.post.duplicate": { duplicate: true },
} satisfies Record<string, Replies["message.send"] | Replies["forum.post"]>;

const host = <M extends HostMethod>(method: M, params: HostMethods[M]["params"], data: HostMethods[M]["data"]) => ({
  [`host.${method}`]: { type: "host", id: `h-${method}`, method, params } as HostRequest,
  [`host.${method}.result`]: { type: "host.result", id: `h-${method}`, data } satisfies HostReply,
});

const hostCalls = {
  ...host("credentials", { provider: "web-search" }, { credential: { type: "apiKey", key: "exa-key" }, searchProvider: "exa" }),
  ...host(
    "credentials.update",
    { provider: "openai-codex", credential: { type: "oauth", access: "access", refresh: "refresh", expires: MS, accountId: "acct" } },
    {},
  ),
  ...host("git.setup", { botId: ADA }, { publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl ada", identity: { name: "Sam", email: "sam@example.com" } }),
  ...host("git.agent", { botId: ADA, message: "AAAAAQs=" }, { message: "AAAAAQw=" }),
  ...host("tools.access", { botId: ADA }, { allowed: false }),
  ...host("mirror.checkpoints", {}, { bots: { [ADA]: 12 }, forum: 7 }),
  ...host(
    "mirror.bot",
    {
      bot: { id: ADA, name: "Ada", kind: "bot", manager: false, managerId: MAX, orchestrator: false, deleted: false, createdAt: AT },
      conversations: [
        { conversationId: 1, kind: "main", createdAt: AT },
        { conversationId: 4, kind: "thread", parentConversationId: 1, title: "Build failures", pinned: true, createdAt: AT },
      ],
      items: [
        { key: "13", conversationId: 4, createdAt: MS, kind: "user", text: "Why does the build fail?" },
        {
          key: "14",
          conversationId: 4,
          createdAt: MS,
          kind: "assistant",
          text: "Looking at the log.",
          usage: { model: "openai-codex/gpt-6-sol", input: 1200, output: 80, cacheRead: 900, cacheWrite: 0, cost: 0.0021 },
        },
        {
          key: "14.1",
          conversationId: 4,
          createdAt: MS,
          kind: "tool",
          tool: { name: "bash", input: '{"command":"npm test"}', output: "1 failing", failed: true },
        },
        { key: "15", conversationId: 4, createdAt: MS, kind: "error", text: "overloaded" },
        { key: "15.1", conversationId: 4, createdAt: MS, kind: "stopped" },
      ],
      upTo: 15,
    },
    {},
  ),
  ...host(
    "mirror.forum",
    {
      rooms: [
        { roomId: 1, createdAt: AT },
        { roomId: 3, parentPostId: 7, title: "The build", pinned: false, createdAt: AT },
      ],
      posts: [
        { id: 7, roomId: 1, author: "bot", botId: ADA, name: "Ada", text: "The build is fixed.", createdAt: MS },
        { id: 8, roomId: 3, author: "user", name: "", text: "Thanks", createdAt: MS },
      ],
      upTo: 8,
    },
    {},
  ),
  ...host("mirror.purge", { botId: MAX }, {}),
  "host.error": { type: "host.error", id: "h-git.setup", message: "No machine runs the bots." } satisfies HostReply,
};

/** Every fixture, keyed by shape name. */
export function wireFixtures(): Record<string, unknown> {
  return {
    BotSummary: bot,
    DeletedBotSummary: deleted,
    ThreadSummary: thread,
    DisplayEntry: failedEntry,
    ConversationSnapshot: snapshot,
    ForumState: forumState,
    ForumRoomSnapshot: room,
    ForumPost: post,
    ForumThreadSummary: forumThread,
    ForumScheduleSummary: schedule,
    ProfilesList: profiles,
    OnboardingStatus: onboarding,
    EnvironmentSummary: environment,
    ModelCatalog: catalog,
    AccountsSummary: accounts,
    RuntimeStatus: runtimeStatus,
    SidebarGroup: group,
    ...pushes,
    ...Object.fromEntries(
      (Object.entries(replies) as [RequestType, unknown][]).map(([type, value]) => [`reply.${type}`, value]),
    ),
    ...replyVariants,
    ...hostCalls,
  };
}

export const wireJSON = () => `${JSON.stringify(wireFixtures(), null, 2)}\n`;

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  writeFileSync(FIXTURES, wireJSON());
  console.log(`wrote ${FIXTURES}`);
}
