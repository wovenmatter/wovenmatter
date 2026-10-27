import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, readFileSync, readdirSync, statSync, appendFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { updateReasoningDetails, flushReasoningDetails } from '../src/reasoning-details.mjs'

test('large reasoning coalesces dirty flushes, forces terminal suffix, and replays immutable emission decisions',t=>{
  const directory=mkdtempSync(join(tmpdir(),'reasoning-details-'))
  t.after(()=>rmSync(directory,{recursive:true,force:true}))
  let activity={id:'run:trace'},before
  const large='α'.repeat(90000),input=text=>({content:{text}})
  const initial=updateReasoningDetails(directory,activity,input(large),'0',1000)
  assert.ok(initial.length>1)
  for(let index=1;index<=20;index++) {
    before=structuredClone(activity)
    assert.deepEqual(updateReasoningDetails(directory,activity,input(' tail'),'r'+index,1000+index*10),[])
    assert.equal(flushReasoningDetails(directory,activity,{now:1000+index*10}),null)
  }
  // Restart/retry after a lost ACK cannot turn a skipped emission into a new event.
  const retried=structuredClone(before)
  assert.deepEqual(updateReasoningDetails(directory,retried,input(' tail'),'r20',9000),[])
  assert.deepEqual(retried,activity)
  const terminal=flushReasoningDetails(directory,activity,{force:true,now:1200})
  assert.equal(JSON.parse(Buffer.concat(terminal.map(part=>Buffer.from(part.data,'base64')))).activity.content,large+' tail'.repeat(20))
  // A lost terminal ACK is replayable from the previously checkpointed row.
  assert.deepEqual(flushReasoningDetails(directory,retried,{force:true,now:10000}),terminal)
  const corrected=updateReasoningDetails(directory,activity,{content:{text:'corrected'},_meta:{wovenThoughtSnapshot:true}},'correction',1201)
  assert.deepEqual(corrected,[]);assert.equal(activity.detailsRecordID,undefined)
  assert.equal(JSON.parse(activity.projectionJSON).content,'corrected')
})

test('hundreds of advancing-clock updates stay live with linear native and sidecar storage',t=>{
  const directory=mkdtempSync(join(tmpdir(),'reasoning-growth-'))
  t.after(()=>rmSync(directory,{recursive:true,force:true}))
  const activity={id:'growing:trace'},records=new Map(),chunk='🧵'.repeat(1024),count=400
  let transferred=0,full='',bases=0,links=0,producerMilliseconds=0
  const started=performance.now()
  function accept(parts) {
    if(!parts.length)return
    const bytes=Buffer.concat(parts.map(part=>Buffer.from(part.data,'base64')))
    transferred+=bytes.length
    const value=JSON.parse(bytes)
    records.set(parts[0].recordID,value)
    if(value.previousDetailsRecordID)links++;else bases++
  }
  function disclosed() {
    if(!activity.detailsRecordID)return JSON.parse(activity.projectionJSON).content
    const suffixes=[];let id=activity.detailsRecordID
    while(id){const value=records.get(id);assert.ok(value);suffixes.push(value.activity.content);id=value.previousDetailsRecordID}
    return suffixes.reverse().join('')
  }
  for(let index=0;index<count;index++) {
    full+=chunk
    const updateStarted=performance.now()
    const emitted=updateReasoningDetails(directory,activity,{content:{text:chunk}},String(index),1000+index*500)
    producerMilliseconds+=performance.now()-updateStarted
    accept(emitted)
    assert.equal(disclosed(),full,'expanded disclosure must include every emitted suffix')
    assert.ok(activity.projectionJSON.length<17000)
  }
  accept(flushReasoningDetails(directory,activity,{force:true,now:202000}))
  assert.equal(disclosed(),full)
  assert.equal(records.get(activity.detailsRecordID).previousDetailsRecordID,undefined)
  const finalBytes=Buffer.byteLength(full),root=join(directory,'activity-details')
  const logFile=readdirSync(root).find(name=>name.endsWith('.jsonl'))
  const metadataFile=readdirSync(root).find(name=>name.endsWith('.json'))
  const storedRecords=readdirSync(join(root,'records')).reduce((sum,name)=>sum+statSync(join(root,'records',name)).size,0)
  assert.ok(transferred<5*finalBytes+count*1024,`native transfer ${transferred} must scale linearly with ${finalBytes}`)
  assert.equal(storedRecords,transferred)
  assert.ok(statSync(join(root,logFile)).size<finalBytes+count*100)
  assert.ok(statSync(join(root,metadataFile)).size<40000)
  assert.ok(links>350);assert.ok(bases<12)
  t.diagnostic(JSON.stringify({updates:count,elapsedMilliseconds:Math.round(performance.now()-started),producerMilliseconds:Math.round(producerMilliseconds),finalBytes,transferred,sidecarLogBytes:statSync(join(root,logFile)).size,sidecarMetadataBytes:statSync(join(root,metadataFile)).size,bases,links}))
})

