import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { PassThrough, Writable } from 'node:stream'
import { createHash } from 'node:crypto'
import { createNativeTaskExecutor } from '../src/task-gateway-native.mjs'
import { nativePresentationUpdates } from '../../default-agent/src/native-journal.mjs'
import { createTaskNativeArchive } from '../src/task-native-archive.mjs'
const fixtureVersion = '2.0.22'
const options = {workspaceRoot:'/workspace',environment:()=>({HOME:'/home'})}
const base = runtimeKind => ({run:{id:'run-1',title:'Fixture',task:{prompt:'fixture only',configuration:{runtimeKind,tools:{}}}},nativeSessionID:null,signal:new AbortController().signal,publish:()=>{},bindSession:()=>{}})
const nativeRecords = updates => updates.flatMap(update => update.recordBatch?.records ?? [])
const text = updates => updates.filter(update => update.sessionUpdate === 'agent_message_chunk').map(update => update.content.text).join('')

function piFixture({events = [{type:'message_update',assistantMessageEvent:{type:'text_delta',delta:'done'}},{type:'agent_settled'}], entries = [], historical = []} = {}) {
  const calls = [], state = {sessionId:'pi-session',sessionFile:'/native/session.jsonl',model:{provider:'lab',id:'model'},thinkingLevel:'low'}
  let killed = false, submitted = false
  const launch = (_command, args, launchOptions) => {
    const child = new EventEmitter();child.stdout=new PassThrough();child.stderr=new PassThrough()
    const frame = value => child.stdout.write(JSON.stringify(value)+'\n')
    child.stdin = new Writable({write(bytes,_encoding,done){
      const command=JSON.parse(String(bytes));calls.push(command)
      if (command.type === 'get_entries') assert.ok(Object.keys(command).every(key=>['id','type','since'].includes(key)))
      setImmediate(() => {
        if(command.type==='set_model')state.model={provider:command.provider,id:command.modelId}
        if(command.type==='set_thinking_level')state.thinkingLevel=command.level
        if(command.type==='get_state'){frame({type:'message_update',assistantMessageEvent:{type:'text_delta',delta:'old'}});frame({type:'agent_settled'})}
        if(command.type==='prompt')submitted=true
        const exported=submitted?[...historical,...entries]:historical
        const since=command.since?exported.findIndex(entry=>entry.id===command.since):-1
        frame({type:'response',id:command.id,success:true,data:command.type==='get_state'?state:command.type==='get_entries'?{entries:exported.slice(since+1)}:{}})
        if(command.type==='prompt')for(const event of events)frame(event)
      });done()
    }})
    child.kill=()=>{killed=true;queueMicrotask(()=>child.emit('exit',0));return true}
    calls.push({args,environment:launchOptions.env});return child
  }
  return {launch,calls,get killed(){return killed}}
}

function openCodeFixture({permissionRequests=[],forms=[],pages=[{data:[{id:'msg_answer',type:'assistant',content:[{type:'text',text:'result'}]}]}],permissions=[],ignorePolicy=false,healthPID=42}={}) {
  const calls=[],session={id:'ses_fixture',model:{providerID:'lab',id:'old'},permissions}
  let submitted=false
  const fetchRequest=async(url,request)=>{
    assert.equal(request.headers.authorization,'Basic '+Buffer.from('opencode:fixture').toString('base64'))
    assert.equal(request.redirect,'error')
    const body=request.body&&JSON.parse(request.body);calls.push({method:request.method,path:url.pathname,query:url.searchParams.toString(),body})
    let response
    if(url.pathname==='/api/info')response={healthy:true,pid:healthPID,version:fixtureVersion}
    else if(url.pathname==='/api/session/ses_fixture/model'){session.model=body.model;response={}}
    else if(url.pathname==='/api/session/ses_fixture'){
      if(request.method==='PATCH'&&!ignorePolicy)session.permissions=body.permissions
      response={data:structuredClone(session)}
    } else if(url.pathname.endsWith('/message')) {
      const index=url.searchParams.has('cursor')?Number(url.searchParams.get('cursor')):0
      response=submitted?pages[index]:{data:[]}
      if(!response)assert.fail('unexpected native cursor '+index)
    } else if(url.pathname.endsWith('/prompt')){submitted=true;response={data:{id:body.id}}}
    else if(url.pathname==='/api/session/active')response={data:{}}
    else if(url.pathname.endsWith('/permission'))response={data:submitted?permissionRequests:[]}
    else if(url.pathname.endsWith('/form'))response={data:submitted?forms:[]}
    else if(url.pathname.endsWith('/interrupt'))response={}
    else assert.fail('unexpected OpenCode operation '+request.method+' '+url.pathname)
    return {ok:true,status:200,json:async()=>structuredClone(response)}
  }
  const execute=createNativeTaskExecutor({...options,instances:{action:async()=>{},registrationPath:'fixture'},read:async()=>JSON.stringify({url:'http://127.0.0.1:4000',password:'fixture',pid:42}),fetchRequest})
  const context=base('opencode');context.nativeSessionID='ses_fixture'
  return {execute,context,calls,session}
}

