import { open, mkdir, rename, unlink, mkdtemp, rm } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const MAX_INLINE_RECORD = 524288;
const STREAM_BYTES = 65536;
const CHUNK_BYTES = 262144;
const MANIFEST_PARTS = 1024;
const METADATA_KEYS = new Set(['id', 'revision', 'runID', 'kind', 'contentMode']);
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

// Group identities precede content in the public projection. Read only its
// bounded scalar prefix: child message/history projections may themselves be
// large, and copying or decoding them would defeat disk chunking.
function nativeGrouping(projectionJSON) {
  if (typeof projectionJSON !== 'string') return {};
  const prefix = projectionJSON.slice(0, 4096), beginning = /^\s*\{/.exec(prefix);
  if (!beginning) return {};
  const fields = /\s*"(nativeConversationID|parentNativeConversationID|childID)"\s*:\s*("(?:\\.|[^"\\])*"|[0-9]+)\s*(,|\})/gy;
  fields.lastIndex = beginning[0].length;
  const result = {};
  for (let count = 0; count < 3; count++) {
    const field = fields.exec(prefix);
    if (!field) break;
    let value;
    try { value = JSON.parse(field[2]); } catch { break; }
    if ((typeof value === 'string' && value.length > 0 && value.length <= 256)
      || (typeof value === 'number' && Number.isSafeInteger(value) && value > 0)) result[field[1]] = value;
    if (field[3] === '}') break;
  }
  return result;
}

const slash = { slash: true };
const literal = text => [...text].map(char => ({ char }));
const hex = () => Array.from({ length: 32 }, () => ({ hex: true }));
const endpointPatterns = [
  [slash, ...literal('private'), slash, ...literal('tmp'), slash, ...literal('wmtools-'), ...hex(), slash, ...hex(), ...literal('.sock')],
  ...['wovenmatter', 'rpc.sock'].map(tail => [slash, ...literal('home'), slash, ...literal('.wmt'), slash, ...hex(), slash, ...hex(), slash, ...literal(tail)]),
];

// The endpoint matcher is a finite-state stream, including arbitrarily nested
// JSON slash escaping. An unusually long candidate spills to a private file,
// rather than requiring an unbounded overlap buffer or leaking split endpoints.
class EndpointRedactor {
  constructor(directory, emit) { this.directory = directory; this.emit = emit; this.buffer = Buffer.alloc(STREAM_BYTES); this.length = 0; this.matches = undefined; this.redacted = false; }
  async put(byte) {
    if (this.length === this.buffer.length) {
      if (!this.spool) { this.spoolPath = join(this.directory, '.endpoint-' + randomUUID()); this.spool = await open(this.spoolPath, 'wx', 0o600); }
      await writeAll(this.spool, this.buffer); this.length = 0;
    }
    this.buffer[this.length++] = byte;
  }
  async flush(discard = false) {
    if (this.spool) {
      await this.spool.close(); this.spool = undefined;
      if (!discard) for await (const bytes of createReadStream(this.spoolPath, { highWaterMark: STREAM_BYTES })) await this.emit(bytes);
      await unlink(this.spoolPath); this.spoolPath = undefined;
    }
    if (!discard && this.length) await this.emit(this.buffer.subarray(0, this.length));
    this.length = 0; this.matches = undefined;
  }
  async feed(bytes) {
    let plain = 0;
    for (let index = 0; index < bytes.length; index++) {
      const byte = bytes[index];
      if (!this.matches) {
        if (byte !== 47 && byte !== 92) continue;
        if (index > plain) await this.emit(bytes.subarray(plain, index));
        this.matches = endpointPatterns.map(pattern => ({ pattern, position: 0 }));
      }
      await this.put(byte);
      this.matches = this.matches.filter(match => {
        const step = match.pattern[match.position];
        if (step.slash) { if (byte === 92) return true; if (byte !== 47) return false; }
        else if (step.hex) { if (!((byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102))) return false; }
        else if (byte !== step.char.charCodeAt(0)) return false;
        match.position++; return true;
      });
      if (this.matches.some(match => match.position === match.pattern.length)) {
        await this.flush(true); await this.emit(Buffer.from('[Woven Matter session tool endpoint]')); this.redacted = true;
      } else if (!this.matches.length) {
        // A mismatching slash can itself start the next endpoint.
        const restart = byte === 47 || byte === 92;
        if (restart) this.length--;
        await this.flush();
        if (restart) { this.matches = endpointPatterns.map(pattern => ({ pattern, position: byte === 47 ? 1 : 0 })); await this.put(byte); }
      }
      plain = index + 1;
    }
    if (!this.matches && plain < bytes.length) await this.emit(bytes.subarray(plain));
  }
  async finish() { await this.flush(); }
  async close() { if (this.spool) await this.spool.close(); if (this.spoolPath) await unlink(this.spoolPath).catch(() => {}); }
}

