import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm, open } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { PassThrough } from 'node:stream'
import { EventEmitter } from 'node:events'
import { createDurableACP } from '../src/durable-acp.mjs'

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

test('disabled mode and unknown commands cannot launch a process', async t => {
  const f = await fixture(t)
  await assert.rejects(f.call('attach', { harnessID: 'arbitrary-shell' }), /Unknown/)
  f.disable()
  await assert.rejects(f.call('attach'), /disabled/)
  assert.equal(f.launches(), 0)
})

test('stopAll terminates the service-owned process', async t => {
  const f = await fixture(t)
  await f.call('attach')
  assert.equal(f.relay.hasActiveRuntime('test'), true)
  await f.relay.stopAll()
  assert.equal(f.relay.hasActiveRuntime('test'), false)
})

test('stdio reconnect serves cached initialization and terminal recovery without old responses', async () => {
  const { runStdioRelay } = await import('../src/durable-acp-stdio.mjs')
  const input = new PassThrough(), output = new PassThrough()
  let text = '', posts = 0
  output.on('data', bytes => { text += bytes; if (text.trim().split('\n').length === 2) input.end() })
  const state = { initialized: { protocolVersion: 1 }, session: { sessionId: 'native', modes: {} },
    busy: false, recoveredRuns: [{ runID: 'run', content: 'Done' }] }
  const request = async (url, options) => {
    if (url.endsWith('/message')) posts++
    return { ok: true, json: async () => ({ state: 'running', snapshot: state,
      events: url.endsWith('/attach') ? [{ sequence: 1, message: { jsonrpc: '2.0', id: 'old', result: {} } }] : [] }) }
  }
  input.write('{"jsonrpc":"2.0","id":1,"method":"initialize"}\n')
  input.write('{"jsonrpc":"2.0","id":2,"method":"session/load","params":{"sessionId":"native"}}\n')
  await runStdioRelay({ channelID: 'channel', harnessID: 'test', token: 'fixture', input, output, request })
  const messages = text.trim().split('\n').map(JSON.parse)
  assert.deepEqual(messages.map(message => message.id), [1, 2])
  assert.equal(messages[1].result._meta.recoveredRuns[0].content, 'Done')
  assert.equal(posts, 0)
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

test('disabled maintenance harness cannot create a runtime', async t => {
  const f = await fixture(t)
  const relay = createDurableACP({ ...f.options, isHarnessEnabled: async () => false })
  await assert.rejects(relay.handle('POST', '/v1/durable-acp/attach', { channelID: 'disabled', harnessID: 'test' }), /harness is disabled/)
  assert.equal(f.launches(), 0)
})

test('disabling during asynchronous admission fences process creation and stopAll', async t => {
  const f = await fixture(t)
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


test('Pi prompt settlement and failed turns remain recoverable after reconnect', async t => {
  const f = await fixture(t)
  f.options.catalog.set('pi', { transport: 'rpc', command: 'pi' })
  const call = (op, body = {}) => f.call(op, { harnessID: 'pi', ...body })
  await call('attach')
  await call('message', { deliveryID: 'pi-prompt', message: {
    type: 'prompt', id: 'p1', message: 'fixture', _meta: { wovenRunID: 'pi-run' },
  } })
  assert.equal(JSON.parse(f.received())._meta, undefined)
  f.child.stdout.write(JSON.stringify({type: 'response', id: 'p1', success: true}) + '\n')
  f.child.stdout.write(JSON.stringify({type: 'message_update', assistantMessageEvent: {type: 'text_delta', delta: 'Hello'}}) + '\n')
  f.child.stdout.write(JSON.stringify({type: 'message_end', message: {role: 'assistant', content: [{type: 'text', text: 'Hello'}], stopReason: 'error', errorMessage: 'fixture failure'}}) + '\n')
  f.child.stdout.write(JSON.stringify({type: 'agent_settled'}) + '\n')
  await new Promise(resolve => setImmediate(resolve))
  const attached = await call('attach')
  assert.equal(attached.snapshot.busy, false)
  assert.deepEqual(attached.snapshot.recoveredRuns, [{runID: 'pi-run', content: 'Hello', error: 'fixture failure'}])
  assert.equal(f.launches(), 1)
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


test('idle polls wait without blocking command admission, then wake on the next output', async t => {
  const f = await fixture(t)
  await f.call('attach')
  let received = false
  const waiting = f.call('poll', {after:0, waitMs:10000}).then(value => {received=true;return value})
  await new Promise(resolve=>setTimeout(resolve,25))
  assert.equal(received,false)
  // This would deadlock if a long poll held the shared command queue.
  await f.call('message',{deliveryID:'during-wait',message:{jsonrpc:'2.0',id:1,method:'initialize'}})
  const started=performance.now()
  f.child.stdout.write('{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}\n')
  const result=await waiting
  assert.equal(result.events.length,1)
  assert.equal(result.events[0].message.id,1)
  assert.ok(performance.now()-started<1000,'output must wake immediately instead of waiting for the ten-second timeout')
  const timed=await f.call('poll',{after:1,waitMs:5})
  assert.equal(timed.events.length,0)
})

test('session shutdown releases waiting polls',async t=>{
  const f=await fixture(t)
  await f.call('attach')
  const waiting=f.call('poll',{after:0,waitMs:10000})
  await new Promise(resolve=>setImmediate(resolve))
  await f.relay.stopAll()
  assert.equal((await waiting).state,'stopped')
})

test('stdio relay makes one idle wait and aborts it immediately when detached',async()=>{
  const {runStdioRelay}=await import('../src/durable-acp-stdio.mjs')
  const input=new PassThrough(),output=new PassThrough()
  let polls=0,observedWait
  const started=new Promise(resolve=>{observedWait=resolve})
  const request=async(url,options)=>{
    if(url.endsWith('/attach'))return {ok:true,json:async()=>({state:'running',snapshot:{busy:false},events:[]})}
    assert.ok(url.endsWith('/poll'))
    polls++
    assert.equal(JSON.parse(options.body).waitMs,10000)
    observedWait()
    return await new Promise((resolve,reject)=>options.signal.addEventListener('abort',()=>reject(options.signal.reason),{once:true}))
  }
  const running=runStdioRelay({channelID:'idle',harnessID:'test',token:'fixture',input,output,request})
  await started
  await new Promise(resolve=>setTimeout(resolve,150))
  assert.equal(polls,1)
  input.end()
  await running
  assert.equal(polls,1)
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
  f.child.stdout.write('{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\n')
  await new Promise(resolve => setImmediate(resolve))
  const done = await f.call('attach')
  assert.equal(done.snapshot.busy, false)
  assert.deepEqual(done.snapshot.recoveredRuns, [{ runID: 'run', content: 'before after ' }])
  assert.equal(f.received().trim().split('\n').length, 3)
})

for (const fast of [false, true]) test(`Codex detached steering retains recovery through native idle (fast=${fast})`, async t => {
  const f = await fixture(t)
  await f.call('attach')
  const send = message => f.child.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n')
  const status = type => send({ method: 'session/update', params: { sessionId: 'native', update: { sessionUpdate: 'session_info_update', _meta: { codex: { threadStatus: { type } } } } } })
  await f.call('message', { deliveryID: 'initial', message: { jsonrpc: '2.0', id: 1, method: 'session/prompt', params: { sessionId: 'native', _meta: { wovenRunID: 'run' } } } })
  await f.call('message', { deliveryID: 'steer', message: { jsonrpc: '2.0', id: 2, method: '_session/steering', params: { sessionId: 'native', prompt: [{ type: 'text', text: 'continue' }] } } })
  status('active'); send({ id: 1, result: { stopReason: 'end_turn' } }); status('idle'); status('active')
  const finish = () => {
    send({ method: 'session/update', params: { sessionId: 'native', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'continuation' } } } })
    status('idle')
  }
  if (fast) finish()
  send({ id: 2, result: { outcome: 'startedNewTurn' } })
  await new Promise(resolve => setImmediate(resolve))
  if (!fast) {
    assert.equal((await f.call('attach')).snapshot.busy, true)
    assert.deepEqual((await f.call('attach')).snapshot.recoveredRuns, [])
    finish()
    await new Promise(resolve => setImmediate(resolve))
  }
  const done = await f.call('attach')
  assert.equal(done.snapshot.busy, false)
  assert.deepEqual(done.snapshot.recoveredRuns, [{ runID: 'run', content: 'continuation' }])
})

for (const rejected of [false, true]) test(`Pi steering preflight retains one recovery through an old settlement (rejected=${rejected})`, async t => {
  const f = await fixture(t)
  f.options.catalog.set('pi', { transport: 'rpc', command: 'pi' })
  const call = (op, body = {}) => f.call(op, { harnessID: 'pi', ...body })
  const emit = message => f.child.stdout.write(JSON.stringify(message) + '\n')
  const tick = () => new Promise(resolve => setImmediate(resolve))
  await call('attach')
  const prompt = id => ({ deliveryID: id, message: { type: 'prompt', id, message: id, _meta: { wovenRunID: 'run' }, ...(id === 'first' ? {} : { streamingBehavior: 'steer' }) } })
  await call('message', prompt('first'))
  emit({ type: 'response', id: 'first', success: true })
  emit({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', delta: 'before ' } })
  await tick()
  await call('message', prompt('second'))
  assert.equal((await call('message', prompt('second'))).duplicate, true)
  emit({ type: 'agent_settled' })
  await tick()
  assert.equal((await call('attach')).snapshot.busy, true)
  emit({ type: 'response', id: 'second', success: !rejected, ...(rejected ? { error: 'rejected' } : {}) })
  if (!rejected) emit({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', delta: 'after' } })
  await tick()
  if (rejected) {
    await call('message', { deliveryID: 'state', message: { type: 'get_state', id: 'state' } })
    emit({ type: 'response', id: 'state', success: true, data: { isStreaming: false, isCompacting: false, pendingMessageCount: 0 } })
  } else emit({ type: 'agent_settled' })
  await tick()
  const done = (await call('attach')).snapshot
  assert.equal(done.busy, false)
  assert.deepEqual(done.recoveredRuns, [{ runID: 'run', content: rejected ? 'before ' : 'before after' }])
  assert.equal(f.received().includes('_meta'), false)
})

test('late same-run ACP continuation extends recovery instead of duplicating or losing its prefix', async t => {
  const f = await fixture(t)
  await f.call('attach')
  for (const id of [1, 2]) {
    await f.call('message', { deliveryID: `input-${id}`, message: { jsonrpc: '2.0', id, method: 'session/prompt', params: { sessionId: 'native', _meta: { wovenRunID: 'run' } } } })
    f.child.stdout.write(JSON.stringify({ method: 'session/update', params: { sessionId: 'native', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: `${id} ` } } } }) + '\n')
    f.child.stdout.write(JSON.stringify({ id, result: { stopReason: 'end_turn' } }) + '\n')
    await new Promise(resolve => setImmediate(resolve))
  }
  assert.deepEqual((await f.call('attach')).snapshot.recoveredRuns, [{ runID: 'run', content: '1 2 ' }])
})