function hermesFixture({events=[{type:'message.complete',payload:{text:'finished',status:'success'}}],snapshot={id:'stored',messages:[]},resolved='stored',historical=[]}={}) {
  const calls=[],exports=[];let submitted=false
  class FixtureSocket extends EventTarget {
    constructor(){super();queueMicrotask(()=>this.dispatchEvent(new Event('open')))}
    send(bytes){
      const frame=JSON.parse(bytes);calls.push(frame)
      const params=frame.params??{}
      let result={}
      if(frame.method==='config.get')result=params.key==='profile'?{home:'/home/.hermes'}:{value:'model'}
      else if(frame.method==='session.resume')result={session_id:'runtime',stored_session_id:resolved,running:false,...(resolved!=='stored'?{resumed:resolved}:{})}
      else if(frame.method==='session.events.since')result={latest_seq:5,epoch:'native-epoch'}
      else if(!['ping','session.cwd.set','config.set','prompt.submit','session.interrupt','approval.respond'].includes(frame.method))assert.fail('unexpected Hermes operation '+frame.method)
      queueMicrotask(()=>{
        if(frame.method==='config.set')this.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({method:'event',params:{session_id:'runtime',seq:1,type:'message.complete',payload:{text:'old',status:'success'}}})}))
        this.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({id:frame.id,result})}))
        if(frame.method==='prompt.submit'){submitted=true;events.forEach((event,index)=>this.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({method:'event',params:{session_id:'runtime',seq:6+index,...event}})})))}
      })
    }
    close(){}
  }
  const execute=createNativeTaskExecutor({...options,hermes:{start:async()=>{}},read:async()=>JSON.stringify({port:4000,token:'fixture-secret'}),WebSocketClass:FixtureSocket,fetchRequest:async(url,request)=>{
    exports.push(url);assert.equal(request.headers.authorization,'Bearer fixture-secret');assert.equal(request.redirect,'error')
    return {ok:true,json:async()=>submitted?snapshot:{id:snapshot.id,messages:historical}}
  }})
  const context=base('hermes');context.nativeSessionID='stored'
  return {execute,context,calls,exports}
}

