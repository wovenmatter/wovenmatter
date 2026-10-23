import { existsSync } from 'node:fs'
import { mkdir, readFile, rm } from 'node:fs/promises'
import { randomUUID, createHash } from 'node:crypto'
import { join } from 'node:path'

const failure = (statusCode, message) => Object.assign(new Error(message), { statusCode })
async function deadline(operation, milliseconds = 5000) {
  let timer
  try {
    return await Promise.race([operation(), new Promise((_, reject) => {
      timer = setTimeout(() => reject(failure(503, 'browser_timed_out')), milliseconds)
    })])
  } finally { clearTimeout(timer) }
}

async function launchBrowser(profile) {
  const bundled = new URL('../default-agent/node_modules/playwright-core/index.mjs', import.meta.url)
  const { chromium } = await import(existsSync(bundled) ? bundled.href
    : new URL('../../default-agent/node_modules/playwright-core/index.mjs', import.meta.url).href)
  await mkdir(profile, { recursive: true, mode: 0o700 })
  await rm(join(profile, 'DevToolsActivePort'), { force: true })
  const context = await chromium.launchPersistentContext(profile, {
    headless: true, viewport: { width: 1280, height: 800 }, timeout: 15000,
    args: ['--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0'],
  })
  try {
    const [port, path] = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).trim().split('\n')
    if (!/^\d+$/.test(port) || +port < 1 || +port > 65535 || !/^\/devtools\/browser\/[a-zA-Z0-9-]+$/.test(path)) {
      throw failure(503, 'browser_endpoint_unavailable')
    }
    return { context, endpoint: `ws://127.0.0.1:${port}${path}` }
  } catch (error) { await context.close(); throw error }
}

// One workspace-owned browser: agents and people operate the same pages.
// Opening the app viewer is passive; only explicit input changes a page. CDP stays on loopback.
export function createWorkspaceBrowser({ profile, launch = launchBrowser }) {
  let active, starting, closed = false, capturing = false
  const pages = new Map(), ids = new WeakMap(), documents = new WeakMap(), frames = new Map(), receipts = new Map()
  const acting = new Set()
  function forget(session) {
    if (active !== session) return
    active = undefined
    pages.clear(); frames.clear(); receipts.clear()
  }
  function inventory() {
    const current = active?.context.pages().filter(page => !page.isClosed()).slice(0, 64) ?? []
    for (const [id, page] of pages) if (!current.includes(page)) pages.delete(id)
    return current.map(page => {
      if (!ids.has(page)) {
        ids.set(page, randomUUID()); documents.set(page, randomUUID())
        page.on('framenavigated', frame => {
          if (frame === page.mainFrame()) documents.set(page, randomUUID())
        })
      }
      const id = ids.get(page)
      pages.set(id, page)
      return { id, page }
    })
  }
  return {
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
    async frame(tabID) {
      if (typeof tabID !== 'string' || !/^[0-9a-f-]{36}$/.test(tabID)) throw failure(400, 'invalid_browser_tab')
      inventory()
      const page = pages.get(tabID)
      if (!page) throw failure(410, 'browser_tab_closed')
      if (capturing) throw failure(409, 'browser_busy')
      capturing = true
      let cdp, expired = false
      try {
        return await deadline(async () => {
          cdp = await page.context().newCDPSession(page)
          if (expired) { await cdp.detach().catch(() => {}); throw failure(503, 'browser_timed_out') }
          const { cssVisualViewport: viewport } = await cdp.send('Page.getLayoutMetrics')
          if (!viewport || ![viewport.pageX, viewport.pageY, viewport.clientWidth, viewport.clientHeight].every(Number.isFinite)
              || viewport.clientWidth <= 0 || viewport.clientHeight <= 0) throw failure(503, 'browser_frame_unavailable')
          if (expired) throw failure(503, 'browser_timed_out')
          const document = documents.get(page)
          const { data } = await cdp.send('Page.captureScreenshot', {
            format: 'jpeg', quality: 65, captureBeyondViewport: false,
            clip: { x: viewport.pageX, y: viewport.pageY, width: Math.min(viewport.clientWidth, 1920),
              height: Math.min(viewport.clientHeight, 1200), scale: 1 },
          })
          if (data.length > 2 * 1024 * 1024) throw failure(413, 'browser_frame_too_large')
          if (page.isClosed() || pages.get(tabID) !== page) throw failure(410, 'browser_tab_closed')
          if (document !== documents.get(page)) throw failure(409, 'browser_page_changed')
          const frameID = randomUUID()
          frames.set(frameID, { page, document, viewport, created: Date.now() })
          while (frames.size > 256) frames.delete(frames.keys().next().value)
          return { tabID, frameID, imageBase64: data }
        })
      } finally {
        expired = true
        if (cdp) await deadline(() => cdp.detach(), 1000).catch(() => {})
        capturing = false
      }
    },
    async action(request) {
      validateAction(request)
      inventory()
      const { tabID, frameID, actionID } = request, page = pages.get(tabID)
      if (!page) throw failure(410, 'browser_tab_closed')
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
      if (acting.has(page)) throw failure(409, 'browser_busy')
      receipts.set(actionID, digest)
      while (receipts.size > 1024) receipts.delete(receipts.keys().next().value)
      acting.add(page)
      let cdp, expired = false, heldButton, heldKey
      try {
        return await deadline(async () => {
          cdp = await page.context().newCDPSession(page)
          if (expired) { await cdp.detach().catch(() => {}); throw failure(503, 'browser_timed_out') }
          const send = async (method, params) => {
            if (expired || page.isClosed() || documents.get(page) !== frame.document) throw failure(409, 'browser_page_changed')
            return cdp.send(method, params)
          }
          const { kind, x, y, modifiers = 0 } = request
          if (['click', 'drag', 'move', 'scroll'].includes(kind)) {
            const { cssVisualViewport: current } = await send('Page.getLayoutMetrics')
            if (!current || (kind === 'scroll' ? ['clientWidth', 'clientHeight'] : ['pageX', 'pageY', 'clientWidth', 'clientHeight']).some(key => Math.abs(current[key] - frame.viewport[key]) > 1)) {
              throw failure(409, 'browser_page_changed')
            }
            const width = Math.min(current.clientWidth, 1920), height = Math.min(current.clientHeight, 1200)
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
          return { tabID, accepted: true }
        })
      } finally {
        expired = true
        if (cdp) {
          await deadline(async () => {
            if (heldButton) await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...heldButton, buttons: 0 }).catch(() => {})
            if (heldKey) await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', ...heldKey }).catch(() => {})
            await cdp.detach()
          }, 1000).catch(() => {})
        }
        acting.delete(page)
      }
    },
    async close() {
      closed = true
      await starting?.catch(() => {})
      const session = active
      active = undefined
      pages.clear()
      await session?.context.close()
    },
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
  if (!['click', 'drag', 'move', 'scroll', 'text', 'key', 'copy', 'navigate', 'back', 'forward', 'reload'].includes(r.kind)) invalid()
  if (r.modifiers !== undefined && (!Number.isInteger(r.modifiers) || r.modifiers < 0 || r.modifiers > 15)) invalid()
  if (['click', 'drag', 'move', 'scroll'].includes(r.kind)) {
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
