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
import { BotEnvironment, IDLE_STOP_MS } from "./environment/container.ts";
import { DockerEngineAPI } from "./environment/engine-api.ts";
import { PreviewManager, type PreviewTransport } from "./environment/previews.ts";
import { type HostAPI, HostClient } from "./host/client.ts";
import { HostCredentialStore } from "./host/credentials.ts";
import { ModelAvailability } from "./limits.ts";
import { MemoryExtractor, memorySection } from "./memory.ts";
import { ConversationMirror } from "./mirror.ts";
import { checkModelRoles, createBotModels } from "./models.ts";
import { RuntimeOperations } from "./operations.ts";
import { ProfileStore } from "./profiles.ts";
import { type BotServer, startServer } from "./server.ts";
import type { SearchProviderId } from "./settings/catalog.ts";
import { SettingsService } from "./settings/service.ts";
import { SettingsStore } from "./settings/store.ts";
import { openSharedDatabase } from "./storage/database.ts";
import { BotRegistry } from "./storage/registry.ts";
import { TitleGenerator } from "./titles.ts";
import { type BotPlatform, forgetBotMessages } from "./tools.ts";
import { WovenMCP } from "./woven-mcp.ts";

export type BotsRuntime = {
  readonly db: SqliteDatabase;
  readonly models: Models;
  readonly manager: BotManager;
  readonly woven: WovenMCP;
  readonly availability: ModelAvailability;
  readonly server: BotServer;
  readonly operations: RuntimeOperations;
  readonly env?: BotEnvironmentAdapter;
  readonly previews?: PreviewManager;
  readonly mirror: ConversationMirror;
  readonly settings: SettingsStore;
  /** Startup environment reconcile (in the background; never rejects). */
  readonly reconciled: Promise<void>;
  close(): Promise<void>;
};

export type StartOptions = {
  /** Override the pi-ai models (tests use the faux provider). */
  readonly models?: Models;
  /** The host API (tests pass a fake). */
  readonly host?: HostAPI;
  /** Where bots' tools run; defaults to containers on the configured engine. `null`: no tools. */
  readonly env?: BotEnvironmentAdapter | null;
  /** How preview traffic reaches a container port; defaults to exec streams. */
  readonly previewTransport?: PreviewTransport;
  /** Settings store override (tests keep settings in memory). */
  readonly settings?: SettingsStore;
  /** Woven MCP HTTP (tests inject a fake). */
  readonly fetch?: typeof fetch;
  readonly port?: number;
  readonly log?: (message: string) => void;
  /** Options for the default container environment (tests shorten the idle period). */
  readonly environment?: Partial<ConstructorParameters<typeof BotEnvironment>[0]>;
};

