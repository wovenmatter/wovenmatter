import { fsyncSync } from 'node:fs'
import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp,rm,readFile,writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { createTaskGateway,occurrenceDate,latestOccurrence } from '../src/task-gateway.mjs'
import { applyTaskConfiguration } from '../src/task-gateway-runner.mjs'

const task=(changes={})=>({id:'event-1',title:'Test',startsAt:'2026-01-01T14:00:00.000Z',timeZoneID:'America/New_York',recurrence:{unit:'day',interval:1},excludedOccurrences:[],revision:1,nextFireAt:'2026-01-01T14:00:00.000Z',task:{prompt:'hello',sessionMode:'same',configuration:{runtimeKind:'codex',title:'Test',tools:{enabled:[]}}},...changes})
const settled=async gateway=>{for(let i=0;i<100 && gateway.status().activeRuns;i++)await new Promise(done=>setTimeout(done,5));assert.equal(gateway.status().activeRuns,0)}
async function fixture(t,options={}) {const directory=await mkdtemp(resolve(tmpdir(),'wm-task-gateway-'));t.after(()=>rm(directory,{recursive:true,force:true}));return {directory,gateway:createTaskGateway({directory,execute:async()=>({}),...options})}}

test('anchored timezone recurrence survives DST and month-end without finite horizon',()=>{
 const daily=task({startsAt:'2026-03-07T14:00:00.000Z'})
 assert.equal(new Date(occurrenceDate(daily,1)).toISOString(),'2026-03-08T13:00:00.000Z')
 const monthly=task({startsAt:'2026-01-31T14:00:00.000Z',recurrence:{unit:'month',interval:1}})
 assert.equal(new Date(occurrenceDate(monthly,1)).toISOString(),'2026-02-28T14:00:00.000Z')
 assert.equal(new Date(occurrenceDate(monthly,2)).toISOString(),'2026-03-31T13:00:00.000Z')
 assert.equal(latestOccurrence(monthly,Date.parse('2046-01-31T14:00:00Z')),240)
})

test('remote defaults enabled; coalesces missed runs, reuses native session and exports durable receipts',async t=>{
 let clock=Date.parse('2026-01-04T15:00:00Z'),calls=[]
 const {directory,gateway}=await fixture(t,{now:()=>clock,execute:async options=>{calls.push(options);options.bindSession('native-1');options.publish({sessionUpdate:'agent_message_chunk',content:{type:'text',text:'done'}});return {stopReason:'end_turn'}}})
 assert.equal(gateway.status().enabled,true)
 gateway.publish({publicationID:'p1',schedules:[task()],knownRuns:[]});gateway.tick();await settled(gateway)
 assert.equal(calls.length,1);assert.equal(calls[0].run.occurrenceIndex,3)
 assert.equal(gateway.results().entries[0].eventRevision,1)
 assert.equal(gateway.results().entries[0].run.status,'accepted')
 assert.equal(gateway.results().entries[0].updates[0].content.text,'done')
 gateway.tick();await settled(gateway);assert.equal(calls.length,1)
 // A reconnect publishing an old same-revision snapshot cannot rewind progress.
 gateway.publish({publicationID:'p2',schedules:[task()],knownRuns:[]})
 clock=Date.parse('2026-01-05T15:00:00Z');gateway.tick();await settled(gateway)
 assert.equal(calls[1].nativeSessionID,'native-1')
 assert.equal(calls[1].run.sessionID,calls[0].run.sessionID)
 const restored=createTaskGateway({directory,execute:async()=>{throw new Error('must not replay')},now:()=>clock})
 restored.tick();await settled(restored);assert.equal(restored.results().entries.length,2)
 assert.equal(restored.results('1').entries.length,1)
})

test('disable drains accepted work and persists disabled across restart',async t=>{
 let stopped=false
 const {directory,gateway}=await fixture(t,{now:()=>Date.parse('2026-01-02T15:00:00Z'),execute:({signal})=>new Promise((done,reject)=>signal.addEventListener('abort',()=>reject(new Error('stopped')))),onDisable:async()=>{stopped=true}})
 gateway.publish({publicationID:'p1',schedules:[task()],knownRuns:[]});gateway.tick();assert.equal(gateway.status().activeRuns,1)
 const status=await gateway.configure({enabled:false})
 assert.equal(status.activeRuns,0);assert.equal(status.enabled,false);assert.equal(stopped,true)
 const restored=createTaskGateway({directory,execute:async()=>assert.fail('disabled tasks ran')})
 assert.equal(restored.status().enabled,false);restored.tick()
 assert.equal(restored.results().entries[0].run.status,'uncertain')
})

