import { lookup as dnsLookup } from "node:dns/promises";
import { BlockList, isIP } from "node:net";
import { Agent } from "undici";
import type { CredentialStore } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, type Extension } from "@earendil-works/pi-durable";
import { Type } from "typebox";
import { SEARCH_PROVIDERS, type SearchProviderId } from "./settings/catalog.ts";
import { run } from "./tools.ts";

/** IPv4 addresses from their parts (the public-tree scan keeps literals out of the tree). */
const ip = (...parts: number[]) => parts.join(".");

type Fetch = typeof globalThis.fetch;

/** What `web_search` and `fetch_url` reach. Keys are read from the store on every call. */
export type WebToolsOptions = {
  /** The shared credential store (search keys: `exa`, `brave`, `firecrawl`). */
  readonly credentials: Pick<CredentialStore, "read">;
  /** The search provider selected in Woven settings: tried first. */
  readonly provider: SearchProviderId | (() => Promise<SearchProviderId | undefined>);
  /** HTTP for both tools; tests inject a fake. */
  readonly fetch?: Fetch;
  /** Every address a host name resolves to; tests inject a fake. */
  readonly lookup?: (hostname: string) => Promise<readonly string[]>;
  readonly timeoutMs?: number;
};

const TIMEOUT_MS = 20_000;
const MAX_RESULTS = 10;
const SNIPPET_CHARS = 300;
const SEARCH_CHARS = 8_000;
/** Bytes read from a fetched page at most; the rest is never downloaded. */
const MAX_BYTES = 2_000_000;
const DEFAULT_PAGE_CHARS = 20_000;
const MAX_PAGE_CHARS = 100_000;
const MAX_REDIRECTS = 5;

export const NO_SEARCH_KEY =
  "Web search isn't set up: connect Exa, Brave or Firecrawl in Woven Matter Settings → Subscriptions & API Keys.";

type SearchResult = { title: string; url: string; date: string; snippet: string };

const str = (value: unknown): string => (typeof value === "string" ? value : "");
const records = (value: unknown): Record<string, unknown>[] =>
  Array.isArray(value)
    ? value.filter((item): item is Record<string, unknown> => !!item && typeof item === "object")
    : [];

const label = (id: SearchProviderId) =>
  SEARCH_PROVIDERS.find((spec) => spec.id === id)?.label ?? id;

function reason(error: unknown): string {
  if (error instanceof Error && error.name === "TimeoutError") return "timed out";
  return error instanceof Error ? error.message : String(error);
}

/** A provider HTTP error as one line; the response body is never echoed (nor the key). */
function httpError(who: string, status: number): Error {
  const why =
    status === 401 || status === 403
      ? "the API key was rejected (check it in Woven Matter Settings → Subscriptions & API Keys)"
      : status === 402
        ? "the account is out of credits or needs a paid plan"
        : status === 429
          ? "rate limited or out of quota; try again later"
          : status >= 500
            ? "the service had an error; try again later"
            : "the request was refused";
  return new Error(`${who} search failed: ${why} (HTTP ${status}).`);
}

async function requestJson(
  options: WebToolsOptions,
  who: string,
  url: string,
  init: RequestInit,
): Promise<Record<string, unknown>> {
  const fetch = options.fetch ?? globalThis.fetch;
  let response: Response;
  try {
    response = await fetch(url, {
      ...init,
      // Search credentials use custom headers, which fetch can retain across
      // cross-origin redirects. Provider endpoints must answer directly.
      redirect: "error",
      signal: AbortSignal.timeout(options.timeoutMs ?? TIMEOUT_MS),
    });
  } catch (error) {
    throw new Error(`${who} search failed: ${reason(error)}.`);
  }
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw httpError(who, response.status);
  }
  const { text, truncated } = await readCapped(response, MAX_BYTES);
  if (truncated) throw new Error(`${who} search failed: the provider response was too large.`);
  try {
    const body = JSON.parse(text) as unknown;
    return body && typeof body === "object" ? (body as Record<string, unknown>) : {};
  } catch {
    throw new Error(`${who} search failed: the response was not JSON.`);
  }
}

type ProviderSearch = (
  options: WebToolsOptions,
  key: string,
  query: string,
  count: number,
) => Promise<SearchResult[]>;

