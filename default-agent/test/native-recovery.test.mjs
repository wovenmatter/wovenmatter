import test from 'node:test';
import assert from 'node:assert/strict';
import { recoverNativeRuns } from '../src/native-recovery.mjs';
import { createDefaultAgentService } from '../src/service.mjs';

function fixture() {
  const submissions = new Map(), entries = new Map();
  const requests = { input: { nativeRequestIDs: ['input:attempt:0'] } };
  submissions.set('input:attempt:0', { type: 'input', status: 'done', conversationId: 1, requestId: 'input:attempt:0', answer: 10 });
  entries.set(10, { id: 10, conversationId: 1, model: [{ role: 'assistant', content: [{ type: 'thinking', thinking: 'private' }, { type: 'text', text: 'Finished' }] }] });
  const tx = { submissionByRequest: async (_, id) => submissions.get(id), entry: async id => entries.get(id) };
  const runs = [{ runID: 'run', inputIDs: ['input'] }];
  return { submissions, entries, requests, tx, runs, recover: () => recoverNativeRuns(runs, requests, 1, tx) };
}

test('recovers exact durable input answer without exposing thinking', async () => {
  const f = fixture();
  assert.deepEqual(await f.recover(), [{ runID: 'run', content: 'Finished' }]);
});

test('missing receipts, active attempts and missing answers stay uncertain', async () => {
  for (const change of [
    f => delete f.requests.input,
    f => f.submissions.clear(),
    f => { f.submissions.get('input:attempt:0').status = 'placed'; },
    f => f.entries.clear(),
    f => { f.entries.get(10).conversationId = 2; },
    f => { f.requests.input.nativeRequestIDs.push('input:attempt:1'); },
  ]) {
    const f = fixture(); change(f);
    assert.deepEqual(await f.recover(), []);
  }
});

test('uses final fallback and deduplicates shared answers for steering inputs', async () => {
  const f = fixture();
  f.submissions.get('input:attempt:0').status = 'unanswered';
  f.requests.input.nativeRequestIDs.push('input:attempt:1');
  f.submissions.set('input:attempt:1', { type: 'input', status: 'done', conversationId: 1, requestId: 'input:attempt:1', answer: 10 });
  f.requests.steer = { nativeRequestIDs: ['steer:attempt:0'] };
  f.submissions.set('steer:attempt:0', { type: 'input', status: 'done', conversationId: 1, requestId: 'steer:attempt:0', answer: 10 });
  f.runs[0].inputIDs.push('steer');
  assert.deepEqual(await f.recover(), [{ runID: 'run', content: 'Finished' }]);
});

test('recovers only the latest answer segment while proving every input', async () => {
  const f = fixture();
  f.requests.steer = { nativeRequestIDs: ['steer:attempt:0'] };
  f.submissions.set('steer:attempt:0', { type: 'input', status: 'done', conversationId: 1, requestId: 'steer:attempt:0', answer: 12 });
  f.entries.set(12, { id: 12, conversationId: 1, model: [{ role: 'assistant', content: [{ type: 'text', text: 'Latest segment' }] }] });
  f.runs[0].inputIDs.unshift('steer');
  assert.deepEqual(await f.recover(), [{ runID: 'run', content: 'Latest segment' }]);
  f.submissions.get('input:attempt:0').status = 'placed';
  assert.deepEqual(await f.recover(), []);
});

test('unanswered is a terminal error without exposing provider detail', async () => {
  const f = fixture();
  Object.assign(f.submissions.get('input:attempt:0'), { status: 'unanswered', reason: 'model_error', detail: 'secret provider body' });
  assert.deepEqual(await f.recover(), [{ runID: 'run', content: '', error: 'The native run ended without a completed answer.' }]);
});

test('rejects ambiguous input ownership', async () => {
  const f = fixture();
  f.runs.push({ runID: 'another', inputIDs: ['input'] });
  await assert.rejects(f.recover(), /Ambiguous/);
});

test('recovery requires current session attachment before engine dispatch', async () => {
  const calls = [];
  const service = createDefaultAgentService({ directory: '/unused-fixture', cwd: '/unused-fixture',
    attachmentState: { tokens: [['native', 'current']] },
    engineFactory: async () => ({ handle: async (method, params) => { calls.push(method); return { sessionId: params.sessionId, idle: true, runs: [] }; } }),
  });
  for (const attachmentToken of [undefined, 'replaced']) {
    await assert.rejects(service.invoke({ method: 'woven/recover', params: { sessionId: 'native', runs: [] }, attachmentToken }), /attachment was replaced/);
  }
  assert.deepEqual(calls, []);
  assert.deepEqual((await service.invoke({ method: 'woven/recover', params: { sessionId: 'native', runs: [] }, attachmentToken: 'current' })).result,
    { sessionId: 'native', idle: true, runs: [] });
  assert.deepEqual(calls, ['woven/recover']);
});
