import { join } from "node:path";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Credential } from "@earendil-works/pi-ai";
import { createModels } from "@earendil-works/pi-ai/models";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxToolCall,
} from "@earendil-works/pi-ai/providers/faux";
import { describe, expect, it } from "vitest";
import { createBotHarnessOptions } from "../src/agent.ts";
import { BotManager } from "../src/bots.ts";
import { openSharedDatabase } from "../src/storage/database.ts";
import {
  fetchUrl,
  createPinnedWebAgent,
  htmlToText,
  isBlockedAddress,
  NO_SEARCH_KEY,
  type WebToolsOptions,
  webSearch,
} from "../src/web.ts";
import { FAUX_MODEL, profileOf, tempDir } from "./helpers.ts";

/** IPv4 addresses from their parts (the public-tree scan keeps literals out of the tree). */
const ip = (...parts: number[]) => parts.join(".");

const ctx = BACKGROUND_CONTEXT;
const EXA_KEY = "exa-test-key-0001";
const BRAVE_KEY = "brave-test-key-0002";
const FIRECRAWL_KEY = "fc-test-key-0003";

type Seen = { url: string; method: string; headers: Record<string, string>; body?: unknown };

/** A fake fetch: records each request and answers with `reply(url)`. */
function fakeFetch(reply: (url: string) => Response) {
  const seen: Seen[] = [];
  const fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const headers: Record<string, string> = {};
    new Headers(init?.headers).forEach((value, name) => {
      headers[name] = value;
    });
    seen.push({
      url,
      method: init?.method ?? "GET",
      headers,
      ...(typeof init?.body === "string" ? { body: JSON.parse(init.body) } : {}),
    });
    return reply(url);
  }) as typeof globalThis.fetch;
  return { fetch, seen };
}

const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });

function store(keys: Record<string, string>): WebToolsOptions["credentials"] {
  return {
    read: async (provider: string): Promise<Credential | undefined> =>
      keys[provider] ? { type: "api_key", key: keys[provider] } : undefined,
  };
}

const lookup = async (host: string) => {
  const table: Record<string, string[]> = {
    "example.com": [ip(93, 184, 215, 14)],
    "docs.example.com": ["2606:2800:21f:cb07:6820:80da:af6b:8b2c"],
    "evil.example": [ip(93, 184, 215, 15), "127.0.0.1"],
    "tailnet.example": [ip(100, 101, 102, 103)],
    "tail6.example": ["fd7a:115c:a1e0::1"],
    localhost: ["127.0.0.1", "::1"],
  };
  const found = table[host];
  if (!found) throw new Error("ENOTFOUND");
  return found;
};

