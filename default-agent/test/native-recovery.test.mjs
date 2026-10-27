import test from 'node:test';
import assert from 'node:assert/strict';
import { recoverNativeRuns } from '../src/native-recovery.mjs';

function fixture() {
  const submissions = new Map(), entries = new Map();
  const requests = { input: { nativeRequestIDs: ['input:attempt:0'] } };
  submissions.set('input:attempt:0', { type: 'input', status: 'done', conversationId: 1, requestId: 'input:attempt:0', answer: 10 });
  entries.set(10, { id: 10, conversationId: 1, model: [{ role: 'assistant', content: [{ type: 'thinking', thinking: 'private' }, { type: 'text', text: 'Finished' }] }] });
  const tx = { submissionByRequest: async (_, id) => submissions.get(id), entry: async id => entries.get(id) };
  const runs = [{ runID: 'run', inputIDs: ['input'] }];
  return { submissions, entries, requests, tx, runs, recover: () => recoverNativeRuns(runs, requests, 1, tx) };
}


test('recovers only the latest answer segment while proving every input', async () => {
  const f = fixture();
  f.requests.steer = { nativeRequestIDs: ['steer:attempt:0'] };
  f.submissions.set('steer:attempt:0', { type: 'input', status: 'done', conversationId: 1, requestId: 'steer:attempt:0', answer: 12 });
  f.entries.set(12, { id: 12, conversationId: 1, model: [{ role: 'assistant', content: [{ type: 'text', text: 'Latest segment' }] }] });
  f.runs[0].inputIDs.unshift('steer');
  assert.deepEqual(await f.recover(), [{ runID: 'run', content: 'Latest segment' }]);
  f.submissions.get('input:attempt:0').status = 'placed';
  assert.deepEqual(await f.recover(), []);
  f.runs.push({ runID: 'another', inputIDs: ['input'] });
  await assert.rejects(f.recover(), /Ambiguous/);
});
