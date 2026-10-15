import { chromium } from 'playwright-core';
import { WebSocketServer } from 'ws';
import { randomUUID } from 'node:crypto';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';

// One authorized CEF page, one invocation, one private connection. CEF never
// opens a debugging port. Native CDP traffic stays on the app-owned stdio pipe.
export async function createCEFBridge({ target, version, sendNative, receiveNative }) {
  const token = randomUUID(), sessionId = 'woven-page';
  const server = new WebSocketServer({ host: '127.0.0.1', port: 0, maxPayload: 4 * 1024 * 1024 });
  await new Promise((resolve, reject) => { server.once('listening', resolve); server.once('error', reject); });
  let peer, nextId = 0, utilityWorld;
  const calls = new Map();
  const info = { targetId: target.id, type: 'page', title: target.title, url: target.url, attached: true, browserContextId: 'woven-context' };
  const unsubscribe = receiveNative(message => {
    if (message.method === 'Runtime.executionContextCreated' && message.params.context.name === '__woven_utility_world') {
      message = { ...message, params: { ...message.params, context: { ...message.params.context, name: utilityWorld } } };
    }
    if (message.id !== undefined) {
      const call = calls.get(message.id);
      if (!call) return;
      calls.delete(message.id);
      if (call.resolve) { if (message.error) call.reject(new Error(message.error.message)); else call.resolve(message.result); return; }
      if (!peer || peer.readyState !== 1) return;
      peer.send(JSON.stringify({ ...message, id: call.id, ...(call.sessionId ? { sessionId: call.sessionId } : {}) }));
    } else if (peer?.readyState === 1) peer.send(JSON.stringify({ ...message, sessionId: message.sessionId ?? sessionId }));
  });
  server.on('connection', (socket, request) => {
    if (peer || request.url !== '/' + token) { socket.close(1008); return; }
    peer = socket;
    socket.on('message', bytes => {
      let message;
      try { message = JSON.parse(bytes.toString()); } catch { socket.close(1008); return; }
      const { id, method, params = {}, sessionId: incomingSession } = message;
      const reply = result => socket.send(JSON.stringify({ id, result, ...(incomingSession ? { sessionId: incomingSession } : {}) }));
      if (!incomingSession) {
        if (method === 'Browser.getVersion') return reply({ protocolVersion: '1.3', product: 'Chrome/' + version, revision: '', userAgent: 'WovenMatter/CEF (Macintosh)' });
        if (method === 'Target.getTargetInfo') return reply({ targetInfo: info });
        if (method === 'Target.getTargets') return reply({ targetInfos: [info] });
        if (method === 'Target.setAutoAttach') {
          if (params.autoAttach) socket.send(JSON.stringify({ method: 'Target.attachedToTarget', params: { sessionId, targetInfo: info, waitingForDebugger: false } }));
          return reply({});
        }
        // Native CEF owns download destinations and completion, not Playwright.
        if (method === 'Browser.setDownloadBehavior') return reply({});
        return socket.send(JSON.stringify({ id, error: { code: -32601, message: 'This connection controls one embedded page. Use Woven Matter tab tools.' } }));
      }
      const nativeId = ++nextId;
      if (params.worldName?.startsWith('__playwright_utility_world_')) {
        utilityWorld = params.worldName; params.worldName = '__woven_utility_world';
      }
      calls.set(nativeId, { id, sessionId: incomingSession });
      sendNative({ id: nativeId, method, params, ...(incomingSession === sessionId ? {} : { sessionId: incomingSession }) });
    });
  });
  return {
    endpoint: `ws://127.0.0.1:${server.address().port}/${token}`,
    setTargetId: id => { info.targetId = id; },
    command: (method, params) => new Promise((resolve, reject) => {
      const id = ++nextId; calls.set(id, { resolve, reject }); sendNative({ id, method, params });
    }),
    close: async () => { unsubscribe(); peer?.terminate(); await new Promise(resolve => server.close(resolve)); }
  };
}

