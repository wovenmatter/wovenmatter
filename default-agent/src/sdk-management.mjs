import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { access, chmod, cp, lstat, mkdir, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const bundledRoot = fileURLToPath(new URL('../', import.meta.url));
const definitions = [
  { id: 'pi', name: 'Pi SDK', packages: ['@earendil-works/pi-coding-agent', '@earendil-works/pi-ai'] },
  { id: 'claude', name: 'Claude SDK', packages: ['@anthropic-ai/claude-agent-sdk'] },
];
const stableVersion = value => typeof value === 'string' && /^\d+\.\d+\.\d+$/.test(value);
const newer = (a, b) => a.split('.').map(Number).some((v, i, aa) => v > b.split('.').map(Number)[i] && aa.slice(0, i).every((x, n) => x === Number(b.split('.')[n])));
export class SDKMaintenanceError extends Error {}
const fail = message => new SDKMaintenanceError(message);
const aborted = signal => { if (signal?.aborted) throw fail('SDK update was cancelled.'); };
const readJSON = async (path, fallback = null) => {
  try { return JSON.parse(await readFile(path, 'utf8')); } catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
};
const packageVersion = async (root, name) => (await readJSON(join(root, 'node_modules', name, 'package.json')))?.version ?? null;
async function privateDirectory(path) {
  await mkdir(path, { recursive: true, mode: 0o700 });
  const value = await lstat(path);
  if (!value.isDirectory() || value.isSymbolicLink() || value.uid !== process.getuid()) throw fail('The SDK installation directory is not owned by this workspace.');
  await chmod(path, 0o700);
}
async function atomicJSON(path, value) {
  const temporary = `${path}.${randomUUID()}.tmp`;
  try { await writeFile(temporary, JSON.stringify(value), { mode: 0o600, flag: 'wx' }); await rename(temporary, path); }
  finally { await rm(temporary, { force: true }); }
}
let fingerprintPromise;
async function fingerprint() {
  return fingerprintPromise ??= (async () => {
    const hash = createHash('sha256').update(process.platform + '/' + process.arch);
    // An app update must never execute a stale copy of its helper source.
    for (const name of ['package.json', 'package-lock.json', ...(await readdir(join(bundledRoot, 'src'))).filter(n => n.endsWith('.mjs')).sort().map(n => 'src/' + n)]) {
      hash.update(name); hash.update(await readFile(join(bundledRoot, name)));
    }
    return hash.digest('hex');
  })();
}
function paths(directory) {
  if (!isAbsolute(directory)) throw fail('The SDK workspace directory must be absolute.');
  const root = join(directory, 'sdk-runtime');
  return { root, generations: join(root, 'generations'), active: join(root, 'active.json'), latest: join(root, 'latest.json'), lock: join(root, 'operation.lock') };
}
export async function resolveSDKRuntime({ directory }) {
  const p = paths(directory), base = await fingerprint();
  const active = await readJSON(p.active).catch(() => null);
  if (active?.base === base && /^[a-f0-9-]{36}$/.test(active.generation ?? '')) {
    const root = join(p.generations, active.generation);
    try {
      const info = await lstat(root);
      const manifest = await readJSON(join(root, 'woven-sdk-generation.json'));
      if (info.isDirectory() && !info.isSymbolicLink() && info.uid === process.getuid() && manifest?.base === base && manifest?.generation === active.generation) {
        await access(join(root, 'src/main-runtime.mjs'));
        return { root, generation: active.generation, base };
      }
    } catch {}
  }
  return { root: bundledRoot, generation: 'bundled-' + base, base };
}
export async function sdkStatus({ directory }) {
  const runtime = await resolveSDKRuntime({ directory });
  const cached = await readJSON(paths(directory).latest).catch(() => null);
  const sdks = await Promise.all(definitions.map(async definition => {
    const versions = await Promise.all(definition.packages.map(name => packageVersion(runtime.root, name).catch(() => null)));
    const installedVersion = versions[0];
    const consistent = versions.every(version => version === installedVersion) && stableVersion(installedVersion);
    const latestVersion = cached?.base === runtime.base ? cached?.versions?.[definition.id] ?? null : null;
    return { id: definition.id, name: definition.name, installedVersion, latestVersion, consistent,
      ...(!consistent ? { notice: 'SDK package versions are inconsistent. Reinstall the SDK update.' } : {}),
      updateAvailable: stableVersion(latestVersion) && stableVersion(installedVersion) && (newer(latestVersion, installedVersion) || !consistent) };
  }));
  return { sdks, generation: runtime.generation, checkedAt: cached?.base === runtime.base ? cached.checkedAt ?? null : null };
}
async function registryVersion(name, signal, fetchImplementation = fetch) {
  const timeout = AbortSignal.timeout(15000);
  const response = await fetchImplementation(`https://registry.npmjs.org/${encodeURIComponent(name)}/latest`, { signal: signal ? AbortSignal.any([signal, timeout]) : timeout });
  if (!response.ok) throw fail('The SDK update source is unavailable. Try again later.');
  let bytes = 0, text = '';
  for await (const chunk of response.body) {
    bytes += chunk.length;
    if (bytes > 262144) throw fail('The SDK update source returned too much data.');
    text += Buffer.from(chunk).toString('utf8');
  }
  const version = JSON.parse(text).version;
  if (!stableVersion(version)) throw fail('The SDK update source did not return a supported release version.');
  return version;
}
function compatible(version, installed) {
  // Claude's minor line is its SDK API compatibility boundary. Pi remains 0.x;
  // allow its minor releases only after the provider-free contract check below.
  return stableVersion(version) && stableVersion(installed) && version.split('.')[0] === installed.split('.')[0];
}
export async function checkSDKUpdates({ directory, id, signal, fetchImplementation } = {}) {
  aborted(signal);
  const runtime = await resolveSDKRuntime({ directory });
  const previous = await readJSON(paths(directory).latest).catch(() => null);
  const versions = previous?.base === runtime.base ? { ...previous.versions } : {};
  if (id !== undefined && !definitions.some(definition => definition.id === id)) throw fail('Choose Pi SDK or Claude SDK.');
  for (const definition of definitions.filter(value => id === undefined || value.id === id)) {
    const current = await packageVersion(runtime.root, definition.packages[0]);
    const latest = await registryVersion(definition.packages[0], signal, fetchImplementation);
    if (!compatible(latest, current) || (definition.id === 'claude' && latest.split('.')[1] !== current.split('.')[1])) {
      throw fail(`${definition.name} has a new incompatible release. Update Woven Matter before installing it.`);
    }
    versions[definition.id] = latest;
  }
  aborted(signal);
  await privateDirectory(paths(directory).root);
  await atomicJSON(paths(directory).latest, { base: runtime.base, versions, checkedAt: new Date().toISOString() });
  return sdkStatus({ directory });
}
async function acquireLock(path, onCompromised) {
  // Use the same maintained lock implementation as credential persistence.
  // A heartbeat permits recovery after a crashed updater without racing a new
  // owner or leaving a mkdir-before-owner-write lock permanently stranded.
  const { default: lockfile } = await import('proper-lockfile');
  try {
    return await lockfile.lock(dirname(path), { lockfilePath: path, realpath: false,
      retries: 0, stale: 120000, update: 10000, onCompromised });
  } catch { throw fail('Another SDK update is already running in this workspace. If its process stopped, retry in two minutes.'); }
}
function safeEnvironment(home, temporary) {
  // Do not pass provider tokens, npm tokens, inherited NODE_OPTIONS, proxy
  // credentials, or user npm configuration to the package installer.
  return { HOME: home, TMPDIR: temporary, PATH: dirname(process.execPath) + ':/usr/bin:/bin:/usr/sbin:/sbin',
    LANG: 'en_US.UTF-8', npm_config_registry: 'https://registry.npmjs.org', npm_config_ignore_scripts: 'true',
    npm_config_audit: 'false', npm_config_fund: 'false', npm_config_update_notifier: 'false' };
}
async function command(executable, args, { cwd, env, timeout = 30000, signal } = {}) {
  aborted(signal);
  return new Promise((resolvePromise, reject) => {
    const child = spawn(executable, args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
    let size = 0, output = '', stopped = false, finished = false, killTimer;
    const stop = () => {
      stopped = true; child.kill('SIGTERM');
      killTimer ??= setTimeout(() => child.kill('SIGKILL'), 1500); killTimer.unref();
    };
    const timer = setTimeout(stop, timeout); timer.unref();
    const consume = chunk => { size += chunk.length; if (size > 1048576) stop(); else output += chunk.toString('utf8'); };
    child.stdout.on('data', consume); child.stderr.on('data', consume);
    signal?.addEventListener('abort', stop, { once: true });
    const finish = error => {
      if (finished) return; finished = true; clearTimeout(timer); clearTimeout(killTimer); signal?.removeEventListener('abort', stop);
      if (error) reject(error); else resolvePromise(output);
    };
    child.on('error', () => finish(fail('The SDK installer could not start.')));
    child.on('close', code => finish(stopped ? fail(signal?.aborted ? 'SDK update was cancelled.' : 'SDK update exceeded its time or output limit.') : code === 0 ? undefined : fail('SDK installation or verification failed. The previous SDKs were kept.')));
  });
}
async function npmCLI() {
  for (const candidate of [join(bundledRoot, 'lib/npm/bin/npm-cli.js'), resolve(dirname(process.execPath), '../lib/node_modules/npm/bin/npm-cli.js')]) {
    try { await access(candidate); return candidate; } catch {}
  }
  throw fail('The bundled SDK installer is unavailable. Update or reinstall Woven Matter.');
}
const verificationSource = `
const pi = await import('@earendil-works/pi-coding-agent');
for (const name of ['createAgentSession','createCodingTools','DefaultResourceLoader','ModelRuntime','SessionManager','SettingsManager']) if (typeof pi[name] !== 'function') throw Error('Pi API unavailable');
const ai = await import('@earendil-works/pi-ai');
for (const name of ['InMemoryCredentialStore','createAssistantMessageEventStream']) if (typeof ai[name] !== 'function') throw Error('Pi API unavailable');
const transcript = await import('@earendil-works/pi-ai/utils/transcript');
for (const name of ['getCurrentSystemPrompt','getCurrentTools']) if (typeof transcript[name] !== 'function') throw Error('Pi API unavailable');
const claude = await import('@anthropic-ai/claude-agent-sdk');
if (typeof claude.query !== 'function') throw Error('Claude API unavailable');
await import('./src/engine.mjs');
`;
export async function updateSDK({ directory, id, version, signal }) {
  const lockController = new AbortController();
  signal = signal ? AbortSignal.any([signal, lockController.signal]) : lockController.signal;
  aborted(signal);
  const definition = definitions.find(value => value.id === id);
  if (!definition) throw fail('Choose Pi SDK or Claude SDK.');
  const p = paths(directory);
  await privateDirectory(p.root); await privateDirectory(p.generations);
  const unlock = await acquireLock(p.lock, () => lockController.abort());
  let stage;
  try {
    const before = await resolveSDKRuntime({ directory });
    const checked = await checkSDKUpdates({ directory, id, signal });
    const selected = checked.sdks.find(value => value.id === id);
    if (version !== undefined && version !== selected.latestVersion) throw fail('The available SDK version changed. Check for updates again.');
    if (!selected.updateAvailable && selected.consistent) return checked;
    aborted(signal);
    const generation = randomUUID();
    stage = join(p.generations, '.staging-' + generation);
    await privateDirectory(stage);
    await cp(join(bundledRoot, 'src'), join(stage, 'src'), { recursive: true, dereference: false, errorOnExist: true });
    const manifest = await readJSON(join(before.root, 'package.json'));
    for (const pkg of definition.packages) manifest.dependencies[pkg] = selected.latestVersion;
    await writeFile(join(stage, 'package.json'), JSON.stringify(manifest), { mode: 0o600 });
    // Preserve the untouched SDK and every other locked dependency.
    await cp(join(before.root, 'package-lock.json'), join(stage, 'package-lock.json'));
    const home = join(stage, '.installer-home'), temporary = join(stage, '.installer-tmp');
    await privateDirectory(home); await privateDirectory(temporary);
    const config = join(stage, '.user-npmrc'), globalConfig = join(stage, '.global-npmrc');
    await writeFile(config, '', { mode: 0o600 }); await writeFile(globalConfig, '', { mode: 0o600 });
    const env = safeEnvironment(home, temporary);
    await command(process.execPath, [await npmCLI(), 'install', '--prefix', stage, '--ignore-scripts', '--omit=dev', '--no-audit', '--no-fund', '--save-exact', '--engine-strict', '--registry=https://registry.npmjs.org', '--userconfig=' + config, '--globalconfig=' + globalConfig, '--cache=' + join(stage, '.npm-cache')], { cwd: stage, env, timeout: 600000, signal });
    for (const pkg of definition.packages) if (await packageVersion(stage, pkg) !== selected.latestVersion) throw fail('The SDK installation did not match the requested version. The previous SDKs were kept.');
    // Imports only: no credentials, model discovery, account checks, or inference.
    await command(process.execPath, ['--input-type=module', '--eval', verificationSource], { cwd: stage, env, signal });
    const claude = join(stage, 'node_modules', `@anthropic-ai/claude-agent-sdk-${process.platform}-${process.arch}`, 'claude');
    if (process.platform === 'darwin') await command('/usr/bin/codesign', ['--verify', '--strict', claude], { cwd: stage, env, signal });
    const engineVersion = await command(claude, ['--version'], { cwd: stage, env, signal });
    if (!/\d+\.\d+\.\d+/.test(engineVersion)) throw fail('The Claude SDK runtime could not be verified. The previous SDKs were kept.');
    await atomicJSON(join(stage, 'woven-sdk-generation.json'), { base: before.base, generation });
    for (const name of ['.installer-home', '.installer-tmp', '.npm-cache', '.user-npmrc', '.global-npmrc']) await rm(join(stage, name), { recursive: true, force: true });
    aborted(signal);
    const completed = join(p.generations, generation);
    await rename(stage, completed); stage = undefined;
    aborted(signal);
    // Atomic activation is the only mutation visible to new helper processes.
    // Existing generations are intentionally retained for live conversations.
    await atomicJSON(p.active, { base: before.base, generation });
    return { ...await sdkStatus({ directory }), notice: 'SDK updated. Running turns finish with their current SDK; new turns use the update.' };
  } catch (error) {
    if (error instanceof SDKMaintenanceError) throw error;
    throw fail(signal?.aborted ? 'SDK update was cancelled.' : 'SDK update could not complete. The previous SDKs were kept.');
  } finally { if (stage) await rm(stage, { recursive: true, force: true }); await unlock().catch(() => {}); }
}
