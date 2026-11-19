// Bots as they ship and start: `node src/cli.ts serve` (or `verify-sdk`, which Pi Durable's SDK
// update runs before it activates a copy) in the layout `remote/host/prune-bots-sdk.py` leaves,
// against Pi Durable's real bundled SDK copy. Every module the process resolves is recorded.
import { type ChildProcess, execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { PI_DURABLE_SDK_PACKAGES } from "../src/pi-durable-sdk.ts";
import { testConfig } from "./runtime.ts";

const run = promisify(execFile);
const BOTS = realpathSync(fileURLToPath(new URL("..", import.meta.url)));
const BUNDLE = realpathSync(join(BOTS, "../default-agent"));
const BUNDLE_MODULES = join(BUNDLE, "node_modules") + sep;
const RECORDER = join(BOTS, "test/resolution-recorder.mjs");
const PRUNER = join(BOTS, "../remote/host/prune-bots-sdk.py");
const CLAUDE = `claude-agent-sdk-${process.platform}-${process.arch}`;

// The bots test run installs Pi Durable's bundle (`run_bots_tests`, `scripts/test-ci.sh`).
// Without it these checks cannot run, and they must not pass by skipping.
if (!existsSync(join(BUNDLE_MODULES, "@earendil-works/pi-durable/package.json"))) {
  throw new Error(`Pi Durable's SDK is not installed in ${BUNDLE}; run npm ci --prefix default-agent.`);
}

/** What `prune-bots-sdk.py` keeps of bots' committed package graph (lockfile keys). */
async function kept(): Promise<string[]> {
  const source = [
    "import importlib.util, json, sys",
    "spec = importlib.util.spec_from_file_location('prune', sys.argv[1])",
    "prune = importlib.util.module_from_spec(spec); spec.loader.exec_module(prune)",
    "print(json.dumps(sorted(prune.kept(json.load(open(sys.argv[2]))))))",
  ].join("\n");
  const { stdout } = await run("python3", ["-c", source, PRUNER, join(BOTS, "package-lock.json")]);
  return JSON.parse(stdout) as string[];
}

/** The package a resolved file belongs to: the name after its last node_modules segment. */
function packageOf(path: string): string {
  const parts = path.split(sep);
  const at = parts.lastIndexOf("node_modules");
  const name = parts[at + 1] ?? "";
  return name.startsWith("@") ? `${name}/${parts[at + 2]}` : name;
}

const isSDK = (name: string) =>
  (PI_DURABLE_SDK_PACKAGES as readonly string[]).includes(name) || name.startsWith("@anthropic-ai/claude-agent-sdk-");

describe("bots in their shipped layout on Pi Durable's bundled SDK", () => {
  let scratch: string;
  let shipped: string;
  let keep: string[];

  beforeAll(async () => {
    scratch = join(realpathSync(tmpdir()), `woven-bots-shipped-${randomUUID()}`);
    shipped = join(scratch, "bots");
    await mkdir(shipped, { recursive: true });
    // What prepare-bots.sh and the host bundle ship, with only the packages the pruner keeps.
    for (const name of ["src", "helper", "image", "package.json", "package-lock.json"]) {
      await cp(join(BOTS, name), join(shipped, name), { recursive: true });
    }
    keep = await kept();
    expect(keep.length).toBeGreaterThan(0);
    for (const key of keep) {
      const from = join(BOTS, key);
      await cp(from, join(shipped, key), {
        recursive: true,
        // Nested packages are lockfile keys of their own, kept or not.
        filter: (source) => !source.slice(from.length).split(sep).includes("node_modules"),
      });
    }
  });
  afterAll(async () => {
    await rm(scratch, { recursive: true, force: true });
  });

  /** Every file the process resolved, checked: nothing of the SDK came from bots' folder. */
  function checkResolutions(log: string): string[] {
    const files = readFileSync(log, "utf8").split("\n").filter(Boolean).map((url) => fileURLToPath(url));
    const ownModules = join(shipped, "node_modules") + sep;
    const allowed = new Set(keep.map((key) => packageOf(join(shipped, key, "package.json"))));
    expect(files.length).toBeGreaterThan(50);
    for (const file of files) {
      const name = packageOf(file);
      if (file.startsWith(ownModules)) {
        // Only what the pruner keeps, and never an SDK package, loads from bots' own folder.
        expect(allowed.has(name), file).toBe(true);
        expect(isSDK(name), file).toBe(false);
      } else if (file.split(sep).includes("node_modules")) {
        expect(file.startsWith(BUNDLE_MODULES), file).toBe(true);
      } else {
        // Bots' own sources, or Pi Durable's code that picks its copy (sdk-management.mjs).
        expect(file.startsWith(shipped + sep) || file.startsWith(join(BUNDLE, "src") + sep), file).toBe(true);
      }
      if (isSDK(name)) expect(file.startsWith(BUNDLE_MODULES), file).toBe(true);
    }
    return files;
  }

  it("starts the real `cli.ts serve` with every SDK module from Pi Durable's copy", async () => {
    const log = join(scratch, `serve-${randomUUID()}.log`);
    const directory = join(scratch, `default-agent-${randomUUID()}`);
    await mkdir(directory, { mode: 0o700 });
    const { paths: _paths, ...raw } = testConfig(join(scratch, `data-${randomUUID()}`), {
      piDurable: { bundle: BUNDLE, directory },
    });
    const config = join(scratch, `runtime-${randomUUID()}.json`);
    await writeFile(config, JSON.stringify(raw));
    const child: ChildProcess = spawn(
      process.execPath,
      ["--import", RECORDER, join(shipped, "src/cli.ts"), "serve", "--config", config],
      { cwd: shipped, env: { ...process.env, NODE_ENV: "production", WOVEN_RESOLUTION_LOG: log }, stdio: ["ignore", "pipe", "pipe"] },
    );
    let output = "";
    const exited = new Promise<number | null>((resolve) => child.once("exit", (code) => resolve(code)));
    try {
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`bots did not start:\n${output}`)), 20_000);
        const read = (chunk: Buffer) => {
          output += chunk.toString("utf8");
          if (output.includes("bots runtime listening on")) {
            clearTimeout(timer);
            // `serve` installs its signal handlers right after it starts listening.
            setTimeout(resolve, 500);
          }
        };
        child.stdout?.on("data", read);
        child.stderr?.on("data", read);
        void exited.then((code) => {
          clearTimeout(timer);
          reject(new Error(`bots exited ${code} before listening:\n${output}`));
        });
      });
    } finally {
      child.kill("SIGTERM");
    }
    expect(await exited).toBe(0);
    expect(output).toContain("Pi Durable SDK: bundled-");
    const files = checkResolutions(log);
    // The whole graph loaded, from Pi Durable's copy: providers, tools, storage.
    for (const path of ["@earendil-works/pi-ai/", "@earendil-works/pi-durable/", "@earendil-works/chord/"]) {
      expect(files.some((file) => file.startsWith(BUNDLE_MODULES + path)), path).toBe(true);
    }
    expect(files.some((file) => file.startsWith(join(shipped, "node_modules/ws") + sep))).toBe(true);
  }, 40_000);

  it("verifies the bundled copy with `cli.ts verify-sdk`: runtime, Claude SDK and helper", async () => {
    const log = join(scratch, `verify-${randomUUID()}.log`);
    await run(process.execPath, ["--import", RECORDER, join(shipped, "src/cli.ts"), "verify-sdk", BUNDLE], {
      cwd: shipped,
      env: { ...process.env, WOVEN_RESOLUTION_LOG: log },
    });
    const files = checkResolutions(log);
    expect(files.some((file) => file.startsWith(join(BUNDLE_MODULES, "@anthropic-ai/claude-agent-sdk") + sep))).toBe(true);
  }, 40_000);
});

