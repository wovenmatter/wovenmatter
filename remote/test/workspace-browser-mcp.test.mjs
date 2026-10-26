import test from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { createWorkspaceBrowserMCP } from '../src/workspace-browser-mcp.mjs'

function fixture() {
  const calls = [], locks = new Set(), pages = new Map(), connections = []
  const context = { newCDPSession: async page => ({ send: async () => ({ targetInfo: { targetId: page.target } }), detach: async () => {} }) }
  const add = () => {
    const id = randomUUID(), page = { target: randomUUID(), id, context: () => context, isClosed: () => false,
      url: () => 'https://same.example/', on() {}, mouse: { up: async () => {} } }
    pages.set(id, page); return page
  }
  const first = add(), second = add()
  let pending, execute = async (page, input) => { calls.push({ page, input }); return { content: [{ type: 'image', mimeType: 'image/jpeg', data: 'fixture' }] } }
  const service = createWorkspaceBrowserMCP({
    tabs: async () => ({ tabs: [...pages.values()].map(page => ({ id: page.id, url: page.url() })) }),
    connect: async () => ({ endpoint: 'ws://127.0.0.1:1234/private' }),
    locate: async id => { assert.ok(pages.has(id)); return { id, page: pages.get(id) } },
    createPage: async () => { const page = add(); return { id: page.id, page } },
    claim: page => { assert.ok(!locks.has(page)); locks.add(page); return () => locks.delete(page) },
    loadRuntime: async () => ({
      browserAction: (...args) => execute(...args),
      connect: async endpoint => {
        assert.equal(endpoint, 'ws://127.0.0.1:1234/private')
        const browser = { contexts: () => [{ pages: () => [...pages.values()].reverse() }], async close() { browser.closed = true; pending?.reject(Error('Connection closed')) } }
        connections.push(browser); return browser
      },
    }),
  })
  return { service, first, second, calls, connections, locks,
    suspend() { execute = () => new Promise((resolve, reject) => { pending = { resolve, reject } }); return () => pending },
  }
}

test('MCP browser resolves an exact shared tab, returns inline content, and retains identical retry receipts', async t => {
  const f = fixture(); t.after(() => f.service.close())
  const scope = { conversationID: randomUUID() }, input = { action: 'screenshot', tabId: f.first.id, requestID: randomUUID() }
  const result = await f.service.execute(scope, input)
  assert.equal(result.content[0].type, 'image')
  assert.equal(f.calls[0].page, f.first, 'same-URL tabs must resolve by CDP target identity')
  assert.deepEqual(await f.service.execute(scope, input), result)
  assert.equal(f.calls.length, 1); assert.equal(f.connections[0].closed, true); assert.equal(f.locks.size, 0)
  await assert.rejects(f.service.execute(scope, { ...input, action: 'click' }), /different browser operation/)
  assert.equal(JSON.parse((await f.service.execute(scope, { action: 'tabs', requestID: randomUUID() })).content[0].text).length, 2)
})

test('caller-owned cancellation disconnects pending input and preserves shared tabs and other callers', async t => {
  const f = fixture(); t.after(() => f.service.close())
  const pending = f.suspend(), scope = { conversationID: randomUUID() }, id = randomUUID()
  const operation = f.service.execute(scope, { action: 'click', selector: '#later', tabId: f.first.id, requestID: id })
  const rejected = assert.rejects(operation, /interrupted/)
  for(let attempt=0;!pending()&&attempt<100;attempt++)await new Promise(resolve => setImmediate(resolve))
  assert.ok(pending(), 'browser operation started')
  assert.deepEqual(await f.service.cancel({ conversationID: randomUUID() }, 'all'), { cancelled: 0 })
  assert.equal(f.connections[0].closed, undefined)
  assert.deepEqual(await f.service.cancel(scope, id), { cancelled: 1 })
  await rejected
  assert.equal(f.connections[0].closed, true); assert.equal(f.first.isClosed(), false); assert.equal(f.locks.size, 0)
})
