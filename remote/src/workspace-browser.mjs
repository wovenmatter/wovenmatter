import { existsSync } from 'node:fs'
import { mkdir, readFile, rm, readdir, lstat, realpath, chmod } from 'node:fs/promises'
import { randomUUID, createHash } from 'node:crypto'
import { join, resolve } from 'node:path'
import { createWorkspaceBrowserMCP } from './workspace-browser-mcp.mjs'

const failure = (statusCode, message) => Object.assign(new Error(message), { statusCode })
async function deadline(operation, milliseconds = 5000) {
  let timer
  try {
    return await Promise.race([operation(), new Promise((_, reject) => {
      timer = setTimeout(() => reject(failure(503, 'browser_timed_out')), milliseconds)
    })])
  } finally { clearTimeout(timer) }
}

export function browserLaunchOptions({ runtimeKind = 'host' } = {}) {
  return {
    headless: true, viewport: { width: 1280, height: 800 }, timeout: 15000,
    // Native hosts always use Chromium's namespace/seccomp sandbox. Existing
    // containers keep their established launch contract until their additional
    // seccomp/AppArmor policy can be validated without weakening containment.
    ...(runtimeKind === 'host' ? { chromiumSandbox: true } : {}),
    args: ['--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0'],
    env: Object.fromEntries(Object.entries(process.env).filter(([key]) =>
      !/TOKEN|SECRET|PASSWORD|API_KEY/i.test(key))),
  }
}

async function browserRuntime() {
  const bundled = new URL('../default-agent/node_modules/playwright-core/index.mjs', import.meta.url)
  return await import(existsSync(bundled) ? bundled.href
    : new URL('../../default-agent/node_modules/playwright-core/index.mjs', import.meta.url).href)
}

export async function browserExecutablePath() { return (await browserRuntime()).chromium.executablePath() }

export async function launchBrowser(profile, options = {}) {
  const { chromium } = await browserRuntime()
  await mkdir(profile, { recursive: true, mode: 0o700 })
  await rm(join(profile, 'DevToolsActivePort'), { force: true })
  const context = await chromium.launchPersistentContext(profile, browserLaunchOptions(options))
  try {
    const [port, path] = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).trim().split('\n')
    if (!/^\d+$/.test(port) || +port < 1 || +port > 65535 || !/^\/devtools\/browser\/[a-zA-Z0-9-]+$/.test(path)) {
      throw failure(503, 'browser_endpoint_unavailable')
    }
    return { context, endpoint: `ws://127.0.0.1:${port}${path}`, executablePath: chromium.executablePath() }
  } catch (error) { await context.close(); throw error }
}

