import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ConfigError, validateRuntimeConfig } from "../src/config.ts";
import { HostClient, HostError } from "../src/host/client.ts";
import { HostCredentialStore, NATIVE_PREFIX, toPiCredential } from "../src/host/credentials.ts";
import { testConfig } from "./runtime.ts";

describe("runtime config", () => {
  it("accepts the Woven server's JSON and derives paths", () => {
    const config = testConfig("/var/lib/woven/bots");
    expect(config.paths).toEqual({
      dataDir: "/var/lib/woven/bots",
      database: "/var/lib/woven/bots/bots.sqlite",
      settings: "/var/lib/woven/bots/settings.json",
      claude: "/var/lib/woven/bots/claude-agent",
    });
    expect(config.engine.kind).toBe("linux-dockerd");
    expect(config.limits.botMemoryBytes).toBeNull();
  });

  it.each([
    ["a public bind address", { listen: { host: "0.0.0.0", port: 1 } }],
    ["a tailnet bind address", { listen: { host: "100.64.1.2", port: 1 } }],
    ["a short runtime token", { runtimeToken: "short" }],
    ["a remote host API", { host: { url: "http://example.com/", token: "host-token-0123456789" } }],
    ["an unknown engine kind", { engine: { socket: "/s", kind: "podman" } }],
    ["a relative data dir", { dataDir: "data" }],
    ["unknown keys", { extra: true }],
  ])("refuses %s", (_name, override) => {
    expect(() => testConfig("/data", override as Record<string, unknown>)).toThrow(ConfigError);
  });

  it("allows IPv6 loopback and a memory limit", () => {
    const config = testConfig("/d", {
      listen: { host: "::1", port: 4100 },
      limits: { botMemoryBytes: 4 * 1024 ** 3 },
      engine: { socket: "/Users/me/Library/Application Support/Woven/bots-engine.sock", kind: "mac-vm" },
    });
    expect(config.listen.host).toBe("::1");
    expect(config.limits.botMemoryBytes).toBe(4 * 1024 ** 3);
    expect(() =>
      validateRuntimeConfig({ ...testConfig("/d"), paths: undefined }),
    ).toThrow(ConfigError);
  });
});

