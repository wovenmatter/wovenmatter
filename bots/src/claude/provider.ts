import { createHash } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  type AnyModel,
  type Api,
  type AssistantMessage,
  type AssistantMessageEventStream,
  createAssistantMessageEventStream,
  type Message,
  type Model,
  type ModelsStoreEntry,
  type Provider,
  type RefreshModelsContext,
  type Usage,
} from "@earendil-works/pi-ai";
import { createProvider } from "@earendil-works/pi-ai/models";
import { getCurrentSystemPrompt, getCurrentTools } from "@earendil-works/pi-ai/utils/transcript";
import type { ErrorIssue } from "../issues.ts";
import { CLAUDE_AGENT_API } from "../compaction/native.ts";
import { CATALOG_REFRESH_MS } from "../model-catalog.ts";
import { type ClaudeRateLimitInfo, claudeLimit, type LimitClass } from "../limits.ts";
import {
  type ClaudeAgentOptions,
  ClaudeAgentRuntime,
  type ClaudeSdkEvent,
  type ClaudeSdkFrame,
} from "./runtime.ts";
import { NATIVE_KEY } from "../host/credentials.ts";

/**
 * Claude through the Claude Agent SDK (Claude Code), so a Claude subscription works, after Woven
 * Matter's `default-agent/src/claude-provider.mjs`. Pi owns the loop: each request replays the
 * canonical history into a fresh SDK process (`shouldQuery: false` frames), runs exactly one model
 * turn (`maxTurns: 1`, no built-in tools, no settings, no skills), and returns the reply to Pi.
 * Tool calls come back as `mcp__bot__<name>` from an inventory-only MCP server; Pi executes them.
 */

export const CLAUDE_SUBSCRIPTION_PROVIDER = "claude-subscription";
export const CLAUDE_AGENT_BASE_URL = "process://claude-agent-sdk";
const PREFIX = "mcp__bot__";
const INVENTORY = fileURLToPath(
  new URL(import.meta.url.endsWith(".ts") ? "./inventory.ts" : "./inventory.js", import.meta.url),
);

/** Set on a compaction request (`Models.stream` options); the summary comes back on the result. */
export type ClaudeCompactOptions = { readonly botCompact?: { readonly instructions?: string } };
export type ClaudeCompaction = { readonly summary: string; readonly preTokens?: number };
export type ClaudeCompactedMessage = AssistantMessage & {
  botCompaction?: ClaudeCompaction;
  /** The usage limit Claude Code reported for a failed request (see limits.ts). */
  botLimit?: LimitClass;
  /** Claude Code is not signed in (see issues.ts). */
  botIssue?: ErrorIssue;
};

/** Claude Code's own sign-in failure ("Not logged in · Please run /login"), which bots can't run. */
const NOT_LOGGED_IN = /not logged in|please run \/login/i;

const zeroCost = () => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 });
const zeroUsage = (): Usage => ({
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: zeroCost(),
});

class ClaudeAgentError extends Error {}

function nativeToolId(value: string): string {
  if (!value) throw new ClaudeAgentError("This conversation has an invalid tool call id.");
  if (/^[A-Za-z0-9_-]{1,64}$/.test(value)) return value;
  const hash = createHash("sha256").update(value).digest("hex").slice(0, 16);
  return `${value.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 47)}_${hash}`;
}

// biome-ignore lint/suspicious/noExplicitAny: Anthropic Messages content blocks.
type Block = any;

function contentBlocks(content: Extract<Message, { role: "user" }>["content"]): Block[] {
  if (typeof content === "string") return content ? [{ type: "text", text: content }] : [];
  return content.map((block) =>
    block.type === "text"
      ? { type: "text", text: block.text }
      : { type: "image", source: { type: "base64", media_type: block.mimeType, data: block.data } },
  );
}

