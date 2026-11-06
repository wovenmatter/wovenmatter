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

test('Pi model globs retain matching semantics and reject amplification patterns within a bounded child', { timeout: 15000 }, async () => {
  await execute(process.execPath, ['--max-old-space-size=96', '--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import { createRequire } from 'node:module';
    import { resolveModelScopeWithDiagnostics } from '@earendil-works/pi-coding-agent';
    const fromPi = createRequire(${JSON.stringify(piEntry)});
    const { Minimatch, minimatch } = fromPi('minimatch');
    const models = [{ id: 'alpha', provider: 'fixture' }, { id: 'beta', provider: 'fixture' }];
    const scope = await resolveModelScopeWithDiagnostics(['FIXTURE/a*:high', 'b[ae]ta'], { getAvailable: async () => models });
    assert.deepEqual(scope.scopedModels.map(x => [x.model.id, x.thinkingLevel]), [['alpha', 'high'], ['beta', undefined]]);
    assert.deepEqual(scope.diagnostics, []);
    assert.equal(minimatch('skills/nested/SKILL.md', 'skills/**/SKILL.md'), true);
    assert.equal(minimatch('skills/private/SKILL.md', 'skills/!(private)/**'), false);
    // GHSA-g3hv-75wg-m249: globstar/parent preprocessing used to amplify
    // entries exponentially at optimization level 2. Failure kills only this child.
    const pattern = '**/../a/b/'.repeat(24) + 'fixture';
    // 11.0.5 refuses the whole over-budget pattern instead of returning a
    // partially optimized match whose result can depend on traversal order.
    assert.throws(() => new Minimatch(pattern, { optimizationLevel: 2, braceExpandMax: 64 }),
      error => error instanceof RangeError && error.message.includes('too many patterns'));
    // Large numeric ranges use one matcher, without expanding a billion rows.
    const numeric = new Minimatch('model-{1..1000000000}', { braceExpandMax: 64 });
    assert.equal(numeric.match('model-999999999'), true);
    assert.equal(numeric.match('model-1000000001'), false);
    const numericScope = await resolveModelScopeWithDiagnostics(['fixture/model-{1..1000000000}*'],
      { getAvailable: async () => [{ id: 'model-999999999', provider: 'fixture' }] });
    assert.deepEqual(numericScope.scopedModels.map(x => x.model.id), ['model-999999999']);
  `], { timeout: 10000, cwd: new URL('..', import.meta.url), env: { PATH: process.env.PATH } });
});

test('effective IP parser escapes invalid IPv6 characters while retaining address classification', { timeout: 10000 }, async () => {
  await execute(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import { createRequire } from 'node:module';
    const { Address6 } = createRequire(${JSON.stringify(import.meta.url)})('ip-address');
    assert.equal(new Address6('2001:db8::1').correctForm(), '2001:db8::1');
    assert.equal(new Address6('::ffff:127.0.0.1').isLoopback(), true);
    for (const character of ['<', '>', '&', '"', "'"]) {
      assert.throws(() => new Address6('2001:db8::' + character), error => {
        assert.equal(error.name, 'AddressError');
        const encoded = { '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&#39;' }[character];
        assert.ok(error.parseMessage.includes('<span class="parse-error">' + encoded + '</span>'), error.parseMessage);
        return true;
      });
    }
  `], { timeout: 5000, env: { PATH: process.env.PATH } });
});

test('Pi HTTP redirects strip tuple-form credentials across origins and preserve same-origin headers', { timeout: 15000 }, async () => {
  await execute(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import { createServer } from 'node:http';
    import { createRequire } from 'node:module';
    const { Agent, request, interceptors } = createRequire(${JSON.stringify(piEntry)})('undici');
    const received = [];
    const target = createServer((input, output) => {
      received.push(input.headers);
      output.end('cross-origin');
    });
    await new Promise(resolve => target.listen(0, '127.0.0.1', resolve));
    const source = createServer((input, output) => {
      if (input.url === '/same') {
        received.push(input.headers);
        output.end('same-origin');
      } else {
        output.writeHead(302, { location: input.url === '/local' ? '/same'
          : 'http://127.0.0.1:' + target.address().port + '/target' });
        output.end();
      }
    });
    await new Promise(resolve => source.listen(0, '127.0.0.1', resolve));
    // The socket dispatcher consumes flat arrays; the redirect interceptor's
    // public header input also accepts tuples. Normalize only at the socket
    // boundary so redirect handling still receives the original representation.
    const flattenHeaders = dispatch => function (options, handler) {
      return dispatch({ ...options, headers: Array.isArray(options.headers?.[0])
        ? options.headers.flat() : options.headers }, handler);
    };
    const dispatcher = new Agent().compose(flattenHeaders, interceptors.redirect({ maxRedirections: 2 }));
    const headers = [['authorization', 'Bearer fixture'], ['cookie', 'fixture=secret'], ['x-fixture', 'retained']];
    try {
      const origin = 'http://127.0.0.1:' + source.address().port;
      assert.equal(await (await request(origin + '/local', { dispatcher, headers })).body.text(), 'same-origin');
      assert.equal(await (await request(origin + '/remote', { dispatcher, headers })).body.text(), 'cross-origin');
      assert.equal(received[0].authorization, 'Bearer fixture');
      assert.equal(received[0].cookie, 'fixture=secret');
      assert.equal(received[0]['x-fixture'], 'retained');
      assert.equal(received[1].authorization, undefined);
      assert.equal(received[1].cookie, undefined);
      assert.equal(received[1]['x-fixture'], 'retained');
    } finally {
      await dispatcher.close();
      for (const server of [source, target]) {
        server.closeAllConnections();
        await new Promise(resolve => server.close(resolve));
      }
    }
  `], { timeout: 10000, env: { PATH: process.env.PATH } });
});
