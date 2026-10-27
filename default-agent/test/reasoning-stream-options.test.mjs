import test from 'node:test';
import assert from 'node:assert/strict';
import { zstdDecompressSync } from 'node:zlib';
import { streamSimple as codexStream } from '@earendil-works/pi-ai/api/openai-codex-responses';
import { streamSimple as responsesStream } from '@earendil-works/pi-ai/api/openai-responses';
import { withReasoningSummaries } from '../src/reasoning-stream-options.mjs';

const model = { id:'fixture-reasoner',name:'Fixture',provider:'openai-codex',api:'openai-codex-responses',reasoning:true,
  baseUrl:'https://fixture.invalid',input:['text'],contextWindow:128000,maxTokens:4096,
  cost:{input:0,output:0,cacheRead:0,cacheWrite:0} };
const fakeJWT = ['fixture',Buffer.from(JSON.stringify({'https://api.openai.com/auth':{chatgpt_account_id:'fixture-account'}})).toString('base64url'),'fixture'].join('.');

for(const [name,stream,selected] of [['Codex',codexStream,model],['OpenAI',responsesStream,{...model,provider:'openai',api:'openai-responses'}]]) {
  test(`${name} actual streamSimple submits detailed reasoning after asynchronous continuation transform`,async()=>{
    let submitted,seenModel;
    const options=withReasoningSummaries(selected,{reasoning:'medium',transport:'sse',maxRetries:0,apiKey:fakeJWT,
      onPayload:async(body,requestedModel)=>{seenModel=requestedModel;return {...body,input:[{role:'user',content:'offline continuation fixture'}],metadata:{fixture:'kept'}};},
      fetch:async(_url,init)=>{
        const headers=new Headers(init.headers),body=headers.get('content-encoding')==='zstd'?zstdDecompressSync(init.body):init.body;
        submitted=JSON.parse(Buffer.isBuffer(body)||body instanceof Uint8Array?Buffer.from(body).toString('utf8'):body);
        throw new Error('Offline fixture: no provider contacted');
      }});
    const response=stream(selected,{messages:[{role:'user',content:'offline fixture',timestamp:0}]},options);
    await response.result();
    assert.ok(submitted,'actual SDK must reach the injected fetch');
    assert.deepEqual(submitted.reasoning,{effort:'medium',summary:'detailed'});
    assert.deepEqual(submitted.input,[{role:'user',content:'offline continuation fixture'}]);
    assert.deepEqual(submitted.metadata,{fixture:'kept'});assert.equal(seenModel,selected);
  });
}

test('summary hook preserves mutation/undefined and explicit hook returns without enabling reasoning',async()=>{
  const payload={reasoning:{effort:'high',summary:'auto'},input:[]};
  const options=withReasoningSummaries(model,{reasoning:'high',onPayload:body=>{body.input.push({fixture:true});}});
  const result=await options.onPayload(payload,model);
  assert.equal(result.reasoning.summary,'detailed');assert.deepEqual(result.input,[{fixture:true}]);
  assert.equal(payload.reasoning.summary,'auto');
  for(const effort of ['none','off',undefined]) {
    const body={reasoning:{effort,summary:'auto'}};
    const plain=withReasoningSummaries(model,{reasoning:'medium'});
    assert.equal(await plain.onPayload(body,model),body);
  }
  const nullHook=withReasoningSummaries(model,{reasoning:'medium',onPayload:()=>null});
  assert.equal(await nullHook.onPayload(payload,model),null);
});

test('non-Responses, non-reasoning and disabled reasoning options remain unchanged',()=>{
  const options={reasoning:'medium',onPayload:()=>{throw new Error('must remain untouched');}};
  for(const selected of [{...model,reasoning:false},{...model,api:'anthropic-messages'},{...model,api:'google-generative-ai'}])
    assert.equal(withReasoningSummaries(selected,options),options);
  for(const reasoning of ['off',undefined]) { const disabled={...options,reasoning};assert.equal(withReasoningSummaries(model,disabled),disabled); }
});