/** Pi messages to SDK input frames, the tool inventory, and the system prompt. */
export function claudeRequest(messages: readonly Message[], model: Model<Api>, compact = false) {
  const names = new Set<string>();
  const inventory = getCurrentTools(messages).map((tool) => {
    if (!/^[A-Za-z0-9_-]{1,50}$/.test(tool.name) || names.has(tool.name)) {
      throw new ClaudeAgentError(`Tool name "${tool.name}" is not usable through Claude Code.`);
    }
    names.add(tool.name);
    return {
      name: tool.name,
      description: tool.description,
      inputSchema: JSON.parse(JSON.stringify(tool.parameters)),
    };
  });
  const frames: ClaudeSdkFrame[] = [];
  for (const message of messages) {
    let role: "user" | "assistant";
    let content: Block[];
    if (message.role === "system") continue;
    if (message.role === "assistant") {
      role = "assistant";
      content = message.content.flatMap((block): Block[] => {
        if (block.type === "text") return block.text ? [{ type: "text", text: block.text }] : [];
        if (block.type === "toolCall") {
          return [
            {
              type: "tool_use",
              id: nativeToolId(block.id),
              name: PREFIX + block.name,
              input: block.arguments,
            },
          ];
        }
        // Signed thinking is only valid on the route that produced it.
        const sameRoute =
          message.api === model.api &&
          message.provider === model.provider &&
          message.model === model.id;
        if (!sameRoute || !block.thinkingSignature) return [];
        return [
          block.redacted
            ? { type: "redacted_thinking", data: block.thinkingSignature }
            : { type: "thinking", thinking: block.thinking, signature: block.thinkingSignature },
        ];
      });
    } else if (message.role === "toolResult") {
      role = "user";
      content = [
        {
          type: "tool_result",
          tool_use_id: nativeToolId(message.toolCallId),
          content: contentBlocks(message.content),
          is_error: message.isError,
        },
      ];
    } else {
      role = "user";
      content = contentBlocks(message.content);
    }
    if (content.length === 0) continue;
    const last = frames.at(-1);
    if (role === "user" && last?.type === "user") last.message.content.push(...content);
    else
      frames.push({
        type: role,
        message: { role, content },
        parent_tool_use_id: null,
        session_id: "",
      });
  }
  if (!compact && frames.at(-1)?.type !== "user") {
    throw new ClaudeAgentError("Claude needs a user message or tool result to continue.");
  }
  return { frames, inventory, names, system: getCurrentSystemPrompt(messages) };
}

function usageOf(native: Block): Usage {
  const usage = zeroUsage();
  if (!native) return usage;
  usage.input = native.input_tokens ?? 0;
  usage.output = native.output_tokens ?? 0;
  usage.cacheRead = native.cache_read_input_tokens ?? 0;
  usage.cacheWrite = native.cache_creation_input_tokens ?? 0;
  usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite;
  return usage;
}

const EFFORT: Record<string, string> = {
  minimal: "low",
  low: "low",
  medium: "medium",
  high: "high",
  xhigh: "xhigh",
  max: "max",
};

export class ClaudeAgentStream {
  readonly #runtime: ClaudeAgentRuntime;
  constructor(runtime: ClaudeAgentRuntime) {
    this.#runtime = runtime;
  }

  stream(
    model: Model<Api>,
    context: { messages: Message[] },
    options: Record<string, unknown> = {},
  ): AssistantMessageEventStream {
    const stream = createAssistantMessageEventStream();
    const message: ClaudeCompactedMessage = {
      role: "assistant",
      content: [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: zeroUsage(),
      stopReason: "stop",
      timestamp: Date.now(),
    };
    const signal = options.signal as AbortSignal | undefined;
    void this.#run(model, context.messages, options, message, stream).then(
      () => {
        stream.push({ type: "done", reason: message.stopReason as "stop", message });
        stream.end(message);
      },
      (error: unknown) => {
        message.stopReason = signal?.aborted ? "aborted" : "error";
        message.errorMessage = signal?.aborted
          ? "Cancelled."
          : error instanceof Error
            ? error.message
            : String(error);
        stream.push({ type: "error", reason: message.stopReason, error: message });
        stream.end(message);
      },
    );
    return stream;
  }