describe("web_search", () => {
  it("maps Exa requests and results", async () => {
    const { fetch, seen } = fakeFetch(() =>
      json({
        results: [
          {
            title: "Pi Durable",
            url: "https://pi.dev/durable",
            publishedDate: "2026-09-01T10:00:00.000Z",
            text: "Durable   agents\non SQLite. ".repeat(40),
          },
          { title: "No URL" },
        ],
      }),
    );
    const out = await webSearch(
      { credentials: store({ exa: EXA_KEY }), provider: "exa", fetch },
      " pi durable ",
      3,
    );
    expect(seen).toEqual([
      {
        url: "https://api.exa.ai/search",
        method: "POST",
        headers: expect.objectContaining({ "x-api-key": EXA_KEY }),
        body: { query: "pi durable", numResults: 3, contents: { text: { maxCharacters: 1000 } } },
      },
    ]);
    expect(out).toMatch(
      /^Results from Exa for "pi durable":\n1\. Pi Durable\n {3}https:\/\/pi\.dev\/durable\n {3}2026-09-01\n {3}Durable agents on SQLite\./,
    );
    // Snippets are one line and capped; results without a URL are dropped.
    expect(out.split("\n").at(-1)?.length).toBeLessThanOrEqual(303);
    expect(out).not.toContain("No URL");
    expect(out).not.toContain(EXA_KEY);
  });

  it("maps Brave requests and results", async () => {
    const { fetch, seen } = fakeFetch(() =>
      json({
        web: {
          results: [
            {
              title: "Brave &amp; friends",
              url: "https://brave.example/a",
              description: "The <strong>best</strong> search",
              age: "2 days ago",
            },
          ],
        },
      }),
    );
    const out = await webSearch(
      { credentials: store({ brave: BRAVE_KEY }), provider: "brave", fetch },
      "best search",
    );
    expect(seen[0]?.url).toBe(
      "https://api.search.brave.com/res/v1/web/search?q=best+search&count=5",
    );
    expect(seen[0]?.method).toBe("GET");
    expect(seen[0]?.headers).toMatchObject({
      "x-subscription-token": BRAVE_KEY,
      accept: "application/json",
    });
    expect(out).toBe(
      'Results from Brave Search for "best search":\n1. Brave & friends\n   https://brave.example/a\n   2 days ago\n   The best search',
    );
  });

  it("maps Firecrawl v2 (and v1-shaped) results", async () => {
    let shape: "v2" | "v1" = "v2";
    const item = { title: "Crawl", url: "https://fc.example/x", description: "Scraped page" };
    const { fetch, seen } = fakeFetch(() =>
      json(shape === "v2" ? { success: true, data: { web: [item] } } : { data: [item] }),
    );
    const options = {
      credentials: store({ firecrawl: FIRECRAWL_KEY }),
      provider: "firecrawl" as const,
      fetch,
    };
    const out = await webSearch(options, "crawl", 20);
    expect(seen[0]).toMatchObject({
      url: "https://api.firecrawl.dev/v2/search",
      method: "POST",
      headers: { authorization: `Bearer ${FIRECRAWL_KEY}` },
      body: { query: "crawl", limit: 10 },
    });
    expect(out).toContain("1. Crawl\n   https://fc.example/x\n   Scraped page");
    shape = "v1";
    expect(await webSearch(options, "crawl")).toBe(out);
  });

  it("falls back to another provider with a key and says so", async () => {
    const { fetch, seen } = fakeFetch(() => json({ web: { results: [] } }));
    const out = await webSearch(
      { credentials: store({ brave: BRAVE_KEY }), provider: "exa", fetch },
      "anything",
    );
    expect(seen.map((request) => new URL(request.url).host)).toEqual(["api.search.brave.com"]);
    expect(out).toBe(
      '(Exa has no API key, so this used Brave Search.)\nNo results from Brave Search for "anything".',
    );
  });

  it("explains how to set it up when no search key exists", async () => {
    const { fetch, seen } = fakeFetch(() => json({}));
    await expect(
      webSearch({ credentials: store({}), provider: "exa", fetch }, "q"),
    ).rejects.toThrow(NO_SEARCH_KEY);
    expect(seen).toEqual([]);
  });

  it("refuses provider redirects before a search key can be forwarded", async () => {
    for (const [provider, key] of [["exa", EXA_KEY], ["brave", BRAVE_KEY], ["firecrawl", FIRECRAWL_KEY]] as const) {
      const fetch = (async (_url: string | URL | Request, init?: RequestInit) => {
        expect(init?.redirect).toBe("error");
        throw new TypeError("redirect blocked");
      }) as typeof globalThis.fetch;
      await expect(webSearch({ credentials: store({ [provider]: key }), provider, fetch }, "q"))
        .rejects.toThrow("redirect blocked");
    }
  });

  it("bounds provider responses before parsing JSON", async () => {
    const { fetch } = fakeFetch(() => json({ results: [], padding: "x".repeat(2_000_000) }));
    await expect(webSearch({ credentials: store({ exa: EXA_KEY }), provider: "exa", fetch }, "q"))
      .rejects.toThrow("provider response was too large");
  });

  it("turns provider HTTP errors into one line without the key or body", async () => {
    for (const [status, text] of [
      [401, "the API key was rejected (check it in Woven Matter Settings → Subscriptions & API Keys) (HTTP 401)"],
      [402, "out of credits"],
      [429, "rate limited"],
      [503, "the service had an error"],
    ] as const) {
      const { fetch } = fakeFetch(() =>
        json({ error: `bad key ${EXA_KEY}`, details: "secret body" }, status),
      );
      const failed = webSearch(
        { credentials: store({ exa: EXA_KEY }), provider: "exa", fetch },
        "q",
      );
      await expect(failed).rejects.toThrow(text);
      const message = await failed.catch((error: Error) => error.message);
      expect(message).toMatch(/^Exa search failed: .*\.$/);
      expect(message).not.toContain(EXA_KEY);
      expect(message).not.toContain("secret body");
    }
    const down = (async () => {
      throw new TypeError("fetch failed");
    }) as typeof globalThis.fetch;
    await expect(
      webSearch({ credentials: store({ exa: EXA_KEY }), provider: "exa", fetch: down }, "q"),
    ).rejects.toThrow("Exa search failed: fetch failed.");
  });
});

