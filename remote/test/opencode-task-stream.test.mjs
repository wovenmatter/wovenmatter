import test from 'node:test'
import assert from 'node:assert/strict'
import {OpenCodeTaskStream} from '../src/opencode-task-stream.mjs'
import {publishNativePresentation} from '../src/task-native-archive.mjs'
const message=content=>[{id:'message',content}]
const rendered=updates=>updates.filter(x=>x.sessionUpdate==='agent_message_chunk').reduce((text,x)=>x._meta?.wovenAssistantSnapshot?x.content.text:text+x.content.text,'')

test('background OpenCode snapshots preserve native order, stable reasoning and evolving tool arguments/output',()=>{
  const updates=[],stream=new OpenCodeTaskStream(x=>updates.push(x))
  const parts=[{id:'a',type:'text',text:'Before'},{id:'r',type:'reasoning',text:'Reason'},
    {id:'t',type:'tool',tool:'bash',state:{status:'pending',input:{command:'echo'}}},{id:'b',type:'text',text:'After'}]
  stream.reconcile(message(parts));stream.reconcile(message(parts))
  assert.deepEqual(updates.map(x=>x.sessionUpdate),['agent_message_chunk','agent_thought_chunk','tool_call','agent_message_chunk'])
  assert.equal(updates[2].status,'pending');assert.deepEqual(updates[2].rawInput,{command:'echo'})
  const changed=structuredClone(parts);changed[2].state={status:'running',input:{command:'echo hello'},output:'hello'}
  stream.reconcile(message(changed))
  assert.equal(updates.at(-1).status,'in_progress');assert.equal(updates.at(-1).rawInput.command,'echo hello');assert.equal(updates.at(-1).rawOutput,'hello')
  changed[2].state={...changed[2].state,status:'error',output:undefined,error:'failed command'};stream.reconcile(message(changed));stream.finish();stream.finish()
  assert.equal(updates.at(-2).status,'failed');assert.equal(updates.at(-2).rawOutput,'failed command')
  assert.equal(updates.filter(x=>x.sessionUpdate==='woven_assistant_boundary').length,1)
  assert.equal(rendered(updates),'BeforeAfter')
})

test('background corrections and removed parts retain exact text and clear stale activity',()=>{
  const updates=[],stream=new OpenCodeTaskStream(x=>updates.push(x))
  stream.reconcile(message([{id:'a',type:'text',text:'old'},{id:'r',type:'reasoning',text:'old reason'},{id:'t',type:'tool',name:'read',state:{status:'running'}}]))
  const start=updates.length
  stream.reconcile(message([{id:'a',type:'text',text:'new'},{id:'r2',type:'reasoning',text:'new reason'},{id:'b',type:'text',text:' tail'}]))
  assert.deepEqual(updates.slice(start,start+3).map(x=>x.content.text),['new','new reason',' tail'])
  assert.equal(rendered(updates),'new tail')
  assert.ok(updates.some(x=>x._meta?.wovenThoughtID==='message:r'&&x.content.text===''))
  assert.equal(updates.at(-1).status,'failed')
})

test('background abort/failure finalization settles outstanding tools exactly once',()=>{
  const updates=[],stream=new OpenCodeTaskStream(x=>updates.push(x))
  stream.reconcile(message([{id:'t',type:'tool',name:'bash',state:{status:'running',output:'partial'}}]));stream.finish();stream.finish()
  assert.deepEqual(updates.filter(x=>x.toolCallId).map(x=>x.status),['in_progress','failed'])
  assert.equal(updates[0].content[0].content.text,'partial')
})

test('native presentation frames Unicode replacement snapshots and preserves upstream frame boundaries',()=>{
  const text='🧵'.repeat(40000),updates=[]
  publishNativePresentation({sessionUpdate:'agent_thought_chunk',content:{type:'text',text},_meta:{wovenThoughtSnapshot:true,wovenThoughtID:'reason'}},x=>updates.push(x))
  assert.equal(updates.map(x=>x.content.text).join(''),text)
  assert.equal(updates.filter(x=>x._meta.wovenSnapshotStart).length,1);assert.equal(updates.filter(x=>x._meta.wovenSnapshotEnd).length,1)
  assert.equal(updates[0]._meta.wovenSnapshotStart,true);assert.equal(updates.at(-1)._meta.wovenSnapshotEnd,true)
  const middle=[];publishNativePresentation({...updates[0],_meta:{...updates[0]._meta,wovenSnapshotStart:false,wovenSnapshotEnd:false}},x=>middle.push(x))
  assert.ok(middle.every(x=>!x._meta.wovenSnapshotStart&&!x._meta.wovenSnapshotEnd))
})
