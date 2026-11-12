import { createHash } from 'node:crypto'
import { WebSocketServer } from './websocket.mjs'
import { authenticateMemberUpgrade, executionMemberKinds, refuseUpgrade } from './member-sockets.mjs'
import { decodeFrame, encodeFrame, maximumClientFrameBytes, maximumFrameBytes, streamCloseCodes, streamErrorFor, streamFailure,
  streamPath, streamProtocolVersion, streamQueueLimits, streamTimings, supportedStreamProtocols } from './stream-protocol.mjs'

// The Linux host's live stream (docs/architecture/WOVEN_EVERYWHERE.md,
// "Streaming"): `GET /v1/stream?protocol=1` at the execution endpoint,
// member-signed, upgraded to a WebSocket that carries `workspace` and
// `conversation` subscriptions and `execution.*` calls. The stream reads the
// stored execution state as it changes (`execution.watch`); it never writes
// the journal.

const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)
const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value)
const hash = text => createHash('sha256').update(text ?? 'null').digest('base64')
const failure = (code, message, retryable = false) => Object.assign(new Error(message), { stream: streamFailure(code, message, retryable) })
const OPEN = 1

/** Entities by ID: the newer copy of an entity replaces the older one in place. */
function mergeByID(older = [], newer = []) {
  const merged = [...older], index = new Map(merged.map((item, position) => [item.id, position]))
  for (const item of newer) {
    if (index.has(item.id)) merged[index.get(item.id)] = item
    else { index.set(item.id, merged.length); merged.push(item) }
  }
  return merged
}

// The fields every transcript upsert carries from the stored transcript.
function transcriptShape(transcript) {
  return { ...(transcript.activeRunID ? { activeRunID: transcript.activeRunID } : {}), ...(transcript.runs ? { runs: transcript.runs } : {}),
    ...(transcript.removedMessageIDs ? { removedMessageIDs: transcript.removedMessageIDs } : {}) }
}

/**
 * One socket's outbound queue (docs: "Backpressure"): bounded by `limits.items`
 * and `limits.bytes`, with a newer item for the same entity superseding a
 * queued one. Responses, ends and hello always go out. A subscription item
 * that still does not fit drops that subscription's queued items and calls
 * `overflow(subscription)`, which ends it with `resync`. At most
 * `limits.inflightBytes` are handed to `send` before its callbacks return.
 */
export function createOutboundQueue({ send, isOpen = () => true, limits, overflow, pressure = () => {}, log = () => {} }) {
  const queue = [], keyed = new Map(), waiters = []
  let queuedBytes = 0, inflight = 0, closed = false
  const room = () => queue.length < limits.items / 2 && queuedBytes < limits.bytes / 2
  function wake() {
    if (!closed && !room()) return
    for (const waiter of waiters.splice(0)) waiter()
  }
  const waitForRoom = () => new Promise(resolve => { waiters.push(resolve); wake() })
  function pump() {
    while (!closed && queue.length && inflight < limits.inflightBytes && isOpen()) {
      const entry = queue.shift()
      queuedBytes -= entry.bytes
      if (entry.key && keyed.get(entry.key) === entry) keyed.delete(entry.key)
      inflight += entry.bytes
      send(entry.text, error => { inflight -= entry.bytes; if (!error) pump() })
    }
    pressure(queue.length >= limits.items || queuedBytes >= limits.bytes)
    wake()
  }
  function drop(subscription) {
    for (let index = queue.length - 1; index >= 0; index--) {
      const entry = queue[index]
      if (entry.subscription !== subscription) continue
      queue.splice(index, 1); queuedBytes -= entry.bytes
      if (entry.key && keyed.get(entry.key) === entry) keyed.delete(entry.key)
    }
  }
  function overflowed(subscription) {
    drop(subscription)
    overflow(subscription)
    return false
  }
  /**
   * Queues one frame. `subscription` marks an item that may be dropped on
   * overflow; `key` names its entity, and `merge(queued, next)` returns the
   * frame that replaces a queued one with the same key (or null to queue both).
   */
  function enqueue(frame, { subscription = null, key = null, merge = null } = {}) {
    if (closed || subscription?.ended) return false
    const fullKey = key && subscription ? subscription.id + '\0' + key : null
    const queued = fullKey ? keyed.get(fullKey) : null
    if (queued && merge) {
      const merged = merge(queued.frame, frame)
      let text = null
      if (merged) { try { text = encodeFrame(merged, { maximumBytes: limits.frameBytes }) } catch {} }
      if (text) {
        const bytes = Buffer.byteLength(text)
        if (queuedBytes - queued.bytes + bytes > limits.bytes) return overflowed(subscription)
        queuedBytes += bytes - queued.bytes
        Object.assign(queued, { frame: merged, text, bytes })
        pump()
        return true
      }
    }
    let text
    try { text = encodeFrame(frame, { maximumBytes: limits.frameBytes }) }
    catch (error) { log('A stream frame could not be sent: ' + error.message); return false }
    const bytes = Buffer.byteLength(text)
    if (subscription && queue.length && (queue.length + 1 > limits.items || queuedBytes + bytes > limits.bytes)) return overflowed(subscription)
    const entry = { frame, text, bytes, key: fullKey, subscription }
    queue.push(entry); queuedBytes += bytes
    if (fullKey) keyed.set(fullKey, entry)
    pump()
    return true
  }
  function close() { closed = true; queue.length = 0; keyed.clear(); queuedBytes = 0; wake() }
  return { enqueue, drop, room, waitForRoom, pump, close, size: () => ({ items: queue.length, bytes: queuedBytes, inflight }) }
}

