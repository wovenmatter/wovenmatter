import type { AssistantMessage } from "@earendil-works/pi-ai";

/** One model call's usage, as `bot_usage` keeps it. */
export type ModelCallUsage = {
  readonly provider: string;
  readonly model: string;
  /** When the call was made, in milliseconds. */
  readonly at: number;
  /** Input not read from or written to the cache. */
  readonly input: number;
  readonly output: number;
  readonly cacheRead: number;
  readonly cacheWrite: number;
  /** In US dollars; 0 when the provider reports none. */
  readonly cost: number;
  readonly responseId?: string;
};

const count = (value: unknown): number =>
  typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;

/** The usage of a reply from `Models`. */
export function replyUsage(reply: AssistantMessage, at = reply.timestamp ?? Date.now()): ModelCallUsage {
  const usage = reply.usage;
  return {
    provider: reply.provider,
    model: reply.model,
    at,
    input: count(usage?.input),
    output: count(usage?.output),
    cacheRead: count(usage?.cacheRead),
    cacheWrite: count(usage?.cacheWrite),
    cost: typeof usage?.cost?.total === "number" && Number.isFinite(usage.cost.total) ? usage.cost.total : 0,
    ...(reply.responseId ? { responseId: reply.responseId } : {}),
  };
}

/**
 * The usage a provider's own compaction endpoint reports: Pi's own shape, the Responses API's
 * (`input_tokens` including `input_tokens_details.cached_tokens`) or the Messages API's
 * (`input_tokens` without the cache, which has counts of its own).
 */
export function providerUsage(value: unknown, provider: string, model: string, at: number): ModelCallUsage | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const usage = value as Record<string, unknown>;
  const zero = { provider, model, at, cost: 0 };
  if ("input" in usage || "output" in usage) {
    const cost = (usage.cost as { total?: unknown } | undefined)?.total;
    return {
      ...zero,
      input: count(usage.input),
      output: count(usage.output),
      cacheRead: count(usage.cacheRead),
      cacheWrite: count(usage.cacheWrite),
      cost: typeof cost === "number" && Number.isFinite(cost) ? cost : 0,
    };
  }
  if ("cache_read_input_tokens" in usage || "cache_creation_input_tokens" in usage) {
    return {
      ...zero,
      input: count(usage.input_tokens),
      output: count(usage.output_tokens),
      cacheRead: count(usage.cache_read_input_tokens),
      cacheWrite: count(usage.cache_creation_input_tokens),
    };
  }
  const cached = count((usage.input_tokens_details as { cached_tokens?: unknown } | undefined)?.cached_tokens);
  return {
    ...zero,
    input: Math.max(0, count(usage.input_tokens) - cached),
    output: count(usage.output_tokens),
    cacheRead: cached,
    cacheWrite: 0,
  };
}
