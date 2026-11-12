import { memberURL } from './member-client.mjs'
import { decodeFrame, encodeFrame, maximumFrameBytes, streamCloseCodes, streamProtocolVersion, streamTimings } from './stream-protocol.mjs'
import { WebSocket } from './websocket.mjs'

// One stream from this server to another member's server, for agent-to-agent
// waiting (docs/architecture/WOVEN_EVERYWHERE.md, "Streaming", "Clients" and
// "Agent to agent"). It owns reconnection: every attempt is signed afresh,
// with backoff from 1 s to 30 s plus jitter. Subscriptions resume after a
// reconnect (a `workspace` journal from its last sequence); calls do not. A
// `4401` close means this member was removed there: no attempt is made until
// `retry()`, which the owner calls when its member list changes.

const fail = (code, message, extra = {}) => Object.assign(new Error(message), { code, ...extra })

/** The signed upgrade target: `<endpoint>/v1/stream?protocol=1`. */
export function streamURL(endpoint) {
  const url = memberURL(endpoint, 'v1/stream')
  url.search = '?protocol=' + streamProtocolVersion
  return url
}

/**
 * `endpoint` is the member's execution endpoint (https on the tailnet).
 * `sign(url)` returns the member signature headers for `GET url`; on a Linux
 * host, `url => transport.signedHeaders(url, {audience})` (member-client.mjs).
 */
