import { readFileSync, mkdirSync, appendFileSync, openSync, fsyncSync, closeSync } from 'node:fs'
import { resolve } from 'node:path'
import { randomUUID } from 'node:crypto'
import { durableJSON } from './openclaw-results/store.mjs'

const fail = (code, message) => Object.assign(new Error(message), { statusCode: code })
const read = (path, fallback) => { try { return JSON.parse(readFileSync(path, 'utf8')) } catch (e) { if (e.code === 'ENOENT') return fallback; throw e } }
const validID = value => typeof value === 'string' && /^[a-zA-Z0-9_-]{1,128}$/.test(value)
const iso = value => new Date(value).toISOString()
const instant = value => typeof value === 'string' && Number.isFinite(Date.parse(value))
const stamp = (eventID, scheduledAt) => `${eventID}:${iso(scheduledAt)}`
const fields = (date, zone) => Object.fromEntries(new Intl.DateTimeFormat('en-GB', { timeZone: zone, year:'numeric', month:'2-digit', day:'2-digit', hour:'2-digit', minute:'2-digit', second:'2-digit', hourCycle:'h23' }).formatToParts(new Date(date)).filter(x => x.type !== 'literal').map(x => [x.type, Number(x.value)]))
const localMillis = p => Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second)

// Gregorian recurrence is anchored to the original local wall-clock date, not
// the previous run. Thus Jan 31 -> Feb 28 -> Mar 31, with no DST clock drift.
export function occurrenceDate(schedule, index) {
  if (!Number.isSafeInteger(index) || index < 0) return null
  const start = Date.parse(schedule.startsAt)
  if (!schedule.recurrence || index === 0) return index === 0 ? start : null
  const p = fields(start, schedule.timeZoneID)
  const { unit, interval } = schedule.recurrence
  const offset = index * interval
  let target
  if (unit === 'month') {
    const month = new Date(Date.UTC(p.year, p.month - 1 + offset, 1))
    const last = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 0)).getUTCDate()
    target = Date.UTC(month.getUTCFullYear(), month.getUTCMonth(), Math.min(p.day, last), p.hour, p.minute, p.second)
  } else target = localMillis(p) + offset * (unit === 'week' ? 7 : 1) * 86400000
  if (!Number.isFinite(target)) return null
  // Try both offsets around a DST boundary. A missing wall-clock time moves
  // forward by the gap; an ambiguous time uses the earlier occurrence.
  const offsets = [...new Set([-86400000, 0, 86400000].map(d => localMillis(fields(target + d, schedule.timeZoneID)) - (target + d)))]
  const candidates = offsets.map(o => target - o).sort((a,b) => a-b)
  const exact = candidates.filter(c => localMillis(fields(c, schedule.timeZoneID)) === target)
  return (exact[0] ?? candidates.filter(c => localMillis(fields(c, schedule.timeZoneID)) > target)[0] ?? candidates[0]) + (start % 1000)
}
export function latestOccurrence(schedule, now) {
  if (now < Date.parse(schedule.startsAt)) return null
  if (!schedule.recurrence) return 0
  let lo = 0, hi = 1
  while (occurrenceDate(schedule, hi) <= now && hi < 1048576) { lo = hi; hi *= 2 }
  while (hi - lo > 1) { const mid = Math.floor((lo+hi)/2); if (occurrenceDate(schedule, mid) <= now) lo = mid; else hi = mid }
  return lo
}
function nextAfter(schedule, now) {
  let index = (latestOccurrence(schedule, now) ?? -1) + 1
  while (schedule.excludedOccurrences.includes(index)) index++
  const next = occurrenceDate(schedule, index)
  return next == null ? null : iso(next)
}
function validateSchedule(value) {
  if (!value || !validID(value.id) || typeof value.title !== 'string' || value.title.length > 4096
    || typeof value.timeZoneID !== 'string' || !value.timeZoneID
    || !instant(value.startsAt) || (value.nextFireAt != null && !instant(value.nextFireAt))
    || !Number.isSafeInteger(value.revision) || value.revision < 0
    || !Array.isArray(value.excludedOccurrences) || value.excludedOccurrences.length > 100000
    || value.excludedOccurrences.some(x => !Number.isSafeInteger(x) || x < 0)
    || !value.task || typeof value.task.prompt !== 'string' || !value.task.prompt.trim() || value.task.prompt.length > 65536
    || !['same','new'].includes(value.task.sessionMode) || !validID(value.task.configuration?.runtimeKind)
    || (value.taskSessionID != null && !validID(value.taskSessionID))) throw fail(400,'Invalid scheduled task.')
  try { fields(Date.now(), value.timeZoneID) } catch { throw fail(400, 'Invalid task time zone.') }
  if (value.recurrence && (!['day','week','month'].includes(value.recurrence.unit) || !Number.isSafeInteger(value.recurrence.interval) || value.recurrence.interval < 1 || value.recurrence.interval > 365)) throw fail(400,'Invalid task recurrence.')
  return structuredClone(value)
}

