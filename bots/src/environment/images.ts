import { createHash, randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import type { DockerEngineAPI } from "./engine-api.ts";
import { createTar, directoryEntries, type TarEntry } from "./tar.ts";

/** bots/image and bots/helper, from bots/src/environment. */
export const IMAGE_DIR = fileURLToPath(new URL("../../image/", import.meta.url));
export const HELPER_DIR = fileURLToPath(new URL("../../helper/", import.meta.url));
export const NODE_MODULES_DIR = fileURLToPath(new URL("../../node_modules/", import.meta.url));

/** Where the helper volume mounts in every bot container. */
export const HELPER_MOUNT = "/opt/woven-bot";
export const HELPER_LABEL = "woven.bots.helper";
const COMPLETE = ".complete";

/** The packages the in-container env agent imports, copied from the runtime's own install. */
const HELPER_PACKAGES = [
  "@earendil-works/pi-durable",
  "@earendil-works/chord",
  "@earendil-works/pi-telemetry",
] as const;

const digest = (data: Buffer) => createHash("sha256").update(data).digest("hex").slice(0, 16);

/** `name` without a tag gets the build context's content hash; a tagged name is used as is. */
export function imageTag(name: string, context: Buffer): string {
  const last = name.slice(name.lastIndexOf("/") + 1);
  return last.includes(":") ? name : `${name}:${digest(context)}`;
}

export async function imageContext(dir = IMAGE_DIR): Promise<Buffer> {
  return createTar(await directoryEntries(dir));
}

/** The helper's files: its scripts and the runtime packages they import (no maps or typings). */
export async function helperArchive(
  helperDir = HELPER_DIR,
  nodeModules = NODE_MODULES_DIR,
): Promise<{ readonly tar: Buffer; readonly hash: string }> {
  const entries: TarEntry[] = await directoryEntries(helperDir, {
    include: (path) => !path.includes("/") && path.endsWith(".mjs"),
  });
  for (const name of HELPER_PACKAGES) {
    entries.push(
      ...(await directoryEntries(`${nodeModules}${name}`, {
        into: `node_modules/${name}`,
        include: (path) =>
          path === "package.json" ||
          path === "LICENSE" ||
          (path.startsWith("dist") && !path.endsWith(".map") && !path.endsWith(".d.ts")),
      })),
    );
  }
  const body = createTar(entries);
  const hash = digest(body);
  // The marker goes last: a volume holding it holds everything before it.
  const tar = createTar([...entries, { path: COMPLETE, data: Buffer.from(hash) }]);
  return { tar, hash };
}

export function helperVolumeName(hash: string): string {
  return `woven-bots-helper-${hash}`;
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
): Promise<string> {
  const context = await imageContext(dir);
  const tag = imageTag(name, context);
  if (await engine.imageExists(tag)) return tag;
  // A missing explicitly tagged image is built from the same context under that tag.
  log(`building bot image ${tag} (the first build takes several minutes)`);
  await engine.build(context, [tag], { log: () => {} });
  log(`built bot image ${tag}`);
  return tag;
}

/**
 * The read-only helper volume for this runtime install, filled through a short-lived container of
 * the bot image (the archive API needs a container to extract into).
 */
export async function ensureHelperVolume(
  engine: DockerEngineAPI,
  image: string,
  labels: Record<string, string>,
  archive?: { readonly tar: Buffer; readonly hash: string },
): Promise<string> {
  const { tar, hash } = archive ?? (await helperArchive());
  const volume = helperVolumeName(hash);
  if (!(await engine.volumeExists(volume))) {
    await engine.createVolume(volume, { ...labels, [HELPER_LABEL]: volume });
  }
  const filler = `woven-bots-helper-fill-${randomUUID().slice(0, 8)}`;
  await engine.createContainer(filler, {
    Image: image,
    User: "root",
    Entrypoint: ["true"],
    Cmd: [],
    Labels: { ...labels, "woven.bots.temporary": "helper" },
    HostConfig: {
      Mounts: [{ Type: "volume", Source: volume, Target: HELPER_MOUNT }],
      NetworkMode: "none",
    },
  });
  try {
    if (!(await engine.pathExists(filler, `${HELPER_MOUNT}/${COMPLETE}`))) {
      await engine.putArchive(filler, HELPER_MOUNT, tar);
    }
  } finally {
    await engine.removeContainer(filler).catch(() => {});
  }
  return volume;
}