test('Pi confirms model/thinking before one prompt and archives native tools/compaction/nontext with the bound identity',async()=>{
  const entries=[{id:'native-tool',type:'message',message:{role:'toolResult',content:[{type:'image',data:'exposed-image',mimeType:'image/png'},{type:'text',text:'tool needle'}]}},{id:'native-compact',type:'compaction',summary:'context needle',tokensBefore:12000}]
  const fixture=piFixture({entries,events:[{type:'tool_execution_start',toolCallId:'call',args:{file:'input'}},{type:'tool_execution_end',toolCallId:'call',result:{content:[{type:'text',text:'tool needle'}]}},{type:'auto_compaction_end',compactionResult:entries[1]},{type:'message_update',assistantMessageEvent:{type:'thinking_delta',delta:'exposed thought'}},{type:'message_update',assistantMessageEvent:{type:'text_delta',delta:'done'}},{type:'agent_settled'}]})
  const context=base('pi'),updates=[],ids=[];context.nativeSessionID='pi-session';context.run.task.configuration.model='lab/next';context.run.task.configuration.thinking='high';context.publish=x=>updates.push(x);context.bindSession=x=>ids.push(x)
  assert.equal((await createNativeTaskExecutor({...options,launch:fixture.launch})(context)).stopReason,'end_turn')
  assert.deepEqual(fixture.calls[0].args,['--mode','rpc','--session','pi-session'])
  assert.equal(fixture.calls.filter(x=>x.type==='prompt').length,1)
  assert.ok(fixture.calls.findIndex(x=>x.type==='set_thinking_level')<fixture.calls.findIndex(x=>x.type==='prompt'))
  assert.deepEqual(ids,['pi-session']);assert.equal(text(updates),'done')
  assert.ok(updates.filter(x=>x.recordBatch).every(x=>x.recordBatch.nativeSessionID===ids[0]))
  const records=nativeRecords(updates)
  assert.ok(records.some(x=>x.kind==='tool_execution_end'));assert.ok(records.some(x=>x.kind==='auto_compaction_end'))
  assert.deepEqual(JSON.parse(records.find(x=>x.id==='entry:native-tool').payload),entries[0]);assert.equal(records.find(x=>x.id==='entry:native-tool').runID,'run-1')
  assert.ok(records.some(x=>x.text?.includes('context needle')))
})

test('unsupported native permission selections fail before spawning/submitting',async()=>{
  let launched=false
  const context=base('pi');context.run.task.configuration.permission='full'
  await assert.rejects(createNativeTaskExecutor({...options,launch:()=>{launched=true}})(context),error=>error.beforePrompt===true)
  assert.equal(launched,false)
  for(const permission of ['normal','acceptEdits','full','auto']){
    const fixture=openCodeFixture();fixture.context.run.task.configuration.permission=permission
    await assert.rejects(fixture.execute(fixture.context),error=>error.beforePrompt===true)
    assert.equal(fixture.calls.length,0)
  }
})

test('OpenCode confirms native rules without removing custom rules and projects the completed response',async()=>{
  for(const permission of ['ask','allow','deny']){
    const custom={action:'bash',resource:'protected/*',effect:'deny'},fixture=openCodeFixture({permissions:[custom,{action:'*',resource:'*',effect:'ask'}]})
    const updates=[];fixture.context.run.task.configuration={runtimeKind:'opencode',permission,model:'lab/new',thinking:'high'};fixture.context.publish=x=>updates.push(x)
    await fixture.execute(fixture.context)
    assert.deepEqual(fixture.session.permissions,[custom,{action:'*',resource:'*',effect:permission}])
    assert.deepEqual(fixture.session.model,{providerID:'lab',id:'new',variant:'high'})
    assert.equal(text(updates),'result');assert.equal(fixture.calls.filter(x=>x.path.endsWith('/prompt')).length,1)
    const patch=fixture.calls.findIndex(x=>x.method==='PATCH');assert.equal(fixture.calls[patch+1].method,'GET')
    assert.ok(nativeRecords(updates).some(x=>x.id==='message:msg_answer'&&x.runID==='run-1'))
  }
})

test('OpenCode rejects ignored policy writes and service identity mismatch before prompt',async()=>{
  for(const config of [{ignorePolicy:true},{healthPID:99}]){
    const fixture=openCodeFixture(config);fixture.context.run.task.configuration.permission='allow'
    await assert.rejects(fixture.execute(fixture.context),error=>error.beforePrompt===true)
    assert.equal(fixture.calls.filter(x=>x.path.endsWith('/prompt')).length,0)
  }
})

test('OpenCode keeps pending native approvals and required input interactive, including allow policy',async()=>{
  for(const pending of [{permissionRequests:[{sessionID:'ses_fixture',id:'per_auth',action:'oauth',resources:[]}]},{forms:[{sessionID:'ses_fixture',id:'form_input',questions:[{question:'Required input'}]}]}]){
    const fixture=openCodeFixture(pending);fixture.context.run.task.configuration.permission='allow'
    await assert.rejects(fixture.execute(fixture.context),error=>error.needsApproval===true&&!error.beforePrompt)
    assert.ok(fixture.calls.some(x=>x.path.endsWith('/interrupt')))
    assert.equal(fixture.calls.some(x=>x.path.endsWith('/reply')),false)
  }
})

