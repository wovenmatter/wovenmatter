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
import { type LiveCatalog, type LiveCatalogOptions, liveCatalog } from "./model-catalog.ts";

export type BotModelsOptions = {
  /** The Claude Agent SDK runtime; `directory` defaults to a per-user temp dir (app: the data dir). */
  readonly claude?: Partial<ClaudeAgentOptions>;
  /**
   * Pi's live model catalog: where fetched catalogs are kept, and (for tests) how they are
   * fetched. Without it bots list only the models pi-ai ships.
   */
  readonly catalog?: { readonly store: ModelsStore } & Pick<
    LiveCatalogOptions,
    "fetch" | "baseUrl" | "now" | "requestMs"
  >;
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
 * pi-ai models for every bot. Request auth resolves through `credentials` (asked of the server:
 * provider connections in Woven settings). `claude-subscription` is Claude through the Claude Agent SDK.
 * With `catalog`, every provider also lists Pi's live catalog once `refreshBotModels` has loaded it.
 */
export function createBotModels(
  credentials: CredentialStore,
  options: BotModelsOptions = {},
): MutableModels {
  const catalog = options.catalog;
  const models = createModels({ credentials, ...(catalog ? { modelsStore: catalog.store } : {}) });
  const restores = new Map<string, LiveCatalog["restore"]>();
  const live = (provider: Provider, more: Pick<LiveCatalogOptions, "source" | "adapt"> = {}) => {
    if (!catalog) return provider;
    const made = liveCatalog(provider, {
      ...more,
      ...(catalog.fetch ? { fetch: catalog.fetch } : {}),
      ...(catalog.baseUrl ? { baseUrl: catalog.baseUrl } : {}),
      ...(catalog.now ? { now: catalog.now } : {}),
      ...(catalog.requestMs ? { requestMs: catalog.requestMs } : {}),
    });
    restores.set(provider.id, made.restore);
    return made.provider;
  };
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
  if (catalog) catalogs.set(models, { store: catalog.store, restores });
  return models;
}

/** The longest a reader waits for the catalog, whatever is slow. */
const READ_LIMIT_MS = 15_000;

/** What `refreshBotModels` needs of the models `createBotModels` made with a catalog. */
const catalogs = new WeakMap<
  MutableModels,
  { readonly store: ModelsStore; readonly restores: ReadonlyMap<string, LiveCatalog["restore"]>; reading?: Promise<string[]> }
>();

/**
 * Load Pi's live catalog into `models`. Without `network`, only the stored catalogs, read
 * straight from the store: no credential is read and nothing is fetched, so a start can wait for
 * it. With `network` (the default), also a newer catalog for every signed-in provider whose stored
 * one is older than four hours. Readers that arrive while one is on its way share it, and its
 * result (the same array: report it once). Never
 * throws: a provider that could not be refreshed keeps the list it had, and is named in the result.
 */
export async function refreshBotModels(
  models: MutableModels,
  options: {
    readonly network?: boolean;
    readonly force?: boolean;
    /** Only these providers (a start reading for one profile's model). */
    readonly providers?: readonly string[];
  } = {},
): Promise<string[]> {
  const catalog = catalogs.get(models);
  if (!catalog) return [];
  const problem = (provider: string, error: unknown) =>
    `${provider}: ${error instanceof Error ? error.message : String(error)}`;
  if (options.network === false) {
    const problems: string[] = [];
    await Promise.all(
      [...catalog.restores].map(async ([provider, restore]) => {
        try {
          restore(await catalog.store.read(provider));
        } catch (error) {
          problems.push(problem(provider, error));
        }
      }),
    );
    return problems;
  }
  const read = () =>
    models
      .refresh({
        allowNetwork: true,
        ...(options.force ? { force: true } : {}),
        ...(options.providers ? { providers: [...options.providers] } : {}),
        // Each catalog request has its own, shorter limit, which is reported and remembered. This
        // one only keeps a host that does not answer for a credential from holding a reader.
        signal: AbortSignal.timeout(READ_LIMIT_MS),
      })
      .then(
        (result) => [
          ...[...result.errors].map(([provider, error]) => problem(provider, error)),
          ...(result.aborted ? ["models: reading the model catalog took too long"] : []),
        ],
        (error: unknown) => [problem("models", error)],
      );
  // pi-ai lets a second refresh supersede the first, which would then answer with the old list.
  if (options.force || options.providers) return read();
  catalog.reading ??= read().finally(() => {
    catalog.reading = undefined;
  });
  return catalog.reading;
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
