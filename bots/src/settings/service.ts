import type { CredentialStore, Models } from "@earendil-works/pi-ai";
import { parseModelRef } from "../config.ts";
import { LIMIT_LABELS, type LimitEntry, type LimitKind } from "../limits.ts";
import { type ModelAccess, type ModelPricing, modelAccess, modelFacts } from "../model-info.ts";
import { TITLE_REASONING } from "../titles.ts";
import { ACCOUNTS, SEARCH_PROVIDERS, SUGGESTED_MODELS, type SearchProviderId } from "./catalog.ts";
import type { SettingsStore } from "./store.ts";

export type AccountStatus = {
  readonly id: string;
  readonly label: string;
  readonly group: string;
  readonly method: "oauth" | "api_key";
  readonly configured: boolean;
};

export type ModelOption = {
  readonly id: string;
  readonly name: string;
  readonly reasoning: boolean;
  readonly contextWindow: number;
  readonly maxTokens?: number;
  readonly input?: readonly string[];
  readonly unsupportedReasoning?: readonly string[];
  readonly pricing: ModelPricing;
  readonly limit?: {
    readonly kind: LimitKind;
    readonly label: string;
    readonly account: string;
    readonly resetsAt?: number;
  };
};
export type ProviderModels = {
  readonly id: string;
  readonly name: string;
  readonly access: ModelAccess;
  models: ModelOption[];
};

/** The title model: the one global model setting; bots' models are in profiles. */
export type Roles = { titles: string; titlesReasoning: string };

export class SettingsError extends Error {}

export type SettingsOptions = {
  /** Provider connections, read through the host API. */
  readonly credentials: CredentialStore;
  readonly models: Models;
  readonly store: SettingsStore;
  /** The search provider selected in Woven settings. */
  readonly searchProvider?: () => Promise<SearchProviderId | undefined>;
  readonly modelLimit?: (ref: string) => LimitEntry | undefined;
};

/**
 * Backs the Bots settings the runtime still owns (model catalog, title model) and read-only
 * connection status. Sign-ins and keys belong to Woven settings; nothing here writes a secret.
 */
export class SettingsService {
  readonly #options: SettingsOptions;

  constructor(options: SettingsOptions) {
    this.#options = options;
  }

  async accounts(): Promise<{
    accounts: AccountStatus[];
    search: { provider: string; providers: AccountStatus[] };
  }> {
    const status = async (spec: (typeof ACCOUNTS)[number]): Promise<AccountStatus> => ({
      id: spec.id,
      label: spec.label,
      group: spec.group,
      method: spec.method,
      configured: (await this.#options.credentials.read(spec.provider).catch(() => undefined)) !== undefined,
    });
    return {
      accounts: await Promise.all(ACCOUNTS.map(status)),
      search: {
        provider: (await this.#options.searchProvider?.().catch(() => undefined)) ?? "exa",
        providers: await Promise.all(SEARCH_PROVIDERS.map(status)),
      },
    };
  }

  /** True once any model provider connection is available. */
  async signedIn(): Promise<boolean> {
    return (await this.accounts()).accounts.some((account) => account.configured);
  }

  /** Whether `ref` is a model of a provider with a working connection. */
  async modelAvailable(ref: string): Promise<boolean> {
    let parsed: ReturnType<typeof parseModelRef>;
    try {
      parsed = parseModelRef(ref);
    } catch {
      return false;
    }
    return (await this.#options.models.getAvailable()).some(
      (model) => model.provider === parsed.provider && model.id === parsed.modelId,
    );
  }

  /** Throws unless `ref` (`provider/modelId`) is a known model. */
  checkModel(ref: string): void {
    let parsed: ReturnType<typeof parseModelRef>;
    try {
      parsed = parseModelRef(ref);
    } catch {
      throw new SettingsError(`invalid model "${ref}": expected provider/modelId`);
    }
    if (!this.#options.models.getModel(parsed.provider, parsed.modelId)) {
      throw new SettingsError(`unknown model "${ref}"`);
    }
  }

  /** Models of providers with a working connection, and the title model. */
  async modelCatalog(): Promise<{
    providers: ProviderModels[];
    /** Connected `SUGGESTED_MODELS`, best first: what the first-run chooser offers. */
    suggested: string[];
    roles: Roles;
    reasoningLevels: readonly string[];
  }> {
    const models = this.#options.models;
    const available = await models.getAvailable();
    const byProvider = new Map<string, ProviderModels>();
    for (const model of available) {
      let entry = byProvider.get(model.provider);
      if (!entry) {
        const auth = await models.checkAuth(model.provider).catch(() => undefined);
        entry = {
          id: model.provider,
          name: models.getProvider(model.provider)?.name ?? model.provider,
          access: modelAccess(model.provider, auth?.type),
          models: [],
        };
        byProvider.set(model.provider, entry);
      }
      const ref = `${model.provider}/${model.id}`;
      const facts = modelFacts(ref, model);
      const limit = this.#options.modelLimit?.(ref);
      entry.models.push({
        id: model.id,
        name: model.name,
        reasoning: model.reasoning,
        contextWindow: model.contextWindow,
        ...(facts.maxTokens ? { maxTokens: facts.maxTokens } : {}),
        ...(facts.input ? { input: facts.input } : {}),
        ...(facts.unsupportedReasoning ? { unsupportedReasoning: facts.unsupportedReasoning } : {}),
        pricing: facts.pricing,
        ...(limit
          ? {
              limit: {
                kind: limit.kind,
                label: LIMIT_LABELS[limit.kind],
                account: limit.account,
                ...(limit.resetsAt ? { resetsAt: limit.resetsAt } : {}),
              },
            }
          : {}),
      });
    }
    const refs = new Set(available.map((model) => `${model.provider}/${model.id}`));
    return {
      providers: [...byProvider.values()],
      suggested: SUGGESTED_MODELS.filter((ref) => refs.has(ref)),
      roles: this.roles(),
      reasoningLevels: TITLE_REASONING,
    };
  }

  roles(): Roles {
    const titles = this.#options.store.current.titles;
    // "" when unset: threads are titled with the default profile's main model.
    return { titles: titles.model ?? "", titlesReasoning: titles.reasoning };
  }

  async setRoles(roles: Partial<Roles>): Promise<Roles> {
    if (roles.titles) this.checkModel(roles.titles);
    if (
      roles.titlesReasoning !== undefined &&
      !(TITLE_REASONING as readonly string[]).includes(roles.titlesReasoning)
    ) {
      throw new SettingsError(`unknown reasoning level "${roles.titlesReasoning}"`);
    }
    await this.#options.store.update((current) => ({
      ...current,
      titles: {
        model: roles.titles === undefined ? current.titles.model : roles.titles || undefined,
        reasoning: (roles.titlesReasoning ?? current.titles.reasoning) as typeof current.titles.reasoning,
      },
    }));
    return this.roles();
  }
}
