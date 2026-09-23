import { createInterface } from 'node:readline'
import { randomUUID } from 'node:crypto'
import { pathToFileURL } from 'node:url'

export async function runStdioRelay({ channelID, harnessID, cwd, permission, nativeSessionID,
  token = process.env.WOVENMATTER_API_TOKEN, port = process.env.WOVENMATTER_LISTEN_PORT ?? '7337',
  input = process.stdin, output = process.stdout, request = fetch, loadTimeout = 30000 }) {
  if (!token) throw new Error('Remote service authentication is unavailable')
  if (!/^\d+$/.test(String(port))) throw new Error('Invalid service port')
  const lifecycle = new AbortController()
  const pi = harnessID === 'pi'
  let stopped = false, cursor = 0, state, activePiPrompt = false, piReconnecting = false, idleBackoff = 100
  const attachment = randomUUID(), requestIDs = new Map(), requestMethods = new Map(), incomingRequests = new Set()
  const write = message => new Promise((resolve, reject) => output.write(JSON.stringify(message) + '\n', error => error ? reject(error) : resolve()))
  async function call(operation, values = {}) {
    const response = await request(`http://127.0.0.1:${port}/v1/durable-acp/${operation}`, {
      method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ channelID, harnessID, cwd, permission, nativeSessionID, ...values }), signal: AbortSignal.any([lifecycle.signal, AbortSignal.timeout(15000)]),
    })
    if (!response.ok) throw new Error(`Remote session relay failed (${response.status})`)
    return response.json()
  }
  let attached = await call('attach')
  if (attached.state === 'stopped') attached = await call('recover')
  state = attached.snapshot
  piReconnecting = pi && !!state.piState
  // Historical notifications are reconciled through recoveredRuns, never blindly
  // replayed into a transcript that already contains them.
  cursor = attached.events.at(-1)?.sequence ?? 0
  while (attached.events.length === 256) {
    const remaining = await call('poll', { after: cursor })
    cursor = remaining.events.at(-1)?.sequence ?? cursor
    state = { ...state, ...remaining.snapshot }
    if (remaining.events.length < 256) break
  }
  const reader = createInterface({ input })
  const operations = new Set()
  async function handleMessage(message) {
      try {
        if (message.method === 'initialize' && state.initialized) {
          await write({ jsonrpc: '2.0', id: message.id, result: state.initialized }); return
        }
        if ((message.method === 'session/load' && state.session?.sessionId === message.params?.sessionId) || (piReconnecting && message.type === 'get_state')) {
          // Re-issue only callbacks still waiting on the service-owned process.
          // The client handles them with its normal permission and filesystem policy.
          for (const pending of state.pendingRequests ?? []) {
            if (incomingRequests.has(pending.id)) continue
            incomingRequests.add(pending.id)
            await write(pending)
          }
          const deadline = Date.now() + loadTimeout
          while (state.busy && Date.now() < deadline && !stopped) {
            await new Promise(resolve => setTimeout(resolve, 100))
            // The main event wait keeps state current without a second poll loop.
          }
          if (state.busy) throw new Error('Remote task is still running; reconnect after it finishes')
          state = (await call('poll', { after: cursor, includeRecovery: true })).snapshot
          if (pi) {
            piReconnecting = false
            await write({ type: 'response', id: message.id, command: 'get_state', success: true, data: {
              ...state.piState, _meta: { recoveredRuns: state.recoveredRuns },
            } }); return
          }
          const { sessionId, ...result } = state.session
          await write({ jsonrpc: '2.0', id: message.id, result: {
            ...result, _meta: { ...result._meta, recoveredRuns: state.recoveredRuns },
          } }); return
        }
        if (attached.state !== 'running') throw new Error('Remote process stopped; start a new session to continue')
        if ((message.method || (pi && message.type !== 'extension_ui_response')) && message.id !== undefined) {
          const id = `${attachment}:${String(message.id)}`
          requestIDs.set(id, message.id)
          requestMethods.set(id, message.method ?? message.type)
          message.id = id
        } else if (!message.method && message.id !== undefined) {
          if (!incomingRequests.delete(message.id)) return
        }
        if (pi && message.type === 'prompt') activePiPrompt = true
        await call('message', { deliveryID: randomUUID(), message })
      } catch (error) {
        const originalID = requestIDs.get(message.id) ?? message.id
        requestIDs.delete(message.id)
        requestMethods.delete(message.id)
        if (pi) {
          if (message.type === 'prompt') activePiPrompt = false
          if (message.id !== undefined) await write({ type: 'response', id: originalID, command: message.type, success: false, error: error.message })
          return
        }
        if (message.id !== undefined) await write({ jsonrpc: '2.0', id: originalID,
          error: { code: -32000, message: error.message } })
      }
  }
  const sending = (async () => {
    for await (const line of reader) {
      if (!line.trim()) continue
      const operation = handleMessage(JSON.parse(line))
      operations.add(operation)
      operation.finally(() => operations.delete(operation)).catch(() => { stopped = true })
    }
    stopped = true
    lifecycle.abort()
    await Promise.all(operations)
  })()
  sending.catch(() => { stopped = true; lifecycle.abort() })
  try {
    while (!stopped) {
      const pollStarted = performance.now()
      const batch = await call('poll', { after: cursor, waitMs: 10000 })
      state = { ...state, ...batch.snapshot }
      for (const event of batch.events) {
        const message = event.message
        if (message.id !== undefined && !message.method && message.type !== 'extension_ui_request') {
          if (requestIDs.has(message.id)) {
            let delivered = { ...message, id: requestIDs.get(message.id) }
            if (requestMethods.get(message.id) === 'session/load' && message.result) delivered.result = {
              ...message.result, _meta: { ...message.result._meta, recoveredRuns: state.recoveredRuns ?? [] },
            }
            if (pi && requestMethods.get(message.id) === 'get_state' && message.success) delivered.data = {
              ...message.data, _meta: { ...message.data?._meta, recoveredRuns: state.recoveredRuns ?? [] },
            }
            await write(delivered)
            requestIDs.delete(message.id)
            requestMethods.delete(message.id)
          }
        } else if ((message.method || (pi && message.type !== 'extension_ui_response')) && message.id !== undefined) {
          if (!incomingRequests.has(message.id)) {
            incomingRequests.add(message.id)
            await write(message)
          }
        } else if (requestIDs.size || activePiPrompt) await write(message)
        if (pi && message.type === 'agent_settled') activePiPrompt = false
        cursor = event.sequence
      }
      if (batch.state !== 'running') throw new Error('Remote process stopped; reconnect to recover its saved results')
      // An older service may ignore waitMs. Avoid spinning its idle endpoint.
      if (!batch.events.length && performance.now() - pollStarted < 25) {
        await new Promise(resolve => setTimeout(resolve, idleBackoff))
        idleBackoff = Math.min(1000, idleBackoff * 2)
      } else { idleBackoff = 100 }
    }
    await sending
  } catch (error) {
    if (!stopped) throw error
    await sending
  } finally { stopped = true; lifecycle.abort(); reader.close() }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2)
  const option = name => args.includes(name) ? args[args.indexOf(name) + 1] : undefined
  runStdioRelay({ channelID: option('--channel-id'), harnessID: option('--harness-id'), cwd: option('--cwd'), permission: option('--permission-mode'), nativeSessionID: option('--session') }).catch(() => {
    process.stderr.write('The remote session relay disconnected. Work may still be running on the workspace.\n')
    process.exitCode = 1
  })
}
