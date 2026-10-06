import { createHash, randomUUID } from 'node:crypto';
import { mkdir } from 'node:fs/promises';
import { join, isAbsolute } from 'node:path';
import { DefaultAgentError, readJSON, writePrivateJSON } from './config.mjs';

const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
const hash = value => createHash('sha256').update(JSON.stringify(canonical(value))).digest('hex');
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const capabilityIdentity = value => JSON.stringify(value)
  .replace(/\/private\/tmp\/wmtools-[0-9a-f]{32}\/[0-9a-f]{32}\.sock/gi, '[Woven Matter session tool endpoint]')
  .replace(/\/home\/\.wmt\/[0-9a-f]{32}\/[0-9a-f]{32}\/(?:wovenmatter|rpc\.sock)/gi, '[Woven Matter session tool endpoint]');

export function canUseClaudeNativeCompaction(model) {
  return ['claude-subscription', 'anthropic'].includes(model?.provider) && model?.api === 'woven-claude-native';
}

// Native SDK disk persistence owns resume. This adapter only copies exposed
// transcript records into Woven's archive; null leaves the SDK's local resume
// environment intact rather than materializing an alternate transcript store.
function claudeTranscriptArchive(archive = async () => {}, runID) {
  const captureID = randomUUID(); let ordinal = 0, queue = Promise.resolve();
  return {
    append(key, entries) {
      const pending = queue.then(async () => {
        await archive(entries.map(entry => ({ id: `claude-sdk:${hash(key)}:${entry.uuid ?? `${captureID}:${ordinal++}`}`,
          revision: hash(entry), kind: `claude.sdk.transcript.${entry.type}`, payload: JSON.stringify({ key, entry }), contentMode: 'event',
          ...(runID ? { runID } : {}), ...(entry.message ? { projectionJSON: JSON.stringify(entry.message) } : {}) })));
      });
      queue = pending.catch(() => {}); return pending;
    },
    async load() { return null; },
  };
}

export async function openClaudeSession(model, request, options) {
  const scope = options.wovenNativeContext;
  if (!scope || !isAbsolute(scope.directory ?? '') || !uuid.test(scope.sessionID ?? '') || scope.provider !== model.provider ||
      scope.modelID !== model.id || typeof scope.accountID !== 'string' || !scope.accountID) throw new DefaultAgentError('Invalid Claude native continuation scope.');
  const routeKey = hash({ provider: model.provider, accountID: scope.accountID, authIdentity: scope.authIdentity ?? null, model: model.id,
    capabilities: capabilityIdentity({ system: request.system, tools: request.inventory }) });
  const workspace = join(scope.directory, 'claude-native', routeKey, 'workspace');
  await mkdir(workspace, { recursive: true, mode: 0o700 });
  const stateFile = join(workspace, 'current-context.json'), saved = await readJSON(stateFile, null);
  const frames = request.frames.map(frame => frame.message);
  const resume = saved?.resumable === true && uuid.test(saved.nativeSessionID ?? '') && Number.isSafeInteger(saved.frameCount) && saved.frameCount >= 0 && saved.frameCount <= frames.length &&
    hash(frames.slice(0, saved.frameCount)) === saved.prefixHash;
  const nativeSessionID = resume ? saved.nativeSessionID : randomUUID();
  return { workspace, routeKey, nativeSessionID, frames: request.frames.slice(resume ? saved.frameCount : 0),
    sdkOptions: { cwd: workspace, persistSession: true, sessionStore: claudeTranscriptArchive(scope.archive, scope.runID), sessionStoreFlush: 'eager',
      ...(resume ? { resume: nativeSessionID } : { sessionId: nativeSessionID }) },
    async commit(response) {
      const prefix = response ? [...frames, { role: 'assistant', content: response.content }] : frames;
      // The SDK may store its inventory-only result after a tool call. At that
      // boundary, replay canonical host results into a fresh native session.
      await writePrivateJSON(stateFile, { nativeSessionID, frameCount: prefix.length, prefixHash: hash(prefix), resumable: !response?.content.some(block => block.type === 'tool_use') });
      return { kind: 'claude-sdk', routeKey, nativeSessionID };
    },
  };
}
