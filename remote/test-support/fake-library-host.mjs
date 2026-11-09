// A stand-in for `wovenmatter-library` in tests: the same command line, files,
// ready line and local API shapes (docs: "Library host"), with an in-memory
// notes store. FAKE_LIBRARY_MEMBERS names a JSON file served as /v1/members;
// FAKE_LIBRARY_LOG appends one JSON line per local API request.
import { randomUUID } from 'node:crypto'
import { appendFileSync, chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { join } from 'node:path'

const args = process.argv.slice(2), option = name => { const index = args.indexOf(name); return index < 0 ? null : args[index + 1] }
const dataRoot = option('--data-root')
if (!dataRoot) { process.stderr.write('--data-root is required\n'); process.exit(64) }
for (const directory of [dataRoot, join(dataRoot, 'library'), join(dataRoot, 'secrets'), join(dataRoot, 'run')]) mkdirSync(directory, { recursive: true, mode: 0o700 })
if (args.includes('--migrate-only')) { process.stdout.write('{"event":"migrated"}\n'); process.exit(0) }
if (process.env.FAKE_LIBRARY_EXIT) process.exit(Number(process.env.FAKE_LIBRARY_EXIT))
const socketPath = option('--socket') ?? join(dataRoot, 'run/library.sock'), tokenFile = option('--token-file') ?? join(dataRoot, 'run/library-api.token')
const token = readFileSync(tokenFile, 'utf8').trim()
const deviceFile = join(dataRoot, 'library/dashboard-device-id')
if (!existsSync(deviceFile)) writeFileSync(deviceFile, randomUUID() + '\n', { mode: 0o600 })
const deviceID = readFileSync(deviceFile, 'utf8').trim()
const notes = new Map(), callers = new Map(), journal = [], botEntries = []
const log = value => { if (process.env.FAKE_LIBRARY_LOG) appendFileSync(process.env.FAKE_LIBRARY_LOG, JSON.stringify(value) + '\n') }

const reply = (response, status, value) => { const body = JSON.stringify(value); response.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) }); response.end(body) }
const tool = (id, value) => ({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: JSON.stringify(value) }], structuredContent: { success: true, result: value }, isError: false } })

function mcp(message, caller, groups) {
  if (message.method === 'tools/list') return { jsonrpc: '2.0', id: message.id, result: { tools: [] } }
  const name = message.params?.name, input = message.params?.arguments ?? {}
  const group = name?.split('_')[1]
  if (!groups.includes(group)) return { jsonrpc: '2.0', id: message.id, result: { isError: true, content: [{ type: 'text', text: 'disabled' }], structuredContent: { success: false, code: 'tool_disabled' } } }
  if (name === 'woven_notes_create') { const id = randomUUID(); notes.set(id, { id, title: input.title, text: '', author: caller }); return tool(message.id, { noteID: id, title: input.title }) }
  if (name === 'woven_notes_append') { const note = notes.get(input.noteID); note.text += input.text; return tool(message.id, { noteID: note.id }) }
  if (name === 'woven_notes_read') { const note = notes.get(input.noteID); return tool(message.id, note ?? null) }
  if (name === 'woven_notes_list') return tool(message.id, { notes: [...notes.values()] })
  if (name === 'woven_history_search') return tool(message.id, { entries: journal.filter(entry => !input.search || JSON.stringify(entry).includes(input.search)).map(entry => entry.eventID) })
  return tool(message.id, { name })
}

const local = createServer(async (request, response) => {
  const chunks = []; for await (const chunk of request) chunks.push(chunk)
  const raw = Buffer.concat(chunks), body = raw.length ? JSON.parse(raw.toString('utf8')) : null
  const path = new URL(request.url, 'http://localhost').pathname
  log({ method: request.method, path, headers: Object.fromEntries(Object.entries(request.headers).filter(([key]) => key.startsWith('x-woven-'))), body })
  if (request.headers.authorization !== 'Bearer ' + token) return reply(response, 401, { code: 'unauthorized', message: 'A valid library API token is required.' })
  if (path === '/v1/health') return reply(response, 200, { status: 'ok', service: 'wovenmatter-library', version: '1', deviceID, uptimeSeconds: 1 })
  if (path === '/v1/identity' && process.env.FAKE_LIBRARY_IDENTITY !== '0') return reply(response, 200, { deviceID, kind: 'linux', name: 'Fake Linux', publicKey: Buffer.alloc(32, 7).toString('base64'), endpoints: [] })
  if (path === '/v1/members') {
    if (!process.env.FAKE_LIBRARY_MEMBERS) return reply(response, 404, { code: 'not_found', message: 'Unknown library API route.' })
    return reply(response, 200, JSON.parse(readFileSync(process.env.FAKE_LIBRARY_MEMBERS, 'utf8')))
  }
  if (path === '/v1/callers') { callers.set(body.conversationID, body); return reply(response, 200, { conversationID: body.conversationID, enabledGroups: (body.enabledGroups ?? []).sort().join(',') }) }
  if (path === '/v1/mcp') {
    const caller = request.headers['x-woven-conversation-id'], groups = (request.headers['x-woven-enabled-groups'] ?? '').split(',').filter(Boolean)
    if (!caller) return reply(response, 400, { code: 'invalid_request', message: 'MCP requires a conversation binding and its current tool selection.' })
    return reply(response, 200, mcp(body, caller, groups))
  }
  if (path === '/v1/publisher/journal') {
    journal.push(...body.entries)
    return reply(response, 200, { libraryID: body.libraryID, acceptedEventIDs: body.entries.map(entry => entry.eventID), cursor: journal.length })
  }
  if (path === '/v1/publisher/retained/settle') return reply(response, 200, { libraryID: body.libraryID, acceptedEventIDs: body.entries.map(entry => entry.eventID) })
  const bots = path.match(/^\/v1\/bots\/([0-9a-f-]{36})\/entries$/)
  if (bots && process.env.FAKE_LIBRARY_BOTS !== '0') { botEntries.push(body); return reply(response, 200, { conversations: body.conversations.length, entries: body.entries.length }) }
  if (path === '/v1/debug/state') return reply(response, 200, { notes: [...notes.values()], callers: Object.fromEntries(callers), journal, botEntries })
  reply(response, 404, { code: 'not_found', message: 'Unknown library API route.' })
})
const network = createServer((request, response) => {
  const path = new URL(request.url, 'http://localhost').pathname.replace(/^\/wovenmatter(?=\/)/, '')
  if (path === '/v1/health') return reply(response, 200, { status: 'ok', service: 'wovenmatter-library', version: '1', deviceID, uptimeSeconds: 1 })
  reply(response, 404, { code: 'not_found' })
})
rmSync(socketPath, { force: true })
network.listen(Number(option('--port') ?? 0), '127.0.0.1', () => local.listen(socketPath, () => {
  chmodSync(socketPath, 0o600)
  const ready = { event: 'ready', pid: process.pid, port: network.address().port, socket: socketPath, version: '1' }
  writeFileSync(join(dataRoot, 'run/library.json'), JSON.stringify(ready) + '\n', { mode: 0o600 })
  process.stdout.write(JSON.stringify(ready) + '\n')
}))
const stop = () => { rmSync(join(dataRoot, 'run/library.json'), { force: true }); local.close(); network.close(); process.exit(0) }
process.on('SIGTERM', stop); process.on('SIGINT', stop)
