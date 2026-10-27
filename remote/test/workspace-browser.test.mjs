import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { createWorkspaceBrowser, streamBrowserFrames, browserLaunchOptions } from '../src/workspace-browser.mjs'
import { mkdtemp, mkdir, writeFile, readFile, stat, symlink, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

test('native production launch explicitly enables the sandbox and keeps control on loopback', () => {
  const options = browserLaunchOptions()
  assert.equal(options.chromiumSandbox, true)
  assert.equal(options.headless, true)
  assert.ok(options.args.includes('--remote-debugging-address=127.0.0.1'))
  assert.ok(options.args.every(argument => !/(no-sandbox|disable-setuid-sandbox|disable-namespace-sandbox)/.test(argument)))
  assert.ok(!Object.keys(options.env).some(key => /TOKEN|SECRET|PASSWORD|API_KEY/i.test(key)))
})

test('profile identities have separate directories, browsers and lifecycle and retain legacy default bytes', async t => {
  const root = await mkdtemp(join(tmpdir(), 'wovenmatter-browser-profiles-')), legacy = join(root, 'browser'), profilesRoot = join(root, 'profiles')
  t.after(() => rm(root, { recursive: true, force: true }))
  await mkdir(legacy); await writeFile(join(legacy, 'cookies-fixture'), 'existing browser state')
  const launches = [], contexts = []
  const service = createWorkspaceBrowser({ profile: legacy, profilesRoot, launch: async (directory, options) => {
    const context = Object.assign(new EventEmitter(), { pages: () => [], close: async () => { context.closed = true; context.emit('close') } })
    contexts.push(context); launches.push({ directory, options }); return { context, endpoint: 'ws://127.0.0.1/' + contexts.length }
  } })
  t.after(() => service.close())
  assert.deepEqual(await service.profiles(), { profiles: ['default'] })
  assert.deepEqual(await service.forProfile('work').tabs(), { running: false, tabs: [] })
  assert.equal(launches.length, 0)
  const [one, same, two] = await Promise.all([service.connect(), service.connect(), service.forProfile('work').connect()])
  assert.deepEqual(one, same); assert.notDeepEqual(one, two); assert.equal(launches.length, 2)
  assert.ok(launches.some(value => value.directory === legacy))
  assert.ok(launches.some(value => value.directory === join(profilesRoot, 'work')))
  assert.deepEqual(await service.profiles(), { profiles: ['default', 'work'] })
  assert.equal(await readFile(join(legacy, 'cookies-fixture'), 'utf8'), 'existing browser state')
  for (const directory of [legacy, profilesRoot, join(profilesRoot, 'work')]) assert.equal((await stat(directory)).mode & 0o777, 0o700)
  await service.forProfile('work').close()
  assert.equal(contexts.filter(value => value.closed).length, 1)
  assert.equal((await service.tabs()).running, true)
})

test('invalid and symlinked profiles never launch a browser or escape the profiles directory', async t => {
  const root = await mkdtemp(join(tmpdir(), 'wovenmatter-browser-profiles-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  let launches = 0
  const service = createWorkspaceBrowser({ profilesRoot: join(root, 'profiles'), launch: async () => { launches++; throw Error('must not launch') } })
  t.after(() => service.close())
  for (const profile of ['../escape', '', 'Uppercase', 'a'.repeat(33), 'with space', null]) {
    assert.throws(() => service.forProfile(profile), { statusCode: 400 })
  }
  await mkdir(join(root, 'profiles')); await mkdir(join(root, 'elsewhere'))
  await symlink(join(root, 'elsewhere'), join(root, 'profiles', 'work'))
  await assert.rejects(service.forProfile('work').connect(), { statusCode: 409 })
  assert.equal(launches, 0)
})

function fixture() {
  const context = new EventEmitter(), pages = [], commands = []
  let launches = 0, detached = 0
  const sessions = []
  context.pages = () => pages
  context.close = async () => context.emit('close')
  context.newCDPSession = async () => {
    const session = Object.assign(new EventEmitter(), {
    async send(method, params) {
      commands.push({ method, params })
      return method === 'Page.getLayoutMetrics'
        ? { cssVisualViewport: { pageX: 12, pageY: 300, clientWidth: 4000, clientHeight: 3000 } }
        : { data: Buffer.from('jpeg fixture').toString('base64') }
    },
    async detach() { detached++ },
    })
    sessions.push(session); return session
  }
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
  return { service, addPage, context, commands, sessions, get launches() { return launches }, get detached() { return detached } }
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

test('transient history screenshot failure retries only capture with fresh layout', async () => {
  const f = fixture(); await f.service.connect(); f.addPage()
  const tab = (await f.service.tabs()).tabs[0]
  const createSession = f.context.newCDPSession
  let captures = 0
  f.context.newCDPSession = async () => {
    const cdp = await createSession(), send = cdp.send
    cdp.send = async (method, params) => {
      if (method === 'Page.captureScreenshot' && ++captures === 1) {
        f.commands.push({ method, params })
        throw new Error('cdpSession.send: Protocol error (Page.captureScreenshot): Unable to capture screenshot')
      }
      return send(method, params)
    }
    return cdp
  }
  assert.equal((await f.service.frame(tab.id)).tabID, tab.id)
  assert.equal(captures, 2)
  assert.equal(f.commands.filter(c => c.method === 'Page.getLayoutMetrics').length, 2)
  assert.ok(f.commands.every(c => c.method.startsWith('Page.')))
  assert.equal(f.sessions.length, 1)
  await f.service.close()
})

test('persistent screenshot failure has bounded retries and releases capture ownership', async () => {
  const f = fixture(); await f.service.connect(); f.addPage()
  const tab = (await f.service.tabs()).tabs[0]
  const createSession = f.context.newCDPSession
  let captures = 0
  f.context.newCDPSession = async () => {
    const cdp = await createSession(), send = cdp.send
    cdp.send = async (method, params) => {
      if (method === 'Page.captureScreenshot') {
        captures++
        throw new Error('cdpSession.send: Protocol error (Page.captureScreenshot): Unable to capture screenshot')
      }
      return send(method, params)
    }
    return cdp
  }
  await assert.rejects(f.service.frame(tab.id), { statusCode: 503, message: 'browser_frame_unavailable' })
  assert.equal(captures, 3)
  f.context.newCDPSession = createSession
  assert.equal((await f.service.frame(tab.id)).tabID, tab.id)
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

test('streams keep the newest frame during backpressure and unsubscribe on disconnect', async () => {
  const response = streamResponse(), received = []; let emit, unsubscribed = false
  const browser = { async watch(tab, callback) { emit = callback; callback({ tabID: tab, frameID: '1', imageID: '1', imageBase64: 'jpeg1' }); return () => { unsubscribed = true } } }
  response.write = data => {
    received.push(JSON.parse(data))
    if (received.length === 1) {
      for (let i = 2; i <= 100; i++) emit({ tabID: 'tab', frameID: String(i), imageID: String(i), imageBase64: 'jpeg' + i })
      setTimeout(() => response.emit('drain'), 20)
      return false
    }
    response.emit('close'); return true
  }
  await streamBrowserFrames(browser, 'tab', response)
  assert.deepEqual(received.map(f => f.frameID), ['1', '100'])
  assert.equal(response.headers['Cache-Control'], 'no-store'); assert.equal(unsubscribed, true)
  assert.equal(response.listenerCount('drain'), 0); assert.equal(response.listenerCount('close'), 0)
})

test('a stalled viewer cannot build an unbounded video backlog', async () => {
  const response = streamResponse(); response.writableLength = 4 * 1024 * 1024
  response.write = () => { assert.fail('must not add to a congested socket') }
  await streamBrowserFrames({ watch: async (_, emit) => { emit({ imageID: 'image', imageBase64: 'jpeg' }); return () => {} } }, 'tab', response)
  assert.equal(response.destroyed, true)
})

test('live frame throughput does not prematurely evict a captured gesture identity', async () => {
  const f = fixture(); await f.service.connect(); f.addPage()
  const tab = (await f.service.tabs()).tabs[0], first = await f.service.frame(tab.id)
  for (let i = 0; i < 300; i++) await f.service.frame(tab.id)
  assert.equal((await f.service.action({ actionID: uuid(), tabID: tab.id, frameID: first.frameID, kind: 'key', key: 'a' })).accepted, true)
  await f.service.close()
})


test('viewers share change-driven capture, preserve full-viewport coordinates, and stop on last disconnect', async () => {
  const f = fixture(); await f.service.connect(); const page = f.addPage()
  const tab = (await f.service.tabs()).tabs[0], received = []
  const stop1 = await f.service.watch(tab.id, frame => received.push(frame), assert.fail)
  const stop2 = await f.service.watch(tab.id, frame => received.push(frame), assert.fail)
  assert.equal(f.sessions.length, 1)
  f.sessions[0].emit('Page.screencastFrame', { sessionId: 1, data: 'jpeg', metadata: {
    deviceWidth: 4000, deviceHeight: 3000, pageScaleFactor: 1, offsetTop: 0, scrollOffsetX: 12, scrollOffsetY: 300,
  } })
  assert.equal(received.length, 2)
  await f.service.action({ actionID: uuid(), tabID: tab.id, frameID: received[0].frameID, kind: 'click', x: 0.5, y: 0.5 })
  assert.equal(f.commands.find(c => c.params?.type === 'mousePressed').params.x, 2000)
  stop1(); assert.equal(f.commands.filter(c => c.method === 'Page.stopScreencast').length, 0)
  stop2(); await new Promise(resolve => setImmediate(resolve))
  assert.equal(f.commands.filter(c => c.method === 'Page.stopScreencast').length, 1)
  assert.equal(f.sessions[0].listenerCount('Page.screencastFrame'), 0)
  assert.equal(f.commands.filter(c => c.method === 'Page.captureScreenshot').length, 0)
  await f.service.close()
})

test('live pointer moves while held, releases outside, and rejects a late cancelled press', async () => {
  const f = fixture(); await f.service.connect(); const page = f.addPage()
  const tab = (await f.service.tabs()).tabs[0], frame = await f.service.frame(tab.id)
  const gestureID = uuid()
  const action = kind => ({ actionID: uuid(), gestureID, tabID: tab.id, frameID: frame.frameID, kind, button: 'left', x: 0.2, y: 0.3 })
  await f.service.action(action('pointerDown'))
  assert.equal(f.commands.at(-1).params.type, 'mousePressed')
  await f.service.action({ ...action('pointerMove'), x: 0.8 })
  assert.equal(f.commands.at(-1).params.buttons, 1)
  assert.equal(f.commands.at(-1).params.x, 1536)
  await f.service.action(action('pointerCancel'))
  assert.equal(f.commands.at(-1).params.type, 'mouseReleased'); assert.equal(f.commands.at(-1).params.x, -1)
  await assert.rejects(f.service.action(action('pointerDown')), { statusCode: 409 })
  const next = { ...action('pointerDown'), gestureID: uuid() }
  await f.service.action(next)
  page.emit('framenavigated', page)
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(f.commands.at(-1).params.type, 'mouseReleased')
  await f.service.close()
})


test('cancellation overtakes a suspended move without re-pressing the mouse', async () => {
  const f = fixture(); await f.service.connect(); f.addPage()
  const tab = (await f.service.tabs()).tabs[0], frame = await f.service.frame(tab.id), gestureID = uuid()
  const action = kind => ({ actionID: uuid(), gestureID, tabID: tab.id, frameID: frame.frameID, kind, x: 0.2, y: 0.3 })
  await f.service.action(action('pointerDown'))
  const cdp = f.sessions[0], original = cdp.send.bind(cdp)
  let resume
  cdp.send = async (method, params) => {
    if (method === 'Page.getLayoutMetrics') await new Promise(resolve => { resume = resolve })
    return original(method, params)
  }
  const moving = f.service.action(action('pointerMove'))
  while (!resume) await new Promise(resolve => setImmediate(resolve))
  await f.service.action(action('pointerCancel'))
  resume()
  await assert.rejects(moving, /browser_pointer_cancelled/)
  const mouse = f.commands.filter(c => c.method === 'Input.dispatchMouseEvent')
  assert.equal(mouse.at(-1).params.type, 'mouseReleased')
  assert.equal(mouse.filter(c => c.params.type === 'mouseMoved' && c.params.buttons === 1).length, 0)
  await f.service.close()
})

test('a disconnect during capture startup tears down the late capture session', async () => {
  const f = fixture(); await f.service.connect(); f.addPage()
  const tab = (await f.service.tabs()).tabs[0], response = streamResponse()
  const create = f.context.newCDPSession
  let resume
  f.context.newCDPSession = async () => { await new Promise(resolve => { resume = resolve }); return create() }
  response.write = () => assert.fail('disconnected viewer must not receive frames')
  const streaming = streamBrowserFrames(f.service, tab.id, response)
  response.emit('close'); resume(); await streaming
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(f.detached, 1)
  assert.equal(f.sessions[0].listenerCount('Page.screencastFrame'), 0)
  await f.service.close()
})


for (const cause of ['renderer crash', 'capture session disconnected']) {
  test(`capture terminates instead of renewing stale images after ${cause}`, async () => {
    const f = fixture(); await f.service.connect(); const page = f.addPage()
    const tab = (await f.service.tabs()).tabs[0], failures = []
    await f.service.watch(tab.id, () => {}, error => failures.push(error))
    if (cause === 'renderer crash') page.emit('crash')
    else {
      const cdp = f.sessions[0], send = cdp.send.bind(cdp)
      cdp.send = (method, params) => method === 'Page.screencastFrameAck' ? Promise.reject(Error('Session closed')) : send(method, params)
      cdp.emit('Page.screencastFrame', { sessionId: 1, data: 'jpeg', metadata: {
        deviceWidth: 1280, deviceHeight: 800, pageScaleFactor: 1, offsetTop: 0, scrollOffsetX: 0, scrollOffsetY: 0,
      } })
    }
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(failures.length, 1)
    assert.equal(f.detached, 1)
    assert.equal(page.listenerCount('crash'), 0)
    assert.equal(f.sessions[0].listenerCount('Page.screencastFrame'), 0)
    await f.service.close()
  })
}


test('capture startup rejection still detaches its control session', async () => {
  const f = fixture(); await f.service.connect(); f.addPage()
  const tab = (await f.service.tabs()).tabs[0], create = f.context.newCDPSession
  f.context.newCDPSession = async () => {
    const cdp = await create(), send = cdp.send.bind(cdp)
    cdp.send = (method, params) => method === 'Page.startScreencast' ? Promise.reject(Error('Capture unavailable')) : send(method, params)
    return cdp
  }
  await assert.rejects(f.service.watch(tab.id, () => {}, () => {}), /Capture unavailable/)
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(f.detached, 1)
  assert.equal(f.sessions[0].listenerCount('Page.screencastFrame'), 0)
  await f.service.close()
})


test('cleanup from an obsolete viewer cannot stop replacement capture', async () => {
  const f = fixture(); await f.service.connect(); const page = f.addPage()
  const tab = (await f.service.tabs()).tabs[0]
  const oldStop = await f.service.watch(tab.id, () => {}, () => {})
  page.emit('crash')
  const newStop = await f.service.watch(tab.id, () => {}, assert.fail)
  oldStop()
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(f.detached, 1)
  assert.equal(f.sessions[1].listenerCount('Page.screencastFrame'), 1)
  newStop(); await f.service.close()
})


test('an active drag can use fresh frames after its press frame expires, but cannot cross documents', async t => {
  const f = fixture(); await f.service.connect(); const page = f.addPage()
  const tab = (await f.service.tabs()).tabs[0], first = await f.service.frame(tab.id), gestureID = uuid()
  const action = (kind, frameID) => ({ actionID: uuid(), gestureID, tabID: tab.id, frameID, kind, x: 0.3, y: 0.4 })
  await f.service.action(action('pointerDown', first.frameID))
  const later = Date.now() + 31000
  t.mock.method(Date, 'now', () => later)
  const current = await f.service.frame(tab.id)
  await assert.rejects(f.service.action(action('pointerMove', first.frameID)), /browser_page_changed/)
  assert.equal((await f.service.action(action('pointerMove', current.frameID))).accepted, true)
  assert.equal((await f.service.action(action('pointerUp', current.frameID))).accepted, true)
  await f.service.action(action('pointerDown', current.frameID))
  page.emit('framenavigated', page)
  const navigated = await f.service.frame(tab.id)
  await assert.rejects(f.service.action(action('pointerMove', navigated.frameID)), /browser_pointer_changed/)
  await f.service.close()
})