// One workspace-owned browser: agents and people operate the same pages.
// Opening the app viewer is passive; only explicit input changes a page. CDP stays on loopback.
function createProfileBrowser({ profile, launch }) {
  let active, starting, closed = false
  const capturing = new Set()
  const pages = new Map(), ids = new WeakMap(), documents = new WeakMap(), frames = new Map(), receipts = new Map()
  const acting = new Set(), sessions = new Map(), casts = new Map(), pointers = new Map(), cancelledPointers = new Set()
  async function sessionFor(page) {
    if (!sessions.has(page)) {
      const pending = page.context().newCDPSession(page)
      sessions.set(page, pending)
      pending.catch(() => { if (sessions.get(page) === pending) sessions.delete(page) })
    }
    return sessions.get(page)
  }
  function discardSession(page) {
    const pending = sessions.get(page)
    sessions.delete(page)
    void pending?.then(cdp => cdp.detach()).catch(() => {})
  }
  async function releasePointer(page, gestureID, cancel = true) {
    if (gestureID && cancel) {
      cancelledPointers.add(gestureID)
      while (cancelledPointers.size > 1024) cancelledPointers.delete(cancelledPointers.values().next().value)
    }
    const pointer = pointers.get(page)
    if (!pointer || (gestureID && pointer.gestureID !== gestureID)) return
    pointers.delete(page); clearTimeout(pointer.timer)
    const event = { ...pointer.event, ...(cancel ? { x: -1, y: -1 } : {}), buttons: 0 }
    await deadline(async () => {
      if (cancel) await pointer.cdp.send('Input.dispatchMouseEvent', { ...event, type: 'mouseMoved' }).catch(() => {})
      await pointer.cdp.send('Input.dispatchMouseEvent', { ...event, type: 'mouseReleased' }).catch(() => {})
    }, 1000).catch(() => {})
  }
  function renewPointer(page, pointer) {
    clearTimeout(pointer.timer)
    pointer.timer = setTimeout(() => { void releasePointer(page, pointer.gestureID) }, 15000)
    pointer.timer.unref?.()
  }
  function recordFrame(page, document, viewport, data, width, height) {
    const tabID = ids.get(page), frameID = randomUUID()
    const digest = createHash('sha256').update(data).digest('hex')
    frames.set(frameID, { page, document, viewport, width, height, digest, created: Date.now() })
    while (frames.size && (frames.size > 8192 || frames.values().next().value.created < Date.now() - 30000)) {
      frames.delete(frames.keys().next().value)
    }
    return { tabID, frameID, imageID: document + ':' + digest, imageBase64: data }
  }
  function stopCast(page) {
    const cast = casts.get(page)
    if (!cast) return
    casts.delete(page); void releasePointer(page); cast.stopped = true; clearInterval(cast.heartbeat)
    page.off('close', cast.closed); page.off('crash', cast.closed)
    for (const listener of cast.listeners) listener.fail(failure(410, 'browser_tab_closed'))
    cast.listeners.clear()
    const cdp = cast.cdp
    if (cdp) {
      cdp.off('Page.screencastFrame', cast.receive)
      // Do not await a failed or wedged start command before cleaning up.
      void deadline(() => cdp.send('Page.stopScreencast'), 1000).catch(() => {})
        .then(() => cdp.detach()).catch(() => {})
    }
  }
  function forget(session) {
    if (active !== session) return
    active = undefined
    for (const page of casts.keys()) stopCast(page)
    pages.clear(); frames.clear(); receipts.clear(); sessions.clear()
  }
  function inventory() {
    const current = active?.context.pages().filter(page => !page.isClosed()).slice(0, 64) ?? []
    for (const [id, page] of pages) if (!current.includes(page)) { pages.delete(id); discardSession(page) }
    return current.map(page => {
      if (!ids.has(page)) {
        ids.set(page, randomUUID()); documents.set(page, randomUUID())
        page.once('close', () => { void releasePointer(page); discardSession(page) })
        page.on('framenavigated', frame => {
          if (frame === page.mainFrame()) { documents.set(page, randomUUID()); void releasePointer(page) }
        })
      }
      const id = ids.get(page)
      pages.set(id, page)
      return { id, page }
    })
  }
  const api = {
    async connect() {
      if (closed) throw failure(503, 'browser_unavailable')
      if (!active && !starting) {
        starting = launch(profile).then(session => {
          active = session
          session.context.once('close', () => forget(session))
          return session
        }).finally(() => { starting = undefined })
      }
      const session = active ?? await starting
      if (closed) throw failure(503, 'browser_unavailable')
      return { endpoint: session.endpoint }
    },
    async tabs() {
      const session = active
      const tabs = await Promise.all(inventory().map(async ({ id, page }) => ({
        id, url: page.url().slice(0, 4096),
        title: (await deadline(() => page.title(), 1500).catch(() => '')).slice(0, 512),
      })))
      return active === session ? { running: !!session, tabs } : { running: false, tabs: [] }
    },
    async watch(tabID, emit, fail) {
      inventory()
      const page = pages.get(tabID)
      if (!page) throw failure(410, 'browser_tab_closed')
      let cast = casts.get(page)
      if (!cast) {
        cast = { listeners: new Set(), stopped: false }
        casts.set(page, cast)
        cast.closed = () => stopCast(page)
        page.once('close', cast.closed); page.once('crash', cast.closed)
        cast.receive = event => {
          if (cast.stopped) return
          // ACK promptly; retaining only the newest frame prevents a playback queue.
          void cast.cdp.send('Page.screencastFrameAck', { sessionId: event.sessionId }).catch(() => { if (!cast.stopped) stopCast(page) })
          const m = event.metadata
          if (!m || ![m.deviceWidth, m.deviceHeight, m.pageScaleFactor, m.scrollOffsetX, m.scrollOffsetY, m.offsetTop].every(Number.isFinite)
              || m.deviceWidth <= 0 || m.deviceHeight <= 0 || m.pageScaleFactor <= 0 || m.offsetTop !== 0
              || typeof event.data !== 'string' || event.data.length > 2 * 1024 * 1024) {
            for (const listener of cast.listeners) listener.fail(failure(503, 'browser_frame_unavailable'))
            stopCast(page); return
          }
          const viewport = { pageX: m.scrollOffsetX, pageY: m.scrollOffsetY,
            clientWidth: m.deviceWidth / m.pageScaleFactor, clientHeight: m.deviceHeight / m.pageScaleFactor }
          const document = documents.get(page)
          cast.latest = { document, viewport, data: event.data }
          const frame = recordFrame(page, document, viewport, event.data, viewport.clientWidth, viewport.clientHeight)
          for (const listener of cast.listeners) listener.emit(frame)
        }
        cast.start = (async () => {
          cast.cdp = await page.context().newCDPSession(page)
          if (cast.stopped) { await cast.cdp.detach().catch(() => {}); return }
          cast.cdp.on('Page.screencastFrame', cast.receive)
          await cast.cdp.send('Page.startScreencast', { format: 'jpeg', quality: 65, maxWidth: 1920, maxHeight: 1200, everyNthFrame: 1 })
        })()
        cast.heartbeat = setInterval(() => {
          const latest = cast.latest
          if (!latest || cast.stopped || latest.document !== documents.get(page)) return
          const frame = recordFrame(page, latest.document, latest.viewport, latest.data, latest.viewport.clientWidth, latest.viewport.clientHeight)
          for (const listener of cast.listeners) listener.emit(frame)
        }, 2000)
        cast.heartbeat.unref?.()
      }
      const listener = { emit, fail }
      cast.listeners.add(listener)
      try { await deadline(() => cast.start) }
      catch (error) { if (!cast.stopped) stopCast(page); throw error }
      if (cast.latest && cast.latest.document === documents.get(page)) {
        const { document, viewport, data } = cast.latest
        emit(recordFrame(page, document, viewport, data, viewport.clientWidth, viewport.clientHeight))
      }
      return () => { cast.listeners.delete(listener); if (!cast.stopped && !cast.listeners.size) stopCast(page) }
    },
    async frame(tabID, previousFrameID) {
      if (typeof tabID !== 'string' || !/^[0-9a-f-]{36}$/.test(tabID)) throw failure(400, 'invalid_browser_tab')
      inventory()
      const page = pages.get(tabID)
      if (!page) throw failure(410, 'browser_tab_closed')
      if (capturing.has(page)) throw failure(409, 'browser_busy')
      capturing.add(page)
      let cdp, expired = false, succeeded = false
      try {
        return await deadline(async () => {
          cdp = await sessionFor(page)
          if (expired) { await cdp.detach().catch(() => {}); throw failure(503, 'browser_timed_out') }
          for (let attempt = 0; attempt < 3; attempt++) {
            if (expired) throw failure(503, 'browser_timed_out')
            const { cssVisualViewport: viewport } = await cdp.send('Page.getLayoutMetrics')
            if (!viewport || ![viewport.pageX, viewport.pageY, viewport.clientWidth, viewport.clientHeight].every(Number.isFinite)
                || viewport.clientWidth <= 0 || viewport.clientHeight <= 0) throw failure(503, 'browser_frame_unavailable')
            if (expired) throw failure(503, 'browser_timed_out')
            const document = documents.get(page)
            let data
            try { ({ data } = await cdp.send('Page.captureScreenshot', {
              format: 'jpeg', quality: 65, optimizeForSpeed: true, captureBeyondViewport: false,
              clip: { x: viewport.pageX, y: viewport.pageY, width: Math.min(viewport.clientWidth, 1920),
                height: Math.min(viewport.clientHeight, 1200), scale: 1 },
            })) } catch (error) {
              // Chromium can briefly lack a screenshot surface after history restoration.
              // Retry only this read, with fresh layout metrics, within the same deadline.
              if (!String(error?.message).includes('Protocol error (Page.captureScreenshot): Unable to capture screenshot')) throw error
              if (attempt === 2) throw failure(503, 'browser_frame_unavailable')
              await new Promise(resolve => setTimeout(resolve, 16 * (attempt + 1)))
              continue
            }
            if (expired) throw failure(503, 'browser_timed_out')
            if (data.length > 2 * 1024 * 1024) throw failure(413, 'browser_frame_too_large')
            if (page.isClosed() || pages.get(tabID) !== page) throw failure(410, 'browser_tab_closed')
            if (document !== documents.get(page)) throw failure(409, 'browser_page_changed')
            const previous = frames.get(previousFrameID)
            const frame = recordFrame(page, document, viewport, data, Math.min(viewport.clientWidth, 1920), Math.min(viewport.clientHeight, 1200))
            const unchanged = previous?.page === page && previous.document === document
              && previous.digest === frames.get(frame.frameID).digest
            succeeded = true
            return { ...frame, imageBase64: unchanged ? '' : data }
          }
        })
      } finally {
        expired = true
        if (!succeeded) discardSession(page)
        capturing.delete(page)
      }
    },
    async actions(requests) {
      if (!Array.isArray(requests) || !requests.length || requests.length > 32
          || Buffer.byteLength(JSON.stringify(requests)) > 65536) throw failure(400, 'invalid_browser_actions')
      requests.forEach(validateAction)
      if (requests.some(r => r.tabID !== requests[0].tabID)) throw failure(400, 'invalid_browser_actions')
      inventory()
      const page = pages.get(requests[0].tabID)
      if (!page) throw failure(410, 'browser_tab_closed')
      if (acting.has(page)) throw failure(409, 'browser_busy')
      acting.add(page)
      try {
        const results = [], expires = performance.now() + 5000
        // Stop at the first rejected gesture. Never replay a partially delivered batch.
        for (const request of requests) {
          if (performance.now() >= expires) throw failure(503, 'browser_timed_out')
          results.push(await api.action(request, page, expires))
        }
        return { results }
      } finally { acting.delete(page) }
    },
    async action(request, batchPage, expires = performance.now() + 5000) {
      validateAction(request)
      inventory()
      const { tabID, frameID, actionID } = request, page = pages.get(tabID)
      if (!page) throw failure(410, 'browser_tab_closed')
      if (request.kind === 'pointerCancel') {
        await releasePointer(page, request.gestureID)
        return { tabID, accepted: true }
      }
      const frame = frames.get(frameID)
      if (!frame || frame.page !== page || frame.document !== documents.get(page) || Date.now() - frame.created > 30000) {
        throw failure(409, 'browser_page_changed')
      }
      const digest = createHash('sha256').update(JSON.stringify(request)).digest('hex')
      if (receipts.has(actionID)) {
        if (receipts.get(actionID) !== digest) throw failure(409, 'browser_action_reused')
        // Never repeat an input whose acknowledgement may have been lost.
        throw failure(409, 'browser_action_already_submitted')
      }
      if (acting.has(page) && batchPage !== page) throw failure(409, 'browser_busy')
      receipts.set(actionID, digest)
      while (receipts.size > 1024) receipts.delete(receipts.keys().next().value)
      acting.add(page)
      let cdp, expired = false, heldButton, heldKey, succeeded = false
      try {
        return await deadline(async () => {
          cdp = await sessionFor(page)
          if (expired) { await cdp.detach().catch(() => {}); throw failure(503, 'browser_timed_out') }
          const send = async (method, params) => {
            if (expired || page.isClosed() || documents.get(page) !== frame.document) throw failure(409, 'browser_page_changed')
            if (request.gestureID && cancelledPointers.has(request.gestureID)) throw failure(409, 'browser_pointer_cancelled')
            return cdp.send(method, params)
          }
          const { kind, x, y, modifiers = 0 } = request
          if (['pointerDown', 'pointerMove', 'pointerUp'].includes(kind)) {
            let pointer = pointers.get(page)
            if (cancelledPointers.has(request.gestureID)) throw failure(409, 'browser_pointer_cancelled')
            if (kind === 'pointerDown' ? !!pointer : !pointer || pointer.gestureID !== request.gestureID || pointer.document !== frame.document) {
              throw failure(409, 'browser_pointer_changed')
            }
            const { cssVisualViewport: current } = await send('Page.getLayoutMetrics')
            const fields = kind === 'pointerDown' ? ['pageX', 'pageY', 'clientWidth', 'clientHeight'] : ['clientWidth', 'clientHeight']
            if (!current || fields.some(key => Math.abs(current[key] - frame.viewport[key]) > 1)) throw failure(409, 'browser_page_changed')
            const event = { x: x * frame.width, y: y * frame.height, modifiers, button: request.button ?? 'left', clickCount: request.clickCount ?? 1 }
            if (kind === 'pointerDown') {
              if (cancelledPointers.has(request.gestureID)) throw failure(409, 'browser_pointer_cancelled')
              pointer = { cdp, event, document: frame.document, gestureID: request.gestureID }
              pointers.set(page, pointer); renewPointer(page, pointer)
              await send('Input.dispatchMouseEvent', { ...event, type: 'mouseMoved', buttons: 0 })
              if (cancelledPointers.has(request.gestureID)) throw failure(409, 'browser_pointer_cancelled')
              await send('Input.dispatchMouseEvent', { ...event, type: 'mousePressed', buttons: event.button === 'left' ? 1 : 2 })
            } else {
              if (pointer.event.button !== event.button) throw failure(400, 'invalid_browser_action')
              pointer.event = event; renewPointer(page, pointer)
              if (kind === 'pointerUp') await releasePointer(page, request.gestureID, false)
              else await send('Input.dispatchMouseEvent', { ...event, type: 'mouseMoved', buttons: event.button === 'left' ? 1 : 2 })
            }
          } else if (['click', 'drag', 'move', 'scroll'].includes(kind)) {
            const { cssVisualViewport: current } = await send('Page.getLayoutMetrics')
            if (!current || (kind === 'scroll' ? ['clientWidth', 'clientHeight'] : ['pageX', 'pageY', 'clientWidth', 'clientHeight']).some(key => Math.abs(current[key] - frame.viewport[key]) > 1)) {
              throw failure(409, 'browser_page_changed')
            }
            const width = frame.width, height = frame.height
            const point = (px, py) => ({ x: px * width, y: py * height })
            const position = point(x, y)
            await send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...position, modifiers })
            if (kind === 'scroll') {
              await send('Input.dispatchMouseEvent', { type: 'mouseWheel', ...position, modifiers, deltaX: request.deltaX, deltaY: request.deltaY })
            } else if (kind !== 'move') {
              const button = request.button ?? 'left', buttons = button === 'left' ? 1 : 2
              const clickCount = request.clickCount ?? 1
              heldButton = { ...position, button, modifiers, clickCount }
              await send('Input.dispatchMouseEvent', { type: 'mousePressed', ...heldButton, buttons })
              if (kind === 'drag') {
                for (let i = 1; i <= 8; i++) {
                  const next = point(x + (request.endX - x) * i / 8, y + (request.endY - y) * i / 8)
                  heldButton = { ...heldButton, ...next }
                  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...heldButton, buttons })
                }
              }
              // Release even if a press navigates or the operation times out.
              await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...heldButton, buttons: 0 })
              heldButton = undefined
            }
          } else if (kind === 'copy') {
            let text = ''
            for (const target of page.frames()) {
              if (expired || documents.get(page) !== frame.document) throw failure(409, 'browser_page_changed')
              const selection = await target.evaluate(() => {
                if (!document.hasFocus()) return ''
                let element = document.activeElement
                while (element?.shadowRoot?.activeElement) element = element.shadowRoot.activeElement
                if (element && ['IFRAME', 'FRAME'].includes(element.tagName)) return ''
                if (element && ['INPUT', 'TEXTAREA'].includes(element.tagName) && typeof element.selectionStart === 'number') {
                  return element.value.slice(element.selectionStart, element.selectionEnd).slice(0, 16384)
                }
                return String(window.getSelection() ?? '').slice(0, 16384)
              }).catch(() => '')
              if (selection) { text = selection; break }
            }
            if (expired || documents.get(page) !== frame.document) throw failure(409, 'browser_page_changed')
            succeeded = true
            return { tabID, accepted: true, text }
          } else if (kind === 'text') {
            await send('Input.insertText', { text: request.text })
          } else if (kind === 'key') {
            const [code, windowsVirtualKeyCode] = keyInfo(request.key)
            const editingCommand = (modifiers & 2) && !(modifiers & 1)
              ? ({ a: 'selectAll', z: modifiers & 8 ? 'redo' : 'undo' })[request.key.toLowerCase()] : undefined
            heldKey = editingCommand ? { key: 'Unidentified' } : { key: request.key, code, windowsVirtualKeyCode, modifiers }
            await send('Input.dispatchKeyEvent', { type: 'keyDown', ...heldKey, ...(editingCommand ? { commands: [editingCommand] } : {}),
              ...(request.text && !(modifiers & 7) ? { text: request.text } : request.key === 'Enter' && modifiers === 0 ? { text: '\r' } : {}) })
            await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', ...heldKey })
            heldKey = undefined
          } else if (kind === 'navigate') {
            await page.goto(request.text, { waitUntil: 'commit', timeout: 4000 })
          } else if (kind === 'back' || kind === 'forward') {
            await page[kind === 'back' ? 'goBack' : 'goForward']({ waitUntil: 'commit', timeout: 4000 })
          } else if (kind === 'reload') {
            await page.reload({ waitUntil: 'commit', timeout: 4000 })
          }
          succeeded = true
          return { tabID, accepted: true }
        }, Math.max(1, expires - performance.now()))
      } finally {
        expired = true
        if (!succeeded && request.gestureID) await releasePointer(page, request.gestureID)
        if (cdp) {
          await deadline(async () => {
            if (heldButton) await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...heldButton, buttons: 0 }).catch(() => {})
            if (heldKey) await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', ...heldKey }).catch(() => {})
            if (!succeeded) discardSession(page)
          }, 1000).catch(() => {})
        }
        if (!batchPage) acting.delete(page)
      }
    },
    async close() {
      closed = true
      await automation.close()
      await starting?.catch(() => {})
      const session = active
      active = undefined
      for (const page of casts.keys()) stopCast(page)
      await Promise.all([...pointers.keys()].map(page => releasePointer(page)))
      pages.clear(); frames.clear(); receipts.clear(); sessions.clear()
      await session?.context.close()
    },
  }
  const automation = createWorkspaceBrowserMCP({
    tabs: () => api.tabs(),
    connect: async () => { await api.connect(); return active },
    locate: async id => {
      inventory()
      const page = pages.get(id)
      if (!page) throw failure(410, 'Choose a current tabId from tabs or open.')
      return { id, page }
    },
    createPage: async () => {
      if (active.context.pages().length >= 64) throw failure(409, 'The shared browser has reached its 64-tab limit.')
      const page = await active.context.newPage()
      inventory()
      return { id: ids.get(page), page }
    },
    claim: page => {
      if (acting.has(page)) throw failure(409, 'browser_busy')
      acting.add(page)
      return () => acting.delete(page)
    },
  })
  api.executeMCP = automation.execute
  api.cancelMCP = automation.cancel
  return api
}