/**
 * `members` is the member verifier, `execution` the client execution service,
 * `registry` the shared member socket registry (member-sockets.mjs).
 * `clock` drives conversation coalescing only, so tests can use fake time.
 */
export function createStreamServer({ members, servedTargets = async () => [], execution, registry, serverDeviceID = () => members.audience(),
  workspaceEnabled = () => true, kinds = executionMemberKinds, clock = { now: () => Date.now(), setTimeout, clearTimeout }, limits = {}, timings = {}, log = () => {} }) {
  const limit = { items: streamQueueLimits.items, bytes: streamQueueLimits.bytes, inflightBytes: 1024 * 1024, subscriptions: 64, calls: 64,
    frameBytes: maximumFrameBytes, clientFrameBytes: maximumClientFrameBytes, snapshotWindow: 40, ...limits }
  const time = { pingMilliseconds: streamTimings.pingMilliseconds, pongTimeoutMilliseconds: streamTimings.pongTimeoutMilliseconds,
    smallMessageBytes: streamTimings.smallMessageBytes, smallMessageMilliseconds: streamTimings.smallMessageMilliseconds,
    largeMessageMilliseconds: streamTimings.largeMessageMilliseconds, closeMilliseconds: 5_000, ...timings }
  const webSockets = new WebSocketServer({ noServer: true, maxPayload: limit.clientFrameBytes, perMessageDeflate: false, clientTracking: false })
  const connections = new Set()
  let closed = false
  const unwatch = execution.watch(change => { for (const connection of connections) connection.changed(change) })

  /** Handles `/v1/stream` upgrades; returns false for any other path. */
  function upgrade(request, socket, head) {
    const url = new URL(request.url, 'http://localhost')
    if (url.pathname !== streamPath) return false
    socket.on('error', () => {})
    void accept(request, socket, head, url).catch(error => { log('A stream upgrade failed: ' + error.message); socket.destroy() })
    return true
  }

  async function accept(request, socket, head, url) {
    // Native apps and servers only: a browser page cannot open the stream.
    if (request.headers.origin !== undefined || request.headers.cookie !== undefined) return refuseUpgrade(socket, 403, { code: 'unauthorized', message: 'Browser requests cannot open the stream.' })
    if (request.method !== 'GET' || (request.headers.upgrade ?? '').toLowerCase() !== 'websocket') return refuseUpgrade(socket, 400, { code: 'invalid', message: 'Open the stream with a WebSocket upgrade.' })
    const requested = url.searchParams.getAll('protocol')
    if (requested.length !== 1 || !supportedStreamProtocols.some(version => String(version) === requested[0])) {
      return refuseUpgrade(socket, 426, { code: 'protocol_unsupported', message: 'This server speaks another stream protocol. Update the app.', supported: [...supportedStreamProtocols] })
    }
    const authenticated = await authenticateMemberUpgrade(request, { members, servedTargets, kinds })
    if (!authenticated.member) return refuseUpgrade(socket, authenticated.status, authenticated.body)
    let descriptor, deviceID
    try { descriptor = execution.descriptor(); deviceID = await serverDeviceID() }
    catch { return refuseUpgrade(socket, 503, { code: 'unavailable', message: 'This server has no workspace to stream yet.' }) }
    if (closed) return refuseUpgrade(socket, 503, { code: 'unavailable', message: 'This server is stopping.' })
    webSockets.handleUpgrade(request, socket, head, ws => open(ws, authenticated.member, { descriptor, deviceID }))
  }

  function open(ws, member, { descriptor, deviceID }) {
    const connection = createConnection(ws, member)
    connections.add(connection)
    connection.enqueue({ t: 'hello', protocol: streamProtocolVersion, deviceID, libraryID: descriptor.libraryID, workspaceID: descriptor.id,
      serverTime: Date.now(), capabilities: descriptor.capabilities ?? [], maxFrameBytes: limit.frameBytes })
  }

  function createConnection(ws, member) {
    const subscriptions = new Map(), calls = new Map()
    const device = { id: member.deviceID, name: member.name, scopes: ['execution', 'inference'], memberKind: member.kind }
    let ended = false, closeTimer = null

    // Liveness: ping every 25 s; a socket with no pong for 60 s is gone.
    const pinger = setInterval(() => { if (ws.readyState === OPEN) ws.ping() }, time.pingMilliseconds)
    const deadline = setTimeout(() => ws.terminate(), time.pongTimeoutMilliseconds)
    pinger.unref?.(); deadline.unref?.()
    ws.on('pong', () => deadline.refresh())
    const unregister = registry ? registry.add(member, { kinds, close: (code, reason) => close(code, reason) }) : () => {}

    function close(code, reason) {
      if (ended) return
      try { ws.close(code, reason) } catch { ws.terminate() }
      closeTimer ??= setTimeout(() => ws.terminate(), time.closeMilliseconds)
      closeTimer.unref?.()
    }
    function violation(message) { close(streamCloseCodes.protocolViolation, message.slice(0, 120)) }

    const outbound = createOutboundQueue({ limits: limit, log, isOpen: () => ws.readyState === OPEN, send: (text, done) => ws.send(text, done),
      // A client that does not read its responses stops being read.
      pressure: full => { if (full && !ws.isPaused) ws.pause(); else if (!full && ws.isPaused) ws.resume() },
      overflow: subscription => endSubscription(subscription, streamFailure('resync', 'This subscription fell behind. Subscribe again.', true)) })
    const { room, waitForRoom } = outbound
    const enqueue = (frame, options) => ended ? false : outbound.enqueue(frame, options)

    function endSubscription(subscription, error) {
      if (subscription.ended) return
      subscription.ended = true
      subscription.stop()
      if (subscriptions.get(subscription.id) === subscription) subscriptions.delete(subscription.id)
      enqueue({ t: 'end', id: subscription.id, ...(error ? { error } : {}) })
    }

    function subscribe(frame) {
      const existing = subscriptions.get(frame.id)
      if (existing) { endSubscription(existing, streamFailure('invalid', 'This subscription ID is already in use.')); return }
      if (subscriptions.size >= limit.subscriptions) { enqueue({ t: 'end', id: frame.id, error: streamFailure('unavailable', 'Too many subscriptions on this connection.', true) }); return }
      const make = { workspace: workspaceStream, conversation: conversationStream }[frame.stream]
      if (!make) { enqueue({ t: 'end', id: frame.id, error: streamFailure('invalid', `This server has no ${frame.stream} stream.`) }); return }
      const subscription = { id: frame.id, ended: false, stop() {}, changed() {} }
      subscriptions.set(frame.id, subscription)
      const context = { subscription, enqueue, waitForRoom, room, end: error => endSubscription(subscription, error) }
      Promise.resolve().then(() => make(context, frame.params)).catch(error => endSubscription(subscription, error.stream ?? streamErrorFor(error)))
    }

    async function call(frame) {
      if (calls.has(frame.id)) { enqueue({ t: 'res', id: frame.id, error: streamFailure('invalid', 'This request ID is already in use.') }); return }
      if (calls.size >= limit.calls) { enqueue({ t: 'res', id: frame.id, error: streamFailure('unavailable', 'Too many calls on this connection.', true) }); return }
      const pending = { abandoned: false }
      calls.set(frame.id, pending)
      let reply
      try { reply = { result: await perform(frame.method, frame.params) ?? null } }
      catch (error) { reply = { error: error.stream ?? streamErrorFor(error) } }
      if (calls.get(frame.id) === pending) calls.delete(frame.id)
      if (!pending.abandoned) enqueue({ t: 'res', id: frame.id, ...reply })
    }

    // The same handlers, idempotent command IDs and receipts as
    // `POST v1/execution/commands` and `GET v1/execution/commands/<id>`.
    async function perform(method, params) {
      if (method === 'execution.command') {
        if (!isObject(params) || !isObject(params.command)) throw failure('invalid', 'Send {command}.')
        if (!workspaceEnabled()) throw failure('unavailable', 'This machine runs no workspace.')
        return execution.command(params.command, device)
      }
      if (method === 'execution.receipt') {
        if (!isObject(params) || typeof params.commandID !== 'string') throw failure('invalid', 'Send {commandID}.')
        try { return execution.receipt(params.commandID, device.id) }
        catch (error) { if (error.statusCode === 404) return null; throw error }
      }
      throw failure('invalid', `Unknown method ${String(method).slice(0, 64)}.`)
    }

    function cancel(id) {
      const subscription = subscriptions.get(id)
      if (subscription) { subscription.ended = true; subscription.stop(); subscriptions.delete(id); outbound.drop(subscription) }
      const pending = calls.get(id)
      if (pending) { pending.abandoned = true; calls.delete(id) }
    }

    ws.on('message', (data, isBinary) => {
      if (ended) return
      if (isBinary) return violation('The stream carries JSON text frames.')
      let frame
      try { frame = decodeFrame(data, { maximumBytes: limit.clientFrameBytes }) } catch (error) { return violation(error.message) }
      if (frame.t === 'req') void call(frame)
      else if (frame.t === 'sub') subscribe(frame)
      else if (frame.t === 'cancel') cancel(frame.id)
      // Unknown frame types, and server frames, are ignored.
    })
    ws.on('error', () => {})
    ws.on('close', () => {
      ended = true
      clearInterval(pinger); clearTimeout(deadline); clearTimeout(closeTimer)
      unregister(); connections.delete(connection)
      for (const subscription of subscriptions.values()) { subscription.ended = true; subscription.stop() }
      subscriptions.clear(); calls.clear(); outbound.close()
    })

    const connection = {
      enqueue, close, member,
      changed(change) { for (const subscription of subscriptions.values()) { if (!subscription.ended) subscription.changed(change) } },
    }
    return connection
  }

  // `workspace` {after?}: conversation summaries, pending interactions and,
  // when `after` is given, the execution journal after it.
  async function workspaceStream({ subscription, enqueue, waitForRoom, room, end }, params) {
    const after = params.after
    if (after !== undefined && (!Number.isSafeInteger(after) || after < 0)) throw failure('invalid', 'after is a journal sequence.')
    const summaries = new Map(), pendingByConversation = new Map(), dirty = new Set(), deleted = new Set()
    let pendingList = null, timer = null, lastSentAt = 0, cursor = after, pumping = false, more = false, synchronized = false
    const item = (kind, data, options = {}) => enqueue({ t: 'item', id: subscription.id, ...(options.seq !== undefined ? { seq: options.seq } : {}), kind, data },
      { subscription, key: options.key ?? null, merge: options.merge ?? null })
    const mergeConversations = (queued, next) => {
      const removed = new Set([...(queued.data.deletedConversationIDs ?? []), ...(next.data.deletedConversationIDs ?? [])])
      const conversations = mergeByID(queued.data.conversations, next.data.conversations)
      for (const conversation of next.data.conversations) removed.delete(conversation.id)
      return { ...next, data: { conversations: conversations.filter(conversation => !(next.data.deletedConversationIDs ?? []).includes(conversation.id)),
        ...(removed.size ? { deletedConversationIDs: [...removed] } : {}), snapshot: false } }
    }

    function sendPending() {
      const interactions = execution.interactions(), fingerprint = hash(JSON.stringify(interactions))
      if (fingerprint === pendingList) return
      pendingList = fingerprint
      item('pending', { interactions }, { key: 'pending', merge: (_, next) => next })
    }

    function flush() {
      timer = null
      if (subscription.ended) return
      const changed = []
      let pendingChanged = false
      for (const id of dirty) {
        const summary = execution.summary(id)
        if (!summary) { if (summaries.has(id)) deleted.add(id); continue }
        const fingerprint = hash(JSON.stringify(summary.conversation)), pending = hash(JSON.stringify(summary.pending))
        if (summaries.get(id) !== fingerprint) { summaries.set(id, fingerprint); changed.push(summary.conversation); deleted.delete(id) }
        if (pendingByConversation.get(id) !== pending) { pendingByConversation.set(id, pending); pendingChanged = true }
      }
      dirty.clear()
      const removed = [...deleted].filter(id => summaries.has(id))
      deleted.clear()
      for (const id of removed) { summaries.delete(id); if (pendingByConversation.delete(id)) pendingChanged = true }
      if (changed.length || removed.length) {
        item('conversations', { conversations: changed, ...(removed.length ? { deletedConversationIDs: removed } : {}), snapshot: false }, { key: 'conversations', merge: mergeConversations })
        lastSentAt = clock.now()
      }
      if (pendingChanged) sendPending()
    }
    function schedule() {
      if (timer || subscription.ended) return
      timer = clock.setTimeout(flush, Math.max(0, lastSentAt + time.smallMessageMilliseconds - clock.now()))
    }

    // The journal is read by cursor, so it waits for room instead of
    // overflowing: nothing is skipped, and nothing is held twice.
    async function pumpJournal() {
      more = true
      if (pumping) return
      pumping = true
      try {
        while (more && !subscription.ended) {
          more = false
          for (;;) {
            if (subscription.ended) return
            if (!room()) { await waitForRoom(); continue }
            const page = execution.events(cursor)
            for (const entry of page.entries) { item('journal', { entry }, { seq: entry.originSequence }); cursor = entry.originSequence }
            if (!page.hasMore) break
          }
        }
      } catch (error) { end(error.stream ?? streamErrorFor(error)); return }
      finally { pumping = false }
      if (!synchronized && !subscription.ended) { synchronized = true; item('synchronized', {}) }
    }

    subscription.changed = change => {
      if (change.kind === 'journal') { if (cursor !== undefined && change.sequence > cursor) void pumpJournal() }
      else if (change.kind === 'record') { dirty.add(change.conversationID); schedule() }
      else if (change.kind === 'deleted') { deleted.add(change.conversationID); dirty.delete(change.conversationID); schedule() }
    }
    subscription.stop = () => { clock.clearTimeout(timer); timer = null }

    const conversations = execution.conversations()
    for (const conversation of conversations) summaries.set(conversation.id, hash(JSON.stringify(conversation)))
    const pendingGroups = new Map()
    for (const interaction of execution.interactions()) pendingGroups.set(interaction.conversationID, [...(pendingGroups.get(interaction.conversationID) ?? []), interaction])
    for (const conversation of conversations) pendingByConversation.set(conversation.id, hash(JSON.stringify(pendingGroups.get(conversation.id) ?? [])))
    // A long list is sent in parts; only the first replaces the client's list.
    for (let offset = 0; offset === 0 || offset < conversations.length; offset += 1000) {
      item('conversations', { conversations: conversations.slice(offset, offset + 1000), snapshot: offset === 0 })
    }
    lastSentAt = clock.now()
    sendPending()
    if (cursor === undefined) { synchronized = true; item('synchronized', {}) }
    else await pumpJournal()
  }

  // `conversation` {conversationID}: the latest transcript window, then
  // upserts of changed messages and activities, the capabilities and the
  // session settings.
  async function conversationStream({ subscription, enqueue, end }, params) {
    const id = params.conversationID
    if (!uuid(id)) throw failure('invalid', 'conversationID is a conversation ID.')
    const sent = new Map(), hints = { all: false, messages: new Set(), activities: new Set() }
    let timer = null, lastSentAt = 0, ready = false, touched = false, shape = null, capabilitiesInput = null, capabilities = null
    let sessionInput = null, session = null, sessionStale = false, sessionRead = null, sessionAgain = false
    const item = (kind, data, options = {}) => enqueue({ t: 'item', id: subscription.id, kind, data }, { subscription, key: options.key ?? null, merge: options.merge ?? null })
    const mergeTranscripts = (queued, next) => queued.data.snapshot ? null : { ...next, data: { snapshot: false, transcript: {
      conversationID: id, messages: mergeByID(queued.data.transcript.messages, next.data.transcript.messages),
      activities: mergeByID(queued.data.transcript.activities, next.data.transcript.activities), ...transcriptShape(next.data.transcript) } } }

    function read() {
      try { return execution.record(id) }
      catch (error) { throw error.statusCode === 404 ? failure('not_found', 'This conversation is not on this workspace.') : error }
    }
    async function refreshCapabilities(record) {
      capabilitiesInput = hash(JSON.stringify([record.conversation.runtimeKind, record.native ?? null, record.conversation.activeRunID ?? null]))
      let value
      try { value = await execution.capabilities(id) } catch { return }
      if (subscription.ended || !value) return
      const fingerprint = hash(JSON.stringify(value))
      if (fingerprint === capabilities) return
      capabilities = fingerprint
      item('capabilities', { capabilities: value }, { key: 'capabilities', merge: (_, next) => next })
    }

    // The session settings, as the `session` workspace read answers them.
    // They are read again when what they derive from changes (the runtime's
    // native configuration, the run, the goal, the enabled tools) or when the
    // execution service says the settings changed (`session`); one read at a
    // time, the last one always after the latest change.
    const sessionKey = record => hash(JSON.stringify([record.conversation.runtimeKind, record.native ?? null, record.conversation.activeRunID ?? null,
      record.goal ?? null, record.enabledTools ?? null]))
    function refreshSession(record) {
      sessionInput = sessionKey(record); sessionStale = false
      if (sessionRead) { sessionAgain = true; return sessionRead }
      sessionRead = (async () => {
        do {
          sessionAgain = false
          let value = null
          try { value = (await execution.readWorkspace({ session: { id } }))?.session?._0 ?? null } catch {}
          if (subscription.ended) return
          if (!value) continue
          const fingerprint = hash(JSON.stringify(value))
          if (fingerprint === session) continue
          session = fingerprint
          item('session', { settings: value }, { key: 'session', merge: (_, next) => next })
        } while (sessionAgain && !subscription.ended)
      })().finally(() => { sessionRead = null })
      return sessionRead
    }

    // Upserts in as few items as fit in a frame.
    function sendUpserts(messages, activities, fields) {
      const entities = [...messages.map(value => ['messages', value]), ...activities.map(value => ['activities', value])]
      let batch = { messages: [], activities: [] }, bytes = 0
      const emit = () => item('transcript', { transcript: { conversationID: id, ...batch, ...fields }, snapshot: false }, { key: 'transcript', merge: mergeTranscripts })
      for (const [field, value] of entities) {
        const size = value.json.length + 64
        if (bytes && bytes + size > limit.frameBytes / 2) { emit(); batch = { messages: [], activities: [] }; bytes = 0 }
        batch[field].push(value.entity); bytes += size
      }
      emit()
    }

    function flush() {
      timer = null
      if (subscription.ended) return
      let record
      try { record = read() } catch (error) { end(error.stream ?? streamErrorFor(error)); return }
      const changed = (list, prefix, ids) => list.filter(entity => ids === null || ids.has(entity.id))
        .map(entity => ({ entity, json: JSON.stringify(entity) })).filter(value => sent.get(prefix + value.entity.id) !== hash(value.json))
      const messages = changed(record.transcript.messages, 'm:', hints.all ? null : hints.messages)
      const activities = changed(record.transcript.activities, 'a:', hints.all ? null : hints.activities)
      // Large messages are sent at most every 200 ms; the hints stay until then.
      const large = messages.some(value => Buffer.byteLength(value.json) > time.smallMessageBytes)
      const wait = lastSentAt + time.largeMessageMilliseconds - clock.now()
      if (large && wait > 0) { timer = clock.setTimeout(flush, wait); return }
      hints.all = false; hints.messages.clear(); hints.activities.clear()
      const fields = transcriptShape(record.transcript), fieldsHash = hash(JSON.stringify(fields))
      if (messages.length || activities.length || fieldsHash !== shape) {
        for (const value of messages) sent.set('m:' + value.entity.id, hash(value.json))
        for (const value of activities) sent.set('a:' + value.entity.id, hash(value.json))
        shape = fieldsHash
        sendUpserts(messages, activities, fields)
        lastSentAt = clock.now()
      }
      const input = hash(JSON.stringify([record.conversation.runtimeKind, record.native ?? null, record.conversation.activeRunID ?? null]))
      if (input !== capabilitiesInput) void refreshCapabilities(record)
      if (sessionStale || sessionKey(record) !== sessionInput) void refreshSession(record)
    }
    function schedule() {
      if (timer || !ready || subscription.ended) return
      timer = clock.setTimeout(flush, Math.max(0, lastSentAt + time.smallMessageMilliseconds - clock.now()))
    }

    subscription.changed = change => {
      if (change.conversationID !== id) return
      if (change.kind === 'deleted') { end(streamFailure('not_found', 'This conversation was removed.')); return }
      if (change.kind === 'session') { sessionStale = touched = true; schedule(); return }
      if (change.kind !== 'record') return
      touched = true
      if (change.transcript === 'all') hints.all = true
      else if (change.transcript) {
        for (const message of change.transcript.messages ?? []) hints.messages.add(message)
        for (const activity of change.transcript.activities ?? []) hints.activities.add(activity)
      }
      schedule()
    }
    subscription.stop = () => { clock.clearTimeout(timer); timer = null }

    const record = read()
    for (const message of record.transcript.messages) sent.set('m:' + message.id, hash(JSON.stringify(message)))
    for (const activity of record.transcript.activities) sent.set('a:' + activity.id, hash(JSON.stringify(activity)))
    shape = hash(JSON.stringify(transcriptShape(record.transcript)))
    // The latest window, as `GET …/transcript` returns it, made smaller only
    // if it does not fit in one frame.
    for (let window = limit.snapshotWindow; ; window = Math.floor(window / 2)) {
      const transcript = execution.transcript(id, null, { limit: Math.max(window, 1) })
      if (item('transcript', { transcript, snapshot: true }) || window <= 1 || subscription.ended) break
    }
    lastSentAt = clock.now()
    await refreshCapabilities(record)
    if (subscription.ended) return
    await refreshSession(record)
    if (subscription.ended) return
    item('synchronized', {})
    ready = true
    // Changes saved while the snapshot was being sent.
    if (touched) schedule()
  }

  async function close() {
    closed = true
    unwatch()
    for (const connection of connections) connection.close(streamCloseCodes.goingAway, 'The server is stopping.')
  }

  return { upgrade, close, connections: () => connections.size }
}
