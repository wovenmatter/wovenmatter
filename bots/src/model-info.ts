import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { type Api, getSupportedThinkingLevels, type Model } from "@earendil-works/pi-ai";
import { ANTHROPIC_MODELS } from "@earendil-works/pi-ai/providers/anthropic.models";
import { OPENAI_MODELS } from "@earendil-works/pi-ai/providers/openai.models";
import { OPENAI_CODEX_MODELS } from "@earendil-works/pi-ai/providers/openai-codex.models";
import { OPENCODE_GO_MODELS } from "@earendil-works/pi-ai/providers/opencode-go.models";
import { OPENROUTER_MODELS } from "@earendil-works/pi-ai/providers/openrouter.models";
import { XAI_MODELS } from "@earendil-works/pi-ai/providers/xai.models";
import { REASONING } from "./config.ts";
import { LIMIT_LABELS, type LimitEntry } from "./limits.ts";
import { CATALOG_ENDPOINTS } from "./model-catalog.ts";

/**
 * What the runtime knows about a model, for the main model's subagent choices and Settings' model pool.
 * Everything comes from the model entry pi-ai serves for that exact `provider/model-id` (no
 * cross-provider matching, no guessing), plus the runtime's own knowledge of how each provider is
 * accessed. Nothing is fetched here: the entry may be one Pi's live catalog added (model-catalog.ts).
 */

export type { ModelAccess, ModelPricing, PriceRates } from "./protocol.ts";
import type { ModelAccess, ModelPricing, PriceRates } from "./protocol.ts";

export type ModelFacts = {
  readonly ref: string;
  /** The model is in the provider's catalog. */
  readonly known: boolean;
  readonly name?: string;
  readonly contextWindow?: number;
  readonly maxTokens?: number;
  /** Input modalities, e.g. ["text", "image"]. */
  readonly input?: readonly string[];
  readonly reasoning?: boolean;
  /** Reasoning levels the model lacks (a request for one runs at its nearest supported level). */
  readonly unsupportedReasoning?: readonly string[];
  readonly pricing: ModelPricing;
};

/**
 * pi-ai's bundled static catalogs (as shipped, without the live catalog) of the providers the runtime
 * registers. A price is attributed to one only when the served model's cost equals the entry for
 * the same id.
 */
const BUNDLED_CATALOG: Readonly<Record<string, Readonly<Record<string, { cost: PriceRates }>>>> = {
  openai: OPENAI_MODELS,
  "openai-codex": OPENAI_CODEX_MODELS,
  anthropic: ANTHROPIC_MODELS,
  openrouter: OPENROUTER_MODELS,
  xai: XAI_MODELS,
  "opencode-go": OPENCODE_GO_MODELS,
};

/** Providers whose list Pi's live catalog adds to (models.ts registers them that way). */
const LIVE_CATALOGS = new Set([...Object.keys(CATALOG_ENDPOINTS), "xai-api"]);

const ACCESS: Readonly<Record<string, ModelAccess>> = {
  "claude-subscription": { kind: "subscription", label: "Claude subscription" },
  "openai-codex": { kind: "subscription", label: "ChatGPT subscription" },
  "opencode-go": { kind: "subscription", label: "OpenCode Go subscription" },
  anthropic: { kind: "api_key", label: "Anthropic API key" },
  openai: { kind: "api_key", label: "OpenAI API key" },
  openrouter: { kind: "api_key", label: "OpenRouter API key" },
  "xai-api": { kind: "api_key", label: "xAI API key" },
  xai: { kind: "subscription", label: "Grok subscription" },
};

/**
 * How `provider` is accessed. xAI's account sign-in and API key share one slot, so its kind comes
 * from the stored credential's type (`authType`).
 */
export function modelAccess(provider: string, authType?: "api_key" | "oauth"): ModelAccess {
  const known = ACCESS[provider];
  if (known) return known;
  if (provider === "xai") {
    if (authType === "oauth") return { kind: "subscription", label: "Grok account" };
    if (authType === "api_key") return { kind: "api_key", label: "xAI API key" };
  }
  return { kind: "unknown", label: "unknown" };
}

export type CatalogProvenance = {
  /** Installed pi-ai version, when readable. */
  readonly version?: string;
  /** When pi-ai generated its bundled catalog (ISO date), when readable. */
  readonly generatedAt?: string;
};

let provenance: CatalogProvenance | undefined;

/** The installed pi-ai version and catalog date, read once from the package on disk. */
export function catalogProvenance(): CatalogProvenance {
  if (provenance) return provenance;
  let found: { version?: string; generatedAt?: string } = {};
  try {
    const dist = dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-ai")));
    try {
      const pkg = JSON.parse(readFileSync(join(dist, "..", "package.json"), "utf8")) as {
        version?: unknown;
      };
      if (typeof pkg.version === "string") found = { ...found, version: pkg.version };
    } catch {
      // Version unknown.
    }
    try {
      const manifest = JSON.parse(
        readFileSync(join(dist, "providers", "data", ".manifest.json"), "utf8"),
      ) as { generatedAt?: unknown };
      if (
        typeof manifest.generatedAt === "string" &&
        !Number.isNaN(Date.parse(manifest.generatedAt))
      )
        found = {
          ...found,
          generatedAt: new Date(manifest.generatedAt).toISOString().slice(0, 10),
        };
    } catch {
      // Catalog date unknown.
    }
  } catch {
    // pi-ai could not be located on disk.
  }
  provenance = found;
  return found;
}

const sameCost = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

/**
 * Where the price of `provider`/`modelId` (served with `cost`) comes from, honestly: pi-ai's
 * bundled catalog when its entry for that exact id has this very cost, else the model list the
 * entry came from (Pi's live catalog, or a provider registered some other way).
 */