export function createStreamClient({ endpoint, sign, webSocket = WebSocket, onEvent = () => {}, timings = {}, random = Math.random }) {
  const time = { initial: streamTimings.reconnectInitialMilliseconds, maximum: streamTimings.reconnectMaximumMilliseconds,
    ping: streamTimings.pingMilliseconds, pongTimeout: streamTimings.pongTimeoutMilliseconds, ...timings }
  const subscriptions = new Map(), calls = new Map()
  let socket = null, state = 'idle', attempts = 0, retryTimer = null, counter = 0, hello = null, stopped = false
  const emit = event => { try { onEvent(event) } catch {} }
  const send = frame => { if (state === 'open' && socket?.readyState === 1) socket.send(encodeFrame(frame)) }

  /** The wait before attempt `n` (from 0): doubling from 1 s, at most 30 s, with jitter. */
  const delay = n => Math.min(time.maximum, Math.min(time.maximum, time.initial * 2 ** n) * (0.8 + 0.4 * random()))

  function schedule() {
    if (stopped || state === 'removed') return
    const wait = delay(attempts++)
    state = 'waiting'
    emit({ type: 'retrying', delay: wait })
    retryTimer = setTimeout(() => { retryTimer = null; void attempt() }, wait)
    retryTimer.unref?.()
  }

  async function attempt() {
    if (stopped || state === 'removed' || state === 'connecting' || state === 'open') return
    state = 'connecting'
    emit({ type: 'connecting' })
    const url = streamURL(endpoint)
    let headers
    try { headers = await sign(url) }
    catch (error) { state = 'idle'; emit({ type: 'refused', error }); schedule(); return }
    if (stopped) return
    const target = new URL(url)
    target.protocol = target.protocol === 'https:' ? 'wss:' : 'ws:'
    const current = new webSocket(target, { headers, perMessageDeflate: false, maxPayload: maximumFrameBytes, handshakeTimeout: 15_000 })
    socket = current
    let pinger = null, deadline = null
    current.on('unexpected-response', (_, response) => {
      // A refusal before the upgrade, such as `member_time_stale`.
      const chunks = []
      response.on('data', chunk => { if (chunks.length < 16) chunks.push(chunk) })
      response.on('end', () => {
        let body = null
        try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')) } catch {}
        emit({ type: 'refused', status: response.statusCode, body })
        current.terminate()
      })
    })
    current.on('open', () => {
      pinger = setInterval(() => { if (current.readyState === 1) current.ping() }, time.ping)
      deadline = setTimeout(() => current.terminate(), time.pongTimeout)
      pinger.unref?.(); deadline.unref?.()
    })
    current.on('pong', () => deadline?.refresh())
    current.on('message', (data, isBinary) => {
      if (isBinary) return
      let frame
      try { frame = decodeFrame(data) } catch { current.close(streamCloseCodes.protocolViolation); return }
      receive(frame)
    })
    current.on('error', () => {})
    current.on('close', code => {
      clearInterval(pinger); clearTimeout(deadline)
      if (socket !== current) return
      socket = null; hello = null
      for (const [id, call] of calls) { calls.delete(id); call.reject(fail('unavailable', 'The stream closed before the server answered.', { outcomeUnknown: true })) }
      emit({ type: 'closed', code })
      if (stopped) { state = 'closed'; return }
      if (code === streamCloseCodes.memberRemoved) { state = 'removed'; emit({ type: 'removed' }); return }
      state = 'idle'
      schedule()
    })
  }

  function subscribeFrame(subscription) {
    return { t: 'sub', id: subscription.id, stream: subscription.stream,
      params: subscription.cursor !== undefined ? { ...subscription.params, after: subscription.cursor } : subscription.params }
  }

  function receive(frame) {
    if (frame.t === 'hello') {
      if (frame.protocol !== streamProtocolVersion) { socket?.close(streamCloseCodes.protocolViolation); return }
      hello = frame; state = 'open'; attempts = 0
      emit({ type: 'open', hello })
      for (const subscription of subscriptions.values()) send(subscribeFrame(subscription))
      return
    }
    if (frame.t === 'res') {
      const call = calls.get(frame.id)
      if (!call) return
      calls.delete(frame.id)
      if (frame.error) call.reject(fail(frame.error.code, frame.error.message, { retryable: frame.error.retryable }))
      else call.resolve(frame.result)
      return
    }
    if (frame.t === 'item') {
      const subscription = subscriptions.get(frame.id)
      if (!subscription) return
      if (frame.kind === 'journal' && subscription.cursor !== undefined && frame.seq !== undefined) subscription.cursor = frame.seq
      try { subscription.onItem(frame) } catch {}
      return
    }
    if (frame.t === 'end') {
      const subscription = subscriptions.get(frame.id)
      if (!subscription) return
      // Fell behind: subscribe again, from a snapshot or the journal cursor.
      if (frame.error?.code === 'resync') { send(subscribeFrame(subscription)); return }
      subscriptions.delete(frame.id)
      try { subscription.onEnd(frame.error ?? null) } catch {}
    }
    // Other frames are ignored.
  }

  return {
    /** Starts connecting; later reconnects are automatic. */
    connect() { stopped = false; if (state === 'idle' || state === 'closed') void attempt() },
    /** After a `4401` close, once this member's list has changed. */
    retry() {
      if (stopped) return
      if (state === 'removed') state = 'idle'
      clearTimeout(retryTimer); retryTimer = null; attempts = 0
      if (state === 'idle' || state === 'waiting') { state = 'idle'; void attempt() }
    },
    /**
     * Opens a subscription that resumes after reconnects. For `workspace`
     * with `after`, a resumed subscription starts after the last journal
     * item received.
     */
    subscribe(stream, params = {}, { onItem = () => {}, onEnd = () => {} } = {}) {
      const { after, ...rest } = params
      const subscription = { id: 's' + ++counter, stream, params: rest, cursor: stream === 'workspace' ? after : undefined, onItem, onEnd }
      if (stream !== 'workspace' && after !== undefined) subscription.params.after = after
      subscriptions.set(subscription.id, subscription)
      send(subscribeFrame(subscription))
      return { id: subscription.id, cursor: () => subscription.cursor, cancel() { if (subscriptions.delete(subscription.id)) send({ t: 'cancel', id: subscription.id }) } }
    },
    /** One call. Never replayed: a call cut off by a disconnect rejects with `outcomeUnknown`. */
    request(method, params = {}) {
      if (state !== 'open') return Promise.reject(fail('unavailable', 'The stream is not connected.'))
      const id = 'r' + ++counter
      return new Promise((resolve, reject) => { calls.set(id, { resolve, reject }); send({ t: 'req', id, method, params }) })
    },
    state: () => state,
    hello: () => hello,
    close() {
      stopped = true
      clearTimeout(retryTimer); retryTimer = null
      if (socket) socket.close(streamCloseCodes.normal); else state = 'closed'
    },
  }
}
