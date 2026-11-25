import { join } from "node:path";
import type { Models } from "@earendil-works/pi-ai";
import type { SqliteDatabase } from "@earendil-works/pi-durable/storage/sqlite";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createBotHarnessOptions } from "./agent.ts";
import { BotManager } from "./bots.ts";
import {
  type ModelRef,
  normalizeProfiles,
  parseModelRef,
  profilesToRaw,
  type RuntimeConfig,
} from "./config.ts";
import type { BotEnvironmentAdapter } from "./env.ts";
import { BotEnvironment } from "./environment/container.ts";
import { DockerEngineAPI } from "./environment/engine-api.ts";
import { type Forum, openForum, USER_NAME } from "./forum.ts";
import { HostChannel } from "./host/channel.ts";
import { ServerCredentials } from "./host/credentials.ts";
import { HostGitSource } from "./host/git.ts";
import { ModelAvailability } from "./limits.ts";
import { MemoryExtractor, memorySection } from "./memory.ts";
import { LibraryMirror } from "./mirror.ts";
import { FileModelsStore } from "./model-catalog.ts";
import { checkModelRoles, createBotModels, refreshBotModels } from "./models.ts";
import { wovenTools } from "./woven-tools.ts";
import { RuntimeOperations } from "./operations.ts";
import { ProfileStore } from "./profiles.ts";
import { type BotServer, startServer } from "./server.ts";
import type { SearchProviderId } from "./protocol.ts";
import { SettingsService } from "./settings/service.ts";
import { SettingsStore } from "./settings/store.ts";
import { openSharedDatabase } from "./storage/database.ts";
import { ForumStore } from "./storage/forum.ts";
import { BotRegistry } from "./storage/registry.ts";
import { TitleGenerator } from "./titles.ts";
import { type BotPlatform, checkUserName, forgetBotMessages } from "./tools.ts";

export type BotsRuntime = {
  readonly db: SqliteDatabase;
  readonly models: Models;
  readonly manager: BotManager;
  readonly host: HostChannel;
  readonly availability: ModelAvailability;
  readonly server: BotServer;
  readonly operations: RuntimeOperations;
  readonly env?: BotEnvironmentAdapter;
  readonly mirror: LibraryMirror;
  readonly forum: Forum;
  readonly settings: SettingsStore;
  /** Startup environment reconcile (in the background; never rejects). */
  readonly reconciled: Promise<void>;
  close(): Promise<void>;
};

export type StartOptions = {
  /** Override the pi-ai models (tests use the faux provider). */
  readonly models?: Models;
  /** Where bots' tools run; defaults to containers on the configured engine. `null`: no tools. */
  readonly env?: BotEnvironmentAdapter | null;
  /** Settings store override (tests keep settings in memory). */
  readonly settings?: SettingsStore;
  /** Pi's model catalog service (tests point it at a fake). */
  readonly catalog?: { readonly fetch?: typeof fetch; readonly baseUrl?: string; readonly now?: () => number };
  /** How long a host request waits for the server (tests shorten it). */
  readonly hostTimeoutMs?: number;
  /** Library copy timing (tests shorten it). */
  readonly mirror?: { readonly debounceMs?: number; readonly sweepMs?: number };
  readonly log?: (message: string) => void;
  /** Options for the default container environment (tests shorten the idle period). */
  readonly environment?: Partial<ConstructorParameters<typeof BotEnvironment>[0]>;
};

async function reconcileWithRetry(
  env: BotEnvironmentAdapter,
  bots: () => Promise<{ active: string[]; deleted: string[] }>,
  log: (message: string) => void,
  attempts = 6,
): Promise<void> {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      const { active, deleted } = await bots();
      await env.reconcile?.(active, deleted);
      return;
    } catch (error) {
      log(`environment reconcile (attempt ${attempt}/${attempts}): ${String(error)}`);
      if (attempt < attempts) await new Promise((resolve) => setTimeout(resolve, attempt * 5000));
    }
  }
}

