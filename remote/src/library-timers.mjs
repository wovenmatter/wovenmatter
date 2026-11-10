// Timers on this machine (docs/architecture/WOVEN_EVERYWHERE.md, "Timers on a
// library host"). Woven timers live in this machine's library copy, which is
// not shared with other devices, so they fire here with every Mac offline: the
// library host returns each due occurrence (`POST /v1/timers/due`), this server
// delivers it to its own session or to one of its bots, then settles it
// (`POST /v1/timers/settle`). The occurrence's delivery ID is the idempotency
// key on both sides, so a retry after a crash never delivers twice.
//
// There is no constant polling: the dispatcher sleeps until the next timer
// fires (at most `maximumSleep`), and `kick()` wakes it after any timer tool
// call and whenever the library host becomes ready.

const fail = (statusCode, message, code) => Object.assign(new Error(message), { statusCode, ...(code ? { code } : {}) })

/**
 * `deliverSession(sessionID, text, deliveryID)` sends to one of this server's
 * sessions; it throws with `code: 'not_here'` for a session it does not run.
 * `deliverBot({botID, text, deliveryID})` reaches this machine's bots runtime.
 */
export function createLibraryTimers({ library, deliverSession, deliverBot = null, log = () => {}, maximumSleep = 60_000, retrySleep = 30_000, now = Date.now }) {
  let timer = null, running = null, again = false, closed = false

  async function settle(occurrence, outcome, reason) {
    await library.client.settleTimer({ timerID: occurrence.timerID, deliveryID: occurrence.deliveryID, outcome, ...(reason ? { reason: String(reason).slice(0, 1024) } : {}) })
  }

  async function deliver(occurrence) {
    try {
      if (occurrence.kind === 'bot') {
        if (!deliverBot) throw fail(503, 'Bots are not running on this machine.')
        await deliverBot({ botID: occurrence.botID, text: occurrence.text, deliveryID: occurrence.deliveryID })
      } else await deliverSession(occurrence.target, occurrence.text, occurrence.deliveryID)
      await settle(occurrence, 'accepted')
      return true
    } catch (error) {
      // A session another device runs never fires here; any other failure is retried.
      const cancelled = error?.code === 'not_here'
      await settle(occurrence, cancelled ? 'cancelled' : 'retry', error?.message).catch(() => {})
      if (!cancelled) log(`Timer ${occurrence.timerID} could not be delivered yet: ${error?.message ?? error}`)
      return false
    }
  }

  async function tick() {
    if (!library.available()) return null
    const due = await library.client.timersDue()
    let failed = false
    for (const occurrence of due.occurrences ?? []) { if (closed) return null; if (!await deliver(occurrence)) failed = true }
    const next = due.nextFireAt ? Date.parse(due.nextFireAt) : NaN
    let wait = Number.isFinite(next) ? Math.max(0, next - now()) : maximumSleep
    if (failed || (due.occurrences ?? []).length) wait = Math.min(wait, failed ? retrySleep : 1000)
    return Math.min(Math.max(wait, 250), maximumSleep)
  }

  function schedule(delay) {
    clearTimeout(timer)
    if (closed) return
    timer = setTimeout(run, delay); timer.unref?.()
  }

  function run() {
    if (closed) return Promise.resolve()
    if (running) { again = true; return running }
    running = (async () => {
      let delay = maximumSleep
      try { delay = (await tick()) ?? maximumSleep } catch (error) { delay = retrySleep; log('Timers could not be checked: ' + error.message) }
      return delay
    })().then(delay => {
      running = null
      if (again) { again = false; schedule(0) } else schedule(delay)
    })
    return running
  }

  return {
    start() { closed = false; schedule(0) },
    /** Check again now: a timer was created or changed, or the library came back. */
    kick() { if (!closed) schedule(0) },
    /** One check, for tests. */
    runOnce: () => run(),
    close() { closed = true; clearTimeout(timer) },
  }
}
