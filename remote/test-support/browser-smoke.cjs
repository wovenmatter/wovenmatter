// Run through stdin inside the real workspace container, without provider traffic.
const assert = require('node:assert/strict');
const { createServer } = require('node:http');
const { once } = require('node:events');
const { mkdtemp, readFile, rm } = require('node:fs/promises');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { join } = require('node:path');
const exec = promisify(execFile);

async function main() {
  assert.equal(process.getuid(), 10001);
  const directory = await mkdtemp('/home/browser-smoke-');
  process.chdir(directory);
  // Resolves the global library even in an empty project with no node_modules.
  const { chromium } = require('playwright');
  const core = require('/opt/wovenmatter/default-agent/node_modules/playwright-core');
  const esm = await import('/usr/local/lib/node_modules/playwright/index.mjs');
  assert.equal(esm.chromium.executablePath(), chromium.executablePath());
  assert.equal(core.chromium.executablePath(), chromium.executablePath());
  assert.ok(chromium.executablePath().startsWith('/opt/ms-playwright/'));
  const html = `<!doctype html><title>Workspace browser</title>
    <label>Name <input aria-label="Name"></label>
    <button onclick="document.querySelector('output').textContent =
      'Hello ' + document.querySelector('input').value">Greet</button><output></output>`;
  const server = createServer((request, response) => {
    response.writeHead(200, { 'Content-Type': 'text/html' });
    response.end(html);
  });
  let browser;
  try {
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const url = `http://127.0.0.1:${server.address().port}/`;
    // No executable override or download: the ordinary launch must work.
    console.log('Checking default headless Chromium launch.');
    browser = await chromium.launch({ timeout: 15000 });
    const page = await browser.newPage();
    page.setDefaultTimeout(10000);
    await page.goto(url);
    assert.equal(await page.title(), 'Workspace browser');
    await page.getByRole('textbox', { name: 'Name' }).fill('remote agent');
    await page.getByRole('button', { name: 'Greet' }).click();
    assert.equal(await page.locator('output').textContent(), 'Hello remote agent');
    const screenshot = await page.screenshot();
    assert.equal(screenshot.subarray(1, 4).toString(), 'PNG');
    await browser.close();
    browser = undefined;
    // CLI screenshots use the full Chromium build, not just the headless shell.
    console.log('Checking full Chromium through the Playwright CLI.');
    const output = join(directory, 'cli.png');
    await exec('playwright', ['screenshot', '--channel', 'chromium', url, output], { timeout: 30000 });
    assert.equal((await readFile(output)).subarray(1, 4).toString(), 'PNG');
    // The app's bundled playwright-core resolves the same browser installation.
    console.log('Checking bundled playwright-core launch.');
    browser = await core.chromium.launch({ timeout: 15000 });
    await browser.close();
    browser = undefined;
    console.log('Checking shared browser discovery, live frames and agent disconnect.');
    const serviceURL = 'http://127.0.0.1:' + (process.env.WOVENMATTER_LISTEN_PORT || '7337');
    const request = async (path, body) => {
      const response = await fetch(serviceURL + '/v1/browser/' + path, {
        method: body ? 'POST' : 'GET',
        headers: { Authorization: 'Bearer ' + process.env.WOVENMATTER_API_TOKEN, 'Content-Type': 'application/json' },
        body: body ? JSON.stringify(body) : undefined,
      });
      assert.equal(response.headers.get('cache-control'), 'no-store');
      return response;
    };
    assert.equal((await (await request('tabs')).json()).running, false);
    const { stdout } = await exec('woven-browser', ['endpoint'], { timeout: 20000 });
    assert.match(stdout.trim(), /^ws:\/\/127\.0\.0\.1:\d+\/devtools\/browser\//);
    const endpoint = new URL(stdout.trim());
    const interfaces = Object.values(require('node:os').networkInterfaces()).flat();
    for (const address of interfaces.filter(value => value.family === 'IPv4' && !value.internal)) {
      await assert.rejects(fetch(`http://${address.address}:${endpoint.port}/json/version`, { signal: AbortSignal.timeout(1500) }));
    }
    browser = await chromium.connectOverCDP(stdout.trim());
    const sharedPage = await browser.contexts()[0].newPage();
    await sharedPage.goto(url);
    const sharedTab = (await (await request('tabs')).json()).tabs.find(tab => tab.url === url);
    assert.ok(sharedTab);
    const firstFrame = await (await request('frame', { tabID: sharedTab.id })).json();
    assert.equal(firstFrame.tabID, sharedTab.id);
    assert.equal(Buffer.from(firstFrame.imageBase64, 'base64').readUInt16BE(), 0xffd8);
    await sharedPage.getByRole('textbox', { name: 'Name' }).fill('visible in the Mac app');
    await sharedPage.getByRole('button', { name: 'Greet' }).click();
    const changedFrame = await (await request('frame', { tabID: sharedTab.id })).json();
    assert.notEqual(changedFrame.imageBase64, firstFrame.imageBase64);
    await browser.close(); browser = undefined;
    assert.ok((await (await request('tabs')).json()).tabs.some(tab => tab.id === sharedTab.id));
    assert.equal((await request('frame', { tabID: sharedTab.id })).status, 200);
    browser = await chromium.connectOverCDP(stdout.trim());
    await browser.contexts()[0].pages().find(page => page.url() === url).close();
    assert.equal((await request('frame', { tabID: sharedTab.id })).status, 410);
    await browser.close(); browser = undefined;
    console.log('Workspace Chromium: navigation, forms, screenshots, CLI, shared live view and bundled core passed.');
  } finally {
    await browser?.close();
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    process.chdir('/home');
    await rm(directory, { recursive: true, force: true });
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
