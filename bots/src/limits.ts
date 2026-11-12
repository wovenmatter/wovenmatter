import type { Api, AssistantMessage, Model, Models } from "@earendil-works/pi-ai";
import { type ModelRef, parseModelRef } from "./config.ts";

/**
 * Main-model usage limits: classify a provider error, remember which models are out until when,
 * and say so honestly. A kind or reset time is only ever what the provider returned; when it
 * returned neither, the limit is plain `usage` (or `credits`) with no reset.
 */
export type LimitKind = "five_hour" | "weekly" | "usage" | "credits";
export type Limit = { readonly kind: LimitKind; readonly resetsAt?: number };
/** `rate`: a transient rate limit, retried as usual; never a fallback. */
export type LimitClass = Limit | { readonly kind: "rate" };

/** What a provider attached to its error message (`pibotLimit`; the Claude provider sets it). */
export type LimitCarrier = Pick<AssistantMessage, "stopReason" | "errorMessage"> & {
  pibotLimit?: LimitClass;
};

/** An HTTP error response seen by the observing fetch (relevant headers only, short body). */
export type ObservedResponse = {
  readonly status: number;
  readonly headers: Readonly<Record<string, string>>;
  readonly body: string;
};

/** Without a reset time, a limited model is tried again after this long. */
export const LIMIT_COOLDOWN_MS = 15 * 60_000;

const CREDITS =
  /insufficient[_ ]quota|insufficient[_ ](?:credits|balance|funds)|credit balance|out of credits|exceeded your current quota|spending limit|payment required|billing_error|credits_required/i;
const USAGE =
  /usage[_ .-]?limit|usage_not_included|subscription_sharing|GoUsageLimitError|FreeUsageLimitError|hit your (?:\S+ )?limit|out of usage/i;
const RATE = /rate[_ .-]?limit|too many requests|\b429\b|overloaded/i;

const WINDOW_KIND: Record<number, LimitKind> = { 300: "five_hour", 10080: "weekly" };

function number(value: unknown): number | undefined {
  const parsed =
    typeof value === "number" ? value : typeof value === "string" ? Number(value) : NaN;
  return Number.isFinite(parsed) ? parsed : undefined;
}

/** Seconds or milliseconds since the epoch, as milliseconds. */
function epoch(value: unknown): number | undefined {
  const parsed = number(value);
  if (parsed === undefined || parsed <= 0) return undefined;
  return parsed < 1e12 ? parsed * 1000 : parsed;
}

function bodyError(body: string): Record<string, unknown> | undefined {
  try {
    const parsed = JSON.parse(body) as unknown;
    if (!parsed || typeof parsed !== "object") return undefined;
    const error = (parsed as { error?: unknown }).error;
    return error && typeof error === "object"
      ? (error as Record<string, unknown>)
      : (parsed as Record<string, unknown>);
  } catch {
    return undefined;
  }
}

/** The limit window and reset the response headers name, if any. */
function fromHeaders(
  headers: Readonly<Record<string, string>>,
  now: number,
): { kind?: LimitKind; resetsAt?: number } {
  // Anthropic (Claude subscription): the claim that was exceeded and its reset.
  const claim = headers["anthropic-ratelimit-unified-representative-claim"];
  if (claim) {
    const kind: LimitKind | undefined = /five_hour|5h/.test(claim)
      ? "five_hour"
      : /seven_day|7d|week/.test(claim)
        ? "weekly"
        : undefined;
    const reset =
      epoch(headers["anthropic-ratelimit-unified-reset"]) ??
      epoch(headers[`anthropic-ratelimit-unified-${kind === "weekly" ? "7d" : "5h"}-reset`]);
    return { ...(kind ? { kind } : {}), ...(reset ? { resetsAt: reset } : {}) };
  }
  // Codex (ChatGPT subscription): whichever window is used up.
  for (const window of ["primary", "secondary"]) {
    const used = number(headers[`x-codex-${window}-used-percent`]);
    if (used === undefined || used < 100) continue;
    const minutes = number(headers[`x-codex-${window}-window-minutes`]);
    const kind = minutes !== undefined ? WINDOW_KIND[minutes] : undefined;
    const after = number(headers[`x-codex-${window}-reset-after-seconds`]);
    const reset =
      epoch(headers[`x-codex-${window}-reset-at`]) ??
      (after !== undefined ? now + after * 1000 : undefined);
    return { ...(kind ? { kind } : {}), ...(reset ? { resetsAt: reset } : {}) };
  }
  return {};
}

