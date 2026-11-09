import { zstdDecompressSync } from "node:zlib";
import type { Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";
import type { ClaudeSdkEvent, ClaudeSdkFrame, ClaudeSdkQuery } from "../src/claude/runtime.ts";

/**
 * Fake OpenAI, xAI, ChatGPT (Codex) and Anthropic HTTP endpoints behind an injected fetch. No
 * request leaves the process and no real key is needed: the credentials are placeholders. The
 * Claude Agent SDK is faked at its `query()` boundary: no Claude Code process starts.
 */

/** The URL a fake Claude Agent SDK `query()` is recorded under. */
export const CLAUDE_QUERY_URL = "process://claude-agent-sdk/query";

/** The text of an SDK input frame. */
export function frameText(frame: ClaudeSdkFrame | undefined): string {
  return (
    (frame?.message.content ?? [])
      // biome-ignore lint/suspicious/noExplicitAny: Anthropic content blocks.
      .filter((block: any) => block.type === "text")
      // biome-ignore lint/suspicious/noExplicitAny: Anthropic content blocks.
      .map((block: any) => block.text)
      .join("\n")
  );
}

export type RecordedRequest = {
  readonly url: string;
  readonly path: string;
  readonly headers: Headers;
  // biome-ignore lint/suspicious/noExplicitAny: provider request bodies are arbitrary JSON.
  readonly body: any;
};

export class MemoryCredentials implements CredentialStore {
  readonly #values = new Map<string, Credential>();
  constructor(values: Record<string, Credential> = {}) {
    for (const [id, value] of Object.entries(values)) this.#values.set(id, value);
  }
  async read(providerId: string) {
    return this.#values.get(providerId);
  }
  async list(): Promise<readonly CredentialInfo[]> {
    return [...this.#values].map(([providerId, value]) => ({ providerId, type: value.type }));
  }
  async modify(
    providerId: string,
    fn: (current: Credential | undefined) => Promise<Credential | undefined>,
  ) {
    const next = await fn(this.#values.get(providerId));
    if (next) this.#values.set(providerId, next);
    else this.#values.delete(providerId);
    return next;
  }
  async delete(providerId: string) {
    this.#values.delete(providerId);
  }
}

function base64url(value: string): string {
  return Buffer.from(value).toString("base64url");
}

/** Placeholder credentials for every provider; the Codex one is an unsigned fake JWT. */
export function fakeCredentials(): MemoryCredentials {
  const jwt = [
    base64url(JSON.stringify({ alg: "none" })),
    base64url(
      JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct-test" } }),
    ),
    "sig",
  ].join(".");
  return new MemoryCredentials({
    openai: { type: "api_key", key: "test-openai-key" },
    xai: { type: "api_key", key: "test-xai-key" },
    anthropic: { type: "api_key", key: "test-anthropic-key" },
    "claude-subscription": { type: "api_key", key: "sk-ant-oat01-test-claude" },
    "openai-codex": {
      type: "oauth",
      access: jwt,
      refresh: "test-refresh",
      expires: Date.now() + 365 * 86_400_000,
    },
  });
}

function sse(events: readonly Record<string, unknown>[], named = true): Response {
  const body = events
    .map(
      (event) =>
        `${named ? `event: ${String(event.type)}\n` : ""}data: ${JSON.stringify(event)}\n\n`,
    )
    .join("");
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function responsesText(model: string, text: string, id: string): Record<string, unknown>[] {
  const item = {
    id: `msg_${id}`,
    type: "message",
    role: "assistant",
    status: "completed",
    content: [],
  };
  const done = { ...item, content: [{ type: "output_text", text, annotations: [] }] };
  const usage = {
    input_tokens: 100,
    output_tokens: 10,
    total_tokens: 110,
    input_tokens_details: { cached_tokens: 0 },
  };
  return [
    {
      type: "response.created",
      response: { id: `resp_${id}`, status: "in_progress", model, output: [] },
    },
    { type: "response.output_item.added", output_index: 0, item },
    {
      type: "response.content_part.added",
      item_id: item.id,
      output_index: 0,
      content_index: 0,
      part: { type: "output_text", text: "" },
    },
    {
      type: "response.output_text.delta",
      item_id: item.id,
      output_index: 0,
      content_index: 0,
      delta: text,
    },
    {
      type: "response.output_text.done",
      item_id: item.id,
      output_index: 0,
      content_index: 0,
      text,
    },
    {
      type: "response.content_part.done",
      item_id: item.id,
      output_index: 0,
      content_index: 0,
      part: done.content[0],
    },
    { type: "response.output_item.done", output_index: 0, item: done },
    {
      type: "response.completed",
      response: { id: `resp_${id}`, status: "completed", model, output: [done], usage },
    },
  ];
}

function anthropicText(model: string, text: string, id: string): Record<string, unknown>[] {
  return [
    {
      type: "message_start",
      message: {
        id: `msg_${id}`,
        type: "message",
        role: "assistant",
        model,
        content: [],
        stop_reason: null,
        usage: { input_tokens: 100, output_tokens: 1 },
      },
    },
    { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
    { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } },
    { type: "content_block_stop", index: 0 },
    {
      type: "message_delta",
      delta: { stop_reason: "end_turn", stop_sequence: null },
      usage: { output_tokens: 10 },
    },
    { type: "message_stop" },
  ];
}

// biome-ignore lint/suspicious/noExplicitAny: provider JSON.
function lastUserText(items: any[] | undefined): string {
  for (const item of [...(items ?? [])].reverse()) {
    if (item?.role !== "user") continue;
    const content =
      typeof item.content === "string" ? [{ text: item.content }] : (item.content ?? []);
    // biome-ignore lint/suspicious/noExplicitAny: provider JSON.
    const text = content.map((part: any) => part.text ?? "").join("");
    if (text) return text;
  }
  return "";
}

export type FakeProviderOptions = {
  /** Answer native compaction with "unsupported" (404 / a 400 the provider documents). */
  readonly unsupported?: boolean;
  /** Content blocks for a fake Claude Code turn; default: text echoing the last user frame. */
  // biome-ignore lint/suspicious/noExplicitAny: Anthropic content blocks.
  readonly claudeReply?: (frames: readonly ClaudeSdkFrame[]) => any[] | undefined;
};

/** One fake for all four providers; `requests` records every call, in order. */
export class FakeProviders {
  readonly requests: RecordedRequest[] = [];
  #counter = 0;
  options: FakeProviderOptions;

  constructor(options: FakeProviderOptions = {}) {
    this.options = options;
  }

  readonly fetch: typeof globalThis.fetch = async (input, init) => {
    const request = input instanceof Request ? input : undefined;
    const url = request ? request.url : String(input);
    const headers = new Headers(init?.headers ?? request?.headers);
    let raw: Uint8Array | string | undefined;
    const source =
      init?.body ?? (request ? new Uint8Array(await request.arrayBuffer()) : undefined);
    if (typeof source === "string") raw = source;
    else if (source instanceof Uint8Array) raw = source;
    else if (source instanceof ArrayBuffer) raw = new Uint8Array(source);
    else if (source !== undefined && source !== null)
      raw = new Uint8Array(
        await new Response(source as ConstructorParameters<typeof Response>[0]).arrayBuffer(),
      );
    if (raw !== undefined && headers.get("content-encoding") === "zstd") {
      raw = zstdDecompressSync(raw as Uint8Array).toString("utf8");
    }
    const text =
      raw === undefined ? "" : typeof raw === "string" ? raw : Buffer.from(raw).toString("utf8");
    const body = text ? JSON.parse(text) : undefined;
    const path = new URL(url).pathname;
    this.requests.push({ url, path, headers, body });
    return this.#answer(url, path, body);
  };

  // biome-ignore lint/suspicious/noExplicitAny: provider JSON.
  #answer(url: string, path: string, body: any): Response {
    const id = String(++this.#counter);
    const host = new URL(url).host;
    if (path.endsWith("/responses/compact")) {
      if (this.options.unsupported)
        return json(
          { error: { message: "Not found", type: "invalid_request_error", code: null } },
          404,
        );
      return json({
        id: `cmp_${id}`,
        object: "response.compaction",
        output: [
          { type: "compaction", id: `cmp_item_${id}`, encrypted_content: `${host}-window-${id}` },
        ],
        usage: { input_tokens: 200, output_tokens: 20, total_tokens: 220 },
      });
    }
    if (host === "chatgpt.com") {
      // biome-ignore lint/suspicious/noExplicitAny: provider JSON.
      if (body?.input?.some((item: any) => item?.type === "compaction_trigger")) {
        if (this.options.unsupported) {
          return sse(
            [
              {
                type: "error",
                error: { code: "unsupported_compaction", message: "compaction is not supported" },
              },
            ],
            false,
          );
        }
        const item = {
          type: "compaction",
          id: `cmp_item_${id}`,
          encrypted_content: `codex-window-${id}`,
        };
        return sse(
          [
            {
              type: "response.created",
              response: { id: `resp_${id}`, status: "in_progress", model: body.model },
            },
            { type: "response.output_item.done", output_index: 0, item },
            {
              type: "response.completed",
              response: {
                id: `resp_${id}`,
                status: "completed",
                model: body.model,
                usage: { input_tokens: 300, output_tokens: 30 },
              },
            },
          ],
          false,
        );
      }
      return sse(responsesText(body.model, `codex: ${lastUserText(body.input)}`, id), false);
    }
    if (path.endsWith("/responses")) {
      return sse(responsesText(body.model, `${host}: ${lastUserText(body.input)}`, id));
    }
    if (path.endsWith("/v1/messages")) {
      if (body?.compaction) {
        if (this.options.unsupported) {
          return json(
            {
              type: "error",
              error: {
                type: "invalid_request_error",
                message: "compaction: Extra inputs are not permitted",
              },
            },
            400,
          );
        }
        return json({
          id: `msg_${id}`,
          type: "message",
          role: "assistant",
          model: body.model,
          content: [
            {
              type: "compaction",
              content: `summary ${id}`,
              signature: `anthropic-signature-${id}`,
            },
          ],
          stop_reason: "compaction",
          usage: { input_tokens: 400, output_tokens: 40 },
        });
      }
      return sse(anthropicText(body.model, `anthropic: ${lastUserText(body.messages)}`, id));
    }
    return json({ error: { message: `fake provider has no ${url}` } }, 404);
  }

  /**
   * A fake Claude Agent SDK `query()`: acknowledges `shouldQuery: false` replay frames with a
   * zero-turn result, answers `/compact` through the PostCompact hook and a `compact_boundary`,
   * and streams one assistant message for a live user frame. Recorded like an HTTP request.
   */
  readonly claudeQuery: ClaudeSdkQuery = ({ prompt, options }) => {
    const frames: ClaudeSdkFrame[] = [];
    // biome-ignore lint/suspicious/noExplicitAny: SDK options.
    const { env, hooks, abortController: _abort, stderr: _stderr, ...rest } = options as any;
    this.requests.push({
      url: CLAUDE_QUERY_URL,
      path: "/query",
      headers: new Headers(),
      body: { frames, options: rest, env },
    });
    const id = String(++this.#counter);
    const fake = this;
    async function* run(): AsyncGenerator<ClaudeSdkEvent> {
      for await (const frame of prompt) {
        frames.push(frame);
        if (frame.type === "assistant") continue;
        if (frame.shouldQuery === false) {
          yield { type: "result", subtype: "success", is_error: false, num_turns: 0 };
          continue;
        }
        const text = frameText(frame);
        if (text.startsWith("/compact")) {
          if (!fake.options.unsupported) {
            await hooks.PostCompact[0].hooks[0]({
              hook_event_name: "PostCompact",
              trigger: "manual",
              compact_summary: `claude-sdk summary ${id}`,
            });
            yield {
              type: "system",
              subtype: "compact_boundary",
              compact_metadata: { trigger: "manual", pre_tokens: 500 },
            };
          }
          yield { type: "result", subtype: "success", is_error: false, num_turns: 0 };
          return;
        }
        const content = fake.options.claudeReply?.(frames) ?? [
          { type: "text", text: `claude: ${text}` },
        ];
        const message = `msg_claude_${id}`;
        yield {
          type: "stream_event",
          parent_tool_use_id: null,
          event: { type: "message_start", message: { id: message } },
        };
        for (const [index, block] of content.entries()) {
          if (block.type !== "text") continue;
          yield {
            type: "stream_event",
            parent_tool_use_id: null,
            event: {
              type: "content_block_start",
              index,
              content_block: { type: "text", text: "" },
            },
          };
          yield {
            type: "stream_event",
            parent_tool_use_id: null,
            event: {
              type: "content_block_delta",
              index,
              delta: { type: "text_delta", text: block.text },
            },
          };
          yield {
            type: "stream_event",
            parent_tool_use_id: null,
            event: { type: "content_block_stop", index },
          };
        }
        for (const block of content) {
          yield {
            type: "assistant",
            parent_tool_use_id: null,
            message: {
              id: message,
              content: [block],
              stop_reason: null,
              usage: { input_tokens: 10, output_tokens: 5 },
            },
          };
        }
        const tool = content.some((block) => block.type === "tool_use");
        yield {
          type: "result",
          subtype: tool ? "error_max_turns" : "success",
          is_error: tool,
          num_turns: 1,
        };
        return;
      }
    }
    return run();
  };

  /** Requests to one path suffix, e.g. `/responses/compact`. */
  to(suffix: string): RecordedRequest[] {
    return this.requests.filter((request) => request.path.endsWith(suffix));
  }
}