/** Open the database, settings, models and every bot, then listen. */
export async function startRuntime(
  config: RuntimeConfig,
  options: StartOptions = {},
): Promise<BotsRuntime> {
  const log = options.log ?? ((message: string) => console.error(message));
  let settingsService: SettingsService | undefined;
  let server: BotServer | undefined;
  let manager: BotManager | undefined;
  let memory: MemoryExtractor | undefined;
  let mirror: LibraryMirror | undefined;
  let forum: Forum | undefined;
  let refreshModels: (how?: Parameters<typeof refreshBotModels>[1]) => Promise<void> = async () => {};
  const settings = options.settings ?? (await SettingsStore.open(config.paths.settings));
  const host = new HostChannel(options.hostTimeoutMs ? { timeoutMs: options.hostTimeoutMs } : {});
  const credentials = new ServerCredentials(host.call);
  const git = new HostGitSource((botId) => host.call("git.setup", { botId }));
  const searchProvider = async (): Promise<SearchProviderId | undefined> =>
    (await host.call("credentials", { provider: "web-search" }).catch(() => undefined))?.searchProvider;
  const platform: BotPlatform = {
    manager: () => {
      if (!manager) throw new Error("bots are still starting");
      return manager;
    },
    settings: () => settingsService,
    get maxMessagesPerHourPerPair() {
      return settings.current.bot_to_bot.max_messages_per_hour_per_pair;
    },
    get maxRoundsPerRequest() {
      return settings.current.bot_to_bot.max_rounds_per_request;
    },
    forum: () => forum,
    userName: async () => (await registry.note(USER_NAME))?.text.trim() || undefined,
    setUserName: async (name) => {
      const saved = checkUserName(name);
      await registry.setNote(USER_NAME, saved);
      server?.broadcast({ type: "user.changed" });
      return saved;
    },
  };
  const db = await openSharedDatabase(config.paths.database);
  const registry = new BotRegistry(db);
  await registry.createTables();
  const installationId = await registry.installationId();
  const forumStore = new ForumStore(db);
  let env: BotEnvironmentAdapter | undefined;
  // The runtime-side half of the idle rule (the container side is checked inside it).
  const probe = async (botId: string) => {
    const bot = await manager?.get(botId).catch(() => undefined);
    if (bot) {
      const live = await bot.harness.inspect(BACKGROUND_CONTEXT);
      if (live.tasks.length || live.submissions.length) return { busy: "a turn is running" };
    }
    if (server?.viewing(botId)) return { busy: "someone has its chat open" };
    return {};
  };
  if (options.env !== null) {
    env =
      options.env ??
      new BotEnvironment({
        engine: new DockerEngineAPI(config.engine.socket),
        kind: config.engine.kind,
        imageName: config.image.tag,
        memoryBytes: config.limits.botMemoryBytes,
        installationId,
        probe,
        log,
        git: (botId: string) => git.current(botId),
        sshAgent: async (botId: string, message: Buffer) =>
          Buffer.from((await host.call("git.agent", { botId, message: message.toString("base64") })).message, "base64"),
        ...options.environment,
      });
  }
  try {
    const live = options.models
      ? undefined
      : createBotModels(credentials, {
          claude: { directory: config.paths.claude },
          catalog: {
            store: new FileModelsStore(join(config.paths.dataDir, "provider-models")),
            ...(options.catalog ?? {}),
          },
        });
    const models = options.models ?? (live as NonNullable<typeof live>);
    /** Load Pi's live catalog; a provider that can't be refreshed keeps the list it had. */
    const reported = new WeakSet<string[]>();
    refreshModels = async (how = {}) => {
      if (!live) return;
      const problems = await refreshBotModels(live, how);
      // Readers that shared one read share its result: say it once.
      if (reported.has(problems)) return;
      reported.add(problems);
      for (const problem of problems) log(`model catalog: ${problem}`);
    };
    // The stored catalog, straight from disk: a profile may name a model only it lists. Nothing
    // is fetched at start or on a timer, as elsewhere in Woven Matter: a newer catalog is read
    // when someone opens a model list.
    await refreshModels({ network: false });
    const profileSet = normalizeProfiles(settings.current);
    if (!options.models) {
      const refs: Record<string, ModelRef> = {};
      const titleModel = settings.current.titles.model;
      if (titleModel) refs["titles.model"] = parseModelRef(titleModel);
      for (const profile of profileSet.profiles) {
        if (profile.main) refs[`profiles.${profile.id}.main`] = parseModelRef(profile.main);
      }
      if (live) {
        const warn = () => {
          for (const problem of checkModelRoles(live, refs)) log(`warning: ${problem}`);
        };
        // A profile names a model of a provider bots have, which neither pi-ai nor the stored
        // catalog lists (a cleared cache, a model added since): the one case a start reads a
        // catalog, that provider's only, and without holding the start up.
        const unknown = new Set(
          Object.values(refs)
            .filter((ref) => live.getProvider(ref.provider) && !live.getModel(ref.provider, ref.modelId))
            .map((ref) => ref.provider),
        );
        if (unknown.size) void refreshModels({ providers: [...unknown] }).then(warn);
        else warn();
      }
    }
    const profiles = new ProfileStore(profileSet, {
      persist: (set) => settings.update((current) => ({ ...current, ...profilesToRaw(set) })).then(() => {}),
      checkModel: (ref) => settingsService?.checkModel(ref),
    });
    const availability = new ModelAvailability({
      store: registry,
      onError: (error) => log(`usage limits: could not save: ${String(error)}`),
    });
    for (const entry of await availability.load()) {
      log(
        `usage limit (from before the restart): ${entry.model} (${entry.account}): ${entry.kind}, retry ${new Date(entry.retryAt).toISOString()}`,
      );
    }
    const titles = new TitleGenerator({
      models,
      // The title model, or else the default profile's main model; neither: no titles yet.
      model: () => {
        const ref = settings.current.titles.model ?? profiles.resolve(undefined).main;
        return ref ? parseModelRef(ref) : undefined;
      },
      reasoning: () => settings.current.titles.reasoning,
    });
    forum = await openForum({
      store: forumStore,
      registry,
      manager: platform.manager,
      titles,
      events: {
        post: (post) => {
          server?.forumPost(post);
          mirror?.scheduleForum();
        },
        thinking: (roomId, botIds) => server?.forumThinking(roomId, botIds),
        changed: () => {
          server?.broadcast({ type: "forum.changed" });
          mirror?.scheduleForum();
        },
      },
      log,
    });
    const room = forum;
    const opened = await BotManager.open({
      db,
      ensureAdmin: true,
      onBotsChanged: () => {
        server?.botsChanged();
        void mirror?.sweep();
      },
      onGroupsChanged: () => server?.groupsChanged(),
      onThreadsChanged: (botId) => {
        server?.threadsChanged(botId);
        mirror?.schedule(botId);
      },
      availability,
      onModelStatus: () => server?.botsChanged(),
      profiles,
      log,
      harnessOptions: (bot, self) => {
        manager ??= self;
        return createBotHarnessOptions({
          bot,
          wovenTools: (install) =>
            wovenTools(bot.id, host, install, {
              seated: async (conversationId) =>
                Boolean(await forumStore.seatOfConversation(bot.id, conversationId)),
              check: async (conversationId) =>
                void (await room.visualReplyRoom(bot.id, conversationId)),
              publish: async (conversationId, visualReply) =>
                void (await room.postVisualReply(bot.id, conversationId, visualReply)),
            }),
          models,
          profile: () => profiles.resolve(self.assignedProfile(bot.id)),
          onSubagent: (event) =>
            log(
              `bot ${bot.id}: subagent ${event.phase} on ${event.model}${event.self ? " (self)" : ""}${event.reasoning ? ` (${event.reasoning})` : ""}${event.detail ? `: ${event.detail}` : ""}`,
            ),
          modelLimit: (ref) => availability.limit(ref),
          platform,
          web: { credentials, provider: searchProvider },
          compaction: settings.current.compaction,
          ...(env ? { env } : {}),
          onReport: (error) => log(`bot ${bot.id}: ${String(error)}`),
          onLimit: (conversationId, model, limit) =>
            self.reportLimit(bot.id, conversationId, model, limit),
          fallbackNote: (conversationId) => self.fallbackNote(bot.id, conversationId),
          memory: async () => memorySection((await self.registry.memory(bot.id)).facts),
        });
      },
      onBotOpened: (bot) => {
        mirror?.attach(bot);
        void room.botOpened(bot).catch((error: unknown) => log(`forum: ${String(error)}`));
      },
      forumConversations: (botId) => room.conversationsOf(botId),
      onBotClosed: (bot, reason) => {
        if (reason !== "closed") log(`bot ${bot.id} harness ${reason}`);
      },
      onBotDeleted: async (bot) => {
        await room.botDeleted(bot.id).catch((error: unknown) => log(`forum: ${String(error)}`));
        mirror?.schedule(bot.id);
        await env?.dispose(bot.id);
      },
      onBotPurged: async (botId) => {
        forgetBotMessages(platform, botId);
        await room.botPurged(botId).catch((error: unknown) => log(`forum: ${String(error)}`));
        await mirror?.purged(botId);
        if (!env) return undefined;
        if (!env.purge) return { removed: false, error: `the ${env.kind} environment can't remove storage` };
        await env.purge(botId);
        return { removed: true };
      },
      titles,
      onReport: (error) => log(`thread title: ${String(error)}`),
      onRecovered: (bot, report) => {
        const parts = [
          report.resumedConversations.length &&
            `resumed live work in conversations ${report.resumedConversations.join(", ")}`,
          report.adoptedThreads.length &&
            `registered unrecorded forks ${report.adoptedThreads.join(", ")} as threads`,
          report.missingThreads.length &&
            `threads ${report.missingThreads.join(", ")} have no stored conversation`,
        ].filter(Boolean);
        if (parts.length) log(`bot ${bot.id} recovery: ${parts.join("; ")}`);
      },
    });
    manager = opened;
    mirror = new LibraryMirror({ manager: opened, forum: forumStore, host, log, ...options.mirror });
    for (const record of await opened.list()) mirror.attach(await opened.get(record.id));
    const extraction = settings.current.extraction;
    memory = extraction.enabled
      ? new MemoryExtractor({
          manager: opened,
          models,
          schedule: extraction.schedule,
          timeZone: extraction.timezone,
          idleMs: extraction.idle_minutes * 60_000,
          onChanged: (botId) => server?.memoryChanged(botId),
          log,
        })
      : undefined;
    settingsService = new SettingsService({
      credentials,
      models,
      store: settings,
      searchProvider,
      modelLimit: (ref) => availability.limit(ref),
      // Whoever opens a model list sees Pi's current one (fetched when the stored one is over
      // four hours old); a slow catalog never holds the list up long.
      refreshModels: () => refreshModels(),
    });
    const operations = new RuntimeOperations({
      manager: opened,
      ...(env ? { env } : {}),
      notify: (message) => server?.broadcast(message),
      forum: room,
      log,
    });
    server = await startServer({
      manager: opened,
      settings: settingsService,
      operations,
      socket: config.socket,
      host,
      environment: env?.kind ?? "none",
      onActivity: (botId) => env?.touch?.(botId),
      forum: room,
      user: {
        name: async () => (await platform.userName?.()) ?? "",
        setName: (name) => platform.setUserName?.(name) ?? Promise.resolve(""),
      },
      log,
    });
    await room.start();
    memory?.start();
    const activeIds = async () => ({
      active: (await opened.list()).map((bot) => bot.id),
      deleted: (await opened.listDeleted()).map((bot) => bot.id),
    });
    const reconciled = env?.reconcile ? reconcileWithRetry(env, activeIds, log) : Promise.resolve();
    return {
      db,
      models,
      manager: opened,
      host,
      availability,
      server,
      operations,
      ...(env ? { env } : {}),
      mirror,
      forum: room,
      settings,
      reconciled,
      async close() {
        await server?.close();
        await room.close();
        await mirror?.close();
        await memory?.close();
        await opened.close();
        availability.close();
        await availability.flushed();
        if (env?.shutdown) await env.shutdown();
        else env?.close?.();
        await db.close();
      },
    };
  } catch (error) {
    await server?.close().catch(() => {});
    await forum?.close().catch(() => {});
    await mirror?.close().catch(() => {});
    await memory?.close().catch(() => {});
    await manager?.close().catch(() => {});
    env?.close?.();
    await db.close().catch(() => {});
    throw error;
  }
}
