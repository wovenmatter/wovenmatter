import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync, symlinkSync, realpathSync, readdirSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { spawn } from 'node:child_process'
import { join } from 'node:path'
import { createHash, randomUUID } from 'node:crypto'
import { createDurableACP } from '../src/durable-acp.mjs'
import { createClientExecutionRuntime } from '../src/client-execution-runtime.mjs'
import { createClientExecution } from '../src/client-execution.mjs'
import { createExecutionAttachments, promptBlocks, readWorkspaceFile, attachmentFileName } from '../src/execution-attachments.mjs'
import { createTitleGenerator, sanitizeTitle } from '../src/title-generation.mjs'
import { openEphemeralACP, ephemeralSession } from '../src/ephemeral-acp.mjs'
import { createDefaultAgentControl } from '../src/default-agent-control.mjs'
import { createNativeClientSessions } from '../src/client-native-sessions.mjs'
import { enroll } from './fixtures/execution.mjs'

const pause = (milliseconds = 25) => new Promise(resolve => setTimeout(resolve, milliseconds))
async function until(read, accept, label = 'fixture') { for (let i = 0; i < 200; i++) { const value = await read(); if (accept(value)) return value; await pause() } throw new Error(label + ' timed out') }
const sha = bytes => createHash('sha256').update(bytes).digest('hex')
// `keep`: the caller removes it, after stopping what writes into it.
function temporary(t, prefix, { keep = false } = {}) { const path = realpathSync(mkdtempSync(join(tmpdir(), prefix))); if (!keep) t.after(() => rmSync(path, { recursive: true, force: true })); return path }

// An ACP agent with Codex-like configuration options. It records every
// request in `log`, answers session/load only for `loadable`, and replies to
// a prompt with `reply`, after asking for permission when `ask` is set.
function acpFixture(directory, { reply = 'done', loadable = [], ask = false } = {}) {
  const script = join(directory, 'agent-' + randomUUID() + '.mjs'), log = join(directory, 'log-' + randomUUID() + '.jsonl')
  writeFileSync(script, `import {appendFileSync} from 'node:fs';import {createInterface} from 'node:readline';
const out=v=>process.stdout.write(JSON.stringify(v)+'\\n');let sid='session_'+process.pid,prompt;
const loadable=${JSON.stringify(loadable)};
const options=()=>[{id:'model',category:'model',currentValue:model,options:[{value:'small',name:'Small'},{value:'large',name:'Large',description:'The larger model.'}]},
  {id:'reasoning_effort',category:'thought_level',currentValue:model==='large'?'high':'low',options:(model==='large'?['low','high']:['low']).map(value=>({value,name:value}))},
  {id:'mode',currentValue:'agent-full-access',options:[{value:'read-only',name:'Read Only'},{value:'agent',name:'Agent',_meta:{kind:'auto_review'}},{value:'agent-full-access',name:'Full'}]}];
let model='small';
createInterface({input:process.stdin}).on('line',line=>{const v=JSON.parse(line);appendFileSync(${JSON.stringify(log)},line+'\\n');
  if(v.method==='initialize')out({jsonrpc:'2.0',id:v.id,result:{protocolVersion:1,_meta:{steering:{supported:true}}}});
  else if(v.method==='session/new')out({jsonrpc:'2.0',id:v.id,result:{sessionId:sid,configOptions:options()}});
  else if(v.method==='session/load'){if(!loadable.includes(v.params.sessionId)){out({jsonrpc:'2.0',id:v.id,error:{code:-32002,message:'unknown session'}});return}sid=v.params.sessionId;out({jsonrpc:'2.0',id:v.id,result:{sessionId:sid,configOptions:options()}})}
  else if(v.method==='session/set_config_option'){if(v.params.configId==='model')model=v.params.value;out({jsonrpc:'2.0',id:v.id,result:{configOptions:options()}})}
  else if(v.method==='session/prompt'){prompt=v;out({jsonrpc:'2.0',method:'session/update',params:{sessionId:sid,update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:${JSON.stringify(reply)}}}}});
    if(${ask})out({jsonrpc:'2.0',id:'approval',method:'session/request_permission',params:{sessionId:sid,options:[{optionId:'once',name:'Allow'}]}});
    else out({jsonrpc:'2.0',id:v.id,result:{stopReason:'end_turn'}})}
  else if(v.id==='approval'){out({jsonrpc:'2.0',id:prompt.id,result:{stopReason:'end_turn'}})}
});`)
  return { harness: { id: 'fixture', displayName: 'Fixture', transport: 'acp', command: process.execPath, arguments: [script] },
    requests: () => existsSync(log) ? readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [] }
}

function directService(t, { runtime = {}, library = null, attachments = null, titleGenerator = null } = {}) {
  const directory = temporary(t, 'wm-parity-')
  const runs = [], created = [], configured = [], steered = []
  const base = { providers: async () => [{ id: 'codex', runtimeKind: 'codex', available: true, canStart: true }, { id: 'default_agent', runtimeKind: 'default_agent', available: true, canStart: true }],
    create: async request => { created.push(request); return { sessionID: randomUUID(), nativeWorkingDirectory: request.nativeWorkingDirectory } },
    settings: async () => ({ model: 'small', thinking: 'low', permission: 'agent-full-access', models: [{ id: 'small', label: 'Small' }, { id: 'large', label: 'Large' }], thinkingLevels: [{ id: 'low', label: 'low' }, { id: 'high', label: 'high' }], permissions: [] }),
    configure: async request => { configured.push(request.options) },
    run: async input => { const done = Promise.withResolvers(); runs.push({ ...input, done }); await done.promise },
    steer: async input => { steered.push(input) },
    stop: async ({ command }) => runs.find(item => item.command.runID === command.runID)?.done.resolve(),
    respond: async () => {}, close: async () => { for (const run of runs) run.done.resolve() }, ...runtime }
  const service = createClientExecution({ directory: join(directory, 'store'), workspaceRoot: directory, runtime: base, library, attachments, titleGenerator })
  t.after(() => service.close())
  const { enrollment, principal } = enroll(service)
  const command = (kind, values = {}) => ({ commandID: randomUUID(), deviceID: enrollment.deviceID, kind, ...values })
  return { directory, service, runs, created, configured, steered, enrollment, principal, command, mac: { ...principal, memberKind: 'mac', administrator: true } }
}

