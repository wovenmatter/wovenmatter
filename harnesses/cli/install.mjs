import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
export function installOpenCode(env = process.env) {
  const path = join(env.XDG_CONFIG_HOME ?? join(env.HOME ?? homedir(), '.config'), 'opencode', 'plugins', 'wovenmatter-cli.js');
  const content = `export { default } from ${JSON.stringify(pathToFileURL(join(root, 'opencode.mjs')).href)};\n`;
  let existing;
  try { existing = readFileSync(path, 'utf8'); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (existing !== content) {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    writeFileSync(path, content, { mode: 0o600 });
  }
}
if (process.argv[1] === fileURLToPath(import.meta.url) && process.argv[2] === 'opencode') installOpenCode();
