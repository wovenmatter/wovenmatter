import { spawn } from 'node:child_process'
import { mkdir, open, readFile, realpath } from 'node:fs/promises'
import { resolve, sep } from 'node:path'
import { createInterface } from 'node:readline'
import { randomUUID } from 'node:crypto'

const identifier = value => {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(value)) throw new Error('Invalid channel identifier')
  return value
}

function newSnapshot(history) {
  const state = { initialized: null, session: null, recoveredRuns: [], busy: false, pendingRequests: [] }
  Object.defineProperties(state, {
    requests: { value: new Map() }, runs: { value: new Map() }, callbacks: { value: new Map() },
    steers: { value: new Map() }, codexStatuses: { value: new Map() }, inputSequences: { value: new Map() },
  })
  for (const item of history) updateSnapshot(state, item)
  return state
}
function finishPiRuns(state) {
  for (const run of new Set(state.runs.values())) if (run.runID) state.recoveredRuns.push({
    runID: run.runID, content: run.content, ...(run.error ? { error: run.error } : {}),
  })
  state.runs.clear()
}
function resumeRun(state, runID, sessionID) {
  const index = runID ? state.recoveredRuns.findIndex(run => run.runID === runID) : -1
  const previous = index < 0 ? undefined : state.recoveredRuns.splice(index, 1)[0]
  // A promptRequired continuation can arrive after the original reply. Keep
  // one cumulative recovery record for the logical run across that gap.
  return { runID, sessionID, content: previous?.content ?? '', completed: previous?.content ?? '', error: previous?.error,
    nextInputSequence: 0, completedInputSequence: -1 }
}
function updatePiSnapshot(state, item) {
  const message = item.message
  if (item.type === 'accepted') {
    if (message.type === 'extension_ui_response') state.callbacks.delete(message.id)
    else if (message.id !== undefined) {
      state.requests.set(message.id, message)
      if (message.type === 'prompt') {
        const runID = message._meta?.wovenRunID
        const existing = runID && [...state.runs.values()].find(run => run.runID === runID)
        state.runs.set(message.id, existing ?? resumeRun(state, runID))
      }
    }
  } else if (item.type === 'output') {
    if (message.type === 'extension_ui_request') state.callbacks.set(message.id, message)
    if (message.type === 'response') {
      const request = state.requests.get(message.id)
      if (request?.type === 'get_state' && message.success) {
        state.piState = message.data
        if (message.data?.isStreaming === false && message.data?.isCompacting === false && message.data?.pendingMessageCount === 0
          && ![...state.requests.values()].some(request => request.type === 'prompt')) finishPiRuns(state)
      }
      if (request?.type === 'prompt' && message.success === false) {
        const run = state.runs.get(message.id)
        state.runs.delete(message.id)
        if (run?.runID && ![...state.runs.values()].includes(run)) state.recoveredRuns.push({ runID: run.runID, content: run.content, error: message.error ?? 'Pi rejected the task' })
      }
      state.requests.delete(message.id)
    }
    for (const run of new Set(state.runs.values())) {
      if (message.type === 'message_update' && message.assistantMessageEvent?.type === 'text_delta') {
        run.content += message.assistantMessageEvent.delta ?? ''
      }
      if (message.type === 'message_end' && message.message?.role === 'assistant') {
        const content = message.message.content ?? []
        const text = Array.isArray(content) ? content.filter(block => block.type === 'text').map(block => block.text ?? '').join('') : ''
        run.completed += text
        run.content = run.completed
        run.error = message.message.stopReason === 'error' ? message.message.errorMessage ?? 'Pi task failed' : null
      }
    }
    if (message.type === 'agent_settled' && ![...state.requests.values()].some(request => request.type === 'prompt' && request.streamingBehavior === 'steer')) finishPiRuns(state)
  }
  state.busy = state.runs.size > 0
  state.pendingRequests = [...state.callbacks.values()]
}
function finishACPInput(state, id, error, ownsCompletion = true) {
  const run = state.runs.get(id)
  const sequence = state.inputSequences.get(id)
  if (run && ownsCompletion && sequence > run.completedInputSequence) {
    run.completedInputSequence = sequence
    run.error = error
  }
  state.inputSequences.delete(id)
  state.runs.delete(id)
  state.steers.delete(id)
  if (run?.runID && ![...state.runs.values()].includes(run)) state.recoveredRuns.push({
    runID: run.runID, content: run.content, ...(run.error ? { error: run.error } : {}),
  })
}
function updateSnapshot(state, item) {
  if (item.type === 'stopped') {
    for (const run of new Set(state.runs.values())) if (run.runID) state.recoveredRuns.push({ runID: run.runID, content: run.content, error: 'Remote execution stopped before completion' })
    state.runs.clear(); state.callbacks.clear(); state.requests.clear(); state.steers.clear(); state.inputSequences.clear()
    state.pendingRequests = []; state.busy = false
    return
  }
  if (item.type === 'recovered') {
    state.initialized = null; state.session = null; state.piState = null
    return
  }
  const message = item.message
  if (!message) return
  if (message.type) { updatePiSnapshot(state, item); return }
  if (item.type === 'accepted') {
    if (message.method && message.id !== undefined) {
      const status = state.codexStatuses.get(message.params?.sessionId)
      state.requests.set(message.id, message.method === 'session/prompt'
        ? { ...message, codexExpectedGeneration: (status?.generation ?? 0) + (status?.active ? 0 : 1) } : message)
      if (message.method === 'session/prompt') {
        const runID = message.params?._meta?.wovenRunID
        // Concurrent ACP prompts steer one logical run. Share its accumulator
        // and wait for every prompt response before exposing terminal recovery.
        const existing = runID && [...state.runs.values()].find(run => run.runID === runID && run.sessionID === message.params?.sessionId)
        state.runs.set(message.id, existing ?? resumeRun(state, runID, message.params?.sessionId))
        state.inputSequences.set(message.id, state.runs.get(message.id).nextInputSequence++)
      }
      if (message.method === '_session/steering') {
        const runID = message.params?._meta?.wovenRunID
        const run = [...state.runs.values()].find(run => run.sessionID === message.params?.sessionId)
          ?? (typeof runID === 'string' ? resumeRun(state, runID, message.params?.sessionId) : undefined)
        if (run) {
          state.runs.set(message.id, run)
          state.inputSequences.set(message.id, run.nextInputSequence++)
          const status = state.codexStatuses.get(run.sessionID)
          const previousGeneration = Math.max(status?.generation ?? 0, ...[...state.requests.values()]
            .filter(request => request.method === 'session/prompt' && request.params?.sessionId === run.sessionID)
            .map(request => request.codexExpectedGeneration ?? 0))
          state.steers.set(message.id, { previousGeneration, started: false, settled: false, detached: false })
        }
      }
    } else if (message.id !== undefined) state.callbacks.delete(message.id)
  }
  if (item.type === 'output') {
    if (message.method && message.id !== undefined) state.callbacks.set(message.id, message)
    if (message.method === 'session/update' && message.params?.update?.sessionUpdate === 'agent_message_chunk') {
      for (const run of new Set(state.runs.values())) if (run.sessionID === message.params.sessionId) run.content += message.params.update.content?.text ?? ''
    }
    const status = message.params?.update?._meta?.codex?.threadStatus?.type
    if (message.method === 'session/update' && status) {
      const sessionID = message.params.sessionId
      const previous = state.codexStatuses.get(sessionID)
      const active = status === 'active'
      const generation = (previous?.generation ?? 0) + (active && !previous?.active ? 1 : 0)
      state.codexStatuses.set(sessionID, { active, generation })
      for (const [id, steer] of state.steers) {
        if (state.runs.get(id)?.sessionID !== sessionID) continue
        if (status === 'active' && generation > steer.previousGeneration) { steer.started = true; steer.settled = false; steer.error = undefined }
        if (status === 'idle' && steer.started) steer.settled = true
        if (steer.started && (status === 'systemError' || status === 'notLoaded')) {
          steer.settled = true; steer.error = 'Codex stopped before completing the steering message'
        }
        if (steer.detached && steer.settled) finishACPInput(state, id, steer.error)
      }
    }
    if (message.id !== undefined && !message.method) {
      const request = state.requests.get(message.id)
      if (request?.method === 'initialize' && message.result) state.initialized = message.result
      if (['session/new', 'session/load'].includes(request?.method) && message.result) state.session = {
        ...message.result, sessionId: message.result.sessionId ?? request.params.sessionId,
      }
      if (state.runs.has(message.id)) {
        const steer = state.steers.get(message.id)
        if (steer && message.result?.outcome === 'startedNewTurn') {
          steer.detached = true
          // Woven's Codex client marks adapter commands that complete without
          // starting native work; their receipt is also their completion.
          if (steer.settled || request.params?._meta?.wovenCommandOnly === true) finishACPInput(state, message.id, steer.error)
        } else {
          // Rejected/injected steering receipts do not settle the underlying
          // prompt or overwrite its error. Concurrent prompt outcomes follow
          // submission order, even when their responses arrive out of order.
          finishACPInput(state, message.id, message.error?.message, !steer)
        }
      }
      state.requests.delete(message.id)
    }
  }
  state.busy = state.runs.size > 0
  state.pendingRequests = [...state.callbacks.values()]
}

