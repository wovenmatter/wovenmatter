// Provider-free acceptance driver. The server, CLI, Pi adapter and native hooks
// come from the built app, rather than replacements in this fixture.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

const [resources, runtime, socket] = process.argv.slice(2);
const cli = join(resources, 'wovenmatter');
const root = await mkdtemp(join(tmpdir(), 'woven-html-harness-'));
const environment = { ...process.env, WOVENMATTER_CLI: cli, WOVENMATTER_SOCKET: socket };
const load = path => import(pathToFileURL(join(resources, path)).href);
let client, previews = 0;
const published = [];
try {
  const image = join(root, 'local image.svg');
  await writeFile(image, '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" fill="green"/></svg>');
  const html = `<!doctype html><html><head><style>body{padding:16px}.cards{display:grid;grid-template-columns:1fr 1fr;gap:12px}.card{height:120px}@media(max-width:450px){.cards{grid-template-columns:1fr}}</style></head><body><div class="cards"><div class="card"><img src="${image}" onload="console.log('local-image-loaded')"></div><div class="card"><button id="count" onclick="this.textContent=Number(this.textContent)+1">0</button></div></div><script>document.getElementById('count').click();console.log('counter:'+document.getElementById('count').textContent)</script></body></html>`;
  let invoke;
  if (runtime === 'default_agent') {
    const { automationTools } = await load('default-agent/src/automation-tools.mjs');
    const tools = automationTools(() => environment);
    assert.ok(tools.some(tool => tool.name === 'html_render'));
    assert.ok(tools.some(tool => tool.name === 'html_preview'));
    invoke = (name, input) => tools.find(tool => tool.name === name).execute(randomUUID(), input);
  } else if (runtime === 'opencode') {
    invoke = await openCodeCLI();
  } else {
    client = new Client({ name: `woven-${runtime}-acceptance`, version: '1' });
    await client.connect(new StdioClientTransport({ command: cli, args: ['mcp'], env: environment }));
    const tools = (await client.listTools()).tools;
    for (const name of ['html_preview', 'html_render']) {
      const tool = tools.find(tool => tool.name === name);
      assert.ok(tool); assert.equal(tool.annotations.readOnlyHint, true);
      assert.equal(tool.annotations.openWorldHint, true);
      assert.equal(tool.inputSchema.additionalProperties, false);
    }
    invoke = (name, input) => client.callTool({ name, arguments: input });
  }
  const heights = [];
  for (const [width, appearance] of [[728, 'light'], [390, 'dark']]) {
    const result = await invoke('html_preview', { html, width, appearance });
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
  const page = { html, title: `${runtime} HTML acceptance`, height: heights[0] };
  const rendered = await invoke('html_render', page);
  assert.ok(!rendered.isError, JSON.stringify(rendered));
  const reference = JSON.parse(rendered.content.find(part => part.type === 'text').text).htmlRender;
  assert.equal(reference.title, page.title); assert.ok(reference.id); published.push(reference.id);

  const missing = join(root, 'missing.png');
  const preview = await invoke('html_preview', { html: `<img src="${missing}">` });
  assert.ok(!preview.isError);
  assert.deepEqual(JSON.parse(preview.content.find(part => part.type === 'text').text).missingImages, [missing]);
  let rejected = false;
  try { rejected = (await invoke('html_render', { ...page, html: `<img src="${missing}">` })).isError === true; }
  catch { rejected = true; }
  assert.ok(rejected, 'Missing local images must prevent publication');
  rejected = false;
  try { rejected = (await invoke('html_render', { ...page, conversationID: randomUUID() })).isError === true; }
  catch { rejected = true; }
  assert.ok(rejected, 'A model cannot select another conversation');

  if (['codex', 'claude_code', 'grok_build'].includes(runtime)) {
    const invokeCLI = await nativeCLI();
    const fallback = await invokeCLI('html_render', { ...page, title: `${runtime} CLI fallback` });
    assert.ok(!fallback.isError, JSON.stringify(fallback));
    published.push(JSON.parse(fallback.content[0].text).htmlRender.id);
  }
  await rm(image);
  process.stdout.write(JSON.stringify({ runtime, previews, heights, published, deletedSourceImage: image }) + '\n');
} finally {
  await client?.close();
  await rm(root, { recursive: true, force: true });
}

function execute(arguments_, input, env) {
  return new Promise((resolve, reject) => {
    const child = spawn('/bin/sh', ['-c', arguments_], { env, stdio: ['pipe', 'pipe', 'pipe'] });
    const stdout = [], stderr = []; let size = 0;
    const deadline = setTimeout(() => { child.kill('SIGTERM'); reject(new Error('CLI fixture timed out')); }, 30000);
    child.stdout.on('data', chunk => { size += chunk.length; if (size > 1100000) child.kill('SIGTERM'); else stdout.push(chunk); });
    child.stderr.on('data', chunk => stderr.push(chunk));
    child.once('error', error => { clearTimeout(deadline); reject(error); });
    child.once('close', () => {
      clearTimeout(deadline);
      try {
        const response = JSON.parse(Buffer.concat(stdout).toString());
        resolve({ isError: !response.success, content: response.result?.content ?? [{ type: 'text', text: JSON.stringify(response.result ?? response) }] });
      } catch (error) { reject(new Error(`${error.message}: ${Buffer.concat(stderr).toString()}`)); }
    });
    child.stdin.on('error', () => {}); child.stdin.end(JSON.stringify(input));
  });
}
async function nativeCLI() {
  const { configure } = await load('harnesses/cli/adapter.mjs');
  const { enqueue } = await load('harnesses/cli/binding.mjs');
  const { handleHook } = await load('harnesses/cli/hook.mjs');
  const directory = join(root, 'binding');
  const context = { executablePath: cli, socketPath: socket, captureID: randomUUID() };
  const env = { ...environment, CODEX_CONFIG: '{}', GROK_HOME: join(root, 'grok') };
  configure(runtime, directory, [], env);
  enqueue(directory, context, ['HTML acceptance']);
  const identity = runtime === 'codex' ? { session_id: 'native', turn_id: 'turn' }
    : runtime === 'claude_code' ? { session_id: 'native', prompt_id: 'turn' } : { sessionId: 'native', promptId: 'turn' };
  handleHook(runtime, directory, { ...identity, hook_event_name: 'UserPromptSubmit', prompt: 'HTML acceptance' });
  return async (name, input) => {
    const field = runtime === 'codex' ? 'cmd' : 'command';
    const tool = runtime === 'codex' ? 'exec_command' : runtime === 'claude_code' ? 'Bash' : 'run_terminal_cmd';
    const result = handleHook(runtime, directory, { ...identity, hook_event_name: 'PreToolUse', tool_name: tool,
      tool_input: { [field]: 'wovenmatter html call --json -' } });
    const command = result.hookSpecificOutput.updatedInput[field];
    return execute(command, { ...input, action: name === 'html_render' ? 'render' : 'preview' }, env);
  };
}
async function openCodeCLI() {
  const { default: plugin } = await load('harnesses/cli/opencode.mjs');
  const context = { executablePath: cli, socketPath: socket, captureID: randomUUID() };
  const hooks = new Map(), storage = new Map(), registration = { dispose() {} };
  let methods;
  const tools = [{ id: 'bash', execute: async input => {
    const event = { env: { ...environment, WOVENMATTER_SOCKET: '/wrong-owner.sock', WOVENMATTER_CLI: '/wrong-cli' } };
    await hooks.get('shell:create.before')(event);
    return execute('wovenmatter html call --json -', input, event.env);
  } }];
  await plugin.setup({
    rpc: { register: async (_schema, handlers) => { methods = handlers; return registration; } },
    storage: { get: async key => storage.get(key), set: async (key, value) => storage.set(key, value) },
    session: { get: async () => ({}), messages: async () => ({ data: [
      { id: 'assistant', type: 'assistant' }, { id: 'user', type: 'user', metadata: { wovenTools: context } }
    ] }), hook: async (name, fn) => { hooks.set(name, fn); return registration; } },
    tool: { transform: async fn => { fn({ list: () => tools, update: (_, fn) => fn(tools[0]) }); return registration; } },
    shell: { hook: async (name, fn) => { hooks.set('shell:' + name, fn); return registration; } },
  });
  await methods.connect({ sessionID: 'session', context });
  return (name, input) => tools[0].execute({ ...input, action: name === 'html_render' ? 'render' : 'preview' }, { sessionID: 'session', messageID: 'assistant' });
}
