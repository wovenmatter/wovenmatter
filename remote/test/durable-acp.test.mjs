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

for (const mode of ['codex', 'codex-paged']) test(`stdio relay forwards continuation output after its last request receipt (${mode})`, { timeout: 5000 }, async t => {
  const { runStdioRelay } = await import('../src/durable-acp-stdio.mjs')
  const f = await fixture(t)
  const count = mode === 'codex-paged' ? 260 : 1
  const input = new PassThrough(), output = new PassThrough(), observed = []
  let buffer = ''
  output.on('data', bytes => {
    buffer += bytes
    while (buffer.includes('\n')) {
      const end = buffer.indexOf('\n'); observed.push(JSON.parse(buffer.slice(0, end))); buffer = buffer.slice(end + 1)
    }
  })
  const until = async predicate => {
    for (let i = 0; i < 500; i++) {
      if (predicate()) return
      await new Promise(resolve => setTimeout(resolve, 5))
    }
    assert.fail('Timed out waiting for forwarded continuation output')
  }
  const request = async (url, options) => {
    const work = f.relay.handle('POST', new URL(url).pathname, JSON.parse(options.body))
    const result = await Promise.race([work, new Promise((_, reject) => {
      if (options.signal.aborted) reject(options.signal.reason)
      else options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true })
    })])
    return { ok: true, json: async () => result }
  }
  const running = runStdioRelay({ channelID: 'session', harnessID: 'test', token: 'fixture', input, output, request })
  t.after(async () => { input.end(); await running })
  const writeInput = message => input.write(JSON.stringify(message) + '\n')
  const native = () => f.received().trim().split('\n').filter(Boolean).map(JSON.parse)
  const emit = message => f.child.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n')
  const status = type => emit({ method: 'session/update', params: { sessionId: 'native', update: { _meta: { codex: { threadStatus: { type } } } } } })
  const text = value => emit({ method: 'session/update', params: { sessionId: 'native', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: value } } } })
  writeInput({ jsonrpc: '2.0', id: 1, method: 'session/prompt', params: { sessionId: 'native', _meta: { wovenRunID: 'run' } } })
  await until(() => native().length === 1)
  const original = native()[0].id
  status('active')
  text('before')
  await until(() => observed.some(message => JSON.stringify(message).includes('before')))
  writeInput({ jsonrpc: '2.0', id: 2, method: '_session/steering', params: { sessionId: 'native', prompt: [{ type: 'text', text: 'continue' }], _meta: { wovenRunID: 'run' } } })
  await until(() => native().length === 2)
  const steering = native()[1].id
  emit({ id: original, result: { stopReason: 'end_turn' } }); status('idle'); status('active')
  emit({ id: steering, result: { outcome: 'startedNewTurn' } })
  await until(() => observed.some(message => message.id === 2))
  await new Promise(resolve => setImmediate(resolve))
  for (let i = 0; i < count; i++) text('continued')
  status('idle')
  await until(() => observed.filter(message => JSON.stringify(message).includes('continued')).length === count)
  input.end()
  await running
  assert.equal(native().length, 2)
  await f.relay.stopAll()
  // Drain the natural-close journal entry queued by the fake child as well.
  await f.call('poll', { harnessID: 'test' })
})

test('stdio relay distinguishes a lost dispatch receipt from native rejection', { timeout: 5000 }, async () => {
  const { runStdioRelay } = await import('../src/durable-acp-stdio.mjs')
  const input = new PassThrough(), output = new PassThrough()
  let result
  output.on('data', bytes => { result = JSON.parse(bytes); input.end() })
  const request = async (url, options) => {
    if (url.endsWith('/attach')) return { ok: true, json: async () => ({ state: 'running', attachmentToken: 'fixture-attachment', snapshot: { busy: false }, events: [] }) }
    if (url.endsWith('/message')) throw new Error('connection lost after dispatch')
    return new Promise((_, reject) => options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true }))
  }
  input.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: '_session/steering', params: { sessionId: 'native' } }) + '\n')
  await runStdioRelay({ channelID: 'session', harnessID: 'test', token: 'fixture', input, output, request })
  assert.equal(result.id, 1)
  assert.equal(result.error.data.deliveryUncertain, true)
})

