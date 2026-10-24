import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { createWorkspaceBrowser, streamBrowserFrames } from '../src/workspace-browser.mjs'

function fixture() {
  const context = new EventEmitter(), pages = [], commands = []
  let launches = 0, detached = 0
  context.pages = () => pages
  context.close = async () => context.emit('close')
  context.newCDPSession = async () => ({
    async send(method, params) {
      commands.push({ method, params })
      return method === 'Page.getLayoutMetrics'
        ? { cssVisualViewport: { pageX: 12, pageY: 300, clientWidth: 4000, clientHeight: 3000 } }
        : { data: Buffer.from('jpeg fixture').toString('base64') }
    },
    async detach() { detached++ },
  })
  const addPage = () => {
    const page = Object.assign(new EventEmitter(), { closed: false, isClosed() { return this.closed }, title: async () => 'Remote tab',
      url: () => 'http://127.0.0.1:3000', context: () => context })
    page.mainFrame = () => page
    pages.push(page)
    return page
  }
  const service = createWorkspaceBrowser({ profile: '/unused', launch: async () => {
    launches++
    await new Promise(resolve => setImmediate(resolve))
    return { context, endpoint: 'ws://127.0.0.1:4000/devtools/browser/fixture' }
  } })
  return { service, addPage, context, commands, get launches() { return launches }, get detached() { return detached } }
}

test('viewing is lazy, concurrent agents share one browser, crash permits a fresh launch', async () => {
  const f = fixture()
  assert.deepEqual(await f.service.tabs(), { running: false, tabs: [] })
  assert.equal(f.launches, 0)
  const connections = await Promise.all([f.service.connect(), f.service.connect()])
  assert.deepEqual(connections[0], connections[1]); assert.equal(f.launches, 1)
  const page = f.addPage(), first = (await f.service.tabs()).tabs[0]
  assert.equal((await f.service.tabs()).tabs[0].id, first.id)
  page.closed = true
  assert.deepEqual((await f.service.tabs()).tabs, [])
  await assert.rejects(f.service.frame(first.id), { statusCode: 410 })
  f.context.emit('close')
  assert.equal((await f.service.tabs()).running, false)
  await f.service.connect(); assert.equal(f.launches, 2)
  await f.service.close()
  await assert.rejects(f.service.connect(), { statusCode: 503 })
})

test('frames use only known tabs, bound the current viewport, and reuse the control session until page closure', async () => {
  const f = fixture(); await f.service.connect(); f.addPage()
  const tab = (await f.service.tabs()).tabs[0]
  await assert.rejects(f.service.frame('http://foreign.invalid'), { statusCode: 400 })
  const frame = await f.service.frame(tab.id)
  assert.equal(frame.tabID, tab.id)
  assert.deepEqual(f.commands[1], { method: 'Page.captureScreenshot', params: {
    format: 'jpeg', quality: 65, optimizeForSpeed: true, captureBeyondViewport: false,
    clip: { x: 12, y: 300, width: 1920, height: 1200, scale: 1 },
  } })
  assert.equal(f.detached, 0)
  assert.ok(f.commands.every(({ method }) => !/navigate|bringToFront|Input|Emulation/.test(method)))
  await f.service.close()
})

test('failed and overlapping frames do not wedge future viewing', async () => {
  const f = fixture(); await f.service.connect(); f.addPage()
  const tab = (await f.service.tabs()).tabs[0]
  let release
  f.context.newCDPSession = async () => {
    await new Promise(resolve => { release = resolve })
    throw new Error('page navigated')
  }
  const pending = f.service.frame(tab.id)
  await assert.rejects(f.service.frame(tab.id), { statusCode: 409 })
  release()
  await assert.rejects(pending, /page navigated/)
  f.context.newCDPSession = async () => { throw new Error('next capture attempted') }
  await assert.rejects(f.service.frame(tab.id), /next capture attempted/)
  await f.service.close()
})

const uuid = () => globalThis.crypto.randomUUID()
test('input targets the captured page, maps coordinates, serializes and refuses stale or duplicate gestures', async () => {
  const f = fixture(); await f.service.connect(); const page = f.addPage()
  const tab = (await f.service.tabs()).tabs[0], frame = await f.service.frame(tab.id)
  const action = { actionID: uuid(), tabID: tab.id, frameID: frame.frameID, kind: 'click', x: 0.5, y: 0.25 }
  assert.equal((await f.service.action(action)).accepted, true)
  const down = f.commands.find(c => c.method === 'Input.dispatchMouseEvent' && c.params.type === 'mousePressed')
  assert.equal(down.params.x, 960); assert.equal(down.params.y, 300)
  assert.equal(f.commands.at(-1).params.type, 'mouseReleased')
  await assert.rejects(f.service.action(action), {statusCode: 409})
  page.emit('framenavigated', page)
  await assert.rejects(f.service.action({...action, actionID: uuid()}), {statusCode: 409})
  await assert.rejects(f.service.action({...action, x: 2}), {statusCode: 400})
  await assert.rejects(f.service.action({...action, kind: 'navigate', text: 'javascript:alert(1)'}), {statusCode: 400})
  await f.service.close()
})

