import test from 'node:test';
import assert from 'node:assert/strict';
import { createDefaultAgentService } from '../src/service.mjs';

test('bots receive access-only credentials, native Claude directories and the selected search key', async () => {
  const stored = {
    anthropic: { type: 'api_key', key: 'sk-fixture' },
    'openai-codex': { type: 'oauth', access: 'access-fixture', refresh: 'refresh-must-not-leave', expires: Date.now() + 60000, accountId: 'acct' },
    xai: { type: 'oauth', access: 'old', refresh: 'r', expires: Date.now() - 1 },
    brave: { key: 'brave-key' },
    'claude-subscription': { type: 'native', accountId: 'profile-1' },
  };
  const profiles = [];
  const engine = {
    config: { searchProvider: 'brave' },
    credentials: { read: async id => stored[id], candidates: async id => [{ id: 'default', credential: stored[id] }] },
    claude: {
      status: async profile => { profiles.push(profile); return { connected: true }; },
      environment: async () => ({ CLAUDE_CONFIG_DIR: '/dev/shm/woven-claude-1-x', CLAUDE_SECURESTORAGE_CONFIG_DIR: '/dev/shm/woven-claude-1-x', ANTHROPIC_API_KEY: 'never' }),
    },
  };
  const service = createDefaultAgentService({ cwd: '/unused', directory: '/unused', engineFactory: async () => engine });
  assert.deepEqual(await service.botCredentials({ provider: 'anthropic' }), { credential: { type: 'api_key', key: 'sk-fixture' } });
  const oauth = await service.botCredentials({ provider: 'openai-codex' });
  assert.deepEqual(Object.keys(oauth.credential).sort(), ['access', 'accountId', 'expires', 'type']);
  assert.ok(!JSON.stringify(oauth).includes('refresh'));
  assert.deepEqual(await service.botCredentials({ provider: 'xai' }), { credential: null }, 'expired access is not handed out');
  assert.deepEqual(await service.botCredentials({ provider: 'openrouter' }), { credential: null });
  assert.deepEqual(await service.botCredentials({ provider: 'web-search' }), { credential: { type: 'api_key', key: 'brave-key' }, searchProvider: 'brave' });
  const claude = await service.botCredentials({ provider: 'claude-subscription' });
  assert.deepEqual(claude, { credential: { type: 'native', configDir: '/dev/shm/woven-claude-1-x', secureStorageDir: '/dev/shm/woven-claude-1-x' } });
  assert.deepEqual(profiles, ['profile-1']);
  await assert.rejects(service.botCredentials({ provider: 'unknown' }), /Woven provider connection/);
});