test('OpenCode follows short native pages and retains nontext and compaction records beyond the first page',async()=>{
  const attachment={id:'msg_tool',type:'assistant',content:[{type:'tool',state:{output:'tool output'}},{type:'file',url:'file:///native/image.png'}]},compact={id:'msg_compact',type:'assistant',content:[{type:'compaction',summary:'context changed'}]}
  const fixture=openCodeFixture({pages:[{data:[attachment],cursor:{next:'1'}},{data:[compact]}]}),updates=[]
  fixture.context.publish=x=>updates.push(x);await fixture.execute(fixture.context)
  assert.ok(fixture.calls.some(x=>x.query.includes('cursor=1')))
  assert.deepEqual(nativeRecords(updates).filter(x=>x.kind==='message').map(x=>JSON.parse(x.payload)),[attachment,compact])
  assert.ok(updates.filter(x=>x.recordBatch).every(x=>x.recordBatch.nativeSessionID==='ses_fixture'))
})

test('OpenCode rejects cycling native page cursors and interrupts accepted work',async()=>{
  const fixture=openCodeFixture({pages:[{data:[{id:'msg_a',type:'assistant'}],cursor:{next:'1'}},{data:[{id:'msg_b',type:'assistant'}],cursor:{next:'1'}}]})
  await assert.rejects(fixture.execute(fixture.context),/nonadvancing/)
  assert.ok(fixture.calls.some(x=>x.path.endsWith('/interrupt')))
})

test('Hermes captures native events/export with exact bound identity while excluding configuration and secret transport',async()=>{
  const snapshot={id:'stored',compression:{parent_session_id:'earlier'},messages:[{id:1,role:'assistant',content:[{type:'image',path:'/native/image.png'},{type:'text',text:'export needle'}]}]}
  const fixture=hermesFixture({snapshot,events:[{type:'tool.start',payload:{name:'read',args:{path:'input'}}},{type:'tool.complete',payload:{result_text:'tool needle'}},{type:'compression.complete',payload:{summary:'compressed context'}},{type:'config.changed',payload:{token:'configuration-secret'}},{type:'secret.expire',payload:{value:'transport-secret'}},{type:'message.complete',payload:{text:'finished',status:'success'}}]}),updates=[],bound=[]
  fixture.context.run.task.configuration.model='model';fixture.context.publish=x=>updates.push(x);fixture.context.bindSession=x=>bound.push(x)
  await fixture.execute(fixture.context)
  assert.equal(fixture.calls.filter(x=>x.method==='prompt.submit').length,1);assert.equal(text(updates),'finished')
  assert.match(bound[0],/^hermes-gateway:/);assert.ok(updates.filter(x=>x.recordBatch).every(x=>x.recordBatch.nativeSessionID===bound[0]))
  const records=nativeRecords(updates),serialized=JSON.stringify(records)
  assert.ok(records.some(x=>x.kind==='tool.complete'));assert.ok(records.some(x=>x.kind==='compression.complete'))
  assert.deepEqual(JSON.parse(records.find(x=>x.id==='session:stored:message:1').payload),snapshot.messages[0])
  assert.ok(!serialized.includes('configuration-secret'));assert.ok(!serialized.includes('transport-secret'));assert.ok(!serialized.includes('fixture-secret'))
  assert.equal(fixture.exports.length,2)
})

