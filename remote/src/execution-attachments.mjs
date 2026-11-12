import { createHash, randomBytes } from 'node:crypto'
import { constants, existsSync, realpathSync } from 'node:fs'
import { lstat, mkdir, open, readFile, realpath, rename, rm } from 'node:fs/promises'
import { homedir } from 'node:os'
import { basename, extname, isAbsolute, join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')

// The Mac's message attachment limits (`AgentMessageAttachmentLimits`).
export const attachmentLimits = Object.freeze({ count: 8, fileBytes: 25 * 1024 * 1024, totalBytes: 50 * 1024 * 1024 })

// The original name with path separators and control characters replaced, so
// agents see the real extension.
export function attachmentFileName(name) {
  const cleaned = [...String(name ?? '')].map(character => character === '/' || character === '\\' || character.codePointAt(0) < 0x20 ? '_' : character).join('').trim()
  return !cleaned || cleaned === '.' || cleaned === '..' ? 'attachment' : cleaned.slice(0, 255)
}
const mimeType = value => typeof value === 'string' && /^[a-z0-9][a-z0-9!#$&^_.+-]{0,126}\/[a-z0-9][a-z0-9!#$&^_.+-]{0,126}$/i.test(value) ? value.toLowerCase() : 'application/octet-stream'

// Message attachments a member uploads before sending: content-addressed under
// `<workspace>/.wovenmatter/attachments/<sha256>/<name>`, where the Mac's SSH
// staging put them, so a harness finds them in its working tree. A send names
// them by digest and name; each is verified again before it is delivered,
// because an agent may have edited a staged copy.
export function createExecutionAttachments({ directory }) {
  const pathFor = (id, name) => {
    if (typeof id !== 'string' || !/^[0-9a-f]{64}$/.test(id)) throw fail(400, 'An attachment is named by its SHA-256 digest.')
    return join(directory, id, attachmentFileName(name))
  }
  async function matches(path, bytes, id) {
    try {
      const info = await lstat(path)
      return info.isFile() && info.size === bytes && sha256(await readFile(path)) === id
    } catch { return false }
  }
  async function store({ id, name, mimeType: type, bytes }) {
    const path = pathFor(id, name)
    if (!Buffer.isBuffer(bytes) || !bytes.length) throw fail(400, 'An attachment needs its bytes.')
    if (bytes.length > attachmentLimits.fileBytes) throw fail(413, 'The attachment is larger than the 25 MB limit.')
    if (sha256(bytes) !== id) throw fail(400, 'The attachment does not match its digest.')
    if (!await matches(path, bytes.length, id)) {
      await mkdir(join(directory, id), { recursive: true, mode: 0o700 })
      const temporary = join(directory, id, '.part.' + randomBytes(6).toString('hex'))
      try {
        const file = await open(temporary, 'wx', 0o600)
        try { await file.writeFile(bytes); await file.sync() } finally { await file.close() }
        await rename(temporary, path)
      } finally { await rm(temporary, { force: true }) }
    }
    return { id, name: basename(path), mimeType: mimeType(type), byteCount: bytes.length, path }
  }
  // `references` from a send or steer: [{id, name, mimeType}].
  async function resolveAll(references) {
    if (references == null) return []
    if (!Array.isArray(references) || references.length > attachmentLimits.count) throw fail(400, `Attach up to ${attachmentLimits.count} files to one message.`)
    const files = []
    let total = 0
    for (const reference of references) {
      if (!reference || typeof reference !== 'object') throw fail(400, 'Invalid attachment.')
      const path = pathFor(reference.id, reference.name)
      let info
      try { info = await lstat(path) } catch { throw fail(409, `${attachmentFileName(reference.name)} is not uploaded to this workspace. Upload it again.`) }
      if (!info.isFile()) throw fail(409, 'The staged attachment is not a regular file.')
      if (info.size > attachmentLimits.fileBytes) throw fail(413, 'The attachment is larger than the 25 MB limit.')
      total += info.size
      if (total > attachmentLimits.totalBytes) throw fail(413, 'The attachments exceed the 50 MB message limit.')
      const bytes = await readFile(path)
      if (sha256(bytes) !== reference.id) throw fail(409, `${attachmentFileName(reference.name)} changed on the workspace. Upload it again.`)
      files.push({ id: reference.id, name: basename(path), mimeType: mimeType(reference.mimeType), byteCount: bytes.length, path, bytes })
    }
    return files
  }
  return { directory, store, resolve: resolveAll, pathFor }
}

// The ACP prompt for a message and its files, as the Mac builds it
// (`LocalACPClient.promptBlocks`): images inline, UTF-8 text files as
// resources, other files as links that are also listed in the text, because
// some adapters reduce a link to an `@name` mention.
//
// A durable channel takes one ACP message of at most 8 MiB and journals it,
// so inline content shares `inlineBytes` (5 MiB, about 6.7 MiB as base64);
// files past it are linked instead, which the harness reads from disk.
export function promptBlocks(text, files = [], { inlineBytes = 5 * 1024 * 1024 } = {}) {
  const blocks = [], linked = []
  let budget = inlineBytes
  for (const file of files) {
    const uri = pathToFileURL(file.path).href
    const fits = file.byteCount <= budget
    if (fits && file.mimeType.startsWith('image/')) { budget -= file.byteCount; blocks.push({ type: 'image', mimeType: file.mimeType, data: file.bytes.toString('base64') }) }
    else if (fits && file.mimeType.startsWith('text/') && isUTF8(file.bytes)) { budget -= file.byteCount; blocks.push({ type: 'resource', resource: { uri, mimeType: file.mimeType, text: file.bytes.toString('utf8') } }) }
    else { linked.push(file.path); blocks.push({ type: 'resource_link', uri, name: file.name, mimeType: file.mimeType, size: file.byteCount }) }
  }
  let outbound = text ?? ''
  if (linked.length) outbound += (outbound ? '\n\n' : '') + 'Attached files available to this session:\n' + linked.map(path => '- ' + path).join('\n')
  return [...(outbound ? [{ type: 'text', text: outbound }] : []), ...blocks]
}
// For an input that carries text only (Grok's interject): every file is named.
export function textWithFiles(text, files = []) {
  if (!files.length) return text
  return (text ? text + '\n\n' : '') + 'Attached files available to this session:\n' + files.map(file => '- ' + file.path).join('\n')
}
function isUTF8(bytes) { try { new TextDecoder('utf-8', { fatal: true }).decode(bytes); return true } catch { return false } }

const knownTypes = { '.txt': 'text/plain', '.md': 'text/markdown', '.csv': 'text/csv', '.json': 'application/json', '.html': 'text/html', '.pdf': 'application/pdf',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.zip': 'application/zip' }

// One explicitly shared regular file, for Library retention of a file an
// agent wrote, read by a Mac through `POST v1/execution/library-file`. The
// file must be inside `root`, /tmp or /mnt/data, is opened without following
// its final symlink, and must not change while it is read.
export async function readWorkspaceFile({ path: requestedPath, root, maximumBytes = attachmentLimits.fileBytes }) {
  if (typeof requestedPath !== 'string' || !requestedPath || requestedPath.includes('\0') || Buffer.byteLength(requestedPath) > 8192) throw fail(400, 'The file path is invalid.')
  let path = requestedPath.startsWith('file://') ? decodeURIComponent(new URL(requestedPath).pathname) : requestedPath
  if (path.startsWith('~/')) path = join(homedir(), path.slice(2))
  if (!isAbsolute(path)) path = resolve(root, path)
  path = resolve(path)
  const roots = [root, '/tmp', '/mnt/data'].filter(value => value && existsSync(value)).map(value => realpathSync(value))
  const inside = candidate => roots.some(value => candidate === value || candidate.startsWith(value.endsWith('/') ? value : value + '/'))
  let actual
  try { actual = await realpath(path) } catch { throw fail(404, 'The shared file is not on this workspace.') }
  if (!inside(actual) || (await lstat(path)).isSymbolicLink()) throw fail(403, 'The shared file is outside the workspace or is a symbolic link.')
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK)
  try {
    const before = await file.stat()
    if (existsSync('/proc/self/fd')) {
      const opened = realpathSync('/proc/self/fd/' + file.fd)
      if (!inside(opened)) throw fail(403, 'The shared file is outside the workspace.')
    }
    if (!before.isFile()) throw fail(400, 'Not a regular workspace file.')
    if (before.size > maximumBytes) throw fail(413, 'The file exceeds the 25 MB retention limit.')
    const bytes = Buffer.alloc(before.size + 1)
    let count = 0
    for (;;) {
      const { bytesRead } = await file.read(bytes, count, bytes.length - count, null)
      if (!bytesRead) break
      count += bytesRead
      if (count >= bytes.length) break
    }
    const after = await file.stat()
    if (count !== before.size || after.size !== before.size || after.mtimeMs !== before.mtimeMs) throw fail(409, 'The file changed while it was being saved. Try again.')
    const data = bytes.subarray(0, count)
    return { name: basename(path), mimeType: knownTypes[extname(path).toLowerCase()] ?? 'application/octet-stream', byteCount: count, sha256: sha256(data), data }
  } finally { await file.close() }
}
