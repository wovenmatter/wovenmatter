import {
  type AssistantMessage,
  contentText,
  type FetchFunction,
  type Message,
  type Models,
} from "@earendil-works/pi-ai";
import {
  type AgentChange,
  type CompactionSettings,
  configure,
  defineExtension,
  type Harness,
  type HarnessOptions,
  type HookApi,
  section,
} from "@earendil-works/pi-durable";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { createCompactionRegistry, NativeCompaction } from "./compaction/context.ts";
import { type ModelRef, type Profile, parseModelRef, type RawConfig } from "./config.ts";
import { containerTools } from "./container-tools.ts";
import type { BotEnvironmentAdapter } from "./env.ts";
import type { PreviewManager } from "./environment/previews.ts";
import {
  classifyLimit,
  hasFallbackNote,
  type Limit,
  type LimitCarrier,
  type LimitEntry,
  observeLimits,
} from "./limits.ts";
import type { BeforeCompactHook } from "./memory.ts";
import type { BotRecord } from "./storage/registry.ts";
import { type SubagentLog, subagentExtension } from "./subagent.ts";
import { type BotPlatform, botTools } from "./tools.ts";
import { type WebToolsOptions, webTools } from "./web.ts";
import type { WovenMCP } from "./woven-mcp.ts";

export type CompactionConfig = RawConfig["compaction"];

/** `[compaction]` as Pi Durable's harness-wide policy with per-model overrides. */
export function compactionSettings(config: CompactionConfig | undefined): CompactionSettings {
  if (!config) return { backgroundTokens: 0 };
  const overrides = Object.fromEntries(
    Object.entries(config.models).map(([ref, value]) => [
      ref,
      {
        ...(value.enabled !== undefined ? { enabled: value.enabled } : {}),
        ...(value.reserve_tokens !== undefined ? { reserveTokens: value.reserve_tokens } : {}),
        ...(value.keep_recent_tokens !== undefined
          ? { keepRecentTokens: value.keep_recent_tokens }
          : {}),
        ...(value.background_tokens !== undefined
          ? { backgroundTokens: value.background_tokens }
          : {}),
      },
    ]),
  );
  return {
    enabled: config.enabled,
    reserveTokens: config.reserve_tokens,
    keepRecentTokens: config.keep_recent_tokens,
    backgroundTokens: config.background_tokens,
    ...(Object.keys(overrides).length ? { modelOverrides: overrides } : {}),
  };
}

/** Harness options plus the callback that hands hooks the opened Harness. */
export type BotHarnessOptions = HarnessOptions & { readonly attach?: (harness: Harness) => void };

export type BotAgentOptions = {
  readonly bot: BotRecord;
  /** pi-ai models resolving credentials from the shared credential store. */
  readonly models: Models | (() => Models);
  /**
   * The bot's model profile, read live: its main model drives the main channel and threads;
   * `run_subagent` runs on the conversation's own current model or a pool model. Never hardcoded.
   */
  readonly profile: Profile | (() => Profile);
  /** Server-side log of model choices (subagent runs). */
  readonly onSubagent?: SubagentLog;
  /** A model's marked usage limit (`ModelAvailability.limit`), shown in the subagent model list. */
  readonly modelLimit?: (ref: string) => LimitEntry | undefined;
  /** Bot tools (list/create/message bots, teams, Admin Bot's settings); omitted: none. */
  readonly platform?: BotPlatform;
  /** `web_search` and `fetch_url` (the app always passes it); omitted: no web tools. */
  readonly web?: WebToolsOptions;
  readonly env?: BotEnvironmentAdapter;
  /** `share_preview` (with an environment). */
  readonly previews?: PreviewManager;
  readonly woven?: WovenMCP;
  readonly onReport?: (error: unknown, info: unknown) => void;
  readonly compaction?: CompactionConfig;
  /** Fetch for provider requests (native compaction and generation); tests inject a fake. */
  readonly fetch?: FetchFunction;
  /** Runs before every compaction; a no-op by default (`MemoryExtractor` reads stored messages). */
  readonly onBeforeCompact?: BeforeCompactHook;
  /** The bot's extracted memory as prompt text (`memorySection`); undefined: none yet. */
  readonly memory?: () => Promise<string | undefined>;
  /**
   * A request in `conversationId` on `model` hit a usage limit or ran out of credits. Returns the
   * fallback the conversation runs now (the failed request is retried on it), if it switched.
   */
  readonly onLimit?: (
    conversationId: number,
    model: ModelRef,
    limit: Limit,
  ) => Promise<string | undefined>;
  /**
   * The fallback note while `conversationId` answers on a fallback main model. New turns store it
   * (`Bot.send`); this covers the turn that was switched mid-way.
   */
  readonly fallbackNote?: (conversationId: number) => Promise<string | undefined>;
};

