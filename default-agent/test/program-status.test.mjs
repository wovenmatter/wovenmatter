import test from 'node:test';
import assert from 'node:assert/strict';
import { setImmediate } from 'node:timers/promises';
import { LiveDoc } from '@earendil-works/pi-durable';
import { reportProgramStatus } from '../src/program-status.mjs';
import { createSubagents, Subagents, ChildContext } from '../src/subagents.mjs';

test('unchanged output is coalesced without losing replacement fields, clears or attention repair', () => {
  const updates = [], record = { runID: 'run', emit: value => updates.push(value) };
  reportProgramStatus(record, { state: 'working', id: 'children/2', msg: 'Compacting' });
  reportProgramStatus(record, { state: 'working', id: 'children/2', msg: 'Compacting' });
  assert.equal(updates.length, 1);
  reportProgramStatus(record, { state: 'working', id: 'children/2' });
  assert.equal(updates.length, 2);
  assert.equal(updates.at(-1).status.msg, undefined);
  for (let index = 0; index < 2; index++) reportProgramStatus(record, { state: 'blocked', id: 'children/2', kind: 'auth' });
  assert.equal(updates.length, 4);
  for (let index = 0; index < 2; index++) reportProgramStatus(record, { state: 'clear' });
  assert.equal(updates.length, 6);
  reportProgramStatus(record, { state: 'working' });
  record.runID = 'next';
  reportProgramStatus(record, { state: 'working' });
  assert.equal(updates.at(-1)._meta.wovenRunID, 'next');
});

for (const scenario of ['block', 'resume', 'cancel']) test(`child notify preserves current authentication state across snapshot awaits: ${scenario}`, async () => {
  let release, entered;
  const paused = new Promise(resolve => { entered = resolve; });
  const gate = new Promise(resolve => { release = resolve; });
  const updates = [], snapshots = [];
  const one = { name: 'one', conversationId: 2, reporterIDs: [], stopping: scenario === 'cancel' };
  const two = { name: 'two', conversationId: 3, reporterIDs: [], stopping: false };
  const group = { children: { one, two } };
  const record = { runID: 'run', conversation: { id: 1 }, emit: value => updates.push(value),
    harness: {
      inspect: async () => ({ tasks: [{ record: { conversationId: 2 } }, { record: { conversationId: 3 } }], submissions: [] }),
      snapshot: async (doc, id) => {
        if (doc === Subagents) return group;
        if (doc === ChildContext) return { sessionID: String(id), name: id === 2 ? 'one' : 'two', connection: { id: 'fixture' } };
        if (doc === LiveDoc) {
          if (id === 3) { entered(); await gate; }
          return { run: 'active' };
        }
        throw Error('Unexpected fixture read');
      },
    }, session: { sessionId: 'native' }, manifest: { storeID: 'fixture' },
  };
  const report = state => reportProgramStatus(record, { state, id: 'children/2', kind: 'auth', ...(state === 'blocked' ? { msg: 'Waiting for authentication' } : {}) });
  report(scenario === 'resume' ? 'blocked' : 'working');
  const children = createSubagents({ record, engine: {}, context: {}, allTools: [], send: value => snapshots.push(value) });
  const notifying = children.notify();
  await paused;
  await setImmediate(); // Child 2 has finished; child 3 still holds Promise.all.
  report(scenario === 'resume' ? 'working' : 'blocked');
  release();
  await notifying;
  const child = snapshots.at(-1).subagents.find(value => value.nativeConversationID === '2');
  const latest = updates.findLast(value => value.status.id === 'children/2').status;
  assert.equal(child.state, scenario === 'block' ? 'blocked' : 'working');
  assert.equal(latest.state, child.state);
  assert.equal(latest.kind, scenario === 'block' ? 'auth' : undefined);
  assert.equal(latest.msg, scenario === 'block' ? 'Waiting for authentication' : scenario === 'cancel' ? 'Cancelling' : undefined);
});