  async #run(
    model: Model<Api>,
    messages: Message[],
    options: Record<string, unknown> & ClaudeCompactOptions,
    message: ClaudeCompactedMessage,
    stream: AssistantMessageEventStream,
  ): Promise<void> {
    // The server's credential is only a marker: Claude Code keeps its own sign-in.
    if (options.apiKey !== NATIVE_KEY) {
      throw new ClaudeAgentError(
        "No Claude connection. Sign in with Claude in Woven Matter Settings → Subscriptions & API Keys.",
      );
    }
    const compact = options.botCompact;
    const request = claudeRequest(messages, model, compact !== undefined);
    const workspace = await this.#runtime.workspace();
    const scratch = await mkdtemp(join(workspace, "request-"));
    const toolsFile = join(scratch, "tools.json");
    await writeFile(toolsFile, JSON.stringify(request.inventory), { mode: 0o600 });

    const controller = new AbortController();
    const signal = options.signal as AbortSignal | undefined;
    const abort = () => controller.abort();
    signal?.addEventListener("abort", abort, { once: true });
    if (signal?.aborted) controller.abort();
    let timer: ReturnType<typeof setTimeout> | undefined;
    let timedOut = false;
    const resetTimeout = () => {
      clearTimeout(timer);
      timer = setTimeout(() => {
        timedOut = true;
        controller.abort();
      }, this.#runtime.options.timeoutMs ?? 180_000);
      timer.unref?.();
    };

    let acknowledge: (() => void) | undefined;
    const aborted = new Promise<void>((resolve) =>
      controller.signal.addEventListener("abort", () => resolve(), { once: true }),
    );
    async function* input(): AsyncGenerator<ClaudeSdkFrame> {
      for (const [index, frame] of request.frames.entries()) {
        const replay =
          frame.type === "user" && (compact !== undefined || index < request.frames.length - 1);
        const waiting = replay
          ? new Promise<void>((resolve) => {
              acknowledge = resolve;
            })
          : undefined;
        yield {
          ...frame,
          client_composed: true,
          ...(replay ? { shouldQuery: false as const } : {}),
        };
        // A historical user frame is appended without a turn; wait for its zero-turn result.
        if (waiting) await Promise.race([waiting, aborted]);
        if (controller.signal.aborted) return;
      }
      if (compact !== undefined) {
        const text = compact.instructions ? `/compact ${compact.instructions}` : "/compact";
        yield {
          type: "user",
          message: { role: "user", content: [{ type: "text", text }] },
          parent_tool_use_id: null,
          session_id: "",
        };
      }
    }

    let summary: string | undefined;
    let boundary: ClaudeSdkEvent | undefined;
    let failure: string | undefined;
    let rateLimit: ClaudeRateLimitInfo | undefined;
    let assistantError: string | undefined;
    let replyId: string | undefined;
    const reply: Block[] = [];
    let replyUsage: Block;
    let stopReason: string | undefined;
    let started = false;
    const indices = new Map<number, number>();
    const textual = message.content as Block[];

    const onPartial = (event: Block) => {
      if (event.type === "message_start") {
        if (replyId !== undefined && event.message?.id !== replyId) return;
        replyId = event.message?.id;
        if (!started) {
          started = true;
          message.responseId = replyId;
          stream.push({ type: "start", partial: message });
        }
        return;
      }
      if (event.type === "content_block_start") {
        const block = event.content_block;
        if (block?.type !== "text" && block?.type !== "thinking") return;
        const index = textual.length;
        indices.set(event.index, index);
        textual.push(
          block.type === "text"
            ? { type: "text", text: block.text ?? "" }
            : { type: "thinking", thinking: block.thinking ?? "" },
        );
        stream.push({
          type: block.type === "text" ? "text_start" : "thinking_start",
          contentIndex: index,
          partial: message,
        });
      } else if (event.type === "content_block_delta") {
        const index = indices.get(event.index);
        if (index === undefined) return;
        const block = textual[index];
        if (event.delta?.type === "text_delta") {
          block.text += event.delta.text;
          stream.push({
            type: "text_delta",
            contentIndex: index,
            delta: event.delta.text,
            partial: message,
          });
        } else if (event.delta?.type === "thinking_delta") {
          block.thinking += event.delta.thinking;
          stream.push({
            type: "thinking_delta",
            contentIndex: index,
            delta: event.delta.thinking,
            partial: message,
          });
        }
      } else if (event.type === "content_block_stop") {
        const index = indices.get(event.index);
        if (index === undefined) return;
        indices.delete(event.index);
        const block = textual[index];
        stream.push(
          block.type === "text"
            ? { type: "text_end", contentIndex: index, content: block.text, partial: message }
            : {
                type: "thinking_end",
                contentIndex: index,
                content: block.thinking,
                partial: message,
              },
        );
      }
    };

    const effort = typeof options.reasoning === "string" ? EFFORT[options.reasoning] : undefined;
    let query: Awaited<ReturnType<ClaudeAgentRuntime["query"]>> | undefined;
    try {
      resetTimeout();
      query = await this.#runtime.query({
        prompt: input(),
        options: {
          cwd: workspace,
          env: this.#runtime.environment(),
          model: model.id,
          tools: [],
          skills: [],
          settingSources: [],
          strictMcpConfig: true,
          mcpServers: { bot: { command: process.execPath, args: [INVENTORY, toolsFile] } },
          systemPrompt: { type: "custom", prompt: request.system, snapshot: false },
          maxTurns: 1,
          permissionMode: "dontAsk",
          includePartialMessages: true,
          persistSession: false,
          ...(effort ? { effort } : {}),
          hooks: {
            PostCompact: [
              {
                hooks: [
                  async (event: { compact_summary?: string }) => {
                    summary = event.compact_summary;
                    return {};
                  },
                ],
              },
            ],
          },
          abortController: controller,
          stderr: () => {},
        },
      });
      for await (const event of query) {
        resetTimeout();
        if (event.type === "system" && event.subtype === "compact_boundary") boundary = event;
        else if (event.type === "rate_limit_event") rateLimit = event.rate_limit_info;
        else if (event.type === "result" && acknowledge) {
          if (event.is_error || event.num_turns !== 0) {
            throw new ClaudeAgentError("Claude Code could not restore this conversation.");
          }
          const resolve = acknowledge;
          acknowledge = undefined;
          resolve();
        } else if (event.type === "result") {
          // A tool call ends the only allowed turn: Pi, not Claude Code, runs the tool.
          if (event.is_error && event.subtype !== "error_max_turns") {
            const reported = [event.api_error_status, event.result, ...(event.errors ?? [])]
              .filter(Boolean)
              .join(" ");
            // Keep the assistant's error text when the result carries nothing more.
            failure = reported || failure || "";
          }
          break;
        } else if (event.type === "stream_event" && event.parent_tool_use_id == null) {
          onPartial(event.event);
        } else if (event.type === "assistant" && event.parent_tool_use_id == null) {
          if (event.error) {
            assistantError = String(event.error);
            failure = (event.message?.content ?? [])
              .filter((block: Block) => block.type === "text")
              .map((block: Block) => block.text)
              .join(" ");
            continue;
          }
          const id = event.message?.id;
          if (replyId === undefined) replyId = id;
          if (id !== replyId) continue;
          reply.push(...(event.message?.content ?? []));
          replyUsage = event.message?.usage ?? replyUsage;
          stopReason = event.message?.stop_reason ?? stopReason;
        }
      }
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      controller.abort();
      acknowledge?.();
      query?.close?.();
      await rm(scratch, { recursive: true, force: true });
    }
    signal?.throwIfAborted();
    if (failure) {
      const limit = claudeLimit(rateLimit, assistantError, failure);
      if (limit) message.botLimit = limit;
    }
    if (timedOut) throw new ClaudeAgentError("The Claude request timed out.");

    if (compact !== undefined) {
      if (!boundary || !summary) {
        throw new ClaudeAgentError(failure ?? "Claude Code did not compact this conversation.");
      }
      message.botCompaction = { summary, preTokens: boundary.compact_metadata?.pre_tokens };
      return;
    }
    if (assistantError === "authentication_failed" || (failure && NOT_LOGGED_IN.test(failure))) {
      message.botIssue = "signIn";
      throw new ClaudeAgentError("Not logged in to Claude.");
    }
    if (failure) throw new ClaudeAgentError(failure);
    if (reply.length === 0) throw new ClaudeAgentError("Claude Code stopped before replying.");

    const ids = new Set<string>();
    message.content = reply.flatMap((block): AssistantMessage["content"] => {
      if (block.type === "text") return [{ type: "text", text: block.text }];
      if (block.type === "thinking") {
        return [{ type: "thinking", thinking: block.thinking, thinkingSignature: block.signature }];
      }
      if (block.type === "redacted_thinking") {
        return [{ type: "thinking", thinking: "", redacted: true, thinkingSignature: block.data }];
      }
      if (block.type === "tool_use") {
        const name = typeof block.name === "string" ? block.name.slice(PREFIX.length) : "";
        if (
          !block.name.startsWith(PREFIX) ||
          !request.names.has(name) ||
          !block.id ||
          ids.has(block.id) ||
          !block.input ||
          typeof block.input !== "object" ||
          Array.isArray(block.input)
        ) {
          throw new ClaudeAgentError("Claude returned a tool outside the active tool inventory.");
        }
        ids.add(block.id);
        return [{ type: "toolCall", id: block.id, name, arguments: block.input }];
      }
      return [];
    });
    if (!started) stream.push({ type: "start", partial: message });
    for (const [index, block] of message.content.entries()) {
      if (block.type !== "toolCall") continue;
      stream.push({ type: "toolcall_start", contentIndex: index, partial: message });
      stream.push({ type: "toolcall_end", contentIndex: index, toolCall: block, partial: message });
    }
    message.usage = usageOf(replyUsage);
    if (stopReason) message.rawStopReason = stopReason;
    message.stopReason = ids.size
      ? "toolUse"
      : stopReason === "max_tokens" || stopReason === "model_context_window_exceeded"
        ? "length"
        : "stop";
  }
}

