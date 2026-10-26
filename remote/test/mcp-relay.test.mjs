import test from 'node:test'
import assert from 'node:assert/strict'
import { PassThrough } from 'node:stream'
import { createInterface } from 'node:readline'
import { once } from 'node:events'
import { runMCPRelay } from '../src/mcp-relay.mjs'

test('remote HTTP relay authenticates requests, preserves MCP results, and propagates cancellation',async t=>{
  const input=new PassThrough(),output=new PassThrough(),packets=createInterface({input:output})
  const queue=[],waiters=[]
  packets.on('line',line=>{const packet=JSON.parse(line);if(waiters.length)waiters.shift()(packet);else queue.push(packet)})
  const next=()=>queue.length?Promise.resolve(queue.shift()):new Promise(resolve=>waiters.push(resolve))
  const running=runMCPRelay({input,output,timeoutMilliseconds:10000})
  t.after(async()=>{input.end();await running;packets.close()})
  const token='s'.repeat(43)
  input.write(JSON.stringify({type:'configure',bearerToken:token})+'\n')
  const ready=await next();assert.equal(ready.type,'ready')
  const headers={authorization:'Bearer '+token,'content-type':'application/json'}
  assert.equal((await fetch(ready.endpointURL,{method:'POST',headers:{...headers,authorization:'Bearer wrong'},body:'{}'})).status,401)
  assert.equal((await fetch(ready.endpointURL,{headers})).status,405)
  assert.equal((await fetch(ready.endpointURL,{method:'POST',headers:{...headers,origin:'https://unrelated.example'},body:'{}'})).status,403)
  const message={jsonrpc:'2.0',id:7,method:'tools/call',params:{name:'woven_browser',arguments:{action:'screenshot'}}}
  const response=fetch(ready.endpointURL,{method:'POST',headers,body:JSON.stringify(message)})
  const packet=await next();assert.equal(packet.type,'request');assert.deepEqual(packet.body,message)
  const result={jsonrpc:'2.0',id:7,result:{content:[{type:'image',mimeType:'image/png',data:'cGl4ZWxz'}],structuredContent:{success:true}}}
  input.write(JSON.stringify({type:'response',id:packet.id,status:200,body:result})+'\n')
  assert.deepEqual(await (await response).json(),result)
  const controller=new AbortController()
  const pending=fetch(ready.endpointURL,{method:'POST',headers,signal:controller.signal,body:JSON.stringify({...message,id:8})})
  const active=await next();assert.equal(active.type,'request');controller.abort()
  await assert.rejects(pending)
  const cancelled=await next();assert.equal(cancelled.type,'cancel');assert.equal(cancelled.id,active.id)
})