const SEARCH: Record<SearchProviderId, ProviderSearch> = {
  // https://docs.exa.ai/reference/search
  exa: async (options, key, query, count) => {
    const body = await requestJson(options, "Exa", "https://api.exa.ai/search", {
      method: "POST",
      headers: { "x-api-key": key, "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({
        query,
        numResults: count,
        contents: { text: { maxCharacters: 1000 } },
      }),
    });
    return records(body.results).map((result) => ({
      title: str(result.title),
      url: str(result.url),
      date: str(result.publishedDate).slice(0, 10),
      snippet: str(result.text),
    }));
  },
  // https://api-dashboard.search.brave.com/app/documentation/web-search/get-started
  brave: async (options, key, query, count) => {
    const url = new URL("https://api.search.brave.com/res/v1/web/search");
    url.searchParams.set("q", query);
    url.searchParams.set("count", String(count));
    const body = await requestJson(options, "Brave Search", url.href, {
      headers: { "X-Subscription-Token": key, Accept: "application/json" },
    });
    const web = body.web as Record<string, unknown> | undefined;
    return records(web?.results).map((result) => ({
      title: str(result.title),
      url: str(result.url),
      date: str(result.age) || str(result.page_age).slice(0, 10),
      snippet: str(result.description),
    }));
  },
  // https://docs.firecrawl.dev/api-reference/endpoint/search (v2: `data.web`; v1: `data`)
  firecrawl: async (options, key, query, count) => {
    const body = await requestJson(options, "Firecrawl", "https://api.firecrawl.dev/v2/search", {
      method: "POST",
      headers: {
        authorization: `Bearer ${key}`,
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify({ query, limit: count }),
    });
    const data = body.data;
    const web = Array.isArray(data) ? data : (data as Record<string, unknown> | undefined)?.web;
    return records(web).map((result) => ({
      title: str(result.title),
      url: str(result.url),
      date: "",
      snippet: str(result.description) || str(result.markdown),
    }));
  },
};

function oneLine(text: string, max: number): string {
  const flat = htmlToText(text).replace(/\s+/g, " ").trim();
  return flat.length > max ? `${flat.slice(0, max - 1).trimEnd()}…` : flat;
}

function formatResults(
  who: string,
  query: string,
  results: readonly SearchResult[],
  note: string | undefined,
): string {
  const head = note ? [note] : [];
  const found = results.filter((result) => result.url);
  if (!found.length) return [...head, `No results from ${who} for "${query}".`].join("\n");
  const lines = [...head, `Results from ${who} for "${query}":`];
  let size = lines.join("\n").length;
  for (const [index, result] of found.entries()) {
    const snippet = oneLine(result.snippet, SNIPPET_CHARS);
    const entry = [
      `${index + 1}. ${oneLine(result.title, 200) || result.url}`,
      `   ${result.url}`,
      ...(result.date ? [`   ${result.date}`] : []),
      ...(snippet ? [`   ${snippet}`] : []),
    ].join("\n");
    if (size + entry.length > SEARCH_CHARS) break;
    lines.push(entry);
    size += entry.length + 1;
  }
  return lines.join("\n");
}

/**
 * Search with `[search] provider`, or the first other search provider that has a key (the result
 * says which). No key at all: a clear setup error.
 */
export async function webSearch(
  options: WebToolsOptions,
  query: string,
  count = 5,
): Promise<string> {
  const trimmed = query.trim();
  if (!trimmed) throw new Error("query is required");
  const n = Math.min(Math.max(Math.round(count) || 5, 1), MAX_RESULTS);
  const preferred =
    (typeof options.provider === "function" ? await options.provider() : options.provider) ??
    "exa";
  const order = [
    preferred,
    ...SEARCH_PROVIDERS.map((spec) => spec.id).filter((id) => id !== preferred),
  ];
  for (const id of order) {
    const credential = await options.credentials.read(id);
    const key = credential?.type === "api_key" ? credential.key : undefined;
    if (!key) continue;
    const note =
      id === preferred
        ? undefined
        : `(${label(preferred)} has no API key, so this used ${label(id)}.)`;
    return formatResults(label(id), trimmed, await SEARCH[id](options, key, trimmed, n), note);
  }
  throw new Error(NO_SEARCH_KEY);
}

/**
 * Addresses `fetch_url` never reaches: unspecified, loopback, private, link-local, CGNAT (which
 * holds the tailnet's 100.64/10), multicast and reserved IPv4; IPv6 loopback, link-local,
 * unique-local (fc00::/7, which holds the tailnet's fd7a:115c:a1e0::/48), multicast and NAT64.
 * IPv4-mapped IPv6 addresses are checked as IPv4.
 */
