import type { Models } from "@earendil-works/pi-ai";
import { type BotsRuntime, type StartOptions, startRuntime } from "../src/app.ts";
import { type RuntimeConfig, validateRuntimeConfig } from "../src/config.ts";
import type {
  HostAPI,
  HostCredential,
  InferenceCredentialResponse,
  MirrorBatch,
} from "../src/host/client.ts";
import { SettingsStore } from "../src/settings/store.ts";
import { Client } from "./ws-client.ts";

export const TEST_TOKEN = "test-runtime-token-0123456789abcdef0123456789";

export function testConfig(dataDir: string, overrides: Record<string, unknown> = {}): RuntimeConfig {
  return validateRuntimeConfig({
    dataDir,
    listen: { host: "127.0.0.1", port: 0 },
    runtimeToken: TEST_TOKEN,
    engine: { socket: "/nonexistent/docker.sock", kind: "linux-dockerd" },
    image: { tag: "woven-bots-test" },
    limits: { botMemoryBytes: null },
    host: { url: "http://127.0.0.1:9/", token: "host-token-0123456789" },
    machine: { deviceID: "test-machine", name: "Test machine" },
    ...overrides,
  });
}

/** Settings with one profile on `main` (the faux model by default). */
export function testSettings(main = "faux/faux-1", extra: Record<string, unknown> = {}) {
  return SettingsStore.memory({
    profiles: { default: { name: "Default", main } },
    titles: { model: main },
    ...extra,
  });
}

/** A scripted host API: records every call, serves the credentials it was given. */
export class FakeHost implements HostAPI {
  readonly calls: { method: string; args: unknown[] }[] = [];
  readonly credentials = new Map<string, HostCredential>();
  readonly mirrored: { botID: string; batch: MirrorBatch }[] = [];
  readonly previews = new Map<string, string>();
  searchProvider: InferenceCredentialResponse["searchProvider"] = "exa";
  mcpEndpoint = "http://127.0.0.1:1/mcp";
  mcpFails = false;
  #keys = 0;

  async mcpKey(botID: string, botName: string) {
    this.calls.push({ method: "mcpKey", args: [botID, botName] });
    if (this.mcpFails) throw new Error("host unavailable");
    return { endpoint: this.mcpEndpoint, token: `bot-key-${botID.slice(0, 8)}-${++this.#keys}` };
  }
  async revokeMcpKey(botID: string) {
    this.calls.push({ method: "revokeMcpKey", args: [botID] });
  }
  async publishPreview(botID: string, port: number, containerPort: number) {
    this.calls.push({ method: "publishPreview", args: [botID, port, containerPort] });
    const url = `https://test-host.tailnet.ts.net:8443/${botID.slice(0, 8)}/${containerPort}/`;
    this.previews.set(`${botID}:${port}`, url);
    return { url };
  }
  async unpublishPreview(botID: string, port: number) {
    this.calls.push({ method: "unpublishPreview", args: [botID, port] });
    this.previews.delete(`${botID}:${port}`);
  }
  async inferenceCredential(provider: string): Promise<InferenceCredentialResponse> {
    this.calls.push({ method: "inferenceCredential", args: [provider] });
    if (provider === "web-search") {
      const id = this.searchProvider ?? "exa";
      return { credential: this.credentials.get(id) ?? null, searchProvider: id };
    }
    return { credential: this.credentials.get(provider) ?? null };
  }
  async mirror(botID: string, batch: MirrorBatch) {
    this.calls.push({ method: "mirror", args: [botID] });
    this.mirrored.push({ botID, batch });
  }
}

export type TestRuntime = BotsRuntime & { readonly url: string; readonly host: FakeHost };

/** The runtime on a free loopback port, with a fake host and no container environment. */
export async function startTestRuntime(
  dataDir: string,
  options: Omit<StartOptions, "models"> & {
    readonly models: Models;
    readonly host?: FakeHost;
    readonly config?: Record<string, unknown>;
  },
): Promise<TestRuntime> {
  const host = options.host ?? new FakeHost();
  const { config, ...rest } = options;
  const runtime = await startRuntime(testConfig(dataDir, config), {
    env: null,
    settings: testSettings(),
    port: 0,
    log: () => {},
    ...rest,
    host,
  });
  return Object.assign(runtime, { url: `${runtime.server.url.replace("http", "ws")}/ws`, host });
}

export function openClient(url: string, token = TEST_TOKEN): Promise<Client> {
  return Client.open(url, { authorization: `Bearer ${token}` });
}