test('a member creates a session with its directory, model, thinking, permission, tools and title', async t => {
  const f = directService(t)
  const project = join(f.directory, 'project'); mkdirSync(project)
  const created = await f.service.command(f.command('createSession', { providerID: 'codex', title: 'Named',
    sessionOptions: { workingDirectory: project, model: 'large', thinking: 'high', permission: 'agent', enabledTools: ['notes', 'history'] } }), f.principal)
  assert.equal(created.status, 'completed', created.message)
  assert.equal(f.created[0].nativeWorkingDirectory, project)
  assert.equal(f.created[0].permission, 'agent')
  assert.deepEqual(f.configured, [{ model: 'large', thinking: 'high' }])
  const settings = (await f.service.readWorkspace({ session: { id: created.conversationID } })).session._0
  assert.deepEqual(settings.enabledTools.sort(), ['goals', 'history', 'notes'])
  assert.equal(f.service.conversations()[0].title, 'Named')
  // A model the harness does not offer keeps its native value, as on the Mac.
  await f.service.command(f.command('createSession', { providerID: 'codex', sessionOptions: { model: 'missing' } }), f.principal)
  assert.equal(f.configured.length, 1)
  // Only Macs choose directories outside the workspace, and they must exist.
  const outside = temporary(t, 'wm-outside-')
  assert.equal((await f.service.command(f.command('createSession', { providerID: 'codex', sessionOptions: { workingDirectory: outside } }), f.principal)).status, 'rejected')
  assert.equal((await f.service.command(f.command('createSession', { providerID: 'codex', sessionOptions: { workingDirectory: outside } }), f.mac)).status, 'completed')
  assert.equal(f.created.at(-1).nativeWorkingDirectory, outside)
  assert.equal((await f.service.command(f.command('createSession', { providerID: 'codex', sessionOptions: { workingDirectory: join(outside, 'missing') } }), f.mac)).status, 'rejected')
  assert.equal((await f.service.command(f.command('createSession', { providerID: 'codex', sessionOptions: { enabledTools: ['root'] } }), f.mac)).status, 'rejected')
  // The orchestration's frozen intent stays internal.
  await assert.rejects(f.service.command(f.command('createSession', { providerID: 'codex', initialConfiguration: { nativeWorkingDirectory: outside } }), f.mac), { statusCode: 400 })
  // Without a directory a session gets its own scratch folder.
  await f.service.command(f.command('createSession', { providerID: 'codex' }), f.principal)
  assert.equal(f.created.at(-1).nativeWorkingDirectory, undefined)
})

test('a folder bound to this workspace runs its sessions in its root; other bindings are refused', async t => {
  const root = temporary(t, 'wm-folder-root-')
  const folders = [], calls = []
  const library = { available: () => true, client: { registerCaller: async () => {}, publisher: async () => ({}),
    mcp: async (message, headers) => { calls.push({ message, headers }); return { status: 200, body: { jsonrpc: '2.0', id: message.id, result: { structuredContent: { success: true, result: { rows: folders, hasMore: false, nextCursor: folders.length } } } } } } } }
  const f = directService(t, { library })
  const here = 'remote:' + f.enrollment.workspaceID, bound = randomUUID(), elsewhere = randomUUID(), unbound = randomUUID()
  folders.push({ id: bound, name: 'Project', execution_workspace_id: here, root_path: root }, { id: elsewhere, name: 'Mac', execution_workspace_id: 'device:' + randomUUID(), root_path: '/Users/x' },
    { id: unbound, name: 'Loose', execution_workspace_id: null, root_path: null })
  const opened = await f.service.command(f.command('createSession', { providerID: 'codex', folderID: bound }), f.principal)
  assert.equal(opened.status, 'completed', opened.message)
  assert.equal(f.created[0].nativeWorkingDirectory, root)
  assert.equal(calls[0].message.params.name, 'woven_sessions_folders')
  assert.equal(calls[0].headers['x-woven-enabled-groups'], 'sessions')
  assert.equal((await f.service.command(f.command('createSession', { providerID: 'codex', folderID: bound, sessionOptions: { workingDirectory: f.directory } }), f.mac)).message, "The folder's root directory is fixed.")
  assert.equal((await f.service.command(f.command('createSession', { providerID: 'codex', folderID: elsewhere }), f.mac)).status, 'rejected')
  // An unbound folder, or one this library has not received yet, is grouping only.
  for (const folderID of [unbound, randomUUID()]) {
    assert.equal((await f.service.command(f.command('createSession', { providerID: 'codex', folderID }), f.principal)).status, 'completed')
    assert.equal(f.created.at(-1).nativeWorkingDirectory, undefined)
  }
})