// Encoded copies of known transport records must be sanitized before base64
// framing. Reuse the same byte matcher as large native archive records; never
// decode or rewrite arbitrary user-provided base64 values.
export async function sanitizeNativeTransportBytes(value) {
  const source = Buffer.from(value), directory = await mkdtemp(join(tmpdir(), 'woven-native-transport-')), chunks = [];
  const redactor = new EndpointRedactor(directory, async bytes => { chunks.push(Buffer.from(bytes)); });
  try {
    await redactor.feed(source); await redactor.finish();
    const bytes = Buffer.concat(chunks);
    return { bytes, sourceSHA256: digest(source), sourceBytes: source.length, sha256: digest(bytes), totalBytes: bytes.length, byteFidelity: redactor.redacted ? 'tool-endpoint-redacted' : 'exact-native-bytes' };
  } finally { await redactor.close(); await rm(directory, { recursive: true, force: true }); }
}

async function writeAll(file, bytes) {
  let written = 0;
  while (written < bytes.length) {
    const { bytesWritten } = await file.write(bytes, written, bytes.length - written);
    if (!bytesWritten) throw new Error('The native archive could not complete its append.');
    written += bytesWritten;
  }
}

// A normalized search projection reads strings, not JSON syntax. The outer
// archive's known payload/projectionJSON fields contain serialized native JSON,
// so only those fields get a second decoding layer. User text containing literal
// backslashes or JSON is retained at its actual schema depth. Both layers carry
// escapes, Unicode and UTF-8 across raw chunk boundaries.
class JSONSearchProjector {
  constructor({ nestedPayloads = true, output } = {}) {
    this.state = 'outside'; this.depth = 0; this.lastSymbol = ''; this.hasString = false;
    this.nestedPayloads = nestedPayloads; this.output = output; this.decoder = new TextDecoder('utf-8', { fatal: true });
  }
  emit(char) {
    if (this.captured !== undefined) { if (this.captured.length + char.length <= 8192) this.captured += char; else this.captured = undefined; }
    if (this.nestedEligible && !this.nestedDecision) {
      if (/\s/.test(char)) return;
      this.nestedDecision = true;
      if (char === '{' || char === '[') this.nested = new JSONSearchProjector({ nestedPayloads: false, output: this.output });
    }
    if (this.nested) this.nested.consumeText(char); else this.output(char);
  }
  scalar(value, low = false) {
    if (low && this.high !== undefined) {
      if (value >= 0xdc00 && value <= 0xdfff) { this.emit(String.fromCodePoint(0x10000 + ((this.high - 0xd800) << 10) + value - 0xdc00)); this.high = undefined; this.state = 'string'; return; }
      this.emit('\\u' + this.high.toString(16).padStart(4, '0')); this.high = undefined;
    }
    if (value >= 0xd800 && value <= 0xdbff) { this.high = value; this.state = 'highSlash'; }
    else { this.emit(value >= 0xdc00 && value <= 0xdfff ? '\\u' + value.toString(16).padStart(4, '0') : String.fromCodePoint(value)); this.state = 'string'; }
  }
  consumeChar(char) {
    if (this.state === 'highSlash') {
      if (char === '\\') { this.state = 'highU'; return; }
      this.emit('\\u' + this.high.toString(16).padStart(4, '0')); this.high = undefined; this.state = 'string';
    } else if (this.state === 'highU') {
      if (char === 'u') { this.state = 'unicodeLow'; this.hex = ''; return; }
      this.emit('\\u' + this.high.toString(16).padStart(4, '0')); this.high = undefined; this.state = 'escape';
    }
    if (this.state === 'unicode' || this.state === 'unicodeLow') {
      if (!/[0-9a-f]/i.test(char)) throw new SyntaxError('Invalid Unicode escape in the native search projection.');
      this.hex += char;
      if (this.hex.length === 4) this.scalar(parseInt(this.hex, 16), this.state === 'unicodeLow');
      return;
    }
    if (this.state === 'escape') {
      if (char === 'u') { this.hex = ''; this.state = 'unicode'; return; }
      const decoded = { '"': '"', '\\': '\\', '/': '/', b: '\b', f: '\f', n: '\n', r: '\r', t: '\t' }[char];
      if (decoded === undefined) throw new SyntaxError('Invalid escape in the native search projection.');
      this.emit(decoded); this.state = 'string'; return;
    }
    if (this.state === 'string') {
      if (char === '"') {
        this.nested?.finishState(); this.lastString = this.captured;
        this.nested = undefined; this.nestedEligible = false; this.state = 'outside'; this.lastSymbol = '"';
      } else if (char === '\\') this.state = 'escape';
      else this.emit(char);
      return;
    }
    if (char === '"') {
      if (this.hasString) this.output('\n'); this.hasString = true;
      this.state = 'string'; this.captured = ''; this.nestedDecision = false;
      this.nestedEligible = this.nestedPayloads && this.depth === 1 && this.lastSymbol === ':' && ['payload', 'projectionJSON'].includes(this.key);
    } else if (char === '{' || char === '[') { this.depth++; this.lastSymbol = char; }
    else if (char === '}' || char === ']') { this.depth--; this.lastSymbol = char; }
    else if (char === ':') { this.key = this.lastString; this.lastSymbol = char; }
    else if (!/\s/.test(char)) this.lastSymbol = char;
  }
  consumeText(text) {
    for (let index = 0; index < text.length;) {
      if (this.state === 'string' && !(this.nestedEligible && !this.nestedDecision)) {
        const special = text.slice(index).search(/["\\]/);
        const until = special < 0 ? text.length : index + special;
        if (until > index) { this.emit(text.slice(index, until)); index = until; continue; }
      }
      this.consumeChar(text[index++]);
    }
  }
  consume(bytes) {
    const result = []; this.output = char => result.push(char);
    // A nested decoder shares the current bounded output sink between calls.
    if (this.nested) this.nested.output = this.output;
    this.consumeText(this.decoder.decode(bytes, { stream: true }));
    return Buffer.from(result.join(''));
  }
  finishState() { if (this.state !== 'outside') throw new SyntaxError('Incomplete native JSON search projection.'); }
  finish() { for (const char of this.decoder.decode()) this.consumeChar(char); this.finishState(); }
}

async function prepareOversized(path, entry) {
  const directory = path + '.chunks'; await mkdir(directory, { recursive: true, mode: 0o700 });
  const temporary = join(directory, '.record-' + randomUUID()), output = await open(temporary, 'wx', 0o600);
  const projectionTemporary = temporary + '.text', projectionOutput = await open(projectionTemporary, 'wx', 0o600), projector = new JSONSearchProjector();
  const wholeHash = createHash('sha256'), parts = [];
  let partHash = createHash('sha256'), byteCount = 0, partLength = 0, projectionBytes = 0, partProjectionStart = 0;
  const emit = async bytes => {
    await writeAll(output, bytes); wholeHash.update(bytes);
    let position = 0;
    while (position < bytes.length) {
      const size = Math.min(bytes.length - position, CHUNK_BYTES - partLength);
      const piece = bytes.subarray(position, position + size); partHash.update(piece);
      const projected = projector.consume(piece); await writeAll(projectionOutput, projected); projectionBytes += projected.length;
      byteCount += size; partLength += size; position += size;
      if (partLength === CHUNK_BYTES) { parts.push({ byteOffset: byteCount - partLength, byteCount: partLength, sha256: partHash.digest('hex'), projectionOffset: partProjectionStart, projectionLength: projectionBytes - partProjectionStart });
        partHash = createHash('sha256'); partLength = 0; partProjectionStart = projectionBytes; }
    }
  };
  const redactor = new EndpointRedactor(directory, emit);
  try {
    for await (const bytes of createReadStream(path, { start: entry.offset, end: entry.offset + entry.length - 1, highWaterMark: STREAM_BYTES })) await redactor.feed(bytes);
    await redactor.finish(); projector.finish();
    if (partLength) parts.push({ byteOffset: byteCount - partLength, byteCount: partLength, sha256: partHash.digest('hex'), projectionOffset: partProjectionStart, projectionLength: projectionBytes - partProjectionStart });
    await output.sync(); await output.close(); await projectionOutput.sync(); await projectionOutput.close();
    const sha256 = wholeHash.digest('hex'), safePath = join(directory, sha256 + '.json');
    await rename(temporary, safePath); const projectionPath = safePath + '.text'; await rename(projectionTemporary, projectionPath);
    return { ...entry, safePath, projectionPath, archivedSHA256: sha256, archivedLength: byteCount, redacted: redactor.redacted, parts };
  } catch (error) { await output.close().catch(() => {}); await projectionOutput.close().catch(() => {}); await redactor.close();
    await unlink(temporary).catch(() => {}); await unlink(projectionTemporary).catch(() => {}); throw error; }
}

async function readAt(file, offset, length) {
  const content = Buffer.alloc(length); let read = 0;
  while (read < length) { const { bytesRead } = await file.read(content, read, length - read, offset + read); if (!bytesRead) throw new Error('Native archive ended before its indexed record.'); read += bytesRead; }
  return content;
}

function boundedUTF8(bytes) {
  for (let leading = 0; leading <= Math.min(3, bytes.length); leading++) {
    try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(leading)); } catch {}
  }
  throw new Error('A native search projection ended inside an invalid UTF-8 scalar.');
}

