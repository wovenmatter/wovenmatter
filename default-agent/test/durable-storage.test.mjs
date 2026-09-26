import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, open, readFile, readdir, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { writePrivateJSON } from '../src/config.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'woven-durable-storage-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const handle = await open(join(directory, 'probe'), 'w');
  const prototype = Object.getPrototypeOf(handle);
  await handle.close();
  return { directory, prototype, path: join(directory, 'state.json') };
}

test('private replacements flush contents before rename and the directory before acknowledgement', async t => {
  const { directory, prototype, path } = await fixture(t);
  await writePrivateJSON(path, { revision: 1 });
  const sync = prototype.sync;
  const observed = [];
  t.mock.method(prototype, 'sync', async function () {
    observed.push({ directory: (await this.stat()).isDirectory(), value: JSON.parse(await readFile(path, 'utf8')) });
    return sync.call(this);
  });
  await writePrivateJSON(path, { revision: 2 });
  assert.deepEqual(observed, [
    { directory: false, value: { revision: 1 } },
    { directory: true, value: { revision: 2 } },
  ]);
  assert.equal((await stat(path)).mode & 0o777, 0o600);
  assert.deepEqual((await readdir(directory)).sort(), ['probe', 'state.json']);
});

test('failed flush preserves the prior file and removes the partial replacement', async t => {
  const { directory, prototype, path } = await fixture(t);
  await writePrivateJSON(path, { revision: 1 });
  t.mock.method(prototype, 'sync', async () => { throw new Error('fixture disk failure'); });
  await assert.rejects(writePrivateJSON(path, { revision: 2 }), /fixture disk failure/);
  assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), { revision: 1 });
  assert.deepEqual((await readdir(directory)).sort(), ['probe', 'state.json']);
});