test('uploaded attachments reach the harness with the message, verified and listed in the transcript', async t => {
  const workspace = temporary(t, 'wm-attachments-')
  const attachments = createExecutionAttachments({ directory: join(workspace, '.wovenmatter/attachments') })
  const f = directService(t, { attachments })
  const opened = await f.service.command(f.command('createSession', { providerID: 'codex' }), f.principal)
  const image = Buffer.from('fake png'), text = Buffer.from('notes 🌱'), binary = Buffer.from([0, 1, 2, 255])
  const stored = []
  for (const [bytes, name, mimeType] of [[image, 'a.png', 'image/png'], [text, 'notes.txt', 'text/plain'], [binary, '../data.bin', 'application/octet-stream']]) {
    stored.push(await f.service.uploadAttachment({ id: sha(bytes), name, mimeType, bytes }))
  }
  assert.deepEqual(stored.map(item => item.name), ['a.png', 'notes.txt', '.._data.bin'])
  assert.equal(stored[0].path, undefined)
  await assert.rejects(f.service.uploadAttachment({ id: sha(image), name: 'a.png', mimeType: 'image/png', bytes: text }), { statusCode: 400 })
  // Uploading the same bytes again reuses the staged copy.
  assert.deepEqual(await f.service.uploadAttachment({ id: sha(image), name: 'a.png', mimeType: 'image/png', bytes: image }), stored[0])
  const references = stored.map(({ id, name, mimeType }) => ({ id, name, mimeType }))
  const sent = await f.service.command(f.command('send', { conversationID: opened.conversationID, text: 'Look', attachments: references, promptContext: 'Workspace snapshot at send time' }), f.principal)
  assert.equal(sent.status, 'accepted', sent.message)
  await until(() => f.runs.length, value => value === 1)
  const run = f.runs[0]
  assert.deepEqual(run.files.map(file => file.name), ['a.png', 'notes.txt', '.._data.bin'])
  assert.ok(run.command.text.startsWith('Look\n\nWorkspace snapshot at send time'))
  const blocks = promptBlocks(run.command.text, run.files)
  assert.equal(blocks[0].type, 'text')
  assert.match(blocks[0].text, /Attached files available to this session:\n- .*\.\._data\.bin$/)
  assert.deepEqual(blocks.slice(1).map(block => block.type), ['image', 'resource', 'resource_link'])
  assert.equal(blocks[1].data, image.toString('base64'))
  assert.equal(blocks[2].resource.text, 'notes 🌱')
  assert.equal(blocks[3].size, binary.length)
  // Past the inline budget an image is linked, so one ACP message stays under the channel's limit.
  const linked = promptBlocks('', run.files, { inlineBytes: 4 })
  assert.deepEqual(linked.map(block => block.type), ['text', 'resource_link', 'resource_link', 'resource_link'])
  assert.match(linked[0].text, /a\.png/)
  const message = f.service.transcript(opened.conversationID).messages[0]
  assert.equal(message.content, 'Look')
  assert.deepEqual(message.attachments.map(item => [item.name, item.byteCount]), [['a.png', 8], ['notes.txt', text.length], ['.._data.bin', 4]])
  run.done.resolve(); await pause()
  // A staged copy an agent changed, or a file never uploaded, is refused.
  writeFileSync(attachments.pathFor(stored[1].id, 'notes.txt'), 'edited')
  const edited = await f.service.command(f.command('send', { conversationID: opened.conversationID, text: 'Again', attachments: [references[1]] }), f.principal)
  assert.equal(edited.status, 'rejected'); assert.match(edited.message, /Upload it again/)
  const missing = await f.service.command(f.command('send', { conversationID: opened.conversationID, text: '', attachments: [{ id: sha(Buffer.from('x')), name: 'x', mimeType: 'text/plain' }] }), f.principal)
  assert.match(missing.message, /not uploaded/)
  // A message may be attachments alone; steering carries them too.
  const only = await f.service.command(f.command('send', { conversationID: opened.conversationID, text: '', attachments: [references[0]] }), f.principal)
  assert.equal(only.status, 'accepted', only.message)
  await until(() => f.runs.length, value => value === 2)
  const steer = await f.service.command(f.command('steer', { conversationID: opened.conversationID, runID: only.runID, text: 'and this', attachments: [references[2]], promptContext: 'context' }), f.principal)
  assert.equal(steer.status, 'completed', steer.message)
  assert.equal(f.steered[0].files[0].name, '.._data.bin')
  assert.equal(f.steered[0].command.text, 'and this\n\ncontext')
  assert.equal(f.service.transcript(opened.conversationID).messages.at(-1).content, 'and this')
  // A workspace without attachment storage says so with a code.
  const plain = directService(t)
  const session = await plain.service.command(plain.command('createSession', { providerID: 'codex' }), plain.principal)
  const refused = await plain.service.command(plain.command('send', { conversationID: session.conversationID, text: 'x', attachments: [references[0]] }), plain.principal)
  assert.equal(refused.code, 'attachment_unavailable')
})

test('the attachment store never writes through a linked digest folder and keeps the host disk from filling', async t => {
  const workspace = temporary(t, 'wm-attachment-store-'), outside = temporary(t, 'wm-attachment-outside-')
  const directory = join(workspace, '.wovenmatter/attachments')
  // A disk with 2 bytes to spare above the minimum; each stored file uses its size.
  let free = 1_000_002
  const store = createExecutionAttachments({ directory, storeLimits: { minimumFreeBytes: 1_000_000 }, freeBytes: async () => free })
  const upload = async (text, name = 'note.txt') => {
    const bytes = Buffer.from(text), stored = await store.store({ id: sha(bytes), name, mimeType: 'text/plain', bytes })
    return stored
  }
  // A digest folder that is a link out of the store is refused, and nothing lands outside.
  const linked = Buffer.from('through a link')
  mkdirSync(directory, { recursive: true }); symlinkSync(outside, join(directory, sha(linked)))
  await assert.rejects(store.store({ id: sha(linked), name: 'note.txt', mimeType: 'text/plain', bytes: linked }), { statusCode: 403 })
  assert.equal(existsSync(join(outside, 'note.txt')), false)
  rmSync(join(directory, sha(linked)))
  // An upload that would leave less than the minimum free is refused with a clear reason.
  await assert.rejects(upload('three'), error => error.statusCode === 507 && /too little free disk space/.test(error.message))
  free = 10_000_000
  await upload('one'); await upload('two')
  // Storing one again needs no space and is never refused.
  free = 0
  assert.equal((await upload('one')).byteCount, 3)
  // There is no lifetime cap: with room on the disk, many files are stored.
  free = 10_000_000
  for (let index = 0; index < 50; index++) await upload('file ' + index)
  // Uploads at once are checked one after another against what is left.
  // The disk's free space is 1,000,002 bytes less what the store holds, so two 1-byte files fit.
  const racingDirectory = join(workspace, 'racing')
  const held = () => existsSync(racingDirectory) ? readdirSync(racingDirectory, { recursive: true, withFileTypes: true })
    .filter(entry => entry.isFile()).reduce((sum, entry) => sum + statSync(join(entry.parentPath, entry.name)).size, 0) : 0
  const racing = createExecutionAttachments({ directory: racingDirectory, storeLimits: { minimumFreeBytes: 1_000_000 },
    freeBytes: async () => 1_000_002 - held() })
  const results = await Promise.allSettled(['a', 'b', 'c'].map(text => { const value = Buffer.from(text); return racing.store({ id: sha(value), name: 'x.txt', bytes: value }) }))
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 2)
})

