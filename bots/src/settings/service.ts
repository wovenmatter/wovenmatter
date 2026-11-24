import type { CredentialStore, Models } from "@earendil-works/pi-ai";
import { parseModelRef } from "../config.ts";
import { LIMIT_LABELS, type LimitEntry } from "../limits.ts";
import { newestFirst } from "../model-catalog.ts";
import { modelAccess, modelFacts } from "../model-info.ts";
import type { AccountStatus, AccountsSummary, ModelCatalog, ProviderModels, Roles } from "../protocol.ts";
import { isReasoning, REASONING } from "../reasoning.ts";
import { ACCOUNTS, SEARCH_PROVIDERS, type SearchProviderId } from "./catalog.ts";
import type { SettingsStore } from "./store.ts";

export type { AccountStatus, ModelOption, ProviderModels, Roles } from "../protocol.ts";

export class SettingsError extends Error {}

export type SettingsOptions = {
  /** Provider connections, asked of the server. */
  readonly credentials: CredentialStore;
  readonly models: Models;
  readonly store: SettingsStore;
  /** The search provider selected in Woven settings. */
  readonly searchProvider?: () => Promise<SearchProviderId | undefined>;
  readonly modelLimit?: (ref: string) => LimitEntry | undefined;
  /** Load Pi's live model catalog before a model list is read (never throws). */
  readonly refreshModels?: () => Promise<void>;
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

  async accounts(): Promise<AccountsSummary> {
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
  async modelCatalog(): Promise<ModelCatalog> {
    const models = this.#options.models;
    await this.#options.refreshModels?.();
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
        ...(facts.input ? { input: [...facts.input] } : {}),
        ...(facts.unsupportedReasoning ? { unsupportedReasoning: [...facts.unsupportedReasoning] } : {}),
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
    // Every list of models a person or a bot reads comes from here, newest first.
    const providers = [...byProvider.values()].map((provider) => ({
      ...provider,
      models: newestFirst(provider.models),
    }));
    return { providers, roles: this.roles(), reasoningLevels: [...REASONING] };
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
      !isReasoning(roles.titlesReasoning)
    ) {
      throw new SettingsError(`unknown reasoning level "${roles.titlesReasoning}"`);
    }
    await this.#options.store.update((current) => ({
      ...current,
      titles: {
        model: roles.titles === undefined ? current.titles.model : roles.titles || undefined,
        reasoning: isReasoning(roles.titlesReasoning) ? roles.titlesReasoning : current.titles.reasoning,
      },
    }));
    return this.roles();
  }
}