export function pricingSource(provider: string, modelId: string, cost: unknown): string {
  const entry = BUNDLED_CATALOG[provider]?.[modelId];
  if (!entry || !sameCost(entry.cost, cost)) {
    // A price pi-ai did not ship came with the list the model is in: Pi's live catalog for the
    // providers that have one, else whatever registered the provider.
    return LIVE_CATALOGS.has(provider)
      ? `Pi's live model catalog for ${provider} (not a verified price list)`
      : `${provider} provider's own model list (not a verified price list)`;
  }
  const { version, generatedAt } = catalogProvenance();
  return `pi-ai${version ? ` ${version}` : ""} bundled ${provider} catalog${generatedAt ? `, generated ${generatedAt}` : ""}`;
}

const rates = (cost: PriceRates): PriceRates => ({
  input: cost.input,
  output: cost.output,
  cacheRead: cost.cacheRead,
  cacheWrite: cost.cacheWrite,
});

const valid = (cost: PriceRates | undefined): cost is PriceRates =>
  cost !== undefined &&
  [cost.input, cost.output, cost.cacheRead, cost.cacheWrite].every(
    (value) => typeof value === "number" && Number.isFinite(value) && value >= 0,
  );

/** The facts of `ref`, from `model` (the entry pi-ai serves for that exact ref, if any). */
export function modelFacts(ref: string, model: Model<Api> | undefined): ModelFacts {
  if (!model) return { ref, known: false, pricing: { status: "unknown" } };
  const cost = model.cost as (PriceRates & { tiers?: unknown }) | undefined;
  let pricing: ModelPricing = { status: "unknown" };
  if (valid(cost)) {
    const source = pricingSource(model.provider, model.id, model.cost);
    const all = [cost.input, cost.output, cost.cacheRead, cost.cacheWrite];
    if (all.every((value) => value === 0)) {
      pricing = { status: "zero", source };
    } else {
      const tiers = (Array.isArray(cost.tiers) ? cost.tiers : [])
        .filter(
          (tier): tier is PriceRates & { inputTokensAbove: number } =>
            valid(tier as PriceRates) &&
            typeof (tier as { inputTokensAbove?: unknown }).inputTokensAbove === "number",
        )
        .map((tier) => ({ ...rates(tier), inputTokensAbove: tier.inputTokensAbove }));
      pricing = {
        status: "listed",
        rates: rates(cost),
        ...(tiers.length ? { tiers } : {}),
        source,
      };
    }
  }
  const supported: readonly string[] = getSupportedThinkingLevels(model);
  const unsupported = model.reasoning
    ? REASONING.filter((level) => !supported.includes(level))
    : [];
  return {
    ref,
    known: true,
    name: model.name,
    ...(model.contextWindow > 0 ? { contextWindow: model.contextWindow } : {}),
    ...(model.maxTokens > 0 ? { maxTokens: model.maxTokens } : {}),
    input: [...model.input],
    reasoning: model.reasoning,
    ...(unsupported.length ? { unsupportedReasoning: unsupported } : {}),
    pricing,
  };
}

/**
 * `$2.5`, `$0.125`, `$0.000001`: the catalog value as given, never rounded to $0. Only float noise
 * past 10 significant digits is dropped; no exponent notation, no grouping.
 */
export const usd = (value: number) =>
  `$${Number(value.toPrecision(10)).toLocaleString("en-US", {
    useGrouping: false,
    maximumFractionDigits: 20,
  })}`;

const tokens = (value: number) =>
  value >= 1_000_000 && value % 1_000_000 === 0
    ? `${value / 1_000_000}M`
    : value >= 1000
      ? `${Math.round(value / 1000)}k`
      : String(value);

/** One line of prices, e.g. "$2 input, $10 output, $0.2 cache read, $2.5 cache write". */
export function formatRates(value: PriceRates): string {
  return `${usd(value.input)} input, ${usd(value.output)} output, ${usd(value.cacheRead)} cache read, ${usd(value.cacheWrite)} cache write`;
}

/** The pricing as one phrase for the main model. */
export function formatPricing(pricing: ModelPricing): string {
  if (pricing.status === "unknown") return "API price unknown (not in the catalog)";
  if (pricing.status === "zero") return "API price listed as $0 (free or unpriced; unverified)";
  const tiers = (pricing.tiers ?? [])
    .map((tier) => `; above ${tokens(tier.inputTokensAbove)} input tokens: ${formatRates(tier)}`)
    .join("");
  return `API list price per 1M tokens: ${formatRates(pricing.rates)}${tiers}`;
}

/** Capabilities as one phrase, e.g. "272k context, 128k max output, input text+image, reasoning". */
export function formatCapabilities(facts: ModelFacts): string {
  if (!facts.known) return "not in the model catalog";
  const parts: string[] = [];
  if (facts.contextWindow) parts.push(`${tokens(facts.contextWindow)} context`);
  if (facts.maxTokens) parts.push(`${tokens(facts.maxTokens)} max output`);
  if (facts.input?.length) parts.push(`input ${facts.input.join("+")}`);
  if (facts.reasoning) {
    parts.push(
      facts.unsupportedReasoning?.length
        ? `reasoning (not: ${facts.unsupportedReasoning.join(", ")})`
        : "reasoning",
    );
  } else if (facts.reasoning === false) {
    parts.push("no reasoning levels");
  }
  return parts.join(", ");
}

/** A marked usage limit as one phrase: only what the provider said. */
export function formatLimit(limit: LimitEntry): string {
  const reset = limit.resetsAt
    ? `resets ${new Date(limit.resetsAt).toISOString().replace(/\.\d{3}Z$/, "Z")}`
    : "reset time unknown";
  return `${LIMIT_LABELS[limit.kind]} (${limit.account}), ${reset}`;
}

