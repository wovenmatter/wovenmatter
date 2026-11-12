/**
 * Client for the runtime host API, served by the machine's Woven server at `host.url` with the
 * bearer `host.token` (docs/architecture/WOVEN_EVERYWHERE.md, Bots → Runtime host API). Every
 * call is JSON over loopback HTTP; responses are size-bounded and error bodies are never echoed.
 */

export type HostCredential =
  | { readonly type: "api_key"; readonly key: string }
  /** Access-only OAuth (renewal belongs to the host): ask again once `expires` (epoch ms) passes. */
  | {
      readonly type: "oauth";
      readonly access: string;
      readonly expires: number;
      readonly accountId?: string;
    }
  /** Claude subscription: the machine's native Claude runtime directories (no token material). */
  | { readonly type: "native"; readonly configDir: string; readonly secureStorageDir?: string };

export type InferenceCredentialResponse = {
  readonly credential: HostCredential | null;
  /** Only for `provider: "web-search"`: the search provider selected in Woven settings. */
  readonly searchProvider?: "exa" | "brave" | "firecrawl";
};

export type MirrorConversation = {
  readonly conversationId: number;
  readonly kind: "main" | "thread";
  readonly parentConversationId?: number;
  readonly forkedAt?: number;
  readonly title?: string;
  readonly pinned?: boolean;
  readonly createdAt?: string;
};

export type MirrorEntry = {
  /** Unique per bot and stable forever: the host upserts by (botID, id). */
  readonly id: number;
  readonly conversationId: number;
  readonly role: "user" | "assistant";
  readonly text: string;
  readonly error?: string;
  readonly stopped?: true;
  readonly createdAt: string;
};

export type MirrorBatch = {
  readonly bot: { readonly id: string; readonly name: string };
  readonly conversations: readonly MirrorConversation[];
  readonly entries: readonly MirrorEntry[];
};

export class HostError extends Error {
  override name = "HostError";
  readonly status: number | undefined;
  constructor(message: string, status?: number) {
    super(message);
    this.status = status;
  }
}

export interface HostAPI {
  mcpKey(botID: string, botName: string): Promise<{ endpoint: string; token: string }>;
  revokeMcpKey(botID: string): Promise<void>;
  publishPreview(botID: string, port: number, containerPort: number): Promise<{ url: string }>;
  unpublishPreview(botID: string, port: number): Promise<void>;
  inferenceCredential(provider: string): Promise<InferenceCredentialResponse>;
  mirror(botID: string, batch: MirrorBatch): Promise<void>;
}

const MAX_RESPONSE = 1024 * 1024;
const TIMEOUT_MS = 20_000;

export class HostClient implements HostAPI {
  readonly #base: URL;
  readonly #token: string;
  readonly #fetch: typeof fetch;

  constructor(url: string, token: string, fetcher: typeof fetch = fetch) {
    this.#base = new URL(url.endsWith("/") ? url : `${url}/`);
    this.#token = token;
    this.#fetch = fetcher;
  }

  async #call<T>(method: string, path: string, body?: unknown): Promise<T | undefined> {
    const url = new URL(path.replace(/^\//, ""), this.#base);
    let response: Response;
    try {
      response = await this.#fetch(url, {
        method,
        redirect: "error",
        signal: AbortSignal.timeout(TIMEOUT_MS),
        headers: {
          authorization: `Bearer ${this.#token}`,
          accept: "application/json",
          ...(body === undefined ? {} : { "content-type": "application/json" }),
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
    } catch {
      throw new HostError("The Woven server is unreachable.");
    }
    const text = await readBounded(response);
    if (!response.ok) {
      throw new HostError(`The Woven server refused ${method} ${path} (HTTP ${response.status}).`, response.status);
    }
    if (!text) return undefined;
    try {
      return JSON.parse(text) as T;
    } catch {
      throw new HostError(`The Woven server sent an unreadable reply to ${method} ${path}.`);
    }
  }

  async mcpKey(botID: string, botName: string) {
    const reply = await this.#call<{ endpoint?: unknown; token?: unknown }>(
      "POST",
      "/v1/bots-host/mcp-keys",
      { botID, botName },
    );
    if (typeof reply?.endpoint !== "string" || typeof reply.token !== "string" || !reply.token) {
      throw new HostError("The Woven server sent no MCP key.");
    }
    return { endpoint: reply.endpoint, token: reply.token };
  }

  async revokeMcpKey(botID: string): Promise<void> {
    await this.#call("DELETE", `/v1/bots-host/mcp-keys/${encodeURIComponent(botID)}`);
  }

  async publishPreview(botID: string, port: number, containerPort: number) {
    const reply = await this.#call<{ url?: unknown }>("POST", "/v1/bots-host/previews", {
      botID,
      port,
      containerPort,
    });
    if (typeof reply?.url !== "string") throw new HostError("The Woven server sent no preview URL.");
    return { url: reply.url };
  }

  async unpublishPreview(botID: string, port: number): Promise<void> {
    await this.#call("DELETE", `/v1/bots-host/previews/${encodeURIComponent(botID)}/${port}`);
  }

  async inferenceCredential(provider: string): Promise<InferenceCredentialResponse> {
    const reply = await this.#call<InferenceCredentialResponse>(
      "POST",
      "/v1/bots-host/inference-credentials",
      { provider },
    );
    return { credential: validCredential(reply?.credential), ...searchField(reply) };
  }

  async mirror(botID: string, batch: MirrorBatch): Promise<void> {
    await this.#call("POST", `/v1/bots-host/conversations/${encodeURIComponent(botID)}/entries`, batch);
  }
}

async function readBounded(response: Response): Promise<string> {
  if (!response.body) return "";
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_RESPONSE) {
      await reader.cancel().catch(() => {});
      throw new HostError("The Woven server sent too large a reply.");
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function searchField(reply: InferenceCredentialResponse | undefined) {
  const value = reply?.searchProvider;
  return value === "exa" || value === "brave" || value === "firecrawl"
    ? { searchProvider: value }
    : {};
}

function validCredential(value: unknown): HostCredential | null {
  if (!value || typeof value !== "object") return null;
  const record = value as Record<string, unknown>;
  if (record.type === "api_key" && typeof record.key === "string" && record.key) {
    return { type: "api_key", key: record.key };
  }
  if (
    record.type === "oauth" &&
    typeof record.access === "string" &&
    record.access &&
    typeof record.expires === "number" &&
    Number.isFinite(record.expires)
  ) {
    return {
      type: "oauth",
      access: record.access,
      expires: record.expires,
      ...(typeof record.accountId === "string" ? { accountId: record.accountId } : {}),
    };
  }
  if (record.type === "native" && typeof record.configDir === "string" && record.configDir) {
    return {
      type: "native",
      configDir: record.configDir,
      ...(typeof record.secureStorageDir === "string" && record.secureStorageDir
        ? { secureStorageDir: record.secureStorageDir }
        : {}),
    };
  }
  return null;
}
