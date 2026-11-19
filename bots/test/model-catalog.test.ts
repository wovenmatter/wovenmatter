import { readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  type Credential,
  InMemoryModelsStore,
  type ModelsStore,
  PI_AI_VERSION,
} from "@earendil-works/pi-ai";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { CLAUDE_SUBSCRIPTION_PROVIDER } from "../src/claude/provider.ts";
import {
  CATALOG_REFRESH_MS,
  checkCatalogModel,
  FileModelsStore,
  parseCatalog,
} from "../src/model-catalog.ts";
import { createBotModels, refreshBotModels } from "../src/models.ts";
import { fakeCredentials, MemoryCredentials } from "./fake-providers.ts";
import { startRuntime } from "../src/app.ts";
import { tempDir } from "./helpers.ts";
import { FakeHost, openClient, testConfig, testSettings } from "./runtime.ts";

/** A catalog entry as Pi's service publishes them. */
function entry(provider: string, id: string, overrides: Record<string, unknown> = {}) {
  const api = {
    "openai-codex": ["openai-codex-responses", "https://chatgpt.com/backend-api"],
    openai: ["openai-responses", "https://api.openai.com/v1"],
    anthropic: ["anthropic-messages", "https://api.anthropic.com"],
    xai: ["openai-responses", "https://api.x.ai/v1"],
    openrouter: ["openai-completions", "https://openrouter.ai/api/v1"],
    "opencode-go": ["openai-completions", "https://opencode.ai/inference/go/openai/v1"],
  }[provider] ?? ["openai-responses", "https://example.invalid"];
  return {
    id,
    name: id.toUpperCase(),
    api: api[0],
    provider,
    baseUrl: api[1],
    type: "chat",
    reasoning: true,
    input: ["text", "image"],
    cost: { input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5, tiers: [{ inputTokensAbove: 272000, input: 4 }] },
    contextWindow: 500_000,
    maxTokens: 128_000,
    ...overrides,
  };
}

type Seen = { url: string; headers: Record<string, string> };

/** Pi's catalog service, faked: one list per provider, with an ETag that follows its content. */
function catalogService(lists: Record<string, unknown[] | number>) {
  const seen: Seen[] = [];
  const fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(String(input));
    const headers: Record<string, string> = {};
    new Headers(init?.headers).forEach((value, name) => {
      headers[name] = value;
    });
    seen.push({ url: url.href, headers });
    const provider = decodeURIComponent(url.pathname.split("/").pop() ?? "");
    const list = lists[provider];
    if (typeof list === "number") return new Response("no", { status: list });
    if (!list) return new Response("unknown", { status: 404 });
    const etag = `"${provider}-${JSON.stringify(list).length}"`;
    if (headers["if-none-match"] === etag) return new Response(null, { status: 304 });
    return new Response(JSON.stringify(list), {
      status: 200,
      headers: { "content-type": "application/json", etag, "last-modified": "Thu, 19 Nov 2026 13:23:05 GMT" },
    });
  }) as typeof globalThis.fetch;
  return { fetch, seen, lists };
}

const ids = (models: readonly { id: string }[]) => models.map((model) => model.id);