test('scheduled Hermes forwards paired checklist writes losslessly only from the owning session and retains native events',async()=>{
  const todos=Array.from({length:140},(_,index)=>({id:`todo-${index}`,content:'Same label',status:'pending'}))
  const payload={tool_id:'write',name:'todo_list',args:{todos:[{id:'todo-0',status:'completed'}],merge:true},result:{revision:2,todos},unknown:'retained'}
  const fixture=hermesFixture({events:[
    {type:'tool.complete',session_id:'child',payload},
    {type:'tool.complete',payload},
    {type:'tool.complete',payload:{...payload,name:'subagent'}},
    {type:'message.complete',payload:{text:'done',status:'success'}},
    {type:'tool.complete',payload}, // Retained, but outside the completed task.
  ]}),updates=[],bound=[]
  fixture.context.publish=update=>updates.push(update)
  fixture.context.bindSession=id=>bound.push(id)
  await fixture.execute(fixture.context)
  const projected=updates.filter(update=>update.sessionUpdate==='woven_hermes_tool_complete')
  assert.equal(projected.length,1)
  assert.equal(projected[0].nativeSessionID,bound[0])
  assert.deepEqual(projected[0].payload,{name:payload.name,args:payload.args,result:payload.result})
  const records=nativeRecords(updates).filter(record=>record.kind==='tool.complete')
  assert.equal(records.length,3)
  assert.deepEqual(JSON.parse(records[0].payload).payload,payload)
})

test('Hermes rejects a different native export before dispatch',async()=>{
  const fixture=hermesFixture({snapshot:{id:'other',messages:[]}})
  await assert.rejects(fixture.execute(fixture.context),/different or incomplete/)
  assert.equal(fixture.calls.some(x=>x.method==='prompt.submit'),false)
})

test('Pi output persistence failures stop the child and stay inside the task result',async()=>{
  const fixture=piFixture({events:[{type:'message_update',assistantMessageEvent:{type:'text_delta',delta:'hello'}}]})
  const context=base('pi');context.publish=()=>{throw Error('fixture journal failure')}
  await assert.rejects(createNativeTaskExecutor({...options,launch:fixture.launch})(context),/fixture journal failure/)
  assert.equal(fixture.killed,true)
})

test('scheduled archive retains changed revisions, deduplicates identical snapshots and redacts only tool endpoints',async()=>{
  const updates=[],archive=await createTaskNativeArchive({sourceID:'fixture',nativeSessionID:'bound',runID:'run',publish:x=>updates.push(x)})
  const endpoint='/private/tmp/wmtools-'+'a'.repeat(32)+'/'+'b'.repeat(32)+'.sock'
  try {
    const first={id:'native',text:'ordinary-token=preserved '+endpoint,endpoint,userBase64:Buffer.from(endpoint).toString('base64')}
    await archive.capture(first,{id:'native',kind:'message',contentMode:'snapshot'})
    await archive.capture(first,{id:'native',kind:'message',contentMode:'snapshot'})
    await archive.capture({...first,text:'changed'},{id:'native',kind:'message',contentMode:'snapshot'})
    const records=nativeRecords(updates);assert.equal(records.length,2);assert.notEqual(records[0].revision,records[1].revision)
    assert.ok(!records[0].payload.includes('wmtools-'));assert.ok(!records[0].text.includes('wmtools-'));assert.equal(JSON.parse(records[0].payload).userBase64,first.userBase64)
    assert.ok(records[0].text.includes('ordinary-token=preserved'));assert.equal(records[0].runID,'run')
  } finally {await archive.close()}
})