const LIMIT_TEXT: Record<Limit["kind"], string> = {
  five_hour: "hit its 5-hour usage limit",
  weekly: "hit its weekly usage limit",
  usage: "hit a usage limit",
  credits: "ran out of credits",
};

/**
 * After a usage limit: mark it and, when the conversation switched to a fallback, reword the error
 * so Pi Durable's normal retry runs the request again (on the fallback). Transient rate limits and
 * ordinary errors are left to the normal retry rules.
 */
export function limitHook(onLimit: NonNullable<BotAgentOptions["onLimit"]>) {
  return async (message: AssistantMessage, api: { readonly conversationId: unknown }) => {
    const found = classifyLimit(message as AssistantMessage & LimitCarrier);
    if (!found || found.kind === "rate") return;
    const model = { provider: message.provider, modelId: message.model };
    const next = await onLimit(Number(api.conversationId), model, found);
    if (!next) return;
    message.errorMessage = `${model.provider}/${model.modelId} ${LIMIT_TEXT[found.kind]}. Woven Matter switched to the fallback ${next}; you can retry your request.`;
  };
}

/**
 * Put the fallback note in front of the turn's user message for this request when it lacks one
 * (the turn was sent before the switch). Later turns carry it in their stored input.
 */
export function withFallbackNote(
  messages: readonly Message[],
  note: string | undefined,
): readonly Message[] | undefined {
  if (!note) return undefined;
  let index = messages.length - 1;
  while (index >= 0 && messages[index]?.role !== "user") index -= 1;
  const user = messages[index];
  if (user?.role !== "user") return undefined;
  const content = user.content;
  const text = typeof content === "string" ? content : contentText(content);
  if (hasFallbackNote(text)) return undefined;
  const noted: Message = {
    ...user,
    content:
      typeof content === "string"
        ? `${note}\n\n${content}`
        : [{ type: "text", text: `${note}\n\n` }, ...content],
  };
  return [...messages.slice(0, index), noted, ...messages.slice(index + 1)];
}

/** The agent every new bot's main channel starts with (its profile's main model). Threads inherit it via fork. */
export function defaultAgent(main: ModelRef): AgentChange {
  return { model: { provider: main.provider, modelId: main.modelId } };
}

const CONTAINER =
  " Your tools run in your own Linux container (Ubuntu, user bot with passwordless sudo) with your files in /workspace, which persists; git, Node, Python, build tools and Chromium are installed. The container stops after 15 idle minutes and starts again on your next tool call: register long-running services with keep_running so they come back on every start, use the browser tool for websites (its tabs and sign-ins persist), and share_preview to show the user a web app you run.";

/** Admin Bot's standing instructions: account/config management, user's ask = go-ahead. */
export const ADMIN_PROMPT = `You are Admin Bot, the setup bot of this machine's Woven Matter bots. You set up model profiles (which models bots use) and create and organize bots and teams on the user's behalf.
Before you change model profiles, say exactly what you will change and ask the user to confirm, unless the user already asked for that change: their request is the go-ahead. Do not ask twice.
Provider sign-ins and API keys (Claude, ChatGPT, Grok, OpenRouter, OpenCode Go, web search) are Woven Matter accounts, managed in Woven Matter Settings → Subscriptions & API Keys: point the user there. Never ask the user to paste a secret into the chat and never reveal one.
You are never on a team, never manage one and are never the orchestrator. Your name is always Admin Bot; you can rename any other bot when the user asks (rename_bot). Deleting and restoring bots is done by the user in the Bots settings.
In your first conversation, keep it short, friendly and non-technical:
- Introduce yourself: you are Admin Bot, here to take care of setup: creating bots, choosing which models they use, and keeping things organized. Your other bots are the ones the user works with day to day; you handle the admin work.
- Check settings_status, then say which providers are signed in and which model you run on. The user chose it when they set you up, and it is the default model for their bots from now on. Say you can change it whenever they like, or they can change it in Settings → Bots → Profiles. If they have other subscriptions or API keys, they can add them in Settings → Subscriptions & API Keys.
- Explain that new bots use this default model unless the user names a model or profile when they ask for one; to change bots that already exist, they can tell you or use Settings → Bots → Profiles.
- Offer to create their first bot: ask what it should help with.
Mention other bot features (threads, each bot's own Linux computer with a browser, previews, teams, an orchestrator, bots messaging each other) only when they are relevant or the user asks.
Models work through profiles. A profile has a main model, which runs a bot's main channel and every thread. The main model can always hand self-contained work to subagents running on itself (run_subagent); the profile's model pool adds more models for subagents, each with optional notes, and its model preferences are the user's own words about the models, which the main model weighs together with the task, each model's capabilities and its API list prices; they are guidance, not routing rules. Separately, a profile can set a memory extraction model, which reviews new conversation messages and saves useful facts into the bot's memory; unset, the bot's active main model does it. A profile can also list up to 5 ordered fallback main models: when the main model hits a usage limit or its key runs out of credits, the bot switches to the first available fallback and back once the main model resets; with no fallbacks it pauses until then. Every bot runs one profile; new bots get the default profile, and editing a profile changes every bot on it from its next reply.
Setting up models: work from what settings_status lists as signed in and available; never ask the user about subscription tiers or spending. When the user asks for a bot without naming a model or profile, put it on the default profile. When they ask for different models, propose profiles (main and pool models, which bot runs which) and apply them with the profile tools. If a needed connection is missing, send the user to Woven Matter Settings → Subscriptions & API Keys first. Save lasting preferences the user tells you about models with write_account_notes and read them back (read_account_notes) before later model decisions.`;

