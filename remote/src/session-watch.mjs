import { createHash } from 'node:crypto'
import { createStreamClient } from './stream-client.mjs'
import { maximumWakeUpsPerRun } from './stream-protocol.mjs'

// Agent-to-agent waiting (docs/architecture/WOVEN_EVERYWHERE.md, "Streaming",
// "Agent to agent"; the exact behaviour is documented on Swift's
// `SessionWakeUp`, which a Mac matches). `woven_sessions_wait` resolves from
// live changes instead of polling, and a session an agent here created on any
// workspace wakes that agent when it finishes or asks a question.
//
// Changes come from one stream per destination server (its `workspace`
// stream, filtered here to the sessions this server watches), or, for this
// machine's own workspace, from the in-process execution changes. Watched
// sessions and pending wake-ups are stored, so both survive a restart: the
// stream's first snapshot is compared with the stored state.

const stableID = value => {
  const h = createHash('sha256').update('woven-session-wake-up-v1\0' + value).digest('hex')
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`
}
const stamp = () => new Date().toISOString()
const isBot = callerID => String(callerID).startsWith('woven:bot:')

/** Exactly `woven_sessions_status`'s state. */
export function sessionState({ conversation, pending = [] }) {
  return pending.length ? 'needsInput' : conversation?.activeRunID ? 'running' : 'idle'
}
/** Whether `state` is what `woven_sessions_wait`'s `until` asks for. */
export const reaches = (state, until) => until === 'either' ? state === 'idle' || state === 'needsInput' : state === until

function clean(value, limit) {
  if (typeof value !== 'string') return null
  const words = value.split(/\s+/).filter(Boolean).join(' ')
  if (!words) return null
  const scalars = Array.from(words)
  return scalars.length > limit ? scalars.slice(0, limit).join('') + '…' : words
}

/** The message a wake-up delivers (Swift `SessionWakeUp.text`; SessionWakeUpFixtures.json). */
export function wakeUpText({ kind, sessionID, title, workspaceName, question, last = false }) {
  const named = clean(title, 200), name = named ? `"${named}" (${sessionID})` : sessionID
  let text
  if (kind === 'finished') text = `Your session ${name} on ${workspaceName} finished. Read it with woven_sessions_status.`
  else {
    const asked = clean(question, 300) ?? 'a question', stop = /[.?!…]$/u.test(asked) ? '' : '.'
    text = `Your session ${name} on ${workspaceName} is waiting for your answer: ${asked}${stop} Read it with woven_sessions_status and answer with woven_sessions_respond.`
  }
  if (last) text += ' This is your last wake-up until something else starts you: wait with woven_sessions_wait or check woven_sessions_status yourself.'
  return text
}

const pendingKey = pending => [...new Set(pending.map(item => String(item.id)))].sort().join(',')

/**
 * One destination's sessions, from its `workspace` stream. Only the sessions
 * `interesting()` names (or `track` adds) are kept; the rest of each snapshot
 * is reduced to its IDs. `listen(fn)` gets `(id, {state, conversation,
 * pending})` for every change of a kept session after the stream has
 * synchronized, and `missing` for one the destination removed or a full
 * snapshot left out.
 */
export function createRemoteSessionSource({ endpoint, sign, expected = null, interesting = () => new Set(), webSocket, timings, log = () => {}, resubscribeMilliseconds = 5_000 }) {
  const listeners = new Set(), tracked = new Map(), conversations = new Map(), pending = new Map(), known = new Set(), removed = new Set()
  let ready = false, closed = false, subscription = null, timer = null, snapshotting = false
  // `expected` ({workspaceID, libraryID}): a server whose hello names another
  // workspace is closed, and none of its sessions are used.
  const client = createStreamClient({ endpoint, sign, expected, ...(webSocket ? { webSocket } : {}), ...(timings ? { timings } : {}),
    onEvent: event => {
      if (event.type === 'closed') ready = false
      if (event.type === 'refused' && event.status) log(`The stream to ${endpoint} was refused (${event.status}).`)
      if (event.type === 'mismatch') log(`The stream at ${endpoint} serves workspace ${event.hello.workspaceID} of library ${event.hello.libraryID}, not ${expected?.workspaceID}; it is not used.`)
    } })
  const wanted = () => new Set([...tracked.keys(), ...interesting()])
  function emit(ids) {
    if (!ready) return
    for (const id of ids) {
      const conversation = conversations.get(id)
      // Not kept (it became interesting after the snapshot) or not seen yet
      // (just created there): its next change says.
      if (!conversation && !removed.has(id)) continue
      const items = pending.get(id) ?? []
      const info = conversation ? { state: sessionState({ conversation, pending: items }), conversation, pending: items } : { state: 'missing', conversation: null, pending: [] }
      for (const listener of listeners) { try { listener(id, info) } catch {} }
    }
  }
  function receive(frame) {
    const keep = wanted()
    if (frame.kind === 'conversations') {
      const data = frame.data ?? {}
      if (data.snapshot) { ready = false; snapshotting = true; known.clear(); conversations.clear() }
      for (const conversation of data.conversations ?? []) {
        const id = String(conversation?.id ?? '').toLowerCase()
        if (!id) continue
        known.add(id); removed.delete(id)
        if (keep.has(id)) conversations.set(id, conversation); else conversations.delete(id)
      }
      for (const raw of data.deletedConversationIDs ?? []) { const id = String(raw).toLowerCase(); known.delete(id); conversations.delete(id); removed.add(id) }
    } else if (frame.kind === 'pending') {
      pending.clear()
      for (const interaction of frame.data?.interactions ?? []) {
        const id = String(interaction?.conversationID ?? '').toLowerCase()
        if (keep.has(id)) pending.set(id, [...pending.get(id) ?? [], interaction])
      }
    } else if (frame.kind === 'synchronized') {
      // A kept session the whole snapshot left out is gone from there.
      if (snapshotting) for (const id of keep) if (!known.has(id)) removed.add(id)
      snapshotting = false; ready = true
    } else return
    emit(keep)
  }
  function open() {
    if (closed) return
    subscription = client.subscribe('workspace', {}, { onItem: receive,
      // Ended for another reason than falling behind: subscribe again shortly.
      onEnd: error => { ready = false; subscription = null; if (error) log(`The ${endpoint} stream ended: ${error.message}`); clearTimeout(timer); timer = setTimeout(open, resubscribeMilliseconds); timer.unref?.() } })
  }
  open()
  client.connect()
  return {
    listen(listener) { listeners.add(listener); return () => listeners.delete(listener) },
    /** Keeps `id` even when `interesting()` does not name it (a wait on a session this caller did not create). */
    track(id) { tracked.set(id, (tracked.get(id) ?? 0) + 1); return () => { const count = tracked.get(id) - 1; if (count > 0) tracked.set(id, count); else tracked.delete(id) } },
    /** Emits the kept sessions' current state again (after the coordinator's own state changed). */
    sync() { emit(wanted()) },
    /**
     * Drops what this source last heard of `id`: the caller acted on it, or
     * stopped watching it, so that state is superseded; its next change says.
     * Without this, a session sent to again within the linger would replay
     * its old idle state as a new finish.
     */
    forget(id) { conversations.delete(id); pending.delete(id) },
    retry: () => client.retry(),
    ready: () => ready,
    close() { closed = true; clearTimeout(timer); subscription?.cancel(); client.close() },
  }
}

/** This workspace's own sessions, from in-process execution changes (`execution.watch`). */
export function createLocalSessionSource({ summary, watch, interesting = () => new Set(), defer = setImmediate }) {
  const listeners = new Set(), tracked = new Map(), queued = new Set()
  let scheduled = false
  const wanted = () => new Set([...tracked.keys(), ...interesting()])
  function emit(ids) {
    for (const id of ids) {
      let value = null
      try { value = summary(id) } catch {}
      const info = value ? { state: sessionState(value), conversation: value.conversation, pending: value.pending ?? [] } : { state: 'missing', conversation: null, pending: [] }
      for (const listener of listeners) { try { listener(id, info) } catch {} }
    }
  }
  // Changes arrive inside the saving transaction: read them once it is done.
  function flush() {
    scheduled = false
    const keep = wanted(), ids = [...queued].filter(id => keep.has(id))
    queued.clear()
    emit(ids)
  }
  const off = watch(change => {
    if (change.kind !== 'record' && change.kind !== 'deleted') return
    queued.add(String(change.conversationID).toLowerCase())
    if (!scheduled) { scheduled = true; defer(flush) }
  })
  return {
    listen(listener) { listeners.add(listener); return () => listeners.delete(listener) },
    track(id) { tracked.set(id, (tracked.get(id) ?? 0) + 1); return () => { const count = tracked.get(id) - 1; if (count > 0) tracked.set(id, count); else tracked.delete(id) } },
    sync() { defer(() => emit(wanted())) },
    // The local summary is read when it is emitted, so nothing is cached.
    forget() {},
    retry() {},
    ready: () => true,
    close() { off() },
  }
}

/**
 * The watched sessions, waits and wake-ups of this server's callers.
 *
 * - `sourceFor(workspaceID, {interesting})` opens a source for one workspace
 *   (`createRemoteSessionSource` or `createLocalSessionSource`), or returns null.
 * - `caller(callerID)` is `{kind: 'conversation', idle, latestRunID}`,
 *   `{kind: 'bot', botID}`, or null for a caller that no longer exists.
 * - `deliverToConversation({callerID, commandID, text, sessionID, title, harness})`
 *   sends into an idle calling conversation and returns the command's receipt.
 * - `deliverToBot({botID, text, deliveryID})` hands a wake-up to the bots runtime.
 */
export function createSessionWatch({ db, sourceFor, caller, deliverToConversation, deliverToBot = null, log = () => {},
  retryMilliseconds = 30_000, lingerMilliseconds = 60_000, maximumWakeUps = maximumWakeUpsPerRun, maximumDeliveryAttempts = 20 }) {
  db.exec(`CREATE TABLE IF NOT EXISTS member_sessions (id TEXT PRIMARY KEY, caller TEXT NOT NULL, workspace TEXT NOT NULL, created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS member_session_watch (id TEXT PRIMARY KEY, caller TEXT NOT NULL, workspace TEXT NOT NULL, workspace_name TEXT, title TEXT, harness TEXT,
      state TEXT NOT NULL, run_id TEXT, questions TEXT, updated_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS member_session_wakeups (id TEXT PRIMARY KEY, caller TEXT NOT NULL, workspace TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL,
      title TEXT, workspace_name TEXT, harness TEXT, question TEXT, attempt INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS member_session_wakeups_caller ON member_session_wakeups(caller);
    CREATE TABLE IF NOT EXISTS member_session_wakeup_counts (caller TEXT PRIMARY KEY, run_id TEXT, count INTEGER NOT NULL);`)
  const sources = new Map(), held = new Map(), chains = new Map(), retries = new Map(), waits = new Map(), failures = new Map()
  // A transient failure is retried after `retryMilliseconds`, doubling to 16 times that.
  const backoff = attempt => retryMilliseconds * 2 ** Math.min(Math.max(0, attempt), 4)
  let listening = 0
  const waitKey = (callerID, id) => callerID + '\0' + id
  // A caller waiting on a session learns its state from the wait itself.
  const awaited = wakeUp => waits.has(waitKey(wakeUp.caller, wakeUp.id))
  let closed = false
  const row = id => db.prepare('SELECT * FROM member_session_watch WHERE id=?').get(id)
  const interestingIn = workspaceID => () => new Set(db.prepare('SELECT id FROM member_session_watch WHERE workspace=?').all(workspaceID).map(item => item.id))
  const callersWithWakeUps = new Set(db.prepare('SELECT DISTINCT caller FROM member_session_wakeups').all().map(item => item.caller))
  const dropWakeUp = id => db.prepare('DELETE FROM member_session_wakeups WHERE id=?').run(id)
  const forgetIn = (workspaceID, id) => sources.get(workspaceID)?.source?.forget?.(id)

  // One source per workspace, shared by watched sessions and waits; it closes
  // a minute after the last one lets go.
  async function hold(workspaceID) {
    let entry = sources.get(workspaceID)
    if (!entry) {
      entry = { holds: 0, linger: null, source: null }
      entry.ready = Promise.resolve().then(() => sourceFor(workspaceID, { interesting: interestingIn(workspaceID) })).then(source => {
        if (!source) throw Object.assign(new Error('This workspace cannot be streamed from here.'), { code: 'no_source' })
        entry.source = source
        entry.off = source.listen((id, info) => changed(workspaceID, id, info))
        return source
      })
      sources.set(workspaceID, entry)
      entry.ready.catch(() => { if (sources.get(workspaceID) === entry) sources.delete(workspaceID) })
    }
    entry.holds++
    clearTimeout(entry.linger); entry.linger = null
    let released = false
    const release = () => {
      if (released) return
      released = true
      if (--entry.holds > 0) return
      entry.linger = setTimeout(() => { if (entry.holds === 0 && sources.get(workspaceID) === entry) { sources.delete(workspaceID); entry.off?.(); entry.source?.close() } }, lingerMilliseconds)
      entry.linger.unref?.()
    }
    try { return { source: await entry.ready, release } } catch (error) { release(); throw error }
  }

  // Keeps a source open for every workspace with a watched session.
  function syncHolds() {
    if (closed) return
    const wanted = new Set(db.prepare('SELECT DISTINCT workspace FROM member_session_watch').all().map(item => item.workspace))
    for (const [workspaceID, value] of held) if (!wanted.has(workspaceID)) { held.delete(workspaceID); value.then(entry => entry?.release()) }
    for (const workspaceID of wanted) {
      if (held.has(workspaceID)) continue
      const holding = hold(workspaceID).then(entry => { failures.delete(workspaceID); entry.source.sync(); return entry }, error => {
        if (held.get(workspaceID) !== holding) return null
        if (error.code === 'no_source') {
          // The workspace is gone from the registry (or cannot stream from
          // here): nothing will ever report these sessions, so stop watching them.
          // Wake-ups already queued for them are still delivered.
          log(`Sessions on workspace ${workspaceID} are no longer watched: ${error.message}`)
          held.delete(workspaceID); failures.delete(workspaceID)
          db.prepare('DELETE FROM member_session_watch WHERE workspace=?').run(workspaceID)
          return null
        }
        // The registry or the destination may not be ready: try again later,
        // less often each time, saying so once.
        const attempt = failures.get(workspaceID) ?? 0
        if (attempt === 0) log(`Sessions on workspace ${workspaceID} cannot be watched yet: ${error.message}`)
        failures.set(workspaceID, attempt + 1)
        const timer = setTimeout(() => { if (held.get(workspaceID) === holding) { held.delete(workspaceID); syncHolds() } }, backoff(attempt))
        timer.unref?.()
        return null
      })
      held.set(workspaceID, holding)
    }
  }

  function addWakeUp(current, kind, key, question = null) {
    db.prepare('INSERT OR REPLACE INTO member_session_wakeups VALUES (?,?,?,?,?,?,?,?,?,0,?)')
      .run(current.id, current.caller, current.workspace, kind, key, current.title, current.workspace_name, current.harness, question, stamp())
    callersWithWakeUps.add(current.caller)
    schedule(current.caller)
  }

  // A watched session changed on its workspace.
  function changed(workspaceID, id, info) {
    if (closed) return
    const current = row(id)
    if (!current || current.workspace !== workspaceID) return
    if (info.state === 'missing') { db.prepare('DELETE FROM member_session_watch WHERE id=?').run(id); dropWakeUp(id); forgetIn(workspaceID, id); syncHolds(); return }
    const title = info.conversation?.title ?? current.title
    if (info.state === 'running') {
      const runID = info.conversation?.activeRunID ?? null
      if (current.state === 'running' && current.run_id === runID) return
      db.prepare('UPDATE member_session_watch SET state=?, run_id=?, questions=NULL, title=?, updated_at=? WHERE id=?').run('running', runID, title, stamp(), id)
      // Running again: whatever it said before no longer holds.
      dropWakeUp(id)
      return
    }
    if (info.state === 'needsInput') {
      const questions = pendingKey(info.pending)
      if (current.state === 'needsInput' && current.questions === questions) return
      const runID = info.conversation?.activeRunID ?? current.run_id
      db.prepare('UPDATE member_session_watch SET state=?, run_id=?, questions=?, title=?, updated_at=? WHERE id=?').run('needsInput', runID, questions, title, stamp(), id)
      const first = info.pending[0]
      addWakeUp({ ...current, title }, 'needsInput', 'needsInput:' + questions, first?.title ?? (first?.kind === 'approval' ? 'an approval' : null))
      return
    }
    // Idle: it finished; nothing more is watched until the caller makes it run again.
    db.prepare('DELETE FROM member_session_watch WHERE id=?').run(id)
    forgetIn(workspaceID, id)
    addWakeUp({ ...current, title }, 'finished', 'finished:' + (current.run_id ?? 'unknown'))
    syncHolds()
  }

  /**
   * What a caller just did to, or read from, a session it created: `state`
   * after a create, send, steer or respond (`running`), a stop (`idle`) or a
   * status read. Any of these replaces a pending wake-up for it, which the
   * caller has now seen or made stale.
   */
  function observe({ callerID, workspace, id, title = null, harness = null, state, runID = null, pending = [], created = false }) {
    if (closed || !id || !workspace?.id) return
    id = String(id).toLowerCase()
    const owner = db.prepare('SELECT caller FROM member_sessions WHERE id=?').get(id)?.caller
    if (owner !== callerID) return
    if (created && isBot(callerID)) db.prepare('DELETE FROM member_session_wakeup_counts WHERE caller=?').run(callerID)
    dropWakeUp(id)
    forgetIn(workspace.id, id)
    const current = row(id)
    if (state === 'idle') db.prepare('DELETE FROM member_session_watch WHERE id=?').run(id)
    else {
      db.prepare(`INSERT INTO member_session_watch VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET workspace_name=excluded.workspace_name,
        title=coalesce(excluded.title,title), harness=coalesce(excluded.harness,harness), state=excluded.state, run_id=coalesce(excluded.run_id,run_id), questions=excluded.questions, updated_at=excluded.updated_at`)
        .run(id, callerID, workspace.id, workspace.name ?? null, title ?? current?.title ?? null, harness ?? current?.harness ?? null, state, runID,
          state === 'needsInput' ? pendingKey(pending) : null, stamp())
    }
    syncHolds()
  }

  function schedule(callerID, delay = 0) {
    if (closed) return
    const run = () => {
      const previous = chains.get(callerID) ?? Promise.resolve()
      const next = previous.then(() => deliver(callerID)).catch(error => log(`A wake-up could not be delivered: ${error.message}`))
      chains.set(callerID, next)
      void next.finally(() => { if (chains.get(callerID) === next) chains.delete(callerID) })
    }
    if (!delay) { setImmediate(run); return }
    if (retries.has(callerID)) return
    const timer = setTimeout(() => { retries.delete(callerID); run() }, delay)
    timer.unref?.(); retries.set(callerID, timer)
  }

  const counted = callerID => db.prepare('SELECT run_id, count FROM member_session_wakeup_counts WHERE caller=?').get(callerID)
  const count = (callerID, runID, value) => db.prepare('INSERT INTO member_session_wakeup_counts VALUES (?,?,?) ON CONFLICT(caller) DO UPDATE SET run_id=excluded.run_id, count=excluded.count').run(callerID, runID, value)
  const textFor = (wakeUp, last) => wakeUpText({ kind: wakeUp.kind, sessionID: wakeUp.id, title: wakeUp.title, workspaceName: wakeUp.workspace_name ?? wakeUp.workspace, question: wakeUp.question, last })
  function forget(callerID) {
    if (!db.prepare('SELECT 1 FROM member_session_wakeups WHERE caller=? LIMIT 1').get(callerID)) callersWithWakeUps.delete(callerID)
  }

  async function deliver(callerID) {
    if (closed) return
    const stored = db.prepare('SELECT * FROM member_session_wakeups WHERE caller=? ORDER BY created_at, rowid').all(callerID)
    if (!stored.length) { forget(callerID); return }
    const waiting = stored.filter(wakeUp => !awaited(wakeUp))
    if (!waiting.length) return
    const target = await caller(callerID)
    if (!target) { db.prepare('DELETE FROM member_session_wakeups WHERE caller=?').run(callerID); forget(callerID); return }
    if (target.kind === 'bot') {
      for (const wakeUp of waiting) {
        const used = counted(callerID)?.count ?? 0
        if (used >= maximumWakeUps) { db.prepare('DELETE FROM member_session_wakeups WHERE id=? AND key=?').run(wakeUp.id, wakeUp.key); continue }
        if (!deliverToBot) { db.prepare('DELETE FROM member_session_wakeups WHERE caller=?').run(callerID); break }
        try {
          await deliverToBot({ botID: target.botID, text: textFor(wakeUp, used + 1 === maximumWakeUps), deliveryID: stableID([callerID, wakeUp.id, wakeUp.key].join(':')) })
        } catch (error) {
          // The bots runtime may be restarting; one that stays away (about ten minutes) drops it.
          if (wakeUp.attempt + 1 >= 20) { dropWakeUp(wakeUp.id); log(`A wake-up for bot ${target.botID} was dropped: ${error.message}`); continue }
          db.prepare('UPDATE member_session_wakeups SET attempt=attempt+1 WHERE id=? AND key=?').run(wakeUp.id, wakeUp.key)
          schedule(callerID, retryMilliseconds); break
        }
        count(callerID, null, used + 1)
        db.prepare('DELETE FROM member_session_wakeups WHERE id=? AND key=?').run(wakeUp.id, wakeUp.key)
      }
      forget(callerID)
      return
    }
    // A running caller is never woken: its next idle moment delivers.
    if (!target.idle) return
    const wakeUp = waiting[0], chain = counted(callerID)
    const used = chain && chain.run_id === target.latestRunID ? chain.count : 0
    if (used >= maximumWakeUps) {
      log(`Session ${callerID} had ${maximumWakeUps} wake-ups in a row; the rest are dropped until it is started another way.`)
      db.prepare('DELETE FROM member_session_wakeups WHERE caller=?').run(callerID); forget(callerID)
      return
    }
    let receipt
    try {
      receipt = await deliverToConversation({ callerID, commandID: stableID([callerID, wakeUp.id, wakeUp.key, wakeUp.attempt].join(':')),
        text: textFor(wakeUp, used + 1 === maximumWakeUps), sessionID: wakeUp.id, title: wakeUp.title, harness: wakeUp.harness })
    } catch (error) {
      // A request the caller's workspace can never accept is not retried.
      if ([400, 403, 404].includes(error.statusCode)) {
        log(`A wake-up for ${callerID} was dropped: ${error.message}`)
        dropWakeUp(wakeUp.id); forget(callerID); schedule(callerID)
        return
      }
      receipt = { status: 'rejected', message: error.message }
    }
    if (['accepted', 'completed'].includes(receipt?.status)) {
      count(callerID, receipt.runID ?? null, used + 1)
      db.prepare('DELETE FROM member_session_wakeups WHERE id=? AND key=?').run(wakeUp.id, wakeUp.key)
      forget(callerID)
      return
    }
    // Refused (it started running meanwhile, or the workspace is at its
    // session limit): a new command when it is next idle, or after a backoff.
    // One refused every time is dropped after `maximumDeliveryAttempts`.
    if (wakeUp.attempt + 1 >= maximumDeliveryAttempts) {
      log(`A wake-up for ${callerID} was dropped after ${maximumDeliveryAttempts} refusals: ${receipt?.message ?? receipt?.status ?? 'no receipt'}`)
      dropWakeUp(wakeUp.id); forget(callerID); schedule(callerID)
      return
    }
    db.prepare('UPDATE member_session_wakeups SET attempt=attempt+1 WHERE id=? AND key=?').run(wakeUp.id, wakeUp.key)
    schedule(callerID, backoff(wakeUp.attempt))
  }

  /**
   * Resolves when session `id` on `workspaceID` reaches `until`, or after
   * `timeoutMilliseconds`. `read()` returns `{body, state}` from the same
   * reads as `woven_sessions_status`: once at the start, once after each
   * change that reaches `until` (to confirm it), and once at the timeout.
   */
  async function wait({ callerID = null, workspaceID, id, until, timeoutMilliseconds, read, signal, now = Date.now }) {
    const deadline = now() + timeoutMilliseconds, key = callerID ? waitKey(callerID, id) : null
    if (key) waits.set(key, (waits.get(key) ?? 0) + 1)
    let hint = false, wake = null, off = () => {}, untrack = () => {}, release = () => {}
    try {
      const entry = await hold(workspaceID)
      release = entry.release
      untrack = entry.source.track(id)
      off = entry.source.listen((changedID, info) => { if (changedID === id && (reaches(info.state, until) || info.state === 'missing')) { hint = true; wake?.() } })
      listening++
      const stop = off
      off = () => { listening--; stop() }
    } catch (error) {
      // No stream to this workspace: the wait still answers, at the timeout.
      if (error.code !== 'no_source') log(`A wait on ${workspaceID} has no live changes: ${error.message}`)
    }
    try {
      for (;;) {
        hint = false
        signal?.throwIfAborted()
        const current = await read()
        if (reaches(current.state, until)) return { ...current.body, state: current.state, timedOut: false }
        const remaining = deadline - now()
        if (remaining <= 0) return { ...current.body, state: current.state, timedOut: true }
        await new Promise(resolve => {
          if (hint) { resolve(); return }
          const timer = setTimeout(done, remaining)
          function done() { clearTimeout(timer); signal?.removeEventListener('abort', done); wake = null; resolve() }
          wake = done
          signal?.addEventListener('abort', done, { once: true })
        })
      }
    } finally {
      off(); untrack(); release()
      if (key) {
        const left = waits.get(key) - 1
        if (left > 0) waits.set(key, left); else waits.delete(key)
        // What the wait did not already show its caller is delivered now.
        if (left <= 0 && callersWithWakeUps.has(callerID)) schedule(callerID)
      }
    }
  }

  return {
    observe, wait,
    /** Starts watching what was stored and delivers what was pending. */
    start() { syncHolds(); for (const callerID of callersWithWakeUps) schedule(callerID) },
    /** A conversation here changed: deliver its pending wake-ups once it is idle. */
    callerChanged(callerID) { if (callersWithWakeUps.has(callerID)) schedule(callerID) },
    /** The member list changed: streams refused with `4401` may try again. */
    retry() { for (const entry of sources.values()) entry.source?.retry() },
    /** A caller's pending wake-ups, or every caller's. */
    pending: callerID => callerID === undefined ? db.prepare('SELECT * FROM member_session_wakeups ORDER BY created_at, rowid').all()
      : db.prepare('SELECT * FROM member_session_wakeups WHERE caller=? ORDER BY created_at, rowid').all(callerID),
    /** How many waits are following live changes now. */
    waiting: () => listening,
    watched: () => db.prepare('SELECT * FROM member_session_watch ORDER BY updated_at').all(),
    close() {
      closed = true
      for (const timer of retries.values()) clearTimeout(timer)
      retries.clear()
      for (const entry of sources.values()) { clearTimeout(entry.linger); entry.off?.(); entry.source?.close() }
      sources.clear(); held.clear()
    },
  }
}