test('scheduled native records over 64 MiB use bounded exact chunks and verified manifests',async()=>{
  const hash=createHash('sha256'),parts=[],manifests=[];let total=0,pages=0,projected=false
  const archive=await createTaskNativeArchive({sourceID:'fixture',nativeSessionID:'bound',runID:'run',publish:update=>{
    assert.equal(update.recordBatch.nativeSessionID,'bound');assert.ok(Buffer.byteLength(JSON.stringify(update))<1048576);pages++
    for(const record of update.recordBatch.records){
      const payload=JSON.parse(record.payload)
      if(record.kind==='native-file.chunk'){
        const bytes=Buffer.from(payload.dataBase64,'base64');assert.equal(createHash('sha256').update(bytes).digest('hex'),payload.sha256)
        hash.update(bytes);parts.push({byteOffset:total,byteCount:bytes.length,chunkID:record.id});total+=bytes.length
        projected ||= record.text?.includes('exposed needle')
      }else manifests.push(payload)
    }
  }})
  try {
    const value={type:'tool_execution_end',result:{text:'exposed needle '+ 'x'.repeat(65*1024*1024)}}
    const payload=JSON.stringify(value), revision=createHash('sha256').update(payload).digest('hex')
    const expected={id:'large',revision,kind:'tool_execution_end',payload,contentMode:'event',text:value.result.text.slice(0,256*1024),completeness:'observed',runID:'run'}
    const expectedBytes=JSON.stringify(expected),expectedHash=createHash('sha256').update(expectedBytes).digest('hex')
    await archive.capture(value,{id:'large',kind:'tool_execution_end'})
    assert.ok(pages>60);assert.ok(projected);assert.equal(manifests.length,1)
    const manifest=manifests[0];assert.equal(hash.digest('hex'),manifest.sha256);assert.equal(total,manifest.totalBytes);assert.deepEqual(parts,manifest.parts);assert.equal(manifest.sha256,expectedHash);assert.equal(total,Buffer.byteLength(expectedBytes))
    assert.equal(manifest.originalRecord.id,'large');assert.equal(manifest.originalRecord.runID,'run');assert.equal(manifest.byteFidelity,'exact-native-bytes')
  }finally{await archive.close()}
})


test('recurring Pi and Hermes snapshots preserve native IDs and assign only new messages to each run',async()=>{
  for(const runtime of ['pi','hermes']){
    const first=runtime==='pi'?{id:'entry-first',type:'message',message:{role:'assistant',content:[{type:'text',text:'first'}]}}:{id:1,role:'assistant',content:'first'}
    const second=runtime==='pi'?{...first,id:'entry-second',message:{role:'assistant',content:'second'}}:{id:2,role:'assistant',content:'second'}
    const updates=[]
    for(const [index,historical,entries] of [[1,[],[first]],[2,[first],[first,second]]]){
      const fixture=runtime==='pi'?piFixture({historical,entries:entries.filter(entry=>!historical.some(old=>old.id===entry.id))}):hermesFixture({historical,snapshot:{id:'stored',messages:entries}})
      const context=runtime==='pi'?base('pi'):fixture.context
      context.run.id='run-'+index;context.publish=x=>updates.push(x)
      await (runtime==='pi'?createNativeTaskExecutor({...options,launch:fixture.launch}):fixture.execute)(context)
    }
    const records=nativeRecords(updates).filter(record=>record.kind==='message')
    const id=runtime==='pi'?'entry:entry-first':'session:stored:message:1'
    assert.ok(records.some(record=>record.id===id&&record.runID==='run-1'))
    assert.ok(records.some(record=>record.id===id&&record.runID===undefined))
    assert.equal(records.some(record=>record.id===id&&record.runID==='run-2'),false)
    assert.ok(records.some(record=>record.id!==id&&record.runID==='run-2'))
  }
})

test('Pi scheduled children do not inherit a connected desktop CLI or tool authority',async()=>{
  const fixture=piFixture(),context=base('pi')
  const inherited={HOME:'/home',WOVENMATTER_CONTEXT_ID:'context',WOVENMATTER_NOTE_ID:'note',WOVENMATTER_SOCKET:'socket',WOVENMATTER_CLI:'cli',WOVENMATTER_SESSION_TOKEN:'token',WOVENMATTER_TOOL_SOCKET:'tool-socket'}
  await createNativeTaskExecutor({...options,environment:()=>inherited,launch:fixture.launch})(context)
  assert.deepEqual(fixture.calls[0].environment,{HOME:'/home',WOVENMATTER_LOCAL_PI:'1'})
  assert.equal(inherited.WOVENMATTER_CONTEXT_ID,'context')
})