/** A reset the error text itself states (Codex "Try again in ~N min", Claude "…|<epoch>"). */
function fromText(text: string, now: number): number | undefined {
  const epochMatch = /resets?_?at"?\s*[:=]\s*"?(\d{10,13})|usage limit reached\|(\d{10,13})/i.exec(
    text,
  );
  if (epochMatch) return epoch(epochMatch[1] ?? epochMatch[2]);
  const minutes = /try again in ~?\s*(\d+)\s*min/i.exec(text);
  if (minutes) return now + Number(minutes[1]) * 60_000;
  return undefined;
}

/**
 * Classify a terminal provider message: a usage limit or out-of-credits (with the window and
 * reset only when the provider said so), a transient rate limit, or nothing (an ordinary error).
 */
export function classifyLimit(
  message: LimitCarrier,
  observed?: ObservedResponse,
  now = Date.now(),
): LimitClass | undefined {
  if (message.stopReason !== "error") return undefined;
  if (message.pibotLimit) return message.pibotLimit;
  const body = observed?.body ?? "";
  const text = `${message.errorMessage ?? ""}\n${body}`;
  const error = body ? bodyError(body) : undefined;
  const headers = observed?.headers ?? {};
  const hinted = fromHeaders(headers, now);
  let kind: LimitKind | undefined;
  if (observed?.status === 402 || CREDITS.test(text)) kind = "credits";
  else if (USAGE.test(text) || hinted.kind) kind = "usage";
  if (!kind) return RATE.test(text) || observed?.status === 429 ? { kind: "rate" } : undefined;
  if (kind === "usage") {
    if (hinted.kind) kind = hinted.kind;
    else if (/\b5[- ]?hour|five[_ ]hour/i.test(text)) kind = "five_hour";
    else if (/\bweekly|seven[_ ]day|7[- ]day/i.test(text)) kind = "weekly";
  }
  const inSeconds = number(error?.resets_in_seconds);
  const retryAfterMs = number(headers["retry-after-ms"]);
  const retryAfter = number(headers["retry-after"]);
  const resetsAt =
    epoch(error?.resets_at) ??
    (inSeconds !== undefined ? now + inSeconds * 1000 : undefined) ??
    hinted.resetsAt ??
    fromText(text, now) ??
    (retryAfterMs !== undefined && retryAfterMs > 0 ? now + retryAfterMs : undefined) ??
    (retryAfter !== undefined && retryAfter > 0 ? now + retryAfter * 1000 : undefined);
  return { kind, ...(resetsAt !== undefined && resetsAt > now ? { resetsAt } : {}) };
}

/** Claude Code's `rate_limit_event` info (the fields pi-bot reads). */
export type ClaudeRateLimitInfo = {
  readonly status?: string;
  readonly resetsAt?: number;
  readonly rateLimitType?: string;
  readonly errorCode?: string;
};

/** The limit behind a failed Claude Code request, from its last rate-limit event and error. */
export function claudeLimit(
  info: ClaudeRateLimitInfo | undefined,
  error: string | undefined,
  failure: string,
  now = Date.now(),
): LimitClass | undefined {
  if (info?.status === "rejected" || info?.errorCode === "credits_required") {
    const type = info.rateLimitType ?? "";
    const kind: LimitKind =
      info.errorCode === "credits_required"
        ? "credits"
        : type === "five_hour"
          ? "five_hour"
          : type.startsWith("seven_day")
            ? "weekly"
            : "usage";
    const resetsAt = epoch(info.resetsAt);
    return { kind, ...(resetsAt !== undefined && resetsAt > now ? { resetsAt } : {}) };
  }
  if (error === "billing_error") return { kind: "usage" };
  if (error === "rate_limit" || error === "overloaded") {
    const text = classifyLimit({ stopReason: "error", errorMessage: failure }, undefined, now);
    return text ?? { kind: "rate" };
  }
  return undefined;
}

/** How the UI names the account behind a provider. */
export function accountLabel(provider: string): string {
  switch (provider) {
    case "openai-codex":
      return "ChatGPT account";
    case "openai":
      return "OpenAI API key";
    case "claude-subscription":
      return "Claude account";
    case "anthropic":
      return "Anthropic API key";
    case "xai":
      return "xAI account";
    case "openrouter":
      return "OpenRouter key";
    case "opencode-go":
      return "OpenCode Go subscription";
    default:
      return `${provider} account`;
  }
}

/** Short names of the limit kinds, for notes and model descriptions. */
export const LIMIT_LABELS: Readonly<Record<LimitKind, string>> = {
  five_hour: "5-hour limit",
  weekly: "weekly limit",
  usage: "usage limit",
  credits: "out of credits",
};
const NOTE_REASON = LIMIT_LABELS;

/**
 * The note put in front of a user turn that runs on a fallback main model, so the replying model
 * says so. Stable for as long as the same fallback runs (prompt caching).
 */