const BLOCKED = new BlockList();
for (const [network, prefix] of [
  ["0.0.0.0", 8],
  [ip(10, 0, 0, 0), 8],
  [ip(100, 64, 0, 0), 10],
  [ip(127, 0, 0, 0), 8],
  [ip(169, 254, 0, 0), 16],
  [ip(172, 16, 0, 0), 12],
  [ip(192, 0, 0, 0), 24],
  [ip(192, 168, 0, 0), 16],
  [ip(198, 18, 0, 0), 15],
  [ip(224, 0, 0, 0), 4],
  [ip(240, 0, 0, 0), 4],
] as const) {
  BLOCKED.addSubnet(network, prefix, "ipv4");
}
for (const [network, prefix] of [
  ["::", 128],
  ["::1", 128],
  ["64:ff9b::", 96],
  ["fc00::", 7],
  ["fe80::", 10],
  ["ff00::", 8],
] as const) {
  BLOCKED.addSubnet(network, prefix, "ipv6");
}

export function isBlockedAddress(address: string): boolean {
  const family = isIP(address);
  if (!family) return true;
  return BLOCKED.check(address, family === 6 ? "ipv6" : "ipv4");
}

const defaultLookup = async (hostname: string): Promise<string[]> =>
  (await dnsLookup(hostname, { all: true, verbatim: true })).map((entry) => entry.address);

/** Refuse non-http(s) URLs and hosts that are, or resolve to, a blocked address. */
async function checkTarget(
  url: URL,
  options: WebToolsOptions,
): Promise<{ address: string; family: 4 | 6 }> {
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error(`only http and https URLs can be fetched, not ${url.protocol}`);
  }
  const host = url.hostname.replace(/^\[|\]$/g, "");
  let addresses: readonly string[];
  if (isIP(host)) {
    addresses = [host];
  } else {
    try {
      addresses = await (options.lookup ?? defaultLookup)(host);
    } catch {
      throw new Error(`could not resolve ${host}`);
    }
  }
  if (!addresses.length) throw new Error(`could not resolve ${host}`);
  if (addresses.some(isBlockedAddress)) {
    throw new Error(
      `refusing to fetch ${url.host}: it is a loopback, private, link-local or tailnet address`,
    );
  }
  const address = addresses[0];
  if (!address) throw new Error(`could not resolve ${host}`);
  return { address, family: isIP(address) as 4 | 6 };
}

/** Connect to the checked address while HTTP Host and TLS SNI remain the URL host. */
export function createPinnedWebAgent(address: string, family: 4 | 6): Agent {
  return new Agent({
    connect: {
      autoSelectFamily: false,
      lookup: (_hostname, _lookupOptions, callback) => callback(null, address, family),
    },
  });
}

async function readCapped(
  response: Response,
  maxBytes: number,
): Promise<{ text: string; truncated: boolean }> {
  const reader = response.body?.getReader();
  if (!reader) return { text: "", truncated: false };
  const chunks: Uint8Array[] = [];
  let size = 0;
  let truncated = false;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    size += value.byteLength;
    if (size >= maxBytes) {
      truncated = true;
      await reader.cancel().catch(() => {});
      break;
    }
  }
  const bytes = Buffer.concat(chunks).subarray(0, maxBytes);
  const charset = /charset=["']?([\w-]+)/i.exec(response.headers.get("content-type") ?? "")?.[1];
  let decoder: TextDecoder;
  try {
    decoder = new TextDecoder(charset ?? "utf-8");
  } catch {
    decoder = new TextDecoder("utf-8");
  }
  return { text: decoder.decode(bytes), truncated };
}

const ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  mdash: "—",
  ndash: "–",
  hellip: "…",
  copy: "©",
  rsquo: "’",
  lsquo: "‘",
  rdquo: "”",
  ldquo: "“",
};

function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (match, name: string) => {
    if (name.startsWith("#")) {
      const code =
        name[1] === "x" || name[1] === "X"
          ? Number.parseInt(name.slice(2), 16)
          : Number(name.slice(1));
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : match;
    }
    return ENTITIES[name.toLowerCase()] ?? match;
  });
}

const BLOCK_TAGS =
  /<\/?(?:p|div|section|article|header|footer|main|aside|nav|li|ul|ol|h[1-6]|tr|table|blockquote|pre|hr|dl|dt|dd|figure|figcaption|form)\b[^>]*>/gi;

