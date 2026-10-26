// Disposable loopback fixture for the opt-in native viewer integration test.
// PLAYWRIGHT_BROWSERS_PATH=... node remote/test-support/browser-native-fixture.mjs
// Pass the printed URL as WOVENMATTER_BROWSER_INPUT_FIXTURE to swift test.
import { createServer } from 'node:http'
import { once } from 'node:events'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { chromium } from '../../default-agent/node_modules/playwright-core/index.mjs'
import { createWorkspaceBrowser, streamBrowserFrames } from '../src/workspace-browser.mjs'
const profile = await mkdtemp(join(tmpdir(), 'woven-native-browser-'))
const browser = createWorkspaceBrowser({ profile })
let agent, server
async function close() {
  server?.closeAllConnections(); server?.close()
  await agent?.close(); await browser.close(); await rm(profile, { recursive: true, force: true })
}
try {
  agent = await chromium.connectOverCDP((await browser.connect()).endpoint)
  const page = await agent.contexts()[0].newPage()
  await page.setContent(`<!doctype html><title>Shared collaboration fixture</title>
    <style>body{margin:0;background:white}input,button,output{position:absolute;left:20px}
    #name{top:20px;width:300px;height:40px}button{top:80px;width:120px;height:40px}
    output{top:150px}#range{top:200px;width:300px;height:40px}canvas{position:absolute;top:300px}</style>
    <input id=name aria-label=Name value=initial><button onclick="document.querySelector('output').textContent='Hello '+document.querySelector('#name').value">Greet</button>
    <output></output><input id=range type=range min=0 max=100 value=0><canvas width=600 height=300></canvas>
    <script>window.held=false;window.moves=0;window.releases=0;
    document.addEventListener('mousedown',()=>window.held=true);
    document.addEventListener('mousemove',e=>{if(e.buttons)window.moves++});
    document.addEventListener('mouseup',()=>{window.held=false;window.releases++});</script>`)
  // Leave another page foreground: the viewer must work on the agent's background tab.
  await agent.contexts()[0].newPage()
  server = createServer(async (request, response) => {
    if (request.headers.authorization !== 'Bearer fixture') { response.writeHead(401); response.end(); return }
    response.setHeader('Cache-Control', 'no-store')
    try {
      const url = new URL(request.url, 'http://localhost')
      if (url.pathname === '/v1/browser/stream') { await streamBrowserFrames(browser, url.searchParams.get('tabID'), response); return }
      let result
      if (url.pathname === '/v1/browser/tabs') result = await browser.tabs()
      else if (url.pathname === '/fixture/state') result = await page.evaluate(() => ({
        name: document.querySelector('#name').value, output: document.querySelector('output').textContent,
        level: document.querySelector('#range').value, held: String(window.held), moves: String(window.moves), releases: String(window.releases),
      }))
      else if (url.pathname === '/fixture/animation') {
        await page.evaluate(enabled => {
          window.animate = enabled
          const context = document.querySelector('canvas').getContext('2d')
          function draw(t) { context.fillStyle = 'hsl('+t/8%360+' 60% 50%)'; context.fillRect(0,0,600,300); if(window.animate)requestAnimationFrame(draw) }
          if(enabled)requestAnimationFrame(draw)
        }, url.searchParams.get('enabled') === 'true')
        result = { ok: true }
      } else {
        let body = ''; for await (const chunk of request) { body += chunk; if (body.length > 65536) throw Error('body too large') }
        const value = JSON.parse(body)
        if (url.pathname === '/v1/browser/frame') result = await browser.frame(value.tabID, value.previousFrameID)
        else if (url.pathname === '/v1/browser/action') result = await browser.action(value)
        else if (url.pathname === '/v1/browser/actions') result = await browser.actions(value.actions)
        else throw Error('unknown route')
      }
      response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify(result))
    } catch (error) {
      if (response.headersSent) { response.destroy(); return }
      response.writeHead(error.statusCode ?? 500, { 'Content-Type': 'application/json' }); response.end(JSON.stringify({ error: error.message }))
    }
  })
  server.listen(0, '127.0.0.1'); await once(server, 'listening')
  console.log(`http://127.0.0.1:${server.address().port}`)
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { void close() })
} catch (error) { await close(); throw error }
