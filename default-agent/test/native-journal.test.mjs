import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, open, readFile, rm } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { openNativeArchive } from '../src/native-journal.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'woven-native-stream-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return join(directory, 'native.jsonl');
}
async function hashFile(path) {
  const hash = createHash('sha256');
  for await (const bytes of createReadStream(path)) hash.update(bytes);
  return hash.digest('hex');
}
async function oversizedFixture(path, { endpoint = false } = {}) {
  const capability = '/private/tmp/wmtools-' + 'a'.repeat(32) + '/' + 'b'.repeat(32) + '.sock';
  let payload;
  if (endpoint) {
    payload = 'x'.repeat(65500) + capability;
    payload += 'y'.repeat(262100 - payload.length) + JSON.stringify(capability.replaceAll('/', String.raw`\/`));
    payload += 'z'.repeat(327679 - payload.length) + '🙂漢字 ordinary-token=preserve-me ';
    payload += '\\'.repeat(65536) + '/ordinary-marker';
    payload += '\\'.repeat(65536) + capability;
  } else {
    payload = '{"value":{"model":[{"role":"assistant","content":[{"type":"text","text":"';
    payload += 'x'.repeat(262143 - payload.length) + String.raw`\nword-after-newline `;
    payload += 'y'.repeat(524285 - payload.length) + String.raw`\u6f22\u5b57\ud83d\ude42 literal\\nkept `;
  }
  payload += 'x'.repeat(67108864 + 65536 - Buffer.byteLength(payload));
  if (!endpoint) payload += '"}]}]}}';
  const record = { id: 'huge-source', revision: 'first', kind: 'native.tool.result', payload, runID: 'fixture-run', contentMode: 'event' };
  const bytes = JSON.stringify(record), sourceSHA256 = createHash('sha256').update(bytes).digest('hex'), sourceBytes = Buffer.byteLength(bytes);
  const archive = await openNativeArchive(path);
  await archive.append([record]);
  return { archive, sourceSHA256, sourceBytes };
}

function cursorGreater(next, previous) {
  const position = cursor => typeof cursor === 'number' ? [cursor, 0] : [cursor.record, cursor.byteOffset];
  const [record, offset] = position(next), [oldRecord, oldOffset] = position(previous);
  return record > oldRecord || (record === oldRecord && offset > oldOffset);
}

async function reconstruct(archive, output, count = 3) {
  const file = await open(output, 'w', 0o600), hash = createHash('sha256'), parts = [], identities = []; let offset = 0, after = 0, pages = 0, manifest, searchableToken = false, searchableUnicode = false, searchableWord = false, searchableLiteral = false;
  try {
    do {
      const page = await archive.page(after, count);
      assert.ok(cursorGreater(page.nextAfter, after));
      assert.ok(Buffer.byteLength(JSON.stringify(page.records)) <= 1048576);
      assert.ok(page.records.length <= count);
      for (const record of page.records) {
        identities.push(record.id); assert.equal(record.runID, 'fixture-run');
        if (record.text) {
          assert.ok(!record.text.includes('wmtools-')); assert.ok(Buffer.byteLength(record.text) <= 263000);
          searchableToken ||= record.text.includes('ordinary-token=preserve-me');
          searchableUnicode ||= record.text.includes('🙂漢字') || record.text.includes('漢字🙂');
          searchableWord ||= record.text.includes('\nword-after-newline');
          searchableLiteral ||= record.text.includes(String.raw`literal\nkept`);
          assert.ok(!record.text.includes('literal\nkept'));
        }
        const payload = JSON.parse(record.payload);
        if (record.kind === 'native-file.chunk') {
          const bytes = Buffer.from(payload.dataBase64, 'base64'); assert.ok(bytes.length <= 262144);
          assert.equal(createHash('sha256').update(bytes).digest('hex'), payload.sha256);
          await file.write(bytes); hash.update(bytes); parts.push({ byteOffset: offset, byteCount: bytes.length, chunkID: record.id }); offset += bytes.length;
        } else { assert.equal(record.kind, 'native-file.manifest'); manifest = payload; }
      }
      after = page.nextAfter; pages++; if (!page.hasMore) break;
    } while (true);
  } finally { await file.close(); }
  assert.equal(after, archive.index.length); assert.equal(hash.digest('hex'), manifest.sha256);
  assert.equal(offset, manifest.totalBytes); assert.deepEqual(parts, manifest.parts);
  assert.equal(manifest.originalRecord.id, 'huge-source'); assert.equal(manifest.originalRecord.revision, 'first');
  assert.equal(manifest.originalRecord.kind, 'native.tool.result'); assert.equal(manifest.originalRecord.runID, 'fixture-run');
  assert.ok(pages > 80);
  return { manifest, identities, searchableToken, searchableUnicode, searchableWord, searchableLiteral };
}

test('current oversized capture preserves exact bytes, bounded pages and decoded search content', async t => {
  const path = await fixture(t), { archive, sourceSHA256, sourceBytes } = await oversizedFixture(path);
  const before = await hashFile(path), output = path + '.reconstructed';
  const { manifest, searchableUnicode, searchableWord, searchableLiteral } = await reconstruct(archive, output);
  assert.equal(archive.index.length, 1); assert.ok(archive.identities.has('huge-source:first'));
  assert.equal(manifest.sourceSHA256, sourceSHA256); assert.equal(manifest.sha256, sourceSHA256);
  assert.equal(manifest.sourceTotalBytes, sourceBytes); assert.equal(manifest.byteFidelity, 'exact-native-bytes');
  assert.equal(await hashFile(output), sourceSHA256); assert.equal(await hashFile(path), before);
  assert.ok(searchableUnicode && searchableWord && searchableLiteral);
  await assert.rejects(archive.page({ record: 0, byteOffset: 1 }, 200), /cursor/);
  await assert.rejects(archive.page({ record: 1, byteOffset: 0 }, 200), /cursor/);
  await assert.rejects(archive.page(0, 0), /budget/);
});
