// Frames of the live stream (docs/architecture/WOVEN_EVERYWHERE.md,
// "Streaming"; Swift `StreamProtocol` in shared/). JSON text frames, one
// message per frame. `decodeFrame` keeps only the fields a frame type defines,
// as the Swift decoder does, so encoding a decoded frame gives the same JSON.

export const streamProtocolVersion = 1
export const supportedStreamProtocols = Object.freeze([1])
export const streamPath = '/v1/stream'
export const streamCapability = 'stream.v1'
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

function streamError(value) {
  if (!isObject(value) || typeof value.code !== 'string' || typeof value.message !== 'string'
    || (value.retryable !== undefined && typeof value.retryable !== 'boolean')) invalid('A stream error needs a code and a message.')
  return { code: value.code, message: value.message, retryable: value.retryable === true }
}

/** The frame with only the fields its type defines, in a fixed order; `{t: 'unknown'}` for a type this build does not know. */
export function normalizeFrame(frame) {
  if (!isObject(frame) || typeof frame.t !== 'string') invalid('A stream frame is a JSON object with a type.')
  switch (frame.t) {
    case 'hello':
      if (!Array.isArray(frame.capabilities) || frame.capabilities.some(item => typeof item !== 'string')) invalid('Hello capabilities are strings.')
      return { t: 'hello', protocol: integer(frame.protocol, 'protocol'), deviceID: text(frame.deviceID, 'device ID'), libraryID: text(frame.libraryID, 'library ID'),
        workspaceID: text(frame.workspaceID, 'workspace ID'), serverTime: integer(frame.serverTime, 'server time'), capabilities: [...frame.capabilities],
        maxFrameBytes: integer(frame.maxFrameBytes, 'maximum frame size') }
    case 'req':
      return { t: 'req', id: text(frame.id, 'request ID'), method: text(frame.method, 'method'), params: frame.params === undefined ? {} : frame.params }
    case 'res':
      // A success always carries `result`, `null` included; a failure carries `error`.
      return frame.error != null ? { t: 'res', id: text(frame.id, 'request ID'), error: streamError(frame.error) }
        : { t: 'res', id: text(frame.id, 'request ID'), result: frame.result === undefined ? null : frame.result }
    case 'sub':
      if (frame.params !== undefined && !isObject(frame.params)) invalid('Subscription parameters are an object.')
      return { t: 'sub', id: text(frame.id, 'subscription ID'), stream: text(frame.stream, 'stream'), params: frame.params ?? {} }
    case 'item': {
      const item = { t: 'item', id: text(frame.id, 'subscription ID') }
      if (frame.seq != null) item.seq = integer(frame.seq, 'sequence')
      item.kind = text(frame.kind, 'item kind')
      item.data = item.kind === 'synchronized' ? {} : frame.data === undefined ? null : frame.data
      return item
    }
    case 'end':
      return frame.error != null ? { t: 'end', id: text(frame.id, 'subscription ID'), error: streamError(frame.error) } : { t: 'end', id: text(frame.id, 'subscription ID') }
    case 'cancel':
      return { t: 'cancel', id: text(frame.id, 'ID') }
    default:
      return { t: 'unknown', type: frame.t }
  }
}

/** Parses one text frame. Throws `StreamFrameError` for invalid JSON, a missing type or a malformed known frame. */
export function decodeFrame(data, { maximumBytes = maximumFrameBytes } = {}) {
  const source = typeof data === 'string' ? data : Buffer.from(data).toString('utf8')
  if (Buffer.byteLength(source) > maximumBytes) invalid('The stream frame is too large.')
  let value
  try { value = JSON.parse(source) } catch { invalid('A stream frame is JSON.') }
  return normalizeFrame(value)
}

/** One frame as its JSON text. Throws for an unknown frame or one larger than `maximumFrameBytes`. */
export function encodeFrame(frame, { maximumBytes = maximumFrameBytes } = {}) {
  const value = normalizeFrame(frame)
  if (value.t === 'unknown') invalid(`An unknown frame type (${value.type}) cannot be sent.`)
  const encoded = JSON.stringify(value)
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
