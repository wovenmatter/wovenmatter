import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm, open } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { PassThrough } from 'node:stream'
import { EventEmitter } from 'node:events'
import { createDurableACP } from '../src/durable-acp.mjs'
import { loadRuntimeConfiguration } from '../src/config.mjs'

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'durable-acp-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  let launches = 0, enabled = true, received = ''
  const child = new EventEmitter()
  Object.assign(child, { stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough(), kill: () => child.emit('close', 0) })
  child.stdin.on('data', bytes => { received += bytes })
  const options = { directory, workspaceRoot: directory, catalog: new Map([['test', { transport: 'acp', command: 'test' }]]),
    environment: () => ({}), isEnabled: async () => enabled, spawnProcess: () => { launches++; return child } }
  const relay = createDurableACP(options)
  const call = (op, body = {}) => relay.handle('POST', '/v1/durable-acp/' + op, { channelID: 'session', harnessID: 'test', ...body })
  return { call, relay, child, options, launches: () => launches, received: () => received, disable: () => { enabled = false } }
}

test('replacement attachment fences delayed old input, cancel and approval without blocking read-only polling', async t => {
  const f = await fixture(t)
  const old = await f.call('attach', { attachmentProtocol: 1 })
  const current = await f.call('attach', { attachmentProtocol: 1 })
  assert.notEqual(current.attachmentToken, old.attachmentToken)
  for (const message of [
    { jsonrpc: '2.0', id: 1, method: 'session/prompt', params: { sessionId: 'native' } },
    { jsonrpc: '2.0', method: 'session/cancel', params: { sessionId: 'native' } },
    { jsonrpc: '2.0', id: 'permission', result: { outcome: 'selected' } },
  ]) {
    await assert.rejects(f.call('message', { attachmentToken: old.attachmentToken, deliveryID: 'late', message }), /attachment was replaced/)
    await assert.rejects(f.call('message', { deliveryID: 'legacy', message }), /attachment was replaced/)
  }
  assert.equal(f.received(), '')
  assert.equal((await f.call('poll')).snapshot.recoveryComplete, false)
  assert.equal((await f.call('poll', { attachmentToken: old.attachmentToken })).snapshot.recoveryComplete, false)
  assert.equal((await f.call('poll', { attachmentToken: current.attachmentToken })).snapshot.recoveryComplete, true)
})

test('reattaching preserves process and journaled output without resubmitting accepted prompts', async t => {
  const f = await fixture(t)
  assert.equal((await f.call('attach')).state, 'running')
  const input = { deliveryID: 'delivery', message: { jsonrpc: '2.0', id: 1, method: 'session/prompt', params: { sessionId: 'native', _meta: { wovenRunID: 'run' } } } }
  await f.call('message', input)
  assert.equal((await f.call('message', input)).duplicate, true)
  f.child.stdout.write('{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"native","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello"}}}}\n')
  f.child.stdout.write('{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}\n')
  await new Promise(resolve => setImmediate(resolve))
  const reattached = await f.call('attach')
  assert.equal(f.launches(), 1)
  assert.equal(f.received().trim().split('\n').length, 1)
  assert.equal(reattached.events.length, 2)
  assert.deepEqual(reattached.snapshot.recoveredRuns, [{ runID: 'run', content: 'Hello' }])
  assert.equal((await f.call('poll', { after: 2 })).events.length, 0)
})

test('restart refuses prompt replay; busy sessions reject competing prompts', async t => {
  const f = await fixture(t)
  await f.call('attach')
  const message = { jsonrpc: '2.0', id: 1, method: 'session/prompt' }
  await f.call('message', { deliveryID: 'once', message })
  await assert.rejects(f.call('message', { deliveryID: 'twice', message }), /still running/)
  const restarted = createDurableACP(f.options)
  const body = { channelID: 'session', harnessID: 'test' }
  assert.equal((await restarted.handle('POST', '/v1/durable-acp/attach', body)).state, 'interrupted')
  assert.equal(f.launches(), 1)
  await assert.rejects(restarted.handle('POST', '/v1/durable-acp/message', { ...body, deliveryID: 'another', message }), /interrupted/)
})

