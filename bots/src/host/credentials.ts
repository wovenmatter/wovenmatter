import type {
  AuthOperationOptions,
  Credential,
  CredentialInfo,
  CredentialStore,
} from "@earendil-works/pi-ai";
import type { HostAPI, HostCredential } from "./client.ts";

/** Woven's provider connection ids, the same ids the machine's default agent uses. */
export const MODEL_PROVIDERS = [
  "openai-codex",
  "openai",
  "openrouter",
  "opencode-go",
  "xai",
  "xai-api",
  "claude-subscription",
  "anthropic",
] as const;

/** Marks a Claude native profile inside an api-key credential (see claude/provider.ts). */
export const NATIVE_PREFIX = "woven-native:";

const POSITIVE_MS = 60_000;
const NEGATIVE_MS = 15_000;
const OAUTH_MARGIN_MS = 60_000;

type Cached = { readonly credential: Credential | undefined; readonly until: number };

/** pi-ai credentials for a host credential. Native Claude becomes a marked api key. */
export function toPiCredential(value: HostCredential | null): Credential | undefined {
  if (!value) return undefined;
  if (value.type === "api_key") return { type: "api_key", key: value.key };
  if (value.type === "oauth") {
    // Access-only: an empty refresh makes pi-ai ask the store again instead of refreshing.
    return {
      type: "oauth",
      access: value.access,
      refresh: "",
      expires: value.expires,
      ...(value.accountId ? { accountId: value.accountId } : {}),
    };
  }
  return {
    type: "api_key",
    key: `${NATIVE_PREFIX}${JSON.stringify({ configDir: value.configDir, secureStorageDir: value.secureStorageDir })}`,
  };
}

/**
 * A read-only pi-ai credential store over the host API: the runtime never stores provider
 * credentials. Values are cached briefly in memory; OAuth access tokens until shortly before they
 * expire, when pi-ai's refresh path (`modify`) asks the host again.
 */
export class HostCredentialStore implements CredentialStore {
  readonly #host: Pick<HostAPI, "inferenceCredential">;
  readonly #cache = new Map<string, Cached>();
  readonly #pending = new Map<string, Promise<Credential | undefined>>();
  readonly #now: () => number;

  constructor(host: Pick<HostAPI, "inferenceCredential">, now: () => number = Date.now) {
    this.#host = host;
    this.#now = now;
  }

  /** Forget cached values (a provider connection changed in Woven settings). */
  invalidate(provider?: string): void {
    if (provider) this.#cache.delete(provider);
    else this.#cache.clear();
  }

  async read(providerId: string, _options?: AuthOperationOptions): Promise<Credential | undefined> {
    const cached = this.#cache.get(providerId);
    if (cached && cached.until > this.#now()) return cached.credential;
    return this.#fetch(providerId);
  }

  #fetch(providerId: string): Promise<Credential | undefined> {
    const running = this.#pending.get(providerId);
    if (running) return running;
    const work = (async () => {
      try {
        const { credential } = await this.#host.inferenceCredential(providerId);
        const value = toPiCredential(credential);
        const now = this.#now();
        const until =
          value?.type === "oauth"
            ? Math.max(now, value.expires - OAUTH_MARGIN_MS)
            : now + (value ? POSITIVE_MS : NEGATIVE_MS);
        this.#cache.set(providerId, { credential: value, until });
        return value;
      } catch {
        // Unreachable host: behave as not connected for a short while; never cache a failure long.
        this.#cache.set(providerId, { credential: undefined, until: this.#now() + 2_000 });
        return undefined;
      }
    })().finally(() => this.#pending.delete(providerId));
    this.#pending.set(providerId, work);
    return work;
  }

  async list(_options?: AuthOperationOptions): Promise<readonly CredentialInfo[]> {
    const found = await Promise.all(
      MODEL_PROVIDERS.map(async (providerId): Promise<CredentialInfo | undefined> => {
        const credential = await this.read(providerId);
        return credential ? { providerId, type: credential.type } : undefined;
      }),
    );
    return found.filter((entry): entry is CredentialInfo => entry !== undefined);
  }

  /**
   * pi-ai's refresh path. The host owns renewal: drop the cached value and read it again; a
   * caller's own write (a sign-in) is not supported, since sign-in belongs to Woven settings.
   */
  async modify(
    providerId: string,
    _fn: (current: Credential | undefined) => Promise<Credential | undefined>,
    _options?: AuthOperationOptions,
  ): Promise<Credential | undefined> {
    this.#cache.delete(providerId);
    return this.#fetch(providerId);
  }

  async delete(providerId: string): Promise<void> {
    this.#cache.delete(providerId);
  }
}
