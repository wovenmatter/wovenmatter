import { existsSync } from 'node:fs'
import { readFile, stat } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'

const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })
const ordered = value => Array.isArray(value) ? value.map(ordered) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])])) : value
const interrupted = () => fail(503, 'Browser operation interrupted. Inspect fresh state before repeating input.')
const text = value => ({ content: [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value) }] })

async function runtime() {
  const bundled = new URL('../default-agent/src/browser-runtime.mjs', import.meta.url)
  const root = existsSync(bundled) ? new URL('../default-agent/', import.meta.url) : new URL('../../default-agent/', import.meta.url)
  const [{ browserAction }, { chromium }] = await Promise.all([
    import(new URL('src/browser-runtime.mjs', root).href),
    import(new URL('node_modules/playwright-core/index.mjs', root).href),
  ])
  return { browserAction, connect: endpoint => chromium.connectOverCDP(endpoint, { noDefaults: true, timeout: 15000 }) }
}

// Each action borrows a separate CDP connection to the exact shared page. Closing
// that connection cancels Playwright's pending locator work without closing the
// browser or its user-visible tabs. The endpoint and target IDs are host-owned.
export function createWorkspaceBrowserMCP({ tabs, connect, locate, createPage, claim, loadRuntime = runtime }) {
  const requests = new Map(), downloads = new Map(), downloadTabs = new Map()
  let stopped = false, downloadBytes = 0
  const callerKey = scope => scope.conversationID
  async function cancel(scope, id) {
    if (id !== 'all' && (typeof id !== 'string' || !/^[0-9a-f-]{36}$/i.test(id))) throw fail(400, 'Choose an operation UUID or all.')
    const pending = []
    for (const request of requests.values()) if (request.caller === callerKey(scope) && (id === 'all' || request.id === id) && !request.finished) {
      request.controller.abort(); pending.push(request.promise)
    }
    await Promise.allSettled(pending)
    return { cancelled: pending.length }
  }
  async function invoke(scope, input, signal) {
    signal.throwIfAborted()
    if (input.action === 'tabs') return text((await tabs()).tabs)
    if (input.action === 'downloads') {
      await locate(input.tabId)
      return text([...downloads.values()].filter(value => value.caller === callerKey(scope) && value.tabId === input.tabId).map(({ bytes: _, caller: __, tabId: ___, ...receipt }) => receipt))
    }
    if (input.action === 'read-download') {
      await locate(input.tabId)
      const value = downloads.get(input.id), offset = input.offset ?? 0
      if (!value || value.caller !== callerKey(scope) || value.tabId !== input.tabId || !Number.isSafeInteger(offset) || offset < 0 || offset > value.bytes.length) {
        throw fail(400, 'Choose a completed download ID and valid byte offset.')
      }
      const data = value.bytes.subarray(offset, offset + 384 * 1024)
      return text({ id: value.id, name: value.name, mimeType: value.mimeType, offset, nextOffset: offset + data.length, totalBytes: value.bytes.length, data: data.toString('base64') })
    }
    const active = await connect()
    signal.throwIfAborted()
    const original = input.action === 'open' ? await createPage() : await locate(input.tabId)
    const release = claim(original.page)
    let borrowed, cdp, pendingDownload, stopWaiting
    const abort = () => { void pendingDownload?.cancel().catch(() => {}); void borrowed?.close().catch(() => {}) }
    signal.addEventListener('abort', abort, { once: true })
    try {
      signal.throwIfAborted()
      const implementation = await loadRuntime()
      signal.throwIfAborted()
      borrowed = await implementation.connect(active.endpoint)
      signal.throwIfAborted()
      const target = await original.page.context().newCDPSession(original.page)
      let targetID
      try { targetID = (await target.send('Target.getTargetInfo')).targetInfo.targetId } finally { await target.detach() }
      let page
      for (const candidate of borrowed.contexts().flatMap(context => context.pages())) {
        const session = await candidate.context().newCDPSession(candidate)
        try { if ((await session.send('Target.getTargetInfo')).targetInfo.targetId === targetID) page = candidate }
        finally { await session.detach() }
        if (page) break
      }
      if (!page) throw fail(503, 'The shared browser tab is no longer available. Inspect tabs again.')
      signal.throwIfAborted()
      cdp = await page.context().newCDPSession(page)
      if (input.action === 'focus') { await page.bringToFront(); return text({ focused: true }) }
      if (input.action === 'close') { await page.close(); return text({ closed: true }) }
      const action = input.action === 'open' ? { ...input, action: 'navigate', url: input.url ?? 'about:blank' } : input
      page.on('dialog', dialog => { void (action.accept ? dialog.accept(action.text) : dialog.dismiss()).catch(() => {}) })
      const waitDownload = async () => {
        // Only the persistent owner knows Chromium's download artifact path.
        // A borrowed CDP connection has a different temporary artifacts folder.
        pendingDownload = await new Promise((resolve, reject) => {
          const cleanup = () => { clearTimeout(timer); original.page.off('download', receive); original.page.off('close', closed); signal.removeEventListener('abort', cancel); stopWaiting = undefined }
          const receive = value => { cleanup(); resolve(value) }
          const cancel = () => { cleanup(); reject(interrupted()) }
          const closed = () => { cleanup(); reject(fail(410, 'The browser tab closed before its download.')) }
          const timer = setTimeout(() => { cleanup(); reject(fail(503, 'Download timed out.')) }, 20000)
          stopWaiting = cancel
          original.page.on('download', receive); original.page.on('close', closed); signal.addEventListener('abort', cancel, { once: true })
          if (signal.aborted) cancel()
        })
        if (signal.aborted) { await pendingDownload.cancel(); throw interrupted() }
        try {
          const path = await pendingDownload.path()
          const size = (await stat(path)).size
          if (size > 64 * 1024 * 1024) throw fail(413, 'Download exceeds 64 MiB.')
          const bytes = await readFile(path, { signal })
          if (bytes.length > 64 * 1024 * 1024) throw fail(413, 'Download exceeds 64 MiB.')
          signal.throwIfAborted()
          while (downloads.size >= 16 || downloadBytes + bytes.length > 64 * 1024 * 1024) {
            const first = downloads.keys().next().value
            downloadBytes -= downloads.get(first).bytes.length; downloads.delete(first)
          }
          const receipt = { id: randomUUID(), name: pendingDownload.suggestedFilename().slice(0, 512), mimeType: 'application/octet-stream', status: 'complete', totalBytes: bytes.length }
          if (!downloadTabs.has(original.id)) {
            const closed = () => {
              for (const [id, value] of downloads) if (value.tabId === original.id) { downloadBytes -= value.bytes.length; downloads.delete(id) }
              downloadTabs.delete(original.id)
            }
            original.page.once('close', closed); downloadTabs.set(original.id, { page: original.page, closed })
          }
          downloads.set(receipt.id, { ...receipt, caller: callerKey(scope), tabId: original.id, bytes }); downloadBytes += bytes.length
          return receipt
        } finally { await pendingDownload.delete().catch(() => {}) }
      }
      const value = await implementation.browserAction(page, action, (method, params) => {
        signal.throwIfAborted(); return cdp.send(method, params)
      }, waitDownload)
      signal.throwIfAborted()
      return input.action === 'open' ? text({ tabId: original.id, url: page.url() }) : value
    } finally {
      stopWaiting?.()
      signal.removeEventListener('abort', abort)
      await pendingDownload?.cancel().catch(() => {})
      await cdp?.detach().catch(() => {})
      await borrowed?.close().catch(() => {})
      // Release held input even if a browser connection vanished mid-gesture.
      if (signal.aborted && !original.page.isClosed()) {
        await Promise.allSettled(['left', 'middle', 'right'].map(button => original.page.mouse?.up({ button })))
      }
      release()
    }
  }
  async function execute(scope, input, { signal } = {}) {
    if (stopped) throw fail(503, 'The workspace browser is unavailable.')
    const key = callerKey(scope) + ':' + input.requestID, fingerprint = JSON.stringify(ordered(input)), previous = requests.get(key)
    if (previous) {
      if (previous.fingerprint !== fingerprint) throw fail(409, 'This request ID belongs to a different browser operation.')
      return previous.promise
    }
    if ([...requests.values()].filter(value => !value.finished).length >= 4) throw fail(429, 'The shared browser is busy.')
    const controller = new AbortController(), request = { caller: callerKey(scope), id: input.requestID, fingerprint, controller, finished: false }
    requests.set(key, request)
    const timeout = setTimeout(() => controller.abort(), 25000); timeout.unref?.()
    const combined = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal
    request.promise = invoke(scope, input, combined).catch(error => { throw combined.aborted ? interrupted() : error }).finally(() => {
      clearTimeout(timeout); request.finished = true
      const completed = [...requests.entries()].filter(([, value]) => value.finished)
      for (const [old] of completed.slice(0, Math.max(0, completed.length - 16))) requests.delete(old)
    })
    return request.promise
  }
  return { execute, cancel, async close() { stopped = true; for (const value of requests.values()) value.controller.abort(); await Promise.allSettled([...requests.values()].map(value => value.promise)); requests.clear(); downloads.clear(); for (const {page,closed} of downloadTabs.values()) page.off('close',closed); downloadTabs.clear(); downloadBytes = 0 } }
}