/** The preamble, read live so team changes apply from the next request. */
async function preamble(options: BotAgentOptions): Promise<string> {
  const container = options.env ? CONTAINER : "";
  if (options.bot.kind === "admin") return ADMIN_PROMPT + container;
  const platform = options.platform;
  const bots = platform ? await platform.manager().list() : [];
  const self = bots.find((bot) => bot.id === options.bot.id);
  // The current name: the user may rename a bot at any time.
  let text = `You are ${self?.name ?? options.bot.name}, a personal assistant bot in Woven Matter. Be concise and helpful.${container}`;
  if (!platform) return text;
  text +=
    "\nYou can create bots when the user asks (create_bot), message any bot (message_bot) and rename yourself when the user asks (rename_me). Model profiles are Admin Bot's job: send the user to Admin Bot. Provider accounts are in Woven Matter Settings → Subscriptions & API Keys.";
  const orchestrator = bots.find((bot) => bot.orchestrator);
  if (self?.orchestrator) {
    const teams = bots
      .filter((bot) => bot.manager && bot.id !== self.id)
      .map((lead) => {
        const members = bots.filter((bot) => bot.managerId === lead.id).map((bot) => bot.name);
        return `${lead.name} (${members.length ? members.join(", ") : "no members yet"})`;
      });
    const others = bots
      .filter((bot) => bot.kind !== "admin" && !bot.orchestrator && !bot.manager && !bot.managerId)
      .map((bot) => bot.name);
    text += `\nYou are the orchestrator: you lead and oversee every bot and team here (Admin Bot stays separate). Orchestrate the work across them (message_bot): hand team work to each team's manager, and other work to bots directly. Teams: ${teams.length ? teams.join("; ") : "none"}. Bots on no team: ${others.length ? others.join(", ") : "none"}.`;
  } else if (orchestrator) {
    text += `\n${orchestrator.name} is the orchestrator: it oversees every bot and team and may hand you work.`;
  }
  if (self?.manager) {
    const members = bots.filter((bot) => bot.managerId === self.id).map((bot) => bot.name);
    text += `\nYou manage a team: ${members.length ? members.join(", ") : "no members yet"}. Your main job is to assign work to your team and orchestrate it (message_bot); bots you create join your team.`;
  } else if (self?.managerId) {
    const lead = bots.find((bot) => bot.id === self.managerId);
    text += `\nYou are on ${lead?.name ?? "a"}'s team; ${lead?.name ?? "your manager"} assigns your work. Bots you create join this team.`;
  }
  return text;
}

/**
 * Harness options for one bot, following the pi-durable-chat composition: one registry and
 * extension, `conversationCreated` configures only the root (main channel) conversation; forks
 * keep the copies they were forked with. With an environment adapter the bot also gets Pi Durable's
 * coding tools (bash, read, write, edit), which run in that environment (the bot's container);
 * without one it has no tools.
 */
