import { createHash } from 'node:crypto'
import { existsSync, readFileSync, mkdirSync, openSync, writeSync, readSync, fsyncSync, closeSync, fstatSync, ftruncateSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { durableJSON } from './durable-json.mjs'

const hash = value => createHash('sha256').update(value).digest('hex')
const statePath = (directory, activity) => resolve(directory, 'activity-details', hash(activity.id) + '.json')
const recordPath = (directory, sha256) => resolve(directory, 'activity-details', 'records', sha256 + '.json')
function read(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')) }
  catch (error) { if (error.code !== 'ENOENT') throw error }
}
function preview(value) {
  let end = Math.min(2048, value.length)
  if (/[\uD800-\uDBFF]/.test(value[end - 1] ?? '')) end--
  return value.slice(0, end)
}
function projection(activity, state, content, contentIsDelta = false) {
  return { id: activity.id, kind: 'thought', title: 'Thinking', content, contentIsDelta,
    locations: [], changes: [], planEntries: [], detailsAvailable: true, detailVersion: state.version }
}
function logText(path, state, offset = state.baseLogOffset ?? 0) {
  if (offset === state.logOffset) return ''
  const file = openSync(path + 'l', 'r'), bytes = Buffer.alloc(state.logOffset - offset)
  try {
    let count = 0
    while (count < bytes.length) {
      const size = readSync(file, bytes, count, bytes.length - count, offset + count)
      if (!size) throw new Error('Reasoning accumulator is incomplete.')
      count += size
    }
  } finally { closeSync(file) }
  let text = ''
  for (const line of bytes.toString('utf8').trimEnd().split('\n')) {
    if (!line) continue
    const value = JSON.parse(line)
    text = value.snapshot ? value.text : text + value.text
  }
  return text
}
function append(path, state, value) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  const file = openSync(path + 'l', 'a+', 0o600), offset = state.logOffset ?? 0
  try {
    const size = fstatSync(file).size
    if (size < offset) throw new Error('Reasoning accumulator is incomplete.')
    // A crash can leave an uncommitted trailing write. The small metadata file
    // is the commit point; truncate only bytes beyond its acknowledged offset.
    if (size > offset) ftruncateSync(file, offset)
    const bytes = Buffer.from(JSON.stringify(value) + '\n')
    let written = 0
    while (written < bytes.length) written += writeSync(file, bytes, written, bytes.length - written)
    fsyncSync(file)
    state.logOffset = offset + bytes.length
    if (value.snapshot) state.baseLogOffset = offset
  } finally { closeSync(file) }
}
function materialize(directory, path, activity, state, force) {
  const detail = force ? state.preview.toWellFormed() : state.preview
  // Bases grow geometrically; between them immutable suffixes keep disclosures
  // current while storage/transfer grows with supplied text, not text squared.
  let base = force || state.reset || !state.published?.recordID || state.contentBytes >= 2 * (state.baseByteCount ?? 0)
  let full
  if (base || state.contentBytes <= 16384) {
    const text = logText(path, state)
    full = projection(activity, state, force ? text.toWellFormed() : text)
    const json = JSON.stringify(full)
    if (Buffer.byteLength(json) <= 16384) return { row: { detail, projectionJSON: json } }
  }
  const envelope = base ? { activity: full } : {
    activity: projection(activity, state, logText(path, state, state.emittedOffset), true),
    previousDetailsRecordID: state.published.recordID,
  }
  if (base) state.baseByteCount = state.contentBytes
  const bytes = Buffer.from(JSON.stringify(envelope)), sha256 = hash(bytes), recordID = 'activity-' + hash(activity.id) + '-' + sha256
  const file = recordPath(directory, sha256)
  if (!existsSync(file)) durableJSON(file, envelope)
  return { row: { detail, projectionJSON: JSON.stringify(projection(activity, state, detail)), detailsRecordID: recordID },
    recordID, sha256, linked: !base }
}
function parts(directory, result) {
  if (!result.recordID) return []
  const bytes = readFileSync(recordPath(directory, result.sha256)), partCount = Math.ceil(bytes.length / 131072)
  return Array.from({ length: partCount }, (_, partIndex) => ({ recordID: result.recordID, format: 'wovenmatter.activity.v2',
    partIndex, partCount, byteCount: bytes.length, sha256: result.sha256, data: bytes.subarray(partIndex * 131072, (partIndex + 1) * 131072).toString('base64') }))
}
function apply(activity, row) {
  delete activity.detailsRecordID
  Object.assign(activity, row)
}
function publish(directory, path, activity, state, now, force = false) {
  state.published = materialize(directory, path, activity, state, force)
  state.emittedAt = now; state.emittedOffset = state.logOffset; state.emittedVersion = state.version
  // A forced mid-run disclosure may normalize a pending high surrogate. Its
  // raw partner still belongs to the next input, so the next publication must
  // replace that normalized base rather than append an isolated low surrogate.
  state.reset = force && /[\uD800-\uDBFF]/.test(state.lastUnit ?? '')
  return state.published
}

