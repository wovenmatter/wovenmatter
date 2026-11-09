import { readdir, readFile, stat } from "node:fs/promises";
import { join, relative, sep } from "node:path";

/** One archive member. Directories have no data. */
export type TarEntry = {
  readonly path: string;
  readonly data?: Buffer;
  readonly mode?: number;
  readonly directory?: boolean;
};

const BLOCK = 512;

function octal(value: number, length: number): string {
  return `${value.toString(8).padStart(length - 1, "0")}\0`;
}

function header(name: string, size: number, mode: number, type: string, prefix = ""): Buffer {
  const block = Buffer.alloc(BLOCK, 0);
  block.write(name, 0, 100, "utf8");
  block.write(octal(mode & 0o7777, 8), 100, 8, "ascii");
  block.write(octal(0, 8), 108, 8, "ascii"); // uid
  block.write(octal(0, 8), 116, 8, "ascii"); // gid
  block.write(octal(size, 12), 124, 12, "ascii");
  block.write(octal(0, 12), 136, 12, "ascii"); // mtime: fixed, so archives are reproducible
  block.write("        ", 148, 8, "ascii");
  block.write(type, 156, 1, "ascii");
  block.write("ustar\0", 257, 6, "ascii");
  block.write("00", 263, 2, "ascii");
  block.write(prefix, 345, 155, "utf8");
  let sum = 0;
  for (const byte of block) sum += byte;
  block.write(octal(sum, 7), 148, 7, "ascii");
  block[155] = 0x20;
  return block;
}

function pad(size: number): Buffer {
  const rest = size % BLOCK;
  return Buffer.alloc(rest ? BLOCK - rest : 0, 0);
}

/** A PAX record `"<len> path=<value>\n"`, whose length counts itself. */
function paxRecord(key: string, value: string): string {
  const body = ` ${key}=${value}\n`;
  let length = Buffer.byteLength(body) + 1;
  while (Buffer.byteLength(`${length}${body}`) !== length) length += 1;
  return `${length}${body}`;
}

/** A ustar archive (PAX headers for long paths). Owner is root; the reader keeps the modes. */
export function createTar(entries: readonly TarEntry[]): Buffer {
  const parts: Buffer[] = [];
  for (const entry of entries) {
    const path = entry.directory && !entry.path.endsWith("/") ? `${entry.path}/` : entry.path;
    const data = entry.directory ? Buffer.alloc(0) : (entry.data ?? Buffer.alloc(0));
    const mode = entry.mode ?? (entry.directory ? 0o755 : 0o644);
    const type = entry.directory ? "5" : "0";
    if (Buffer.byteLength(path) <= 100) {
      parts.push(header(path, data.length, mode, type));
    } else {
      const pax = Buffer.from(paxRecord("path", path));
      parts.push(header("PaxHeader", pax.length, 0o644, "x"), pax, pad(pax.length));
      parts.push(header(path.slice(-99).replace(/^\/+/, ""), data.length, mode, type));
    }
    if (data.length) parts.push(data, pad(data.length));
  }
  parts.push(Buffer.alloc(BLOCK * 2, 0));
  return Buffer.concat(parts);
}

/**
 * Files under `root`, as archive entries named relative to it (with `into` as a prefix), in a
 * stable order. `include` filters by relative path.
 */
export async function directoryEntries(
  root: string,
  options: { readonly into?: string; readonly include?: (path: string) => boolean } = {},
): Promise<TarEntry[]> {
  const out: TarEntry[] = [];
  const walk = async (dir: string): Promise<void> => {
    const names = (await readdir(dir)).sort();
    for (const name of names) {
      const full = join(dir, name);
      const rel = relative(root, full).split(sep).join("/");
      if (options.include && !options.include(rel)) continue;
      const info = await stat(full);
      const path = options.into ? `${options.into.replace(/\/$/, "")}/${rel}` : rel;
      if (info.isDirectory()) {
        out.push({ path, directory: true, mode: 0o755 });
        await walk(full);
      } else if (info.isFile()) {
        out.push({ path, data: await readFile(full), mode: info.mode & 0o111 ? 0o755 : 0o644 });
      }
    }
  };
  await walk(root);
  return out;
}