describe("verify-sdk refuses a copy bots cannot run", () => {
  // A copy of Pi Durable's SDK packages that a test can change. It lives below bots'
  // node_modules so the packages' own dependencies still resolve from an installed tree.
  const copy = join(BOTS, "node_modules/.cache", `woven-sdk-copy-${randomUUID()}`);
  const verify = () => run(process.execPath, [join(BOTS, "src/cli.ts"), "verify-sdk", copy], { cwd: BOTS });

  beforeAll(async () => {
    const names = [
      ...PI_DURABLE_SDK_PACKAGES.filter((name) => name !== "@earendil-works/pi-coding-agent"),
      "@earendil-works/pi-schema",
      "@earendil-works/pi-telemetry",
      "@earendil-works/pi-codemode",
    ];
    for (const name of names) await cp(join(BUNDLE_MODULES, name), join(copy, "node_modules", name), { recursive: true });
    // Bots never import pi-coding-agent; Pi Durable's update installs it with the rest.
    const coding = join(copy, "node_modules/@earendil-works/pi-coding-agent");
    await mkdir(coding, { recursive: true });
    await writeFile(join(coding, "package.json"), JSON.stringify({ name: "@earendil-works/pi-coding-agent", version: "1.0.0" }));
    const binary = join(copy, "node_modules/@anthropic-ai", CLAUDE);
    await mkdir(binary, { recursive: true });
    await writeFile(join(binary, "package.json"), JSON.stringify({ name: `@anthropic-ai/${CLAUDE}`, version: "1.0.0" }));
    await writeFile(join(binary, "claude"), "#!/bin/sh\n", { mode: 0o755 });
  }, 60_000);
  afterAll(async () => {
    await rm(copy, { recursive: true, force: true });
  });

  /** Runs `body` with `path` rewritten by `change`, then restores it. */
  async function changed(path: string, change: (text: string) => string, body: () => Promise<void>) {
    const original = await readFile(path, "utf8");
    await writeFile(path, change(original));
    try {
      await body();
    } finally {
      await writeFile(path, original);
    }
  }
  const withoutExport = (subpath: string) => (text: string) => {
    const manifest = JSON.parse(text) as { exports: Record<string, unknown> };
    delete manifest.exports[subpath];
    return JSON.stringify(manifest);
  };

  it("accepts the copy as installed", async () => {
    await verify();
  }, 30_000);

  it("refuses a copy without a subpath bots import (pi-durable/tools)", async () => {
    await changed(join(copy, "node_modules/@earendil-works/pi-durable/package.json"), withoutExport("./tools"), async () => {
      await expect(verify()).rejects.toThrow(/tools/);
    });
  }, 30_000);

  it("refuses a copy without an export bots import (pi-ai's xaiProvider)", async () => {
    // `./providers/*` maps to dist/providers/*.js.
    await changed(join(copy, "node_modules/@earendil-works/pi-ai/dist/providers/xai.js"), () => "export {};\n", async () => {
      await expect(verify()).rejects.toThrow(/xaiProvider/);
    });
  }, 30_000);

  it("refuses a copy without the Claude Agent SDK's query", async () => {
    const sdk = JSON.parse(await readFile(join(copy, "node_modules/@anthropic-ai/claude-agent-sdk/package.json"), "utf8")) as {
      exports: Record<string, string | { import?: string; default?: string }>;
    };
    const entry = sdk.exports["."];
    const file = join(
      copy,
      "node_modules/@anthropic-ai/claude-agent-sdk",
      typeof entry === "string" ? entry : (entry?.import ?? entry?.default ?? ""),
    );
    await changed(file, () => "export const other = 1;\n", async () => {
      await expect(verify()).rejects.toThrow(/query/);
    });
  }, 30_000);

  it("refuses a copy without the Claude binary for this machine", async () => {
    const binary = join(copy, "node_modules/@anthropic-ai", CLAUDE, "claude");
    await rm(binary);
    try {
      await expect(verify()).rejects.toThrow(/no Claude binary/);
    } finally {
      await writeFile(binary, "#!/bin/sh\n", { mode: 0o755 });
    }
  }, 30_000);

  it("refuses a copy the in-container helper cannot load (pi-durable/env/node)", async () => {
    // Only the helper imports this subpath; bots on the host never do.
    await changed(join(copy, "node_modules/@earendil-works/pi-durable/package.json"), withoutExport("./env/node"), async () => {
      await expect(verify()).rejects.toThrow(/helper/);
    });
  }, 30_000);
});
