import test from 'node:test';
import assert from 'node:assert/strict';
import { Harness, MemoryStorage, createRegistry } from '@earendil-works/pi-durable';
import { createModels } from '@earendil-works/pi-ai/models';
import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
import { watchConversation } from '../src/durable-view.mjs';

test('state watches recover full history and coalesced window gaps without duplicating progress', { timeout: 15000 }, async t => {
  const harness = await Harness.open(new MemoryStorage(), { models: createModels(), registry: createRegistry() }, context);
  t.after(() => harness.close(context));
  const root = await harness.root(context);
  const append = index => root.submit({ type: 'write', requestId: `entry-${index}`, entry: { kind: 'fixture', data: { index }, model: [{ role: 'assistant', content: [{type:'text',text:String(index)}] }] } }, context);
  for (let index = 0; index < 151; index++) await append(index);
  const watch = await watchConversation(root, context);
  t.after(() => watch.stop());
  assert.equal(watch.snapshot.entries.length, 151, 'initial snapshot must page beyond the default 50-entry window');
  const entered = Promise.withResolvers(), release = Promise.withResolvers(), caughtUp = Promise.withResolvers();
  t.after(() => release.resolve());
  const receipts = [];
  watch.start(async events => {
    receipts.push(...events.filter(event => event.type === 'message_end').map(event => event.entry.data.index));
    if (receipts.length === 1) { entered.resolve(); await release.promise; }
    if (watch.snapshot.entries.length === 352) caughtUp.resolve();
  });
  await append(151); await entered.promise;
  for (let index = 152; index < 352; index++) await append(index);
  release.resolve(); await caughtUp.promise;
  assert.deepEqual(watch.snapshot.entries.map(entry => entry.data.index), Array.from({length:352}, (_,i) => i));
  assert.deepEqual(receipts, Array.from({length:201}, (_,i) => i+151), 'only newly committed entries grant progress');
  await watch.stop();
  const reopened = await watchConversation(root, context);
  assert.equal(reopened.snapshot.entries.length, 352);
  const changed = Promise.withResolvers();
  reopened.start(async events => changed.resolve(events));
  await root.submit({ type: 'write', requestId: 'metadata', entry: {kind:'fixture.metadata',data:{index:352}} }, context);
  const events = await changed.promise;
  assert.equal(events.filter(event => event.type === 'message_end').length, 0, 'metadata/input placement is not completed model work');
  assert.equal(events.filter(event => event.type === 'entry_appended').length, 1);
  await reopened.stop();
});