describe("fetch_url", () => {
  it("dials the validated address without re-resolving the URL hostname", async () => {
    let requestedHost: string | undefined;
    const server = createServer((request, response) => {
      requestedHost = request.headers.host;
      response.end("pinned");
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const agent = createPinnedWebAgent("127.0.0.1", 4);
    try {
      const port = (server.address() as AddressInfo).port;
      const response = await fetch(`http://rebinding.invalid:${port}/`, {
        dispatcher: agent,
      } as RequestInit);
      expect(await response.text()).toBe("pinned");
      expect(requestedHost).toBe(`rebinding.invalid:${port}`);
    } finally {
      await agent.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  const page = `<!doctype html><html><head><title>Hello &amp; welcome</title>
    <style>body { color: red }</style><script>alert("x")</script></head>
    <body><nav>Menu</nav><h1>Heading</h1><p>First   paragraph<br>next line</p>
    <!-- hidden --><ul><li>one</li><li>two &#x2014; &#8212; done</li></ul></body></html>`;

  it("blocks loopback, private, link-local, CGNAT/tailnet and unique-local addresses", () => {
    for (const address of [
      "127.0.0.1",
      ip(10, 1, 2, 3),
      ip(172, 20, 0, 1),
      ip(192, 168, 1, 1),
      ip(169, 254, 169, 254),
      ip(100, 64, 0, 1),
      ip(100, 127, 255, 254),
      "0.0.0.0",
      "::1",
      "::",
      "fe80::1",
      "fd00::1",
      "fd7a:115c:a1e0::1",
      "::ffff:127.0.0.1",
      "::ffff:a9fe:a9fe",
      "not-an-ip",
    ]) {
      expect(isBlockedAddress(address), address).toBe(true);
    }
    for (const address of [ip(93, 184, 215, 14), ip(100, 128, 0, 1), "2606:4700::1111", ip(8, 8, 8, 8)]) {
      expect(isBlockedAddress(address), address).toBe(false);
    }
  });

  it("returns readable text from HTML", async () => {
    const { fetch, seen } = fakeFetch(
      () => new Response(page, { headers: { "content-type": "text/html; charset=utf-8" } }),
    );
    const out = await fetchUrl(
      { credentials: store({}), provider: "exa", fetch, lookup },
      "https://example.com/a",
    );
    expect(seen[0]?.url).toBe("https://example.com/a");
    expect(out).toBe(
      "URL: https://example.com/a\nTitle: Hello & welcome\n\nMenu\n\nHeading\n\nFirst paragraph\nnext line\n\none\n\ntwo — — done",
    );
    expect(htmlToText("<p>a</p><script>x()</script><p>b</p>")).toBe("a\n\nb");
  });

  it("returns JSON and plain text as is, caps characters and refuses binaries", async () => {
    const body = JSON.stringify({ hello: "<b>world</b>" });
    let reply = () => json({ hello: "<b>world</b>" });
    const { fetch } = fakeFetch(() => reply());
    const options = { credentials: store({}), provider: "exa" as const, fetch, lookup };
    expect(await fetchUrl(options, "https://example.com/data.json")).toBe(
      `URL: https://example.com/data.json\n\n${body}`,
    );
    reply = () => new Response("x".repeat(5000), { headers: { "content-type": "text/plain" } });
    const capped = await fetchUrl(options, "https://example.com/big.txt", 1000);
    expect(capped).toContain(`\n\n${"x".repeat(1000)}\n\n[truncated at 1000 characters]`);
    reply = () => new Response("PNG", { headers: { "content-type": "image/png" } });
    await expect(fetchUrl(options, "https://example.com/a.png")).rejects.toThrow(
      "not a text page (image/png)",
    );
    reply = () => new Response("gone", { status: 404 });
    await expect(fetchUrl(options, "https://example.com/missing")).rejects.toThrow(
      "fetch failed: HTTP 404 from example.com",
    );
  });

  it("refuses non-http(s) URLs and blocked hosts before any request", async () => {
    const { fetch, seen } = fakeFetch(() => new Response("never"));
    const options = { credentials: store({}), provider: "exa" as const, fetch, lookup };
    await expect(fetchUrl(options, "file:///etc/passwd")).rejects.toThrow(
      "only http and https URLs can be fetched",
    );
    await expect(fetchUrl(options, "ftp://example.com/x")).rejects.toThrow("only http and https");
    await expect(fetchUrl(options, "not a url")).rejects.toThrow("not a valid URL");
    for (const url of [
      "http://localhost:4317/",
      "http://127.0.0.1/",
      "http://2130706433/",
      "http://0x7f.1/",
      "http://[::1]:4317/",
      "http://[::ffff:127.0.0.1]/",
      "http://[fd7a:115c:a1e0::1]/",
      `http://${ip(100, 100, 100, 100)}/`,
      "http://tailnet.example/",
      "http://tail6.example/",
      // One blocked address among several is enough.
      "http://evil.example/",
      `http://${ip(169, 254, 169, 254)}/latest/meta-data/`,
    ]) {
      await expect(fetchUrl(options, url), url).rejects.toThrow(/refusing to fetch/);
    }
    await expect(fetchUrl(options, "http://nowhere.invalid/")).rejects.toThrow(
      "could not resolve nowhere.invalid",
    );
    expect(seen).toEqual([]);
  });

  it("follows redirects manually and re-checks every hop", async () => {
    const hops: Record<string, Response | (() => Response)> = {};
    const { fetch, seen } = fakeFetch((url) => {
      const found = hops[url];
      if (!found) return new Response("no", { status: 404 });
      return typeof found === "function" ? found() : found;
    });
    const options = { credentials: store({}), provider: "exa" as const, fetch, lookup };
    const redirect = (location: string) => () =>
      new Response(null, { status: 302, headers: { location } });
    hops["https://example.com/start"] = redirect("/next");
    hops["https://example.com/next"] = redirect("https://docs.example.com/final");
    hops["https://docs.example.com/final"] = () =>
      new Response("done", { headers: { "content-type": "text/plain" } });
    expect(await fetchUrl(options, "https://example.com/start")).toBe(
      "URL: https://docs.example.com/final\n\ndone",
    );
    expect(seen.map((request) => request.url)).toEqual([
      "https://example.com/start",
      "https://example.com/next",
      "https://docs.example.com/final",
    ]);

    // A redirect into Pi Bot itself or the tailnet is refused before it is requested.
    seen.length = 0;
    hops["https://example.com/sneaky"] = redirect("http://127.0.0.1:4317/ws");
    await expect(fetchUrl(options, "https://example.com/sneaky")).rejects.toThrow(
      "refusing to fetch 127.0.0.1:4317",
    );
    hops["https://example.com/tail"] = redirect("http://tailnet.example/");
    await expect(fetchUrl(options, "https://example.com/tail")).rejects.toThrow(
      "refusing to fetch tailnet.example",
    );
    expect(seen.map((request) => request.url)).toEqual([
      "https://example.com/sneaky",
      "https://example.com/tail",
    ]);

    hops["https://example.com/loop"] = redirect("/loop");
    await expect(fetchUrl(options, "https://example.com/loop")).rejects.toThrow(
      "too many redirects",
    );
  });
});

describe("web tools in a bot", () => {
  it("are offered to every bot and run through the agent loop", async () => {
    const dir = await tempDir();
    const db = await openSharedDatabase(join(dir.path, "db.sqlite"));
    const faux = fauxProvider({ tokensPerSecond: 5000 });
    const models = createModels();
    models.setProvider(faux.provider);
    const contexts: string[] = [];
    const { fetch } = fakeFetch(() =>
      json({ results: [{ title: "Found it", url: "https://found.example/", text: "snippet" }] }),
    );
    const manager = await BotManager.open({
      db,
      ensureAdmin: true,
      harnessOptions: (bot, self) =>
        createBotHarnessOptions({
          bot,
          models,
          profile: profileOf(FAUX_MODEL),
          platform: { manager: () => self },
          web: { credentials: store({ exa: EXA_KEY }), provider: "exa", fetch, lookup },
        }),
    });
    try {
      const admin = await manager.admin();
      if (!admin) throw new Error("no Admin Bot");
      const plain = await manager.create("Plain");
      for (const id of [admin.id, plain.id]) {
        faux.setResponses([
          (context) => {
            contexts.push(JSON.stringify(context));
            return fauxAssistantMessage([fauxToolCall("web_search", { query: "pi" })], {
              stopReason: "toolUse",
            });
          },
          (context) => {
            contexts.push(JSON.stringify(context));
            return fauxAssistantMessage([fauxText("ok")]);
          },
        ]);
        const sent = await (await manager.get(id)).send("search");
        await expect(sent.submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
      }
      for (const context of contexts) {
        expect(context).toContain('"name":"web_search"');
        expect(context).toContain('"name":"fetch_url"');
        // Keys never reach the model.
        expect(context).not.toContain(EXA_KEY);
      }
      expect(contexts[1]).toContain("1. Found it");
      expect(contexts[3]).toContain("https://found.example/");
    } finally {
      await manager.close();
      await db.close();
      await dir.cleanup();
    }
  });
});
