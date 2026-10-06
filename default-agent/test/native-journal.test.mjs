import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, open, readFile, stat, rm } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { openNativeArchive, openNativeJournal, sanitizeNativeTransportBytes } from '../src/native-journal.mjs';

test('encoded native transport copies reuse endpoint sanitization while arbitrary user base64 remains untouched', async () => {
  const capability = '/private/tmp/wmtools-' + 'a'.repeat(32) + '/' + 'b'.repeat(32) + '.sock';
  const remote = '/home/.wmt/' + 'c'.repeat(32) + '/' + 'd'.repeat(32) + '/wovenmatter';
  const userBase64 = Buffer.from(capability).toString('base64');
  const original = Buffer.from(JSON.stringify({ tool: capability, nested: JSON.stringify({ remote, unchanged: '🙂漢字', userBase64 }), userBase64 }));
  const safe = await sanitizeNativeTransportBytes(original), reconstructed = Buffer.from(safe.bytes.toString('base64'), 'base64'), parsed = JSON.parse(reconstructed);
  assert.ok(!reconstructed.toString().includes('wmtools-')); assert.ok(!reconstructed.toString().includes('.wmt'));
  assert.equal(parsed.userBase64, userBase64); assert.equal(JSON.parse(parsed.nested).userBase64, userBase64);
  assert.equal(JSON.parse(parsed.nested).unchanged, '🙂漢字');
  assert.equal(safe.byteFidelity, 'tool-endpoint-redacted');
  assert.equal(safe.sourceSHA256, createHash('sha256').update(original).digest('hex')); assert.equal(safe.sha256, createHash('sha256').update(reconstructed).digest('hex'));
  assert.equal(safe.sourceBytes, original.length); assert.equal(safe.totalBytes, reconstructed.length);
  const plain = Buffer.from(JSON.stringify({ userBase64, other: '/private/tmp/ordinary.sock', unicode: '🙂' })), exact = await sanitizeNativeTransportBytes(plain);
  assert.deepEqual(exact.bytes, plain); assert.equal(exact.byteFidelity, 'exact-native-bytes'); assert.equal(exact.sha256, exact.sourceSHA256);
});

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

test('current oversized capture redacts tool endpoints and preserves unrelated native content', async t => {
  const path = await fixture(t), { archive, sourceSHA256 } = await oversizedFixture(path, { endpoint: true });
  const before = await hashFile(path), output = path + '.sanitized';
  const { manifest, searchableToken, searchableUnicode } = await reconstruct(archive, output);
  assert.ok(searchableToken && searchableUnicode);
  assert.equal(manifest.sourceSHA256, sourceSHA256); assert.notEqual(manifest.sha256, sourceSHA256);
  assert.equal(manifest.byteFidelity, 'tool-endpoint-redacted'); assert.equal(await hashFile(path), before);
  let carry = '', foundUnicode = false, foundToken = false, markers = 0;
  const decoder = new TextDecoder();
  for await (const bytes of createReadStream(output, { highWaterMark: 65536 })) {
    const text = decoder.decode(bytes, { stream: true }), window = carry + text;
    assert.ok(!window.includes('wmtools-')); assert.ok(!window.includes('b'.repeat(32)));
    foundUnicode ||= window.includes('🙂漢字'); foundToken ||= window.includes('ordinary-token=preserve-me');
    markers += [...window.matchAll(/\[Woven Matter session tool endpoint\]/g)].filter(match => match.index + match[0].length > carry.length).length;
    carry = window.slice(-128);
  }
  assert.ok(foundUnicode && foundToken); assert.equal(markers, 3);
});

test('fresh transport spools preserve ordinary encoding and never overwrite an existing file', async t => {
  const path = await fixture(t), archive = await openNativeArchive(path);
  const record = { id: 'ordinary', revision: 'a', kind: 'tool', payload: 'x'.repeat(65535) + '🙂\n"\\' + '\ud800', optional: undefined, nested: { null: null, false: false, list: [1, '二', null] } };
  await archive.append([record]);
  const expected = JSON.stringify(record) + String.fromCharCode(10);
  assert.equal(await readFile(path, 'utf8'), expected);
  assert.equal(archive.index.length, 1); assert.ok(archive.identities.has('ordinary:a'));
  assert.deepEqual((await archive.page(0, 1)).records, [JSON.parse(JSON.stringify(record))]);
  await assert.rejects(openNativeArchive(path), { code: 'EEXIST' });
  assert.equal(await readFile(path, 'utf8'), expected);
  const medium = { id: 'medium', kind: 'tool', payload: '漢🙂'.repeat(80000) };
  await archive.append([medium]);
  const chunks = []; let after = 1, manifest;
  do {
    const page = await archive.page(after, 200);
    assert.ok(Buffer.byteLength(JSON.stringify(page.records)) <= 1048576);
    for (const item of page.records) {
      const payload = JSON.parse(item.payload);
      if (item.kind === 'native-file.chunk') chunks.push(Buffer.from(payload.dataBase64, 'base64'));
      else manifest = payload;
    }
    after = page.nextAfter; if (!page.hasMore) break;
  } while (true);
  assert.equal(manifest.originalRecord.id, 'medium');
  assert.equal(Buffer.concat(chunks).toString(), JSON.stringify(medium));
});

test('current journal pages seek through a large spool without retaining payload copies', async t => {
  const path = await fixture(t), journal = await openNativeJournal(path);
  const update = { sessionUpdate: 'woven_native_record', payload: 'x'.repeat(524288) };
  for (let index = 0; index < 257; index++) await journal.append([update]);
  assert.ok((await stat(path)).size > 134217728);
  let after = 253;
  do {
    const page = await journal.page(after);
    assert.ok(Buffer.byteLength(JSON.stringify(page.updates)) <= 1048576);
    assert.equal(page.updates.length, 1); assert.deepEqual(page.updates[0], update);
    assert.equal(page.totalCount, 257); assert.ok(page.cursor > after);
    after = page.cursor; if (!page.hasMore) break;
  } while (true);
  await journal.append([{ sessionUpdate: 'finished', content: '🙂' }]);
  assert.equal(journal.index.length, 258);
  assert.deepEqual((await journal.page(257)).updates, [{ sessionUpdate: 'finished', content: '🙂' }]);
});