test('woven_context returns the note the sending device showed for that input', async t => {
  const f = directService(t)
  const opened = await f.service.command(f.command('createSession', { providerID: 'codex', sessionOptions: { enabledTools: ['notes'] } }), f.principal)
  const connection = f.service.mcp.sessionConnection(opened.conversationID), principal = f.service.mcp.resolvePrincipal('Bearer ' + connection.bearerToken)
  const context = async () => (await f.service.mcp.handle(principal, { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'woven_context', arguments: {} } })).result.structuredContent.result
  assert.equal(await context(), null)
  const sent = await f.service.command(f.command('send', { conversationID: opened.conversationID, text: 'About this note', noteID: 'note-1' }), f.principal)
  await until(() => f.runs.length, value => value === 1)
  assert.equal(await context(), 'note-1')
  await f.service.command(f.command('steer', { conversationID: opened.conversationID, runID: sent.runID, text: 'now this one', noteID: 'note-2' }), f.principal)
  assert.equal(await context(), 'note-2')
  f.runs[0].done.resolve(); await pause()
  assert.equal((await f.service.command(f.command('send', { conversationID: opened.conversationID, text: 'x', noteID: '../bad' }), f.principal)).status, 'rejected')
  // Without Notes the input captures nothing.
  const other = await f.service.command(f.command('createSession', { providerID: 'codex', sessionOptions: { enabledTools: ['history'] } }), f.principal)
  await f.service.command(f.command('send', { conversationID: other.conversationID, text: 'x', noteID: 'note-3' }), f.principal)
  assert.equal(f.service.record(other.conversationID).inputContexts[0].noteID, null)
})

test('a chat named by its first message gets a generated title unless it was named or renamed', async t => {
  const titles = []
  let answer = 'Generated title'
  const f = directService(t, { titleGenerator: async text => { titles.push(text); return answer } })
  const opened = await f.service.command(f.command('createSession', { providerID: 'codex' }), f.principal)
  await f.service.command(f.command('send', { conversationID: opened.conversationID, text: 'Please plan the garden beds' }), f.principal)
  await until(() => f.service.conversations().find(item => item.id === opened.conversationID).title, title => title === 'Generated title')
  assert.deepEqual(titles, ['Please plan the garden beds'])
  f.runs[0].done.resolve(); await pause()
  await f.service.command(f.command('send', { conversationID: opened.conversationID, text: 'second' }), f.principal)
  await pause(50)
  assert.equal(titles.length, 1)
  // A title named at creation stays.
  const named = await f.service.command(f.command('createSession', { providerID: 'codex', title: 'Mine' }), f.principal)
  await f.service.command(f.command('send', { conversationID: named.conversationID, text: 'hello' }), f.principal)
  await pause(50)
  assert.equal(titles.length, 1)
  // A failure keeps the first-message title, and the next message tries again.
  answer = null
  const failed = await f.service.command(f.command('createSession', { providerID: 'codex' }), f.principal)
  await f.service.command(f.command('send', { conversationID: failed.conversationID, text: 'first try' }), f.principal)
  await until(() => titles.length, value => value === 2)
  await pause(25)
  assert.equal(f.service.conversations().find(item => item.id === failed.conversationID).title, 'first try')
  answer = 'Second try'
  f.runs.at(-1).done.resolve(); await pause()
  await f.service.command(f.command('send', { conversationID: failed.conversationID, text: 'again' }), f.principal)
  await until(() => f.service.conversations().find(item => item.id === failed.conversationID).title, title => title === 'Second try')
})

test('title generation prompts a harness with the Mac instructions and cleans its answer', async t => {
  const directory = temporary(t, 'wm-title-')
  const fixture = acpFixture(directory, { reply: '{"title":"  Garden   bed plan. "}', ask: true })
  const generate = createTitleGenerator({ catalog: new Map([['fixture', fixture.harness]]), runtimeKind: 'fixture', cwd: async () => directory, environment: () => process.env })
  assert.equal(await generate('Plan my garden'), 'Garden bed plan')
  const requests = fixture.requests()
  const prompt = requests.find(item => item.method === 'session/prompt')
  assert.match(prompt.params.prompt[0].text, /^Generate a short title[\s\S]*First message:\nPlan my garden$/)
  assert.deepEqual(requests.find(item => item.method === 'session/new').params.mcpServers, [])
  // The agent's permission request was refused.
  assert.deepEqual(requests.find(item => item.id === 'approval').result, { outcome: { outcome: 'cancelled' } })
  assert.equal(sanitizeTitle('prefix {"title":"Inner"} suffix'), 'Inner')
  assert.equal(sanitizeTitle('"First line"\nsecond'), 'First line')
  assert.equal(sanitizeTitle('x'.repeat(60)), 'x'.repeat(47) + '…')
  assert.equal(sanitizeTitle('  ""  '), null)
  assert.equal(await createTitleGenerator({ catalog: new Map(), cwd: async () => directory })('text'), null)
})

