import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync,rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { createClientExecution } from '../src/client-execution.mjs'
import { maximumMCPRequestBytes } from '../src/workspace-mcp.mjs'
import { enroll } from './fixtures/execution.mjs'

// `mac` answers the signed requests a Mac member would receive (member-client.mjs).
async function fixture(t,{mac,workspaceBrowser}={}) {
  const directory=mkdtempSync(join(tmpdir(),'woven-workspace-mcp-'))
  const runtime={providers:async()=>[{id:'default_agent',runtimeKind:'default_agent',available:true}],create:async()=>({sessionID:randomUUID()}),close:async()=>{}}
  const members=mac?{deviceID:()=>randomUUID(),hasMac:()=>true,transport:{workspaces:async()=>[],
    macs:async()=>[{deviceID:randomUUID(),name:'Mac',endpoint:'https://mac.example.ts.net/wovenmatter'}],request:async(url,options)=>mac(url,options)}}:null
  const service=createClientExecution({directory,runtime,managedDataRoot:join(directory,'databases'),publisherIntervalMilliseconds:0,workspaceBrowser,members})
  t.after(async()=>{await service.close();rmSync(directory,{recursive:true,force:true})})
  const {principal:device}=enroll(service)
  const command=(kind,values={})=>service.command({commandID:randomUUID(),deviceID:device.id,kind,...values},device)
  const opened=await command('createSession'),id=opened.conversationID,connection=service.mcp.sessionConnection(id)
  const scope=service.mcp.resolvePrincipal('Bearer '+connection.bearerToken)
  const call=(name,input={},who=scope)=>service.mcp.handle(who,{jsonrpc:'2.0',id:randomUUID(),method:'tools/call',params:{name,arguments:input}})
  return {directory,service,id,connection,scope,command,call}
}

test('workspace browser runs locally without library authority and returns inline images, including scheduled callers',async t=>{
  const calls=[],workspaceBrowser={executeMCP:async(scope,input)=>{calls.push({scope,input});return {content:[{type:'image',mimeType:'image/jpeg',data:'fixture'}]}},cancelMCP:()=>({cancelled:1})}
  const f=await fixture(t,{workspaceBrowser})
  const response=await f.call('woven_browser_use',{action:'screenshot',tabId:randomUUID()})
  assert.equal(response.result.isError,false);assert.equal(response.result.content[0].type,'image')
  assert.equal(response.result.structuredContent.requestID,calls[0].input.requestID)
  const task=await f.service.prepareTaskMCP({run:{id:randomUUID(),sessionID:randomUUID(),task:{configuration:{tools:{enabled:['browser']}}}},eventRevision:1})
  const taskScope=f.service.mcp.resolvePrincipal('Bearer '+task.bearerToken)
  assert.equal((await f.call('woven_browser_use',{action:'tabs'},taskScope)).result.isError,false)
  await f.command('workspace',{conversationID:f.id,workspaceAction:{sessionTools:{id:f.id,enabled:['goals']}}})
  assert.equal((await f.call('woven_browser_use',{action:'tabs'})).error.code,-32602)
  assert.equal((await f.call('woven_browser_use_cancel',{id:'all'})).result.structuredContent.result.cancelled,1)
})

test('session and outside-agent MCP credentials preserve caller scope, readonly access, and current tool policy',async t=>{
  const f=await fixture(t)
  assert.equal(f.service.mcp.resolvePrincipal('Bearer unrelated'),null)
  const client=f.service.mcp.provisionClient({conversationID:f.id,label:'Outside reviewer'})
  // A tool group a newer Mac names and this host does not have is left out, not refused.
  const newer=f.service.mcp.provisionClient({conversationID:f.id,label:'From a newer Mac',enabledGroups:['notes','a-later-group']})
  assert.deepEqual(newer.enabledGroups,['notes'])
  assert.throws(()=>f.service.mcp.provisionClient({conversationID:f.id,label:'Malformed',enabledGroups:['notes',7]}),{statusCode:400})
  const principal=f.service.mcp.resolvePrincipal('Bearer '+client.connection.bearerToken)
  const denied=await f.call('woven_goals_set',{objective:'Must be denied'},principal)
  assert.equal(denied.error.code,-32602)
  const forged=await f.call('woven_goals_get',{conversationID:randomUUID()})
  assert.equal(forged.error.code,-32602)
  assert.equal((await f.call('woven_goals_get',{},principal)).result.structuredContent.result,null)
  const changed=await f.command('workspace',{conversationID:f.id,workspaceAction:{sessionTools:{id:f.id,enabled:['goals']}}})
  assert.equal(changed.status,'completed')
  const listed=await f.service.mcp.handle(principal,{jsonrpc:'2.0',id:'discover-disabled',method:'tools/list'})
  const names=listed.result.tools.map(tool=>tool.name)
  assert.ok(names.includes('woven_databases_list'))
  assert.ok(!names.includes('woven_databases_create')&&!names.includes('woven_computer_use'))
  assert.equal((await f.call('woven_databases_list',{},principal)).error.code,-32602)
  const ownHistory=await f.call('woven_history_conversations',{},principal)
  assert.deepEqual(ownHistory.result.structuredContent.result.rows.map(row=>row.id),[f.id])
  await f.command('workspace',{conversationID:f.id,workspaceAction:{sessionTools:{id:f.id,enabled:['goals','notes']}}})
  assert.equal((await f.call('woven_databases_list',{},principal)).result.isError,false)
  f.service.mcp.revokeClient(client.id)
  assert.equal(f.service.mcp.resolvePrincipal('Bearer '+client.connection.bearerToken),null)
})

