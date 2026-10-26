import test from 'node:test'
import assert from 'node:assert/strict'
import { queryWorkspaceMCPHistory as query } from '../src/workspace-mcp-history.mjs'

function fixture(count=12) {
  const records=[],events=[]
  for(let index=0;index<count;index++) {
    const id='conversation-'+index,folderID=index%2?'other':'current'
    records.push({conversation:{id,title:'Session '+index,folderID,runtimeKind:index%2?'claude_code':'codex',updatedAt:'2026-10-26T12:00:00Z'},
      native:{sessionID:'native-'+index},transcript:{messages:[{id:'message-'+index,conversationID:id,runID:'run-'+index,role:'assistant',status:'completed',content:'Retained message '+index,createdAt:'2026-10-26T12:00:00Z'}],activities:[]}})
    events.push({eventID:'event-'+index,originSequence:index+1,conversationID:id,runID:'run-'+index,kind:'transcript',recordedAt:'2026-10-26T12:00:00Z',transcript:{messages:records[index].transcript.messages}})
  }
  return {records,events,callerID:'conversation-0',workspace:{id:'owner-workspace'}}
}

function readAll(name,input,state) {
  const rows=[];let after=0
  for(let page=0;page<100;page++) {
    const result=query(name,{...input,after},state)
    rows.push(...result.rows)
    if(!result.hasMore)return rows
    assert.notEqual(result.nextCursor,after,'a nonterminal page must advance')
    after=result.nextCursor
  }
  assert.fail('pagination did not terminate')
}

test('every advertised after cursor traverses stable listings, history events and runs',()=>{
  const state=fixture(83)
  const conversations=readAll('woven_sessions_list',{limit:7,allWorkspace:true},state)
  assert.equal(conversations.length,83)
  assert.equal(new Set(conversations.map(row=>row.id)).size,83)
  assert.equal(conversations[0].id,'conversation-82')
  state.records[0].conversation.updatedAt='2099-01-01T00:00:00Z'
  assert.deepEqual(readAll('woven_history_conversations',{limit:13},state).map(row=>row.id),conversations.map(row=>row.id))
  assert.equal(readAll('woven_history_events',{limit:9},state).length,83)
  assert.equal(readAll('woven_history_search',{search:'Retained message',limit:5,allWorkspace:true},state).length,83)
  assert.equal(readAll('woven_history_runs',{limit:8},state).length,83)
  // Retained batches can introduce several runs at one journal sequence.
  state.events.push({eventID:'multi-run',originSequence:84,conversationID:'conversation-0',kind:'transcript',transcript:{runs:[{id:'extra-a'},{id:'extra-b'}]}})
  assert.equal(readAll('woven_history_runs',{limit:1},state).length,85)
})

test('canonical filters select exact retained provenance and unavailable metadata never broadens a query',()=>{
  const state=fixture(4)
  Object.assign(state.events[2],{sourceID:'native-source',nativeSessionID:'native-2',nativeRecordID:'native-record',nativeConversationID:'child-2'})
  const result=query('woven_history_search',{search:'Retained',allWorkspace:true,conversation:'conversation-2',run:'run-2',harness:'codex',folder:'current',kind:'transcript',
    since:'2026-10-26T11:00:00Z',until:'2026-10-26T13:00:00Z',sourceID:'native-source',nativeSessionID:'native-2',nativeRecordID:'native-record',nativeConversationID:'child-2'},state)
  assert.deepEqual(result.rows.map(row=>row.id),['event-2'])
  assert.equal(query('woven_history_events',{harness:'does-not-exist'},state).rows.length,0)
  assert.throws(()=>query('woven_history_events',{conversation:'conversation-0',sourceID:'unrecorded'},state),{code:'metadata_unavailable'})
  delete state.events[0].recordedAt
  assert.throws(()=>query('woven_history_events',{since:'2026-10-26T00:00:00Z'},state),{code:'metadata_unavailable'})
  assert.throws(()=>query('woven_history_events',{since:'tomorrow'},state),{statusCode:400})
  assert.throws(()=>query('woven_history_events',{since:'2026-10-27T00:00:00Z',until:'2026-10-26T00:00:00Z'},state),{statusCode:400})
  assert.equal(query('woven_history_search',{search:'message 1'},state).scope,'workspace','empty folder search broadens within the same owner')
  const native=Buffer.from(JSON.stringify({sourceID:'original-source',_meta:{nativeConversationID:'child'},content:{text:'Native tool detail needle'}}))
  state.events.push({eventID:'native-event',originSequence:5,conversationID:'conversation-0',kind:'nativeRecord',nativeRecord:{recordID:'original-record',partIndex:0,partCount:1,byteCount:native.length,data:native.toString('base64')}})
  const raw=query('woven_history_search',{search:'Native tool detail needle',sourceID:'original-source',nativeSessionID:'native-0',nativeConversationID:'child'},state)
  assert.deepEqual(raw.rows.map(row=>row.id),['native-event'])
})

test('message pages and Unicode body windows are separate, and scoped readers cannot cross conversations',()=>{
  const state=fixture(2),record=state.records[0]
  record.transcript.messages=Array.from({length:9},(_,index)=>({id:'chunk-message-'+index,conversationID:record.conversation.id,runID:'run-0',role:'assistant',content:'😀漢字'.repeat(30)}))
  assert.equal(readAll('woven_history_conversation',{id:record.conversation.id,limit:2,characters:3},state).length,9)
  const recovered=[];let offset=0
  for(;;) {
    const row=query('woven_history_message',{id:'chunk-message-0',offset,characters:7},state).rows[0]
    recovered.push(row.content)
    if(!row.content_has_more)break
    assert.ok(row.nextOffset>offset);offset=row.nextOffset
  }
  assert.equal(recovered.join(''),'😀漢字'.repeat(30))
  const scoped={...state,readableConversationIDs:new Set([record.conversation.id]),relationship:id=>({sessionID:id,coordinationEpoch:'epoch',notificationsEnabled:true})}
  assert.equal(query('woven_sessions_status',{id:record.conversation.id},scoped).relationship.coordinationEpoch,'epoch')
  assert.throws(()=>query('woven_history_conversation',{id:'conversation-1'},scoped),{statusCode:403})
  assert.equal(query('woven_history_search',{search:'Retained',allWorkspace:true},scoped).rows.some(row=>row.conversation_id==='conversation-1'),false)
  const event=query('woven_history_event',{id:'event-0',offset:0,characters:10},state).rows[0]
  assert.equal(event.payload.length,10);assert.ok(event.payload_has_more);assert.equal(event.nextOffset,10)
})