describe("Pi's live model catalog for bots", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let now: number;
  /** Signed in to just these providers (a ChatGPT subscription unless named otherwise). */
  const signedIn = async (...providers: string[]) => {
    const all = fakeCredentials();
    const chosen: Record<string, Credential> = {};
    for (const provider of providers.length ? providers : ["openai-codex"]) {
      chosen[provider] = (await all.read(provider)) ?? { type: "api_key", key: "test-key" };
    }
    return new MemoryCredentials(chosen);
  };
  const open = async (
    service: ReturnType<typeof catalogService>,
    store: ModelsStore = new InMemoryModelsStore(),
    providers: string[] = [],
  ) =>
    createBotModels(await signedIn(...providers), {
      claude: { directory: join(dir.path, "claude") },
      catalog: { store, fetch: service.fetch, now: () => now },
    });

  beforeEach(async () => {
    dir = await tempDir();
    now = Date.parse("2026-11-19T15:00:00Z");
  });
  afterEach(async () => {
    await dir.cleanup();
  });

  it("lists what pi-ai ships until the catalog is loaded, then the live list", async () => {
    const service = catalogService({
      "openai-codex": [entry("openai-codex", "gpt-6.1-sol"), entry("openai-codex", "gpt-6.2-sol"), entry("openai-codex", "gpt-6.2-astra")],
    });
    const models = await open(service);
    const bundled = ids(models.getModels("openai-codex"));
    expect(bundled).toContain("gpt-6.1-sol");
    expect(bundled).not.toContain("gpt-6.2-sol");

    expect(await refreshBotModels(models)).toEqual([]);
    expect(ids(models.getModels("openai-codex"))).toEqual(["gpt-6.1-sol", "gpt-6.2-sol", "gpt-6.2-astra"]);
    expect(ids(await models.getAvailable("openai-codex"))).toContain("gpt-6.2-astra");
    expect(models.getModel("openai-codex", "gpt-6.2-sol")).toMatchObject({
      provider: "openai-codex",
      api: "openai-codex-responses",
      baseUrl: "https://chatgpt.com/backend-api",
    });
    // The request Pi chats make: chat models for this Pi version, nothing about the user.
    const request = service.seen.find((item) => item.url.includes("/openai-codex"));
    expect(request?.url).toBe(
      `https://pi.dev/api/models/providers/openai-codex?types=chat&pi-version=${PI_AI_VERSION}`,
    );
    expect(request?.headers).toEqual({ accept: "application/json", "user-agent": `pi/${PI_AI_VERSION}` });
  });

  it("asks only for providers that are signed in", async () => {
    const service = catalogService({
      "openai-codex": [entry("openai-codex", "gpt-6.2-sol")],
      xai: [entry("xai", "grok-5")],
      openai: [entry("openai", "gpt-6.2")],
    });
    const models = await open(service, new InMemoryModelsStore(), ["xai"]);
    await refreshBotModels(models);
    expect(service.seen.map((item) => new URL(item.url).pathname)).toEqual(["/api/models/providers/xai"]);
    // The others still list what pi-ai ships.
    expect(ids(models.getModels("openai-codex"))).not.toContain("gpt-6.2-sol");
  });

  it("keeps a catalog for four hours, then revalidates it", async () => {
    const service = catalogService({ "openai-codex": [entry("openai-codex", "gpt-6.2-sol")] });
    const store = new InMemoryModelsStore();
    const models = await open(service, store);
    await refreshBotModels(models);
    const first = service.seen.length;
    now += CATALOG_REFRESH_MS - 1_000;
    await refreshBotModels(models);
    expect(service.seen.length).toBe(first);

    now += 2_000;
    await refreshBotModels(models);
    const codex = service.seen.filter((item) => item.url.includes("/openai-codex"));
    expect(codex).toHaveLength(2);
    // Unchanged: a 304 keeps the list and only moves when it was last checked.
    expect(codex[1]?.headers["if-none-match"]).toMatch(/^"openai-codex-/);
    expect(ids(models.getModels("openai-codex"))).toEqual(["gpt-6.2-sol"]);
    expect((await store.read("openai-codex"))?.checkedAt).toBe(now);

    // A changed catalog replaces it; a forced refresh does not wait for the four hours.
    service.lists["openai-codex"] = [entry("openai-codex", "gpt-6.2-sol"), entry("openai-codex", "gpt-7-sol")];
    await refreshBotModels(models);
    expect(ids(models.getModels("openai-codex"))).toEqual(["gpt-6.2-sol"]);
    await refreshBotModels(models, { force: true });
    expect(ids(models.getModels("openai-codex"))).toEqual(["gpt-6.2-sol", "gpt-7-sol"]);
  });

  it("restores the stored catalog without the network, as a restart does", async () => {
    const service = catalogService({ "openai-codex": [entry("openai-codex", "gpt-6.2-sol")] });
    const store = new FileModelsStore(join(dir.path, "provider-models"));
    await refreshBotModels(await open(service, store));
    const requests = service.seen.length;

    const restarted = await open(service, store);
    expect(ids(restarted.getModels("openai-codex"))).not.toContain("gpt-6.2-sol");
    expect(await refreshBotModels(restarted, { network: false })).toEqual([]);
    expect(ids(restarted.getModels("openai-codex"))).toEqual(["gpt-6.2-sol"]);
    expect(service.seen.length).toBe(requests);
  });

  it("keeps the list it had when the catalog can't be read or is refused", async () => {
    const service = catalogService({ "openai-codex": 503, xai: [entry("xai", "grok-5", { baseUrl: "https://evil.example/v1" })] });
    const models = await open(service, new InMemoryModelsStore(), ["openai-codex", "xai"]);
    const bundledCodex = ids(models.getModels("openai-codex"));
    const bundledXai = ids(models.getModels("xai"));
    const problems = await refreshBotModels(models);
    expect(problems.sort()).toEqual([
      "openai-codex: the model catalog answered 503",
      "xai: the model catalog returned invalid model metadata",
    ]);
    expect(ids(models.getModels("openai-codex"))).toEqual(bundledCodex);
    expect(ids(models.getModels("xai"))).toEqual(bundledXai);
  });

  it("gives the key-only xAI connection and the Claude subscription their source's catalog", async () => {
    const service = catalogService({
      xai: [entry("xai", "grok-5")],
      anthropic: [entry("anthropic", "claude-next")],
      "openai-codex": [entry("openai-codex", "gpt-6.2-sol")],
    });
    const models = await open(service, new InMemoryModelsStore(), ["xai", "xai-api", CLAUDE_SUBSCRIPTION_PROVIDER]);
    expect(await refreshBotModels(models)).toEqual([]);
    expect(models.getModels("xai-api")).toMatchObject([{ id: "grok-5", provider: "xai-api", baseUrl: "https://api.x.ai/v1" }]);
    expect(models.getModels("xai")).toMatchObject([{ id: "grok-5", provider: "xai" }]);
    // Claude runs through the Claude Agent SDK: its models keep that API, not Anthropic's endpoint.
    const bundled = createBotModels(await signedIn(), { claude: { directory: join(dir.path, "claude") } });
    const shipped = bundled.getModels(CLAUDE_SUBSCRIPTION_PROVIDER)[0];
    expect(models.getModels(CLAUDE_SUBSCRIPTION_PROVIDER)).toMatchObject([
      { id: "claude-next", provider: CLAUDE_SUBSCRIPTION_PROVIDER, api: shipped?.api, baseUrl: shipped?.baseUrl },
    ]);
    expect(service.seen.filter((item) => item.url.includes("/anthropic")).length).toBe(1);
  });

  it("ignores a stored catalog that would send a credential somewhere else", async () => {
    const service = catalogService({ "openai-codex": 503 });
    const store = new InMemoryModelsStore();
    await store.write("openai-codex", {
      models: [entry("openai-codex", "gpt-6.2-sol", { baseUrl: "https://evil.example" })] as never,
      checkedAt: now,
    });
    const models = await open(service, store);
    const bundled = ids(models.getModels("openai-codex"));
    await refreshBotModels(models, { network: false });
    expect(ids(models.getModels("openai-codex"))).toEqual(bundled);
  });

  it("shows the live list wherever a model is chosen, and keeps it across a restart", async () => {
    const service = catalogService({ xai: [entry("xai", "grok-4.3"), entry("xai", "grok-5")] });
    const host = new FakeHost();
    host.credentials.set("xai", { type: "api_key", key: "test-xai-key" });
    const logs: string[] = [];
    const start = () =>
      startRuntime(testConfig(dir.path), {
        env: null,
        // A profile on a model only the live catalog lists.
        settings: testSettings("xai/grok-5"),
        host,
        port: 0,
        log: (line) => logs.push(line),
        catalog: { fetch: service.fetch },
      });
    type Catalog = { providers: { id: string; models: { id: string }[] }[] };
    const listed = async (runtime: Awaited<ReturnType<typeof start>>) => {
      const client = await openClient(`${runtime.server.url.replace("http", "ws")}/ws`);
      try {
        const catalog = await client.request<Catalog>("models.catalog");
        return catalog.providers.find((provider) => provider.id === "xai")?.models.map((model) => model.id);
      } finally {
        client.close();
      }
    };
    let runtime = await start();
    try {
      // Nothing is fetched at start: asking for the list is what loads the catalog.
      expect(await listed(runtime)).toEqual(["grok-4.3", "grok-5"]);
      expect(JSON.parse(await readFile(join(dir.path, "provider-models", "xai.json"), "utf8")).models).toHaveLength(2);
    } finally {
      await runtime.close();
    }
    // Restarted with the catalog service down: the stored list is there from the first moment.
    service.lists.xai = 503;
    logs.length = 0;
    runtime = await start();
    try {
      expect(runtime.models.getModel("xai", "grok-5")).toMatchObject({ id: "grok-5", provider: "xai" });
      expect(logs.filter((line) => line.includes("has no model"))).toEqual([]);
      expect(await listed(runtime)).toEqual(["grok-4.3", "grok-5"]);
    } finally {
      await runtime.close();
    }
  });

  describe("what a catalog may say", () => {
    it("takes chat models at the provider's own endpoint and skips the rest", () => {
      const models = parseCatalog(
        [
          entry("openrouter", "a/chat"),
          entry("openrouter", "a/image", { type: "image", api: "openrouter-images" }),
          entry("openrouter", "a/other-api", { api: "google-generative-ai", baseUrl: "https://elsewhere.example" }),
          entry("openrouter", "a/router", { cost: { input: -1_000_000, output: -1_000_000 } }),
          entry("openrouter", "a/claude", { api: "anthropic-messages", baseUrl: "https://openrouter.ai/api" }),
        ],
        "openrouter",
      );
      expect(ids(models)).toEqual(["a/chat", "a/claude"]);
      expect(ids(parseCatalog({ models: [entry("xai", "grok-5")] }, "xai"))).toEqual(["grok-5"]);
      expect(ids(parseCatalog([entry("opencode-go", "glm-6")], "opencode-go"))).toEqual(["glm-6"]);
    });

    it("refuses the whole catalog when one entry is wrong", () => {
      const bad = (overrides: Record<string, unknown>, provider = "openai") => () =>
        parseCatalog([entry(provider, "good"), entry(provider, "bad", overrides)], provider);
      expect(bad({ baseUrl: "https://api.openai.com.evil.example/v1" })).toThrow("invalid model metadata");
      expect(bad({ headers: { authorization: "x" } })).toThrow("invalid model metadata");
      expect(bad({ provider: "someone-else" })).toThrow("invalid model metadata");
      expect(bad({ id: "good" })).toThrow("invalid model metadata");
      expect(bad({ id: "line\nbreak" })).toThrow("invalid model metadata");
      expect(bad({ contextWindow: 0 })).toThrow("invalid model metadata");
      expect(bad({ cost: { input: -1 } })).toThrow("invalid model metadata");
      expect(bad({ input: ["audio"] })).toThrow("invalid model metadata");
      // An unpriced OpenRouter router is left out, but not if it also points somewhere else.
      expect(
        bad({ cost: { input: -1_000_000, output: 0 }, baseUrl: "https://evil.example" }, "openrouter"),
      ).toThrow("invalid model metadata");
      expect(() => parseCatalog("nope", "openai")).toThrow("invalid model metadata");
      expect(() => parseCatalog([entry("openai", "img", { type: "image" })], "openai")).toThrow("no chat models");
      expect(() => checkCatalogModel(entry("unknown-provider", "x"), "unknown-provider")).toThrow();
    });
  });

  describe("the catalog files", () => {
    it("keeps one private file per provider and reads it back", async () => {
      const store = new FileModelsStore(join(dir.path, "provider-models"));
      expect(await store.read("openai-codex")).toBeUndefined();
      const saved = { models: [entry("openai-codex", "gpt-6.2-sol")] as never, checkedAt: 5, lastModified: 4, etag: '"e"' };
      await store.write("openai-codex", saved);
      expect(await store.read("openai-codex")).toEqual(saved);
      const path = join(dir.path, "provider-models", "openai-codex.json");
      expect((await stat(path)).mode & 0o777).toBe(0o600);
      expect(JSON.parse(await readFile(path, "utf8")).piVersion).toBe(PI_AI_VERSION);
      await store.delete("openai-codex");
      expect(await store.read("openai-codex")).toBeUndefined();
    });

    it("does not reuse a file from another Pi version, a broken one, or an odd name", async () => {
      const store = new FileModelsStore(join(dir.path, "provider-models"));
      await store.write("xai", { models: [entry("xai", "grok-5")] as never, checkedAt: 1 });
      const path = join(dir.path, "provider-models", "xai.json");
      const text = await readFile(path, "utf8");
      await writeFile(path, text.replace(PI_AI_VERSION, "0.0.1"));
      expect(await store.read("xai")).toBeUndefined();
      await writeFile(path, "{not json");
      expect(await store.read("xai")).toBeUndefined();
      await expect(store.write("../escape", { models: [] })).rejects.toThrow("invalid provider id");
      expect(await store.read("../escape")).toBeUndefined();
    });
  });
});
