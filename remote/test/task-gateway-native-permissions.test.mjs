import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { PassThrough, Writable } from 'node:stream'
import { createTaskExecutor } from '../src/task-gateway-runner.mjs'

test('scheduled ACP archives full current updates before bounded presentation and excludes other sessions/configuration',async()=>{
  const updates=[],source='🙂漢字'+'x'.repeat(2*1024*1024)
  const launch=()=>{
    const child=new EventEmitter();child.stdout=new PassThrough();child.stderr=new PassThrough()
    const frame=value=>child.stdout.write(JSON.stringify(value)+'\n')
    child.kill=()=>{queueMicrotask(()=>child.emit('exit',0));return true}
    child.stdin=new Writable({write(bytes,_encoding,done){
      const request=JSON.parse(String(bytes))
      setImmediate(()=>{
        if(request.method==='initialize')frame({id:request.id,result:{protocolVersion:1}})
        if(request.method==='session/new')frame({id:request.id,result:{sessionId:'native'}})
        if(request.method==='session/prompt'){
          for(const [sessionId,update] of [
            ['other',{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'other session'}}],
            ['native',{sessionUpdate:'config_option_update',configOptions:[{token:'configuration-secret'}]}],
            ['native',{sessionUpdate:'agent_message_chunk',content:{type:'text',text:source}}],
            ['native',{sessionUpdate:'tool_call_update',toolCallId:'call',status:'completed',content:[{type:'image',mimeType:'image/png',data:'a'.repeat(2*1024*1024),url:'file:///native/image.png'}]}],
          ])frame({method:'session/update',params:{sessionId,update}})
          frame({id:request.id,result:{stopReason:'end_turn'}})
        }
      });done()
    }})
    return child
  }
  const execute=createTaskExecutor({workspaceRoot:'/workspace',environment:()=>({}),catalog:new Map([['codex',{id:'codex',transport:'acp',command:'fixture',arguments:[]}]]),launch})
  await execute({run:{id:'run',task:{prompt:'fixture',configuration:{runtimeKind:'codex'}}},signal:new AbortController().signal,bindSession:()=>{},publish:update=>updates.push(update)})
  assert.ok(updates.every(update=>Buffer.byteLength(JSON.stringify(update))<1048576))
  assert.equal(updates.filter(update=>update.sessionUpdate==='agent_message_chunk').map(update=>update.content.text).join(''),source)
  const tool=updates.find(update=>update.sessionUpdate==='tool_call_update')
  assert.equal(tool.toolCallId,'call');assert.equal(tool.content[0].data,undefined);assert.equal(tool.content[0].url,'file:///native/image.png')
  assert.ok(updates.some(update=>update.recordBatch?.records.some(record=>record.kind==='native-file.chunk')))
  assert.ok(!JSON.stringify(updates).includes('configuration-secret'));assert.ok(!JSON.stringify(updates).includes('other session'))
})