export function fallbackNote(primary: string, kind: LimitKind, active: string): string {
  return `[Note: ${primary} is unavailable (${NOTE_REASON[kind]}); you are ${active}. Mention this briefly in your reply.]`;
}

const NOTE_PREFIX =
  /^\[Note: \S+ is unavailable \([^)\n]*\); you are \S+\. Mention this briefly in your reply\.\]\n\n/;

/** Whether a user turn already starts with a fallback note. */
export function hasFallbackNote(text: string): boolean {
  return NOTE_PREFIX.test(text);
}

/** A user turn's text without its fallback note (the chat shows what the user wrote). */
export function stripFallbackNote(text: string): string {
  return text.replace(NOTE_PREFIX, "");
}

/** One limited model (or, for `credits`, every model on the provider's account). */
export type LimitEntry = {
  readonly model: string;
  readonly provider: string;
  readonly account: string;
  readonly kind: LimitKind;
  /** When the provider said it resets. */
  readonly resetsAt?: number;
  /** When it is tried again: the reset, or a cooldown when the reset is unknown. */
  readonly retryAt: number;
  readonly at: number;
};

/** Where marked limits outlive a restart (`pibot_limits`; `BotRegistry` implements it). */
export type LimitStore = {
  /** Entries as stored; `load()` checks each one. */
  limits(): Promise<readonly { readonly key: string; readonly entry: unknown }[]>;
  saveLimit(key: string, entry: LimitEntry): Promise<void>;
  deleteLimit(key: string): Promise<void>;
};

export type AvailabilityOptions = {
  readonly now?: () => number;
  readonly cooldownMs?: number;
  /** Persist marked limits; `load()` reads them back after a restart. */
  readonly store?: LimitStore;
  /** A store write failed (the in-memory state is still right). */
  readonly onError?: (error: unknown) => void;
};

function isLimitEntry(value: unknown): value is LimitEntry {
  const entry = value as Partial<LimitEntry> | null;
  return (
    typeof entry === "object" &&
    entry !== null &&
    typeof entry.model === "string" &&
    typeof entry.provider === "string" &&
    typeof entry.account === "string" &&
    ["five_hour", "weekly", "usage", "credits"].includes(entry.kind as string) &&
    typeof entry.retryAt === "number" &&
    typeof entry.at === "number" &&
    (entry.resetsAt === undefined || typeof entry.resetsAt === "number")
  );
}

/**
 * Which main models are out, shared by every bot on the server. With a store, marked limits are
 * saved and `load()` restores the live ones after a restart. An entry ends at its reset, or after
 * the cooldown when the reset is unknown; then the model is tried again and a new limit marks it
 * again. New credentials for a provider clear its limits (`clear`).
 */
export class ModelAvailability {
  readonly #entries = new Map<string, LimitEntry>();
  readonly #timers = new Map<string, ReturnType<typeof setTimeout>>();
  readonly #listeners = new Set<() => void>();
  readonly #now: () => number;
  readonly #cooldownMs: number;
  readonly #store: LimitStore | undefined;
  readonly #onError: (error: unknown) => void;
  /** Store writes, in order. */
  #writes: Promise<void> = Promise.resolve();

  constructor(options: AvailabilityOptions = {}) {
    this.#now = options.now ?? Date.now;
    this.#cooldownMs = options.cooldownMs ?? LIMIT_COOLDOWN_MS;
    this.#store = options.store;
    this.#onError = options.onError ?? (() => {});
  }