test('native presentation splits Unicode text without loss and bounds nested tool and inline binary previews',()=>{
  const source='x'.repeat(32767)+'🙂漢字'+String.raw`\n`+'z'.repeat(130000)
  for(const sessionUpdate of ['agent_message_chunk','agent_thought_chunk']){
    const chunks=[...nativePresentationUpdates({sessionUpdate,content:{type:'text',text:source}})]
    assert.equal(chunks.map(chunk=>chunk.content.text).join(''),source)
    assert.ok(chunks.every(chunk=>Buffer.byteLength(JSON.stringify(chunk))<1048576))
    assert.ok(chunks.every(chunk=>!/[\ud800-\udbff]$/.test(chunk.content.text)))
  }
  const image={type:'image',mimeType:'image/png',url:'file:///native/image.png',data:'x'.repeat(2*1024*1024)}
  const nested=Array.from({length:128},()=>Array.from({length:128},()=>({['key'.repeat(100)]:'value'.repeat(1000)})))
  const [preview]=nativePresentationUpdates({sessionUpdate:'tool_call_update',toolCallId:'native-tool',status:'completed',content:[image,{type:'text',text:'body'.repeat(20000)}],nested})
  assert.equal(preview.toolCallId,'native-tool');assert.equal(preview.status,'completed')
  assert.equal(preview.content[0].data,undefined);assert.equal(preview.content[0].mimeType,'image/png');assert.equal(preview.content[0].url,image.url)
  assert.ok(Buffer.byteLength(JSON.stringify(preview))<1048576)
})

test('oversized native tool previews never split a Unicode surrogate pair',()=>{
  for(const field of ['rawOutput','content']){
    const envelope={sessionUpdate:'tool_call_update',toolCallId:'native-tool',status:'completed'}
    const wrap=value=>({...envelope,[field]:field==='content'?[{type:'text',text:value}]:value})
    const read=value=>field==='content'?value.content[0].text:value.rawOutput
    const limit=read([...nativePresentationUpdates(wrap('x'.repeat(65536)))][0]).length
    const source='x'.repeat(limit-1)+'🙂漢字'+'z'.repeat(65536)
    const [preview]=nativePresentationUpdates(wrap(source))
    assert.equal(read(preview),source.slice(0,limit-1))
    assert.doesNotMatch(JSON.stringify(preview),/\\u[dD][89aAbB][0-9a-fA-F]{2}/)
    assert.equal(source.slice(limit-1,limit+1),'🙂')
  }
})

test('direct OpenCode projects native text snapshots and tool/thinking activity without duplicate final text',async()=>{
  const fixture=openCodeFixture({pages:[{data:[{id:'msg_answer',type:'assistant',content:[
    {id:'thought',type:'reasoning',text:'Considering the file'},
    {id:'tool',type:'tool',name:'read',state:{status:'completed',output:'file contents'}},
    {id:'text',type:'text',text:'Result'}]}]}]})
  const updates=[];fixture.context.publish=update=>updates.push(update);fixture.context.interactive={publish:()=>{},bind:()=>{}}
  await fixture.execute(fixture.context)
  assert.equal(text(updates),'Result')
  assert.equal(updates.find(update=>update.sessionUpdate==='agent_message_chunk')._meta.wovenAssistantSnapshot,true)
  assert.equal(updates.find(update=>update.sessionUpdate==='agent_thought_chunk').content.text,'Considering the file')
  assert.equal(updates.find(update=>update.sessionUpdate==='tool_call_update').status,'completed')
  assert.ok(nativeRecords(updates).some(record=>record.id==='message:msg_answer'))
})

test('direct Hermes exposes native tool activity while preserving the native archive',async()=>{
  const fixture=hermesFixture({events:[{type:'tool.start',payload:{tool_id:'tool1',name:'read',context:'Reading'}},
    {type:'tool.complete',payload:{tool_id:'tool1',name:'read',result:{text:'done'},result_text:'done'}},
    {type:'message.complete',payload:{text:'Finished',status:'success'}}]})
  const updates=[];fixture.context.publish=update=>updates.push(update);fixture.context.interactive={publish:()=>{},bind:()=>{}}
  await fixture.execute(fixture.context)
  const tools=updates.filter(update=>update.sessionUpdate==='tool_call_update')
  assert.deepEqual(tools.map(update=>update.status),['running','completed'])
  assert.ok(tools.every(update=>update.toolCallId==='tool1'))
  assert.equal(text(updates),'Finished')
  assert.ok(nativeRecords(updates).some(record=>record.kind==='tool.complete'))
})
