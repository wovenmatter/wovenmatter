import { mkdir, open, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  type AnyModel,
  type Api,
  type Model,
  type ModelsStore,
  type ModelsStoreEntry,
  PI_AI_VERSION,
  type Provider,
  type RefreshModelsContext,
} from "@earendil-works/pi-ai";

/**
 * Pi's live model catalog for bots. pi-ai ships each provider's models as a list inside the
 * package, which is as new as the package; Pi itself keeps current by reading the catalog its
 * service publishes (`pi.dev`). Bots do the same through pi-ai's own hook (a provider's
 * `refreshModels`, a `ModelsStore`, `Models.refresh()`), under the rules the default agent and the
 * iPhone app apply (docs/DISTRIBUTED_CLIENT_ARCHITECTURE.md, "Provider model metadata"): the same
 * request, the same checks, the same four hours, and no fetch at launch or on a timer.
 */

/** How long a fetched catalog counts as current. */
export const CATALOG_REFRESH_MS = 4 * 60 * 60 * 1000;
const CATALOG_URL = "https://pi.dev";
const BYTE_LIMIT = 4 * 1024 * 1024;
const MODEL_LIMIT = 4096;
const REQUEST_TIMEOUT_MS = 15_000;

/**
 * Where each provider's requests may go, by API. Fixed policy, never downloaded: a catalog names
 * models, it does not get to choose where a credential is sent.
 */
export const CATALOG_ENDPOINTS: Readonly<Record<string, Readonly<Record<string, string>>>> = {
  openai: { "openai-responses": "https://api.openai.com/v1" },
  "openai-codex": { "openai-codex-responses": "https://chatgpt.com/backend-api" },
  anthropic: { "anthropic-messages": "https://api.anthropic.com" },
  openrouter: {
    "openai-completions": "https://openrouter.ai/api/v1",
    "anthropic-messages": "https://openrouter.ai/api",
  },
  "opencode-go": {
    "openai-completions": "https://opencode.ai/inference/go/openai/v1",
    "openai-responses": "https://opencode.ai/inference/go/openai/v1",
    "anthropic-messages": "https://opencode.ai/inference/go/anthropic",
  },
  xai: { "openai-responses": "https://api.x.ai/v1" },
};

/** OpenRouter's routers price tokens with this sentinel; they are left out, like in Pi chats. */
const UNPRICED = -1_000_000;

export class CatalogError extends Error {
  override name = "CatalogError";
}

const invalid = () => new CatalogError("the model catalog returned invalid model metadata");

const isId = (value: unknown): value is string =>
  typeof value === "string" &&
  value.length > 0 &&
  Buffer.byteLength(value) <= 512 &&
  !/[\x00-\x1f\x7f]/u.test(value);

const isCount = (value: unknown): value is number =>
  typeof value === "number" && Number.isSafeInteger(value) && value > 0 && value <= 100_000_000;

function checkCost(value: unknown): void {
  if (typeof value === "number") {
    if (!Number.isFinite(value) || value < 0) throw invalid();
  } else if (value && typeof value === "object") {
    for (const nested of Object.values(value)) checkCost(nested);
  } else throw invalid();
}

/**
 * One catalog entry as a chat model of `source`, or a throw: its ids, sizes and prices are sane,
 * it carries no headers, and its endpoint is the one this provider's API is allowed.
 */
export function checkCatalogModel(entry: unknown, source: string): Model<Api> {
  const model = entry as Record<string, unknown> | null;
  const endpoint = typeof model?.api === "string" ? CATALOG_ENDPOINTS[source]?.[model.api] : undefined;
  if (
    !model ||
    typeof model !== "object" ||
    model.provider !== source ||
    !isId(model.id) ||
    !isId(model.name) ||
    !(model.type === undefined || model.type === "chat") ||
    endpoint === undefined ||
    model.baseUrl !== endpoint ||
    model.headers !== undefined ||
    !isCount(model.contextWindow) ||
    !isCount(model.maxTokens) ||
    typeof model.reasoning !== "boolean" ||
    !Array.isArray(model.input) ||
    !model.input.includes("text") ||
    model.input.some((kind) => kind !== "text" && kind !== "image") ||
    !model.cost ||
    typeof model.cost !== "object" ||
    Array.isArray(model.cost) ||
    Buffer.byteLength(JSON.stringify(model)) > 65_536
  ) {
    throw invalid();
  }
  checkCost(model.cost);
  return model as unknown as Model<Api>;
}

/**
 * The chat models of a catalog response for `source`. Models of other types, and of APIs this
 * provider has no allowed endpoint for, are skipped; anything malformed refuses the whole catalog.
 */
