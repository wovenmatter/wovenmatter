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
 * request, the same checks, the same four hours, and no fetch at launch or on a timer (a start
 * reads a provider's catalog only when a profile names a model of it that is not known).
 *
 * The live catalog adds to the list pi-ai ships and wins where both name a model, as in Pi's own
 * coding agent. It never takes a shipped model away: a bot keeps running on the model it has.
 */

/** How long a fetched catalog counts as current. */
export const CATALOG_REFRESH_MS = 4 * 60 * 60 * 1000;
/** How long a catalog that could not be read is left alone before the next read tries again. */
export const CATALOG_RETRY_MS = 5 * 60 * 1000;
const CATALOG_URL = "https://pi.dev";
const BYTE_LIMIT = 4 * 1024 * 1024;
const MODEL_LIMIT = 4096;
/** How long one catalog request may take. Readers wait for it, so it is short. */
export const CATALOG_REQUEST_MS = 8_000;

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
    "google-generative-ai": "https://opencode.ai/inference/go/google/v1beta",
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
 * name. Dates (2024-08-06, 12-2024, 20251001, 2508) and sizes (70b, 8x22b, 32k) are not versions, and an
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
        .matchAll(/(?<!\d)\d{1,3}(?![\dbBkK]|x\d)/gu),
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
  /** How long one catalog request may take (tests shorten it). */
  readonly requestMs?: number;
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

export type LiveCatalog = {
  /** `provider`, listing Pi's live catalog on top of what it ships. */
  readonly provider: Provider;
  /** Show a stored catalog. Reads no credential and nothing from the network. */
  readonly restore: (stored: Readonly<ModelsStoreEntry> | undefined) => void;
};

/**
 * `provider` with Pi's live catalog on top of its shipped list: a live model is added, and wins
 * over a shipped model of the same id; a shipped model the catalog does not name stays. (A catalog
 * stored by another Pi version only adds models: there the shipped list is the newer word.) Until a
 * catalog has been loaded (from the store, or fetched) it lists what pi-ai ships, so a machine
 * that is offline still has models. `Models.refresh()` drives it: every call restores the stored
 * catalog, and one made with network access fetches a new one when the stored one is older than
 * four hours. A catalog that could not be read is tried again after five minutes, not on every
 * read.
 */
export function liveCatalog(provider: Provider, options: LiveCatalogOptions = {}): LiveCatalog {
  const source = options.source ?? provider.id;
  const adapt = options.adapt ?? ((model: Model<Api>) => ({ ...model, provider: provider.id }));
  const fetcher = options.fetch ?? globalThis.fetch;
  const now = options.now ?? Date.now;
  let live: readonly Model<Api>[] | undefined;
  let merged: { readonly chat: readonly AnyModel[]; readonly all: readonly AnyModel[] } | undefined;
  /** The live list only fills gaps: it names models the shipped list lacks, and wins nowhere. */
  let fills = false;
  let failedAt: number | undefined;
  const show = (models: readonly Model<Api>[] | undefined, how: { readonly fills: boolean }) => {
    if (!models) return;
    live = models;
    fills = how.fills;
    merged = undefined;
  };
  /**
   * A stored catalog with no time checked was saved for another Pi version (FileModelsStore): the
   * list this version ships is the better word on a model both name.
   */
  const stale = (stored: Readonly<ModelsStoreEntry> | undefined) => stored?.checkedAt === undefined;
  /** The shipped list with the live one over it. The shipped list does not change while running. */
  const listed = () => {
    if (!live) return undefined;
    if (!merged) {
      const over = (shipped: readonly AnyModel[]) => {
        const byKey = new Map<string, AnyModel>();
        const ours = live as readonly AnyModel[];
        for (const model of fills ? [...ours, ...shipped] : [...shipped, ...ours]) {
          byKey.set(`${(model as { type?: string }).type ?? "chat"}\0${model.id}`, model);
        }
        return [...byKey.values()];
      };
      merged = {
        chat: over(provider.getModels() as readonly AnyModel[]),
        all: over((provider.getAllModels?.() ?? provider.getModels()) as readonly AnyModel[]),
      };
    }
    return merged;
  };
  /** Stored entries are checked like fetched ones: a file on disk is no more trusted. */
  const checked = (stored: Readonly<ModelsStoreEntry> | undefined) => {
    if (!stored?.models.length) return undefined;
    try {
      return parseCatalog(stored.models, source).map(adapt);
    } catch {
      return undefined;
    }
  };
  const fetchCatalog = async (
    context: RefreshModelsContext,
    stored: Readonly<ModelsStoreEntry> | undefined,
    restored: readonly Model<Api>[] | undefined,
  ) => {
    const url = new URL(`/api/models/providers/${encodeURIComponent(source)}`, options.baseUrl ?? CATALOG_URL);
    url.searchParams.set("types", "chat");
    url.searchParams.set("pi-version", PI_AI_VERSION);
    // Only revalidate a catalog that is here to keep: a 304 must never leave the list empty.
    const etag = restored ? validator(stored?.etag) : undefined;
    const timeout = AbortSignal.timeout(options.requestMs ?? CATALOG_REQUEST_MS);
    const late = (error: unknown) =>
      timeout.aborted && !context.signal.aborted ? new CatalogError("the model catalog did not answer in time") : error;
    const response = await Promise.resolve(fetcher(url, {
      headers: {
        accept: "application/json",
        "user-agent": `pi/${PI_AI_VERSION}`,
        ...(etag ? { "if-none-match": etag } : {}),
      },
      credentials: "omit",
      redirect: "error",
      signal: AbortSignal.any([context.signal, timeout]),
    })).catch((error: unknown) => {
      throw late(error);
    });
    if (response.status === 304 && etag && stored && restored) {
      await response.body?.cancel().catch(() => {});
      await context.publish({ persist: { ...stored, checkedAt: now() } });
      return;
    }
    if (response.status !== 200) {
      await response.body?.cancel().catch(() => {});
      throw new CatalogError(`the model catalog answered ${response.status}`);
    }
    const models = parseCatalog(
      await readBody(response).catch((error: unknown) => {
        throw late(error);
      }),
      source,
    );
    const lastModified = Date.parse(response.headers.get("last-modified") ?? "");
    const next = models.map(adapt);
    const update = () => show(next, { fills: false });
    try {
      await context.publish({
        // Stored as the catalog gave them, so a restore checks them the same way.
        persist: {
          models: models as readonly AnyModel[],
          checkedAt: now(),
          ...(Number.isFinite(lastModified) ? { lastModified } : {}),
          ...(validator(response.headers.get("etag")) ? { etag: response.headers.get("etag") as string } : {}),
        },
        update,
      });
    } catch (error) {
      // A catalog that could not be saved is still the current one.
      if (!context.signal.aborted) await context.publish({ update });
      throw error;
    }
  };
  const wrapped = {
    ...provider,
    getModels: () => listed()?.chat ?? provider.getModels(),
    getAllModels: () => listed()?.all ?? provider.getAllModels?.() ?? provider.getModels(),
    // The catalog comes from Pi's service, so a stale provider sign-in must not block it.
    refreshModelsAuth: "configured",
    refreshModels: async (context: RefreshModelsContext) => {
      const stored = context.stored;
      const restored = checked(stored);
      const shown = await context.publish({ update: () => show(restored, { fills: stale(stored) }) });
      if (!shown || !context.allowNetwork || context.signal.aborted) return;
      const since = (at: number | undefined) => (at === undefined ? undefined : now() - at);
      const within = (age: number | undefined, limit: number) => age !== undefined && age >= 0 && age < limit;
      if (!context.force) {
        if (restored && within(since(stored?.checkedAt), CATALOG_REFRESH_MS)) return;
        if (within(since(failedAt), CATALOG_RETRY_MS)) return;
      }
      try {
        await fetchCatalog(context, stored, restored);
        failedAt = undefined;
      } catch (error) {
        // Including a catalog that did not answer in time: the next reads don't wait for it again.
        // Not a read that was called off (another one took its place): that says nothing about it.
        if (!context.signal.aborted) failedAt = now();
        throw error;
      }
    },
  } as Provider;
  return { provider: wrapped, restore: (stored) => show(checked(stored), { fills: stale(stored) }) };
}

/** `liveCatalog(provider).provider`, for a caller that restores through `Models.refresh()`. */
export function withLiveCatalog(provider: Provider, options: LiveCatalogOptions = {}): Provider {
  return liveCatalog(provider, options).provider;
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
      const entries: unknown = saved?.models;
      if (!Array.isArray(entries) || !entries.every((entry) => entry && typeof entry === "object" && !Array.isArray(entry))) {
        return undefined;
      }
      // A catalog fetched for another Pi version still lists its models (a profile may name one
      // only it has), but only where this version ships none of that id, and it is due at once:
      // no time checked, and no validator to answer 304 to.
      if (saved.piVersion !== PI_AI_VERSION) return { models: entries };
      return {
        models: entries,
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
