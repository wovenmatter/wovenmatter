import { createHash } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  type Api,
  type AssistantMessage,
  type AssistantMessageEventStream,
  createAssistantMessageEventStream,
  type Message,
  type Model,
  type Provider,
  type Usage,
} from "@earendil-works/pi-ai";
import { createProvider } from "@earendil-works/pi-ai/models";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { getCurrentSystemPrompt, getCurrentTools } from "@earendil-works/pi-ai/utils/transcript";
import type { ErrorIssue } from "../issues.ts";
import { CLAUDE_AGENT_API } from "../compaction/native.ts";
import { type ClaudeRateLimitInfo, claudeLimit, type LimitClass } from "../limits.ts";
import {
  type ClaudeAgentOptions,
  ClaudeAgentRuntime,
  type ClaudeSdkEvent,
  type ClaudeSdkFrame,
} from "./runtime.ts";
import { NATIVE_PREFIX } from "../host/credentials.ts";

/**
 * Claude through the Claude Agent SDK (Claude Code), so a Claude subscription works, after Woven
 * Matter's `default-agent/src/claude-provider.mjs`. Pi owns the loop: each request replays the
 * canonical history into a fresh SDK process (`shouldQuery: false` frames), runs exactly one model
 * turn (`maxTurns: 1`, no built-in tools, no settings, no skills), and returns the reply to Pi.
 * Tool calls come back as `mcp__pibot__<name>` from an inventory-only MCP server; Pi executes them.
 */

export const CLAUDE_SUBSCRIPTION_PROVIDER = "claude-subscription";
export const CLAUDE_AGENT_BASE_URL = "process://claude-agent-sdk";
const PREFIX = "mcp__pibot__";
const INVENTORY = fileURLToPath(
  new URL(import.meta.url.endsWith(".ts") ? "./inventory.ts" : "./inventory.js", import.meta.url),
);

/** Set on a compaction request (`Models.stream` options); the summary comes back on the result. */
export type ClaudeCompactOptions = { readonly pibotCompact?: { readonly instructions?: string } };
export type ClaudeCompaction = { readonly summary: string; readonly preTokens?: number };
export type ClaudeCompactedMessage = AssistantMessage & {
  pibotCompaction?: ClaudeCompaction;
  /** The usage limit Claude Code reported for a failed request (see limits.ts). */
  pibotLimit?: LimitClass;
  /** Claude Code is not signed in (see issues.ts). */
  pibotIssue?: ErrorIssue;
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

export type ClaudeCredential = {
  /** The machine's native Claude runtime directories: Claude Code owns the sign-in there. */
  readonly native?: { readonly configDir: string; readonly secureStorageDir?: string };
  /** A setup token or API key handed to Claude Code through its environment. */
  readonly key?: string;
};

/** Split the host's credential: a marked native profile, or a plain key. */
export function claudeCredential(key: string): ClaudeCredential {
  if (!key.startsWith(NATIVE_PREFIX)) return { key };
  try {
    const parsed = JSON.parse(key.slice(NATIVE_PREFIX.length)) as {
      configDir?: unknown;
      secureStorageDir?: unknown;
    };
    if (typeof parsed.configDir !== "string" || !parsed.configDir) throw new Error();
    return {
      native: {
        configDir: parsed.configDir,
        ...(typeof parsed.secureStorageDir === "string" && parsed.secureStorageDir
          ? { secureStorageDir: parsed.secureStorageDir }
          : {}),
      },
    };
  } catch {
    throw new ClaudeAgentError("The Claude connection from Woven Matter is unreadable.");
  }
}

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
    const key = options.apiKey;
    if (typeof key !== "string" || !key) {
      throw new ClaudeAgentError(
        "No Claude connection. Connect Claude in Woven Matter Settings → Subscriptions & API Keys.",
      );
    }
    const credential = claudeCredential(key);
    const compact = options.pibotCompact;
    const request = claudeRequest(messages, model, compact !== undefined);
    const { config, workspace } = await this.#runtime.directories(credential.native?.configDir);
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
          env: this.#runtime.environment(config, credential),
          model: model.id,
          tools: [],
          skills: [],
          settingSources: [],
          strictMcpConfig: true,
          mcpServers: { pibot: { command: process.execPath, args: [INVENTORY, toolsFile] } },
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
      if (limit) message.pibotLimit = limit;
    }
    if (timedOut) throw new ClaudeAgentError("The Claude request timed out.");

    if (compact !== undefined) {
      if (!boundary || !summary) {
        throw new ClaudeAgentError(failure ?? "Claude Code did not compact this conversation.");
      }
      message.pibotCompaction = { summary, preTokens: boundary.compact_metadata?.pre_tokens };
      return;
    }
    if (failure && (assistantError === "authentication_failed" || NOT_LOGGED_IN.test(failure))) {
      message.pibotIssue = "signIn";
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

/** The `claude-subscription` provider: Anthropic's catalog, served through Claude Code. */
export function claudeAgentProvider(options: ClaudeAgentOptions): Provider {
  const agent = new ClaudeAgentStream(new ClaudeAgentRuntime(options));
  const stream = (model: Model<Api>, context: { messages: Message[] }, request?: object) =>
    agent.stream(model, context, request as Record<string, unknown>);
  return createProvider({
    id: CLAUDE_SUBSCRIPTION_PROVIDER,
    name: "Claude (Claude Agent SDK)",
    baseUrl: CLAUDE_AGENT_BASE_URL,
    auth: {
      // The host API supplies the credential: the machine's native Claude profile (no token
      // material), or an API key. Sign-in belongs to Woven settings.
      apiKey: {
        name: "Claude (Woven connection)",
        resolve: async (input: { credential?: { key?: string } }) =>
          input.credential?.key
            ? { auth: { apiKey: input.credential.key }, source: "Woven connection" }
            : undefined,
      },
    },
    models: anthropicProvider()
      .getModels()
      .map((model) => ({
        ...model,
        api: CLAUDE_AGENT_API,
        provider: CLAUDE_SUBSCRIPTION_PROVIDER,
        baseUrl: CLAUDE_AGENT_BASE_URL,
      })),
    api: { stream, streamSimple: stream },
  } as unknown as Parameters<typeof createProvider>[0]);
}