/** How long before a Woven timer fires that a bot counts as busy. */
const TIMER_WINDOW_MS = 5 * 60_000;

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
  let mirror: ConversationMirror | undefined;
  const settings = options.settings ?? (await SettingsStore.open(config.paths.settings));
  const host = options.host ?? new HostClient(config.host.url, config.host.token);
  const credentials = new HostCredentialStore(host);
  const searchProvider = async (): Promise<SearchProviderId | undefined> =>
    (await host.inferenceCredential("web-search").catch(() => undefined))?.searchProvider;
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
  };
  const db = await openSharedDatabase(config.paths.database);
  const registry = new BotRegistry(db);
  await registry.migrate();
  let env: BotEnvironmentAdapter | undefined;
  let previews: PreviewManager | undefined;
  const woven = new WovenMCP(registry, host, options.fetch ?? fetch);
  // The runtime-side half of the idle rule (the container side is checked inside it).
  const probe = async (botId: string) => {
    const bot = await manager?.get(botId).catch(() => undefined);
    if (bot) {
      const live = await bot.harness.inspect(BACKGROUND_CONTEXT);
      if (live.tasks.length || live.submissions.length) return { busy: "a turn is running" };
    }
    if (server?.viewing(botId)) return { busy: "someone has its chat open" };
    const lastTraffic = previews?.lastTraffic(botId);
    if (lastTraffic && Date.now() - lastTraffic < (options.environment?.idleMs ?? IDLE_STOP_MS)) {
      return { busy: "preview traffic" };
    }
    const record = await manager?.record(botId).catch(() => undefined);
    if (record && (await woven.timerDueWithin(record, TIMER_WINDOW_MS).catch(() => undefined))) {
      return { busy: "a timer is due soon" };
    }
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
        machineId: config.machine.deviceID,
        probe,
        log,
        ...options.environment,
      });
    const environment = env;
    if (environment.connectPort) {
      previews = new PreviewManager({
        host,
        registry,
        transport: options.previewTransport ?? {
          connect: (botId, port) => environment.connectPort!(botId, port),
        },
        activity: (botId) => environment.touch?.(botId),
        log,
      });
    }
  }
  try {
    const models =
      options.models ??
      createBotModels(credentials, {
        claude: {
          directory: config.paths.claude,
          ...(config.claude?.executable ? { executable: config.claude.executable } : {}),
        },
      });
    const profileSet = normalizeProfiles(settings.current);
    if (!options.models) {
      const refs: Record<string, ModelRef> = {};
      const titleModel = settings.current.titles.model;
      if (titleModel) refs["titles.model"] = parseModelRef(titleModel);
      for (const profile of profileSet.profiles) {
        if (profile.main) refs[`profiles.${profile.id}.main`] = parseModelRef(profile.main);
      }
      for (const problem of checkModelRoles(createBotModels(credentials), refs)) log(`warning: ${problem}`);
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
    await woven.load((await registry.list()).map((bot) => bot.id));
    const opened = await BotManager.open({
      db,
      ensureAdmin: true,
      onBotsChanged: () => server?.botsChanged(),
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
          woven,
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
          ...(previews ? { previews } : {}),
          onReport: (error) => log(`bot ${bot.id}: ${String(error)}`),
          onLimit: (conversationId, model, limit) =>
            self.reportLimit(bot.id, conversationId, model, limit),
          fallbackNote: (conversationId) => self.fallbackNote(bot.id, conversationId),
          memory: async () => memorySection((await self.registry.memory(bot.id)).facts),
        });
      },
      onBotOpened: (bot) => mirror?.attach(bot),
      onBotClosed: (bot, reason) => {
        if (reason !== "closed") log(`bot ${bot.id} harness ${reason}`);
      },
      ...(env ? { onBotDeleted: (bot) => env.dispose(bot.id) } : {}),
      onBotPurged: async (botId) => {
        forgetBotMessages(platform, botId);
        await previews?.unshareAll(botId).catch(() => {});
        await woven.revoke(botId).catch((error: unknown) => log(`bot ${botId}: revoke MCP key: ${String(error)}`));
        if (!env) return undefined;
        if (!env.purge) return { removed: false, error: `the ${env.kind} environment can't remove storage` };
        await env.purge(botId);
        return { removed: true };
      },
      titles: new TitleGenerator({
        models,
        // The title model, or else the default profile's main model; neither: no titles yet.
        model: () => {
          const ref = settings.current.titles.model ?? profiles.resolve(undefined).main;
          return ref ? parseModelRef(ref) : undefined;
        },
        reasoning: () => settings.current.titles.reasoning,
      }),
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
    mirror = new ConversationMirror({ manager: opened, host, log });
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
    });
    const operations = new RuntimeOperations({
      manager: opened,
      ...(env ? { env } : {}),
      ...(previews ? { previews } : {}),
      notify: (message) => server?.broadcast(message),
      log,
    });
    server = await startServer({
      manager: opened,
      settings: settingsService,
      woven,
      operations,
      token: config.runtimeToken,
      environment: env?.kind ?? "none",
      host: config.listen.host,
      port: options.port ?? config.listen.port,
      onActivity: (botId) => env?.touch?.(botId),
      ...(previews ? { previews } : {}),
      log,
    });
    memory?.start();
    const activeIds = async () => ({
      active: (await opened.list()).map((bot) => bot.id),
      deleted: (await opened.listDeleted()).map((bot) => bot.id),
    });
    const reconciled = env?.reconcile ? reconcileWithRetry(env, activeIds, log) : Promise.resolve();
    void previews
      ?.restore((await opened.list()).map((bot) => bot.id))
      .catch((error: unknown) => log(`previews: ${String(error)}`));
    return {
      db,
      models,
      manager: opened,
      woven,
      availability,
      server,
      operations,
      ...(env ? { env } : {}),
      ...(previews ? { previews } : {}),
      mirror,
      settings,
      reconciled,
      async close() {
        await server?.close();
        previews?.close();
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
    previews?.close();
    await mirror?.close().catch(() => {});
    await memory?.close().catch(() => {});
    await manager?.close().catch(() => {});
    env?.close?.();
    await db.close().catch(() => {});
    throw error;
  }
}
