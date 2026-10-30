// Install an adapter and its independently selected engine as one immutable
// npm graph. Upstream's engine range is overridden only in this consumer graph;
// vendor manifests, executable signatures and the generated lock stay intact.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { mkdir, mkdtemp, readFile, writeFile, rm, symlink, rename, realpath } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const engines = {
  '@agentclientprotocol/codex-acp': { package: '@openai/codex', command: 'codex-acp' },
  '@agentclientprotocol/claude-agent-acp': { package: '@anthropic-ai/claude-agent-sdk', command: 'claude-agent-acp' },
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
        } catch { finish(new Error('Adapter and engine failed ACP v1 verification.')); }
      }
    });
    child.stdin.on('error', () => finish(new Error('Adapter verification input closed.')));
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
      protocolVersion: 1, clientCapabilities: {}, clientInfo: { name: 'Woven Matter verification', version: '1' },
    } }) + '\n');
  });
}

export async function installAdapter({ prefix, adapter, adapterVersion, engineVersion, npm }) {
  const selection = engines[adapter];
  if (!selection || !exact(adapterVersion) || !exact(engineVersion) || !Array.isArray(npm) || !npm.length || npm.some(x => typeof x !== 'string')) throw new Error('Invalid adapter selection.');
  prefix = resolve(prefix);
  await mkdir(join(prefix, 'Installations'), { recursive: true, mode: 0o700 });
  const generation = await realpath(await mkdtemp(join(prefix, 'Installations', 'adapter-')));
  const temporary = join(prefix, 'bin', '.' + selection.command + '-' + randomUUID());
  let promoted = false;
  try {
    await writeFile(join(generation, 'package.json'), JSON.stringify({ private: true,
      dependencies: { [adapter]: adapterVersion, [selection.package]: engineVersion },
      overrides: { [adapter]: { [selection.package]: '$' + selection.package } },
    }, null, 2) + '\n', { mode: 0o600 });
    await run(npm[0], [...npm.slice(1), 'install', '--prefix', generation, '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund'], { cwd: generation });
    const modules = join(generation, 'node_modules');
    const engine = join(modules, selection.package);
    const engineManifest = await object(join(engine, 'package.json'));
    const adapterManifest = join(modules, adapter, 'package.json');
    const search = createRequire(adapterManifest).resolve.paths(selection.package) ?? [];
    const selected = search.map(path => join(path, selection.package, 'package.json')).find(existsSync);
    if (!selected || await realpath(selected) !== await realpath(join(engine, 'package.json'))) throw new Error('Adapter resolves a different engine graph.');
    if (engineManifest.version !== engineVersion
      || (await object(join(modules, adapter, 'package.json'))).version !== adapterVersion) throw new Error('Installed adapter graph differs from its selection.');
    // Do not inherit credentials, user configuration, or executable overrides
    // for the provider-free probe. Only initialize is sent, never a prompt.
    const probeHome = join(generation, 'verification-home');
    await mkdir(probeHome, { mode: 0o700 });
    const env = { PATH: process.env.PATH, HOME: probeHome, CODEX_HOME: join(probeHome, 'codex'),
      XDG_CONFIG_HOME: join(probeHome, 'config'), CLAUDE_CONFIG_DIR: join(probeHome, 'claude'),
      CLAUDE_SECURESTORAGE_CONFIG_DIR: join(probeHome, 'storage'),
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1' };
    for (const key of ['CODEX_HOME', 'XDG_CONFIG_HOME', 'CLAUDE_CONFIG_DIR', 'CLAUDE_SECURESTORAGE_CONFIG_DIR']) await mkdir(env[key], { recursive: true, mode: 0o700 });
    if (adapter.endsWith('/codex-acp')) {
      const version = await run(process.execPath, [join(engine, 'bin/codex.js'), '--version'], { env });
      if (version.match(/\b\d+\.\d+\.\d+\b/)?.[0] !== engineVersion) throw new Error('Codex executable version differs from its package.');
    } else {
      const binary = join(modules, `@anthropic-ai/claude-agent-sdk-${process.platform}-${process.arch}`, 'claude');
      const version = await run(binary, ['--version'], { env });
      if (version.match(/\b\d+\.\d+\.\d+\b/)?.[0] !== engineManifest.claudeCodeVersion) throw new Error('Claude executable version differs from its SDK.');
      if (process.platform === 'darwin') await run('/usr/bin/codesign', ['--verify', '--strict', binary], { env });
    }
    const executable = join(modules, '.bin', selection.command);
    await verifyAdapter(executable, adapterVersion, env);
    await writeFile(join(generation, 'verification.json'), JSON.stringify({ adapter, adapterVersion, engine: selection.package, engineVersion, protocolVersion: 1 }) + '\n', { mode: 0o600 });
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

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 3) throw new Error('Adapter installation requires one selection.');
    console.log(await installAdapter(JSON.parse(process.argv[2])));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
