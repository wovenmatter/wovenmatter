// Bots run on this machine's Pi Durable SDK copy, never on one of their own: the copy Pi
// Durable's SDK update made current (`<directory>/sdk/current`, see default-agent/src/sdk.mjs),
// or else the one bundled with Woven Matter. Every SDK package resolves from that copy. One SDK
// update covers both; the server restarts bots after it.
import { accessSync, constants, existsSync, realpathSync } from "node:fs";
import { registerHooks } from "node:module";
import { basename, dirname, isAbsolute, join, sep } from "node:path";
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
  /** Pi Durable's data folder on this machine, which holds `sdk/current`. */
  readonly directory: string;
}

export interface PiDurableSDK {
  /** The copy: a directory whose `node_modules` holds every SDK package. */
  readonly root: string;
  /** An update's folder name, or `bundled`. */
  readonly generation: string;
  /** That copy's Claude Agent SDK binary. */
  readonly claudeExecutable: string;
}

export class PiDurableSDKError extends Error {}

/** The SDK package a bare specifier names, if it names one. */
export function sdkPackage(specifier: string): string | undefined {
  return PI_DURABLE_SDK_PACKAGES.find((name) => specifier === name || specifier.startsWith(name + "/"));
}

/** The copy Pi Durable runs on this machine: its current SDK update, or the bundled one. */
export async function resolvePiDurableSDK(
  location: PiDurableLocation,
  { platform = process.platform, arch = process.arch }: { platform?: string; arch?: string } = {},
): Promise<PiDurableSDK> {
  if (!isAbsolute(location.bundle) || !isAbsolute(location.directory)) {
    throw new PiDurableSDKError("The Pi Durable location must be absolute.");
  }
  const current = join(location.directory, "sdk", "current");
  const updated = existsSync(join(current, "node_modules"));
  const root = updated ? current : location.bundle;
  try {
    const sdk = piDurableSDKAt(root, { platform, arch });
    return { ...sdk, generation: updated ? basename(sdk.root) : "bundled" };
  } catch (error) {
    throw new PiDurableSDKError(`Pi Durable's SDK could not be found in ${root}: ${(error as Error).message}`);
  }
}

/** The SDK copy at `root`, if bots can run on it: every SDK package and the Claude binary. */
export function piDurableSDKAt(
  root: string,
  { platform = process.platform, arch = process.arch }: { platform?: string; arch?: string } = {},
): { root: string; claudeExecutable: string } {
  const real = realpathSync(root);
  // Every package must be in this copy, or bots would not run what Pi Durable runs.
  for (const name of PI_DURABLE_SDK_PACKAGES) present(real, name);
  return { root: real, claudeExecutable: claudeExecutable(real, platform, arch) };
}

/** The Claude binary in `root`: the glibc package, or the musl one. */
export function claudeExecutable(root: string, platform: string = process.platform, arch: string = process.arch): string {
  for (const name of [`claude-agent-sdk-${platform}-${arch}`, `claude-agent-sdk-${platform}-${arch}-musl`]) {
    try {
      const executable = join(present(root, `@anthropic-ai/${name}`), "claude");
      accessSync(executable, constants.X_OK);
      return executable;
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
 * Before the runtime is imported: with `piDurable` (always, from the server), this process loads
 * this machine's Pi Durable SDK copy and runs its Claude binary. Without it (tests, a checkout),
 * bots keep their own development dependencies.
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
