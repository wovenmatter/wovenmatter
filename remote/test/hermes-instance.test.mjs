import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { createHermesInstance } from '../src/hermes-instance.mjs'

test('Hermes owns a persistent backend and restores its startup preference', async () => {
  const root=await mkdtemp(resolve(tmpdir(),'hermes-instance-'))
  const fixture=resolve(root,'backend.mjs')
  await writeFile(fixture,`import {createServer} from 'node:http';import{writeFileSync}from'node:fs';
    const server=createServer((req,res)=>{if(req.headers.authorization!=='Bearer '+process.env.HERMES_DASHBOARD_SESSION_TOKEN){res.writeHead(401);res.end();return}
      res.setHeader('content-type','application/json');res.end(JSON.stringify({process:{pid:process.pid}}))});
    server.listen(0,'127.0.0.1',()=>writeFileSync(process.env.HERMES_DESKTOP_READY_FILE,JSON.stringify({port:server.address().port})));`)
  const children=[]
  const options={environment:()=>({ ...process.env,HOME:root,HERMES_HOME:resolve(root,'.hermes') }),isEnabled:async()=>true,
    pluginSource:resolve(import.meta.dirname,'../../harnesses/hermes-delivery'), acquireLock:async()=>()=>{},
    spawnProcess:(command,args,options)=>{
      assert.equal(command,'hermes');assert.deepEqual(args.slice(0,2),['serve','--isolated'])
      assert.equal(options.env.HERMES_DESKTOP,'1');assert.equal(options.env.HERMES_DESKTOP_PARENT_PID,undefined)
      const child=spawn(process.execPath,[fixture],options);children.push(child);return child
    }}
  const first=createHermesInstance(options)
  let second
  try {
    await Promise.all([first.start(),first.start()])
    assert.equal(children.length,1)
    assert.equal(first.status().state,'running')
    assert.equal(await readFile(resolve(root,'.hermes/.woven-matter/enabled'),'utf8'),'1')
    first.close();await once(children[0],'exit')
    second=createHermesInstance(options);await second.restore()
    assert.equal(second.status().state,'running');assert.equal(children.length,2)
    assert.notEqual(children[0].pid,children[1].pid)
  } finally { first.close();second?.close();for(const child of children)child.kill('SIGTERM');await rm(root,{recursive:true,force:true}) }
})

test('disabled Hermes never launches', async()=>{
  const instance=createHermesInstance({environment:()=>({HOME:'/tmp'}),isEnabled:async()=>false,spawnProcess:()=>{throw Error('unexpected launch')}})
  try { await assert.rejects(instance.start(),/disabled/);assert.equal(instance.status().state,'stopped') }
  finally{instance.close()}
})

test('native delivery plugin has provider-free durable-identity tests', async()=>{
  const child=spawn('python3',[resolve(import.meta.dirname,'../../harnesses/hermes-delivery/test_delivery.py')],{env:{...process.env,PYTHONDONTWRITEBYTECODE:'1'},stdio:'pipe'})
  let error='';child.stderr.on('data',bytes=>{error+=bytes})
  const [code]=await once(child,'exit');assert.equal(code,0,error)
})
