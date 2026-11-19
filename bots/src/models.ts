import { tmpdir } from "node:os";
import { join } from "node:path";
import type {
  Api,
  CredentialStore,
  Model,
  ModelsStore,
  MutableModels,
  Provider,
} from "@earendil-works/pi-ai";
import { createModels } from "@earendil-works/pi-ai/models";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { openaiProvider } from "@earendil-works/pi-ai/providers/openai";
import { openaiCodexProvider } from "@earendil-works/pi-ai/providers/openai-codex";
import { opencodeGoProvider } from "@earendil-works/pi-ai/providers/opencode-go";
import { openrouterProvider } from "@earendil-works/pi-ai/providers/openrouter";
import { xaiProvider } from "@earendil-works/pi-ai/providers/xai";
import { claudeAgentModel, claudeAgentProvider } from "./claude/provider.ts";
import type { ClaudeAgentOptions } from "./claude/runtime.ts";
import type { ModelRef } from "./config.ts";
import { type LiveCatalogOptions, withLiveCatalog } from "./model-catalog.ts";

export type BotModelsOptions = {
  /** The Claude Agent SDK runtime; `directory` defaults to a per-user temp dir (app: the data dir). */
  readonly claude?: Partial<ClaudeAgentOptions>;
  /**
   * Pi's live model catalog: where fetched catalogs are kept, and (for tests) how they are
   * fetched. Without it bots list only the models pi-ai ships.
   */
  readonly catalog?: { readonly store: ModelsStore } & Pick<LiveCatalogOptions, "fetch" | "baseUrl" | "now">;
};

/**
 * Woven keeps the xAI subscription (`xai`, OAuth) and the xAI API key (`xai-api`) as separate
 * connections, as the default agent does: `xai-api` is pi-ai's xAI provider with key auth only.
 */
function xaiApiProvider(): Provider {
  const xai = xaiProvider();
  const relabel = <T extends { provider: string }>(model: T): T => ({ ...model, provider: "xai-api" });
  return {
    ...xai,
    id: "xai-api",
    name: "xAI API key",
    auth: { apiKey: xai.auth.apiKey } as Provider["auth"],
    getModels: () => xai.getModels().map(relabel),
    getAllModels: () => (xai.getAllModels?.() ?? xai.getModels()).map(relabel),
    refreshModels: undefined,
  } as Provider;
}

/**
 * pi-ai models for every bot. Request auth resolves through `credentials` (the host API: provider
 * connections in Woven settings). `claude-subscription` is Claude through the Claude Agent SDK.
 * With `catalog`, every provider lists Pi's live catalog once `refreshBotModels` has loaded it.
 */
export function createBotModels(
  credentials: CredentialStore,
  options: BotModelsOptions = {},
): MutableModels {
  const catalog = options.catalog;
  const models = createModels({ credentials, ...(catalog ? { modelsStore: catalog.store } : {}) });
  const live = (provider: Provider, more: Pick<LiveCatalogOptions, "source" | "adapt"> = {}) =>
    catalog
      ? withLiveCatalog(provider, {
          ...more,
          ...(catalog.fetch ? { fetch: catalog.fetch } : {}),
          ...(catalog.baseUrl ? { baseUrl: catalog.baseUrl } : {}),
          ...(catalog.now ? { now: catalog.now } : {}),
        })
      : provider;
  models.setProvider(live(openaiProvider()));
  models.setProvider(live(openaiCodexProvider()));
  models.setProvider(live(anthropicProvider()));
  models.setProvider(live(openrouterProvider()));
  models.setProvider(live(xaiProvider()));
  // The key-only connection and the Claude subscription read another provider's catalog.
  models.setProvider(live(xaiApiProvider(), { source: "xai" }));
  models.setProvider(live(opencodeGoProvider()));
  models.setProvider(
    live(
      claudeAgentProvider({
        ...options.claude,
        directory:
          options.claude?.directory ??
          join(tmpdir(), `woven-bots-claude-agent-${process.getuid?.() ?? "user"}`),
      }),
      { source: "anthropic", adapt: (model: Model<Api>) => claudeAgentModel(model) },
    ),
  );
  return models;
}

/**
 * Load Pi's live catalog into `models`: the stored one at once, and with `network` a newer one
 * for every signed-in provider whose stored catalog is older than four hours. Never throws: a
 * provider that could not be refreshed keeps the list it had, and is named in the result.
 */
export async function refreshBotModels(
  models: MutableModels,
  options: { readonly network?: boolean; readonly force?: boolean; readonly timeoutMs?: number } = {},
): Promise<string[]> {
  const result = await models
    .refresh({
      allowNetwork: options.network !== false,
      ...(options.force ? { force: true } : {}),
      ...(options.timeoutMs ? { signal: AbortSignal.timeout(options.timeoutMs) } : {}),
    })
    .catch((error: unknown) => ({ errors: new Map([["models", error as Error]]) }));
  return [...result.errors].map(([provider, error]) => `${provider}: ${error.message}`);
}

/** Problems with the configured roles, for startup warnings (unknown provider or model). */
export function checkModelRoles(models: MutableModels, roles: Record<string, ModelRef>): string[] {
  const problems: string[] = [];
  for (const [role, ref] of Object.entries(roles)) {
    if (!models.getProvider(ref.provider)) {
      problems.push(`models.${role}: unknown provider "${ref.provider}"`);
    } else if (!models.getModel(ref.provider, ref.modelId)) {
      problems.push(`models.${role}: provider "${ref.provider}" has no model "${ref.modelId}"`);
    }
  }
  return problems;
}