/** A model Claude Code offers its sign-in: an entry of the SDK's `supportedModels()`. */
export type ClaudeCodeModel = {
  readonly value: string;
  readonly displayName: string;
  readonly resolvedModel?: string;
  readonly supportedEffortLevels?: readonly string[];
};

const isClaudeCodeModel = (entry: unknown): entry is ClaudeCodeModel =>
  typeof (entry as ClaudeCodeModel)?.value === "string" && typeof (entry as ClaudeCodeModel).displayName === "string";

/** "Opus 5.5" for `opus` resolving to claude-opus-5-5, as Pi Durable names it; else Claude Code's own name. */
function modelName(model: ClaudeCodeModel): string {
  const base = model.value.replace(/\[1m\]$/, "").replace(/^claude-/, "");
  const family = base.match(/^[a-z]+/i)?.[0];
  if (!family || base === "default") return model.displayName;
  const title = family[0]?.toUpperCase() + family.slice(1).toLowerCase();
  const resolved = typeof model.resolvedModel === "string" ? model.resolvedModel : model.value;
  const number = resolved.match(
    new RegExp(`^claude-${family}-(\\d+(?:[-.]\\d{1,2})?)(?:-\\d{8})?(?:\\[1m\\])?$`, "i"),
  )?.[1];
  return number ? `${title} ${number.replace("-", ".")}` : model.displayName;
}