describe("host API client", () => {
  let server: Server;
  let base: string;
  const seen: { method: string; url: string; auth?: string; body: unknown }[] = [];
  let reply: (request: IncomingMessage, body: unknown) => { status: number; body?: unknown } = () => ({ status: 200, body: {} });
  beforeEach(async () => {
    seen.length = 0;
    server = createServer(async (request, response) => {
      let raw = "";
      for await (const chunk of request) raw += chunk;
      const body = raw ? JSON.parse(raw) : undefined;
      seen.push({ method: request.method ?? "", url: request.url ?? "", auth: request.headers.authorization, body });
      const answer = reply(request, body);
      response.writeHead(answer.status, { "content-type": "application/json" });
      response.end(answer.body === undefined ? "" : JSON.stringify(answer.body));
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  afterEach(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });

  it("calls every route with the host bearer and the documented bodies", async () => {
    const client = new HostClient(base, "host-secret");
    reply = (request) => {
      if (request.url === "/v1/bots-host/mcp-keys") return { status: 200, body: { endpoint: "http://127.0.0.1:1/mcp", token: "bot-key" } };
      if (request.url === "/v1/bots-host/previews") return { status: 200, body: { url: "https://h.ts.net:8443/" } };
      if (request.url === "/v1/bots-host/inference-credentials") {
        return { status: 200, body: { credential: { type: "oauth", access: "a", expires: 5, accountId: "acct" }, searchProvider: "brave" } };
      }
      return { status: request.method === "DELETE" ? 204 : 200 };
    };
    expect(await client.mcpKey("b1", "Bot One")).toEqual({ endpoint: "http://127.0.0.1:1/mcp", token: "bot-key" });
    await client.revokeMcpKey("b1");
    expect(await client.publishPreview("b1", 40123, 3000)).toEqual({ url: "https://h.ts.net:8443/" });
    await client.unpublishPreview("b1", 40123);
    expect(await client.inferenceCredential("web-search")).toEqual({
      credential: { type: "oauth", access: "a", expires: 5, accountId: "acct" },
      searchProvider: "brave",
    });
    await client.mirror("b1", { bot: { id: "b1", name: "Bot One" }, conversations: [], entries: [] });
    expect(seen.map((call) => `${call.method} ${call.url}`)).toEqual([
      "POST /v1/bots-host/mcp-keys",
      "DELETE /v1/bots-host/mcp-keys/b1",
      "POST /v1/bots-host/previews",
      "DELETE /v1/bots-host/previews/b1/40123",
      "POST /v1/bots-host/inference-credentials",
      "POST /v1/bots-host/conversations/b1/entries",
    ]);
    expect(seen.every((call) => call.auth === "Bearer host-secret")).toBe(true);
    expect(seen[0]?.body).toEqual({ botID: "b1", botName: "Bot One" });
    expect(seen[2]?.body).toEqual({ botID: "b1", port: 40123, containerPort: 3000 });
    expect(seen[4]?.body).toEqual({ provider: "web-search" });
  });

  it("reports failures by status without echoing the reply", async () => {
    reply = () => ({ status: 403, body: { error: "leaked-detail" } });
    const client = new HostClient(base, "host-secret");
    const error = await client.mcpKey("b1", "x").catch((e: unknown) => e);
    expect(error).toBeInstanceOf(HostError);
    expect((error as HostError).status).toBe(403);
    expect((error as Error).message).not.toContain("leaked-detail");
    expect((error as Error).message).not.toContain("host-secret");
    reply = () => ({ status: 200, body: { credential: { type: "mystery" } } });
    expect(await client.inferenceCredential("openai")).toEqual({ credential: null });
    await expect(new HostClient("http://127.0.0.1:9", "t").mcpKey("b", "n")).rejects.toThrow(/unreachable/);
  });
});

describe("host credentials", () => {
  it("serves pi-ai credentials from the host, cached briefly, never refreshing tokens itself", async () => {
    let now = 1_000_000;
    const asked: string[] = [];
    let access = "first";
    const store = new HostCredentialStore(
      {
        async inferenceCredential(provider: string) {
          asked.push(provider);
          if (provider === "openai") return { credential: { type: "api_key", key: "sk-1" } };
          if (provider === "openai-codex") return { credential: { type: "oauth", access, expires: now + 120_000 } };
          return { credential: null };
        },
      },
      () => now,
    );
    expect(await store.read("openai")).toEqual({ type: "api_key", key: "sk-1" });
    expect(await store.read("openai")).toEqual({ type: "api_key", key: "sk-1" });
    expect(asked).toEqual(["openai"]);
    expect(await store.read("openai-codex")).toMatchObject({ type: "oauth", access: "first", refresh: "" });
    access = "second";
    now += 61_000;
    // Within a minute of expiry: ask the host again.
    expect(await store.read("openai-codex")).toMatchObject({ access: "second" });
    // pi-ai's refresh path asks the host instead of refreshing.
    access = "third";
    expect(await store.modify("openai-codex", async () => undefined)).toMatchObject({ access: "third" });
    expect(await store.read("xai")).toBeUndefined();
    expect((await store.list()).map((entry) => entry.providerId).sort()).toEqual(["openai", "openai-codex"]);
  });

  it("marks a native Claude profile without carrying token material", () => {
    const value = toPiCredential({ type: "native", configDir: "/dev/shm/woven-claude-1000-abc" });
    expect(value?.type).toBe("api_key");
    expect(value?.type === "api_key" && value.key?.startsWith(NATIVE_PREFIX)).toBe(true);
    expect(JSON.stringify(value)).toContain("/dev/shm/woven-claude-1000-abc");
  });
});