test('a harness lists its options before a session exists, with permission descriptions', async t => {
  const workspaceRoot = temporary(t, 'wm-options-')
  const fixture = acpFixture(workspaceRoot)
  const catalog = new Map([['codex', { ...fixture.harness, id: 'codex' }]])
  const runtime = createClientExecutionRuntime({ defaultAgent: { status: async () => ({ locked: true }), cancelActive: async () => {} }, durableACP: { stopAll: async () => {} }, catalog, workspaceRoot,
    harnessStatus: async harness => ({ id: harness.id, displayName: harness.displayName, state: 'ready' }), environment: () => process.env,
    // Run the fixture itself, not inside the Woven MCP adapter Codex uses.
    spawnProcess: (command, args, options) => spawn(fixture.harness.command, fixture.harness.arguments, options) })
  const options = await runtime.sessionOptions({ runtimeKind: 'codex', model: 'large' })
  assert.equal(options.model, 'large')
  assert.deepEqual(options.thinkingLevels.map(item => item.id), ['low', 'high'])
  assert.equal(options.models[1].description, 'The larger model.')
  assert.deepEqual(options.permissions.map(item => [item.id, item.label]), [['agent-full-access', 'Full access'], ['agent', 'Approve for me']], 'Read only is not offered')
  assert.equal(options.permissions[1].description, 'Only ask for actions detected as potentially unsafe.')
  assert.deepEqual(fixture.requests().find(item => item.method === 'session/new').params.mcpServers, [])
  await assert.rejects(runtime.sessionOptions({ runtimeKind: 'codex', model: 'missing' }), /available model/)
  // Pi Durable answers from its own session configuration, and says when it is locked.
  await assert.rejects(runtime.sessionOptions({ runtimeKind: 'default_agent' }), error => error.code === 'default_agent_locked')
  const providers = await runtime.providers()
  assert.equal(providers[0].locked, true)
  // The service adds tool groups and returns the SessionSettings shape.
  const service = createClientExecution({ directory: join(workspaceRoot, 'store'), workspaceRoot, runtime })
  t.after(() => service.close())
  enroll(service)
  const settings = await service.sessionOptions('codex', {})
  assert.equal(settings.conversationID, '')
  assert.ok(settings.availableTools.some(item => item.id === 'notes'))
  assert.equal(settings.canConfigure, true)
  await assert.rejects(service.sessionOptions('default_agent'), { statusCode: 423 })
  await assert.rejects(service.sessionOptions('unknown'), { statusCode: 404 })
})

test('Pi Durable options come from a new Pi session with its own permission descriptions', async t => {
  const workspaceRoot = temporary(t, 'wm-pi-options-')
  const calls = []
  const configuration = model => ({ sessionId: 'pi', configOptions: [{ id: 'model', category: 'model', currentValue: model, options: [{ value: 'a', name: 'A' }, { value: 'b', name: 'B' }] },
    { id: 'thinking', category: 'thought_level', currentValue: 'low', options: [{ value: 'low', name: 'Low' }] },
    { id: 'permission_mode', currentValue: 'full', options: [{ value: 'full', name: 'Full access', description: 'Native Durable workspace tools run without approval prompts.' }] }] })
  const defaultAgent = { status: async () => ({ locked: false, epoch: 'e' }), cancelActive: async () => {},
    invoke: async message => { calls.push(message); return { result: message.method === 'session/new' ? { ...configuration('a'), _meta: { attachmentToken: 't' } } : configuration(message.params.value) } } }
  const runtime = createClientExecutionRuntime({ defaultAgent, durableACP: { stopAll: async () => {} }, catalog: new Map(), workspaceRoot })
  const options = await runtime.sessionOptions({ runtimeKind: 'default_agent', model: 'b' })
  assert.equal(options.model, 'b')
  assert.equal(options.permissions[0].description, 'Native Durable workspace tools run without approval prompts.')
  assert.equal(calls[1].method, 'session/set_config_option')
  assert.equal(calls[1].attachmentToken, 't')
})

test('OpenCode lists its models for a directory without creating a session', async () => {
  const calls = []
  const sessions = createNativeClientSessions({ workspaceRoot: '/workspace', instances: { action: async () => {}, registrationPath: 'r' },
    read: async () => JSON.stringify({ url: 'http://127.0.0.1:4000', password: 'p', pid: 7 }),
    fetchRequest: async (url, request) => {
      calls.push(request.method + ' ' + url.pathname)
      const data = url.pathname === '/api/info' ? { pid: 7, version: '2.0.22' }
        : url.pathname === '/api/model' ? { data: [{ providerID: 'lab', id: 'm', name: 'M', enabled: true, variants: [{ id: 'high', name: 'High' }] }, { providerID: 'lab', id: 'off', enabled: false }] }
        : url.pathname === '/api/model/default' ? { data: { providerID: 'lab', id: 'm' } } : assert.fail(url.pathname)
      return { ok: true, status: 200, json: async () => data }
    } })
  const options = await sessions.perform('opencode', { nativeWorkingDirectory: '/workspace/project' }, 'options', {})
  assert.deepEqual(options.models, [{ id: 'lab/m', label: 'M' }])
  assert.deepEqual(options.thinkingLevels.map(item => item.id), ['default', 'high'])
  assert.equal(options.permissions[0].label, 'Full access')
  assert.ok(!calls.some(call => call.includes('/api/session')))
})

