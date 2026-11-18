// Install an ACP adapter as one immutable npm graph in Woven Matter's folder. The adapter
// drives the person's own native CLI (CODEX_PATH / CLAUDE_CODE_EXECUTABLE), never a copy
// bundled inside its package. Claude's library SDK is selected independently of that CLI.
import { spawn } from 'node:child_process';
import { existsSync, realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { mkdir, mkdtemp, readFile, writeFile, rm, symlink, rename, realpath } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const adapters = {
  '@agentclientprotocol/codex-acp': { command: 'codex-acp', cliVariable: 'CODEX_PATH' },
  '@agentclientprotocol/claude-agent-acp': { command: 'claude-agent-acp', cliVariable: 'CLAUDE_CODE_EXECUTABLE' },
};
const exact = value => /^\d+\.\d+\.\d+$/.test(value);
const object = async path => JSON.parse(await readFile(path, 'utf8'));

export async function run(command, args, options = {}) {
  return new Promise((accept, reject) => {
    const child = spawn(command, args, { ...options, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '', settled = false;
    const stop = () => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} };
    const finish = (error) => { if (settled) return; settled = true; clearTimeout(timer); stop(); error ? reject(error) : accept(output); };
    const timer = setTimeout(() => finish(new Error('Adapter installation or version verification timed out.')), 300000);
    for (const stream of [child.stdout, child.stderr]) stream.on('data', data => { output = (output + data).slice(-65536); });
    child.on('error', () => finish(new Error('Adapter installation or version verification could not start.')));
    child.on('close', code => finish(code === 0 ? null : new Error('Adapter installation or version verification failed.')));
  });
}

export async function verifyAdapter(executable, adapterVersion, environment) {
  return new Promise((accept, reject) => {
    const child = spawn(process.execPath, [executable], { env: environment, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let buffer = '', bytes = 0, settled = false;
    const finish = (error) => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      try { process.kill(-child.pid, 'SIGKILL'); } catch {}
      error ? reject(error) : accept();
    };
    const timer = setTimeout(() => finish(new Error('Adapter protocol verification timed out.')), 20000);
    child.on('error', () => finish(new Error('Adapter protocol verification could not start.')));
    child.on('close', () => finish(new Error('Adapter exited before protocol verification.')));
    child.stderr.on('data', data => { bytes += data.length; if (bytes > 2 * 1024 * 1024) finish(new Error('Adapter verification output exceeded its limit.')); });
    child.stdout.on('data', data => {
      bytes += data.length;
      if (bytes > 2 * 1024 * 1024) return finish(new Error('Adapter verification output exceeded its limit.'));
      buffer += data;
      for (let end; (end = buffer.indexOf('\n')) >= 0;) {
        const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
        if (!line.trim()) continue;
        try {
          const response = JSON.parse(line);
          if (response.id !== 1) continue;
          if (response.result?.protocolVersion !== 1 || response.result?.agentInfo?.version !== adapterVersion) throw new Error();
          finish();
        } catch { finish(new Error('Adapter failed ACP v1 verification.')); }
      }
    });
    child.stdin.on('error', () => finish(new Error('Adapter verification input closed.')));
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
      protocolVersion: 1, clientCapabilities: {}, clientInfo: { name: 'Woven Matter verification', version: '1' },
    } }) + '\n');
  });
}