export function parseCatalog(value: unknown, source: string): Model<Api>[] {
  const entries = Array.isArray(value)
    ? value
    : value && typeof value === "object"
      ? ((value as { models?: unknown }).models ?? Object.values(value))
      : undefined;
  if (!Array.isArray(entries) || entries.length > MODEL_LIMIT) throw invalid();
  const seen = new Set<string>();
  const models: Model<Api>[] = [];
  for (const entry of entries as Record<string, unknown>[]) {
    if (!entry || typeof entry !== "object" || entry.provider !== source) throw invalid();
    if (!(entry.type === undefined || entry.type === "chat")) continue;
    const endpoint = typeof entry.api === "string" ? CATALOG_ENDPOINTS[source]?.[entry.api] : undefined;
    if (endpoint === undefined) continue;
    const cost = entry.cost as { input?: unknown; output?: unknown } | undefined;
    if (source === "openrouter" && [cost?.input, cost?.output].includes(UNPRICED)) {
      // Leaving one out must not hide a wrong destination or injected headers.
      if (entry.baseUrl !== endpoint || entry.headers !== undefined) throw invalid();
      continue;
    }
    const model = checkCatalogModel(entry, source);
    if (seen.has(model.id)) throw invalid();
    seen.add(model.id);
    models.push(model);
  }
  if (!models.length) throw new CatalogError("the model catalog listed no chat models");
  return models;
}

/**
 * `models` newest release first. The catalog carries no release dates, so the version numbers in a
 * model's id decide, highest first (gpt-6.2 before gpt-6.1 before gpt-6 before gpt-5.6), then the
 * name. Dates (2024-08-06, 12-2024, 20251001, 2508) and sizes (70b, 8x22b) are not versions, and an
 * id with no version goes last. A provider that resells other labs' models (`openai/gpt-6`) keeps
 * each lab's models together, labs by name: version numbers of different labs say nothing about
 * which is newer.
 */
export function newestFirst<T extends { readonly id: string; readonly name: string }>(
  models: readonly T[],
): T[] {
  const keyOf = (id: string) => {
    const slash = id.indexOf("/");
    const version = [
      ...id
        .slice(slash + 1)
        .replace(/\d{4}-\d{2}-\d{2}|(?<!\d)\d{2}-\d{4}(?!\d)/gu, "")
        .matchAll(/(?<!\d)\d{1,3}(?![\dbB]|x\d)/gu),
    ].map((match) => Number(match[0]));
    return { lab: slash < 0 ? "" : id.slice(0, slash), version };
  };
  return models
    .map((model) => ({ model, ...keyOf(model.id) }))
    .sort((a, b) => {
      if (a.lab !== b.lab) return a.lab < b.lab ? -1 : 1;
      for (let index = 0; index < Math.max(a.version.length, b.version.length); index++) {
        const [x, y] = [a.version[index], b.version[index]];
        // The longer version is the later one: 6.1 follows 6.
        if (x === undefined) return 1;
        if (y === undefined) return -1;
        if (x !== y) return y - x;
      }
      return (
        a.model.name.localeCompare(b.model.name, "en", { numeric: true, sensitivity: "base" }) ||
        (a.model.id < b.model.id ? -1 : a.model.id > b.model.id ? 1 : 0)
      );
    })
    .map((entry) => entry.model);
}

export type LiveCatalogOptions = {
  /**
   * The provider whose catalog this one reads, when it is not its own: `xai-api` reads `xai`, and
   * the Claude subscription reads `anthropic`.
   */
  readonly source?: string;
  /** How a catalog model becomes this provider's (its API and endpoint, for Claude). */
  readonly adapt?: (model: Model<Api>) => Model<Api>;
  readonly fetch?: typeof fetch;
  /** The catalog service (tests point it at a fake). */
  readonly baseUrl?: string;
  readonly now?: () => number;
};

async function readBody(response: Response): Promise<unknown> {
  if (Number(response.headers.get("content-length")) > BYTE_LIMIT) {
    await response.body?.cancel().catch(() => {});
    throw invalid();
  }
  const chunks: Buffer[] = [];
  let length = 0;
  for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
    length += chunk.length;
    if (length > BYTE_LIMIT) throw invalid();
    chunks.push(Buffer.from(chunk));
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw invalid();
  }
}

/** A header value worth keeping as a validator: one short line. */
const validator = (value: string | null | undefined) =>
  typeof value === "string" && value.length > 0 && value.length <= 1024 && !/[\r\n]/u.test(value)
    ? value
    : undefined;

/**
 * `provider` with Pi's live catalog in place of its bundled list. Until a catalog has been loaded
 * (from the store, or fetched) it lists what pi-ai ships, so a machine that is offline still has
 * models. `Models.refresh()` drives it: every call restores the stored catalog, and one made with
 * network access fetches a new one when the stored one is older than four hours.
 */