for (const harnessID of ['test']) {
  test(`${harnessID} reconnect waits for restored approval beyond the load deadline`, { timeout: 2000 }, async () => {
    const { runStdioRelay } = await import('../src/durable-acp-stdio.mjs')
    const input = new PassThrough(), output = new PassThrough()
    const approval = { jsonrpc: '2.0', id: 'approval', method: 'session/request_permission', params: { sessionId: 'native' } }
    const reply = { jsonrpc: '2.0', id: 'approval', result: { outcome: { outcome: 'selected', optionId: 'allow' } } }
    const state = { session: { sessionId: 'native' }, busy: true, pendingRequests: [approval], recoveredRuns: [{ runID: 'saved-run', content: 'Done' }] }
    let settle
    const settled = new Promise(resolve => { settle = resolve })
    const messages = [], delivered = []
    output.on('data', data => {
      for (const line of data.toString().trim().split('\n')) {
        const message = JSON.parse(line)
        messages.push(message)
        if (message.id === 'approval') {
          // The load deadline is already exhausted before the user responds.
          setImmediate(() => { if (!input.writableEnded) input.write(JSON.stringify(reply) + '\n') })
        } else if (message.id === 1) input.end()
      }
    })
    const request = async (url, options) => {
      if (url.endsWith('/message')) {
        delivered.push(JSON.parse(options.body).message)
        state.busy = false; state.pendingRequests = []
        settle()
        return { ok: true, json: async () => ({ accepted: true }) }
      }
      if (url.endsWith('/poll') && state.busy) {
        await Promise.race([settled, new Promise((_, reject) => {
          if (options.signal.aborted) reject(options.signal.reason)
          else options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true })
        })])
      }
      return { ok: true, json: async () => ({ state: 'running', attachmentToken: 'fixture-attachment', snapshot: structuredClone(state), events: [] }) }
    }
    input.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'session/load', params: { sessionId: 'native' } }) + '\n')
    await runStdioRelay({ channelID: 'approval', harnessID, token: 'fixture', input, output, request, loadTimeout: 0 })
    assert.deepEqual(delivered, [reply], 'reattachment must only forward the approval, never a new prompt')
    const result = messages.find(message => message.id === 1)
    assert.equal(result.error, undefined)
    assert.deepEqual(result.result._meta.recoveredRuns, state.recoveredRuns)
  })
}

for (const notifyOnly of [false]) {
  test(`reconnect still times out without a pending dialog (notify only: ${notifyOnly})`, async () => {
    const { runStdioRelay } = await import('../src/durable-acp-stdio.mjs')
    const input = new PassThrough(), output = new PassThrough()
    const messages = []
    output.on('data', data => {
      for (const line of data.toString().trim().split('\n')) {
        const message = JSON.parse(line)
        messages.push(message)
        if (message.id === 1) input.end()
      }
    })
    const request = async (url, options) => {
      if (url.endsWith('/attach')) return { ok: true, json: async () => ({ state: 'running', attachmentToken: 'fixture-attachment', events: [],
        snapshot: { session: { sessionId: 'native' }, busy: true,
          pendingRequests: [] } }) }
      assert.ok(url.endsWith('/poll'), 'timed-out recovery must not send a prompt')
      return await new Promise((_, reject) => {
        if (options.signal.aborted) reject(options.signal.reason)
        else options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true })
      })
    }
    input.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'session/load', params: { sessionId: 'native' } }) + '\n')
    await runStdioRelay({ channelID: 'busy', harnessID: 'test', token: 'fixture', input, output, request, loadTimeout: 0 })
    const result = messages.find(message => message.id === 1)
    assert.match(result.error.message, /still running/)
  })
}

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

test('session shutdown releases waiting polls',async t=>{
  const f=await fixture(t)
  await f.call('attach')
  const waiting=f.call('poll',{after:0,waitMs:10000})
  await new Promise(resolve=>setImmediate(resolve))
  assert.equal(f.relay.hasActiveRuntime('test'), true)
  await f.relay.stopAll()
  assert.equal(f.relay.hasActiveRuntime('test'), false)
  assert.equal((await waiting).state,'stopped')
})