function chunkID(entry, part) { return `native-record:${entry.sha256}:native-file.chunk:${part.sha256}`; }
function originalMetadata(entry, ordinal) {
  return { ...entry.nativeGrouping, id: entry.id, ...(entry.revision !== undefined ? { revision: entry.revision } : {}), ...(entry.runID ? { runID: entry.runID } : {}), kind: entry.kind ?? 'native.raw.record', ...(entry.syntheticID ? { ordinal } : {}) };
}
function manifestRecord(entry, ordinal, page) {
  const manifestPages = Math.ceil(entry.parts.length / MANIFEST_PARTS);
  return {
    id: `native-file.manifest:${entry.sha256}:${page}`, ...(entry.runID ? { runID: entry.runID } : {}), kind: 'native-file.manifest', contentMode: 'event', completeness: 'native-record-chunk-manifest',
    payload: JSON.stringify({ format: 'woven-native-file-manifest/v2', originalRecord: originalMetadata(entry, ordinal), sourceSHA256: entry.sha256, sourceTotalBytes: entry.length,
      sha256: entry.archivedSHA256, byteFidelity: entry.redacted ? 'tool-endpoint-redacted' : 'exact-native-bytes', totalBytes: entry.archivedLength,
      manifestPage: page, manifestPages, chunkBytes: CHUNK_BYTES,
      parts: entry.parts.slice(page * MANIFEST_PARTS, (page + 1) * MANIFEST_PARTS).map(part => ({ byteOffset: part.byteOffset, byteCount: part.byteCount, chunkID: chunkID(entry, part) })) }),
    projectionJSON: JSON.stringify({ ...entry.nativeGrouping, originalRecord: originalMetadata(entry, ordinal) }),
  };
}

