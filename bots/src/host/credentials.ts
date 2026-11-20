import type {
  AuthOperationOptions,
  Credential,
  CredentialInfo,
  CredentialStore,
} from "@earendil-works/pi-ai";
import type { HostCredential } from "../protocol.ts";
import type { HostCall } from "./channel.ts";

/** Woven's provider connection ids, the same ids Pi Durable uses. */
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

/**
 * Claude Code's own sign-in, as pi-ai sees it: an api-key credential with this marker, which the
 * Claude provider runs with Claude's default configuration (claude/provider.ts).
 */
export const NATIVE_KEY = "woven-native";

/** A missing or failed answer is asked again after this long. */
const REFETCH_AFTER_MS = 2_000;
/** A credential the server gave is asked for again after this long (it may have been removed). */
const KEEP_MS = 60_000;
/** An OAuth credential this close to expiring is asked for again (the server may have renewed it). */
const EXPIRY_MARGIN_MS = 60_000;

/** The server's form to pi-ai's. */
export function fromWire(value: HostCredential | null | undefined): Credential | undefined {
  if (value?.type === "apiKey" && typeof value.key === "string" && value.key) {
    return { type: "api_key", key: value.key };
  }
  if (value?.type === "oauth" && typeof value.access === "string") {
    const { type: _type, ...rest } = value;
    return { ...rest, type: "oauth" } as Credential;
  }
  if (value?.type === "native") return { type: "api_key", key: NATIVE_KEY };
  return undefined;
}

/** pi-ai's form to the server's. */
export function toWire(credential: Credential): HostCredential {
  if (credential.type === "api_key") {
    return credential.key === NATIVE_KEY ? { type: "native" } : { type: "apiKey", key: credential.key ?? "" };
  }
  return { ...credential, type: "oauth" } as Extract<HostCredential, { type: "oauth" }>;
}

const expiresSoon = (credential: Credential | undefined) =>
  credential?.type === "oauth" && Number(credential.expires) <= Date.now() + EXPIRY_MARGIN_MS;

type Known = { readonly credential: Credential | undefined; readonly at: number };

/**
 * pi-ai's credential store, backed by the server (as Pi Durable's is): credentials are held in
 * memory only, asked for at first need, again a minute later, and again soon when one is missing
 * or about to expire. A subscription pi-ai renews is reported back with `credentials.update` so
 * the server stores it.
 */
export class ServerCredentials implements CredentialStore {
  readonly #call: HostCall;
  readonly #values = new Map<string, Known>();
  readonly #fetching = new Map<string, Promise<Credential | undefined>>();
  readonly #chains = new Map<string, Promise<unknown>>();

  constructor(call: HostCall) {
    this.#call = call;
  }

  /** Forget what the server said (a connection changed in Woven settings). */
  invalidate(provider?: string): void {
    if (provider) this.#values.delete(provider);
    else this.#values.clear();
  }

  async read(providerId: string, _options?: AuthOperationOptions): Promise<Credential | undefined> {
    const known = this.#values.get(providerId);
    const keep = known?.credential && !expiresSoon(known.credential) ? KEEP_MS : REFETCH_AFTER_MS;
    if (known && Date.now() - known.at <= keep) return structuredClone(known.credential);
    return structuredClone(await this.#fetch(providerId));
  }

  #fetch(providerId: string): Promise<Credential | undefined> {
    const running = this.#fetching.get(providerId);
    if (running) return running;
    const work = this.#call("credentials", { provider: providerId })
      .then(
        (reply) => fromWire(reply.credential),
        // No server, or it failed: not connected, for a moment.
        () => undefined,
      )
      .then((credential) => {
        this.#values.set(providerId, { credential, at: Date.now() });
        return credential;
      })
      .finally(() => this.#fetching.delete(providerId));
    this.#fetching.set(providerId, work);
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

  /** pi-ai's renewal path: one change at a time per provider; a changed credential goes to the server. */
  modify(
    providerId: string,
    fn: (current: Credential | undefined) => Promise<Credential | undefined>,
    _options?: AuthOperationOptions,
  ): Promise<Credential | undefined> {
    const run = async () => {
      const before = await this.read(providerId);
      const next = await fn(before);
      if (next === undefined) return before;
      this.#values.set(providerId, { credential: structuredClone(next), at: Date.now() });
      if (JSON.stringify(next) !== JSON.stringify(before)) {
        await this.#call("credentials.update", { provider: providerId, credential: toWire(next) });
      }
      return structuredClone(next);
    };
    const result = (this.#chains.get(providerId) ?? Promise.resolve()).then(run, run);
    this.#chains.set(providerId, result.catch(() => {}));
    return result;
  }

  async delete(providerId: string): Promise<void> {
    this.#values.delete(providerId);
  }
}
