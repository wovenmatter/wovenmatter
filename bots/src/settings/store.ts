import { mkdir, open, readFile, rename, unlink } from "node:fs/promises";
import { dirname } from "node:path";
import { z } from "zod";
import { ConfigError, type RawSettings, settingsSchema } from "../config.ts";

/** Write `text` to `path` atomically (temp file, fsync, rename), mode 0600. */
export async function writePrivateFile(path: string, text: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${Date.now()}.tmp`;
  try {
    const file = await open(temporary, "wx", 0o600);
    try {
      await file.writeFile(text);
      await file.sync();
    } finally {
      await file.close();
    }
    await rename(temporary, path);
  } finally {
    await unlink(temporary).catch(() => {});
  }
}

export function parseSettings(input: unknown, source = "settings"): RawSettings {
  const result = settingsSchema.safeParse(input);
  if (!result.success) {
    throw new ConfigError(`invalid ${source}:\n${z.prettifyError(result.error)}`);
  }
  return result.data;
}

/**
 * The runtime's own settings file (`settings.json`): read once at start, then every change is a
 * serialized read-modify-write so concurrent edits (profiles, title model) never lose each other.
 * Without a path (tests) the settings live in memory only.
 */
export class SettingsStore {
  #current: RawSettings;
  readonly #path: string | undefined;
  #queue: Promise<unknown> = Promise.resolve();

  private constructor(current: RawSettings, path: string | undefined) {
    this.#current = current;
    this.#path = path;
  }

  static memory(input: unknown = {}): SettingsStore {
    return new SettingsStore(parseSettings(input), undefined);
  }

  static async open(path: string): Promise<SettingsStore> {
    let text: string | undefined;
    try {
      text = await readFile(path, "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    const settings = parseSettings(text === undefined ? {} : JSON.parse(text), path);
    const store = new SettingsStore(settings, path);
    if (text === undefined) await store.update((value) => value);
    return store;
  }

  get current(): RawSettings {
    return this.#current;
  }

  update(change: (current: RawSettings) => RawSettings): Promise<RawSettings> {
    const run = this.#queue.then(async () => {
      const next = parseSettings(change(this.#current));
      if (this.#path) await writePrivateFile(this.#path, `${JSON.stringify(next, null, 2)}\n`);
      this.#current = next;
      return next;
    });
    this.#queue = run.catch(() => {});
    return run;
  }
}