function cursorPosition(after, index) {
  if (Number.isSafeInteger(after) && after >= 0 && after <= index.length) return { record: after, byteOffset: 0 };
  if (after && typeof after === 'object' && Number.isSafeInteger(after.record) && after.record >= 0 && after.record < index.length && Number.isSafeInteger(after.byteOffset) && after.byteOffset >= 0) {
    const entry = index[after.record];
    if (entry.length > MAX_INLINE_RECORD) {
      const manifests = Math.ceil(entry.parts.length / MANIFEST_PARTS);
      if ((after.byteOffset < entry.archivedLength && after.byteOffset % CHUNK_BYTES === 0) || (after.byteOffset >= entry.archivedLength && after.byteOffset < entry.archivedLength + manifests)) return { record: after.record, byteOffset: after.byteOffset };
    }
  }
  throw new Error('Invalid native archive continuation cursor.');
}

// A cursor is a record ordinal, or {record, byteOffset} while copying an
// oversized record. Offsets below totalBytes select raw chunks; totalBytes +
// manifestPage selects its bounded manifest pages. No source line is reassembled
// in either the JS transport or the app merely to ingest its archive copy.
async function createIndexedJournal(path, chunkOversized = false) {
  const file = await open(path, 'wx', 0o600); await file.close();
  const index = [], identities = new Set();
  return {
    index, identities,
    async append(records) {
      const file = await open(path, 'a', 0o600), added = [];
      let position = (await file.stat()).size;
      try {
        for (const record of records) {
          const hash = createHash('sha256'); let length = 0;
          for (const piece of jsonPieces(record)) { const bytes = Buffer.from(piece); await writeAll(file, bytes); hash.update(bytes); length += bytes.length; }
          await writeAll(file, Buffer.from('\n'));
          let entry = { offset: position, length, sha256: hash.digest('hex'), syntheticID: record.id === undefined, nativeGrouping: nativeGrouping(record.projectionJSON), ...Object.fromEntries([...METADATA_KEYS].filter(key => record[key] !== undefined).map(key => [key, record[key]])) };
          if (chunkOversized && length > MAX_INLINE_RECORD) entry = await prepareOversized(path, entry);
          added.push(entry); position += length + 1;
        }
        await file.sync(); index.push(...added); for (const entry of added) identities.add(`${entry.id}:${entry.revision ?? ''}`);
      } finally { await file.close(); }
    },
  };
}