// Append each incoming text once and atomically commit bounded metadata. Exact
// emission descriptors refer to immutable files, so retries never depend on time
// and neither full text nor old checkpoints are rewritten on every token.
export function updateReasoningDetails(directory, activity, update, revisionKey, now = Date.now()) {
  const path = statePath(directory, activity), previous = read(path)
  let state = previous
  if (previous?.revisionKey !== revisionKey) {
    let text = update.content?.text ?? '', snapshot = update._meta?.wovenThoughtSnapshot === true
    state = { ...previous, revisionKey, logOffset: previous?.logOffset ?? 0, version: previous?.version ?? 0 }
    if (snapshot && previous) {
      const prior = logText(path, previous)
      if (text.startsWith(prior)) { text = text.slice(prior.length); snapshot = false }
    } else if (!previous && !snapshot) text = (activity.detail ?? '') + text
    const changed = !!text || snapshot
    if (changed) {
      append(path, state, { text, snapshot })
      state.version++
      state.reset = previous?.reset || snapshot
      const pendingUnit = /[\uD800-\uDBFF]/.test(previous?.lastUnit ?? '') ? previous.lastUnit : ''
      state.preview = snapshot ? preview(text) : (previous?.contentUnits ?? 0) < 2048
        ? preview(preview(previous?.preview ?? '') + pendingUnit + text) : preview(previous.preview)
      // Buffer.byteLength encodes lone surrogates as replacements; joining a
      // split pair removes two bytes from that sum. JSONL itself preserves them.
      const joinsPair = /[\uD800-\uDBFF]/.test(previous?.lastUnit ?? '') && /^[\uDC00-\uDFFF]/.test(text)
      state.contentBytes = snapshot ? Buffer.byteLength(text) : (previous?.contentBytes ?? 0) + Buffer.byteLength(text) - (joinsPair ? 2 : 0)
      state.contentUnits = snapshot ? text.length : (previous?.contentUnits ?? 0) + text.length
      state.lastUnit = text.at(-1) ?? ''
    } else {
      state.preview ??= ''; state.contentBytes ??= 0; state.contentUnits ??= 0
    }
    // A JSON string containing half of a split UTF-16 pair cannot be decoded
    // by native clients. Wait for its partner; source bytes remain in the log.
    const ready = !/[\uD800-\uDBFF]/.test(state.lastUnit ?? '')
    if (!state.published && !ready) state.published = { row: { detail: '', projectionJSON: JSON.stringify(projection(activity, { ...state, version: 0 }, '')) } }
    const emit = ready && (!previous?.published || state.reset || (state.version !== state.emittedVersion
      && (now - (previous.emittedAt ?? 0) >= 400 || state.contentBytes < 12000)))
    state.revisionResult = emit ? publish(directory, path, activity, state, now) : { row: state.published.row }
    durableJSON(path, state)
  }
  apply(activity, state.revisionResult.row)
  return parts(directory, state.revisionResult)
}

export function flushReasoningDetails(directory, activity, { force = false, now = Date.now() } = {}) {
  const path = statePath(directory, activity), state = read(path)
  if (!state) return []
  if (state.emittedVersion !== state.version || (force && state.published?.linked)) {
    if (!force && (now - (state.emittedAt ?? 0) < 400 || /[\uD800-\uDBFF]/.test(state.lastUnit ?? ''))) return null
    publish(directory, path, activity, state, now, force)
    durableJSON(path, state)
  }
  const result = state.published
  if (activity.projectionJSON === result.row.projectionJSON && activity.detailsRecordID === result.row.detailsRecordID) return []
  apply(activity, result.row)
  return parts(directory, result)
}
