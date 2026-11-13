import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { randomUUID } from 'node:crypto'

const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })
const actions = new Set(['status', 'catalog', 'login', 'logout', 'reset', 'refresh', 'sign-in-status', 'claude-status', 'probe-server'])
const maximumOutputBytes = 4 * 1024 * 1024

// Pi Durable's settings actions, on this host, for a Mac that used to run
// `wm-exec default-agent --control` over SSH. The same one-line request (the
// Mac's `DefaultAgentPayload` plus `action`, `provider`, `profile`, `force`)
// goes to the same control helper, started here. Its payload stays in that
// helper's memory, as it did over SSH; this server keeps none of it.
//
// A control session is one helper run: it reports sign-in `notifications`
// (a link and code), a `prompt` the caller answers, then its `result` or
// `error`. Finished sessions are kept for five minutes.
export function createDefaultAgentControl({ command, environment = () => process.env, cwd, spawnProcess = spawn,
  timeoutMilliseconds = 10 * 60_000, retentionMilliseconds = 5 * 60_000, maximumSessions = 8 }) {
  const sessions = new Map()
  function view(session) {
    return { id: session.id, action: session.action, state: session.state, notifications: session.notifications,
      ...(session.prompt ? { prompt: session.prompt } : {}), ...(session.state === 'succeeded' ? { result: session.result } : {}),
      ...(session.state === 'failed' ? { error: session.error } : {}) }
  }
  function prune() {
    for (const [id, session] of sessions) if (session.state !== 'running' && Date.now() - session.finishedAt > retentionMilliseconds) sessions.delete(id)
  }
  function start(request) {
    if (!request || typeof request !== 'object' || Array.isArray(request) || !actions.has(request.action ?? 'status')) throw fail(400, 'Choose a Pi Durable control action.')
    prune()
    if ([...sessions.values()].filter(session => session.state === 'running').length >= maximumSessions) throw fail(429, 'Pi Durable is already running several settings actions. Retry after they finish.')
    const launch = command()
    const child = spawnProcess(launch.command, launch.arguments, { cwd: cwd(), env: environment(), stdio: ['pipe', 'pipe', 'pipe'] })
    const session = { id: randomUUID(), action: request.action ?? 'status', state: 'running', notifications: [], prompt: null, child, bytes: 0 }
    const done = Promise.withResolvers()
    session.done = done.promise
    const finish = (state, value) => {
      if (session.state !== 'running') return
      session.state = state; session.prompt = null; session.finishedAt = Date.now()
      if (state === 'succeeded') session.result = value; else session.error = value
      clearTimeout(timer); done.resolve(view(session))
      if (child.exitCode === null && !child.killed) child.kill('SIGTERM')
    }
    const timer = setTimeout(() => finish('failed', 'The Pi Durable settings action timed out.'), timeoutMilliseconds)
    timer.unref?.()
    child.stderr?.on('data', () => {})
    child.stdin.on('error', () => {})
    child.once('error', () => finish('failed', 'Pi Durable settings could not start on this workspace.'))
    // Its last line is read before the exit settles the session.
    child.once('close', code => setImmediate(() => finish('failed', code === 0 ? 'Pi Durable settings ended without a result.' : 'Pi Durable settings did not complete on this workspace.')))
    createInterface({ input: child.stdout }).on('line', line => {
      session.bytes += Buffer.byteLength(line)
      if (session.bytes > maximumOutputBytes) { finish('failed', 'Pi Durable settings returned too much output.'); return }
      let message
      try { message = JSON.parse(line) } catch { return }
      if (message.notification) session.notifications.push(message.notification)
      else if (message.prompt && message.id != null) session.prompt = { id: String(message.id), ...message.prompt }
      else if (Object.hasOwn(message, 'result')) finish('succeeded', message.result)
      // Only app-authored helper errors reach the caller (`operationErrorMessage`).
      else if (typeof message.error === 'string') finish('failed', message.error.slice(0, 1024))
    })
    sessions.set(session.id, session)
    child.stdin.write(JSON.stringify({ ...request, action: session.action }) + '\n')
    return session
  }
  function get(id) {
    prune()
    const session = sessions.get(id)
    if (!session) throw fail(404, 'This Pi Durable settings action is not running.')
    return session
  }
  return {
    // One action to its end: its result, or its error as a 409.
    async run(request) {
      const session = start(request)
      const finished = await session.done
      if (finished.state === 'failed') throw fail(409, finished.error)
      return finished.result
    },
    start: request => view(start(request)),
    status: id => view(get(id)),
    answer(id, { answerTo, answer } = {}) {
      const session = get(id)
      if (session.state !== 'running' || !session.prompt || String(answerTo) !== session.prompt.id) throw fail(409, 'This question is no longer waiting.')
      if (typeof answer !== 'string' || Buffer.byteLength(answer) > 4096) throw fail(400, 'Choose an answer.')
      session.prompt = null
      session.child.stdin.write(JSON.stringify({ answerTo, answer }) + '\n')
      return view(session)
    },
    cancel(id) {
      const session = get(id)
      if (session.state === 'running') { session.child.stdin.end(); session.child.kill('SIGTERM') }
      return view(session)
    },
    close() { for (const session of sessions.values()) if (session.state === 'running') session.child.kill('SIGTERM') },
  }
}
