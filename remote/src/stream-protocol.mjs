// Frames of the live stream (docs/architecture/WOVEN_EVERYWHERE.md,
// "Streaming"; Swift `StreamProtocol` in shared/). JSON text frames, one
// message per frame. Every device runs the same build, so a frame is one of
// the types below, an item one of the kinds below, and each carries the keys
// its type or kind requires: anything else is a protocol violation, as it is
// for the Swift decoder. `decodeFrame` keeps only the fields a frame type
// defines, so encoding a decoded frame gives the same JSON.

export const streamPath = '/stream'
export const streamCapability = 'stream'
export const maximumFrameBytes = 8 * 1024 * 1024
// Client frames are requests, subscriptions and cancels: small.
export const maximumClientFrameBytes = 1024 * 1024
export const streamCloseCodes = Object.freeze({ normal: 1000, goingAway: 1001, protocolViolation: 4400, memberRemoved: 4401 })
export const streamTimings = Object.freeze({ pingMilliseconds: 25_000, pongTimeoutMilliseconds: 60_000, reconnectInitialMilliseconds: 1_000, reconnectMaximumMilliseconds: 30_000,
  smallMessageBytes: 8 * 1024, smallMessageMilliseconds: 50, largeMessageMilliseconds: 200,
  // `library` items (the library change cursor) on a `workspace` subscription.
  libraryMilliseconds: 300 })
export const streamQueueLimits = Object.freeze({ items: 512, bytes: 8 * 1024 * 1024 })
// Agent to agent (session-watch.mjs; Swift `StreamProtocol`, `SessionWakeUp`).
export const maximumWaitSeconds = 50
export const maximumWakeUpsPerRun = 10

export class StreamFrameError extends Error {}

const invalid = message => { throw new StreamFrameError(message) }
const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value)
const text = (value, name) => typeof value === 'string' && value.length > 0 && value.length <= 256 ? value : invalid(`A stream frame needs a ${name}.`)
const integer = (value, name) => Number.isSafeInteger(value) ? value : invalid(`A stream frame's ${name} must be an integer.`)
const flag = (value, name) => typeof value === 'boolean' ? value : invalid(`A stream frame's ${name} is true or false.`)
const strings = (value, name) => Array.isArray(value) && value.every(item => typeof item === 'string') ? value : invalid(`A stream frame's ${name} are strings.`)
const object = (value, name) => isObject(value) ? value : invalid(`A stream frame's ${name} is an object.`)
/** An entity: an object that names itself with the string `keys`. */
const entity = (value, name, keys) => isObject(value) && keys.every(key => typeof value[key] === 'string') ? value : invalid(`A stream frame's ${name} has ${keys.join(', ')}.`)
const entities = (value, name, keys) => Array.isArray(value) ? value.map(item => entity(item, name, keys)) : invalid(`A stream frame lists each ${name}.`)

function streamError(value) {
  if (!isObject(value) || typeof value.code !== 'string' || typeof value.message !== 'string' || typeof value.retryable !== 'boolean') invalid('A stream error has a code, a message and whether it is retryable.')
  return { code: value.code, message: value.message, retryable: value.retryable }
}

// The item kinds and, for each, its `data` (Swift `StreamItem.Payload`): the
// keys the kind defines and what names each entity they hold. The rest of an
// entity is the library protocol's (`LibraryConversation`,
// `PendingInteraction`, `ExecutionJournalEntry`, `LibraryTranscript`,
// `HarnessCapabilities`, `SessionSettings`).
const itemData = new Map(Object.entries({
  conversations: data => ({ conversations: entities(data.conversations, 'conversation', ['id']),
    ...(data.deletedConversationIDs != null ? { deletedConversationIDs: strings(data.deletedConversationIDs, 'deleted conversation IDs') } : {}),
    snapshot: flag(data.snapshot, 'snapshot') }),
  pending: data => ({ interactions: entities(data.interactions, 'interaction', ['id', 'conversationID']) }),
  journal: data => {
    const entry = entity(data.entry, 'journal entry', ['eventID', 'workspaceID', 'conversationID', 'kind'])
    integer(entry.originSequence, 'journal sequence')
    return { entry }
  },
  transcript: data => {
    const transcript = entity(data.transcript, 'transcript', ['conversationID'])
    entities(transcript.messages, 'message', ['id']); entities(transcript.activities, 'activity', ['id'])
    return { transcript, snapshot: flag(data.snapshot, 'snapshot') }
  },
  capabilities: data => ({ capabilities: object(data.capabilities, 'capabilities') }),
  session: data => ({ settings: object(data.settings, 'session settings') }),
  owner: data => ({ online: flag(data.online, 'owner state'), ...(data.error != null ? { error: typeof data.error === 'string' ? data.error : invalid("A stream frame's owner error is text.") } : {}) }),
  library: data => ({ cursor: integer(data.cursor, 'library cursor') }),
  synchronized: () => ({}),
  'server.state': data => ({ scopes: strings(data.scopes, 'scopes'),
    ...(data.conversationIDs != null ? { conversationIDs: strings(data.conversationIDs, 'conversation IDs') } : {}) }),
}))

