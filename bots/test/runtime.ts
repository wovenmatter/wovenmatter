import { join } from "node:path";
import type { Models } from "@earendil-works/pi-ai";
import { type BotsRuntime, type StartOptions, startRuntime } from "../src/app.ts";
import { type RuntimeConfig, validateRuntimeConfig } from "../src/config.ts";
import { SettingsStore } from "../src/settings/store.ts";
import { socketDirectory } from "./helpers.ts";

export function testConfig(dataDir: string, socket: string): RuntimeConfig {
  return validateRuntimeConfig({
    dataDir,
    socket,
    engine: { socket: "/nonexistent/docker.sock", kind: "linux-dockerd" },
    image: { tag: "woven-bots-test" },
    limits: { botMemoryBytes: null },
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

export type TestRuntime = BotsRuntime & { readonly socket: string };

/** The runtime on a socket in `dir`, with no container environment. */
export async function startTestRuntime(
  dir: string,
  options: Omit<StartOptions, "models"> & { readonly models: Models },
): Promise<TestRuntime> {
  const socket = join(socketDirectory(dir, "runtime.sock"), "runtime.sock");
  const runtime = await startRuntime(testConfig(join(dir, "bots"), socket), {
    env: null,
    settings: testSettings(),
    log: () => {},
    ...options,
  });
  return Object.assign(runtime, { socket });
}