test('member sessions run, and their channels survive, with background execution off', async t => {
  const workspaceRoot = temporary(t, 'wm-background-off-', { keep: true })
  const fixture = acpFixture(workspaceRoot, { reply: 'still works' })
  const catalog = new Map([['fixture', fixture.harness]])
  // The server no longer gates these channels on the task gateway.
  const relay = createDurableACP({ catalog, workspaceRoot, environment: () => process.env })
  const runtime = createClientExecutionRuntime({ defaultAgent: { status: async () => ({ locked: true }), cancelActive: async () => {} }, durableACP: relay, catalog, workspaceRoot,
    harnessStatus: async harness => ({ id: harness.id, displayName: harness.displayName, state: 'ready' }) })
  const service = createClientExecution({ directory: join(workspaceRoot, 'store'), workspaceRoot, runtime })
  t.after(async () => { await service.close(); await relay.stopAll(); rmSync(workspaceRoot, { recursive: true, force: true }) })
  const { enrollment, principal } = enroll(service)
  const providers = await runtime.providers()
  assert.equal(providers.find(item => item.id === 'fixture').available, true)
  const opened = await service.command({ commandID: randomUUID(), deviceID: enrollment.deviceID, kind: 'createSession', providerID: 'fixture' }, principal)
  assert.equal(opened.status, 'completed', opened.message)
  const input = { commandID: randomUUID(), deviceID: enrollment.deviceID, kind: 'send', conversationID: opened.conversationID, text: 'hi' }
  await service.command(input, principal)
  await until(() => service.receipt(input.commandID, enrollment.deviceID), receipt => receipt.status === 'completed')
  assert.equal(service.transcript(opened.conversationID).messages.at(-1).content, 'still works')
  // Turning background execution off stops other channels, not this one.
  const other = await relay.handle('POST', '/v1/durable-acp/attach', { channelID: 'relay-' + randomUUID().slice(0, 8), harnessID: 'fixture', cwd: workspaceRoot })
  await relay.stopAll({ except: id => service.ownsConversation(id) })
  assert.equal((await relay.peek(other.channelID)).state, 'stopped')
  assert.equal((await relay.peek(opened.conversationID)).state, 'running')
  assert.equal(service.ownsConversation(other.channelID), false)
})

test('adoption reopens a stopped or missing durable channel and never leaves a failed one behind', async t => {
  const workspaceRoot = temporary(t, 'wm-adopt-reopen-', { keep: true })
  const fixture = acpFixture(workspaceRoot, { loadable: ['native-known', 'native-second'], reply: 'after adoption' })
  const catalog = new Map([['fixture', fixture.harness]])
  const relay = createDurableACP({ catalog, workspaceRoot, environment: () => process.env })
  const runtime = createClientExecutionRuntime({ defaultAgent: { status: async () => ({ locked: true }), cancelActive: async () => {} }, durableACP: relay, catalog, workspaceRoot,
    harnessStatus: async harness => ({ id: harness.id, displayName: harness.displayName, state: 'ready' }) })
  const service = createClientExecution({ directory: join(workspaceRoot, 'store'), workspaceRoot, runtime })
  t.after(async () => { await service.close(); await relay.stopAll(); rmSync(workspaceRoot, { recursive: true, force: true }) })
  const { enrollment, principal } = enroll(service)
  const body = (id, nativeSessionID, extra = {}) => ({ workspaceID: enrollment.workspaceID, conversation: { id, title: 'Existing chat', preview: '', updatedAt: '', runtimeKind: 'fixture' },
    runtimeKind: 'fixture', nativeSessionID, nativeWorkingDirectory: workspaceRoot, ...extra })
  // An SSH session that never had a durable channel (background execution off).
  const fresh = randomUUID(), runID = randomUUID()
  const history = { messages: [{ id: randomUUID(), runID, role: 'user', content: 'before', createdAt: '' }, { id: runID, runID, role: 'assistant', content: 'partial', status: 'running', createdAt: '' }],
    activities: [{ id: runID + ':tool', runID, title: 'Read', status: 'running' }] }
  const adopted = await service.adopt(body(fresh, 'native-known', { transcript: history, knownRunIDs: [runID] }))
  assert.equal(adopted.id, fresh)
  const seeded = service.transcript(fresh)
  assert.deepEqual(seeded.messages.map(item => [item.content, item.status ?? null]), [['before', null], ['partial', 'interrupted']])
  assert.equal(seeded.activities[0].status, 'interrupted')
  assert.ok(fixture.requests().some(item => item.method === 'session/load' && item.params.sessionId === 'native-known'))
  const input = { commandID: randomUUID(), deviceID: enrollment.deviceID, kind: 'send', conversationID: fresh, text: 'continue' }
  await service.command(input, principal)
  await until(() => service.receipt(input.commandID, enrollment.deviceID), receipt => receipt.status === 'completed')
  assert.equal(service.transcript(fresh).messages.at(-1).content, 'after adoption')
  assert.equal(service.conversations().find(item => item.id === fresh).title, 'Existing chat')
  // A native session the harness cannot load leaves no process or journal.
  const failing = randomUUID()
  await assert.rejects(service.adopt(body(failing, 'native-unknown')))
  assert.equal(await relay.peek(failing), null)
  assert.equal(existsSync(join(workspaceRoot, '.wovenmatter/durable-acp', failing + '.jsonl')), false)
  assert.equal(service.ownsConversation(failing), false)
  // A channel a host restart stopped is recovered and reloaded.
  const stopped = randomUUID()
  const page = await relay.handle('POST', '/v1/durable-acp/attach', { channelID: stopped, harnessID: 'fixture', cwd: workspaceRoot, attachmentProtocol: 1 })
  const message = value => relay.handle('POST', '/v1/durable-acp/message', { channelID: stopped, attachmentToken: page.attachmentToken, deliveryID: randomUUID(), message: value })
  await message({ jsonrpc: '2.0', id: randomUUID(), method: 'initialize', params: { protocolVersion: 1 } })
  await message({ jsonrpc: '2.0', id: randomUUID(), method: 'session/load', params: { sessionId: 'native-second', cwd: workspaceRoot } })
  await until(() => relay.handle('POST', '/v1/durable-acp/poll', { channelID: stopped, after: 0 }), value => value.snapshot.session?.sessionId === 'native-second')
  await relay.stopAll({ except: id => id !== stopped })
  assert.equal((await relay.peek(stopped)).state, 'stopped')
  await assert.rejects(service.adopt(body(stopped, 'another-session')), /different native session/)
  assert.equal((await service.adopt(body(stopped, 'native-second'))).id, stopped)
  assert.equal((await relay.peek(stopped)).state, 'running')
})

