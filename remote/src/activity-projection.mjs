import { existsSync, mkdirSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { randomUUID } from 'node:crypto'
import { durableJSON, read, sha256 as hash } from './durable-json.mjs'

// Canonical `AgentRunActivity` projections for a run's tools, plans,
// commentary and Pi Durable subagents, as the Mac's ACP client builds them
// (`LocalACPClient.projectedEvent`). A transcript row carries the bounded
// presentation summary (`AgentRunActivity.presentationSummary`); the full
// projection stays on this machine, is read on disclosure
// (`GET v1/execution/conversations/<id>/activity`), and is journaled once
// the activity settles so library history can disclose it too.

const preview = 280
const fullPath = (directory, id) => resolve(directory, 'activity-details', 'tools', hash(id) + '.json')
const recordPath = (directory, sha256) => resolve(directory, 'activity-details', 'records', sha256 + '.json')
const partBytes = 131072
const base = id => ({ id, locations: [], changes: [], planEntries: [] })
const text = value => typeof value === 'string' ? value : undefined
const json = value => value === undefined ? undefined : JSON.stringify(value)
const terminal = status => ['completed', 'failed', 'cancelled', 'interrupted'].includes(status)

function writeQuickly(path, value) {
  // The raw native updates are journaled already; this is a cache for disclosure.
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = `${path}.${randomUUID()}.tmp`
  writeFileSync(temporary, JSON.stringify(value), { mode: 0o600 })
  renameSync(temporary, path)
}

function displayToolName(value) {
  if (!value) return 'Tool'
  return String(value).replace(/[_-]/g, ' ').split(' ').filter(Boolean).map(word => word[0].toUpperCase() + word.slice(1)).join(' ')
}

// The changed line counts a compact row shows (`AgentRunFileChange.additions`).
export function lineCounts(oldText = '', newText = '', unifiedDiff) {
  if (unifiedDiff) {
    let additions = 0, deletions = 0
    for (const line of unifiedDiff.split('\n')) {
      if (line.startsWith('+++') || line.startsWith('---')) continue
      if (line.startsWith('+')) additions++
      else if (line.startsWith('-')) deletions++
    }
    return { additions, deletions }
  }
  let before = (oldText ?? '').split('\n'), after = newText.split('\n')
  while (before.length && after.length && before[0] === after[0]) { before.shift(); after.shift() }
  while (before.length && after.length && before.at(-1) === after.at(-1)) { before.pop(); after.pop() }
  if (before.length * after.length > 4_000_000) return { additions: after.length, deletions: before.length }
  // Longest common subsequence of the differing middle, as Swift's `difference(from:)`.
  let previous = new Array(after.length + 1).fill(0)
  for (let i = 1; i <= before.length; i++) {
    const row = new Array(after.length + 1).fill(0)
    for (let j = 1; j <= after.length; j++) row[j] = before[i - 1] === after[j - 1] ? previous[j - 1] + 1 : Math.max(previous[j], row[j - 1])
    previous = row
  }
  const common = previous[after.length]
  return { additions: after.length - common, deletions: before.length - common }
}

// One ACP `tool_call` or `tool_call_update` merged onto what the tool had.
export function toolActivity(update, previous, id) {
  const items = Array.isArray(update.content) ? update.content : null
  const parts = [], changes = []
  for (const item of items ?? []) {
    if (item?.type === 'diff' && typeof item.path === 'string' && typeof item.newText === 'string') {
      changes.push({ path: item.path, ...(typeof item.oldText === 'string' ? { oldText: item.oldText } : {}), newText: item.newText,
        ...(typeof item.diff === 'string' ? { unifiedDiff: item.diff } : {}) })
    } else {
      const value = item?.content?.text ?? item?.text
      if (typeof value === 'string' && value) parts.push(value)
    }
  }
  const delta = !parts.length ? text(update._meta?.terminal_output_delta?.data) ?? text(update._meta?.mcp_output_delta?.data) : undefined
  const locations = (Array.isArray(update.locations) ? update.locations : []).flatMap(value =>
    typeof value?.path === 'string' ? [{ path: value.path, ...(Number.isSafeInteger(value.line) ? { line: value.line } : {}) }] : [])
  const status = text(update.status)
  const phase = status === 'completed' || status === 'failed' ? 'end' : status === 'in_progress' ? 'update' : previous ? 'update' : 'start'
  const prior = previous ?? base(id)
  const content = delta !== undefined ? (prior.content ?? '') + delta : items ? parts.join('\n\n') : prior.content
  return { ...prior, id, kind: 'tool', phase,
    title: text(update.title) ?? prior.title ?? (previous ? undefined : displayToolName(update.kind)),
    status: status ?? prior.status ?? 'pending', toolName: text(update.kind) ?? prior.toolName,
    ...(content !== undefined ? { content } : {}), contentIsDelta: false,
    locations: locations.length ? locations : prior.locations, changes: changes.length ? changes : prior.changes,
    ...(update.rawInput !== undefined ? { rawInputJSON: json(update.rawInput) } : {}),
    ...(update.rawOutput !== undefined ? { rawOutputJSON: json(update.rawOutput) } : {}),
    rawPayloadJSON: json(update) }
}

// An ACP `plan` update: the run's one checklist, replaced as a whole.
export function planActivity(update, id) {
  const entries = (Array.isArray(update.entries) ? update.entries : []).flatMap(value =>
    typeof value?.content === 'string' && typeof value?.status === 'string'
      ? [{ content: value.content, status: value.status, ...(typeof value.priority === 'string' ? { priority: value.priority } : {}), ...(typeof value.id === 'string' ? { nativeID: value.id } : {}) }] : [])
  return { ...base(id), kind: 'plan', phase: entries.length ? 'update' : 'clear', title: 'Plan',
    status: entries.every(entry => entry.status === 'completed') ? 'completed' : 'running', planEntries: entries,
    planKind: 'checklist', planOperation: entries.length ? 'replace' : 'clear' }
}

// Pi Durable's `woven_subagents` snapshot (`AgentRunActivity.builtInSubagentSnapshot`).
export function subagentActivity(update, id) {
  const subagents = Array.isArray(update.subagents) ? update.subagents.filter(item => typeof item?.id === 'string') : []
  const idle = ['idle', 'completed', 'done', 'succeeded', 'failed', 'error', 'cancelled', 'canceled', 'stopped', 'aborted']
  const active = subagents.filter(item => !idle.includes(String(item.state ?? '').toLowerCase())).length
  return { ...base(id), kind: 'activity', phase: 'update', title: 'Subagents', detail: `${active} active · ${subagents.length} total`,
    status: active ? 'running' : 'completed', subagents, rawPayloadJSON: json(update) }
}

// Frozen assistant text that preceded later work in the run.
export function commentaryActivity(id, messageID, content) {
  return { ...base(id), kind: 'assistant', assistantMessageID: messageID, content }
}

// `AgentRunActivity.presentationSummary`: bounded fields, line counts in
// place of file texts, no raw data, and whether a disclosure has more.
export function summary(full, version) {
  const short = value => typeof value === 'string' ? value.slice(0, preview) : value
  const keepsContent = full.kind === 'assistant' || full.kind === 'plan'
  const content = keepsContent ? full.content : short(full.content)
  const changes = (full.changes ?? []).map(change => {
    const counts = lineCounts(change.oldText, change.newText, change.unifiedDiff)
    return { path: change.path, newText: '', additionCount: counts.additions, deletionCount: counts.deletions }
  })
  const value = { id: full.id, kind: full.kind, locations: full.locations ?? [], changes, planEntries: full.planEntries ?? [] }
  for (const key of ['phase', 'status', 'toolName', 'contentIsDelta', 'assistantMessageID', 'position', 'planKind', 'planOperation']) {
    if (full[key] !== undefined) value[key] = full[key]
  }
  if (full.title !== undefined) value.title = short(full.title)
  if (full.detail !== undefined) value.detail = short(full.detail)
  if (content !== undefined) value.content = content
  const more = full.rawInputJSON != null || full.rawOutputJSON != null || full.rawPayloadJSON != null || (full.subagents?.length ?? 0) > 0
    || (full.changes?.length ?? 0) > 0 || content !== full.content || value.title !== full.title || value.detail !== full.detail
  if (more) value.detailsAvailable = true
  if (version !== undefined) value.detailVersion = version
  return value
}

// Stores a new full projection for `row` and refreshes the row's summary.
export function storeActivity(directory, row, full) {
  const path = fullPath(directory, row.id), version = (read(path)?.detailVersion ?? 0) + 1
  const stored = { ...full, detailVersion: version }
  const compact = summary(stored, version)
  if (compact.detailsAvailable) writeQuickly(path, stored)
  row.projectionJSON = JSON.stringify(compact)
  delete row.detailsRecordID
  return stored
}

export function storedActivity(directory, id) {
  return read(fullPath(directory, id))
}

// A settled activity's full projection, as an immutable journal record
// (`wovenmatter.activity.v2`) that library history discloses from.
export function settleActivity(directory, row) {
  if (row.detailsRecordID) return []
  const full = storedActivity(directory, row.id)
  if (!full) return []
  const { detailVersion, ...activity } = full
  const bytes = Buffer.from(JSON.stringify({ activity: { ...activity, contentIsDelta: false } })), sha256 = hash(bytes)
  const recordID = 'activity-' + hash(row.id) + '-' + sha256, file = recordPath(directory, sha256)
  if (!existsSync(file)) durableJSON(file, JSON.parse(bytes))
  row.detailsRecordID = recordID
  const partCount = Math.max(1, Math.ceil(bytes.length / partBytes))
  return Array.from({ length: partCount }, (_, partIndex) => ({ recordID, format: 'wovenmatter.activity.v2', partIndex, partCount,
    byteCount: bytes.length, sha256, data: bytes.subarray(partIndex * partBytes, (partIndex + 1) * partBytes).toString('base64') }))
}

// A row's complete projection for disclosure: the stored tool projection,
// a reasoning record chain, or the row itself when it is complete.
export function activityDetails(directory, row) {
  const stored = storedActivity(directory, row.id)
  if (stored) return JSON.stringify(stored)
  if (row.detailsRecordID) {
    const suffixes = [], seen = new Set()
    let next = row.detailsRecordID, head
    while (next) {
      const sha256 = /^activity-[0-9a-f]{64}-([0-9a-f]{64})$/.exec(next)?.[1]
      if (!sha256 || seen.has(next) || seen.size > 16384) break
      seen.add(next)
      const envelope = read(recordPath(directory, sha256))
      if (!envelope?.activity) break
      head ??= envelope.activity
      suffixes.push(envelope.activity.content ?? '')
      if (!envelope.activity.contentIsDelta) return JSON.stringify({ ...head, content: suffixes.reverse().join(''), contentIsDelta: false })
      next = envelope.previousDetailsRecordID
    }
  }
  return row.projectionJSON ?? null
}

export { terminal as settled }