test('only pending server callbacks survive attachment; duplicate replies never reach child', async t => {
  const f = await fixture(t)
  await f.call('attach')
  f.child.stdout.write('{"jsonrpc":"2.0","id":"permission","method":"session/request_permission","params":{"sessionId":"native"}}\n')
  await new Promise(resolve => setImmediate(resolve))
  assert.equal((await f.call('attach')).snapshot.pendingRequests.length, 1)
  const reply = { jsonrpc: '2.0', id: 'permission', result: { outcome: { outcome: 'cancelled' } } }
  await f.call('message', { deliveryID: 'reply1', message: reply })
  assert.equal((await f.call('attach')).snapshot.pendingRequests.length, 0)
  assert.equal((await f.call('message', { deliveryID: 'reply2', message: reply })).duplicate, true)
  assert.equal(f.received().trim().split('\n').length, 1)
})

test('disabling during asynchronous admission fences process creation and stopAll', async t => {
  const f = await fixture(t)
  await assert.rejects(f.call('attach', { harnessID: 'arbitrary-shell' }), /Unknown/)
  let release, reached
  const gate = new Promise(resolve => { release = resolve })
  const entered = new Promise(resolve => { reached = resolve })
  const relay = createDurableACP({ ...f.options, isHarnessEnabled: async () => { reached(); await gate; return true } })
  const attaching = relay.handle('POST', '/v1/durable-acp/attach', { channelID: 'racing', harnessID: 'test' })
  const rejected = assert.rejects(attaching, /disabled/)
  await entered
  f.disable()
  const stopped = relay.stopAll()
  release()
  await rejected
  await stopped
  assert.equal(f.launches(), 0)
  assert.equal(relay.hasActiveRuntime(), false)
  await assert.rejects(f.call('attach'), /disabled/)
})

test('stream output batches disk sync while terminal receipt flushes the complete recovery', async t => {
  const f = await fixture(t)
  let syncs = 0
  const relay = createDurableACP({...f.options, journalFlushInterval: 75,
    openJournal: async (...args) => {
      const file = await open(...args)
      return {writeFile: data => file.writeFile(data), close: () => file.close(),
        sync: async () => { syncs++; await file.sync() }}
    },
  })
  const call = (op, body = {}) => relay.handle('POST', '/v1/durable-acp/' + op, {channelID:'batch',harnessID:'test',...body})
  await call('attach')
  await call('message', {deliveryID:'input',message:{jsonrpc:'2.0',id:1,method:'session/prompt',params:{sessionId:'native',_meta:{wovenRunID:'batch-run'}}}})
  const initialSyncs = syncs, started = performance.now()
  for (let i=0;i<1000;i++) f.child.stdout.write(JSON.stringify({jsonrpc:'2.0',method:'session/update',params:{sessionId:'native',update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'x'}}}})+'\n')
  await new Promise(resolve=>setImmediate(resolve))
  const live = await call('poll')
  assert.equal(live.events.length,256)
  assert.equal(live.snapshot.busy,true)
  f.child.stdout.write('{"jsonrpc":"2.0","id":1,"result":{}}\n')
  await new Promise(resolve=>setImmediate(resolve))
  const complete = await call('attach')
  assert.equal(complete.snapshot.recoveredRuns[0].content, 'x'.repeat(1000))
  assert.ok(syncs-initialSyncs < 20, `stream used ${syncs-initialSyncs} syncs`)
  t.diagnostic(`1000 chunks: ${syncs-initialSyncs} journal syncs, ${(performance.now()-started).toFixed(1)}ms`)
  const restarted = createDurableACP(f.options)
  const restored = await restarted.handle('POST','/v1/durable-acp/attach',{channelID:'batch',harnessID:'test'})
  assert.equal(restored.snapshot.recoveredRuns[0].content,'x'.repeat(1000))
})