test('adoption reopens a durable channel its owner left interrupted, never one a process still holds', async t => {
  const workspaceRoot = temporary(t, 'wm-adopt-interrupted-', { keep: true })
  const fixture = acpFixture(workspaceRoot, { loadable: ['native-left'], reply: 'after the crash' })
  const catalog = new Map([['fixture', fixture.harness]])
  // The former owner ran the channel and died without recording a stop.
  const former = createDurableACP({ catalog, workspaceRoot, environment: () => process.env })
  const channelID = randomUUID()
  const page = await former.handle('POST', '/v1/durable-acp/attach', { channelID, harnessID: 'fixture', cwd: workspaceRoot, attachmentProtocol: 1 })
  const message = value => former.handle('POST', '/v1/durable-acp/message', { channelID, attachmentToken: page.attachmentToken, deliveryID: randomUUID(), message: value })
  await message({ jsonrpc: '2.0', id: randomUUID(), method: 'initialize', params: { protocolVersion: 1 } })
  await message({ jsonrpc: '2.0', id: randomUUID(), method: 'session/load', params: { sessionId: 'native-left', cwd: workspaceRoot } })
  await until(() => former.handle('POST', '/v1/durable-acp/poll', { channelID, after: 0 }), value => value.snapshot.session?.sessionId === 'native-left')
  await former.stopAll()
  await former.peek(channelID) // after the stop its process exit queued
  const path = join(workspaceRoot, '.wovenmatter/durable-acp', channelID + '.jsonl')
  writeFileSync(path, readFileSync(path, 'utf8').split('\n').filter(line => line && JSON.parse(line).type !== 'stopped').map(line => line + '\n').join(''))
  const relay = createDurableACP({ catalog, workspaceRoot, environment: () => process.env })
  const runtime = createClientExecutionRuntime({ defaultAgent: { status: async () => ({ locked: true }), cancelActive: async () => {} }, durableACP: relay, catalog, workspaceRoot,
    harnessStatus: async harness => ({ id: harness.id, displayName: harness.displayName, state: 'ready' }) })
  const service = createClientExecution({ directory: join(workspaceRoot, 'store'), workspaceRoot, runtime })
  t.after(async () => { await service.close(); await relay.stopAll(); rmSync(workspaceRoot, { recursive: true, force: true }) })
  const { enrollment, principal } = enroll(service)
  assert.deepEqual(await relay.peek(channelID), { state: 'interrupted', live: false, sessionID: 'native-left', busy: false, pendingRequests: 0 })
  const body = { workspaceID: enrollment.workspaceID, conversation: { id: channelID, title: 'Left running', preview: '', updatedAt: '', runtimeKind: 'fixture' },
    runtimeKind: 'fixture', nativeSessionID: 'native-left', nativeWorkingDirectory: workspaceRoot }
  await assert.rejects(service.adopt({ ...body, nativeSessionID: 'another-session' }), /different native session/)
  assert.equal((await relay.peek(channelID)).state, 'interrupted')
  assert.equal((await service.adopt(body)).id, channelID)
  assert.equal((await relay.peek(channelID)).state, 'running')
  const input = { commandID: randomUUID(), deviceID: enrollment.deviceID, kind: 'send', conversationID: channelID, text: 'continue' }
  await service.command(input, principal)
  await until(() => service.receipt(input.commandID, enrollment.deviceID), receipt => receipt.status === 'completed')
  assert.equal(service.transcript(channelID).messages.at(-1).content, 'after the crash')
  // A channel whose process still runs is never released.
  await assert.rejects(relay.release(channelID), /still running/)
  let released = false
  const held = createClientExecutionRuntime({ defaultAgent: { status: async () => ({ locked: true }), cancelActive: async () => {} }, catalog, workspaceRoot,
    durableACP: { peek: async () => ({ state: 'interrupted', live: true, sessionID: 'native-held', busy: false, pendingRequests: 0 }), release: async () => { released = true }, stopAll: async () => {} },
    harnessStatus: async harness => ({ id: harness.id, displayName: harness.displayName, state: 'ready' }) })
  t.after(() => held.close?.())
  await assert.rejects(held.adopt({ native: { sessionID: 'native-held', channelID: randomUUID(), nativeWorkingDirectory: workspaceRoot }, runtimeKind: 'fixture' }), /still running on this host/)
  assert.equal(released, false)
})

test('ephemeral ACP refuses client RPCs and stops its process', async t => {
  const directory = temporary(t, 'wm-ephemeral-')
  const fixture = acpFixture(directory)
  const connection = openEphemeralACP({ harness: fixture.harness, cwd: directory })
  const session = await ephemeralSession(connection, directory)
  assert.match(session.sessionId, /^session_/)
  await connection.close()
  await assert.rejects(connection.request('session/new', { cwd: directory }))
})

