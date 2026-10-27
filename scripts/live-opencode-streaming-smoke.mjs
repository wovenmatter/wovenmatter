#!/usr/bin/env node
// Manual provider probe. Never run from tests/CI. Uses the existing local service.
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';
const args = process.argv.slice(2), option = name => args[args.indexOf(name) + 1];
if (!args.includes('--live') || !args.includes('--model')) {
  console.error('Manual provider use: node scripts/live-opencode-streaming-smoke.mjs --live --model provider/model [--output /absolute/report.json]');
  process.exit(2);
}
const selected = option('--model'), slash = selected.indexOf('/');
if (slash < 1) throw new Error('Expected provider/model');
const registration = JSON.parse(await readFile(join(process.env.XDG_STATE_HOME ?? join(homedir(), '.local/state'), 'opencode/service.json'), 'utf8'));
const origin = new URL(registration.url);
if (!['localhost', '127.0.0.1', '[::1]'].includes(origin.hostname)) throw new Error('Only existing loopback services are supported');
// This credential stays in memory and is sent only to its registered loopback service.
const headers = { Authorization: 'Basic ' + Buffer.from('opencode:' + registration.password).toString('base64'), 'Content-Type': 'application/json' };
const call = async (method, path, body) => {
  const response = await fetch(new URL(path, origin), { method, headers, redirect: 'error', signal: AbortSignal.timeout(15000), body: body ? JSON.stringify(body) : undefined });
  if (!response.ok) throw new Error(`HTTP ${response.status} ${method} ${path.replace(/ses_[^/]+/g, 'SESSION')}`);
  const text = await response.text(); return text ? JSON.parse(text) : null;
};
const directory = await mkdtemp(join(tmpdir(), 'woven-opencode-smoke-'));
const id = 'ses_' + crypto.randomUUID().replaceAll('-', '');
const path = '/api/session/' + id;
const report = { schemaVersion: 1, harness: 'opencode', model: selected, version: registration.version,
  scope: 'OpenCode v2 native HTTP/SSE, not Woven UI', at: new Date().toISOString(), counts: {}, firstMS: {}, shapes: {}, events: [], terminal: null };
let start, created = false, streamTask;
const controller = new AbortController();
try {
  await call('POST', '/api/session', { id, location: { directory }, title: 'Woven streaming smoke (temporary)' }); created = true;
  await call('PATCH', path, { model: { providerID: selected.slice(0, slash), id: selected.slice(slash + 1) }, permissions: [{ action: '*', resource: '*', effect: 'deny' }] });
  const response = await fetch(new URL('/api/event', origin), { headers, redirect: 'error', signal: controller.signal });
  if (!response.ok) throw new Error(`event stream HTTP ${response.status}`);
  start = performance.now();
  streamTask = (async () => {
    let buffer = '', decoder = new TextDecoder();
    for await (const chunk of response.body) {
      buffer += decoder.decode(chunk, { stream: true });
      buffer = buffer.replaceAll('\r\n', '\n');
      let split;
      while ((split = buffer.indexOf('\n\n')) >= 0) {
        const frame = buffer.slice(0, split).replaceAll('\r', ''); buffer = buffer.slice(split + 2);
        const data = frame.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trim()).join('\n');
        let event; try { event = JSON.parse(data); } catch { continue; }
        event = event.payload ?? event;
        if (event.sessionID !== id && event.data?.sessionID !== id && event.properties?.sessionID !== id) continue;
        const type = event.type ?? 'unknown', ms = Math.round(performance.now() - start);
        report.counts[type] = (report.counts[type] ?? 0) + 1; report.firstMS[type] ??= ms;
        const value = event.data ?? event.properties ?? {};
        report.shapes[type] ??= { eventKeys: Object.keys(event), dataKeys: Object.keys(value),
          fields: Object.fromEntries(Object.entries(value).map(([key, val]) => [key, Array.isArray(val) ? 'array' : typeof val])) };
        if (report.events.length < 10000) report.events.push({ type, ms, ...(typeof value.delta === 'string' ? { characters: value.delta.length } : {}) });
        if (['session.execution.succeeded', 'session.execution.failed', 'session.execution.interrupted'].includes(type)) {
          report.terminal = type;
          if (value.error) {
            const errorText = JSON.stringify(value.error);
            report.failureCategory = /auth|credential|api.key|unauthorized|401/i.test(errorText) ? 'authentication'
              : /not.found|unknown.model|model.*not/i.test(errorText) ? 'model-unavailable'
              : /quota|rate.limit|429/i.test(errorText) ? 'quota-or-rate-limit' : 'provider-or-runtime-error';
            report.failureShape = Object.keys(value.error);
            if (typeof value.error.name === 'string') report.failureName = value.error.name;
          }
        }
      }
    }
  })().catch(error => { if (!controller.signal.aborted) report.streamError = error.name; });
  await call('POST', path + '/prompt', { id: 'msg_' + crypto.randomUUID().replaceAll('-', ''),
    text: 'Bounded streaming transport smoke check. Do not use tools, files, commands, web access, or subagents. Explain in about 80 words why 17 times 19 is 323 and finish with STREAM_SMOKE_COMPLETE.', files: [], delivery: 'steer' });
  while (!report.terminal && performance.now() - start < 90000) await new Promise(resolve => setTimeout(resolve, 250));
  report.elapsedMS = Math.round(performance.now() - start);
  if (!report.terminal) report.terminal = 'deadline';
  const page = await call('GET', path + '/message');
  report.messageSnapshotShape = { keys: Object.keys(page ?? {}), entries: Array.isArray(page) ? page.length : undefined };
} catch (error) { report.error = error.message; report.terminal ??= 'error'; }
finally {
  controller.abort(); await streamTask;
  if (created) {
    if (report.terminal !== 'session.execution.succeeded') await call('POST', path + '/interrupt').catch(() => {});
    await call('DELETE', path).catch(() => { report.cleanupFailed = true; });
  }
  await rm(directory, { recursive: true, force: true });
}
report.passed = report.terminal === 'session.execution.succeeded' && Object.entries(report.counts).some(([key, count]) => key.includes('text') && count > 1);
if (args.includes('--output')) await writeFile(option('--output'), JSON.stringify(report, null, 2) + '\n', { mode: 0o600 });
console.log(JSON.stringify({ ...report, events: undefined }, null, 2));
process.exitCode = report.passed ? 0 : 1;
