// Model facts against the installed pi-ai catalog: pure in-memory lookups (no credentials, no
// auth checks, no network).
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { openaiCodexProvider } from "@earendil-works/pi-ai/providers/openai-codex";
import { openrouterProvider } from "@earendil-works/pi-ai/providers/openrouter";
import { xaiProvider } from "@earendil-works/pi-ai/providers/xai";
import { describe, expect, it } from "vitest";
import { claudeAgentProvider } from "../src/claude/provider.ts";
import {
  catalogProvenance,
  formatPricing,
  formatRates,
  modelAccess,
  modelFacts,
  pricingSource,
  usd,
} from "../src/model-info.ts";

const find = (provider: { getModels(): readonly { id: string }[] }, id: string) =>
  // biome-ignore lint/suspicious/noExplicitAny: catalog entries are Model<Api>
  provider.getModels().find((model) => model.id === id) as any;

describe("model facts", () => {
  it("reads the installed catalog's version and date", () => {
    const provenance = catalogProvenance();
    expect(provenance.version).toMatch(/^\d+\.\d+\.\d+/);
    expect(provenance.generatedAt).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    const sol = find(openaiCodexProvider(), "gpt-6-sol");
    expect(pricingSource("openai-codex", "gpt-6-sol", sol.cost)).toBe(
      `pi-ai ${provenance.version} bundled openai-codex catalog, generated ${provenance.generatedAt}`,
    );
    // A provider serving another price for the same id is not attributed to the catalog.
    expect(pricingSource("openai-codex", "gpt-6-sol", { ...sol.cost, input: 99 })).toBe(
      "openai-codex provider's own model list (not a verified price list)",
    );
  });

  it("gives a subscription model its own provider's raw API prices, exactly as listed", () => {
    const model = find(openaiCodexProvider(), "gpt-6-sol");
    const facts = modelFacts("openai-codex/gpt-6-sol", model);
    expect(facts.pricing).toEqual({
      status: "listed",
      rates: {
        input: model.cost.input,
        output: model.cost.output,
        cacheRead: model.cost.cacheRead,
        cacheWrite: model.cost.cacheWrite,
      },
      tiers: model.cost.tiers,
      source: pricingSource("openai-codex", "gpt-6-sol", model.cost),
    });
    expect(facts).toMatchObject({
      known: true,
      contextWindow: model.contextWindow,
      maxTokens: model.maxTokens,
      input: model.input,
      reasoning: model.reasoning,
    });
    expect(modelAccess("openai-codex")).toEqual({
      kind: "subscription",
      label: "ChatGPT subscription",
    });
  });

  it("matches claude-subscription to Anthropic's entry for the same id, and says so", () => {
    const claude = find(
      claudeAgentProvider({ directory: "/tmp/pi-bot-model-info" }),
      "claude-opus-5-5",
    );
    const anthropic = find(anthropicProvider(), "claude-opus-5-5");
    const facts = modelFacts("claude-subscription/claude-opus-5-5", claude);
    expect(facts.pricing.status).toBe("listed");
    if (facts.pricing.status !== "listed") return;
    expect(facts.pricing.rates).toEqual({
      input: anthropic.cost.input,
      output: anthropic.cost.output,
      cacheRead: anthropic.cost.cacheRead,
      cacheWrite: anthropic.cost.cacheWrite,
    });
    expect(facts.pricing.source).toContain("bundled anthropic catalog");
    expect(facts.pricing.source).toContain("Anthropic API prices for the same model id");
    expect(modelAccess("claude-subscription").kind).toBe("subscription");
    expect(modelAccess("anthropic")).toEqual({ kind: "api_key", label: "Anthropic API key" });
  });

  it("never turns a $0 or missing price into free", () => {
    const router = find(openrouterProvider(), "auto");
    const zero = modelFacts("openrouter/auto", router);
    expect(zero.pricing).toEqual({
      status: "zero",
      source: pricingSource("openrouter", "auto", router.cost),
    });
    expect(zero.pricing.status === "zero" && zero.pricing.source).toContain("bundled openrouter");
    expect(formatPricing(zero.pricing)).toBe(
      "API price listed as $0 (free or unpriced; unverified)",
    );
    const missing = modelFacts("openai-codex/gpt-9-imaginary", undefined);
    expect(missing).toEqual({
      ref: "openai-codex/gpt-9-imaginary",
      known: false,
      pricing: { status: "unknown" },
    });
    expect(formatPricing(missing.pricing)).toBe("API price unknown (not in the catalog)");
    expect(
      pricingSource("my-local", "m", { input: 1, output: 1, cacheRead: 0, cacheWrite: 0 }),
    ).toBe("my-local provider's own model list (not a verified price list)");
  });

  it("knows access per provider: Woven keeps the Grok subscription and xAI key apart", () => {
    expect(find(xaiProvider(), "grok-4.7")).toBeDefined();
    expect(modelAccess("xai")).toEqual({ kind: "subscription", label: "Grok subscription" });
    expect(modelAccess("xai-api")).toEqual({ kind: "api_key", label: "xAI API key" });
    expect(modelAccess("someone-else").kind).toBe("unknown");
  });

  it("keeps tiny prices: a positive price is never shown as $0", () => {
    expect(usd(0.000001)).toBe("$0.000001");
    expect(usd(0.00000125)).toBe("$0.00000125");
    expect(usd(2.5)).toBe("$2.5");
    expect(usd(0.125)).toBe("$0.125");
    expect(usd(0.1 + 0.2)).toBe("$0.3");
    expect(usd(1500)).toBe("$1500");
    expect(usd(0)).toBe("$0");
    expect(formatRates({ input: 0.000001, output: 0.000002, cacheRead: 0, cacheWrite: 0 })).toBe(
      "$0.000001 input, $0.000002 output, $0 cache read, $0 cache write",
    );
    // Every tier is listed with its own rates; nothing assumes a tier costs more.
    expect(
      formatPricing({
        status: "listed",
        rates: { input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5 },
        tiers: [
          { inputTokensAbove: 200_000, input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1 },
          { inputTokensAbove: 1_000_000, input: 0.000001, output: 6, cacheRead: 0, cacheWrite: 0 },
        ],
        source: "s",
      }),
    ).toBe(
      "API list price per 1M tokens: $2 input, $10 output, $0.2 cache read, $2.5 cache write; above 200k input tokens: $1 input, $5 output, $0.1 cache read, $1 cache write; above 1M input tokens: $0.000001 input, $6 output, $0 cache read, $0 cache write",
    );
  });
});
