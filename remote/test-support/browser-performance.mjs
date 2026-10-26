// Provider-free, disposable real-Chromium benchmark. Network delay is simulated;
// this does not claim to measure a deployed workspace or the Mac compositor.
// PLAYWRIGHT_BROWSERS_PATH=... node remote/test-support/browser-performance.mjs
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { EventEmitter } from 'node:events'
import { chromium } from '../../default-agent/node_modules/playwright-core/index.mjs'
import { createWorkspaceBrowser, streamBrowserFrames } from '../src/workspace-browser.mjs'
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
const profile = await mkdtemp(join(tmpdir(), 'woven-browser-performance-'))
const service = createWorkspaceBrowser({ profile })
let agent
const summary = samples => {
  const sorted = samples.toSorted((a, b) => a - b)
  return { median: +sorted[Math.floor(sorted.length / 2)].toFixed(1), p95: +sorted[Math.floor(sorted.length * .95)].toFixed(1) }
}
try {
  agent = await chromium.connectOverCDP((await service.connect()).endpoint)
  const page = await agent.contexts()[0].newPage()
  await page.setContent('<input aria-label="Text"><div style="font:36px sans-serif">Shared browser performance fixture</div><canvas width=600 height=300></canvas>')
  const tab = (await service.tabs()).tabs.at(-1)
  const capture = []
  for (let i = 0; i < 30; i++) { const start = performance.now(); await service.frame(tab.id); capture.push(performance.now() - start) }
  console.log(JSON.stringify({ metric: 'capture_ms', ...summary(capture) }))
  for (const rtt of [0, 50, 100, 200]) {
    const result = { rtt_ms: rtt }
    for (const mode of ['serial', 'batch']) {
      const samples = []
      for (let trial = 0; trial < 3; trial++) {
        await page.locator('input').fill('')
        const frame = await service.frame(tab.id)
        const actions = Array.from({ length: 30 }, () => ({ actionID: randomUUID(), tabID: tab.id, frameID: frame.frameID, kind: 'key', key: 'a', text: 'a' }))
        const start = performance.now()
        for (const batch of mode === 'batch' ? [actions] : actions.map(a => [a])) {
          if (rtt) await sleep(rtt / 2)
          if (mode === 'batch') await service.actions(batch); else await service.action(batch[0])
          if (rtt) await sleep(rtt / 2)
        }
        if ((await page.locator('input').inputValue()).length !== 30) throw Error('Lost or reordered keyboard input')
        samples.push(performance.now() - start)
      }
      result[mode] = summary(samples)
    }
    console.log(JSON.stringify({ metric: '30_key_burst_ms', ...result }))
  }
  await page.locator('input').blur()
  await page.evaluate(() => {
    window.animate = true
    const context = document.querySelector('canvas').getContext('2d')
    function draw(time) {
      context.fillStyle = `hsl(${time / 8 % 360} 60% 50%)`; context.fillRect(0, 0, 600, 300)
      if (window.animate) requestAnimationFrame(draw)
    }
    requestAnimationFrame(draw)
  })
  for (const rtt of [0, 100, 200]) {
    let count = 0, start = performance.now()
    do {
      await sleep(rtt / 2); await service.tabs(); await sleep(rtt / 2)
      await sleep(rtt / 2); await service.frame(tab.id); await sleep(rtt / 2)
      count++; await sleep(200)
    } while (performance.now() - start < 3000)
    const legacyFPS = count * 1000 / (performance.now() - start)
    const response = new EventEmitter(), deliveries = [], timers = new Set()
    response.writableLength = 0
    response.writeHead = () => { response.headersSent = true }
    response.flushHeaders = () => {}
    response.destroy = () => response.emit('close')
    response.write = data => {
      const captured = performance.now()
      const timer = setTimeout(() => { timers.delete(timer); if (JSON.parse(data).imageBase64) deliveries.push({ arrived: performance.now(), age: performance.now() - captured }) }, rtt / 2)
      timers.add(timer); return true
    }
    const streaming = streamBrowserFrames(service, tab.id, response)
    await sleep(3300); response.emit('close'); await streaming
    for (const timer of timers) clearTimeout(timer)
    const elapsed = deliveries.at(-1).arrived - deliveries[0].arrived
    console.log(JSON.stringify({ metric: 'animated_frames_per_second', rtt_ms: rtt, legacy: +legacyFPS.toFixed(1), stream: +((deliveries.length - 1) * 1000 / elapsed).toFixed(1) }))
  }
  await page.evaluate(() => { window.animate = false }); await sleep(100)
  let bytes = 0, images = 0
  const response = new EventEmitter()
  response.writableLength = 0; response.writeHead = () => { response.headersSent = true }; response.flushHeaders = () => {}
  response.destroy = () => response.emit('close')
  response.write = data => { bytes += Buffer.byteLength(data); if (JSON.parse(data).imageBase64) images++; return true }
  const stream = streamBrowserFrames(service, tab.id, response)
  await sleep(5000); response.emit('close'); await stream
  console.log(JSON.stringify({ metric: 'idle_stream_5_seconds', bytes, fullImages: images }))
} finally { await agent?.close(); await service.close(); await rm(profile, { recursive: true, force: true }) }