/** `cli` is the native CLI the adapter will drive; older callers may still send `engineVersion`, which is ignored. */
export async function installAdapter({ prefix, adapter, adapterVersion, protocolSDKVersion, librarySDKVersion, npm, cli }) {
  const selection = adapters[adapter];
  if (!selection || !exact(adapterVersion) || !Array.isArray(npm) || !npm.length || npm.some(x => typeof x !== 'string')) throw new Error('Invalid adapter selection.');
  if (cli !== undefined && (typeof cli !== 'string' || !cli.startsWith('/'))) throw new Error('Invalid CLI selection.');
  if (protocolSDKVersion !== undefined && !exact(protocolSDKVersion)) throw new Error('Invalid ACP SDK selection.');
  if (librarySDKVersion !== undefined && (adapter !== '@agentclientprotocol/claude-agent-acp' || !exact(librarySDKVersion))) throw new Error('Invalid library SDK selection.');
  prefix = resolve(prefix);
  await mkdir(join(prefix, 'Installations'), { recursive: true, mode: 0o700 });
  const generation = await realpath(await mkdtemp(join(prefix, 'Installations', 'adapter-')));
  const temporary = join(prefix, 'bin', '.' + selection.command + '-' + randomUUID());
  let promoted = false;
  try {
    const dependencies = { [adapter]: adapterVersion };
    const overrides = {};
    if (protocolSDKVersion) {
      dependencies['@agentclientprotocol/sdk'] = protocolSDKVersion;
      overrides['@agentclientprotocol/sdk'] = '$@agentclientprotocol/sdk';
    }
    if (librarySDKVersion) {
      dependencies['@anthropic-ai/claude-agent-sdk'] = librarySDKVersion;
      overrides['@anthropic-ai/claude-agent-sdk'] = '$@anthropic-ai/claude-agent-sdk';
    }
    await writeFile(join(generation, 'package.json'), JSON.stringify({ private: true,
      dependencies, ...(Object.keys(overrides).length ? { overrides: { [adapter]: overrides } } : {}),
    }, null, 2) + '\n', { mode: 0o600 });
    await run(npm[0], [...npm.slice(1), 'install', '--prefix', generation, '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund'], { cwd: generation });
    const modules = join(generation, 'node_modules');
    const adapterManifest = join(modules, adapter, 'package.json');
    if ((await object(adapterManifest)).version !== adapterVersion) throw new Error('Installed adapter graph differs from its selection.');
    for (const [name, version] of [['@agentclientprotocol/sdk', protocolSDKVersion], ['@anthropic-ai/claude-agent-sdk', librarySDKVersion]]) {
      if (!version) continue;
      const selected = createRequire(adapterManifest).resolve.paths(name).map(path => join(path, name, 'package.json')).find(existsSync);
      if (!selected || await realpath(selected) !== await realpath(join(modules, name, 'package.json'))
        || (await object(selected)).version !== version) throw new Error('Adapter resolves a different selected SDK graph.');
    }
    // The provider-free probe inherits no credentials or user configuration; it is pointed
    // only at the native CLI the adapter will drive. Only initialize is sent, never a prompt.
    const probeHome = join(generation, 'verification-home');
    await mkdir(probeHome, { mode: 0o700 });
    const env = { PATH: process.env.PATH, HOME: probeHome, CODEX_HOME: join(probeHome, 'codex'),
      XDG_CONFIG_HOME: join(probeHome, 'config'), CLAUDE_CONFIG_DIR: join(probeHome, 'claude'),
      CLAUDE_SECURESTORAGE_CONFIG_DIR: join(probeHome, 'storage'),
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1' };
    for (const key of ['CODEX_HOME', 'XDG_CONFIG_HOME', 'CLAUDE_CONFIG_DIR', 'CLAUDE_SECURESTORAGE_CONFIG_DIR']) await mkdir(env[key], { recursive: true, mode: 0o700 });
    if (cli) env[selection.cliVariable] = cli;
    const executable = join(modules, '.bin', selection.command);
    await verifyAdapter(executable, adapterVersion, env);
    await writeFile(join(generation, 'verification.json'), JSON.stringify({ adapter, adapterVersion, cli: cli ?? null, protocolSDKVersion, librarySDKVersion, protocolVersion: 1 }) + '\n', { mode: 0o600 });
    await rm(probeHome, { recursive: true, force: true });
    await mkdir(join(prefix, 'bin'), { recursive: true, mode: 0o700 });
    await symlink(executable, temporary);
    await rename(temporary, join(prefix, 'bin', selection.command));
    promoted = true;
    return join(prefix, 'bin', selection.command);
  } finally {
    await rm(temporary, { force: true });
    if (!promoted) await rm(generation, { recursive: true, force: true });
  }
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 3) throw new Error('Adapter installation requires one selection.');
    console.log(await installAdapter(JSON.parse(process.argv[2])));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
