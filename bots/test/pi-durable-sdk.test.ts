import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { realpathSync } from "node:fs";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ConfigError } from "../src/config.ts";
import { verifyHelper } from "../src/environment/images.ts";
import { PI_DURABLE_SDK_PACKAGES } from "../src/pi-durable-sdk.ts";
import { tempDir } from "./helpers.ts";
import { testConfig } from "./runtime.ts";

const run = promisify(execFile);
const PROBE = fileURLToPath(new URL("./pi-durable-probe.ts", import.meta.url));
// Pi Durable as Woven Matter bundles it: its own selection code decides which copy bots load.
const BUNDLE = realpathSync(fileURLToPath(new URL("../../default-agent/", import.meta.url)));
const CLAUDE = `claude-agent-sdk-${process.platform}-${process.arch}`;

interface Probe {
  executable: string | null;
  resolved: string[];
  copies: string[];
  helper: Record<string, string>;
}

/** Pi Durable's fingerprint of its bundle, which an update generation must carry. */
async function bundleBase(): Promise<string> {
  const management = (await import(pathToFileURL(join(BUNDLE, "src/sdk-management.mjs")).href)) as {
    resolveSDKRuntime(options: { directory: string }): Promise<{ generation: string }>;
  };
  // A directory with no update selects the bundle itself, named by that fingerprint.
  const empty = join(realpathSync(tmpdir()), `pi-durable-base-${randomUUID()}`);
  return (await management.resolveSDKRuntime({ directory: empty })).generation.replace(/^bundled-/, "");
}

/** An update generation as `updateSDK` leaves it, with marker packages instead of the real SDK. */
async function installGeneration(
  directory: string,
  label: string,
  { omit = [] as string[], activate = true } = {},
): Promise<string> {
  const base = await bundleBase();
  const generation = randomUUID();
  const root = join(directory, "sdk-runtime", "generations", generation);
  await mkdir(join(root, "src"), { recursive: true, mode: 0o700 });
  await writeFile(join(root, "src/main-runtime.mjs"), "");
  await writeFile(join(root, "package.json"), "{}");
  await writeFile(join(root, "woven-sdk-generation.json"), JSON.stringify({ base, generation }));
  // pi-telemetry: in the copy, but the helper carries it only if its imports reach it.
  for (const name of [...PI_DURABLE_SDK_PACKAGES, "@earendil-works/pi-telemetry"].filter((name) => !omit.includes(name))) {
    const dir = join(root, "node_modules", name);
    await mkdir(dir, { recursive: true });
    const exports = Object.fromEntries([".", "./models", "./context", "./storage/sqlite"].map((key) => [key, "./index.js"]));
    await writeFile(join(dir, "package.json"), JSON.stringify({ name, version: "9.9.9", type: "module", exports }));
    await writeFile(join(dir, "index.js"), `export const copy = ${JSON.stringify(`${label}:${name}`)};\n`);
  }
  const binary = join(root, "node_modules/@anthropic-ai", CLAUDE);
  await mkdir(binary, { recursive: true });
  await writeFile(join(binary, "package.json"), JSON.stringify({ name: `@anthropic-ai/${CLAUDE}`, version: "9.9.9" }));
  await writeFile(join(binary, "claude"), "#!/bin/sh\n", { mode: 0o755 });
  if (activate) {
    await writeFile(join(directory, "sdk-runtime", "active.json"), JSON.stringify({ base, generation }));
  }
  return realpathSync(root);
}

/**
 * Packages shaped like what the in-container helper imports (`bots/helper/agent.mjs`):
 * chord/context, pi-durable/env (needing pi-schema) and pi-durable/env/node (needing a nested
 * dependency whose top-level copy is a different, unusable version).
 */
async function helperPackages(root: string): Promise<void> {
  const write = async (dir: string, manifest: object, files: Record<string, string>) => {
    await rm(dir, { recursive: true, force: true });
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "package.json"), JSON.stringify({ type: "module", ...manifest }));
    for (const [name, text] of Object.entries(files)) {
      await mkdir(join(dir, name, ".."), { recursive: true });
      await writeFile(join(dir, name), text);
    }
  };
  const modules = join(root, "node_modules");
  await write(join(modules, "@earendil-works/chord"), { name: "@earendil-works/chord", version: "9.9.9", exports: { "./context": "./dist/context.js" } }, {
    "dist/context.js": "export const BACKGROUND_CONTEXT = {};\nexport function withAbortSignal() {}\n",
    "dist/context.js.map": "{}",
    "dist/context.d.ts": "",
    "README.md": "",
  });
  await write(
    join(modules, "@earendil-works/pi-durable"),
    {
      name: "@earendil-works/pi-durable",
      version: "9.9.9",
      dependencies: { "@earendil-works/pi-schema": "2.0.0", "nested-dep": "1.0.0" },
      exports: { "./env": "./dist/env.js", "./env/node": "./dist/node.js" },
    },
    {
      "dist/env.js": 'import { schema } from "@earendil-works/pi-schema";\nexport class ExecutionError {}\nexport class FileError { static schema = schema; }\n',
      "dist/node.js": 'import { nested } from "nested-dep";\nexport class NodeExecutionEnv { static nested = nested; }\n',
    },
  );
  await write(join(modules, "@earendil-works/pi-schema"), { name: "@earendil-works/pi-schema", version: "2.0.0", exports: "./index.js" }, {
    "index.js": "export const schema = 1;\n",
  });
  await write(join(modules, "@earendil-works/pi-durable/node_modules/nested-dep"), { name: "nested-dep", version: "1.0.0", exports: "./index.js" }, {
    "index.js": "export const nested = 1;\n",
  });
  await write(join(modules, "nested-dep"), { name: "nested-dep", version: "0.1.0", exports: "./index.js" }, { "index.js": "export const other = 1;\n" });
  await write(join(modules, "unrelated"), { name: "unrelated", version: "1.0.0" }, { "index.js": "" });
}

