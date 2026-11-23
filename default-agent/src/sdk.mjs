import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, realpathSync } from 'node:fs';
import { mkdir, readdir, readFile, rename, rm, symlink, writeFile } from 'node:fs/promises';
import { registerHooks } from 'node:module';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

// The SDK packages a session process loads. `update-sdk` installs their latest
// releases into a fresh folder under the data folder and points `sdk/current` at
// it. Each process resolves that link once, at start, so running sessions keep
// the packages they started with and new ones use the update.
export const sdkPackages = ['@earendil-works/pi-durable', '@earendil-works/pi-ai', '@earendil-works/pi-coding-agent', '@earendil-works/chord',
  '@earendil-works/pi-codemode', '@earendil-works/pi-mcp', '@earendil-works/pi-schema', '@anthropic-ai/claude-agent-sdk'];
const source = pathToFileURL(fileURLToPath(new URL('.', import.meta.url))).href;
const run = promisify(execFile);

export function useInstalledSDK(data) {
  const current = join(data, 'sdk', 'current');
  if (!existsSync(join(current, 'node_modules'))) return;
  const root = realpathSync(current);
  const parentURL = pathToFileURL(join(root, 'package.json')).href;
  const ours = new RegExp(`^(${sdkPackages.map(name => name.replace('/', '\\/')).join('|')})(\\/|-|$)`);
  registerHooks({
    resolve(specifier, context, next) {
      if (context.parentURL?.startsWith(source) && ours.test(specifier)) return next(specifier, { ...context, parentURL });
      return next(specifier, context);
    },
  });
}

// The npm that ships beside Pi Durable: the Mac app's `default-agent/lib/npm`, then Linux Node's own.
function npmCommand() {
  const bundled = [fileURLToPath(new URL('../lib/npm/bin/npm-cli.js', import.meta.url)),
    join(dirname(process.execPath), '..', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js')].find(existsSync);
  return bundled ? [process.execPath, [bundled]] : ['npm', []];
}

export async function updateSDK(data) {
  const base = join(data, 'sdk');
  const id = new Date().toISOString().replace(/[^0-9]/g, '') + '-' + randomUUID().slice(0, 8);
  const target = join(base, id);
  await mkdir(target, { recursive: true, mode: 0o700 });
  try {
    await writeFile(join(target, 'package.json'), JSON.stringify({ private: true, type: 'module' }));
    const [command, prefix] = npmCommand();
    await run(command, [...prefix, 'install', '--no-audit', '--no-fund', '--omit=dev', '--omit=optional', '--prefix', target, ...sdkPackages.map(name => `${name}@latest`)],
      { timeout: 10 * 60 * 1000, maxBuffer: 16 * 1024 * 1024 });
    // The packages must load before sessions are pointed at them.
    await run(process.execPath, ['--input-type=module', '-e', "await import('@earendil-works/pi-durable'); await import('@earendil-works/pi-durable/codemode'); await import('@earendil-works/pi-codemode'); await import('@earendil-works/pi-coding-agent');"], { cwd: target, timeout: 60000 });
  } catch (error) {
    await rm(target, { recursive: true, force: true });
    throw new Error(`The SDK update failed: ${error.stderr?.toString().trim().split('\n').at(-1) || error.message}`);
  }
  const link = join(base, `link-${randomUUID()}`);
  await symlink(id, link);
  const previous = existsSync(join(base, 'current')) ? basename(realpathSync(join(base, 'current'))) : undefined;
  await rename(link, join(base, 'current'));
  // Keep the update and the one before it, which sessions may still be running.
  for (const entry of await readdir(base)) {
    if (entry !== 'current' && entry !== id && entry !== previous) await rm(join(base, entry), { recursive: true, force: true });
  }
  const versions = {};
  for (const name of sdkPackages) versions[name] = JSON.parse(await readFile(join(target, 'node_modules', name, 'package.json'), 'utf8')).version;
  return { installed: versions };
}
