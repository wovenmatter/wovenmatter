import { createHash, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, readdirSync, mkdirSync, unlinkSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';

export const quote = text => "'" + String(text).replaceAll("'", "'\\''") + "'";
export const key = value => createHash('sha256').update(value).digest('hex');
export function writeJSON(path, value) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = path + '.' + randomUUID();
  writeFileSync(temporary, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
  renameSync(temporary, path);
}
const readJSON = path => JSON.parse(readFileSync(path, 'utf8'));
export function validateConnection(context) {
  const url = new URL(context?.endpointURL ?? '');
  if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password
      || (url.protocol === 'http:' && !['localhost', '127.0.0.1', '[::1]'].includes(url.hostname))
      || typeof context?.bearerToken !== 'string' || !context.bearerToken) throw new Error('Invalid Woven MCP connection.');
  return context;
}
export function connect(directory, context) {
  validateConnection(context);
  writeJSON(join(directory, 'connection.json'), { endpointURL: context.endpointURL, bearerToken: context.bearerToken });
}
export function enqueue(directory, context, prompts) {
  if (!context) return;
  if ((context.captureID != null && typeof context.captureID !== 'string') || !Array.isArray(prompts) || !prompts.every(p => typeof p === 'string')) throw new Error('Invalid input capture.');
  connect(directory, context);
  const captureID = context.captureID ?? '';
  const path = join(directory, 'pending', key(captureID || randomUUID()) + '.json');
  writeJSON(path, { captureID, prompts, submitted: process.hrtime.bigint().toString() });
  return () => { try { unlinkSync(path); } catch (error) { if (error.code !== 'ENOENT') throw error; } };
}
// Submission only adds a pending entry. Native consumption owns its generation.
export function consume(directory, generation, prompt) {
  if (!generation) throw new Error('Native input identity is missing.');
  const pending = join(directory, 'pending');
  const candidates = existsSync(pending) ? readdirSync(pending).filter(name => name.endsWith('.json'))
    .map(name => ({ path: join(pending, name), ...readJSON(join(pending, name)) }))
    .filter(item => item.prompts.includes(prompt))
    .sort((a, b) => BigInt(a.submitted) < BigInt(b.submitted) ? -1 : 1) : [];
  const captureID = candidates[0]?.captureID ?? '';
  if (candidates[0]) unlinkSync(candidates[0].path);
  writeJSON(join(directory, 'generations', key(generation) + '.json'), { captureID });
  return captureID;
}
export function binding(directory, generation) {
  let captureID = '';
  try { captureID = readJSON(join(directory, 'generations', key(generation) + '.json')).captureID; }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  return { ...readJSON(join(directory, 'connection.json')), captureID };
}
export function recordCallContext(directory, requestID, captureID) {
  const calls = join(directory, 'calls');
  writeJSON(join(calls, key(requestID) + '.json'), { captureID, createdAt: Date.now() });
  // Keep exact bindings for retries, bounded in count and age; never retarget to
  // whichever input happens to be newest when a request arrives.
  const entries = readdirSync(calls).filter(name => name.endsWith('.json'))
    .map(name => ({ path: join(calls, name), ...readJSON(join(calls, name)) }))
    .sort((a, b) => b.createdAt - a.createdAt);
  for (let i = 0; i < entries.length; i++) if (i >= 2048 || entries[i].createdAt < Date.now() - 86400000) {
    try { unlinkSync(entries[i].path); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}
export function callContext(directory, requestID) {
  if (typeof requestID !== 'string') return undefined;
  try {
    const stored = readJSON(join(directory, 'calls', key(requestID) + '.json'));
    return stored.createdAt >= Date.now() - 86400000 ? stored.captureID : undefined;
  } catch (error) { if (error.code !== 'ENOENT') throw error; return undefined; }
}