/** The JSON a Woven server writes (without the paths the runtime derives). */
function runtimeJSON(dataDir: string, piDurable: Record<string, string>): string {
  const { paths: _paths, ...raw } = testConfig(dataDir, { piDurable });
  return JSON.stringify(raw);
}

async function probe(config: string, ...imports: string[]): Promise<Probe> {
  const { stdout } = await run(process.execPath, [PROBE, config, ...imports], { cwd: fileURLToPath(new URL("..", import.meta.url)) });
  return JSON.parse(stdout) as Probe;
}

const IMPORTS = [
  "@earendil-works/pi-durable",
  "@earendil-works/pi-ai",
  "@earendil-works/pi-ai/models",
  "@earendil-works/chord/context",
  "@anthropic-ai/claude-agent-sdk",
];

describe("bots run Pi Durable's SDK copy", () => {
  let dir: { path: string; cleanup: () => Promise<void> };
  let directory: string;
  let config: string;

  beforeEach(async () => {
    dir = await tempDir();
    directory = join(dir.path, "default-agent");
    await mkdir(directory, { mode: 0o700 });
    config = join(dir.path, "runtime.json");
    await writeFile(config, runtimeJSON(join(dir.path, "data"), { bundle: BUNDLE, directory }));
  });
  afterEach(async () => {
    await dir.cleanup();
  });

  it("loads the active SDK update and its Claude binary", async () => {
    const root = await installGeneration(directory, "update");
    const result = await probe(config, ...IMPORTS);
    expect(result.copies).toEqual(IMPORTS.map((name) => `update:${name.replace(/^(@[^/]+\/[^/]+).*$/, "$1")}`));
    expect(result.resolved.length).toBe(IMPORTS.length);
    for (const url of result.resolved) expect(fileURLToPath(url).startsWith(join(root, "node_modules") + sep)).toBe(true);
    expect(result.executable).toBe(join(root, "node_modules/@anthropic-ai", CLAUDE, "claude"));
  });

  it("gives the in-container helper the package closure it imports from that copy", async () => {
    const root = await installGeneration(directory, "update");
    await helperPackages(root);
    // Node's resolution from the copy: pi-schema is new, nested-dep is nested under pi-durable
    // (a different version sits at the top), and pi-telemetry is no longer imported.
    expect((await probe(config, "helper")).helper).toEqual({
      "@earendil-works/chord": "9.9.9",
      "@earendil-works/pi-durable": "9.9.9",
      "@earendil-works/pi-schema": "2.0.0",
      "@earendil-works/pi-durable/node_modules/nested-dep": "1.0.0",
    });
    await verifyHelper(join(root, "node_modules") + sep);
  });

  it("refuses a helper whose imports do not load from the copy", async () => {
    const root = await installGeneration(directory, "update");
    await helperPackages(root);
    await rm(join(root, "node_modules/@earendil-works/pi-durable/node_modules"), { recursive: true });
    // The top-level nested-dep lacks what pi-durable/env/node imports from its own copy.
    await expect(verifyHelper(join(root, "node_modules") + sep)).rejects.toThrow(/helper/);
  });

  it("moves to the next update after a restart, once the replaced copy is gone", async () => {
    const first = await installGeneration(directory, "first");
    expect((await probe(config, "@earendil-works/pi-ai")).copies).toEqual(["first:@earendil-works/pi-ai"]);
    const second = await installGeneration(directory, "second");
    await rm(first, { recursive: true, force: true });
    const result = await probe(config, "@earendil-works/pi-ai", "@anthropic-ai/claude-agent-sdk");
    expect(result.copies).toEqual(["second:@earendil-works/pi-ai", "second:@anthropic-ai/claude-agent-sdk"]);
    expect(result.executable).toBe(join(second, "node_modules/@anthropic-ai", CLAUDE, "claude"));
  });

  it("refuses to start on a copy missing an SDK package rather than use bots' own", async () => {
    await installGeneration(directory, "partial", { omit: ["@earendil-works/chord"] });
    // Pi Durable itself still selects this copy (it checks only its manifest), so bots must too.
    await expect(probe(config, "@earendil-works/pi-ai")).rejects.toThrow(/@earendil-works\/chord/);
  });

  it("refuses a Pi Durable bundle that is not there", async () => {
    await writeFile(config, runtimeJSON(join(dir.path, "data"), { bundle: join(dir.path, "missing"), directory }));
    await expect(probe(config, "@earendil-works/pi-ai")).rejects.toThrow(/could not be found/);
  });

  it("takes the Claude binary from Pi Durable, never alongside it", () => {
    expect(() =>
      testConfig("/d", { piDurable: { bundle: BUNDLE, directory }, claude: { executable: "/x/claude" } }),
    ).toThrow(ConfigError);
    expect(() => testConfig("/d", { piDurable: { bundle: "default-agent", directory } })).toThrow(ConfigError);
    expect(() => testConfig("/d", { piDurable: { bundle: BUNDLE, directory, extra: 1 } })).toThrow(ConfigError);
  });
});
