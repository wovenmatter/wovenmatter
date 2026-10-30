import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../default-agent/package.json', import.meta.url));
const { Client, StreamableHTTPClientTransport } = require('@modelcontextprotocol/client');
const endpoint = new URL(process.argv[2]);
assert.equal(endpoint.protocol, 'http:');
assert.equal(endpoint.hostname, '127.0.0.1');
assert.equal(endpoint.pathname, '/mcp');
const token = process.env.WOVEN_MCP_TEST_TOKEN;
const outside = process.argv[3] === '--outside';
if (!outside) assert.ok(token, 'The native fixture must supply its disposable bearer.');
const deadline = setTimeout(() => {
  process.stderr.write('Native HTTP MCP interoperability fixture timed out.\n');
  process.exit(1);
}, 15000);
deadline.unref();

const client = new Client({ name: 'woven-native-http-fixture', version: '1' }, { capabilities: {} });
const denied = new Client({ name: 'woven-native-denied-fixture', version: '1' }, { capabilities: {} });
try {
  await client.connect(new StreamableHTTPClientTransport(endpoint, {
    requestInit: { headers: outside ? {} : { authorization: `Bearer ${token}` } }
  }));
  assert.equal(client.getServerVersion()?.name, 'woven');
  const catalog = await client.listTools();
  assert.ok(catalog.tools.some(tool => tool.name === 'woven_notes_list'));
  assert.ok(catalog.tools.some(tool => tool.name === 'woven_notes_create'), 'Exposed Notes includes writes.');
  const result = await client.callTool({ name: 'woven_notes_list', arguments: {} });
  assert.equal(result.isError, false);
  assert.equal(result.structuredContent.success, true);
  assert.equal(typeof result.structuredContent.result.callerID, 'string');
  if (outside) assert.equal(result.structuredContent.result.callerID, 'woven:tailnet');
  await assert.rejects(denied.connect(new StreamableHTTPClientTransport(endpoint, {
    requestInit: { headers: { authorization: 'Bearer deliberately-invalid-fixture-bearer' } }
  })), /401|unauthoriz/i);
  process.stdout.write(JSON.stringify({ serverName: 'woven', listed: true, called: true,
    callerID: result.structuredContent.result.callerID, unauthorizedRejected: true }) + '\n');
} finally {
  clearTimeout(deadline);
  await Promise.allSettled([client.close(), denied.close()]);
}
