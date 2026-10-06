import { existsSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createHash } from 'node:crypto'

const bundled = new URL('../default-agent/src/native-journal.mjs', import.meta.url)
const { openNativeArchive, sanitizeNativeTransportBytes, nativePresentationUpdates } = await import(
  existsSync(bundled) ? bundled.href : new URL('../../default-agent/src/native-journal.mjs', import.meta.url).href)

// Use the same exact records, large-record chunks, checksums and manifests as
// Built-in transport. This spool belongs only to the current scheduled run.
export async function createTaskNativeArchive({sourceID, nativeSessionID, runID, publish}) {
  const directory = await mkdtemp(join(tmpdir(), 'woven-task-native-'))
  const archive = await openNativeArchive(join(directory, 'records.jsonl'))
  let pending = Promise.resolve(), after = 0, ordinal = 0
  return {
    capture(value, {id, kind, contentMode = 'event', completeness = 'observed', currentRun = true, present} = {}) {
      const eventID = id ?? `event:${runID}:${++ordinal}`
      const operation = pending.then(async () => {
        const safe = await sanitizeNativeTransportBytes(JSON.stringify(value))
        const payload = safe.bytes.toString('utf8'), native = JSON.parse(payload)
        const record = {id: eventID, revision: createHash('sha256').update(payload).digest('hex'), kind,
          payload, contentMode, text: searchableText(native), completeness, ...(currentRun ? {runID} : {}),
          ...(safe.byteFidelity !== 'exact-native-bytes' ? {projectionJSON: JSON.stringify({payloadByteFidelity: safe.byteFidelity, sourcePayloadSHA256: safe.sourceSHA256, payloadSHA256: safe.sha256})} : {})}
        if (archive.identities.has(`${record.id}:${record.revision}`)) return native
        await archive.append([record])
        do {
          const page = await archive.page(after, 200)
          publish({sessionUpdate: 'woven_native_record', recordBatch: {
            schemaVersion: 1, sourceID, nativeSessionID, records: page.records}})
          after = page.nextAfter
          if (!page.hasMore) break
        } while (true)
        present?.(native)
        return native
      })
      pending = operation
      operation.catch(() => {})
      return operation
    },
    drain: () => pending,
    async close() { await pending.catch(() => {}); await rm(directory, {recursive: true, force: true}) },
  }
}

export const piRunEvent = type => typeof type === 'string'
  && (type === 'extension_ui_request' || ['agent_', 'message_', 'tool_', 'turn_', 'auto_compaction_', 'auto_retry_'].some(prefix => type.startsWith(prefix)))
export const hermesRunEvent = type => typeof type === 'string'
  && !['config.', 'auth.', 'credential.', 'secret.', 'sudo.'].some(prefix => type.startsWith(prefix))

const textKeys = ['message', 'content', 'text', 'thinking', 'reasoning', 'summary', 'output', 'result', 'result_text', 'payload', 'assistantMessageEvent', 'delta', 'arguments', 'args', 'input']
function searchableText(value, remaining = {characters: 256 * 1024}) {
  if (!remaining.characters) return undefined
  if (typeof value === 'string') {
    const text = value.slice(0, remaining.characters)
    remaining.characters -= text.length
    return text
  }
  if (Array.isArray(value)) return value.map(item => searchableText(item, remaining)).filter(Boolean).join('\n')
  if (!value || typeof value !== 'object') return undefined
  return textKeys.map(key => searchableText(value[key], remaining)).filter(Boolean).join('\n') || undefined
}

export function publishNativePresentation(update, publish) {
  for (const preview of nativePresentationUpdates(update)) publish(preview)
}

export function isolateTaskEnvironment(environment) {
  const isolated = {...environment}
  for (const key of Object.keys(isolated)) {
    if (key.startsWith('WOVENMATTER_SESSION_') || key.startsWith('WOVENMATTER_TOOL_')
      || ['WOVENMATTER_CONTEXT_ID', 'WOVENMATTER_NOTE_ID', 'WOVENMATTER_SOCKET', 'WOVENMATTER_CLI'].includes(key)) delete isolated[key]
  }
  return isolated
}
