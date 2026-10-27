#!/usr/bin/env node
// Manual provider smoke, deliberately excluded from test-changes.sh and CI.
// Requires an explicit --live flag. Existing credentials only; never authenticates.
import { spawn } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { performance } from 'node:perf_hooks';

const args = process.argv.slice(2);
const flag = name => { const i = args.indexOf(name); return i < 0 ? undefined : args[i + 1]; };
const harness = flag('--harness');
if (!args.includes('--live') || !['codex', 'claude_code', 'grok_build'].includes(harness)) {
  console.error('Manual provider use: node scripts/live-streaming-smoke.mjs --live --harness codex|claude_code|grok_build [--model ID] [--output /absolute/report.json]');
  process.exit(2);
}
const executable = flag('--executable') ?? (harness === 'grok_build' ? 'grok'
  : join(homedir(), 'Library/Application Support/Woven Matter/Node Tools/bin', harness === 'codex' ? 'codex-acp' : 'claude-agent-acp'));
const root = await mkdtemp(join(tmpdir(), 'woven-streaming-smoke-'));
const started = performance.now();
const report = { schemaVersion: 1, harness, model: flag('--model') ?? 'advertised-default',
  scope: 'installed ACP adapter wire, not Woven UI', at: new Date().toISOString(),
  events: [], counts: {}, firstMS: {}, terminal: null, permissionsDenied: 0, textCharacters: 0,
  reasoningCharacters: 0, textBeforeTerminal: false };
const child = spawn(executable, harness === 'grok_build' ? ['--disable-web-search', '--no-subagents', '--permission-mode', 'default', 'agent', 'stdio'] : [], {
  cwd: root, env: { ...process.env, NO_OPEN_BROWSER: '1', BROWSER: '/usr/bin/false' }, stdio: ['pipe', 'pipe', 'pipe'], detached: true,
});
let nextID = 0, promptStart, sessionID, failure;
const pending = new Map();
const send = value => child.stdin.write(JSON.stringify(value) + '\n');
const request = (method, params) => new Promise((resolve, reject) => {
  const id = ++nextID; pending.set(id, { resolve, reject }); send({ jsonrpc: '2.0', id, method, params });
});
const fail = error => { failure ??= error; for (const waiter of pending.values()) waiter.reject(error); pending.clear(); };
child.on('error', () => fail(new Error('adapter could not start')));
child.on('exit', code => fail(new Error(`adapter exited (${code})`)));
// Do not retain or print stderr: vendor diagnostics can contain account details.
child.stderr.resume();
createInterface({ input: child.stdout }).on('line', line => {
  let message; try { message = JSON.parse(line); } catch { return; }
  if (message.id != null && !message.method) {
    const waiter = pending.get(message.id); if (!waiter) return;
    pending.delete(message.id);
    if (message.error) waiter.reject(new Error(`RPC error ${message.error.code ?? 'unknown'}`));
    else waiter.resolve(message.result);
  } else if (message.id != null) {
    if (message.method === 'session/request_permission') {
      report.permissionsDenied++; send({ jsonrpc: '2.0', id: message.id, result: { outcome: { outcome: 'cancelled' } } });
    } else send({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Smoke probe does not provide tools or credentials' } });
  } else if (message.method === 'session/update' && promptStart != null) {
    const update = message.params?.update ?? {}, type = update.sessionUpdate;
    if (typeof type !== 'string') return;
    const ms = Math.round(performance.now() - promptStart);
    report.counts[type] = (report.counts[type] ?? 0) + 1;
    report.firstMS[type] ??= ms;
    const characters = typeof update.content?.text === 'string' ? update.content.text.length : 0;
    if (type === 'agent_message_chunk') { report.textCharacters += characters; report.textBeforeTerminal ||= characters > 0 && !report.terminal; }
    if (type === 'agent_thought_chunk') report.reasoningCharacters += characters;
    if (report.events.length < 10000) report.events.push({ type, ms, ...(characters ? { characters } : {}) });
  }
});
const timeout = setTimeout(() => fail(new Error('120 second deadline exceeded')), 120_000);
try {
  const initialized = await request('initialize', { protocolVersion: harness === 'grok_build' ? 2 : 1,
    clientCapabilities: {}, clientInfo: { name: 'woven-streaming-smoke', version: '1' } });
  report.protocolVersion = initialized.protocolVersion;
  const session = await request('session/new', { cwd: root, mcpServers: [] });
  sessionID = session.sessionId;
  if (!sessionID) throw new Error('adapter returned no session');
  report.advertisedModels = session.configOptions?.find(value => value.category === 'model')?.options?.map(value => value.value)
    ?? session.models?.availableModels?.map(value => value.modelId) ?? [];
  if (args.includes('--catalog-only')) report.terminal = 'catalog-only';
  else {
    if (flag('--model')) {
      const option = session.configOptions?.find(value => value.category === 'model');
      await request(option ? 'session/set_config_option' : 'session/set_model', option
        ? { sessionId: sessionID, configId: option.id, value: flag('--model') }
        : { sessionId: sessionID, modelId: flag('--model') });
    }
    promptStart = performance.now();
    const result = await request('session/prompt', { sessionId: sessionID, prompt: [{ type: 'text',
      text: 'This is a bounded streaming transport smoke check. Do not use tools, access files, execute commands, make network requests, or delegate. Explain in about 80 words why 17 times 19 is 323, then finish with STREAM_SMOKE_COMPLETE.' }] });
    report.terminal = result.stopReason ?? 'response';
    report.terminalMS = Math.round(performance.now() - promptStart);
  }
} catch (error) { report.error = error.message; report.terminal ??= 'error'; }
finally {
  clearTimeout(timeout);
  if (child.pid) {
    try { process.kill(-child.pid, 'SIGTERM'); } catch {}
    const kill = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 2000);
    kill.unref(); child.once('close', () => clearTimeout(kill));
  }
  await rm(root, { recursive: true, force: true });
}
report.elapsedMS = Math.round(performance.now() - started);
report.passed = report.terminal === 'end_turn' && report.textBeforeTerminal && report.counts.agent_message_chunk > 1;
const json = JSON.stringify(report, null, 2) + '\n';
if (flag('--output')) await writeFile(flag('--output'), json, { mode: 0o600 });
process.stdout.write(flag('--output') ? JSON.stringify({ ...report, events: undefined, advertisedModels: undefined }, null, 2) + '\n' : json);
process.exitCode = report.passed || report.terminal === 'catalog-only' ? 0 : 1;