export async function browserAction(page, input, command, waitDownload) {
  page.setDefaultTimeout(15000);
  page.setDefaultNavigationTimeout(20000);
  let scope = page;
  if (input.frame) {
    const handle = await page.locator(input.frame).elementHandle();
    scope = await handle?.contentFrame(); await handle?.dispose();
    if (!scope) throw new Error('Choose a current iframe selector.');
  }
  const selector = () => {
    if (typeof input.selector !== 'string' || !input.selector || input.selector.length > 4096) throw new Error('Provide a selector from the latest page snapshot.');
    return scope.locator(input.selector);
  };
  const viewportPoint = () => {
    if (input.frame || !Number.isFinite(input.x) || !Number.isFinite(input.y) || input.x < 0 || input.y < 0) {
      throw new Error('Provide viewport x/y coordinates without a frame selector.');
    }
    return [input.x, input.y];
  };
  switch (input.action) {
    case 'navigate': {
      const url = new URL(input.url);
      if (!['http:', 'https:', 'about:'].includes(url.protocol) || (url.protocol === 'about:' && url.href !== 'about:blank')) throw new Error('Use HTTP(S) or about:blank.');
      await page.goto(url.href, { waitUntil: 'domcontentloaded' }); break;
    }
    case 'snapshot': return { content: [{ type: 'text', text: (await scope.locator('body').ariaSnapshot()).slice(0, 100000) }] };
    case 'screenshot': {
      let bytes = await page.screenshot({ type: 'jpeg', quality: 55, scale: 'css', fullPage: false });
      if (bytes.length > 650000) bytes = await page.screenshot({ type: 'jpeg', quality: 20, scale: 'css', fullPage: false });
      if (bytes.length > 650000) throw new Error('The browser viewport exceeds the screenshot limit. Reduce its size and capture again.');
      return { content: [{ type: 'image', mimeType: 'image/jpeg', data: bytes.toString('base64') }] };
    }
    case 'click': {
      const options = { button: input.button ?? 'left', clickCount: input.clickCount ?? 1 };
      if (input.selector) await selector().click(options);
      else await page.mouse.click(...viewportPoint(), options);
      break;
    }
    case 'fill': await selector().fill(input.text); break;
    case 'type': if (input.selector) await selector().pressSequentially(input.text); else await page.keyboard.type(input.text); break;
    case 'press': if (input.selector) await selector().press(input.key); else await page.keyboard.press(input.key); break;
    case 'scroll': await page.mouse.wheel(input.x ?? 0, input.y ?? 500); break;
    case 'hover':
      if (input.selector) await selector().hover(); else await page.mouse.move(...viewportPoint());
      break;
    case 'select': await selector().selectOption(input.value); break;
    case 'check': await selector().setChecked(input.checked ?? true); break;
    case 'drag': await selector().dragTo(scope.locator(input.destination)); break;
    case 'evaluate': return { content: [{ type: 'text', text: JSON.stringify(await scope.evaluate(input.code)) ?? 'undefined' }] };
    case 'upload': {
      if (!/^[A-Za-z0-9+/]*={0,2}$/.test(input.data ?? '') || (input.data?.length ?? 0) > 2800000) throw new Error('Upload data must be base64 and at most 2 MiB.');
      const buffer = Buffer.from(input.data, 'base64');
      if (buffer.length > 2 * 1024 * 1024) throw new Error('Upload data must be base64 and at most 2 MiB.');
      await selector().setInputFiles({ name: input.name ?? 'upload', mimeType: input.mimeType ?? 'application/octet-stream', buffer }); break;
    }
    case 'download': {
      const waiting = waitDownload();
      waiting.catch(() => {}); // The click can fail before the wait completes.
      await selector().click();
      const receipt = await waiting;
      if (receipt.status !== 'complete') throw new Error('Download was cancelled or exceeded 64 MiB.');
      return { content: [{ type: 'text', text: JSON.stringify(receipt) }] };
    }
    case 'dialog': {
      await command('Page.handleJavaScriptDialog', { accept: input.accept ?? true, promptText: input.text });
      break;
    }
    default: throw new Error('Unknown browser action.');
  }
  return { content: [{ type: 'text', text: JSON.stringify({ url: page.url(), title: await page.title() }) }] };
}

async function main() {
  const lines = createInterface({ input: process.stdin });
  const listeners = new Set();
  const first = await new Promise(resolve => lines.once('line', line => resolve(JSON.parse(line))));
  lines.on('line', line => { try { const packet = JSON.parse(line); if (packet.native) for (const listener of listeners) listener(packet.native); } catch {} });
  const bridge = await createCEFBridge({ ...first, sendNative: cdp => process.stdout.write(JSON.stringify({ cdp }) + '\n'), receiveNative: listener => { listeners.add(listener); return () => listeners.delete(listener); } });
  let browser;
  try {
    if (first.input.action === 'dialog') {
      await bridge.command('Page.handleJavaScriptDialog', { accept: first.input.accept ?? true, promptText: first.input.text });
      process.stdout.write(JSON.stringify({ result: { content: [{ type: 'text', text: 'Browser dialog handled.' }] } }) + '\n');
      return;
    }
    // Chromium identifies the main frame by its native target ID. A UI tab UUID
    // cannot substitute for this: Playwright would lose the utility context.
    const { frameTree } = await bridge.command('Page.getFrameTree', {});
    bridge.setTargetId(frameTree.frame.id);
    browser = await chromium.connectOverCDP(bridge.endpoint, { noDefaults: true, timeout: 15000 });
    const page = browser.contexts()[0]?.pages()[0];
    if (!page) throw new Error('The embedded page is unavailable.');
    // Playwright normally dismisses dialogs. Explicit accept handles a site's
    // confirmation/prompt in the triggering action without desktop permissions.
    page.on('dialog', dialog => {
      (first.input.accept ? dialog.accept(first.input.text) : dialog.dismiss()).catch(() => {});
    });
    const waitDownload = () => new Promise((resolve, reject) => {
      const listener = message => {
        if (message.method !== 'Woven.downloadComplete') return;
        clearTimeout(timer); listeners.delete(listener); resolve(message.params);
      };
      const timer = setTimeout(() => { listeners.delete(listener); reject(new Error('Download timed out.')); }, 20000);
      listeners.add(listener);
    });
    const result = await browserAction(page, first.input, bridge.command, waitDownload);
    process.stdout.write(JSON.stringify({ result }) + '\n');
  } catch (error) {
    process.stdout.write(JSON.stringify({ error: String(error.message).slice(0, 2000) }) + '\n');
  } finally {
    await browser?.close().catch(() => {});
    await bridge.close(); lines.close();
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main().catch(() => { process.exitCode = 1; });