test('keyboard modifiers and text are sent only to the explicit live tab', async () => {
  const f = fixture(); await f.service.connect(); f.addPage()
  const tab = (await f.service.tabs()).tabs[0], frame = await f.service.frame(tab.id)
  const action = { actionID: uuid(), tabID: tab.id, frameID: frame.frameID, kind: 'key', key: 'a', modifiers: 2 }
  await f.service.action(action)
  assert.equal(f.commands.at(-2).params.type, 'keyDown')
  assert.deepEqual(f.commands.at(-2).params.commands, ['selectAll'])
  assert.equal(f.commands.at(-1).params.type, 'keyUp')
  await f.service.action({...action, actionID: uuid(), kind: 'text', text: 'A person and agent share this input'})
  assert.equal(f.commands.at(-1).method, 'Input.insertText')
  await assert.rejects(f.service.action({...action, actionID: uuid(), kind: 'text', text: 'x'.repeat(16385)}), {statusCode: 400})
  await f.service.close()
})


test('input batches preserve DOM key events, stop after navigation, and never replay partial delivery', async () => {
  const f = fixture(); await f.service.connect(); const page = f.addPage()
  const tab = (await f.service.tabs()).tabs[0], frame = await f.service.frame(tab.id)
  const actions = ['a', 'b', 'c'].map(key => ({ actionID: uuid(), tabID: tab.id, frameID: frame.frameID, kind: 'key', key, text: key }))
  assert.equal((await f.service.actions(actions)).results.length, 3)
  assert.deepEqual(f.commands.filter(c => c.method === 'Input.dispatchKeyEvent' && c.params.type === 'keyDown').map(c => c.params.text), ['a', 'b', 'c'])
  await assert.rejects(f.service.actions(actions), { statusCode: 409 })
  await assert.rejects(f.service.actions(Array(33).fill(actions[0])), { statusCode: 400 })
  const next = actions.map(a => ({ ...a, actionID: uuid() }))
  // An explicit navigation invalidates every remaining captured-frame gesture.
  page.goto = async () => page.emit('framenavigated', page)
  await assert.rejects(f.service.actions([{ ...next[0], kind: 'navigate', text: 'https://example.test' }, next[1]]), { statusCode: 409 })
  assert.equal(f.commands.filter(c => c.params?.text === 'b').length, 1)
  await f.service.close()
})

test('unchanged images omit JPEG bytes but renew input identity; navigation forces a fresh image', async () => {
  const f = fixture(); await f.service.connect(); const page = f.addPage()
  const tab = (await f.service.tabs()).tabs[0], first = await f.service.frame(tab.id)
  const next = await f.service.frame(tab.id, first.frameID)
  assert.equal(next.imageBase64, ''); assert.notEqual(next.frameID, first.frameID)
  assert.equal(next.imageID, first.imageID)
  await f.service.action({ actionID: uuid(), tabID: tab.id, frameID: next.frameID, kind: 'key', key: 'a' })
  page.emit('framenavigated', page)
  const navigated = await f.service.frame(tab.id, next.frameID)
  assert.ok(navigated.imageBase64); assert.notEqual(navigated.imageID, next.imageID)
  await f.service.close()
})


function streamResponse() {
  const response = new EventEmitter()
  response.writableLength = 0
  response.writeHead = (status, headers) => { response.headersSent = true; response.status = status; response.headers = headers }
  response.flushHeaders = () => {}
  response.destroy = () => { response.destroyed = true; response.emit('close') }
  return response
}

test('live frames recover from capture contention and stop as soon as the viewer disconnects', async () => {
  const response = streamResponse(), received = []; let captures = 0
  const browser = { async frame() {
    captures++
    if (captures < 3) throw Object.assign(Error('busy'), { statusCode: 409 })
    return { tabID: 'tab', frameID: String(captures), imageBase64: 'jpeg' }
  } }
  response.write = data => { received.push(JSON.parse(data)); response.emit('close'); return true }
  await streamBrowserFrames(browser, 'tab', response)
  assert.equal(captures, 3); assert.equal(received.length, 1)
  assert.equal(response.headers['Cache-Control'], 'no-store')
  assert.equal(response.listenerCount('close'), 0)
})

test('a stalled viewer cannot build an unbounded video backlog', async () => {
  const response = streamResponse(); response.writableLength = 4 * 1024 * 1024
  response.write = () => { assert.fail('must not add to a congested socket') }
  await streamBrowserFrames({ frame: async () => ({ imageBase64: 'jpeg' }) }, 'tab', response)
  assert.equal(response.destroyed, true)
})


test('network backpressure waits for drain before capturing another image', async () => {
  const response = streamResponse(); let captures = 0, writes = 0
  const browser = { frame: async () => { captures++; return { imageBase64: 'jpeg' } } }
  response.write = () => {
    if (++writes === 1) {
      setTimeout(() => { assert.equal(captures, 1); response.emit('drain') }, 80)
      return false
    }
    response.emit('close'); return true
  }
  await streamBrowserFrames(browser, 'tab', response)
  assert.equal(captures, 2); assert.equal(response.listenerCount('drain'), 0)
})


test('live frame throughput does not prematurely evict a captured gesture identity', async () => {
  const f = fixture(); await f.service.connect(); f.addPage()
  const tab = (await f.service.tabs()).tabs[0], first = await f.service.frame(tab.id)
  for (let i = 0; i < 300; i++) await f.service.frame(tab.id)
  assert.equal((await f.service.action({ actionID: uuid(), tabID: tab.id, frameID: first.frameID, kind: 'key', key: 'a' })).accepted, true)
  await f.service.close()
})