export function withLiveCatalog(provider: Provider, options: LiveCatalogOptions = {}): Provider {
  const source = options.source ?? provider.id;
  const adapt = options.adapt ?? ((model: Model<Api>) => ({ ...model, provider: provider.id }));
  const fetcher = options.fetch ?? globalThis.fetch;
  const now = options.now ?? Date.now;
  let live: readonly Model<Api>[] | undefined;
  /** Stored entries are checked like fetched ones: a file on disk is no more trusted. */
  const restore = (stored: Readonly<ModelsStoreEntry> | undefined) => {
    if (!stored?.models.length) return undefined;
    try {
      return parseCatalog(stored.models, source).map(adapt);
    } catch {
      return undefined;
    }
  };
  return {
    ...provider,
    getModels: () => live ?? provider.getModels(),
    getAllModels: () => live ?? provider.getAllModels?.() ?? provider.getModels(),
    // The catalog comes from Pi's service, so a stale provider sign-in must not block it.
    refreshModelsAuth: "configured",
    refreshModels: async (context: RefreshModelsContext) => {
      const stored = context.stored;
      const restored = restore(stored);
      const shown = await context.publish({
        update: () => {
          live = restored ?? live;
        },
      });
      if (!shown || !context.allowNetwork || context.signal.aborted) return;
      const checkedAt = stored?.checkedAt;
      const age = checkedAt === undefined ? undefined : now() - checkedAt;
      if (!context.force && restored && age !== undefined && age >= 0 && age < CATALOG_REFRESH_MS) {
        return;
      }
      const url = new URL(`/api/models/providers/${encodeURIComponent(source)}`, options.baseUrl ?? CATALOG_URL);
      url.searchParams.set("types", "chat");
      url.searchParams.set("pi-version", PI_AI_VERSION);
      // Only revalidate a catalog that is here to keep: a 304 must never leave the list empty.
      const etag = restored ? validator(stored?.etag) : undefined;
      const response = await fetcher(url, {
        headers: {
          accept: "application/json",
          "user-agent": `pi/${PI_AI_VERSION}`,
          ...(etag ? { "if-none-match": etag } : {}),
        },
        credentials: "omit",
        redirect: "error",
        signal: AbortSignal.any([context.signal, AbortSignal.timeout(REQUEST_TIMEOUT_MS)]),
      });
      if (context.signal.aborted) return;
      if (response.status === 304 && stored && restored) {
        await response.body?.cancel().catch(() => {});
        await context.publish({ persist: { ...stored, checkedAt: now() } });
        return;
      }
      if (response.status !== 200) {
        await response.body?.cancel().catch(() => {});
        throw new CatalogError(`the model catalog answered ${response.status}`);
      }
      const models = parseCatalog(await readBody(response), source);
      const lastModified = Date.parse(response.headers.get("last-modified") ?? "");
      const next = models.map(adapt);
      await context.publish({
        // Stored as the catalog gave them, so a restore checks them the same way.
        persist: {
          models: models as readonly AnyModel[],
          checkedAt: now(),
          ...(Number.isFinite(lastModified) ? { lastModified } : {}),
          ...(validator(response.headers.get("etag")) ? { etag: response.headers.get("etag") as string } : {}),
        },
        update: () => {
          live = next;
        },
      });
    },
  } as Provider;
}

const PROVIDER_FILE = /^[a-z0-9][a-z0-9-]{0,63}$/;

/** Catalogs on disk, one private file per provider, each bounded in size. */
export class FileModelsStore implements ModelsStore {
  readonly #directory: string;

  constructor(directory: string) {
    this.#directory = directory;
  }

  #path(providerId: string): string {
    if (!PROVIDER_FILE.test(providerId)) throw new CatalogError(`invalid provider id ${providerId}`);
    return join(this.#directory, `${providerId}.json`);
  }

  async read(providerId: string): Promise<ModelsStoreEntry | undefined> {
    let file: Awaited<ReturnType<typeof open>> | undefined;
    try {
      file = await open(this.#path(providerId), "r");
      const info = await file.stat();
      if (!info.isFile() || info.size > BYTE_LIMIT) return undefined;
      const saved = JSON.parse(await file.readFile("utf8")) as Partial<ModelsStoreEntry> & { piVersion?: string };
      // A catalog fetched for another Pi version is refetched, not reused.
      if (saved.piVersion !== PI_AI_VERSION || !Array.isArray(saved.models)) return undefined;
      return {
        models: saved.models,
        ...(typeof saved.checkedAt === "number" && Number.isFinite(saved.checkedAt) ? { checkedAt: saved.checkedAt } : {}),
        ...(typeof saved.lastModified === "number" && Number.isFinite(saved.lastModified)
          ? { lastModified: saved.lastModified }
          : {}),
        ...(validator(saved.etag) ? { etag: saved.etag as string } : {}),
      };
    } catch {
      return undefined;
    } finally {
      await file?.close();
    }
  }

  async write(providerId: string, entry: ModelsStoreEntry): Promise<void> {
    const path = this.#path(providerId);
    const text = JSON.stringify({ ...entry, piVersion: PI_AI_VERSION });
    if (Buffer.byteLength(text) > BYTE_LIMIT) throw invalid();
    await mkdir(this.#directory, { recursive: true, mode: 0o700 });
    const temporary = `${path}.${process.pid}.tmp`;
    await writeFile(temporary, text, { mode: 0o600 });
    await rename(temporary, path);
  }

  async delete(providerId: string): Promise<void> {
    await rm(this.#path(providerId), { force: true });
  }
}
