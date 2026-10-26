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
    <input id=range type=range min=0 max=100 value=0 aria-label=Level>
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
    await verifyInteraction(sharedPage, sharedTab.id, request);
    await sharedPage.getByRole('textbox', { name: 'Name' }).fill('');
    const batchFrame = await (await request('frame', { tabID: sharedTab.id })).json();
    const actions = Array.from({ length: 30 }, () => ({ kind: 'key', key: 'a', text: 'a', tabID: sharedTab.id,
      frameID: batchFrame.frameID, actionID: require('node:crypto').randomUUID() }));
    const batch = await request('actions', { actions });
    assert.equal(batch.status, 200); assert.equal((await batch.json()).results.length, 30);
    assert.equal(await sharedPage.getByRole('textbox', { name: 'Name' }).inputValue(), 'a'.repeat(30));
    const stream = await fetch(serviceURL + '/v1/browser/stream?tabID=' + sharedTab.id, {
      headers: { Authorization: 'Bearer ' + process.env.WOVENMATTER_API_TOKEN }, signal: AbortSignal.timeout(5000),
    });
    assert.equal(stream.status, 200); assert.equal(stream.headers.get('cache-control'), 'no-store');
    const reader = stream.body.getReader(); let line = '';
    while (!line.includes('\n')) { const { value, done } = await reader.read(); assert.ok(!done); line += Buffer.from(value).toString(); }
    const streamed = JSON.parse(line.split('\n')[0]);
    assert.equal(streamed.tabID, sharedTab.id); assert.ok(streamed.frameID);
    assert.equal(Buffer.from(streamed.imageBase64, 'base64').readUInt16BE(), 0xffd8);
    await reader.cancel();
    console.log('Shared browser performance transport: ordered 30-key batch and authenticated live stream passed.');
    await browser.close(); browser = undefined;
    assert.ok((await (await request('tabs')).json()).tabs.some(tab => tab.id === sharedTab.id));
    assert.equal((await request('frame', { tabID: sharedTab.id })).status, 200);
    browser = await chromium.connectOverCDP(stdout.trim());
    await browser.contexts()[0].pages().find(page => page.url() === sharedPage.url()).close();
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
async function verifyInteraction(page, tabID, request) {
  const assert = require('node:assert/strict');
  const originalURL = page.url();
  const otherTab = await page.context().newPage();
  await otherTab.goto(originalURL + '?agent=another-tab');
  const frame = async () => {
    const response = await request('frame', { tabID });
    assert.equal(response.status, 200, response.status === 200 ? undefined : await response.text());
    return response.json();
  };
  const input = async (gesture) => {
    const capture = await frame();
    const response = await request('action', { ...gesture, tabID, frameID: capture.frameID, actionID: require('node:crypto').randomUUID() });
    assert.equal(response.status, 200, JSON.stringify(gesture));
    const result = await response.json();
    assert.equal(result.accepted, true);
    return result;
  };
  const position = async (selector, fraction = 0.5) => {
    const box = await page.locator(selector).boundingBox();
    return { x: (box.x + box.width * fraction) / 1280, y: (box.y + box.height / 2) / 800 };
  };
  await input({ kind: 'click', ...await position('input[aria-label="Name"]') });
  await input({ kind: 'key', key: 'a', modifiers: 2 });
  await input({ kind: 'text', text: 'Human collaboration 日本語' });
  assert.equal(await page.getByRole('textbox', { name: 'Name' }).inputValue(), 'Human collaboration 日本語');
  await input({ kind: 'click', ...await position('button') });
  assert.equal(await page.locator('output').textContent(), 'Hello Human collaboration 日本語');
  // The agent retains this exact page/context and can continue after human input.
  await page.getByRole('textbox', { name: 'Name' }).fill('agent continued');
  await input({ kind: 'click', ...await position('input[aria-label="Name"]') });
  await input({ kind: 'key', key: 'a', modifiers: 2 });
  assert.equal((await input({ kind: 'copy' })).text, 'agent continued');
  await input({ kind: 'text', text: 'human returned' });
  assert.equal(await page.getByRole('textbox', { name: 'Name' }).inputValue(), 'human returned');
  const start = await position('#range', 0.05), end = await position('#range', 0.95);
  const gestureID = require('node:crypto').randomUUID();
  await input({ kind: 'pointerDown', gestureID, ...start });
  await input({ kind: 'pointerMove', gestureID, ...end });
  // The actual page changes while the button is held, not only after release.
  assert.ok(Number(await page.locator('#range').inputValue()) > 80);
  await input({ kind: 'pointerUp', gestureID, ...end });
  await page.evaluate(() => { document.body.style.minHeight = '3000px'; });
  await input({ kind: 'scroll', x: 0.5, y: 0.5, deltaX: 0, deltaY: 500 });
  await page.waitForFunction(() => window.scrollY > 0);
  const beforeNavigation = await frame();
  await input({ kind: 'navigate', text: originalURL + '?human=1' });
  await page.waitForURL(originalURL + '?human=1', { waitUntil: 'commit' });
  assert.equal((await request('action', { kind: 'text', text: 'stale input must not land', tabID,
    frameID: beforeNavigation.frameID, actionID: require('node:crypto').randomUUID() })).status, 409);
  // Repeated history restoration exercises captures before the next renderer paint.
  for (let visit = 0; visit < 5; visit++) {
    await input({ kind: 'back' });
    await page.waitForURL(originalURL, { waitUntil: 'commit' });
    await input({ kind: 'forward' });
    await page.waitForURL(originalURL + '?human=1', { waitUntil: 'commit' });
  }
  await input({ kind: 'reload' });
  assert.equal(await otherTab.getByRole('textbox', { name: 'Name' }).inputValue(), '');
  await otherTab.close();
  console.log('Shared browser collaboration: user click, typing, Unicode, select/copy, dragging, scrolling, navigation, stale-input rejection and agent continuation passed.');
}
module.exports = { verifyInteraction };
if (!module.parent) main().catch(error => { console.error(error); process.exitCode = 1; });