// ACP processes belong to the service, never to the transient SSH attachment.
// Journaling acceptance before writing prevents a retry from submitting a prompt twice.
export function createDurableACP({ catalog, workspaceRoot, environment, isEnabled = async () => true, isHarnessEnabled = async () => true,
  directory = resolve(workspaceRoot, '.wovenmatter/durable-acp'), spawnProcess = spawn, openJournal = open, journalFlushInterval = 75 }) {
  const channels = new Map()
  let queue = Promise.resolve()
  const serialize = action => {
    const result = queue.then(action)
    queue = result.catch(() => {})
    return result
  }
  async function flushJournal(channel) {
    clearTimeout(channel.flushTimer); channel.flushTimer = null
    if (!channel.pendingJournal?.length) return
    const data = channel.pendingJournal.join('')
    const file = await openJournal(channel.path, 'a', 0o600)
    try { await file.writeFile(data); await file.sync() } finally { await file.close() }
    channel.pendingJournal = []; channel.pendingBytes = 0
  }
  async function record(channel, entry) {
    const line = JSON.stringify(entry) + '\n'
    const bytes = Buffer.byteLength(line)
    if ((channel.journalBytes ?? 0) + bytes > 64 * 1024 * 1024) throw new Error('Remote session journal is full; start a new session')
    channel.pendingJournal ??= []
    channel.pendingJournal.push(line)
    channel.pendingBytes = (channel.pendingBytes ?? 0) + bytes
    channel.journalBytes = (channel.journalBytes ?? 0) + bytes
    // Streaming output is visible immediately, with bounded durability batches.
    // Input acceptance and terminal records always flush before acknowledgement.
    const message = entry.message
    const terminal = entry.type === 'output' && (
      message.type === 'agent_settled' ||
      (message.id !== undefined && !message.method &&
        (message.type === 'response' || !message.type)))
    if (entry.type !== 'output' || terminal || channel.pendingBytes >= 65536) {
      await flushJournal(channel)
    } else if (!channel.flushTimer) {
      channel.flushTimer = setTimeout(() => {
        channel.flushTimer = null
        serialize(() => flushJournal(channel)).catch(() => {
          channel.failure = 'Unable to retain ACP output'; channel.process?.kill('SIGTERM')
        })
      }, journalFlushInterval)
      channel.flushTimer.unref()
    }
    if (entry.type === 'created') {
      const folder = await open(directory, 'r')
      try { await folder.sync() } finally { await folder.close() }
    }
  }
  async function channelFor(id, harnessID, cwd, permission, nativeSessionID, recovering = false) {
    identifier(id)
    if (channels.has(id)) {
      const existing = channels.get(id)
      if (harnessID && existing.harnessID !== harnessID) throw new Error('Channel belongs to another harness')
      if (permission && existing.permission !== permission) throw new Error('Permission changed; start a new remote session')
      if (!recovering) return existing
      if (existing.state !== 'stopped') throw new Error('Unknown execution state; explicit recovery is required')
    }
    const path = resolve(directory, id + '.jsonl')
    await mkdir(directory, { recursive: true, mode: 0o700 })
    let history = []
    try { history = (await readFile(path, 'utf8')).split('\n').filter(Boolean).map(JSON.parse) }
    catch (error) { if (error.code !== 'ENOENT') throw new Error('Channel journal is unreadable; refusing to replay work') }
    const metadata = history.find(item => item.type === 'created')
    if (metadata && harnessID && metadata.harnessID !== harnessID) throw new Error('Channel belongs to another harness')
    const selected = metadata?.harnessID ?? harnessID
    const harness = catalog.get(selected)
    if (!harness || !(['acp', 'agent-stdio', 'acp-and-gateway'].includes(harness.transport) || (selected === 'pi' && harness.transport === 'rpc'))) throw new Error('Unknown ACP harness')
    if (permission && metadata && metadata.permission !== permission) throw new Error('Permission changed; start a new remote session')
    const channel = { id, harnessID: selected, permission: metadata?.permission ?? permission, path, events: history.filter(item => item.type === 'output'),
      journalBytes: Buffer.byteLength(history.map(JSON.stringify).join('\n')), snapshot: newSnapshot(history), accepted: new Set(history.filter(item => item.type === 'accepted').map(item => item.deliveryID)),
      process: null, state: metadata ? (history.filter(item => ['stopped', 'recovered'].includes(item.type)).at(-1)?.type === 'stopped' ? 'stopped' : 'interrupted') : 'starting', failure: null }
    // An existing journal means the former service owner stopped. Do not replay
    // accepted inputs or quietly start a fresh session under the same identity.
    if (metadata && !recovering) { channels.set(id, channel); return channel }
    if (recovering && channel.state !== 'stopped') throw new Error('Unknown execution state; explicit recovery is required')
    const base = await realpath(workspaceRoot)
    const workingDirectory = await realpath(cwd ?? metadata?.cwd ?? workspaceRoot)
    if (workingDirectory !== base && !workingDirectory.startsWith(base + sep)) throw new Error('Working directory is outside this workspace')
    let args = [...(harness.arguments ?? [])]
    if (selected === 'pi' && nativeSessionID) { identifier(nativeSessionID); args.push('--session', nativeSessionID) }
    if (selected === 'grok_build' && permission) {
      if (!['default', 'acceptEdits', 'auto', 'bypassPermissions', 'dontAsk'].includes(permission)) throw new Error('Invalid Grok permission')
      const index = args.indexOf('--permission-mode')
      if (index >= 0) args.splice(index, 2)
      args = ['--permission-mode', permission, ...args]
      const agent = args.indexOf('agent')
      if (agent >= 0) args.splice(agent + 1, 0, '--no-leader')
    }
    if (!await isEnabled()) throw new Error('Background execution is disabled')
    if (!await isHarnessEnabled(selected)) throw new Error('This harness is disabled')
    const creation = metadata ? { type: 'recovered' } : { type: 'created', harnessID: selected, permission, cwd: workingDirectory }
    await record(channel, creation)
    updateSnapshot(channel.snapshot, creation)
    channels.set(id, channel)
    if (!await isEnabled() || !await isHarnessEnabled(selected)) {
      channel.state = 'stopped'
      throw new Error('Background execution or harness is disabled')
    }
    const wrapped = ['codex', 'claude_code', 'cursor', 'grok_build', 'pi'].includes(selected);
    const child = spawnProcess(wrapped ? process.execPath : harness.command, wrapped
      ? [new URL('../../harnesses/cli/adapter.mjs', import.meta.url).pathname, selected, harness.command, ...args] : args, {
      cwd: workingDirectory, env: { ...environment(harness), ...(selected === 'pi' ? { WOVENMATTER_LOCAL_PI: '1' } : {}) }, stdio: ['pipe', 'pipe', 'pipe'],
    })
    channel.process = child
    channel.state = 'running'
    const lines = createInterface({ input: child.stdout })
    lines.on('line', line => {
      if (Buffer.byteLength(line) > 8 * 1024 * 1024) { child.kill('SIGTERM'); return }
      let message
      try { message = JSON.parse(line) } catch { return }
      serialize(async () => {
        const event = { type: 'output', sequence: channel.events.length + 1, message }
        await record(channel, event)
        channel.events.push(event)
        updateSnapshot(channel.snapshot, event)
        wakePolls(channel)
      }).catch(() => { channel.failure = 'Unable to retain ACP output'; child.kill('SIGTERM') })
    })
    // Drain stderr, but never persist potentially sensitive provider diagnostics.
    child.stderr.on('data', () => {})
    child.stdin.on('error', () => { channel.state = 'interrupted'; wakePolls(channel) })
    child.on('error', () => {
      channel.state = 'interrupted'; channel.process = null; wakePolls(channel)
      serialize(() => flushJournal(channel)).catch(() => { channel.failure = 'Unable to retain ACP output' })
    })
    child.on('close', () => {
      channel.state = 'stopped'; channel.process = null; lines.close()
      // Keep terminal recovery durable even when the native process exits on
      // its own, and settle any prompt that did not produce a final response.
      serialize(async () => {
        const entry = { type: 'stopped' }
        await record(channel, entry)
        updateSnapshot(channel.snapshot, entry)
        wakePolls(channel)
      }).catch(() => { channel.failure = 'Unable to retain ACP termination' })
    })
    return channel
  }
  function wakePolls(channel) {
    for (const wake of channel.pollWaiters ?? []) wake()
  }
  function waitForOutput(channel, after, milliseconds) {
    if (channel.state !== 'running' || channel.events.length > after) return Promise.resolve()
    channel.pollWaiters ??= new Set()
    if (channel.pollWaiters.size >= 32) throw new Error('Too many session attachments')
    return new Promise(resolve => {
      let timer
      const finish = () => { clearTimeout(timer); channel.pollWaiters.delete(finish); resolve() }
      channel.pollWaiters.add(finish)
      timer = setTimeout(finish, milliseconds)
    })
  }
  async function handle(method, path, body) {
    if (method !== 'POST' || !path.startsWith('/v1/durable-acp/')) return null
    const operation = path.slice('/v1/durable-acp/'.length)
    const result = await serialize(async () => {
      if (!await isEnabled()) throw new Error('Background execution is disabled')
      if (!['attach', 'message', 'poll', 'recover', 'cli'].includes(operation)) throw new Error('Unknown relay operation')
      const channel = await channelFor(body.channelID, body.harnessID, body.cwd, body.permission, body.nativeSessionID, operation === 'recover')
      if (['attach', 'recover'].includes(operation) && body.attachmentProtocol === 1) {
        // This shares the native admission queue: earlier requests are already
        // accounted for, while delayed requests from the old relay cannot admit.
        channel.attachmentToken = randomUUID()
      }
      if (operation === 'cli') {
        if (!channel.attachmentToken || body.attachmentToken !== channel.attachmentToken) throw new Error('This session attachment was replaced')
        if (!channel.process || channel.state !== 'running') throw new Error('Native process is unavailable')
        if (!body.context || typeof body.context.executablePath !== 'string' || !body.context.executablePath.startsWith('/')) throw new Error('Invalid CLI connection')
        channel.process.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'woven/cli', params: body.context }) + '\n')
        return { ready: true }
      }
      if (operation === 'message') {
        if ((channel.attachmentToken || body.attachmentToken) && body.attachmentToken !== channel.attachmentToken) {
          throw new Error('This session attachment was replaced. Reconnect before sending another message.')
        }
        identifier(body.deliveryID)
        if (!body.message || (channel.harnessID === 'pi' ? typeof body.message.type !== 'string' : body.message.jsonrpc !== '2.0')) throw new Error('Invalid ACP message')
        if (channel.accepted.has(body.deliveryID)) return { accepted: true, duplicate: true }
        if ((!body.message.method && !body.message.type || body.message.type === 'extension_ui_response') && body.message.id !== undefined && !channel.snapshot.callbacks.has(body.message.id)) return { accepted: true, duplicate: true }
        if (!channel.process || channel.state !== 'running') throw new Error('Session interrupted; explicit recovery is required')
        const sameRunSteering = body.message.method === 'session/prompt'
          && typeof body.message.params?._meta?.wovenRunID === 'string'
          && [...channel.snapshot.runs.values()].some(run => run.runID === body.message.params._meta.wovenRunID
            && run.sessionID === body.message.params.sessionId)
        if (channel.snapshot.busy && body.message.method === '_session/steering'
          && ![...channel.snapshot.runs.values()].some(run => run.sessionID === body.message.params?.sessionId
            && (body.message.params?._meta?.wovenRunID === undefined || run.runID === body.message.params._meta.wovenRunID))) {
          throw new Error('Steering input belongs to another remote task')
        }
        if (channel.snapshot.busy && !sameRunSteering && ['session/prompt', 'session/load', 'session/new', 'session/set_model', 'session/set_mode', 'session/set_config_option'].includes(body.message.method)) throw new Error('Remote task is still running; reconnect after it finishes')
        const samePiRunSteering = body.message.type === 'prompt' && body.message.streamingBehavior === 'steer'
          && typeof body.message._meta?.wovenRunID === 'string'
          && [...channel.snapshot.runs.values()].some(run => run.runID === body.message._meta.wovenRunID)
        if (channel.snapshot.busy && channel.harnessID === 'pi' && !samePiRunSteering && !['get_state', 'get_available_models', 'get_available_thinking_levels', 'get_commands', 'abort', 'steer', 'follow_up', 'extension_ui_response'].includes(body.message.type)) throw new Error('Remote task is still running; reconnect after it finishes')
        const outgoing = { ...body.message }
        if (channel.harnessID === 'pi' && outgoing._meta) {
          if (outgoing._meta.wovenTools) outgoing._meta = { wovenTools: outgoing._meta.wovenTools };
          else delete outgoing._meta
        }
        const line = JSON.stringify(outgoing) + '\n'
        if (Buffer.byteLength(line) > 8 * 1024 * 1024) throw new Error('ACP message is too large')
        const accepted = { type: 'accepted', deliveryID: body.deliveryID, message: body.message }
        await record(channel, accepted)
        updateSnapshot(channel.snapshot, accepted)
        channel.accepted.add(body.deliveryID)
        channel.process.stdin.write(line)
        const stoppedPreflight = channel.harnessID === 'pi' && body.message.type === 'abort'
          && body.message._meta?.wovenStopPreflight === true
        // Pi aborts the active loop, but an extension preflight can otherwise
        // finish later and start another loop. Explicit Stop retires this
        // service-owned process just as local cancellation retires local Pi.
        if (stoppedPreflight) {
          channel.state = 'stopped'
          const child = channel.process
          await new Promise(resolve => {
            const timer = setTimeout(() => { if (channel.process === child) child.kill('SIGKILL') }, 1500)
            child.once('close', () => { clearTimeout(timer); resolve() })
            child.kill('SIGTERM')
          })
        }
        return { accepted: true, ...(stoppedPreflight ? { stoppedPreflight: true } : {}) }
      }
      const after = body.after ?? 0
      if (!Number.isSafeInteger(after) || after < 0) throw new Error('Invalid output cursor')
      const publicSnapshot = { initialized: channel.snapshot.initialized, piState: channel.snapshot.piState, session: channel.snapshot.session,
        busy: channel.snapshot.busy, pendingRequests: channel.snapshot.pendingRequests,
        recoveryComplete: !!channel.attachmentToken && body.attachmentToken === channel.attachmentToken
          && !channel.snapshot.busy && !channel.failure && channel.state === 'running',
        ...((['attach', 'recover'].includes(operation) || body.includeRecovery) ? { recoveredRuns: channel.snapshot.recoveredRuns } : {}) }
      return { channelID: channel.id, state: channel.state, failure: channel.failure,
        ...(['attach', 'recover'].includes(operation) && body.attachmentProtocol === 1 ? { attachmentToken: channel.attachmentToken } : {}),
        snapshot: publicSnapshot, events: channel.events.slice(after, after + 256) }
    })
    if (operation === 'poll' && body.waitMs != null) {
      if (!Number.isFinite(body.waitMs) || body.waitMs < 0) throw new Error('Invalid poll wait')
      if (body.waitMs > 0 && result.state === 'running' && result.events.length === 0) {
        // Never hold the command serialization queue while an idle client waits.
        // Check current state while registering so output between read and wait
        // cannot be lost. Every output record wakes all attached clients.
        await waitForOutput(channels.get(body.channelID), body.after ?? 0, Math.min(10000, body.waitMs))
        return handle(method, path, {...body, waitMs: 0})
      }
    }
    return result
  }
  return { handle,
    hasActiveRuntime: id => [...channels.values()].some(channel => channel.process && (!id || channel.harnessID === id)),
    stopAll: () => serialize(async () => {
      await Promise.all([...channels.values()].map(channel => new Promise(resolve => {
        if (!channel.process) { resolve(); return }
        channel.state = 'stopped'
        const child = channel.process
        const timer = setTimeout(() => { if (channel.process === child) child.kill('SIGKILL') }, 1500)
        child.once('close', () => { clearTimeout(timer); resolve() })
        child.kill('SIGTERM')
      })))
      for (const channel of channels.values()) {
        if (channel.state !== 'stopped') continue
        const entry = { type: 'stopped' }
        await record(channel, entry)
        updateSnapshot(channel.snapshot, entry)
        wakePolls(channel)
      }
    }),
  }
}