/** Readable text from HTML: no scripts, styles or tags; block elements become line breaks. */
export function htmlToText(html: string): string {
  return decodeEntities(
    html
      .replace(/<!--[\s\S]*?-->/g, " ")
      .replace(/<(script|style|noscript|template|svg|head|iframe)\b[\s\S]*?<\/\1\s*>/gi, " ")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(BLOCK_TAGS, "\n")
      .replace(/<[^>]*>/g, " "),
  )
    .replace(/[ \t\f\v\r ]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/**
 * Fetch one http(s) page as readable text (HTML stripped; JSON and plain text as is). Every hop of
 * a redirect is checked against the blocked addresses before it is requested.
 */
export async function fetchUrl(
  options: WebToolsOptions,
  raw: string,
  maxChars = DEFAULT_PAGE_CHARS,
): Promise<string> {
  let url: URL;
  try {
    url = new URL(raw.trim());
  } catch {
    throw new Error("not a valid URL");
  }
  const limit = Math.min(Math.max(Math.round(maxChars) || DEFAULT_PAGE_CHARS, 500), MAX_PAGE_CHARS);
  const fetch = options.fetch ?? globalThis.fetch;
  const signal = AbortSignal.timeout(options.timeoutMs ?? TIMEOUT_MS);
  for (let hop = 0; ; hop++) {
    const pinned = await checkTarget(url, options);
    // The production connection must use the address that passed the check.
    // A fresh dispatcher for each hop also prevents cross-request socket reuse.
    const dispatcher = options.fetch ? undefined : createPinnedWebAgent(pinned.address, pinned.family);
    try {
      let response: Response;
      try {
        response = await fetch(url.href, {
          redirect: "manual",
          signal,
          headers: {
            "user-agent": "Pi Bot (fetch_url)",
            accept: "text/html, application/json, text/plain;q=0.9, */*;q=0.5",
          },
          ...(dispatcher ? { dispatcher } : {}),
        } as RequestInit);
      } catch (error) {
        throw new Error(`fetch failed: ${reason(error)}`);
      }
      const location = response.headers.get("location");
      if (response.status >= 300 && response.status < 400 && location) {
        await response.body?.cancel().catch(() => {});
        if (hop >= MAX_REDIRECTS) throw new Error(`too many redirects (more than ${MAX_REDIRECTS})`);
        try {
          url = new URL(location, url);
        } catch {
          throw new Error("the page redirected to an invalid URL");
        }
        continue;
      }
      if (!response.ok) {
        await response.body?.cancel().catch(() => {});
        throw new Error(`fetch failed: HTTP ${response.status} from ${url.host}`);
      }
      const type = (response.headers.get("content-type") ?? "").toLowerCase();
      if (type && !/^text\/|json|xml|javascript/.test(type)) {
        await response.body?.cancel().catch(() => {});
        throw new Error(`not a text page (${type.split(";")[0]})`);
      }
      let { text, truncated } = await readCapped(response, MAX_BYTES);
      let title: string | undefined;
      if (/html/.test(type) || (!type && /^\s*<(?:!doctype html|html)/i.test(text))) {
        const found = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(text)?.[1];
        title = found ? oneLine(found, 200) : undefined;
        text = htmlToText(text);
      }
      if (text.length > limit) {
        text = text.slice(0, limit);
        truncated = true;
      }
      return [
        `URL: ${url.href}`,
        ...(title ? [`Title: ${title}`] : []),
        "",
        text || "(no text)",
        ...(truncated ? [`\n[truncated at ${text.length} characters]`] : []),
      ].join("\n");
    } finally {
      await dispatcher?.destroy();
    }
  }
}

/**
 * `web_search` and `fetch_url`, offered to every bot (and its subagents) whatever is configured,
 * so the tool list stays stable; keys are checked when a tool is called.
 */
export function webTools(options: WebToolsOptions): Extension {
  return defineExtension({
    name: "pi-bot-web",
    tools: [
      defineTool({
        name: "web_search",
        description:
          "Search the web. Returns a numbered list of results (title, URL, date when known, short snippet); read a result in full with fetch_url.",
        parameters: Type.Object({
          query: Type.String({ description: "What to search for" }),
          count: Type.Optional(
            Type.Integer({ minimum: 1, maximum: MAX_RESULTS, description: "Results (default 5)" }),
          ),
        }),
        replay: "safe",
        execute: (args) => run(() => webSearch(options, args.query, args.count)),
      }),
      defineTool({
        name: "fetch_url",
        description:
          "Fetch one public http(s) web page and return its readable text (JSON and plain text as is). Private, local and tailnet addresses are refused.",
        parameters: Type.Object({
          url: Type.String({ description: "The http(s) URL" }),
          maxChars: Type.Optional(
            Type.Integer({
              minimum: 500,
              maximum: MAX_PAGE_CHARS,
              description: `Most characters to return (default ${DEFAULT_PAGE_CHARS})`,
            }),
          ),
        }),
        replay: "safe",
        execute: (args) => run(() => fetchUrl(options, args.url, args.maxChars)),
      }),
    ],
  });
}