export async function openNativeArchive(path) {
  const store = await createIndexedJournal(path, true), { index } = store;
  return {
    ...store,
    async page(after, count, budget = 1048576) {
      if (!Number.isSafeInteger(count) || count < 1 || !Number.isSafeInteger(budget) || budget < 1) throw new Error('Invalid native archive page budget.');
      let { record: ordinal, byteOffset } = cursorPosition(after, index);
      const records = [], file = await open(path, 'r'); let bytes = 0;
      try {
        while (ordinal < index.length && records.length < count) {
          const entry = index[ordinal]; let record, nextOffset = 0, complete = true;
          if (entry.length <= MAX_INLINE_RECORD) {
            if (records.length && bytes + entry.length > budget) break;
            record = JSON.parse((await readAt(file, entry.offset, entry.length)).toString('utf8'));
          } else if (byteOffset < entry.archivedLength) {
            const part = entry.parts[byteOffset / CHUNK_BYTES];
            const estimate = Math.ceil(part.byteCount / 3) * 4 + part.byteCount + 4096;
            if (records.length && bytes + estimate > budget) break;
            const source = await open(entry.safePath, 'r'); let content, projection;
            try { content = await readAt(source, part.byteOffset, part.byteCount); } finally { await source.close(); }
            const projected = await open(entry.projectionPath, 'r');
            try {
              const start = Math.max(0, part.projectionOffset - 512), length = part.projectionOffset + part.projectionLength - start;
              projection = boundedUTF8(await readAt(projected, start, length));
            } finally { await projected.close(); }
            if (digest(content) !== part.sha256) throw new Error('An archived native chunk failed its content checksum.');
            record = { id: chunkID(entry, part), ...(entry.runID ? { runID: entry.runID } : {}), kind: 'native-file.chunk', contentMode: 'event', completeness: 'native-record-chunk',
              payload: JSON.stringify({ format: 'woven-native-file-chunk/v1', encoding: 'base64', sha256: part.sha256, dataBase64: content.toString('base64') }),
              text: projection, projectionJSON: JSON.stringify({ ...entry.nativeGrouping, originalRecord: originalMetadata(entry, ordinal), byteOffset: part.byteOffset, byteCount: part.byteCount }) };
            nextOffset = byteOffset + part.byteCount; complete = false;
          } else {
            const page = byteOffset - entry.archivedLength; record = manifestRecord(entry, ordinal, page);
            nextOffset = byteOffset + 1; complete = page + 1 >= Math.ceil(entry.parts.length / MANIFEST_PARTS);
          }
          const size = Buffer.byteLength(JSON.stringify(record));
          if (records.length && bytes + size > budget) break;
          if (entry.length > MAX_INLINE_RECORD && size > budget) throw new Error('The native archive page budget cannot fit one bounded chunk or manifest.');
          records.push(record); bytes += size;
          if (complete) { ordinal++; byteOffset = 0; } else byteOffset = nextOffset;
        }
      } finally { await file.close(); }
      return { records, nextAfter: byteOffset ? { record: ordinal, byteOffset } : ordinal, hasMore: ordinal < index.length };
    },
  };
}

