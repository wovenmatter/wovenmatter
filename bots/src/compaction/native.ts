import type {
  Api,
  FetchFunction,
  Message,
  Model,
  Models,
  UserMessage,
} from "@earendil-works/pi-ai";

/**
 * Provider-native context compaction, ported from Woven Matter's
 * `default-agent/src/provider-compaction.mjs`. Every strategy starts from the exact request pi-ai
 * would send for the covered messages (captured, never sent), so system prompt, tools, auth and
 * account headers are the provider's own. There are no retries, model changes or credential
 * fallbacks here; an `unsupported` answer lets the caller fall back to Pi Durable's summarizer.
 */

type Json = Record<string, unknown>;

/** Which native mechanism a model's provider route offers, if any. */
export type NativeStrategy =
  | "openai-responses-compact"
  | "xai-responses-compact"
  | "codex-compaction-trigger"
  | "anthropic-compaction"
  | "claude-agent-sdk-compact";

/** The opaque provider window that replaces the covered messages in later requests. */
export type NativeWindow =
  | { readonly kind: "responses"; readonly output: readonly Json[] }
  | { readonly kind: "anthropic"; readonly block: Json }
  /** Claude Code's `/compact` summary (the SDK's PostCompact `compact_summary`). */
  | { readonly kind: "summary"; readonly text: string };

/** The route a window is valid for. A window is never replayed to a different route. */
export type NativeRoute = {
  readonly provider: string;
  readonly modelId: string;
  readonly api: string;
  readonly strategy: NativeStrategy;
  readonly endpoint: string;
};

export type NativeCompaction = {
  readonly route: NativeRoute;
  readonly window: NativeWindow;
  readonly usage?: unknown;
};

export type NativeOutcome = NativeCompaction | { readonly unsupported: string };

export class NativeCompactionError extends Error {
  override name = "NativeCompactionError";
  readonly code: string;
  readonly status: number | undefined;
  constructor(code: string, message: string, status?: number) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

/** The API the Claude Agent SDK provider registers; compacted by Claude Code's `/compact`. */
export const CLAUDE_AGENT_API = "pibot-claude-agent";
const CLAUDE_AGENT_ENDPOINT = "process://claude-agent-sdk/compact";

/** A compaction summary as the user message that replaces the covered turns. */
export function summaryMessage(text: string): UserMessage {
  return {
    role: "user",
    content: [
      {
        type: "text",
        text: `The conversation history before this point was compacted into the following summary:\n\n<summary>\n${text}\n</summary>`,
      },
    ],
    timestamp: 0,
  };
}

const OPENAI_RESPONSES = "https://api.openai.com/v1/responses";
const XAI_RESPONSES = "https://api.x.ai/v1/responses";
const CODEX_RESPONSES = "https://chatgpt.com/backend-api/codex/responses";
const ANTHROPIC_MESSAGES = "https://api.anthropic.com/v1/messages";
export const ANTHROPIC_COMPACTION_BETA = "compact-2026-09-04";

/** Automatic per-provider selection. `undefined`: Pi Durable compaction is the only path. */
export function nativeStrategy(model: Model<Api>): NativeStrategy | undefined {
  if (model.api === "openai-responses" && model.provider === "openai")
    return "openai-responses-compact";
  if (model.api === "openai-responses" && model.provider.startsWith("xai"))
    return "xai-responses-compact";
  if (model.api === "openai-codex-responses") return "codex-compaction-trigger";
  if (model.api === "anthropic-messages" && model.provider === "anthropic") {
    return "anthropic-compaction";
  }
  if (model.api === CLAUDE_AGENT_API) return "claude-agent-sdk-compact";
  return undefined;
}

export type CapturedRequest = {
  readonly url: string;
  readonly headers: Headers;
  readonly payload: Json;
};

const CAPTURE_PATH = /\/(responses|messages)(\?.*)?$/;

/**
 * The request pi-ai would send for `messages`, without sending it: `onPayload` records the body
 * and a capturing fetch records URL and headers, then answers an error so nothing leaves the box.
 * Any other request (an OAuth refresh) goes to the real fetch.
 */
export async function captureRequest(
  models: Models,
  model: Model<Api>,
  messages: readonly Message[],
  options: {
    readonly fetch?: FetchFunction;
    readonly signal?: AbortSignal;
    readonly transform?: (payload: Json) => Json;
  } = {},
): Promise<CapturedRequest> {
  let payload: Json | undefined;
  let url: string | undefined;
  let headers: Headers | undefined;
  const controller = new AbortController();
  const abort = () => controller.abort(options.signal?.reason);
  options.signal?.addEventListener("abort", abort, { once: true });
  const real = options.fetch ?? globalThis.fetch;
  const capture: FetchFunction = async (input, init) => {
    const target = input instanceof Request ? input.url : String(input);
    if (
      url !== undefined ||
      !CAPTURE_PATH.test(new URL(target).pathname + new URL(target).search)
    ) {
      return real(input, init);
    }
    url = target;
    headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined));
    return new Response(JSON.stringify({ error: { message: "pi-bot request capture" } }), {
      status: 400,
      headers: { "content-type": "application/json" },
    });
  };
  try {
    const stream = models.streamSimple(
      model,
      { messages: [...messages] },
      {
        signal: controller.signal,
        fetch: capture,
        maxRetries: 0,
        transport: "sse",
        onPayload: (value) => {
          const body = structuredClone(value) as Json;
          payload = options.transform ? options.transform(body) : body;
          return undefined;
        },
      },
    );
    for await (const _event of stream) {
      // Drain: the captured request ends in an error event.
    }
  } finally {
    options.signal?.removeEventListener("abort", abort);
  }
  options.signal?.throwIfAborted();
  if (payload === undefined || url === undefined || headers === undefined) {
    throw new NativeCompactionError(
      "capture",
      "Could not prepare the provider compaction request.",
    );
  }
  return { url, headers, payload };
}

