import { createHash, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, readdirSync, mkdirSync, unlinkSync, existsSync } from 'node:fs';
import { join, dirname, isAbsolute } from 'node:path';

export const quote = text => "'" + String(text).replaceAll("'", "'\\''") + "'";
export const key = value => createHash('sha256').update(value).digest('hex');
export function writeJSON(path, value) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = path + '.' + randomUUID();
  writeFileSync(temporary, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
  renameSync(temporary, path);
}
const readJSON = path => JSON.parse(readFileSync(path, 'utf8'));
export function connect(directory, context) {
  if (!context || !isAbsolute(context.executablePath ?? '')
      || (context.socketPath && !isAbsolute(context.socketPath))) throw new Error('Invalid Woven Matter CLI connection.');
  writeJSON(join(directory, 'connection.json'), { executablePath: context.executablePath, socketPath: context.socketPath });
}
export function enqueue(directory, context, prompts) {
  if (!context) return;
  if (!context.captureID || !Array.isArray(prompts) || !prompts.every(p => typeof p === 'string')) throw new Error('Invalid input capture.');
  connect(directory, context);
  const path = join(directory, 'pending', key(context.captureID) + '.json');
  writeJSON(path, { captureID: context.captureID, prompts, submitted: process.hrtime.bigint().toString() });
  return () => { try { unlinkSync(path); } catch (error) { if (error.code !== 'ENOENT') throw error; } };
}

// Hooks run at native input consumption. A queued submission only creates a
// pending entry; it cannot replace the generation currently executing tools.
export function consume(directory, generation, prompt) {
  if (!generation) throw new Error('Native input identity is missing.');
  const pending = join(directory, 'pending');
  const candidates = existsSync(pending) ? readdirSync(pending).filter(name => name.endsWith('.json'))
    .map(name => ({ path: join(pending, name), ...readJSON(join(pending, name)) }))
    .filter(item => item.prompts.includes(prompt))
    .sort((a, b) => BigInt(a.submitted) < BigInt(b.submitted) ? -1 : 1) : [];
  const captureID = candidates[0]?.captureID ?? '';
  if (candidates[0]) unlinkSync(candidates[0].path);
  bindGeneration(directory, generation, captureID);
  return captureID;
}
export function bindGeneration(directory, generation, captureID) {
  writeJSON(join(directory, 'generations', key(generation) + '.json'), { captureID });
}
export function binding(directory, generation) {
  const connection = readJSON(join(directory, 'connection.json'));
  let captureID = '';
  try { captureID = readJSON(join(directory, 'generations', key(generation) + '.json')).captureID; }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  return { ...connection, captureID };
}
export function environment(context, base = {}) {
  const result = { ...base };
  for (const name of ['WOVENMATTER_SOCKET', 'WOVENMATTER_CLI', 'WOVENMATTER_CONTEXT_ID', 'WOVENMATTER_NOTE_ID']) delete result[name];
  result.WOVENMATTER_CLI = context.executablePath;
  result.WOVENMATTER_CONTEXT_ID = context.captureID;
  if (context.socketPath) result.WOVENMATTER_SOCKET = context.socketPath;
  result.PATH = dirname(context.executablePath) + ':' + (base.PATH ?? process.env.PATH ?? '');
  return result;
}
export function shellInput(input, context) {
  const env = environment(context);
  delete env.PATH;
  const pathPrefix = quote(dirname(context.executablePath)) + ':"$PATH"';
  const prefix = 'unset WOVENMATTER_SOCKET WOVENMATTER_NOTE_ID; export '
    + Object.entries(env).map(([name, value]) => name + '=' + quote(value)).join(' ') + '; export PATH=' + pathPrefix + ';\n';
  if (typeof input.command === 'string') return { ...input, command: prefix + input.command };
  if (typeof input.cmd === 'string') return { ...input, cmd: prefix + input.cmd };
  if (Array.isArray(input.command) && input.command.every(p => typeof p === 'string')) {
    return { ...input, command: ['/bin/sh', '-c', prefix + 'exec "$@"', 'wovenmatter', ...input.command] };
  }
  return input;
}
