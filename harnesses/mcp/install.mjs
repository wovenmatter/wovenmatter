import { mkdirSync, readFileSync, writeFileSync, unlinkSync, realpathSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
export function installOpenCode(env = process.env) {
  const directory = join(env.XDG_CONFIG_HOME ?? join(env.HOME ?? homedir(), '.config'), 'opencode', 'plugins');
  const path = join(directory, 'woven-mcp.js');
  const content = `export { default } from ${JSON.stringify(pathToFileURL(join(root, 'opencode.mjs')).href)};\n`;
  let existing;
  try { existing = readFileSync(path, 'utf8'); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (existing !== content) { mkdirSync(directory, { recursive: true, mode: 0o700 }); writeFileSync(path, content, { mode: 0o600 }); }
  // Remove only Woven's obsolete generated loader, preserving user plugins.
  const retired = join(directory, 'wovenmatter-cli.js');
  try {
    const old = readFileSync(retired, 'utf8');
    if (/^export \{ default \} from "file:.*\/harnesses\/cli\/opencode\.mjs";\n$/.test(old)) unlinkSync(retired);
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
}
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url) && process.argv[2] === 'opencode') installOpenCode();