test('crashed pre-send claim is uncertain and never automatically replayed',async t=>{
 const {directory,gateway}=await fixture(t,{now:()=>Date.parse('2026-01-02T15:00:00Z'),execute:()=>new Promise(()=>{})})
 gateway.publish({publicationID:'p1',schedules:[task()],knownRuns:[]});gateway.tick()
 const restored=createTaskGateway({directory,execute:async()=>assert.fail('replayed'),now:()=>Date.parse('2026-01-02T16:00:00Z')})
 restored.tick();assert.equal(restored.status().activeRuns,0)
 assert.equal(restored.results().entries[0].run.status,'uncertain')
})

test('known local sends, exclusions, publication retry, and absent next fire cannot duplicate prompts',async t=>{
 let calls=0
 const {gateway}=await fixture(t,{now:()=>Date.parse('2026-01-02T15:00:00Z'),execute:async()=>{calls++}})
 const request={publicationID:'p1',schedules:[task({excludedOccurrences:[1]})],knownRuns:[{eventID:'event-1',scheduledAt:'2026-01-01T14:00:00Z'}]}
 gateway.publish(request);gateway.publish(request);gateway.tick();await settled(gateway);assert.equal(calls,0)
 gateway.publish({publicationID:'p2',schedules:[task({revision:2,nextFireAt:null})],knownRuns:[]});gateway.tick();assert.equal(calls,0)
 assert.throws(()=>gateway.publish({publicationID:'p3',schedules:[task()],knownRuns:[]}),/newer/)
})

test('applies only advertised selections and rejects unconfirmed permission before prompt',async()=>{
 const calls=[]
 const initial={configOptions:[{id:'model',currentValue:'a',options:[{value:'a'},{value:'b'}]},{id:'mode',currentValue:'default',options:[{value:'default'},{value:'safe'}]}]}
 await assert.rejects(()=>applyTaskConfiguration(async(method,params)=>{calls.push(params);return {configOptions:initial.configOptions}},'native',initial,{runtimeKind:'codex',permission:'safe'}),/did not confirm/)
 assert.equal(calls[0].value,'safe')
 await assert.rejects(()=>applyTaskConfiguration(async()=>assert.fail(),'native',initial,{runtimeKind:'codex',model:'unknown'}),/no longer available/)
})

test('locked Built-in credentials defer before submission and retry after reconnect without consuming occurrence',async t=>{
 let clock=Date.parse('2026-01-02T15:00:00Z'),locked=true,calls=0
 const {directory,gateway}=await fixture(t,{now:()=>clock,execute:async()=>{calls++;if(locked)throw Object.assign(new Error('Waiting for Woven Matter to reconnect and unlock the Built-in agent.'),{beforePrompt:true,deferred:true});return {}}})
 gateway.publish({publicationID:'p1',schedules:[task()],knownRuns:[]});gateway.tick();await settled(gateway)
 assert.equal(gateway.results().entries.length,0)
 assert.match(gateway.status().waitingTasks[0].reason,/unlock/)
 gateway.tick();assert.equal(calls,1)
 const restored=createTaskGateway({directory,now:()=>clock,execute:async()=>{calls++;return {}}})
 assert.equal(restored.results().entries.length,0)
 clock+=61000;locked=false;restored.tick();await settled(restored)
 assert.equal(calls,2);assert.equal(restored.results().entries.length,1)
 assert.equal(restored.results().entries[0].run.status,'accepted')
 assert.equal(restored.status().waitingTasks.length,0)
})