/** A Claude Code model as pi-ai lists it, defined as Pi Durable defines it (`default-agent/src/claude.mjs`). */
export function claudeCodeModel(model: ClaudeCodeModel): Model<Api> & { readonly resolvedModel?: string } {
  const levels = model.supportedEffortLevels ?? [];
  return {
    id: model.value,
    name: modelName(model),
    api: CLAUDE_AGENT_API,
    provider: CLAUDE_SUBSCRIPTION_PROVIDER,
    baseUrl: CLAUDE_AGENT_BASE_URL,
    reasoning: levels.length > 0,
    input: ["text", "image"],
    thinkingLevelMap: Object.fromEntries(
      ["off", "minimal", "low", "medium", "high", "xhigh", "max"].map((level) => [
        level,
        level === "off" || levels.includes(level) ? level : null,
      ]),
    ),
    contextWindow: 200_000,
    maxTokens: 32_000,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    ...(model.resolvedModel ? { resolvedModel: model.resolvedModel } : {}),
  } as unknown as Model<Api> & { readonly resolvedModel?: string };
}

/** Claude Code's models in a stored catalog, or undefined when it holds none of them. */
function storedModels(stored: Readonly<ModelsStoreEntry> | undefined): ClaudeCodeModel[] | undefined {
  const entries = stored?.models as readonly unknown[] | undefined;
  return entries?.length && entries.every(isClaudeCodeModel) ? [...entries] : undefined;
}