test('append-only accumulator recovers an uncommitted tail and preserves split Unicode deltas',t=>{
  const directory=mkdtempSync(join(tmpdir(),'reasoning-log-'))
  t.after(()=>rmSync(directory,{recursive:true,force:true}))
  const activity={id:'recover:trace'},large='x'.repeat(20000)
  updateReasoningDetails(directory,activity,{content:{text:large}},'0',1000)
  assert.deepEqual(updateReasoningDetails(directory,activity,{content:{text:'\ud83e'}},'1',1500),[])
  const root=join(directory,'activity-details'),logFile=join(root,readdirSync(root).find(name=>name.endsWith('.jsonl')))
  appendFileSync(logFile,'{"text":"not committed"}\n{"partial":')
  updateReasoningDetails(directory,activity,{content:{text:'\uddf5 suffix'}},'2',2000)
  const parts=flushReasoningDetails(directory,activity,{force:true,now:2001})
  assert.equal(JSON.parse(Buffer.concat(parts.map(part=>Buffer.from(part.data,'base64')))).activity.content,large+'🧵 suffix')
  assert.equal(readFileSync(logFile,'utf8').includes('not committed'),false)
})

test('small inline reasoning waits for split Unicode and terminal normalization leaves the raw log intact',t=>{
  const directory=mkdtempSync(join(tmpdir(),'reasoning-inline-unicode-'))
  t.after(()=>rmSync(directory,{recursive:true,force:true}))
  const activity={id:'unicode:small'}
  assert.deepEqual(updateReasoningDetails(directory,activity,{content:{text:'\ud83e'}},'high',1000),[])
  assert.equal(activity.detail,'');assert.equal(JSON.parse(activity.projectionJSON).content,'')
  updateReasoningDetails(directory,activity,{content:{text:'\uddf5'}},'low',1500)
  assert.equal(JSON.parse(activity.projectionJSON).content,'🧵')
  updateReasoningDetails(directory,activity,{content:{text:'\ud83e'}},'malformed',2000)
  flushReasoningDetails(directory,activity,{force:true,now:2001})
  assert.equal(activity.detail,'🧵');assert.equal(JSON.parse(activity.projectionJSON).content,'🧵�')
  const root=join(directory,'activity-details'),file=join(root,readdirSync(root).find(name=>name.endsWith('.jsonl')))
  assert.equal(readFileSync(file,'utf8').trimEnd().split('\n').map(line=>JSON.parse(line).text).join(''),'🧵\ud83e')
})

test('exact preview cap drops a split high surrogate and stays valid through native promotion and finalization',t=>{
  const directory=mkdtempSync(join(tmpdir(),'reasoning-preview-cap-'))
  t.after(()=>rmSync(directory,{recursive:true,force:true}))
  const activity={id:'unicode:preview-cap'},prefix='a'.repeat(2047),decode=parts=>JSON.parse(Buffer.concat(parts.map(part=>Buffer.from(part.data,'base64'))))
  function checkRow() {
    assert.equal(activity.detail.isWellFormed(),true)
    assert.equal(JSON.parse(activity.projectionJSON).content.isWellFormed(),true)
  }
  updateReasoningDetails(directory,activity,{content:{text:prefix+'\ud83e'}},'high',1000);checkRow()
  updateReasoningDetails(directory,activity,{content:{text:'\uddf5'}},'low',1500);checkRow()
  assert.equal(activity.detail,prefix)
  assert.equal(JSON.parse(activity.projectionJSON).content,prefix+'🧵')
  const body='b'.repeat(20000)
  const parts=updateReasoningDetails(directory,activity,{content:{text:body}},'promote',2000);checkRow()
  assert.equal(decode(parts).activity.content,prefix+'🧵'+body)
  flushReasoningDetails(directory,activity,{force:true,now:2001});checkRow()
  assert.equal(activity.detail,prefix)
})

test('forced mid-run normalization rebases the next completed Unicode pair instead of linking a lone low surrogate',t=>{
  const directory=mkdtempSync(join(tmpdir(),'reasoning-forced-pair-'))
  t.after(()=>rmSync(directory,{recursive:true,force:true}))
  const activity={id:'unicode:forced-pair'},prefix='x'.repeat(20000),records=new Map()
  function accept(parts) {
    if(!parts.length)return
    const value=JSON.parse(Buffer.concat(parts.map(part=>Buffer.from(part.data,'base64'))))
    assert.equal(value.activity.content.isWellFormed(),true)
    records.set(parts[0].recordID,value)
    return value
  }
  accept(updateReasoningDetails(directory,activity,{content:{text:prefix}},'base',1000))
  assert.deepEqual(updateReasoningDetails(directory,activity,{content:{text:'\ud83e'}},'high',1500),[])
  const forced=accept(flushReasoningDetails(directory,activity,{force:true,now:1501}))
  assert.equal(forced.activity.content,prefix+'�')
  const paired=accept(updateReasoningDetails(directory,activity,{content:{text:'\uddf5 tail'}},'low',1502))
  assert.equal(paired.previousDetailsRecordID,undefined)
  assert.equal(paired.activity.contentIsDelta,false)
  assert.equal(paired.activity.content,prefix+'🧵 tail')
  const linked=accept(updateReasoningDetails(directory,activity,{content:{text:' continued'}},'continue',2002))
  assert.ok(linked.previousDetailsRecordID)
  const suffixes=[];let id=activity.detailsRecordID
  while(id){const value=records.get(id);suffixes.push(value.activity.content);id=value.previousDetailsRecordID}
  assert.equal(suffixes.reverse().join(''),prefix+'🧵 tail continued')
  const root=join(directory,'activity-details'),file=join(root,readdirSync(root).find(name=>name.endsWith('.jsonl')))
  assert.equal(readFileSync(file,'utf8').trimEnd().split('\n').map(line=>JSON.parse(line).text).join(''),prefix+'🧵 tail continued')
})
