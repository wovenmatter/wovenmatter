import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { accountDetails, signInStatuses, readCodexAccount } from '../src/sign-in-status.mjs';

test('status metadata only includes reported account labels and methods', async () => {
  assert.deepEqual(accountDetails('claude_code', JSON.stringify({ authMethod: 'claude.ai', email: 'person@example.test', accessToken: 'secret' })),
    [{ method: 'Claude subscription', name: 'person@example.test' }]);
  assert.deepEqual(accountDetails('opencode', '│ ● OpenAI oauth\n│ ● Anthropic api\n│ ● OpenAI OPENAI_API_KEY\n└ 2 credentials'),
    [{ name: 'OpenAI', method: 'OAuth' }, { name: 'Anthropic', method: 'API key' }, { name: 'OpenAI', method: 'Environment key · OPENAI_API_KEY' }]);
  const statuses = await signInStatuses([{ id: 'codex', executable: '/fixture/codex' }],
    async () => ({ stderr: 'Logged in using ChatGPT' }), async () => [{ method: 'ChatGPT', name: 'person@example.test' }]);
  assert.equal(statuses[0].state, 'verified');
  assert.equal(statuses[0].accounts[0].name, 'person@example.test');
  const failed = await signInStatuses([{ id: 'claude_code', executable: '/fixture/claude' }],
    async () => ({ stdout: '{"loggedIn":false,"email":"old@example.test"}' }));
  assert.deepEqual(failed[0].accounts, []);
  assert.deepEqual(accountDetails('claude_code', '{"authMethod":"api_key","apiKeyName":"sk-secret","apiKey":"sk-secret"}'), [{ method: 'API key', name: undefined }]);
});

test('Codex account read never refreshes tokens and stops its process', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'woven-account-fixture-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const executable = join(directory, 'codex');
  await writeFile(executable, `#!${process.execPath}
const readline = require('node:readline');
readline.createInterface({ input: process.stdin }).on('line', line => {
 const message = JSON.parse(line);
 if (message.method === 'initialize') process.stdout.write(JSON.stringify({id:1,result:{}})+'\\n');
 else if (message.method === 'account/read' && message.params.refreshToken === false)
   process.stdout.write(JSON.stringify({id:2,result:{account:{type:'chatgpt',email:'person@example.test',accessToken:'never-return'}}})+'\\n');
 else if (message.method !== 'initialized') process.exit(2);
});
`, { mode: 0o700 });
  assert.deepEqual(await readCodexAccount(executable), [{ method: 'ChatGPT', name: 'person@example.test' }]);
});
