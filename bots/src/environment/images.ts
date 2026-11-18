import { createHash, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { sdkNodeModules } from "../pi-durable-sdk.ts";
import type { DockerEngineAPI } from "./engine-api.ts";
import { createTar, directoryEntries, readTar as readTarEntries, type TarEntry } from "./tar.ts";

/** bots/image and bots/helper, from bots/src/environment. */
export const IMAGE_DIR = fileURLToPath(new URL("../../image/", import.meta.url));
export const HELPER_DIR = fileURLToPath(new URL("../../helper/", import.meta.url));
export const NODE_MODULES_DIR = fileURLToPath(new URL("../../node_modules/", import.meta.url));
const SOURCE_ROOT = fileURLToPath(new URL("../../../", import.meta.url));

/** Where each bot reaches its selected helper: a link in its container to a shared directory. */
export const HELPER_MOUNT = "/opt/woven-bot";
/** Where each bot reaches its selected toolchain (Node, npm, Playwright, Chromium), likewise. */
export const TOOLCHAIN_PATH = "/opt/woven-toolchain";
/** The runtime's shared volume, mounted read-only in every bot: helper/<hash>, toolchain/<hash>. */
export const SHARED_VOLUME = "woven-bots-shared";
export const SHARED_MOUNT = "/opt/woven";
/** Legacy helper volumes (one per helper version, before the shared volume) carry this label. */
export const HELPER_LABEL = "woven.bots.helper";
export const SHARED_LABEL = "woven.bots.shared";
const COMPLETE = ".complete";
/** Where filler containers mount the shared volume, writable. */
const FILL = "/fill";
const TOOLCHAIN_DIR = "toolchain";

export const helperDir = (hash: string) => `${SHARED_MOUNT}/helper/${hash}`;
export const toolchainDir = (hash: string) => `${SHARED_MOUNT}/toolchain/${hash}`;

const execFileAsync = promisify(execFile);

const digest = (data: Buffer) => createHash("sha256").update(data).digest("hex").slice(0, 16);

/** A build context's content hash: an image's tag, and its shared directory's name. */
export const contentHash = digest;

/** `name` without a tag gets the build context's content hash; a tagged name is used as is. */
export function imageTag(name: string, context: Buffer): string {
  const last = name.slice(name.lastIndexOf("/") + 1);
  return last.includes(":") ? name : `${name}:${digest(context)}`;
}

/** The toolchain image's name next to the base image's: `repo-toolchain`, keeping any tag. */
export function toolchainImageName(name: string): string {
  const slash = name.lastIndexOf("/");
  const colon = name.indexOf(":", slash + 1);
  return colon === -1 ? `${name}-toolchain` : `${name.slice(0, colon)}-toolchain${name.slice(colon)}`;
}

/** The tag part of an image name (`repo:hash`), made safe as a directory name. */
export function tagHash(tag: string): string {
  const last = tag.slice(tag.lastIndexOf("/") + 1);
  const colon = last.indexOf(":");
  return (colon === -1 ? last : last.slice(colon + 1)).replace(/[^A-Za-z0-9_.-]/g, "_");
}

/** The base image's context: bots/image without toolchain/, whose changes must not move bots. */
export async function imageContext(dir = IMAGE_DIR): Promise<Buffer> {
  const entries = await directoryEntries(dir, {
    include: (path) => path !== TOOLCHAIN_DIR && !path.startsWith(`${TOOLCHAIN_DIR}/`),
  });
  return createTar(entries);
}

/** The toolchain image's context: bots/image/toolchain plus the npm tooling records it uses. */
export async function toolchainContext(dir = IMAGE_DIR, sourceRoot = SOURCE_ROOT): Promise<Buffer> {
  const entries = await directoryEntries(join(dir, TOOLCHAIN_DIR));
  // Signed app resources retain remote/npm-runtime; native host bundles put it
  // at the release root. Include the canonical records in the content hash so
  // a tooling refresh rebuilds the toolchain without maintaining another copy.
  const graph = existsSync(join(sourceRoot, "remote/npm-runtime")) ? "remote/npm-runtime" : "npm-runtime";
  for (const [source, target] of [
    ["harnesses/prepare-npm.mjs", "harnesses/prepare-npm.mjs"],
    ["harnesses/install-adapter.mjs", "harnesses/install-adapter.mjs"],
    ["harnesses/npm-version.json", "harnesses/npm-version.json"],
    [`${graph}/package.json`, "npm-runtime/package.json"],
    [`${graph}/package-lock.json`, "npm-runtime/package-lock.json"],
  ] as const) {
    entries.push({ path: `tooling/${target}`, data: await readFile(join(sourceRoot, source)) });
  }
  return createTar(entries);
}

/**
 * The helper's own imports of packages, verbatim from its scripts (`import ... from "pkg"`):
 * what the in-container env agent loads from the archive's node_modules.
 */
export async function helperImports(helperDir = HELPER_DIR): Promise<string[]> {
  const statements: string[] = [];
  for (const entry of await directoryEntries(helperDir, { include: (path) => !path.includes("/") && path.endsWith(".mjs") })) {
    const source = entry.data?.toString("utf8") ?? "";
    for (const match of source.matchAll(/^import\s+(?:[\w*{}\s,$]+?\s+from\s+)?(["'])([^"']+)\1;?/gm)) {
      const specifier = match[2] ?? "";
      if (!specifier.startsWith("node:") && !specifier.startsWith(".") && !specifier.startsWith("/")) statements.push(match[0]);
    }
  }
  return [...new Set(statements)];
}

// Runs as its own process: imports `source` as if it were a helper script at `<root>/helper.mjs`
// and prints every file Node resolved on the way (the module graph, through Node's resolution).
const TRACE = `
import { registerHooks } from "node:module";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
const { root, source } = JSON.parse(process.env.WOVEN_HELPER_TRACE);
const parentURL = pathToFileURL(join(root, "helper.mjs")).href;
const files = new Set();
registerHooks({
  resolve(specifier, context, nextResolve) {
    const resolved = nextResolve(specifier, context.parentURL?.startsWith("data:") ? { ...context, parentURL } : context);
    if (resolved.url.startsWith("file:")) files.add(fileURLToPath(resolved.url));
    return resolved;
  },
});
await import("data:text/javascript," + encodeURIComponent(source));
process.stdout.write(JSON.stringify([...files]));
`;

export class HelperPackagesError extends Error {}

/**
 * Every file the helper's imports load, resolved and linked by Node from a helper at `root`
 * (beside `root/node_modules`), in a separate process. A missing package or export fails here.
 */
export async function traceHelper(root: string, helperDir = HELPER_DIR): Promise<string[]> {
  const source = (await helperImports(helperDir)).join("\n");
  const env: NodeJS.ProcessEnv = { ...process.env, WOVEN_HELPER_TRACE: JSON.stringify({ root, source }) };
  delete env.NODE_OPTIONS;
  try {
    const { stdout } = await execFileAsync(process.execPath, ["--input-type=module", "--eval", TRACE], {
      cwd: root,
      env,
      maxBuffer: 16 * 1024 * 1024,
      timeout: 60_000,
    });
    return JSON.parse(stdout) as string[];
  } catch (error) {
    const stderr = String((error as { stderr?: unknown }).stderr ?? "").trim();
    throw new HelperPackagesError(`The bot helper's packages do not load from ${root}: ${stderr.split("\n").slice(-3).join(" ") || (error as Error).message}`);
  }
}

/**
 * The packages (as `node_modules/...` paths under `root`, nested ones included) that hold the
 * files the helper's imports load from `root`: its package closure, as Node resolves it there.
 */
export async function helperPackages(root: string, helperDir = HELPER_DIR): Promise<string[]> {
  const modules = join(root, "node_modules") + sep;
  const packages = new Set<string>();
  for (const file of await traceHelper(root, helperDir)) {
    if (!file.startsWith(modules)) throw new HelperPackagesError(`The bot helper's import of ${file} is outside ${modules}.`);
    const rel = file.slice(root.length + 1).split(sep);
    const at = rel.lastIndexOf("node_modules");
    const name = rel[at + 1]?.startsWith("@") ? 2 : 1;
    packages.add(rel.slice(0, at + 1 + name).join("/"));
  }
  return [...packages].sort();
}

const closures = new Map<string, Promise<string[]>>();

/** What of a package the helper carries: no nested packages (each is its own), sources, maps, typings or docs. */
function carried(path: string): boolean {
  const parts = path.split("/");
  if (parts.includes("node_modules") || parts[0] === "docs") return false;
  // Node never strips types under node_modules, so TypeScript sources are never loaded there.
  return !/\.(map|md|ts|mts|cts|tsx)$/i.test(path);
}

/** The helper's files: its scripts and the package closure they import (no maps or typings). */
export async function helperArchive(
  helperDir = HELPER_DIR,
  nodeModules = sdkNodeModules() ?? NODE_MODULES_DIR,
): Promise<{ readonly tar: Buffer; readonly hash: string }> {
  const root = realpathSync(dirname(nodeModules));
  const key = `${helperDir}\0${root}`;
  let closure = closures.get(key);
  if (!closure) {
    closure = helperPackages(root, helperDir);
    closures.set(key, closure);
    closure.catch(() => closures.delete(key));
  }
  const entries: TarEntry[] = await directoryEntries(helperDir, {
    include: (path) => !path.includes("/") && path.endsWith(".mjs"),
  });
  for (const pkg of await closure) {
    entries.push(...(await directoryEntries(join(root, pkg), { into: pkg, include: carried })));
  }
  const body = createTar(entries);
  const hash = digest(body);
  // The marker goes last: a volume holding it holds everything before it.
  const tar = createTar([...entries, { path: COMPLETE, data: Buffer.from(hash) }]);
  return { tar, hash };
}

/**
 * Builds the helper archive from the SDK copy at `nodeModules`, unpacks it as a bot's helper
 * directory, and loads the helper's imports there: every one must resolve inside the archive.
 */
export async function verifyHelper(nodeModules: string, helperDir = HELPER_DIR): Promise<void> {
  const { tar } = await helperArchive(helperDir, nodeModules);
  const into = realpathSync(await mkdtemp(join(tmpdir(), "woven-bots-helper-")));
  try {
    for (const entry of readTarEntries(tar)) {
      const path = join(into, ...entry.path.split("/"));
      if (entry.directory) await mkdir(path, { recursive: true });
      else if (entry.data) {
        await mkdir(dirname(path), { recursive: true });
        await writeFile(path, entry.data, { mode: entry.mode ?? 0o644 });
      }
    }
    await helperPackages(into, helperDir);
  } finally {
    await rm(into, { recursive: true, force: true });
  }
}

/** What the bot image carries, read from its Dockerfile: the base and the pinned tools. */
export type ImageTools = { readonly base?: string; readonly node?: string; readonly playwright?: string };

export async function imageTools(dir = IMAGE_DIR): Promise<ImageTools> {
  const base = await readFile(join(dir, "Dockerfile"), "utf8").catch(() => "");
  const tools = await readFile(join(dir, TOOLCHAIN_DIR, "Dockerfile"), "utf8").catch(() => "");
  const arg = (name: string) => new RegExp(`^ARG ${name}=(\\S+)`, "m").exec(tools)?.[1];
  return { base: /^FROM (\S+)/m.exec(base)?.[1], node: arg("NODE_VERSION"), playwright: arg("PLAYWRIGHT_VERSION") };
}

/**
 * The bot image: present, or built through the Engine API from bots/image. Concurrent callers
 * share one build.
 */
export async function ensureImage(
  engine: DockerEngineAPI,
  name: string,
  log: (message: string) => void,
  dir = IMAGE_DIR,
  context?: Buffer,
): Promise<string> {
  context ??= await imageContext(dir);
  const tag = imageTag(name, context);
  if (await engine.imageExists(tag)) return tag;
  // A missing explicitly tagged image is built from the same context under that tag.
  log(`building bot image ${tag} (the first build takes several minutes)`);
  for (let attempt = 1; ; attempt += 1) {
    const output = new BuildOutputTail();
    try {
      await engine.build(context, [tag], { log: (line) => output.add(line) });
      break;
    } catch (error) {
      const tail = output.text();
      // The engine's error names only the failing step; the cause (apt's own message) is in the output.
      if (tail) log(`bot image ${tag} build output (last ${BUILD_OUTPUT_TAIL_BYTES / 1024} KB):\n${tail}`);
      if (attempt === 1 && TRANSIENT_FETCH.test(tail)) {
        log(`bot image ${tag} build could not fetch packages; retrying once`);
        continue;
      }
      // Keep the error's type (callers classify EngineError) and add the output's end.
      if (tail && error instanceof Error) error.message += `\n${tail.slice(-BUILD_ERROR_CAUSE_CHARS)}`;
      throw error;
    }
  }
  log(`built bot image ${tag}`);
  return tag;
}

/** How much build output a failed build keeps for the runtime log and the error. */
export const BUILD_OUTPUT_TAIL_BYTES = 64 * 1024;
const BUILD_ERROR_CAUSE_CHARS = 2000;
/** Package fetch failures that a second attempt can clear (DNS, connection, mirror sync). */
const TRANSIENT_FETCH =
  /Temporary failure resolving|Could not resolve|Failed to fetch|Unable to connect to|Could not connect to|Connection (timed out|reset|refused)|Hash Sum mismatch|File has unexpected size/;

/** The last BUILD_OUTPUT_TAIL_BYTES of build output, whole lines only. */
class BuildOutputTail {
  #lines: string[] = [];
  #bytes = 0;
  add(line: string): void {
    const kept = line.length > BUILD_OUTPUT_TAIL_BYTES ? line.slice(-BUILD_OUTPUT_TAIL_BYTES) : line;
    this.#lines.push(kept);
    this.#bytes += Buffer.byteLength(kept) + 1;
    while (this.#bytes > BUILD_OUTPUT_TAIL_BYTES && this.#lines.length > 1) {
      this.#bytes -= Buffer.byteLength(this.#lines.shift() ?? "") + 1;
    }
  }
  text(): string {
    return this.#lines.join("\n");
  }
}

/**
 * The shared volume's directory for this helper (helper/<hash>), filled through a short-lived
 * container of the bot image (the archive API needs a container to extract into). Directories are
 * immutable once complete, so bots running an older one are never disturbed.
 */
export async function ensureSharedHelper(
  engine: DockerEngineAPI,
  image: string,
  labels: Record<string, string>,
  archive?: { readonly tar: Buffer; readonly hash: string },
): Promise<string> {
  const { tar, hash } = archive ?? (await helperArchive());
  await ensureSharedVolume(engine, labels);
  const filler = `woven-bots-helper-fill-${randomUUID().slice(0, 8)}`;
  await engine.createContainer(filler, {
    Image: image,
    User: "root",
    Entrypoint: ["true"],
    Cmd: [],
    Labels: { ...labels, "woven.bots.temporary": "helper" },
    HostConfig: {
      Mounts: [{ Type: "volume", Source: SHARED_VOLUME, Target: FILL }],
      NetworkMode: "none",
    },
  });
  try {
    if (!(await engine.pathExists(filler, `${FILL}/helper/${hash}/${COMPLETE}`))) {
      const into = `helper/${hash}`;
      const entries = readTarEntries(tar).map((entry) => ({ ...entry, path: `${into}/${entry.path}` }));
      await engine.putArchive(filler, FILL, createTar([{ path: "helper", directory: true }, { path: into, directory: true }, ...entries]));
    }
  } finally {
    await engine.removeContainer(filler).catch(() => {});
  }
  return hash;
}

/**
 * The shared volume's directory for this toolchain (toolchain/<hash>): its image's
 * /opt/woven-toolchain, copied in by a short-lived container of that image and renamed into place
 * whole, with the completion marker inside.
 */
export async function ensureSharedToolchain(
  engine: DockerEngineAPI,
  image: string,
  labels: Record<string, string>,
  hash = tagHash(image),
): Promise<string> {
  await ensureSharedVolume(engine, labels);
  const filler = `woven-bots-toolchain-fill-${randomUUID().slice(0, 8)}`;
  const dir = `${FILL}/${TOOLCHAIN_DIR}/${hash}`;
  const stage = `${FILL}/${TOOLCHAIN_DIR}/.stage-${hash}-${randomUUID().slice(0, 8)}`;
  await engine.createContainer(filler, {
    Image: image,
    User: "root",
    Entrypoint: ["sh", "-c"],
    Cmd: [
      `set -e; [ -f ${dir}/${COMPLETE} ] && exit 0; mkdir -p ${stage}; cp -a ${TOOLCHAIN_PATH}/. ${stage}/; ` +
        `touch ${stage}/${COMPLETE}; rm -rf ${dir}; mv ${stage} ${dir}`,
    ],
    Labels: { ...labels, "woven.bots.temporary": "toolchain" },
    HostConfig: {
      Mounts: [{ Type: "volume", Source: SHARED_VOLUME, Target: FILL }],
      NetworkMode: "none",
    },
  });
  try {
    await engine.startContainer(filler);
    const code = await engine.waitContainer(filler);
    if (code !== 0) throw new Error(`copying the bot toolchain ${hash} exited ${code}`);
  } finally {
    await engine.removeContainer(filler).catch(() => {});
  }
  return hash;
}

async function ensureSharedVolume(engine: DockerEngineAPI, labels: Record<string, string>): Promise<void> {
  if (!(await engine.volumeExists(SHARED_VOLUME))) {
    await engine.createVolume(SHARED_VOLUME, { ...labels, [SHARED_LABEL]: "1" });
  }
}

/**
 * Remove shared directories no bot links to, keeping `keep` (this runtime's current ones), through
 * a short-lived container of `image`. Returns what was removed (helper/<hash>, toolchain/<hash>).
 */
export async function pruneShared(
  engine: DockerEngineAPI,
  image: string,
  labels: Record<string, string>,
  keep: ReadonlySet<string>,
): Promise<string[]> {
  if (!(await engine.volumeExists(SHARED_VOLUME))) return [];
  const name = `woven-bots-prune-${randomUUID().slice(0, 8)}`;
  const kept = [...keep].map((entry) => `'${entry.replace(/'/g, "")}'`).join(" ");
  await engine.createContainer(name, {
    Image: image,
    User: "root",
    Entrypoint: ["sh", "-c"],
    Cmd: [
      `cd ${FILL} || exit 0; for d in helper/* ${TOOLCHAIN_DIR}/* ${TOOLCHAIN_DIR}/.stage-*; do [ -e "$d" ] || continue; ` +
        `keep=0; for k in ${kept}; do [ "$d" = "$k" ] && keep=1; done; ` +
        `if [ $keep = 0 ]; then rm -rf "$d" && echo "$d"; fi; done`,
    ],
    Labels: { ...labels, "woven.bots.temporary": "prune" },
    HostConfig: {
      Mounts: [{ Type: "volume", Source: SHARED_VOLUME, Target: FILL }],
      NetworkMode: "none",
    },
  });
  try {
    await engine.startContainer(name);
    await engine.waitContainer(name);
    return (await engine.containerLogs(name)).split("\n").filter(Boolean);
  } finally {
    await engine.removeContainer(name).catch(() => {});
  }
}
