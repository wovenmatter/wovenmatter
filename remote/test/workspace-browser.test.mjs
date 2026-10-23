import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { createWorkspaceBrowser } from '../src/workspace-browser.mjs'

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

test('frames use only known tabs, bound the current viewport, and detach after capture', async () => {
  const f = fixture(); await f.service.connect(); f.addPage()
  const tab = (await f.service.tabs()).tabs[0]
  await assert.rejects(f.service.frame('http://foreign.invalid'), { statusCode: 400 })
  const frame = await f.service.frame(tab.id)
  assert.equal(frame.tabID, tab.id)
  assert.deepEqual(f.commands[1], { method: 'Page.captureScreenshot', params: {
    format: 'jpeg', quality: 65, captureBeyondViewport: false,
    clip: { x: 12, y: 300, width: 1920, height: 1200, scale: 1 },
  } })
  assert.equal(f.detached, 1)
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