test('goal MCP mutations retain stable receipts and reject request IDs reused with another payload',async t=>{
  const f=await fixture(t),requestID=randomUUID(),input={objective:'Verify MCP migration',requestID}
  const first=await f.call('woven_goals_set',input),retry=await f.call('woven_goals_set',input)
  assert.equal(first.result.isError,false)
  assert.deepEqual(retry.result.structuredContent,first.result.structuredContent)
  const conflict=await f.call('woven_goals_set',{...input,objective:'Different objective'})
  assert.equal(conflict.result.isError,true)
  assert.match(conflict.result.content[0].text,/request ID/)
})

test('remote harnesses delegate prepared HTML with their authenticated caller and retain ordinary request limits',async t=>{
  const requests=[],f=await fixture(t,{mac:async(url,options)=>{requests.push({url,options});return {status:200,body:{jsonrpc:'2.0',id:'html',result:{content:[],structuredContent:{success:true}}}}}})
  // Visual replies remain available even on an older persisted optional-tool selection.
  await f.command('workspace',{conversationID:f.id,workspaceAction:{sessionTools:{id:f.id,enabled:['goals']}}})
  const html='<img src="data:image/png;base64,'+'A'.repeat(5*1024*1024)+'">',requestID=randomUUID()
  assert.equal((await f.call('woven_html_render',{html,title:'Chart',height:240,requestID})).result.structuredContent.success,true)
  const forwarded=requests.find(item=>item.options.body.params?.name==='woven_html_render')
  assert.equal(String(forwarded.url),'https://mac.example.ts.net/wovenmatter/mcp/workspace')
  assert.equal(forwarded.options.headers['x-woven-conversation-id'],f.id)
  assert.ok(forwarded.options.headers['x-woven-enabled-groups'].split(',').includes('html'))
  assert.equal(forwarded.options.body.params.arguments.html,html)
  assert.equal(forwarded.options.body.params.arguments.requestID,requestID)
  assert.equal((await f.call('woven_html_render',{html,title:'Chart',height:240,conversationID:randomUUID()})).error.code,-32602)
  assert.equal(maximumMCPRequestBytes({method:'tools/call',params:{name:'woven_html_render'}}),40*1024*1024)
  assert.equal(maximumMCPRequestBytes({method:'tools/call',params:{name:'woven_notes_read'}}),4*1024*1024)
  assert.equal(maximumMCPRequestBytes({method:'tools/list',params:{name:'woven_html_render'}}),4*1024*1024)
})

test('owner-local database MCP tools work with no Mac and roll back failed SQL atomically',async t=>{
  const f=await fixture(t)
  const created=await f.call('woven_databases_create',{title:'Offline collection',requestID:randomUUID()})
  assert.equal(created.result.isError,false)
  const row=created.result.structuredContent.result
  assert.match(row.owner,/^workspace:/)
  const committed=await f.call('woven_databases_execute',{databaseID:row.id,query:'CREATE TABLE observations(value); INSERT INTO observations VALUES(42)',requestID:randomUUID()})
  assert.equal(committed.result.isError,false)
  const failed=await f.call('woven_databases_execute',{databaseID:row.id,query:'INSERT INTO observations VALUES(99); INSERT INTO missing VALUES(1)',requestID:randomUUID()})
  assert.equal(failed.result.isError,true)
  const queried=await f.call('woven_databases_query',{databaseID:row.id,query:'SELECT value FROM observations'})
  assert.deepEqual(queried.result.structuredContent.result.query.rows,[['42']])
  const listed=await f.call('woven_databases_list')
  assert.equal(listed.result.structuredContent.result.databases[0].revision,2)
  assert.equal(listed.result.structuredContent.result.databases[0].owner,row.owner)
})

test('scheduled MCP callers expose safe content tools and a null input capture without claiming a second lifecycle owner',async t=>{
  const f=await fixture(t,{mac:async url=>String(url).endsWith('/prepare')?{status:200,body:{enabledGroups:['notes','sessions','goals','timers','browser','a-later-group']}}
    :{status:200,body:{jsonrpc:'2.0',id:'fixture',result:{content:[]}}}})
  const run={id:randomUUID(),sessionID:randomUUID(),eventID:randomUUID(),task:{configuration:{tools:{enabled:['notes','sessions','goals','timers','browser']}}}}
  const connection=await f.service.prepareTaskMCP({run,eventRevision:1})
  const scope=f.service.mcp.resolvePrincipal('Bearer '+connection.bearerToken)
  const listed=await f.service.mcp.handle(scope,{jsonrpc:'2.0',id:1,method:'tools/list'})
  const names=listed.result.tools.map(tool=>tool.name)
  assert.ok(names.includes('woven_notes_read'));assert.ok(names.includes('woven_browser_use'))
  assert.ok(!names.includes('woven_goals_set'));assert.ok(!names.includes('woven_sessions_create'));assert.ok(!names.includes('woven_timers_create'))
  const context=await f.call('woven_context',{},scope)
  assert.equal(context.result.structuredContent.result,null)
})