export function createBotHarnessOptions(options: BotAgentOptions): BotHarnessOptions {
  const source = options.models;
  const native = new NativeCompaction(typeof source === "function" ? source : () => source, {
    native: options.compaction?.native ?? "auto",
    ...(options.fetch ? { fetch: options.fetch } : {}),
    ...(options.onBeforeCompact ? { onBeforeCompact: options.onBeforeCompact } : {}),
    ...(options.onReport ? { onReport: options.onReport } : {}),
  });
  const profile = () =>
    typeof options.profile === "function" ? options.profile() : options.profile;
  // The bot's identity, standing instructions and memory; subagents run without them.
  const memory = options.memory;
  const identity = defineExtension({
    name: "pi-bot-preamble",
    sections: [
      section("preamble", () => preamble(options), { tag: false }),
      ...(memory ? [section("memory", () => memory())] : []),
    ],
  });
  const fallbackNote = options.fallbackNote;
  const beforeRequest: typeof native.beforeRequest = fallbackNote
    ? async (request, api: HookApi, ctx) => {
        const noted = withFallbackNote(
          request.messages,
          await fallbackNote(Number(api.conversationId)),
        );
        const next = noted ? { messages: noted } : request;
        return (await native.beforeRequest(next, api, ctx)) ?? (noted ? next : undefined);
      }
    : native.beforeRequest;
  const extension = defineExtension({
    name: "pi-bot",
    // One implementation for the main channel and every thread.
    hooks: [
      {
        task: "pi.generation",
        handlers: {
          beforeRequest,
          ...(options.onLimit ? { afterResponse: limitHook(options.onLimit) } : {}),
        },
      },
      { task: "pi.compaction", handlers: { beforeCompact: native.beforeCompact } },
    ],
  });
  const tools = options.platform ? botTools(options.bot, options.platform) : undefined;
  const identityOf = async () =>
    options.platform ? options.platform.manager().record(options.bot.id) : options.bot;
  const woven = options.woven?.extension(options.bot.id, identityOf);
  const container = options.env
    ? containerTools(options.bot.id, options.env, options.previews)
    : undefined;
  const web = options.web ? webTools(options.web) : undefined;
  // What a subagent keeps: coding tools (with a container) and web tools; nothing bot-specific.
  const childTools = [...(options.env ? [CodingTools] : []), ...(web ? [web] : [])].flatMap(
    (installed) => (installed.tools ?? []).map((tool) => tool.name),
  );
  const subagent = subagentExtension({
    childTools,
    profile,
    models: typeof source === "function" ? source : () => source,
    ...(options.modelLimit ? { limit: options.modelLimit } : {}),
    botMessaging: tools !== undefined,
    // Subagents never get the bot's tools (bot-to-bot messaging, Admin Bot's) or its preamble.
    removeFromChild: [
      identity,
      ...(tools ? [tools] : []),
      ...(woven ? [woven] : []),
      ...(container ? [container] : []),
    ],
    ...(options.onSubagent ? { log: options.onSubagent } : {}),
  });
  const extensions = [
    identity,
    extension,
    ...(woven ? [woven] : []),
    ...(options.env ? [CodingTools] : []),
    ...(container ? [container] : []),
    ...(tools ? [tools] : []),
    // Subagents keep the web tools: research is typical delegated work.
    ...(web ? [web] : []),
    subagent,
  ];
  const registry = createCompactionRegistry();
  for (const installed of extensions) registry.install(installed);
  return {
    models: observeLimits(native.models(), options.fetch),
    registry,
    settings: {
      extensions,
      documentRetentionMs: 0,
      // Woven's durable-session settings: SSE transport, no hidden retries, no background compaction.
      stream: { transport: "sse", maxRetries: 0 },
      compaction: compactionSettings(options.compaction),
    },
    attach: (harness) => {
      native.harness.attach(harness);
      if (options.woven) {
        const client = options.woven;
        const stop = client.subscribe((botId) => {
          if (botId === options.bot.id) registry.install(client.extension(botId, identityOf));
        });
        void harness.closed.then(stop);
        // The bot's own Woven MCP key, fetched in the background; cached tools serve meanwhile.
        void identityOf()
          .then((bot) => client.connect(bot))
          .catch(() => {});
      }
    },
    conversationCreated: (tx, conversation) => {
      // Without a main model the conversation starts unconfigured; choosing one applies it.
      const main = profile().main;
      return main && conversation.owner === undefined && conversation.parent === undefined
        ? configure(tx, conversation.id, defaultAgent(parseModelRef(main)))
        : undefined;
    },
    ...(options.env ? { env: options.env.harnessEnv(options.bot.id) } : {}),
    ...(options.onReport
      ? {
          onReport: (report: import("@earendil-works/pi-durable").Report) =>
            options.onReport?.(report.error, report),
        }
      : {}),
  };
}
