import { randomUUID } from "node:crypto";
import type { JsonValue } from "@earendil-works/chord";
import type { ToolResultMessage } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, type Extension, section } from "@earendil-works/pi-durable";
import { Type } from "typebox";
import type { HostAPI } from "./host/client.ts";
import type { BotRegistry } from "./storage/registry.ts";

const CACHE_NOTE = "woven.mcp.tools.";
const UNAVAILABLE = "Woven Matter is unavailable. Check its MCP connection and try again.";
/** Browser, computer and session tools can legitimately run for minutes. */
const TOOL_CALL_TIMEOUT_MS = 15 * 60_000;
export type WovenStatus = {
  state: "disconnected" | "connecting" | "ready" | "unavailable";
  endpointURL?: string;
  toolCount: number;
  error?: string;
  /** Per bot (additive): each bot has its own Woven MCP key. */
  bots?: Record<string, { state: WovenStatus["state"]; toolCount: number }>;
};
type BotIdentity = { id: string; name: string };
export type WovenTool = {
  name: string;
  description?: string;
  inputSchema: { type: "object"; [key: string]: unknown };
  annotations?: { readOnlyHint?: boolean; idempotentHint?: boolean };
};
type ToolResult = {
  content?: ToolResultMessage["content"];
  isError?: boolean;
  structuredContent?: JsonValue;
};
type Key = { endpointURL: string; bearerToken: string };
type BotState = {
  key?: Key;
  tools: WovenTool[];
  state: WovenStatus["state"];
  error?: string;
  /** In-flight key and tool fetch, shared by concurrent callers. */
  connecting?: Promise<void>;
};

export function validateWovenEndpoint(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error("Invalid Woven MCP endpoint.");
  }
  if (
    url.username ||
    url.password ||
    url.hash ||
    (url.protocol !== "https:" &&
      !(url.protocol === "http:" && ["127.0.0.1", "[::1]", "localhost"].includes(url.hostname)))
  ) {
    throw new Error("Woven MCP requires HTTPS or a loopback HTTP endpoint.");
  }
  return url.href;
}

function validateTools(value: unknown): WovenTool[] {
  if (!Array.isArray(value) || value.length > 512) throw new Error(UNAVAILABLE);
  const names = new Set<string>();
  for (const item of value) {
    if (
      !item ||
      typeof item !== "object" ||
      !/^woven_[a-z0-9_]+$/.test(item.name) ||
      names.has(item.name) ||
      item.inputSchema?.type !== "object"
    )
      throw new Error(UNAVAILABLE);
    names.add(item.name);
  }
  return value;
}

/**
 * Woven MCP for every bot. Each bot has its own key from the machine's Woven server (principal
 * `woven:bot:<machine-device-id>:<bot-id>`), so attribution, per-bot revoke and pause-all live in
 * Woven. Keys stay in memory only; tool definitions (no secrets) are cached per bot so a restart
 * never waits on the network. Stateless JSON-RPC; credentials never enter the registry or the
 * transcript.
 */
export class WovenMCP {
  readonly #registry: BotRegistry;
  readonly #host: Pick<HostAPI, "mcpKey" | "revokeMcpKey">;
  readonly #fetch: typeof fetch;
  readonly #listeners = new Set<(botId: string) => void>();
  readonly #bots = new Map<string, BotState>();

  constructor(
    registry: BotRegistry,
    host: Pick<HostAPI, "mcpKey" | "revokeMcpKey">,
    fetcher: typeof fetch = fetch,
  ) {
    this.#registry = registry;
    this.#host = host;
    this.#fetch = fetcher;
  }