// String chunks retain JSON.stringify's byte encoding, including surrogate
// pairs, without making a second whole-record string/buffer for large results.
function* jsonPieces(value, ancestors = new Set()) {
  if (typeof value === 'string') {
    yield '"';
    for (let from = 0; from < value.length;) {
      let until = Math.min(value.length, from + STREAM_BYTES);
      if (until < value.length && value.charCodeAt(until - 1) >= 0xd800 && value.charCodeAt(until - 1) <= 0xdbff && value.charCodeAt(until) >= 0xdc00 && value.charCodeAt(until) <= 0xdfff) until--;
      yield JSON.stringify(value.slice(from, until)).slice(1, -1); from = until;
    }
    yield '"'; return;
  }
  if (value === null || typeof value !== 'object') { yield JSON.stringify(value) ?? 'null'; return; }
  if (typeof value.toJSON === 'function') { yield* jsonPieces(value.toJSON(), ancestors); return; }
  if (ancestors.has(value)) throw new TypeError('A native archive record contains a circular value.');
  ancestors.add(value);
  if (Array.isArray(value)) { yield '['; for (let index = 0; index < value.length; index++) { if (index) yield ','; yield* jsonPieces(value[index], ancestors); } yield ']'; }
  else { yield '{'; let first = true; for (const key of Object.keys(value)) { const item = value[key]; if (item === undefined || typeof item === 'function' || typeof item === 'symbol') continue; if (!first) yield ','; first = false; yield JSON.stringify(key); yield ':'; yield* jsonPieces(item, ancestors); } yield '}'; }
  ancestors.delete(value);
}

// A process owns a fresh append-only transport spool. Polls seek directly to
// its in-memory offsets; prior spools remain untouched and are not replayed.
export async function openNativeJournal(path) {
  const store = await createIndexedJournal(path), { index } = store;
  return {
    ...store,
    async page(after = 0, count = 200, budget = 1048576) {
      if (!Number.isSafeInteger(after) || after < 0 || after > index.length || !Number.isSafeInteger(count) || count < 1 || !Number.isSafeInteger(budget) || budget < 1) throw new Error('Invalid native journal page cursor or budget.');
      const file = await open(path, 'r'), updates = []; let bytes = 0, cursor = after;
      try {
        while (cursor < index.length && updates.length < count) {
          const entry = index[cursor];
          if (updates.length && bytes + entry.length > budget) break;
          updates.push(JSON.parse((await readAt(file, entry.offset, entry.length)).toString('utf8'))); bytes += entry.length; cursor++;
        }
      } finally { await file.close(); }
      return { updates, cursor, hasMore: cursor < index.length, totalCount: index.length };
    },
  };
}

// Presentation stays small while the canonical native copy retains every field.
// Text deltas split losslessly; tool/activity bodies are previews. An oversized
// inline image/audio payload is omitted rather than producing invalid base64.
export function* nativePresentationUpdates(update) {
  if (update?.sessionUpdate === 'woven_subagents') { yield subagentPresentation(update); return; }
  const text = ['agent_message_chunk', 'agent_thought_chunk', 'user_message_chunk'].includes(update?.sessionUpdate)
    && update.content?.type === 'text' && typeof update.content.text === 'string' ? update.content.text : undefined;
  const preview = nativePreview(text === undefined ? update : { ...update, content: { ...update.content, text: undefined } });
  if (text === undefined || !text.length) { yield text === undefined ? preview : { ...preview, content: { ...preview.content, text: '' } }; return; }
  for (let start = 0; start < text.length;) {
    let end = Math.min(text.length, start + 32768);
    if (end < text.length && text.charCodeAt(end - 1) >= 0xd800 && text.charCodeAt(end - 1) <= 0xdbff) end--;
    yield { ...preview, content: { ...preview.content, text: text.slice(start, end) } }; start = end;
  }
}

