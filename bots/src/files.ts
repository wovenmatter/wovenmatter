import { mkdir, readdir } from "node:fs/promises";
import { join } from "node:path";
import type { RuntimeConfig } from "./config.ts";
import { BotEnvironment, INSTALLATION_LABEL } from "./environment/container.ts";
import { DockerEngineAPI } from "./environment/engine-api.ts";
import { openSharedDatabase } from "./storage/database.ts";
import { BotRegistry } from "./storage/registry.ts";

export type FilesAction = "export" | "import" | "remove";

/**
 * Each bot's files, for a transfer, while the runtime is stopped: `export` writes every bot's
 * storage volume out of the engine as `<dir>/<botId>.tar` (a bot that never ran a tool has none);
 * `import` puts those archives into this engine's volumes; `remove` deletes every container and
 * volume of this installation from the engine. Bots come from the bots folder's database.
 */
export async function botFiles(
  config: RuntimeConfig,
  action: FilesAction,
  dir: string | undefined,
  log: (message: string) => void = (message) => console.error(message),
): Promise<void> {
  const db = await openSharedDatabase(config.paths.database);
  try {
    const registry = new BotRegistry(db);
    await registry.createTables();
    const installationId = await registry.installationId();
    const ids = [...(await registry.list()), ...(await registry.listDeleted())].map((bot) => bot.id);
    const engine = new DockerEngineAPI(config.engine.socket);
    const env = new BotEnvironment({
      engine,
      kind: config.engine.kind,
      imageName: config.image.tag,
      memoryBytes: config.limits.botMemoryBytes,
      installationId,
      log,
    });
    try {
      if (action === "remove") {
        for (const id of ids) await env.purge(id);
        const label = `${INSTALLATION_LABEL}=${installationId}`;
        for (const container of await engine.listContainers(label)) {
          await engine.removeContainer(container.Id);
        }
        for (const volume of await engine.listVolumes(label)) await engine.removeVolume(volume);
        return;
      }
      if (!dir) throw new Error(`files ${action} needs --dir <folder>`);
      if (action === "export") {
        await mkdir(dir, { recursive: true, mode: 0o700 });
        for (const id of ids) {
          if (await env.exportFiles(id, join(dir, `${id}.tar`))) log(`bot ${id}: files written`);
        }
        return;
      }
      const known = new Set(ids);
      for (const name of await readdir(dir)) {
        const id = name.replace(/\.tar$/, "");
        if (!name.endsWith(".tar") || !known.has(id)) continue;
        await env.importFiles(id, join(dir, name));
        log(`bot ${id}: files read in`);
      }
    } finally {
      env.close();
    }
  } finally {
    await db.close();
  }
}