  /**
   * Restore the stored limits that are still live (expired ones are deleted). Run before any bot
   * opens; returns the restored entries.
   */
  async load(): Promise<LimitEntry[]> {
    if (!this.#store) return [];
    const now = this.#now();
    const restored: LimitEntry[] = [];
    for (const { key, entry } of await this.#store.limits()) {
      if (!isLimitEntry(entry) || entry.retryAt <= now) {
        this.#write((store) => store.deleteLimit(key));
        continue;
      }
      this.#install(key, entry, now);
      restored.push(entry);
    }
    if (restored.length) this.#emit();
    await this.flushed();
    return restored;
  }

  /** Resolves once every store write so far has finished (tests, shutdown). */
  flushed(): Promise<void> {
    return this.#writes;
  }

  /** Mark `ref` (its whole provider account for `credits`) out until its reset or the cooldown. */
  mark(ref: string | ModelRef, limit: Limit): LimitEntry {
    const parsed = typeof ref === "string" ? parseModelRef(ref) : ref;
    const now = this.#now();
    const resetsAt =
      limit.resetsAt !== undefined && limit.resetsAt > now ? limit.resetsAt : undefined;
    const entry: LimitEntry = {
      model: `${parsed.provider}/${parsed.modelId}`,
      provider: parsed.provider,
      account: accountLabel(parsed.provider),
      kind: limit.kind,
      ...(resetsAt !== undefined ? { resetsAt } : {}),
      retryAt: resetsAt ?? now + this.#cooldownMs,
      at: now,
    };
    const key = limit.kind === "credits" ? `${parsed.provider}/*` : entry.model;
    this.#install(key, entry, now);
    this.#write((store) => store.saveLimit(key, entry));
    this.#emit();
    return entry;
  }

  #install(key: string, entry: LimitEntry, now: number): void {
    this.#entries.set(key, entry);
    clearTimeout(this.#timers.get(key));
    const timer = setTimeout(
      () => {
        this.#timers.delete(key);
        if (this.#entries.get(key) === entry) this.#expire(key);
      },
      Math.min(Math.max(entry.retryAt - now, 0), 2 ** 31 - 1),
    );
    timer.unref?.();
    this.#timers.set(key, timer);
  }

  #write(op: (store: LimitStore) => Promise<void>): void {
    const store = this.#store;
    if (!store) return;
    this.#writes = this.#writes.then(() => op(store)).catch(this.#onError);
  }

  /** The live limit on `ref`, if any. */
  limit(ref: string | ModelRef): LimitEntry | undefined {
    const parsed = typeof ref === "string" ? parseModelRef(ref) : ref;
    const now = this.#now();
    for (const key of [`${parsed.provider}/${parsed.modelId}`, `${parsed.provider}/*`]) {
      const entry = this.#entries.get(key);
      if (!entry) continue;
      if (entry.retryAt > now) return entry;
      this.#entries.delete(key);
      this.#write((store) => store.deleteLimit(key));
    }
    return undefined;
  }

  available(ref: string | ModelRef): boolean {
    return this.limit(ref) === undefined;
  }

  /** Forget the limits on one provider (new credentials) or all of them. */
  clear(provider?: string): void {
    let changed = false;
    for (const [key, entry] of this.#entries) {
      if (provider !== undefined && entry.provider !== provider) continue;
      this.#entries.delete(key);
      clearTimeout(this.#timers.get(key));
      this.#timers.delete(key);
      this.#write((store) => store.deleteLimit(key));
      changed = true;
    }
    if (changed) this.#emit();
  }

  /** Called when a limit is marked or ends. */
  onChange(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  close(): void {
    for (const timer of this.#timers.values()) clearTimeout(timer);
    this.#timers.clear();
    this.#listeners.clear();
  }

  #expire(key: string): void {
    this.#entries.delete(key);
    this.#write((store) => store.deleteLimit(key));
    this.#emit();
  }

  #emit(): void {
    for (const listener of this.#listeners) listener();
  }
}

type Fetch = typeof globalThis.fetch;
const KEPT_HEADERS = /^(?:retry-after(?:-ms)?|x-codex-|anthropic-ratelimit-unified)/;

/** A fetch that hands every HTTP error response (relevant headers, first 4 KB) to `seen`. */
export function observingFetch(base: Fetch, seen: (response: ObservedResponse) => void): Fetch {
  return (async (input: Parameters<Fetch>[0], init?: Parameters<Fetch>[1]) => {
    const response = await base(input, init);
    if (response.status >= 400) {
      const headers: Record<string, string> = {};
      response.headers.forEach((value, name) => {
        if (KEPT_HEADERS.test(name.toLowerCase())) headers[name.toLowerCase()] = value;
      });
      const body = await response
        .clone()
        .text()
        .catch(() => "");
      seen({ status: response.status, headers, body: body.slice(0, 4096) });
    }
    return response;
  }) as Fetch;
}

/**
 * Models whose failed requests carry their usage-limit class on the message (`pibotLimit`), read
 * from the HTTP error the provider saw; providers without HTTP (Claude) set it themselves.
 */
export function observeLimits(models: Models, fetch?: Fetch): Models {
  return new Proxy(models, {
    get(target, key, receiver) {
      const value = Reflect.get(target, key, receiver);
      if (key !== "streamSimple" && key !== "stream") return value;
      return (model: Model<Api>, input: unknown, options?: Record<string, unknown>) => {
        let observed: ObservedResponse | undefined;
        const base = (options?.fetch as Fetch | undefined) ?? fetch ?? globalThis.fetch;
        const stream = (
          value as (...args: unknown[]) => { result(): Promise<AssistantMessage> }
        ).call(target, model, input, {
          ...options,
          fetch: observingFetch(base, (response) => {
            observed = response;
          }),
        });
        const result = stream.result.bind(stream);
        stream.result = async () => {
          const message = (await result()) as AssistantMessage & LimitCarrier;
          if (message.stopReason === "error" && observed && !message.pibotLimit) {
            const found = classifyLimit(message, observed);
            if (found) message.pibotLimit = found;
          }
          return message;
        };
        return stream;
      };
    },
  });
}
