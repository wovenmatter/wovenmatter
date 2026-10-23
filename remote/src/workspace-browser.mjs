import { existsSync } from 'node:fs'
import { mkdir, readFile, rm } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
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

// One lazy, workspace-owned browser. The viewer never launches, navigates, focuses,
// resizes or closes an agent's page. CDP stays inside the container's loopback.
export function createWorkspaceBrowser({ profile, launch = launchBrowser }) {
  let active, starting, closed = false, capturing = false
  const pages = new Map(), ids = new WeakMap()
  function forget(session) {
    if (active !== session) return
    active = undefined
    pages.clear()
  }
  function inventory() {
    const current = active?.context.pages().filter(page => !page.isClosed()).slice(0, 64) ?? []
    for (const [id, page] of pages) if (!current.includes(page)) pages.delete(id)
    return current.map(page => {
      if (!ids.has(page)) ids.set(page, randomUUID())
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
          const { data } = await cdp.send('Page.captureScreenshot', {
            format: 'jpeg', quality: 65, captureBeyondViewport: false,
            clip: { x: viewport.pageX, y: viewport.pageY, width: Math.min(viewport.clientWidth, 1920),
              height: Math.min(viewport.clientHeight, 1200), scale: 1 },
          })
          if (data.length > 2 * 1024 * 1024) throw failure(413, 'browser_frame_too_large')
          if (page.isClosed() || pages.get(tabID) !== page) throw failure(410, 'browser_tab_closed')
          return { tabID, imageBase64: data }
        })
      } finally {
        expired = true
        if (cdp) await deadline(() => cdp.detach(), 1000).catch(() => {})
        capturing = false
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
