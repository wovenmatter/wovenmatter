import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (file) => readFileSync(new URL(file, root), 'utf8');
const json = (file) => JSON.parse(read(file));

test('Pi Bot shares the recorded Node release and all official checksums', () => {
  const selection = json('pi-bot/selection.json');
  const remote = json('remote/host/runtime-versions.json');
  assert.equal(selection.schema, 1);
  assert.equal(selection.protocol, 1);
  assert.equal(selection.repository, 'https://github.com/wovenmatter/pi-bot.git');
  assert.match(selection.commit, /^[a-f0-9]{40}$/);
  assert.equal(selection.node.version, read('default-agent/.node-version').trim());
  assert.equal(selection.node.version, remote.nodeVersion);
  assert.deepEqual(Object.keys(selection.node.sha256).sort(), ['darwin-arm64', 'darwin-x64', 'linux-arm64', 'linux-x64']);
  const prepare = read('scripts/prepare-default-agent.sh');
  for (const [platform, checksum] of Object.entries(selection.node.sha256)) {
    assert.match(checksum, /^[a-f0-9]{64}$/);
    if (platform.startsWith('linux-')) assert.equal(checksum, remote.nodeSHA256[platform]);
    else {
      const arch = platform.endsWith('arm64') ? 'arm64' : 'x86_64';
      assert.ok(prepare.includes(`${arch}) node_arch=${platform.slice(7)}; checksum=${checksum}`), platform);
    }
  }
});

test('npm tooling locks the same pnpm selection with registry integrity', () => {
  const selection = json('pi-bot/selection.json');
  const tooling = json('pi-bot/tooling/package.json');
  const lock = json('pi-bot/tooling/package-lock.json');
  assert.equal(tooling.dependencies.pnpm, selection.pnpm);
  assert.equal(lock.packages[''].dependencies.pnpm, selection.pnpm);
  assert.equal(lock.packages['node_modules/pnpm'].version, selection.pnpm);
  assert.match(lock.packages['node_modules/pnpm'].integrity, /^sha512-/);
});