test('ACP executor confirms settings, binds recurring session before one prompt, and never grants unattended approval',async()=>{
 const {EventEmitter}=await import('node:events')
 const {PassThrough,Writable}=await import('node:stream')
 const {createTaskExecutor}=await import('../src/task-gateway-runner.mjs')
 const messages=[],bound=[]
 const child=new EventEmitter();child.stdout=new PassThrough();child.stderr=new PassThrough()
 child.kill=()=>{queueMicrotask(()=>{child.emit('exit',0);child.emit('close',0)});return true}
 const reply=message=>child.stdout.write(JSON.stringify(message)+'\n')
 let promptID
 child.stdin=new Writable({write(bytes,encoding,done){
   const message=JSON.parse(String(bytes));messages.push(message)
   queueMicrotask(()=>{
     if(message.method==='initialize')reply({id:message.id,result:{protocolVersion:1,agentCapabilities:{loadSession:true}}})
     if(message.method==='session/load')reply({id:message.id,result:{sessionId:'native-1',configOptions:[{id:'model',currentValue:'a',options:[{value:'a'},{value:'b'}]}]}})
     if(message.method==='session/set_config_option')reply({id:message.id,result:{configOptions:[{id:'model',currentValue:'b',options:[{value:'a'},{value:'b'}]}]}})
     if(message.method==='session/prompt'){assert.deepEqual(bound,['native-1']);promptID=message.id;reply({jsonrpc:'2.0',id:'permission',method:'session/request_permission',params:{options:[{kind:'allow_once',optionId:'allow'}]}})}
     if(message.id==='permission'){assert.equal(message.result.outcome.outcome,'cancelled');reply({id:promptID,result:{stopReason:'end_turn'}})}
   });done()
 }})
 const execute=createTaskExecutor({catalog:new Map([['codex',{id:'codex',transport:'acp',command:'fixture',arguments:[]}]]),workspaceRoot:'/tmp',environment:()=>({}),launch:()=>child})
 const config={...task().task.configuration,model:'b'}
 await assert.rejects(()=>execute({run:{id:'run',title:'Fixture',task:{...task().task,configuration:config}},nativeSessionID:'native-1',signal:new AbortController().signal,publish:()=>{},bindSession:id=>bound.push(id)}),error=>error.needsApproval===true)
 assert.equal(messages.filter(m=>m.method==='session/prompt').length,1)
 assert.ok(messages.find(m=>m.method==='session/prompt').params.prompt[0].text.includes('require the Mac app'))
})

test('re-enabling cannot run stale schedules until a fresh publication fences local edits',async t=>{
 let count=0
 const {gateway}=await fixture(t,{now:()=>Date.parse('2026-01-02T15:00:00Z'),execute:async()=>{count++}})
 gateway.publish({publicationID:'old',schedules:[task()],knownRuns:[]})
 await gateway.configure({enabled:false});await gateway.configure({enabled:true})
 gateway.tick();assert.equal(count,0)
 gateway.publish({publicationID:'fresh',schedules:[],knownRuns:[]});gateway.tick();assert.equal(count,0)
 gateway.publish({publicationID:'fresh2',schedules:[task()],knownRuns:[]});gateway.tick();await settled(gateway);assert.equal(count,1)
})


test('scheduled output batches sync and is complete before the terminal result is published', async t=>{
 let syncs=0
 const {directory,gateway}=await fixture(t,{now:()=>Date.parse('2026-01-02T15:00:00Z'),
 syncJournal:fd=>{syncs++;fsyncSync(fd)},execute:async ({publish})=>{
   for(let i=0;i<1000;i++)publish({sessionUpdate:'agent_message_chunk',content:{type:'text',text:'x'}})
 }})
 const started=performance.now()
 gateway.publish({publicationID:'batch',schedules:[task()],knownRuns:[]});gateway.tick();await settled(gateway)
 const result=gateway.results().entries[0]
 assert.equal(result.updates.length,1000)
 assert.ok(syncs<10,`stream used ${syncs} syncs`)
 assert.equal((await readFile(resolve(directory,`run-${result.id}.jsonl`),'utf8')).trim().split('\n').length,1000)
 t.diagnostic(`1000 scheduled chunks: ${syncs} journal syncs, ${(performance.now()-started).toFixed(1)}ms`)
 const restarted=createTaskGateway({directory,execute:async()=>{throw new Error('no replay')}})
 assert.equal(restarted.results().entries[0].updates.length,1000)
})
