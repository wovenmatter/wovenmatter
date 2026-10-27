import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { accountDetails, signInStatuses, readCodexAccount } from '../src/sign-in-status.mjs';

test('OpenCode v2 stored account rows report credentials without verifying access', async () => {
  const stdout = 'OpenCode Go  OpenCode Go 2               stored\nOpenCode Go  OpenCode Go                 stored\nOpenCode Go  API key                     stored\n';
  const [status] = await signInStatuses([{ id: 'opencode', executable: '/fixture/opencode' }], async () => ({ stdout }));
  assert.equal(status.state, 'credentials_present');
  assert.deepEqual(status.accounts, [
    { name: 'OpenCode Go · OpenCode Go 2', method: 'Saved credential' },
    { name: 'OpenCode Go', method: 'Saved credential' },
    { name: 'OpenCode Go', method: 'API key' },
  ]);
  const [failed] = await signInStatuses([{ id: 'opencode', executable: '/fixture/opencode' }], async () => { throw { stdout }; });
  assert.equal(failed.state, 'check_failed');
  assert.deepEqual(failed.accounts, []);
  assert.deepEqual(accountDetails('opencode', 'OpenCode Go  sk-secret  stored\n'), []);
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
