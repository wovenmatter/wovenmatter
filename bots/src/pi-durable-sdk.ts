// Bots run on the machine's Pi Durable SDK copy, never on one of their own. Pi Durable picks
// its copy (the active SDK update, or the one bundled with Woven Matter) with
// `resolveSDKRuntime` in `default-agent/src/sdk-management.mjs`; bots call that same function
// at launch, then resolve every SDK package from the copy it returns. One SDK update in
// Settings → Updates covers both; the machine's Woven server restarts bots after it.
import { realpathSync } from "node:fs";
import { registerHooks } from "node:module";
import { dirname, isAbsolute, join, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { RuntimeConfig } from "./config.ts";

/** The packages Pi Durable's SDK update installs; bots load each from Pi Durable's copy. */
export const PI_DURABLE_SDK_PACKAGES = [
  "@earendil-works/pi-durable",
  "@earendil-works/pi-ai",
  "@earendil-works/pi-coding-agent",
  "@earendil-works/chord",
  "@anthropic-ai/claude-agent-sdk",
] as const;

export interface PiDurableLocation {
  /** Pi Durable as Woven Matter bundles it (`<Resources>/default-agent`, `<release>/default-agent`). */
  readonly bundle: string;
  /** Pi Durable's SDK workspace on this machine, which holds `sdk-runtime/active.json`. */
  readonly directory: string;
}

export interface PiDurableSDK {
  /** The copy: a directory whose `node_modules` holds every SDK package. */
  readonly root: string;
  /** Pi Durable's name for it: an update's id, or `bundled-<fingerprint>`. */
  readonly generation: string;
  /** That copy's Claude Agent SDK binary. */
  readonly claudeExecutable: string;
}

export class PiDurableSDKError extends Error {}

/** The SDK package a bare specifier names, if it names one. */
export function sdkPackage(specifier: string): string | undefined {
  return PI_DURABLE_SDK_PACKAGES.find((name) => specifier === name || specifier.startsWith(name + "/"));
}

/** The copy Pi Durable runs on this machine, chosen by Pi Durable's own code. */
export async function resolvePiDurableSDK(
  location: PiDurableLocation,
  { platform = process.platform, arch = process.arch }: { platform?: string; arch?: string } = {},
): Promise<PiDurableSDK> {
  if (!isAbsolute(location.bundle) || !isAbsolute(location.directory)) {
    throw new PiDurableSDKError("The Pi Durable location must be absolute.");
  }
  let runtime: { root: string; generation: string };
  try {
    const management = (await import(pathToFileURL(join(location.bundle, "src/sdk-management.mjs")).href)) as {
      resolveSDKRuntime(options: { directory: string }): Promise<{ root: string; generation: string }>;
    };
    runtime = await management.resolveSDKRuntime({ directory: location.directory });
  } catch (error) {
    throw new PiDurableSDKError(`Pi Durable's SDK could not be found in ${location.bundle}: ${(error as Error).message}`);
  }
  const root = realpathSync(runtime.root);
  // Every package must be in this copy, or bots would not run what Pi Durable runs.
  for (const name of PI_DURABLE_SDK_PACKAGES) present(root, name);
  return { root, generation: runtime.generation, claudeExecutable: claudeExecutable(root, platform, arch) };
}

/**
 * Pi Durable's Claude binary in `root`, where its SDK update verifies it
 * (`default-agent/src/sdk-management.mjs`): the glibc package, or the musl one.
 */
export function claudeExecutable(root: string, platform: string = process.platform, arch: string = process.arch): string {
  for (const name of [`claude-agent-sdk-${platform}-${arch}`, `claude-agent-sdk-${platform}-${arch}-musl`]) {
    try {
      return join(present(root, `@anthropic-ai/${name}`), "claude");
    } catch {
      continue;
    }
  }
  throw new PiDurableSDKError(`Pi Durable's SDK in ${root} has no Claude binary for ${platform}-${arch}.`);
}

let installed: string | undefined;

/** The `node_modules/` (with its slash) of the SDK copy this process loads, once it does. */
export function sdkNodeModules(): string | undefined {
  return installed === undefined ? undefined : join(installed, "node_modules") + sep;
}

/**
 * From now on, every import of an SDK package in this process (bots' own code and their other
 * dependencies alike) resolves from `root`, as if Pi Durable had imported it. A resolution that
 * lands outside `root` fails rather than loading another copy.
 */
export function loadSDKFrom(root: string): void {
  if (installed !== undefined) {
    if (installed === root) return;
    throw new PiDurableSDKError("This process already loads another Pi Durable SDK copy.");
  }
  installed = root;
  const parentURL = pathToFileURL(join(root, "package.json")).href;
  registerHooks({
    resolve(specifier, context, nextResolve) {
      const name = sdkPackage(specifier);
      if (!name) return nextResolve(specifier, context);
      const resolved = nextResolve(specifier, { ...context, parentURL });
      if (resolved.url.startsWith("file:")) inside(root, fileURLToPath(resolved.url), name);
      return resolved;
    },
  });
}

function present(root: string, name: string): string {
  return dirname(inside(root, join(root, "node_modules", name, "package.json"), name));
}

function inside(root: string, path: string, name: string): string {
  const real = realpathSync(path);
  if (!real.startsWith(join(root, "node_modules") + sep)) {
    throw new PiDurableSDKError(`${name} resolved outside Pi Durable's SDK (${real}).`);
  }
  return real;
}

/**
 * Before the runtime is imported: with `piDurable` (always, from the Woven server), this
 * process loads that machine's Pi Durable SDK copy and runs its Claude binary. Without it
 * (tests, a checkout), bots keep their own development dependencies.
 */
export async function usePiDurableSDK(
  config: RuntimeConfig,
  log: (line: string) => void = (line) => console.error(line),
): Promise<RuntimeConfig> {
  if (!config.piDurable) return config;
  const sdk = await resolvePiDurableSDK(config.piDurable);
  loadSDKFrom(sdk.root);
  log(`Pi Durable SDK: ${sdk.generation} (${sdk.root})`);
  return { ...config, claude: { executable: sdk.claudeExecutable } };
}
