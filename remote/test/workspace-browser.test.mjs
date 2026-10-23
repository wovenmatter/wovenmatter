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
    const page = { closed: false, isClosed() { return this.closed }, title: async () => 'Remote tab',
      url: () => 'http://127.0.0.1:3000', context: () => context }
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