export type ClaudeAgentProvider = {
  readonly provider: Provider;
  /** Show a stored list. Starts no Claude Code. */
  readonly restore: (stored: Readonly<ModelsStoreEntry> | undefined) => void;
};

/**
 * The `claude-subscription` provider: the models Claude Code offers its sign-in on this machine,
 * served through Claude Code. `Models.refresh()` restores the stored list, and asks Claude Code
 * again when there is none, it is older than the live catalogs' four hours, or the refresh is
 * forced. pi-ai runs that only with a Claude sign-in.
 */
export function claudeAgentProvider(options: ClaudeAgentOptions): ClaudeAgentProvider {
  const runtime = new ClaudeAgentRuntime(options);
  const agent = new ClaudeAgentStream(runtime);
  const stream = (model: Model<Api>, context: { messages: Message[] }, request?: object) =>
    agent.stream(model, context, request as Record<string, unknown>);
  const base = createProvider({
    id: CLAUDE_SUBSCRIPTION_PROVIDER,
    name: "Claude (Claude Agent SDK)",
    baseUrl: CLAUDE_AGENT_BASE_URL,
    auth: {
      // The server supplies a marker for Claude Code's own sign-in (no token material).
      apiKey: {
        name: "Claude (Woven connection)",
        resolve: async (input: { credential?: { key?: string } }) =>
          input.credential?.key === NATIVE_KEY
            ? { auth: { apiKey: NATIVE_KEY }, source: "Claude Code" }
            : undefined,
      },
    },
    models: [],
    api: { stream, streamSimple: stream },
  } as unknown as Parameters<typeof createProvider>[0]);
  let listed: readonly Model<Api>[] = [];
  const show = (models: readonly ClaudeCodeModel[] | undefined) => {
    if (models) listed = models.map(claudeCodeModel);
  };
  const provider = {
    ...base,
    getModels: () => listed,
    getAllModels: () => listed,
    refreshModels: async (context: RefreshModelsContext) => {
      const stored = storedModels(context.stored);
      const shown = await context.publish({ update: () => show(stored) });
      if (!shown || !context.allowNetwork || context.signal.aborted) return;
      const age = Date.now() - (context.stored?.checkedAt ?? 0);
      if (stored && !context.force && age >= 0 && age < CATALOG_REFRESH_MS) return;
      const found = await discoverModels(runtime);
      await context.publish({
        persist: { models: found as unknown as AnyModel[], checkedAt: Date.now() },
        update: () => show(found),
      });
    },
  } as Provider;
  return { provider, restore: (stored) => show(storedModels(stored)) };
}

/** Claude Code's models for its sign-in: an empty streaming input starts it without a model request. */
async function discoverModels(runtime: ClaudeAgentRuntime): Promise<ClaudeCodeModel[]> {
  const workspace = await runtime.workspace();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15_000);
  async function* input(): AsyncGenerator<ClaudeSdkFrame> {
    await new Promise((resolve) => controller.signal.addEventListener("abort", resolve, { once: true }));
  }
  const session = await runtime.query({
    prompt: input(),
    options: {
      cwd: workspace,
      env: runtime.environment(),
      tools: [],
      settingSources: [],
      strictMcpConfig: true,
      mcpServers: {},
      persistSession: false,
      abortController: controller,
      stderr: () => {},
    },
  });
  try {
    const models = await session.supportedModels?.();
    if (!Array.isArray(models) || !models.length || !models.every(isClaudeCodeModel)) {
      throw new ClaudeAgentError("Claude Code did not list its models.");
    }
    return models;
  } finally {
    clearTimeout(timer);
    controller.abort();
    session.close?.();
  }
}