test('workspace files are read for Library retention only inside the session root, /tmp or /mnt/data', async t => {
  const root = temporary(t, 'wm-library-file-'), outside = temporary(t, 'wm-library-outside-')
  writeFileSync(join(root, 'report.md'), '# Report')
  mkdirSync(join(root, 'nested')); writeFileSync(join(root, 'nested', 'data.csv'), 'a,b')
  writeFileSync(join(outside, 'secret.txt'), 'secret')
  symlinkSync(join(outside, 'secret.txt'), join(root, 'link.txt'))
  const file = await readWorkspaceFile({ path: 'report.md', root })
  assert.deepEqual([file.name, file.mimeType, file.data.toString()], ['report.md', 'text/markdown', '# Report'])
  assert.equal((await readWorkspaceFile({ path: 'file://' + join(root, 'nested', 'data.csv'), root })).mimeType, 'text/csv')
  // The system temporary folder is /tmp on Linux, which is itself a shared
  // root, so the outside checks name the shared roots explicitly.
  await assert.rejects(readWorkspaceFile({ path: join(outside, 'secret.txt'), root, sharedRoots: [] }), { statusCode: 403 })
  await assert.rejects(readWorkspaceFile({ path: 'link.txt', root, sharedRoots: [] }), { statusCode: 403 })
  assert.equal((await readWorkspaceFile({ path: join(outside, 'secret.txt'), root, sharedRoots: [outside] })).data.toString(), 'secret')
  await assert.rejects(readWorkspaceFile({ path: 'missing.txt', root }), { statusCode: 404 })
  await assert.rejects(readWorkspaceFile({ path: 'nested', root }), { statusCode: 400 })
  await assert.rejects(readWorkspaceFile({ path: 'report.md', root, maximumBytes: 3 }), { statusCode: 413 })
  // A malformed file URL is the caller's mistake, not a server error.
  for (const path of ['file://%E0%A4%A', 'file://host:99999/x', 'file:///a%00b']) await assert.rejects(readWorkspaceFile({ path, root }), { statusCode: 400 }, path)
  // The service resolves a session's working directory.
  const f = directService(t)
  const opened = await f.service.command(f.command('createSession', { providerID: 'codex', sessionOptions: { workingDirectory: root } }), f.mac)
  const read = await f.service.readLibraryFile({ conversationID: opened.conversationID, path: 'report.md' })
  assert.equal(Buffer.from(read.data, 'base64').toString(), '# Report')
  assert.equal(read.sha256, sha(Buffer.from('# Report')))
  assert.equal(attachmentFileName(''), 'attachment')
  assert.equal(attachmentFileName('a\u0001b/c'), 'a_b_c')
})

test('Pi Durable lock refusals carry a code a Mac acts on', async t => {
  const f = directService(t, { runtime: { providers: async () => [{ id: 'default_agent', runtimeKind: 'default_agent', available: false, canStart: false, locked: true, unavailableReason: 'Pi Durable is locked.' }] } })
  const receipt = await f.service.command(f.command('createSession', { providerID: 'default_agent' }), f.principal)
  assert.equal(receipt.status, 'rejected')
  assert.equal(receipt.code, 'default_agent_locked')
})

test('a member sets a goal on a session that has none', async t => {
  const f = directService(t)
  const opened = await f.service.command(f.command('createSession', { providerID: 'codex' }), f.principal)
  const set = await f.service.command(f.command('workspace', { conversationID: opened.conversationID, workspaceAction: { goal: { id: opened.conversationID, mutation: { set: { objective: 'Ship it' } } } } }), f.principal)
  assert.equal(set.status, 'completed', set.message)
  assert.equal((await f.service.readWorkspace({ session: { id: opened.conversationID } })).session._0.goal.objective, 'Ship it')
})

test('Pi Durable settings run the control helper here: results, sign-in prompts and failures', async t => {
  const directory = temporary(t, 'wm-pi-control-')
  const helper = join(directory, 'helper.mjs')
  writeFileSync(helper, `import {createInterface} from 'node:readline';const out=v=>process.stdout.write(JSON.stringify(v)+'\\n');
createInterface({input:process.stdin}).on('line',line=>{const v=JSON.parse(line);
  if(v.answerTo){out({result:{connected:v.answer==='yes'}});process.exit(0)}
  if(v.action==='status'){out({result:{providers:[{id:'openai',connected:Boolean(v.credentials?.openai)}],workspace:v.workspace,cwd:process.cwd(),directory:process.env.WOVEN_DEFAULT_AGENT_DIRECTORY}});process.exit(0)}
  if(v.action==='login'){out({notification:{url:'https://example.test/device',userCode:'ABCD-1234'}});out({id:'q1',prompt:{message:'Continue?',options:[{id:'yes',label:'Yes'}]}})}
  if(v.action==='catalog'){out({error:'Choose an enabled provider to browse its models.'});process.exit(1)}
});`)
  const control = createDefaultAgentControl({ command: () => ({ command: process.execPath, arguments: [helper] }), cwd: () => directory,
    environment: () => ({ ...process.env, WOVEN_DEFAULT_AGENT_DIRECTORY: join(directory, 'agent') }) })
  t.after(() => control.close())
  const status = await control.run({ action: 'status', workspace: 'w', credentials: { openai: { type: 'api_key', key: 'test' } } })
  assert.deepEqual(status.providers, [{ id: 'openai', connected: true }])
  assert.equal(status.directory, join(directory, 'agent'))
  await assert.rejects(control.run({ action: 'catalog' }), { statusCode: 409, message: 'Choose an enabled provider to browse its models.' })
  assert.throws(() => control.start({ action: 'shell' }), { statusCode: 400 })
  const login = control.start({ action: 'login', provider: 'openai' })
  const waiting = await until(() => control.status(login.id), value => !!value.prompt)
  assert.deepEqual(waiting.notifications, [{ url: 'https://example.test/device', userCode: 'ABCD-1234' }])
  assert.throws(() => control.answer(login.id, { answerTo: 'other', answer: 'yes' }), { statusCode: 409 })
  control.answer(login.id, { answerTo: 'q1', answer: 'yes' })
  const finished = await until(() => control.status(login.id), value => value.state !== 'running')
  assert.deepEqual([finished.state, finished.result], ['succeeded', { connected: true }])
  const cancelled = control.start({ action: 'login', provider: 'openai' })
  control.cancel(cancelled.id)
  assert.equal((await until(() => control.status(cancelled.id), value => value.state !== 'running')).state, 'failed')
})