test('same-run steering is forwarded once and all prompt responses own completion', async t => {
  const f = await fixture(t)
  await f.call('attach')
  const prompt = id => ({ deliveryID: 'input-' + id, message: { jsonrpc: '2.0', id, method: 'session/prompt', params: { sessionId: 'native', _meta: { wovenRunID: 'run' } } } })
  await f.call('message', prompt(1))
  const update = text => f.child.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: 'native', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text } } } }) + '\n')
  update('before ')
  await new Promise(resolve => setImmediate(resolve))
  await f.call('message', prompt(2))
  await f.call('message', prompt(3))
  assert.equal((await f.call('message', prompt(2))).duplicate, true)
  f.child.stdout.write('{"jsonrpc":"2.0","id":1,"result":{"stopReason":"cancelled"}}\n')
  update('after ')
  f.child.stdout.write('{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}\n')
  await new Promise(resolve => setImmediate(resolve))
  const active = await f.call('attach')
  assert.equal(active.snapshot.busy, true)
  assert.deepEqual(active.snapshot.recoveredRuns, [])
  await assert.rejects(f.call('message', { deliveryID: 'foreign', message: { ...prompt(4).message, params: { sessionId: 'other', _meta: { wovenRunID: 'run' } } } }), /still running/)
  for (const params of [{ sessionId: 'other' }, { sessionId: 'native', _meta: { wovenRunID: 'other-run' } }]) {
    await assert.rejects(f.call('message', { deliveryID: 'foreign-steer', message: {
      jsonrpc: '2.0', id: 4, method: '_session/steering', params,
    } }), /another remote task/)
  }
  f.child.stdout.write('{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\n')
  await new Promise(resolve => setImmediate(resolve))
  const done = await f.call('attach')
  assert.equal(done.snapshot.busy, false)
  assert.deepEqual(done.snapshot.recoveredRuns, [{ runID: 'run', content: 'before after ' }])
  assert.equal(f.received().trim().split('\n').length, 3)
})

for (const latestFailed of [false, true]) test(`concurrent ACP recovery follows input order, not response order (failed=${latestFailed})`, async t => {
  const f = await fixture(t)
  await f.call('attach')
  for (const id of [1, 2]) await f.call('message', { deliveryID: `input-${id}`, message: {
    jsonrpc: '2.0', id, method: 'session/prompt', params: { sessionId: 'native', _meta: { wovenRunID: 'run' } },
  } })
  for (const id of [2, 1]) {
    const failed = (id === 2) === latestFailed
    f.child.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, ...(failed ? { error: { code: -1, message: 'turn failed' } } : { result: { stopReason: 'end_turn' } }) }) + '\n')
  }
  await new Promise(resolve => setImmediate(resolve))
  const done = await f.call('attach')
  assert.equal(done.snapshot.busy, false)
  assert.deepEqual(done.snapshot.recoveredRuns, [{ runID: 'run', content: '', ...(latestFailed ? { error: 'turn failed' } : {}) }])
})
test('natural process exit settles interrupted prompts and survives service restart', async t => {
  const f = await fixture(t)
  await f.call('attach')
  await f.call('message', { deliveryID: 'prompt', message: {
    jsonrpc: '2.0', id: 1, method: 'session/prompt', params: {
      sessionId: 'native', _meta: { wovenRunID: 'run' },
    },
  } })
  f.child.emit('close', 1)
  const stopped = await f.call('attach')
  assert.equal(stopped.state, 'stopped')
  assert.equal(stopped.snapshot.busy, false)
  assert.equal(stopped.snapshot.recoveredRuns[0].runID, 'run')
  assert.match(stopped.snapshot.recoveredRuns[0].error, /stopped before completion/)
  const restarted = createDurableACP(f.options)
  const restored = await restarted.handle('POST', '/v1/durable-acp/attach', {
    channelID: 'session', harnessID: 'test',
  })
  assert.equal(restored.state, 'stopped')
  assert.deepEqual(restored.snapshot.recoveredRuns, stopped.snapshot.recoveredRuns)
  assert.equal(f.launches(), 1)
})

