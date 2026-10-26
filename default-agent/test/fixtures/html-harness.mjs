// Provider-free acceptance driver. The MCP clients, Pi adapter and native hooks
// come from the built app, rather than replacements in this fixture.
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID, createHash } from 'node:crypto';
import { Client, StreamableHTTPClientTransport } from '@modelcontextprotocol/client';

const [resources, runtime, endpointURL] = process.argv.slice(2);
const bound = { endpointURL, bearerToken: process.env.WOVEN_HTML_TEST_TOKEN, captureID: randomUUID() };
const root = await mkdtemp(join(tmpdir(), 'woven-html-harness-'));
const environment = { ...process.env, GROK_HOME: join(root, 'grok'), CODEX_CONFIG: '{}' };
const load = path => import(pathToFileURL(join(resources, path)).href);
let client, closeProxy, disposePlugin, piClient, previews = 0;
const published = [];
try {
  const image = join(root, 'local image.svg');
  await writeFile(image, '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" fill="green"/></svg>');
  const html = `<!doctype html><html><head><style>body{padding:16px}.cards{display:grid;grid-template-columns:1fr 1fr;gap:12px}.card{height:120px}@media(max-width:450px){.cards{grid-template-columns:1fr}}</style></head><body><div class="cards"><div class="card"><img src="${image}" onload="console.log('local-image-loaded')"></div><div class="card"><button id="count" onclick="this.textContent=Number(this.textContent)+1">0</button></div></div><script>document.getElementById('count').click();console.log('counter:'+document.getElementById('count').textContent)</script></body></html>`;
  let invoke;
  if (runtime === 'default_agent') {
    const { WovenMCPClient, wovenMCPTools } = await load('default-agent/src/woven-mcp.mjs');
    piClient = new WovenMCPClient();
    const tools = wovenMCPTools(await piClient.listTools(bound), piClient, () => bound);
    assert.ok(tools.some(tool => tool.name === 'woven_html_render' && tool.replay === 'unsafe'));
    assert.ok(tools.some(tool => tool.name === 'woven_html_preview' && tool.replay === 'safe'));
    invoke = (name, input) => tools.find(tool => tool.name === name).execute(randomUUID(), input);
  } else {
    let connection;
    if (runtime === 'opencode') {
      const { default: plugin } = await load('harnesses/mcp/opencode.mjs');
      const sessionID = 'html-acceptance', registration = { dispose() {} };
      const prefix = 'woven_' + createHash('sha256').update(sessionID).digest('hex').slice(0, 16);
      const tools = ['woven_html_preview', 'woven_html_render'].map(name => ({ id: prefix + '_' + name,
        execute: input => client.callTool({ name, arguments: input }) }));
      let methods;
      disposePlugin = await plugin.setup({
        rpc: { register: async (_schema, value) => { methods = value; return registration; } },
        session: { get: async () => ({}), hook: async () => registration },
        tool: { transform: async fn => { fn({ list: () => tools, update: (id, fn) => fn(tools.find(tool => tool.id === id)) }); return registration; } },
      });
      connection = await methods.connect({ sessionID, context: bound });
      invoke = (name, input) => tools.find(tool => tool.id === prefix + '_' + name).execute(input, { sessionID });
      await assert.rejects(tools[1].execute({}, { sessionID: 'other-session' }), /another session/);
    } else {
      const { configure } = await load('harnesses/mcp/adapter.mjs');
      configure(runtime, join(root, 'binding'), [], environment);
      const { createMCPProxy } = await load('harnesses/mcp/proxy.mjs');
      const proxy = await createMCPProxy({ getConnection: () => bound });
      closeProxy = () => proxy.close(); connection = proxy.connection;
      invoke = (name, input) => client.callTool({ name, arguments: input });
    }
    client = new Client({ name: `woven-${runtime}-acceptance`, version: '1' });
    await client.connect(new StreamableHTTPClientTransport(new URL(connection.endpointURL), {
      requestInit: { headers: { authorization: 'Bearer ' + connection.bearerToken }, redirect: 'error' },
    }));
    const tools = (await client.listTools()).tools;
    for (const name of ['woven_html_preview', 'woven_html_render']) {
      const tool = tools.find(tool => tool.name === name);
      assert.ok(tool); assert.equal(tool.annotations.readOnlyHint, true);
      assert.equal(tool.annotations.openWorldHint, true);
      assert.equal(tool.inputSchema.additionalProperties, false);
    }
  }
  const heights = [];
  for (const [width, appearance] of [[728, 'light'], [390, 'dark']]) {
    const result = await invoke('woven_html_preview', { html, width, appearance });
    assert.ok(!result.isError, JSON.stringify(result));
    const metadata = JSON.parse(result.content.find(part => part.type === 'text').text);
    assert.equal(metadata.width, width);
    assert.ok(metadata.contentHeight >= 80 && metadata.contentHeight < 1000);
    assert.ok(metadata.consoleMessages.some(line => line.text === 'counter:1'));
    assert.ok(metadata.consoleMessages.some(line => line.text === 'local-image-loaded'));
    assert.deepEqual(metadata.missingImages, []);
    const screenshot = result.content.find(part => part.type === 'image');
    assert.equal(screenshot.mimeType, 'image/png');
    assert.deepEqual([...Buffer.from(screenshot.data, 'base64').subarray(0, 8)], [137,80,78,71,13,10,26,10]);
    heights.push(metadata.contentHeight); previews++;
  }
  assert.ok(heights[1] > heights[0], 'Phone layout should be taller than desktop layout');
  const page = { html, requestID: randomUUID(), title: `${runtime} HTML acceptance`, height: heights[0] };
  const rendered = await invoke('woven_html_render', page);
  assert.ok(!rendered.isError, JSON.stringify(rendered));
  const reference = JSON.parse(rendered.content.find(part => part.type === 'text').text).htmlRender;
  assert.equal(reference.title, page.title); assert.ok(reference.id); published.push(reference.id);
  const replay = await invoke('woven_html_render', page);
  assert.equal(JSON.parse(replay.content[0].text).htmlRender.id, reference.id);

  const missing = join(root, 'missing.png');
  const preview = await invoke('woven_html_preview', { html: `<img src="${missing}">` });
  assert.ok(!preview.isError);
  assert.deepEqual(JSON.parse(preview.content.find(part => part.type === 'text').text).missingImages, [missing]);
  let rejected = false;
  try { rejected = (await invoke('woven_html_render', { ...page, html: `<img src="${missing}">` })).isError === true; }
  catch { rejected = true; }
  assert.ok(rejected, 'Missing local images must prevent publication');
  rejected = false;
  try { rejected = (await invoke('woven_html_render', { ...page, conversationID: randomUUID() })).isError === true; }
  catch { rejected = true; }
  assert.ok(rejected, 'A model cannot select another conversation');

  await rm(image);
  process.stdout.write(JSON.stringify({ runtime, previews, heights, published, deletedSourceImage: image }) + '\n');
} finally {
  await client?.close(); await piClient?.close(); closeProxy?.(); await disposePlugin?.();
  await rm(root, { recursive: true, force: true });
}