const validProfile = id => typeof id === 'string' && /^[a-z0-9-]{1,32}$/.test(id)

// Each identity owns its browser, tabs, action receipts and cookies. Choosing a
// profile never changes another identity's page or shares its browser context.
export function createWorkspaceBrowser({ profile, profilesRoot, runtimeKind = 'host', launch = launchBrowser }) {
  const profiles = new Map()
  let closed = false
  async function directory(id) {
    if (!profilesRoot) {
      if (id !== 'default') throw failure(400, 'browser_profiles_unavailable')
      return profile
    }
    const root = resolve(profilesRoot)
    await mkdir(root, { recursive: true, mode: 0o700 })
    const rootStat = await lstat(root)
    if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) throw failure(409, 'unsafe_browser_profiles_directory')
    await chmod(root, 0o700)
    // Keeping the old directory as default preserves all cookies and login
    // state without a potentially destructive cross-filesystem migration.
    const legacy = id === 'default' && profile && existsSync(profile)
    const path = legacy ? resolve(profile) : join(root, id)
    await mkdir(path, { recursive: true, mode: 0o700 })
    const info = await lstat(path)
    if (info.isSymbolicLink() || !info.isDirectory()) throw failure(409, 'unsafe_browser_profile_directory')
    if (!legacy && await realpath(path) !== join(await realpath(root), id)) throw failure(409, 'unsafe_browser_profile_directory')
    await chmod(path, 0o700)
    return path
  }
  function forProfile(id = 'default') {
    if (!validProfile(id)) throw failure(400, 'invalid_browser_profile')
    if (closed) throw failure(503, 'browser_unavailable')
    if (!profiles.has(id)) {
      if (profiles.size >= 32) throw failure(409, 'browser_profile_limit')
      profiles.set(id, createProfileBrowser({ profile: id, launch: async () => launch(await directory(id), { runtimeKind }) }))
    }
    return profiles.get(id)
  }
  return {
    forProfile,
    async profiles() {
      const ids = new Set(['default', ...profiles.keys()])
      if (profilesRoot) {
        for (const item of await readdir(profilesRoot, { withFileTypes: true }).catch(error => {
          if (error.code === 'ENOENT') return []
          throw error
        })) if (item.isDirectory() && validProfile(item.name)) ids.add(item.name)
      }
      return { profiles: [...ids].sort((a, b) => a === 'default' ? -1 : b === 'default' ? 1 : a.localeCompare(b)) }
    },
    connect: async () => forProfile().connect(),
    tabs: async () => forProfile().tabs(),
    watch: async (...args) => forProfile().watch(...args),
    frame: async (...args) => forProfile().frame(...args),
    action: async (...args) => forProfile().action(...args),
    actions: async (...args) => forProfile().actions(...args),
    executeMCP: async (scope, input, options) => forProfile(input.profile).executeMCP(scope, input, options),
    cancelMCP: async (scope, id) => {
      const results = await Promise.all([...profiles.values()].map(browser => browser.cancelMCP(scope, id)))
      return { cancelled: results.reduce((sum, result) => sum + result.cancelled, 0) }
    },
    async close() { closed = true; await Promise.all([...profiles.values()].map(browser => browser.close())); profiles.clear() },
  }
}