// A single child's history must never consume the identities or route/state
// fields of later children. This public projection uses explicit scalar fields
// and a separate, fair content budget; native records retain the full content.
function subagentPresentation(update) {
  const scalar = (value, limit) => {
    if (typeof value === 'string') {
      let end = Math.min(value.length, limit);
      if (end < value.length && value.charCodeAt(end - 1) >= 0xd800 && value.charCodeAt(end - 1) <= 0xdbff && value.charCodeAt(end) >= 0xdc00 && value.charCodeAt(end) <= 0xdfff) end--;
      return value.slice(0, end).replace(/[\u0000-\u001f\u007f]/g, ' ');
    }
    return value === null || typeof value === 'boolean' || typeof value === 'number' && Number.isFinite(value) ? value : undefined;
  };
  const fields = (value, limits) => {
    const result = {};
    for (const [key, limit] of Object.entries(limits)) {
      const item = scalar(value?.[key], limit);
      if (item !== undefined) result[key] = item;
    }
    return result;
  };
  const identities = { id: 128, name: 512, provider: 512, modelID: 512, modelId: 512,
    accountID: 128, accountLabel: 512, connectionID: 512, connectionLabel: 512,
    accessKind: 128, billing: 128, thinking: 128, state: 128,
    sourceID: 512, archiveSourceID: 512, nativeStoreID: 128, nativeSessionID: 128,
    parentNativeSessionID: 128, nativeConversationID: 128, parentNativeConversationID: 128, childID: 128 };
  const rowIdentities = { id: 128, kind: 128, title: 128, status: 128 };
  const result = fields(update, { sessionUpdate: 128, concurrency: 128, activeCount: 128, totalCount: 128,
    sourceID: 512, archiveSourceID: 512, nativeStoreID: 128, nativeSessionID: 128,
    parentNativeSessionID: 128, nativeConversationID: 128, parentNativeConversationID: 128 });
  const children = Array.isArray(update.subagents) ? update.subagents.slice(0, 24) : [];
  const childBudget = Math.min(2048, Math.floor(16384 / Math.max(1, children.length)));
  result.subagents = children.map(child => {
    const projected = fields(child, identities);
    const textFields = ['task', 'result', 'detail'].filter(key => typeof child?.[key] === 'string' && child[key].length);
    const categories = [textFields.length ? textFields : undefined];
    for (const key of ['activity', 'history']) {
      const rows = Array.isArray(child?.[key]) ? child[key].slice(-24) : [];
      if (Array.isArray(child?.[key])) projected[key] = rows.map(row => fields(row, rowIdentities));
      categories.push(rows.some(row => typeof row?.content === 'string' && row.content.length) ? rows : undefined);
    }
    const categoryBudget = Math.floor(childBudget / Math.max(1, categories.filter(Boolean).length));
    const content = (value, limit) => {
      if (typeof value !== 'string') return undefined;
      let end = Math.min(value.length, limit);
      if (end < value.length && value.charCodeAt(end - 1) >= 0xd800 && value.charCodeAt(end - 1) <= 0xdbff && value.charCodeAt(end) >= 0xdc00 && value.charCodeAt(end) <= 0xdfff) end--;
      return value.slice(0, end);
    };
    for (const key of textFields) projected[key] = content(child[key], Math.floor(categoryBudget / textFields.length));
    for (const [index, key] of ['activity', 'history'].entries()) {
      const rows = categories[index + 1];
      if (!rows) continue;
      const count = rows.filter(row => typeof row?.content === 'string' && row.content.length).length;
      rows.forEach((row, ordinal) => {
        const preview = content(row?.content, Math.floor(categoryBudget / count));
        if (preview !== undefined) projected[key][ordinal].content = preview;
      });
    }
    return projected;
  });
  return result;
}

function nativePreview(value, budget = { characters: 32768, nodes: 2048 }, depth = 0) {
  if (budget.nodes <= 0 || depth > 12) return undefined;
  budget.nodes--;
  if (typeof value === 'string') {
    let end = Math.min(value.length, budget.characters);
    if (end < value.length && value.charCodeAt(end - 1) >= 0xd800 && value.charCodeAt(end - 1) <= 0xdbff && value.charCodeAt(end) >= 0xdc00 && value.charCodeAt(end) <= 0xdfff) end--;
    const text = value.slice(0, end); budget.characters -= text.length; return text;
  }
  if (!value || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.slice(0, 128).map(item => nativePreview(item, budget, depth + 1)).filter(item => item !== undefined);
  const identityKeys = ['sessionUpdate', 'toolCallId', 'id', 'status', 'type', 'mimeType', 'uri', 'url', 'path'];
  const keys = [...identityKeys.filter(key => Object.hasOwn(value, key)), ...Object.keys(value).filter(key => !identityKeys.includes(key))];
  const result = {};
  for (const key of keys.slice(0, 128)) {
    if (key.length > budget.characters) break;
    budget.characters -= key.length;
    if (key === 'dataBase64' || key === 'blob' || key === 'data' && ['image', 'audio', 'blob'].includes(value.type)) {
      if (typeof value[key] !== 'string' || value[key].length > Math.min(32768, budget.characters)) continue;
    }
    const child = nativePreview(value[key], budget, depth + 1);
    if (child !== undefined) result[key] = child;
  }
  return result;
}
