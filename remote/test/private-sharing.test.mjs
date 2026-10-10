import test from 'node:test'
import assert from 'node:assert/strict'
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,rmSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join,resolve} from 'node:path'
import {spawnSync} from 'node:child_process'

function fixture(t,configuration={}) {
  const root=mkdtempSync(join(tmpdir(),'wm-tailnet-sharing-')),bin=join(root,'bin'),state=join(root,'serve.json'),log=join(root,'calls')
  mkdirSync(bin);writeFileSync(state,JSON.stringify(configuration))
  const executable=(name,body)=>writeFileSync(join(bin,name),'#!/bin/sh\n'+body,{mode:0o700})
  executable('docker',`case "$1" in
info) exit 0;;
version) case "$3" in *Platform.Name*) echo 'Docker Engine - Community';;*) echo '1.55';;esac;;
context) case "$2" in show) echo default;;*) echo unix:///var/run/docker.sock;;esac;;
container) echo '127.0.0.1:7337';;
*) exit 1;; esac\n`)
  executable('tailscale',`case "$1 $2" in
'status --json') echo '{"BackendState":"Running","Self":{"DNSName":"host.example.ts.net."}}';;
'serve status') cat "$FAKE_SERVE_STATE";;
'serve --bg') printf '%s\\n' "$*" >> "$FAKE_SERVE_LOG"; python3 -c 'import json,os; p=os.environ["FAKE_SERVE_STATE"];s=json.load(open(p));s.setdefault("TCP",{})["8443"]={"HTTPS":True};s.setdefault("Web",{}).setdefault("host.example.ts.net:8443",{}).setdefault("Handlers",{})["/wovenmatter-execution/test"]={"Proxy":"http://127.0.0.1:7337"};json.dump(s,open(p,"w"))';;
*) exit 1;; esac\n`)
  t.after(()=>rmSync(root,{recursive:true,force:true}))
  const run=()=>spawnSync('/bin/bash',[resolve(import.meta.dirname,'../../scripts/remote-workspace.sh'),'expose','test','7337','8443'],{env:{...process.env,PATH:bin+':'+process.env.PATH,XDG_RUNTIME_DIR:root,FAKE_SERVE_STATE:state,FAKE_SERVE_LOG:log},encoding:'utf8'})
  return {run,state,log}
}

test('private client sharing preserves unrelated routes and remains idempotent',t=>{
  const f=fixture(t,{Web:{'host.example.ts.net:443':{Handlers:{'/':{Proxy:'http://127.0.0.1:8000'}}}}})
  const result=f.run()
  assert.equal(result.status,0,result.stderr)
  assert.equal(JSON.parse(result.stdout).endpoint,'https://host.example.ts.net:8443/wovenmatter-execution/test')
  const state=JSON.parse(readFileSync(f.state))
  assert.equal(state.Web['host.example.ts.net:443'].Handlers['/'].Proxy,'http://127.0.0.1:8000')
  assert.equal(f.run().status,0)
  assert.equal(readFileSync(f.log,'utf8').trim().split('\n').length,1)
})

test('private client sharing rejects public Funnel and conflicting routes without mutation',t=>{
  for(const config of [
    {AllowFunnel:{'host.example.ts.net:8443':true}},
    {Web:{'host.example.ts.net:8443':{Handlers:{'/wovenmatter-execution/test':{Proxy:'http://127.0.0.1:9999'}}}}},
  ]) {
    const f=fixture(t,config),result=f.run()
    assert.notEqual(result.status,0)
    assert.match(result.stderr,/tailscale_route_conflict/)
    assert.deepEqual(JSON.parse(readFileSync(f.state)),config)
    assert.throws(()=>readFileSync(f.log),{code:'ENOENT'})
  }
})