test('native host durable sessions permit linked external folders while containers retain containment', async t => {
  const external = await mkdtemp(join(tmpdir(), 'woven-linked-project-'))
  t.after(() => rm(external, { recursive: true, force: true }))
  for (const runtimeKind of ['container', 'host']) {
    const f = await fixture(t)
    const relay = createDurableACP({ ...f.options, runtimeKind })
    const body = { channelID: 'external-project', harnessID: 'test', cwd: external }
    const attaching = relay.handle('POST', '/v1/durable-acp/attach', body)
    if (runtimeKind === 'container') {
      await assert.rejects(attaching, /outside this workspace/)
      assert.equal(f.launches(), 0)
    } else {
      assert.equal((await attaching).state, 'running')
      assert.equal(f.launches(), 1)
    }
    await relay.stopAll()
  }
})

test('full-root durable relay enforces its workspace permission on stale client settings', async t => {
  const f = await fixture(t)
  const relay = createDurableACP({ ...f.options, runtimeKind: 'host',
    configuration: loadRuntimeConfiguration({ WOVENMATTER_RUNTIME_KIND: 'host', WOVENMATTER_ACCESS_MODE: 'fullRoot' }),
    catalog: new Map([['codex', { transport: 'acp', command: 'codex-acp', arguments: [] }]]) })
  await relay.handle('POST', '/v1/durable-acp/attach', { channelID: 'root-session', harnessID: 'codex', cwd: f.options.workspaceRoot })
  await relay.handle('POST', '/v1/durable-acp/message', { channelID: 'root-session', deliveryID: 'config',
    message: { jsonrpc: '2.0', id: 1, method: 'session/set_config_option', params: { sessionId: 'native', configId: 'mode', value: 'ask' } } })
  assert.equal(JSON.parse(f.received()).params.value, 'agent-full-access')
  await relay.stopAll()
})

test('recovery replaces assistant snapshots atomically, preserves suffixes and replays the same result', async t => {
  const snapshot = {wovenAssistantSnapshot:true}
  const start = {...snapshot,wovenSnapshotStart:true,wovenSnapshotEnd:false}
  const end = {...snapshot,wovenSnapshotStart:false,wovenSnapshotEnd:true}
  for (const [frames, expected] of [
    [[['old answer'],['Before ',start],['🧵',end],[' after']], 'Before 🧵 after'],
    [[['old answer'],['corrected',snapshot],[' retained']], 'corrected retained'],
    [[['complete answer'],['incomplete',start]], 'complete answer'],
  ]) {
    const f = await fixture(t)
    await f.call('attach')
    await f.call('message', {deliveryID:'run',message:{jsonrpc:'2.0',id:1,method:'session/prompt',params:{sessionId:'native',_meta:{wovenRunID:'run'}}}})
    for (const [text, meta] of frames) f.child.stdout.write(JSON.stringify({jsonrpc:'2.0',method:'session/update',params:{sessionId:'native',update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text},...(meta?{_meta:meta}:{})}}})+'\n')
    f.child.stdout.write('{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}\n')
    await new Promise(resolve => setImmediate(resolve))
    const recovered = [{runID:'run',content:expected}]
    assert.deepEqual((await f.call('attach')).snapshot.recoveredRuns,recovered)
    await f.relay.stopAll()
    const restarted = createDurableACP(f.options)
    const attached = await restarted.handle('POST','/v1/durable-acp/attach',{channelID:'session',harnessID:'test'})
    assert.deepEqual(attached.snapshot.recoveredRuns,recovered)
  }
})
