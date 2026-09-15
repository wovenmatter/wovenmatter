import { createHash, randomUUID } from 'node:crypto'
import { mkdirSync, openSync, writeFileSync, fsyncSync, closeSync, renameSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'

const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex')
const validID = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value)
const validConsumer = value => typeof value === 'string' && /^[a-z0-9-]{1,80}$/.test(value)

// Hook callbacks write before returning: an unawaited observational hook must
// not leave a promise racing transcript pruning or ordinary Gateway shutdown.
export function durableJSON(path, value) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = `${path}.${randomUUID()}.tmp`
  const file = openSync(temporary, 'wx', 0o600)
  try { writeFileSync(file, JSON.stringify(value)); fsyncSync(file) }
  finally { closeSync(file) }
  renameSync(temporary, path)
  const directory = openSync(dirname(path), 'r')
  try { fsyncSync(directory) } finally { closeSync(directory) }
}

function readJSON(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')) }
  catch (error) { if (error.code === 'ENOENT') return null; throw error }
}

function names(directory) {
  try { return readdirSync(directory).filter(name => /^[a-f0-9]{64}\.json$/.test(name)).sort() }
  catch (error) { if (error.code === 'ENOENT') return []; throw error }
}

export function createResultStore(directory) {
  const root = resolve(directory)
  let lastError = null
  const path = (kind, id) => resolve(root, kind, `${id}.json`)
  const sessionIdentity = (jobID, sessionID) => digest([jobID, sessionID])

  function finish(id, completion) {
    if (readJSON(path('results', id))) return
    const run = completion.run
    const transcript = run.sessionId && readJSON(path('transcripts', sessionIdentity(run.jobId, run.sessionId)))
    let output = transcript?.sessionKey === run.sessionKey ? transcript.output : undefined
    if (!output && run.status !== 'ok') output = run.error || run.summary || `OpenClaw reported ${run.status}.`
    if (!output) return // A summary is not a full successful result.
    durableJSON(path('results', id), { ...completion, output })
  }

  function captureAgent(event, context) {
    const { sessionId, sessionKey } = context
    const jobId = /^agent:[^:]+:cron:([^:]+):run:[^:]+$/.exec(sessionKey ?? '')?.[1]
    if (!jobId || !sessionId || (context.jobId && context.jobId !== jobId)) return
    // Isolated run identity owns this transcript. Main/reused sessions cannot
    // be attributed from timestamps or a last-message heuristic.
    const replies = event.messages.filter(message => message.role === 'assistant'
      && !['toolUse', 'tool_use', 'error', 'aborted'].includes(message.stopReason))
    const output = replies.map(message => typeof message.content === 'string' ? message.content
      : (Array.isArray(message.content) ? message.content : [])
        .filter(block => block.type === 'text').map(block => block.text).join('\n\n'))
      .filter(Boolean).join('\n\n')
    if (!output) return
    durableJSON(path('transcripts', sessionIdentity(jobId, sessionId)), { output, sessionKey, sessionId })
    // The two native hooks may arrive in either order, including across restart.
    const pending = readJSON(path('sessions', sessionIdentity(jobId, sessionId)))
    if (pending) finish(pending.id, readJSON(path('completions', pending.id)))
  }

  function captureCron(event) {
    if (event.action !== 'finished') return
    if (!event.jobId || !Number.isSafeInteger(event.runAtMs) || !Number.isFinite(event.durationMs)) {
      throw new Error('Scheduled run has no stable completion identity.')
    }
    const run = { ...event, ts: event.runAtMs + event.durationMs }
    delete run.job
    const id = digest([run.jobId, run.runId ?? `history:${run.jobId}:${run.ts}`])
    const completion = { id, run, title: event.job?.name ?? 'Scheduled result', storedAt: new Date().toISOString() }
    durableJSON(path('completions', id), completion)
    if (run.sessionId) durableJSON(path('sessions', sessionIdentity(run.jobId, run.sessionId)), { id })
    finish(id, completion)
  }

  function list({ consumer, after = '', limit = 100 } = {}) {
    if (!validConsumer(consumer) || (after && !validID(after)) || !Number.isInteger(limit) || limit < 1 || limit > 100) {
      throw new Error('Invalid scheduled-result page.')
    }
    const pending = names(resolve(root, 'completions')).filter(name => name.slice(0, -5) > after
      && !readJSON(path(`receipts/${consumer}`, name.slice(0, -5))))
    const selected = pending.slice(0, limit)
    const entries = selected.map(name => {
      const id = name.slice(0, -5)
      const completion = readJSON(path('completions', id))
      finish(id, completion)
      const result = readJSON(path('results', id))
      return { ...completion, available: Boolean(result), error: result ? null
        : 'Full output is not retained yet. Collection will retry; main-session and command jobs require native transcript support.' }
    })
    return { entries, next: pending.length > selected.length ? selected.at(-1).slice(0, -5) : null,
      error: lastError ?? readJSON(resolve(root, 'error.json'))?.message ?? null }
  }

  function output({ id, offset = 0 } = {}) {
    if (!validID(id) || !Number.isSafeInteger(offset) || offset < 0) throw new Error('Invalid scheduled-result cursor.')
    const result = readJSON(path('results', id))
    if (!result || offset > result.output.length) throw new Error('Scheduled result is unavailable.')
    let end = Math.min(offset + 65536, result.output.length)
    // Do not split a UTF-16 surrogate pair across JSON strings.
    if (end < result.output.length && /[\uD800-\uDBFF]/.test(result.output[end - 1])) end--
    return { text: result.output.slice(offset, end), nextOffset: end < result.output.length ? end : null }
  }

  function acknowledge({ consumer, id } = {}) {
    if (!validConsumer(consumer) || !validID(id) || !readJSON(path('results', id))) throw new Error('Invalid scheduled-result receipt.')
    durableJSON(path(`receipts/${consumer}`, id), { collectedAt: new Date().toISOString() })
    return { acknowledged: true }
  }

  function recordFailure() {
    lastError = 'The host could not retain a scheduled result. Check available disk space and Gateway logs.'
    durableJSON(resolve(root, 'error.json'), { message: lastError })
  }

  return { captureAgent, captureCron, list, output, acknowledge, recordFailure }
}