  #state(botId: string): BotState {
    let state = this.#bots.get(botId);
    if (!state) {
      state = { tools: [], state: "disconnected" };
      this.#bots.set(botId, state);
    }
    return state;
  }

  /** Restore cached tool lists only: an unreachable Woven server never holds up bot startup. */
  async load(botIds: readonly string[]): Promise<void> {
    for (const botId of botIds) {
      const cache = await this.#registry.note(`${CACHE_NOTE}${botId}`);
      if (!cache?.text) continue;
      try {
        const state = this.#state(botId);
        state.tools = validateTools(JSON.parse(cache.text));
        state.state = "unavailable";
        state.error = "Woven Matter tools will reconnect on use.";
      } catch {
        // A corrupt cache is refetched on connect.
      }
    }
  }

  status(): WovenStatus {
    const bots = Object.fromEntries(
      [...this.#bots].map(([id, state]) => [
        id,
        { state: state.state, toolCount: state.key || state.tools.length ? state.tools.length : 0 },
      ]),
    );
    const states = Object.values(bots).map((bot) => bot.state);
    const state: WovenStatus["state"] = states.includes("ready")
      ? "ready"
      : states.includes("connecting")
        ? "connecting"
        : states.includes("unavailable")
          ? "unavailable"
          : "disconnected";
    return {
      state,
      toolCount: Math.max(0, ...Object.values(bots).map((bot) => bot.toolCount)),
      ...(state === "unavailable" ? { error: UNAVAILABLE } : {}),
      bots,
    };
  }

  connected(botId: string): boolean {
    const state = this.#bots.get(botId);
    return state !== undefined && (state.key !== undefined || state.tools.length > 0);
  }

  hasTool(botId: string, name: string): boolean {
    return this.#bots.get(botId)?.tools.some((tool) => tool.name === name) ?? false;
  }

  subscribe(listener: (botId: string) => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  #changed(botId: string): void {
    for (const listener of this.#listeners) listener(botId);
  }

  /** Get this bot's key from the host and list its tools (once; again after `refresh`). */
  connect(bot: BotIdentity, options: { readonly refresh?: boolean } = {}): Promise<void> {
    const state = this.#state(bot.id);
    if (state.connecting) return state.connecting;
    if (state.key && state.state === "ready" && !options.refresh) return Promise.resolve();
    const run = (async () => {
      state.state = "connecting";
      this.#changed(bot.id);
      try {
        const issued = await this.#host.mcpKey(bot.id, bot.name);
        const key = {
          endpointURL: validateWovenEndpoint(issued.endpoint),
          bearerToken: issued.token,
        };
        if (!/^[A-Za-z0-9._~+/-]+=*$/.test(key.bearerToken))
          throw new Error("Invalid Woven MCP credential.");
        state.key = key;
        const tools: WovenTool[] = [];
        const cursors = new Set<string>();
        const signal = AbortSignal.timeout(30_000);
        let cursor: string | undefined;
        do {
          const page = await this.#rpc<{ tools: WovenTool[]; nextCursor?: string }>(
            key,
            bot,
            "tools/list",
            cursor ? { cursor } : {},
            signal,
          );
          tools.push(...validateTools(page.tools));
          validateTools(tools);
          cursor = page.nextCursor;
          if (cursor !== undefined && (typeof cursor !== "string" || cursors.has(cursor)))
            throw new Error(UNAVAILABLE);
          if (cursor) cursors.add(cursor);
          if (cursors.size > 512) throw new Error(UNAVAILABLE);
        } while (cursor);
        await this.#registry.setNote(`${CACHE_NOTE}${bot.id}`, JSON.stringify(tools));
        state.tools = tools;
        state.state = "ready";
        state.error = undefined;
      } catch {
        state.state = "unavailable";
        state.error = UNAVAILABLE;
      } finally {
        state.connecting = undefined;
      }
      this.#changed(bot.id);
    })();
    state.connecting = run;
    return run;
  }

  /** A purged bot: revoke its key in Woven and forget its tools. */
  async revoke(botId: string): Promise<void> {
    this.#bots.delete(botId);
    await this.#registry.setNote(`${CACHE_NOTE}${botId}`, "");
    await this.#host.revokeMcpKey(botId);
  }

  async #rpc<T>(
    bound: Key,
    bot: BotIdentity,
    method: string,
    params: object,
    signal: AbortSignal,
  ): Promise<T> {
    const id = randomUUID();
    const response = await this.#fetch(bound.endpointURL, {
      method: "POST",
      redirect: "error",
      signal,
      headers: {
        "content-type": "application/json",
        accept: "application/json",
        authorization: `Bearer ${bound.bearerToken}`,
        "x-woven-bot-id": bot.id,
        "x-woven-bot-name": encodeURIComponent(bot.name),
      },
      body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
    });
    if (response.status === 401) throw Object.assign(new Error(UNAVAILABLE), { unauthorized: true });
    if (!response.ok) throw new Error(UNAVAILABLE);
    // Even a broken endpoint echoing its authorization must not leak it to a tool result/cache.
    const message = JSON.parse(await response.text());
    if (message.jsonrpc !== "2.0" || message.id !== id || message.error || !message.result)
      throw new Error(UNAVAILABLE);
    return JSON.parse(
      JSON.stringify(message.result).split(bound.bearerToken).join("[redacted]"),
    ) as T;
  }

  async callTool(
    bot: BotIdentity,
    name: string,
    input: Record<string, unknown>,
    signal: AbortSignal,
  ): Promise<ToolResult> {
    const state = this.#state(bot.id);
    if (!state.key) await this.connect(bot);
    let bound = state.key;
    if (!bound)
      return { isError: true, content: [{ type: "text", text: UNAVAILABLE }] };
    const requestID = input.requestID ?? randomUUID();
    const call = (key: Key) =>
      this.#rpc<ToolResult>(
        key,
        bot,
        "tools/call",
        { name, arguments: { ...input, requestID } },
        AbortSignal.any([signal, AbortSignal.timeout(TOOL_CALL_TIMEOUT_MS)]),
      );
    try {
      signal.throwIfAborted();
      let result: ToolResult;
      try {
        result = await call(bound);
      } catch (error) {
        // A revoked or rotated key: ask the host for this bot's key once more.
        if (!(error as { unauthorized?: boolean }).unauthorized) throw error;
        await this.connect(bot, { refresh: true });
        if (!state.key || state.key === bound) throw error;
        bound = state.key;
        result = await call(bound);
      }
      if (state.key === bound) {
        state.state = "ready";
        state.error = undefined;
      }
      return result;
    } catch {
      if (
        signal.aborted &&
        ["woven_browser_use", "woven_computer_use", "woven_html_preview"].includes(name)
      ) {
        await this.#rpc(
          bound,
          bot,
          "tools/call",
          {
            name: name === "woven_html_preview" ? "woven_html_cancel" : `${name}_cancel`,
            arguments: { id: requestID },
          },
          AbortSignal.timeout(3000),
        ).catch(() => {});
      }
      if (state.key === bound && !signal.aborted) {
        state.state = "unavailable";
        state.error = UNAVAILABLE;
      }
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: signal.aborted ? "Woven Matter tool call cancelled." : UNAVAILABLE,
          },
        ],
      };
    }
  }

  /**
   * Whether one of the bot's Woven timers fires within `withinMs`, from `woven_timers_list`.
   * Undefined when it can't be told (no timer tool, Woven unreachable): a due timer is
   * delivered to the bot through the runtime protocol and wakes it either way.
   */
  async timerDueWithin(bot: BotIdentity, withinMs: number, now = Date.now()): Promise<boolean | undefined> {
    if (!this.hasTool(bot.id, "woven_timers_list")) return undefined;
    const result = await this.callTool(
      bot,
      "woven_timers_list",
      { limit: 200 },
      AbortSignal.timeout(10_000),
    );
    if (result.isError) return undefined;
    const values: unknown[] = [];
    if (result.structuredContent !== undefined) values.push(result.structuredContent);
    for (const block of result.content ?? []) {
      if (block.type !== "text") continue;
      try {
        values.push(JSON.parse(block.text));
      } catch {
        // Not JSON: nothing to read.
      }
    }
    return values.some((value) => timerDue(value, now, withinMs));
  }

  extension(botId: string, bot: () => Promise<BotIdentity>): Extension {
    const state = this.#bots.get(botId);
    const tools = state && this.connected(botId) ? state.tools : [];
    return defineExtension({
      name: "pi-bot-woven-mcp",
      sections: [
        section("woven_matter", () =>
          this.connected(botId)
            ? "Woven Matter tools are available. Schedules are Woven timers (woven_timers_*): a due timer is delivered to you as a message. You can launch and manage agent sessions in Woven Matter workspaces with woven_sessions_* tools."
            : undefined,
        ),
      ],
      tools: tools.map((definition) =>
        defineTool({
          name: definition.name,
          description: definition.description ?? "",
          parameters: Type.Unsafe<Record<string, unknown>>(definition.inputSchema),
          replay:
            definition.annotations?.readOnlyHint === true &&
            definition.annotations?.idempotentHint !== false
              ? "safe"
              : "unsafe",
          execute: async (input, api, ctx) => {
            const requestID =
              input.requestID ?? (await api.memo("wovenRequestID", randomUUID(), ctx));
            const result = await this.callTool(
              await bot(),
              definition.name,
              { ...input, requestID },
              ctx.abortSignal ?? new AbortController().signal,
            );
            return {
              output: result.content ?? [],
              isError: result.isError === true,
              ...(result.structuredContent === undefined
                ? {}
                : { details: { structuredContent: result.structuredContent } }),
            };
          },
        }),
      ),
    });
  }
}

const DATE_KEYS = ["at", "next", "nextAt", "nextFire", "nextFireAt", "fireAt", "due", "dueAt"];

/** Any unpaused timer-like object in `value` whose next fire time falls within the window. */
export function timerDue(value: unknown, now: number, withinMs: number, depth = 0): boolean {
  if (depth > 6 || value === null || typeof value !== "object") return false;
  if (Array.isArray(value)) return value.some((item) => timerDue(item, now, withinMs, depth + 1));
  const record = value as Record<string, unknown>;
  if (record.paused !== true) {
    for (const key of DATE_KEYS) {
      const raw = record[key];
      const at =
        typeof raw === "string" ? Date.parse(raw) : typeof raw === "number" ? raw : Number.NaN;
      if (Number.isFinite(at) && at >= now - 60_000 && at <= now + withinMs) return true;
    }
  }
  return Object.values(record).some((item) => timerDue(item, now, withinMs, depth + 1));
}
