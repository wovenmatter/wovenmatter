import test from 'node:test';
import assert from 'node:assert/strict';
import { forwardInferenceStream } from '../../ios/Runtime/inference-stream.js';

const model = {id:'fixture',api:'fixture-api',provider:'fixture-provider'};
for (const outcome of ['disconnect','cancel','missing-terminal']) test(`mobile inference ${outcome} retains native partial content and usage`, async () => {
  const controller = new AbortController(), events = []; let ended = false;
  const partial = {role:'assistant',content:[{type:'thinking',thinking:'Reason'},{type:'text',text:'🧵 partial'}],usage:{input:3,output:4,totalTokens:7}};
  await forwardInferenceStream({push:event=>events.push(event),end:()=>{ended=true;}}, model, controller.signal, async emit => {
    emit({type:'start',partial});
    if (outcome === 'cancel') controller.abort();
    if (outcome !== 'missing-terminal') throw new Error('Disconnected');
  });
  assert.equal(ended,true);
  assert.equal(events.at(-1).type,'error');
  assert.equal(events.at(-1).reason,outcome==='cancel'?'aborted':'error');
  assert.deepEqual(events.at(-1).error.content,partial.content);
  assert.deepEqual(events.at(-1).error.usage,partial.usage);
});

test('mobile terminal event wins over late bridge errors or duplicate provider frames', async () => {
  const events = []; let ended = 0;
  const done = {type:'done',reason:'stop',message:{role:'assistant',content:[{type:'text',text:'Complete'}]}};
  await forwardInferenceStream({push:event=>events.push(event),end:()=>ended++},model,undefined,async emit => {
    emit(done); emit(done); emit({type:'text_delta',delta:'late'}); throw new Error('late bridge error');
  });
  assert.deepEqual(events,[done]); assert.equal(ended,1);
});