export function createTaskGateway({ directory, execute, now = Date.now, onDisable = async () => {}, maximumConcurrent = 4, maximumOutputBytes = 64 * 1024 * 1024, syncJournal = fsyncSync }) {
  mkdirSync(directory, { recursive:true, mode:0o700 })
  const path = resolve(directory, 'state.json')
  let state = read(path, { enabled:true, schedules:[], knownRuns:[], results:[], claims:{}, publicationIDs:[] })
  const epoch = randomUUID()
  const active = new Map()
  let timer, closed = false, disabling = false
  const save = () => durableJSON(path, state)
  // Acceptance is durable before a prompt is sent. A process restart makes
  // unfinished work uncertain, never eligible for automatic replay.
  for (const claim of Object.values(state.claims)) if (!claim.completedAt) {
    const completed = read(resolve(directory, `result-${claim.id}.json`), null)
    if (completed) {
      Object.assign(claim, completed); delete claim.updates
    } else {
      claim.completedAt = iso(now()); claim.error = 'The workspace restarted during this task. Check its session before retrying.'
      claim.run.status = 'uncertain'; claim.run.error = claim.error
      durableJSON(resolve(directory, `result-${claim.id}.json`), {...claim,updates:readJournal(claim.id)})
    }
    if (!state.results.includes(claim.id)) state.results.push(claim.id)
  }
  save()
  function readJournal(id) {
    try {
      const lines = readFileSync(resolve(directory, `run-${id}.jsonl`), 'utf8').split('\n')
      // A crash can tear the final append. Keep complete records while the
      // durable claim marks the run uncertain; never resubmit its prompt.
      lines.pop()
      return lines.filter(Boolean).map(JSON.parse)
    }
    catch (e) { if (e.code === 'ENOENT') return []; throw e }
  }
  function status() { return { enabled:state.enabled, epoch, activeRuns:active.size, scheduleCount:state.schedules.length, waitingTasks:state.schedules.filter(s=>s.waitingReason).map(s=>({eventID:s.id,reason:s.waitingReason,retryAfter:s.retryAfter})) } }
  async function configure(body) {
    if (typeof body.enabled !== 'boolean') throw fail(400,'Choose whether background execution is enabled.')
    if (body.enabled) {
      if (disabling) throw fail(409,'Background execution is still stopping.')
      state.enabled = true; save(); return status()
    }
    disabling = true
    try {
      state.enabled = false; state.requiresPublication = true; save()
      for (const job of active.values()) job.controller.abort()
      await Promise.allSettled([...active.values()].map(x => x.completion))
      await onDisable()
      if (active.size) throw fail(503,'Background work could not be durably stopped. Do not reclaim its schedules yet.')
      return status()
    } finally { disabling = false }
  }
  function publish(body) {
    if (!validID(body.publicationID) || !Array.isArray(body.schedules) || body.schedules.length > 10000 || !Array.isArray(body.knownRuns) || body.knownRuns.length > 100000) throw fail(400,'Invalid schedule publication.')
    if (state.publicationIDs.includes(body.publicationID)) return { ...status(), publicationID:body.publicationID }
    const schedules = body.schedules.map(validateSchedule)
    if (new Set(schedules.map(x=>x.id)).size !== schedules.length) throw fail(400,'Duplicate schedule.')
    for (const schedule of schedules) {
      const previous = state.schedules.find(x => x.id === schedule.id)
      if (previous && previous.revision > schedule.revision) throw fail(409,'A newer schedule is already published.')
      if (previous && previous.revision === schedule.revision) {
        // Reconnecting with a stale snapshot must not rewind a remote series.
        schedule.nextFireAt = previous.nextFireAt
        schedule.taskSessionID = previous.taskSessionID
        schedule.nativeSessionID = previous.nativeSessionID
        schedule.retryAfter = previous.retryAfter; schedule.waitingReason = previous.waitingReason
      } else if (previous && schedule.taskSessionID === previous.taskSessionID) schedule.nativeSessionID = previous.nativeSessionID
    }
    const known = body.knownRuns.map(r => { if (!validID(r.eventID) || !instant(r.scheduledAt)) throw fail(400,'Invalid previous run.'); return stamp(r.eventID,r.scheduledAt) })
    for (const job of active.values()) {
      if (!schedules.some(s => s.id === job.eventID && s.revision === job.eventRevision)) job.controller.abort()
    }
    state.schedules = schedules
    state.requiresPublication = false
    state.knownRuns = [...new Set([...state.knownRuns,...known])]
    state.publicationIDs = [...state.publicationIDs.slice(-999), body.publicationID]
    save()
    return { ...status(), publicationID:body.publicationID }
  }
  async function run(schedule, index, at) {
    const previousNextFireAt = schedule.nextFireAt
    delete schedule.retryAfter; delete schedule.waitingReason
    let deferred = false
    const scheduledAt = iso(at)
    const key = stamp(schedule.id, scheduledAt)
    const id = randomUUID()
    const reuseSession = schedule.task.sessionMode === 'same' && schedule.recurrence != null
    const sessionID = reuseSession ? schedule.taskSessionID ?? randomUUID() : randomUUID()
    const claim = { id, eventRevision:schedule.revision, run:{ id,eventID:schedule.id,occurrenceIndex:index,scheduledAt,sessionID,task:structuredClone(schedule.task),status:'sending',title:schedule.title }, nativeSessionID:reuseSession ? schedule.nativeSessionID ?? null : null }
    state.claims[key] = claim
    state.knownRuns.push(key)
    if (schedule.task.sessionMode === 'same' && schedule.recurrence) schedule.taskSessionID = sessionID
    schedule.nextFireAt = nextAfter(schedule, now())
    save()
    const controller = new AbortController()
    const updates = []
    let journalLines = [], journalBytes = 0, outputBytes = 0, journalTimer
    const flushJournal = () => {
      clearTimeout(journalTimer); journalTimer = null
      if (!journalLines.length) return
      const fd = openSync(resolve(directory, `run-${id}.jsonl`), 'a', 0o600)
      try { appendFileSync(fd, journalLines.join('')); syncJournal(fd) } finally { closeSync(fd) }
      journalLines = []; journalBytes = 0
    }
    const publishUpdate = update => {
      const line = JSON.stringify(update)+'\n'
      const bytes = Buffer.byteLength(line)
      if (outputBytes + bytes > maximumOutputBytes) throw new Error('The task exceeded its response limit.')
      outputBytes += bytes
      journalLines.push(line); journalBytes += bytes
      updates.push(update)
      if (journalBytes >= 65536) flushJournal()
      else if (!journalTimer) {
        journalTimer = setTimeout(() => {
          try { flushJournal() } catch { controller.abort() }
        }, 75)
        journalTimer.unref()
      }
    }
    const bindSession = nativeID => {
      claim.nativeSessionID = nativeID
      if (schedule.task.sessionMode === 'same' && schedule.recurrence) {
        schedule.nativeSessionID = nativeID
        const current = state.schedules.find(s => s.id === schedule.id && s.taskSessionID === sessionID)
        if (current) current.nativeSessionID = nativeID
      }
      save()
    }
    const job = { controller, completion:null, eventID:schedule.id, eventRevision:schedule.revision, runtimeKind:schedule.task.configuration.runtimeKind }
    active.set(id,job)
    job.completion = (async () => {
      try {
        const result = await execute({ run:claim.run,nativeSessionID:claim.nativeSessionID,signal:controller.signal,publish:publishUpdate,bindSession })
        claim.result = result ?? null; claim.run.status = 'accepted'
      } catch (error) {
        if (error?.beforePrompt === true && error?.deferred === true) {
          deferred = true
          const current = state.schedules.find(s=>s.id===schedule.id && s.revision===schedule.revision)
          if (current) { current.nextFireAt=previousNextFireAt;current.retryAfter=iso(now()+60000);current.waitingReason=error.message }
          state.knownRuns=state.knownRuns.filter(value=>value!==key);delete state.claims[key]
        }
        claim.error = error?.message ?? 'The task could not finish.'
        claim.run.error = claim.error
        claim.run.status = error?.beforePrompt === true || error?.needsApproval === true ? 'failed' : 'uncertain'
      } finally {
        flushJournal()
        if (!deferred) {
          claim.completedAt = iso(now())
          durableJSON(resolve(directory, `result-${id}.json`), {...claim,updates})
          state.results.push(id)
        }
        save(); active.delete(id)
      }
    })()
    await job.completion
  }
  function tick() {
    if (closed || !state.enabled || disabling || state.requiresPublication) return
    for (const schedule of state.schedules) {
      if (active.size >= maximumConcurrent) break
      if (schedule.retryAfter && Date.parse(schedule.retryAfter)>now()) continue
      if (schedule.nextFireAt == null || Date.parse(schedule.nextFireAt) > now()) continue
      if ([...active.values()].some(job => job.eventID === schedule.id)) continue
      let index = latestOccurrence(schedule, now())
      while (index != null && index >= 0 && schedule.excludedOccurrences.includes(index)) index--
      const at = index == null ? null : occurrenceDate(schedule,index)
      if (at == null || at < Date.parse(schedule.nextFireAt) || state.knownRuns.includes(stamp(schedule.id,at))) { schedule.nextFireAt = nextAfter(schedule,now()); save(); continue }
      void run(schedule,index,at).catch(() => { /* fail closed: durable claim prevents replay */ })
    }
  }
  function results(after = '0') {
    const cursor = Number(after)
    if (!Number.isSafeInteger(cursor) || cursor < 0 || cursor > state.results.length) throw fail(400,'Invalid result cursor.')
    const entries = state.results.slice(cursor,cursor+20).map(id => read(resolve(directory, `result-${id}.json`), null))
    if (entries.some(x => !x)) throw fail(503,'A task result could not be read; its cursor was not advanced.')
    return { entries:structuredClone(entries),cursor:String(cursor+entries.length) }
  }
  return { status,configure,publish,tick,results,schedules:() => ({ schedules:structuredClone(state.schedules), ...status() }),
    enabled:() => state.enabled && !disabling,
    hasActiveRuntime:id => [...active.values()].some(x=>x.runtimeKind === id),
    start() { timer ??= setInterval(tick,1000); timer.unref(); tick() },
    async close() { closed=true; clearInterval(timer); for (const job of active.values()) job.controller.abort(); await Promise.allSettled([...active.values()].map(x=>x.completion)) },
  }
}
