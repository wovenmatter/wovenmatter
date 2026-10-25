import test from 'node:test';
import assert from 'node:assert/strict';
import { createDefaultAgentService } from '../src/service.mjs';

test('passive inspection does not start an engine and preserves SDK task scheduling states',async()=>{
  let starts=0;
  const service=createDefaultAgentService({cwd:'/unused',directory:'/unused',engineFactory:async()=>{
    starts++;
    return {sessions:new Map([['chat',{session:{sessionId:'native-chat'},busy:true,selected:'fixture/model',
      harness:{inspect:async()=>({tasks:[{record:{id:17,kind:'woven.subagent'},state:{kind:'blocked',reason:'missing_task'}}]})}}]])};
  }});
  assert.deepEqual(await service.inspection(),[]);
  assert.equal(starts,0);
  await service.engine();
  const items=await service.inspection();
  assert.equal(starts,1);
  assert.equal(items[1].state,'blocked');
  assert.equal(items[1].nativeSessionID,'native-chat');
  assert.equal(items[1].parentID,items[0].id);
  assert.equal(JSON.stringify(items).includes('missing_task'),false);
});