/** The frame with only the fields its type defines, in a fixed order. Throws `StreamFrameError` for anything else. */
export function normalizeFrame(frame) {
  if (!isObject(frame) || typeof frame.t !== 'string') invalid('A stream frame is a JSON object with a type.')
  switch (frame.t) {
    case 'hello':
      return { t: 'hello', deviceID: text(frame.deviceID, 'device ID'), libraryID: text(frame.libraryID, 'library ID'),
        workspaceID: text(frame.workspaceID, 'workspace ID'), serverTime: integer(frame.serverTime, 'server time'), capabilities: [...strings(frame.capabilities, 'capabilities')],
        maxFrameBytes: integer(frame.maxFrameBytes, 'maximum frame size') }
    case 'req':
      if (frame.params === undefined) invalid('A call has parameters.')
      return { t: 'req', id: text(frame.id, 'request ID'), method: text(frame.method, 'method'), params: frame.params }
    case 'res':
      // A success always carries `result`, `null` included; a failure carries `error`.
      return frame.error != null ? { t: 'res', id: text(frame.id, 'request ID'), error: streamError(frame.error) }
        : { t: 'res', id: text(frame.id, 'request ID'), result: frame.result === undefined ? null : frame.result }
    case 'sub': {
      const given = object(frame.params, 'subscription parameters'), params = {}
      if (given.after != null) params.after = integer(given.after, 'journal cursor')
      if (given.conversationID != null) params.conversationID = typeof given.conversationID === 'string' ? given.conversationID : invalid("A stream frame's conversation ID is text.")
      return { t: 'sub', id: text(frame.id, 'subscription ID'), stream: text(frame.stream, 'stream'), params }
    }
    case 'item': {
      const item = { t: 'item', id: text(frame.id, 'subscription ID') }
      if (frame.seq != null) item.seq = integer(frame.seq, 'sequence')
      const data = itemData.get(frame.kind)
      if (!data) invalid('A stream item has a kind this protocol defines.')
      item.kind = frame.kind
      item.data = data(frame.kind === 'synchronized' ? {} : object(frame.data, 'item data'))
      return item
    }
    case 'end':
      return frame.error != null ? { t: 'end', id: text(frame.id, 'subscription ID'), error: streamError(frame.error) } : { t: 'end', id: text(frame.id, 'subscription ID') }
    case 'cancel':
      return { t: 'cancel', id: text(frame.id, 'ID') }
    default:
      return invalid('A stream frame has a type this protocol defines.')
  }
}

/** Parses one text frame. Throws `StreamFrameError` for invalid JSON and for any frame `normalizeFrame` refuses. */
export function decodeFrame(data, { maximumBytes = maximumFrameBytes } = {}) {
  const source = typeof data === 'string' ? data : Buffer.from(data).toString('utf8')
  if (Buffer.byteLength(source) > maximumBytes) invalid('The stream frame is too large.')
  let value
  try { value = JSON.parse(source) } catch { invalid('A stream frame is JSON.') }
  return normalizeFrame(value)
}

/** One frame as its JSON text. Throws for a frame `normalizeFrame` refuses or one larger than `maximumBytes`. */
export function encodeFrame(frame, { maximumBytes = maximumFrameBytes } = {}) {
  const encoded = JSON.stringify(normalizeFrame(frame))
  if (Buffer.byteLength(encoded) > maximumBytes) invalid('The stream frame is too large.')
  return encoded
}

export const streamFailure = (code, message, retryable = false) => ({ code, message, retryable })

/** A server error (an HTTP-style `statusCode`) as a stream error. */
export function streamErrorFor(error) {
  const status = error?.statusCode, message = typeof error?.message === 'string' && error.message ? error.message.slice(0, 1024) : 'The request failed.'
  if (status === 400 || status === 413 || status === 415) return streamFailure('invalid', message)
  if (status === 401 || status === 403) return streamFailure('unauthorized', message)
  if (status === 404) return streamFailure('not_found', message)
  if (status === 409) return streamFailure('conflict', message)
  return streamFailure('unavailable', (status && status < 500) || status === 503 ? message : 'The server could not complete this request.', status === 503 || status === 504)
}

/** A failure that ended a subscription. A store or server error is not the
 * subscriber's fault and may pass: it subscribes again after its backoff, as
 * the Mac server marks it. A refusal (4xx) stays terminal. */
export function subscriptionErrorFor(error) {
  if (error?.stream) return error.stream
  const failure = streamErrorFor(error), status = error?.statusCode
  return failure.code === 'unavailable' && !(status && status < 500) ? { ...failure, retryable: true } : failure
}