function keyInfo(key) {
  const special = { Enter: ['Enter', 13], Tab: ['Tab', 9], Escape: ['Escape', 27], Backspace: ['Backspace', 8],
    Delete: ['Delete', 46], ArrowLeft: ['ArrowLeft', 37], ArrowRight: ['ArrowRight', 39],
    ArrowUp: ['ArrowUp', 38], ArrowDown: ['ArrowDown', 40], Home: ['Home', 36], End: ['End', 35],
    PageUp: ['PageUp', 33], PageDown: ['PageDown', 34], ' ': ['Space', 32] }
  if (Object.hasOwn(special, key)) return special[key]
  const punctuation = { '`': ['Backquote', 192], '~': ['Backquote', 192], '-': ['Minus', 189], '_': ['Minus', 189],
    '=': ['Equal', 187], '+': ['Equal', 187], '[': ['BracketLeft', 219], '{': ['BracketLeft', 219],
    ']': ['BracketRight', 221], '}': ['BracketRight', 221], ';': ['Semicolon', 186], ':': ['Semicolon', 186],
    "'": ['Quote', 222], '"': ['Quote', 222], ',': ['Comma', 188], '<': ['Comma', 188],
    '.': ['Period', 190], '>': ['Period', 190], '/': ['Slash', 191], '?': ['Slash', 191],
    '\\': ['Backslash', 220], '|': ['Backslash', 220] }
  if (Object.hasOwn(punctuation, key)) return punctuation[key]
  const shifted = '!@#$%^&*()'.indexOf(key)
  if (typeof key === 'string' && key.length === 1 && shifted >= 0) return ['Digit' + ((shifted + 1) % 10), 48 + ((shifted + 1) % 10)]
  if (typeof key === 'string' && /^[a-zA-Z0-9]$/.test(key)) return [/^[0-9]$/.test(key) ? 'Digit' + key : 'Key' + key.toUpperCase(), key.toUpperCase().charCodeAt(0)]
  throw failure(400, 'invalid_browser_key')
}
function validateAction(r) {
  const invalid = () => { throw failure(400, 'invalid_browser_action') }
  if (!r || !['tabID', 'frameID', 'actionID'].every(key => typeof r[key] === 'string' && /^[0-9a-f-]{36}$/i.test(r[key]))) invalid()
  if (!['click', 'drag', 'move', 'scroll', 'text', 'key', 'copy', 'navigate', 'back', 'forward', 'reload', 'pointerDown', 'pointerMove', 'pointerUp', 'pointerCancel'].includes(r.kind)) invalid()
  if (r.kind.startsWith('pointer') && (typeof r.gestureID !== 'string' || !/^[0-9a-f-]{36}$/i.test(r.gestureID))) invalid()
  if (r.modifiers !== undefined && (!Number.isInteger(r.modifiers) || r.modifiers < 0 || r.modifiers > 15)) invalid()
  if (['click', 'drag', 'move', 'scroll', 'pointerDown', 'pointerMove', 'pointerUp'].includes(r.kind)) {
    if (![r.x, r.y].every(v => Number.isFinite(v) && v >= 0 && v <= 1)) invalid()
    if (r.button !== undefined && !['left', 'right'].includes(r.button)) invalid()
    if (r.clickCount !== undefined && ![1, 2, 3].includes(r.clickCount)) invalid()
    if (r.kind === 'drag' && ![r.endX, r.endY].every(v => Number.isFinite(v) && v >= 0 && v <= 1)) invalid()
    if (r.kind === 'scroll' && ![r.deltaX, r.deltaY].every(v => Number.isFinite(v) && Math.abs(v) <= 4000)) invalid()
  }
  if (r.kind === 'key') {
    keyInfo(r.key)
    if (r.text !== undefined && (typeof r.text !== 'string' || r.text.length !== 1 || r.text !== r.key)) invalid()
  }
  if (r.kind === 'text' && (typeof r.text !== 'string' || Buffer.byteLength(r.text) > 16384 || !r.text)) invalid()
  if (r.kind === 'navigate') {
    let url
    try { url = new URL(r.text) } catch { invalid() }
    if (!['http:', 'https:'].includes(url.protocol) || r.text.length > 4096) invalid()
  }
}

