import test from 'node:test';
import { execFile } from 'node:child_process';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

const require = createRequire(import.meta.url);
const execute = promisify(execFile);
const piEntry = fileURLToPath(import.meta.resolve('@earendil-works/pi-coding-agent'));
const piRequire = createRequire(piEntry);

test('Pi HTTP dispatcher rejects excessive encodings without crashing and still decodes normal gzip responses', { timeout: 15000 }, async () => {
  // An unhandled dependency error must fail the child, without terminating
  // the other test files. All HTTP traffic stays on the fixture's loopback port.
  await execute(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import { createServer } from 'node:http';
    import { gzipSync } from 'node:zlib';
    import { setTimeout as delay } from 'node:timers/promises';
    import { configureHttpDispatcher } from ${JSON.stringify(pathToFileURL(join(dirname(piEntry), 'core/http-dispatcher.js')).href)};
    import { getGlobalDispatcher } from ${JSON.stringify(pathToFileURL(piRequire.resolve('undici')).href)};
    const server = createServer((request, response) => {
      if (request.url === '/malformed') {
        response.writeHead(200, { 'content-encoding': 'gzip, gzip, gzip, gzip, gzip, gzip', 'content-length': '100' });
        response.flushHeaders(); response.socket.end(); return;
      }
      const body = gzipSync('{"fixture":true}');
      response.writeHead(200, { 'content-encoding': 'gzip', 'content-type': 'application/json', 'content-length': body.length }); response.end(body);
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    try {
      configureHttpDispatcher(1000);
      const origin = 'http://127.0.0.1:' + server.address().port;
      await assert.rejects(fetch(origin + '/malformed'), /fetch failed/);
      await delay(100);
      assert.deepEqual(await (await fetch(origin + '/valid')).json(), { fixture: true });
    } finally {
      await getGlobalDispatcher().close(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    }
  `], { timeout: 10000, env: { PATH: process.env.PATH } });
});

test('MCP body parser survives trailing compressed bytes and continues parsing JSON', { timeout: 15000 }, async () => {
  await execute(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import { createServer, request } from 'node:http';
    import { gzipSync } from 'node:zlib';
    import { setTimeout as delay } from 'node:timers/promises';
    import bodyParser from ${JSON.stringify(pathToFileURL(require.resolve('body-parser')).href)};
    const parser = bodyParser.json();
    const server = createServer((input, output) => parser(input, output, error => {
      output.writeHead(error ? 400 : 200, { 'content-type': 'application/json' });
      output.end(JSON.stringify(error ? { rejected: true } : input.body));
    }));
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const send = body => new Promise((resolve, reject) => {
      const call = request({ host: '127.0.0.1', port: server.address().port, method: 'POST',
        headers: { 'content-type': 'application/json', 'content-encoding': 'gzip', 'content-length': body.length } }, response => {
        let text = ''; response.on('data', bytes => text += bytes); response.on('end', () => resolve({ status: response.statusCode, body: JSON.parse(text) }));
      });
      call.on('error', reject); call.end(body);
    });
    try {
      await send(Buffer.concat([gzipSync('{"malformed":true}'), Buffer.from('trailing invalid gzip bytes')]));
      await delay(100);
      assert.deepEqual(await send(gzipSync('{"fixture":true}')), { status: 200, body: { fixture: true } });
    } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  `], { timeout: 10000, env: { PATH: process.env.PATH } });
});
