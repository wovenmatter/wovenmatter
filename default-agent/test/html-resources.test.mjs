import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { prepareHTMLTool, imageMIME, HTML_IMAGE_LIMIT } from '../../harnesses/mcp/html-resources.mjs';
import { prepareHTMLTool as overlayHTMLTool, imageMIME as overlayImageMIME } from '../src/html-resources.mjs';
import { createMCPProxy } from '../../harnesses/mcp/proxy.mjs';
import { wovenMCPTools } from '../src/woven-mcp.mjs';

const png = Buffer.from([137,80,78,71,13,10,26,10]);
test('native harnesses and relocated SDK clients use the same HTML image implementation', () => {
  assert.equal(prepareHTMLTool, overlayHTMLTool);
  assert.equal(imageMIME, overlayImageMIME);
});
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'woven-html-images-'));
  t.after(() => rm(root, { recursive: true, force: true })); return root;
}
test('HTML preparation embeds caller images in markup, CSS and JS, preserving remote URLs', async t => {
  const root = await fixture(t), image = join(root, 'image café.png'), bare = join(root, 'bare.png');
  await writeFile(image, png); await writeFile(bare, png);
  const input = { html: `<img src="${image}"><style>.a{background:url('${image}')}.b{background:url(${bare})}</style><script>const p=\`${image}\`;</script><img src="//cdn.invalid/image.png"><img src="https://cdn.invalid/image.png">` };
  const result = await prepareHTMLTool('woven_html_preview', input);
  assert.equal(result.arguments.html.match(/data:image\/png;base64,/g).length, 4);
  assert.ok(result.arguments.html.includes('//cdn.invalid/image.png'));
  assert.ok(result.arguments.html.includes('https://cdn.invalid/image.png'));
  assert.deepEqual(result.missingImages, []);
  await rm(image); assert.ok(!result.arguments.html.includes(image));
  assert.equal((await prepareHTMLTool('woven_notes_set_html', input)).arguments, input);
});
test('HTML preparation rejects oversized pages/images and never embeds disguised text or FIFOs', async t => {
  const root = await fixture(t), image = join(root, 'large.png'), text = join(root, 'secret.png'), fifo = join(root, 'fifo.png');
  await writeFile(image, Buffer.concat([png, Buffer.alloc(HTML_IMAGE_LIMIT - png.length)]));
  const html = `<img src="${image}">`;
  assert.ok((await prepareHTMLTool('woven_html_render', { html })).arguments.html.length > HTML_IMAGE_LIMIT);
  await assert.rejects(prepareHTMLTool('woven_html_render', { html: html + html }), /25 MiB/);
  await writeFile(image, Buffer.alloc(HTML_IMAGE_LIMIT + 1));
  await assert.rejects(prepareHTMLTool('woven_html_preview', { html }), /10 MiB/);
  await writeFile(text, 'private text is not an image');
  assert.equal(spawnSync('/usr/bin/mkfifo', [fifo]).status, 0);
  const missing = `<img src="${text}"><img src="${fifo}"><img src="${text}">`;
  const preview = await prepareHTMLTool('woven_html_preview', { html: missing });
  assert.deepEqual(preview.missingImages, [text, fifo]); assert.ok(!preview.arguments.html.includes('private text'));
  await assert.rejects(prepareHTMLTool('woven_html_render', { html: missing }), /could not be read/);
  await assert.rejects(prepareHTMLTool('woven_html_render', { html: '🧶'.repeat(256001) }), /512,000/);
  assert.equal(imageMIME(Buffer.from('<?xml version="1.0"?><!--x--><!DOCTYPE svg [<!ENTITY x ">">]><svg/>')), 'image/svg+xml');
  assert.equal(imageMIME(Buffer.from('<html><svg/></html>')), undefined);
});
test('native proxy prepares images before forwarding and returns useful missing-image errors', async t => {
  const root = await fixture(t), image = join(root, 'local.svg');
  await writeFile(image, '<svg xmlns="http://www.w3.org/2000/svg"/>');
  const packets = [];
  const proxy = await createMCPProxy({ getConnection: () => ({ endpointURL: 'http://127.0.0.1:12345/mcp', bearerToken: 'fixture-upstream-token' }),
    fetchImpl: async (_url, options) => { packets.push(JSON.parse(options.body)); return new Response(JSON.stringify({ jsonrpc: '2.0', id: 1, result: {} }), { headers: { 'content-type': 'application/json' } }); } });
  t.after(() => proxy.close());
  const invoke = async (name, html) => (await fetch(proxy.connection.endpointURL, { method: 'POST', headers: {
    authorization: 'Bearer ' + proxy.connection.bearerToken, 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: { html } } }) })).json();
  await invoke('woven_html_render', `<img src="${image}">`);
  assert.ok(packets[0].params.arguments.html.includes('data:image/svg+xml;base64,'));
  await invoke('woven_html_preview', `<img src="${root}/missing.png">`);
  assert.deepEqual(packets[1].params._meta.wovenHTMLMissingImages, [root + '/missing.png']);
  const error = await invoke('woven_html_render', `<img src="${root}/missing.png">`);
  assert.equal(error.result.isError, true); assert.match(error.result.content[0].text, /could not be read/);
  assert.equal(packets.length, 2);
});
test('HTML publication cannot replay as a read even though it changes only the caller thread', () => {
  const [render, preview] = wovenMCPTools([
    { name: 'woven_html_render', annotations: { readOnlyHint: true, idempotentHint: false }, inputSchema: {} },
    { name: 'woven_html_preview', annotations: { readOnlyHint: true, idempotentHint: true }, inputSchema: {} },
  ], {}, () => ({}));
  assert.equal(render.replay, 'unsafe'); assert.equal(preview.replay, 'safe');
});