const UNSUPPORTED_CODES = new Set([
  "unsupported_model",
  "model_not_supported",
  "unsupported_compaction",
  "compaction_not_supported",
  "unsupported_endpoint",
  "not_implemented",
]);
const UNSUPPORTED_MESSAGE =
  /\b(?:compaction|compact(?:ion)? endpoint)\b.*\b(?:not supported|unsupported)\b|\b(?:does not|doesn't) support\b.*\bcompaction\b|\bmodel\b.*\b(?:not supported|unsupported)\b.*\b(?:compaction|compact)\b|\bcompaction: Extra inputs are not permitted\b/i;

/** Woven's `unsupportedResponse`: only a definite "this route has no native compaction". */
export function unsupportedResponse(
  status: number,
  body: unknown,
  allowEndpointAbsence = true,
): boolean {
  const error = (
    body as { error?: { code?: unknown; type?: unknown; message?: unknown } } | undefined
  )?.error;
  const code =
    typeof error?.code === "string"
      ? error.code
      : typeof error?.type === "string"
        ? error.type
        : undefined;
  if (
    [401, 403, 408, 429].includes(status) ||
    (code && /auth|permission|rate_limit|quota/.test(code))
  ) {
    return false;
  }
  if (code && UNSUPPORTED_CODES.has(code)) {
    return (
      (allowEndpointAbsence || !["unsupported_endpoint", "not_implemented"].includes(code)) &&
      [400, 404, 405, 422, 501].includes(status)
    );
  }
  if (
    [400, 422].includes(status) &&
    typeof error?.message === "string" &&
    UNSUPPORTED_MESSAGE.test(error.message)
  ) {
    return true;
  }
  return (
    allowEndpointAbsence &&
    [404, 405, 501].includes(status) &&
    (!code || ["not_found", "method_not_allowed", "endpoint_not_found"].includes(code))
  );
}

function requestHeaders(captured: Headers, accept: string): Headers {
  const headers = new Headers(captured);
  for (const name of ["content-length", "content-encoding", "x-stainless-retry-count"]) {
    headers.delete(name);
  }
  headers.set("content-type", "application/json");
  headers.set("accept", accept);
  return headers;
}

function endpointOf(url: string): string {
  const parsed = new URL(url);
  return `${parsed.origin}${parsed.pathname}`;
}

function isObjectArray(value: unknown): value is Json[] {
  return (
    Array.isArray(value) &&
    value.every((item) => item !== null && typeof item === "object" && !Array.isArray(item))
  );
}

async function readJson(response: Response): Promise<unknown> {
  const text = await response.text();
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

export type CompactRequest = {
  readonly models: Models;
  readonly model: Model<Api>;
  /** The covered messages: what the provider summarizes. */
  readonly messages: readonly Message[];
  /** The route's previous window, when the covered range starts at one. */
  readonly prior?: NativeWindow;
  readonly instructions?: string;
  readonly fetch?: FetchFunction;
  readonly signal?: AbortSignal;
};

/** Run the model's native compaction. `unsupported` when the route has none. */
export async function compactNative(request: CompactRequest): Promise<NativeOutcome> {
  const strategy = nativeStrategy(request.model);
  if (!strategy) return { unsupported: `no native compaction for ${request.model.api}` };
  if (strategy === "claude-agent-sdk-compact") return claudeAgentCompact(request);
  const captured = await captureRequest(request.models, request.model, request.messages, {
    ...(request.fetch ? { fetch: request.fetch } : {}),
    ...(request.signal ? { signal: request.signal } : {}),
    ...(request.prior ? { transform: (payload) => applyWindow(payload, request.prior) } : {}),
  });
  const endpoint = endpointOf(captured.url);
  const route: NativeRoute = {
    provider: request.model.provider,
    modelId: request.model.id,
    api: request.model.api,
    strategy,
    endpoint,
  };
  const fetch = request.fetch ?? globalThis.fetch;
  switch (strategy) {
    case "openai-responses-compact":
    case "xai-responses-compact": {
      const expected = strategy === "openai-responses-compact" ? OPENAI_RESPONSES : XAI_RESPONSES;
      // A custom Responses-compatible base URL is not evidence that it offers this endpoint.
      if (endpoint !== expected) return { unsupported: `no native compaction at ${endpoint}` };
      return responsesCompact(route, captured, request, fetch);
    }
    case "codex-compaction-trigger":
      if (endpoint !== CODEX_RESPONSES)
        return { unsupported: `no native compaction at ${endpoint}` };
      return codexCompact(route, captured, request, fetch);
    case "anthropic-compaction":
      if (endpoint !== ANTHROPIC_MESSAGES)
        return { unsupported: `no native compaction at ${endpoint}` };
      return anthropicCompact(route, captured, request, fetch);
    default:
      return { unsupported: `no captured-request compaction for ${strategy}` };
  }
}

/**
 * Claude Agent SDK (Woven's `compactClaudeContext`): replay the covered history into Claude Code
 * and run its own `/compact`; the window is the summary its PostCompact hook reports. Requests go
 * through `Models`, so the credential comes from the shared store like any generation.
 */
async function claudeAgentCompact(request: CompactRequest): Promise<NativeOutcome> {
  const { model } = request;
  const messages = [...request.messages];
  if (request.prior?.kind === "summary") {
    const at = messages[0]?.role === "system" ? 1 : 0;
    messages.splice(at, 0, summaryMessage(request.prior.text));
  }
  const options = {
    ...(request.signal ? { signal: request.signal } : {}),
    pibotCompact: request.instructions ? { instructions: request.instructions } : {},
  };
  const result = (await request.models.stream(model, { messages }, options).result()) as {
    stopReason: string;
    errorMessage?: string;
    usage?: unknown;
    pibotCompaction?: { summary?: string };
  };
  const summary = result.pibotCompaction?.summary;
  if (result.stopReason === "error" || result.stopReason === "aborted" || !summary) {
    throw new NativeCompactionError(
      "claude_agent_sdk",
      result.errorMessage ?? "Claude Code did not compact this conversation.",
    );
  }
  return {
    route: {
      provider: model.provider,
      modelId: model.id,
      api: model.api,
      strategy: "claude-agent-sdk-compact",
      endpoint: CLAUDE_AGENT_ENDPOINT,
    },
    window: { kind: "summary", text: summary },
    usage: result.usage,
  };
}

/** `POST /v1/responses/compact` (OpenAI and xAI): `{model, input}` → `{output: [...window]}`. */
async function responsesCompact(
  route: NativeRoute,
  captured: CapturedRequest,
  request: CompactRequest,
  fetch: FetchFunction,
): Promise<NativeOutcome> {
  const { payload } = captured;
  const body: Json = { model: payload.model, input: payload.input };
  if (typeof payload.instructions === "string") body.instructions = payload.instructions;
  const instructions = request.instructions?.trim();
  if (instructions) {
    if (route.provider === "openai") body.instructions = instructions;
    else {
      body.input = [
        ...(payload.input as Json[]),
        {
          role: "user",
          content: [{ type: "input_text", text: `Compaction instructions:\n${instructions}` }],
        },
      ];
    }
  }
  const response = await fetch(`${route.endpoint}/compact`, {
    method: "POST",
    headers: requestHeaders(captured.headers, "application/json"),
    body: JSON.stringify(body),
    redirect: "error",
    ...(request.signal ? { signal: request.signal } : {}),
  });
  const native = (await readJson(response)) as
    | { output?: unknown; usage?: unknown; model?: unknown }
    | undefined;
  if (!response.ok) {
    if (unsupportedResponse(response.status, native)) {
      return { unsupported: `${route.endpoint}/compact answered ${response.status}` };
    }
    throw new NativeCompactionError(
      [401, 403].includes(response.status) ? "auth" : "provider",
      `Native context compaction failed (${response.status}).`,
      response.status,
    );
  }
  if (!native || !isObjectArray(native.output) || native.output.length === 0) {
    throw new NativeCompactionError("invalid-response", "Native compaction returned no window.");
  }
  return {
    route,
    window: { kind: "responses", output: native.output },
    ...(native.usage !== undefined ? { usage: native.usage } : {}),
  };
}

/** Woven's `retainedCodexUsers`: Codex's native V2 replacement keeps recent user frames. */
export function retainedCodexUsers(
  input: readonly Json[],
  contextWindow: number | undefined,
): Json[] {
  let remaining = Math.min(64000, Math.max(1024, Math.floor((contextWindow ?? 256000) / 4)));
  const retained: Json[] = [];
  for (const item of [...input].reverse()) {
    if (item.role !== "user" || (item.type !== undefined && item.type !== "message")) continue;
    const size = Math.max(1, Math.ceil(JSON.stringify(item).length / 3));
    if (size > remaining) break;
    retained.push(item);
    remaining -= size;
  }
  return retained.reverse();
}

/** Parse an SSE body into its JSON data events. */
async function* sseEvents(response: Response, signal?: AbortSignal): AsyncGenerator<Json> {
  if (!response.body) throw new NativeCompactionError("invalid-response", "No response stream.");
  const decoder = new TextDecoder();
  let buffered = "";
  for await (const chunk of response.body) {
    signal?.throwIfAborted();
    buffered += decoder.decode(chunk, { stream: true });
    let index = buffered.search(/\r?\n\r?\n/);
    while (index >= 0) {
      const frame = buffered.slice(0, index);
      buffered = buffered.slice(index).replace(/^\r?\n\r?\n/, "");
      const data = frame
        .split(/\r?\n/)
        .filter((line) => line.startsWith("data:"))
        .map((line) => line.slice(5).replace(/^ /, ""))
        .join("\n");
      if (data && data !== "[DONE]") {
        let value: unknown;
        try {
          value = JSON.parse(data);
        } catch {
          throw new NativeCompactionError(
            "invalid-response",
            "Native Codex compaction sent invalid JSON.",
          );
        }
        if (value && typeof value === "object" && !Array.isArray(value)) yield value as Json;
      }
      index = buffered.search(/\r?\n\r?\n/);
    }
  }
}

/**
 * ChatGPT subscription (Codex): append `{type: "compaction_trigger"}` to a streamed Responses turn
 * and collect exactly one `compaction` item, as official Codex and Woven do.
 */
async function codexCompact(
  route: NativeRoute,
  captured: CapturedRequest,
  request: CompactRequest,
  fetch: FetchFunction,
): Promise<NativeOutcome> {
  const payload = captured.payload;
  const input = (payload.input as Json[] | undefined) ?? [];
  const instructions = request.instructions?.trim();
  const body: Json = {
    ...payload,
    instructions: [
      typeof payload.instructions === "string" && payload.instructions
        ? payload.instructions
        : "You are a helpful assistant.",
      instructions ? `Compaction instructions:\n${instructions}` : undefined,
    ]
      .filter(Boolean)
      .join("\n\n"),
    stream: true,
    store: false,
    include: ["reasoning.encrypted_content"],
    parallel_tool_calls: true,
    input: [...input, { type: "compaction_trigger" }],
  };
  const headers = requestHeaders(captured.headers, "text/event-stream");
  headers.set("OpenAI-Beta", "responses=experimental");
  const response = await fetch(route.endpoint, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
    redirect: "error",
    ...(request.signal ? { signal: request.signal } : {}),
  });
  if (!response.ok) {
    const native = await readJson(response);
    if (unsupportedResponse(response.status, native, false)) {
      return { unsupported: `Codex compaction answered ${response.status}` };
    }
    throw new NativeCompactionError(
      "provider",
      `Native Codex compaction failed (${response.status}).`,
      response.status,
    );
  }
  let item: Json | undefined;
  let count = 0;
  let completed: Json | undefined;
  let emitted = false;
  for await (const event of sseEvents(response, request.signal)) {
    const type = event.type;
    if (type === "error" || type === "response.failed" || type === "response.incomplete") {
      const failure = (event.response as Json | undefined) ?? event;
      const unsupported =
        !emitted && unsupportedResponse(400, failure.error ? failure : { error: failure }, false);
      if (unsupported) return { unsupported: "Codex compaction is not supported for this model" };
      throw new NativeCompactionError("provider", "Native Codex compaction did not complete.");
    }
    if (typeof type === "string" && type.startsWith("response.output")) emitted = true;
    if (type === "response.output_item.done") {
      const candidate = event.item as Json | undefined;
      if (
        candidate &&
        (candidate.type === "compaction" || candidate.type === "compaction_summary")
      ) {
        count++;
        if (typeof candidate.encrypted_content !== "string" || !candidate.encrypted_content) {
          throw new NativeCompactionError(
            "invalid-response",
            "Codex compaction item has no content.",
          );
        }
        item = candidate;
      }
    } else if (type === "response.completed") {
      completed = (event.response as Json | undefined) ?? {};
      break;
    }
  }
  if (!completed || count !== 1 || !item) {
    throw new NativeCompactionError(
      "invalid-response",
      "Native Codex compaction must return exactly one compaction item.",
    );
  }
  return {
    route,
    window: {
      kind: "responses",
      output: [...retainedCodexUsers(input, request.model.contextWindow), item],
    },
    ...(completed.usage !== undefined ? { usage: completed.usage } : {}),
  };
}

/**
 * Anthropic on-demand compaction (`anthropic-beta: compact-2026-09-04`): the same system and
 * tools with `compaction: {type: "summarize"}` answer one signed `compaction` block.
 */
async function anthropicCompact(
  route: NativeRoute,
  captured: CapturedRequest,
  request: CompactRequest,
  fetch: FetchFunction,
): Promise<NativeOutcome> {
  const { stream: _stream, betas: _betas, context_management: _cm, ...payload } = captured.payload;
  const instructions = request.instructions?.trim();
  const body: Json = {
    ...payload,
    compaction: { type: "summarize", ...(instructions ? { instructions } : {}) },
  };
  const headers = requestHeaders(captured.headers, "application/json");
  const betas = new Set(
    (headers.get("anthropic-beta") ?? "")
      .split(",")
      .map((beta) => beta.trim())
      .filter(Boolean),
  );
  for (const beta of (captured.payload.betas as string[] | undefined) ?? []) betas.add(beta);
  betas.add(ANTHROPIC_COMPACTION_BETA);
  headers.set("anthropic-beta", [...betas].join(","));
  const url = new URL(captured.url);
  url.searchParams.set("beta", "true");
  const response = await fetch(url.toString(), {
    method: "POST",
    headers,
    body: JSON.stringify(body),
    redirect: "error",
    ...(request.signal ? { signal: request.signal } : {}),
  });
  const native = (await readJson(response)) as
    | { content?: unknown; stop_reason?: unknown; usage?: unknown }
    | undefined;
  if (!response.ok) {
    if (unsupportedResponse(response.status, native)) {
      return { unsupported: `Anthropic compaction answered ${response.status}` };
    }
    throw new NativeCompactionError(
      "provider",
      `Anthropic compaction failed (${response.status}).`,
      response.status,
    );
  }
  const blocks = isObjectArray(native?.content) ? native.content : [];
  const block = blocks.length === 1 && blocks[0]?.type === "compaction" ? blocks[0] : undefined;
  if (native?.stop_reason !== "compaction" || !block) {
    throw new NativeCompactionError(
      "invalid-response",
      `Anthropic compaction stopped with ${String(native?.stop_reason)} and no compaction block.`,
    );
  }
  return {
    route,
    window: { kind: "anthropic", block },
    ...(native?.usage !== undefined ? { usage: native.usage } : {}),
  };
}

/**
 * Put a window in front of a request body: Responses `input` items go first, verbatim; the
 * Anthropic block becomes the first message, with the beta on the request.
 */
export function applyWindow(payload: Json, window: NativeWindow | undefined): Json {
  if (!window || window.kind === "summary") return payload;
  if (window.kind === "responses") {
    const input = Array.isArray(payload.input) ? payload.input : [];
    return { ...payload, input: [...window.output, ...input] };
  }
  const messages = Array.isArray(payload.messages) ? [...(payload.messages as Json[])] : [];
  const first = messages[0];
  if (first?.role === "assistant") {
    const content =
      typeof first.content === "string" ? [{ type: "text", text: first.content }] : first.content;
    messages[0] = { ...first, content: [window.block, ...((content as Json[]) ?? [])] };
  } else {
    messages.unshift({ role: "assistant", content: [window.block] });
  }
  const betas = new Set((payload.betas as string[] | undefined) ?? []);
  betas.add(ANTHROPIC_COMPACTION_BETA);
  return { ...payload, messages, betas: [...betas] };
}

export function sameRoute(left: NativeRoute | undefined, right: NativeRoute | undefined): boolean {
  return (
    left !== undefined &&
    right !== undefined &&
    left.provider === right.provider &&
    left.modelId === right.modelId &&
    left.api === right.api &&
    left.strategy === right.strategy
  );
}