// Keep video independent of network round trips. Never accumulate a video backlog:
// a slow receiver is disconnected rather than shown seconds of obsolete frames.
const streams = new WeakMap()
export async function streamBrowserFrames(browser, tabID, response) {
  if (!streams.has(browser)) streams.set(browser, new Set())
  const viewers = streams.get(browser)
  if (viewers.size >= 4) throw failure(429, 'browser_viewer_limit')
  viewers.add(response)
  let stopped = false, wake, unsubscribe, latest, failed, previousImageID
  const stop = () => { stopped = true; wake?.() }
  response.once('close', stop)
  try {
    unsubscribe = await browser.watch(tabID, frame => { latest = frame; wake?.() }, error => { failed = error; wake?.() })
    while (!stopped) {
      if (failed) throw failed
      if (!latest) { await new Promise(resolve => { wake = resolve }); continue }
      const frame = latest; latest = undefined
      if (!response.headersSent) {
        response.writeHead(200, { 'Content-Type': 'application/x-ndjson', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no' })
        response.flushHeaders()
      }
      if (response.writableLength > 3 * 1024 * 1024) break
      const writable = response.write(JSON.stringify({ ...frame, imageBase64: frame.imageID === previousImageID ? '' : frame.imageBase64 }) + '\n')
      previousImageID = frame.imageID
      if (!writable && !stopped) {
        const drained = await new Promise(resolve => {
          const finish = value => {
            clearTimeout(timer); response.off('drain', ready); response.off('close', gone); resolve(value)
          }
          const ready = () => finish(true), gone = () => finish(false)
          const timer = setTimeout(gone, 1500)
          response.once('drain', ready); response.once('close', gone)
        })
        if (!drained) break
      }
    }
  } catch (error) {
    if (!response.headersSent && !stopped) throw error
  } finally {
    unsubscribe?.()
    viewers.delete(response)
    response.off('close', stop)
    if (response.headersSent) response.destroy()
  }
}
