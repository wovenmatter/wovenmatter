#!/usr/bin/env bash
set -euo pipefail
# Default is provider-free local fixtures. --installed ID validates only the
# native workspace whose installation record matches ID, on its Linux host.
# Invoke from the Mac over the app's Tailnet SSH transport after deployment.
if [ "${1:-}" != --installed ]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  PYTHONDONTWRITEBYTECODE=1 python3 "$repo_root/scripts/test-support/test_remote_host_json.py"
  PYTHONDONTWRITEBYTECODE=1 python3 "$repo_root/scripts/test-support/test_host_bundle.py"
  exit
fi
workspace_id="${2:-}"
[[ "$workspace_id" =~ ^[a-z0-9][a-z0-9-]{0,47}$ ]] || { printf '%s\n' 'An installed workspace ID is required.' >&2; exit 64; }
[[ "$(uname -s)" = Linux ]] || { printf '%s\n' 'Installed-host verification runs on the deployed Linux host.' >&2; exit 69; }
node="$HOME/.local/share/wovenmatter/node/current/bin/node"
exec "$node" --input-type=module - "$workspace_id" "${3:-}" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync, mkdirSync, writeFileSync, statSync, realpathSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { execFileSync, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
const root=join(homedir(),'.local/share/wovenmatter');
const installation=JSON.parse(readFileSync(join(root,'installation.json'),'utf8'));
assert.equal(installation.id,process.argv[2],'Refuse to test an unrelated workspace.');
const settings=Object.fromEntries(readFileSync(join(homedir(),'.config/wovenmatter/service.env'),'utf8').trim().split('\n').filter(x=>x&&!x.startsWith('#')).map(line=>{const i=line.indexOf('=');return [line.slice(0,i),JSON.parse(line.slice(i+1))]}));
const base='http://127.0.0.1:'+installation.port;
async function call(path,method='GET',body) {
 const response=await fetch(base+path,{method,headers:{authorization:'Bearer '+settings.WOVENMATTER_API_TOKEN,'content-type':'application/json'},...(body?{body:JSON.stringify(body)}:{}),signal:AbortSignal.timeout(90000)});
 assert.equal(response.ok,true,'Native service request failed: '+path+' ('+response.status+')');
 return response.json();
}
const initial=await call('/v1/health');
assert.equal(initial.runtimeKind,'host'); assert.equal(initial.serviceFingerprint,installation.fingerprint);
assert.equal(initial.workspaceRoot,join(root,'workspace')); assert.equal(initial.accessMode,installation.accessMode);
const selftest=await call('/v1/browser/selftest'); assert.equal(selftest.ok,true,JSON.stringify(selftest));
const npmRoot=realpathSync(join(root,'current/tooling/lib/node_modules/npm'));
assert.equal(realpathSync(join(root,'current/default-agent/lib/npm')),npmRoot,'SDK updates must use the private patched npm.');
const npmVersion=JSON.parse(readFileSync(join(npmRoot,'package.json'),'utf8')).version;
const npmNumbers=npmVersion.split('.').map(Number);
assert.ok(npmNumbers[0]>12||(npmNumbers[0]===12&&(npmNumbers[1]>2||(npmNumbers[1]===2&&npmNumbers[2]>=1))),'Private npm is below its security floor.');
const npmGraph=JSON.parse(readFileSync(join(root,'current/npm-runtime/package-lock.json'),'utf8')).packages;
for(const name of Object.keys(npmGraph).filter(key=>key.startsWith('node_modules/')&&!key.slice(13).includes('/node_modules/')).map(key=>key.slice(13))) assert.equal(JSON.parse(readFileSync(join(npmRoot,'node_modules',name,'package.json'),'utf8')).version,npmGraph['node_modules/'+name].version);
const require=createRequire(join(npmRoot,'bin/npm-cli.js'));
assert.equal(typeof require('undici').request,'function'); assert.equal(typeof require('ip-address').Address6,'function'); assert.equal(typeof require('minimatch').minimatch,'function');
assert.equal(execFileSync(process.execPath,[join(npmRoot,'bin/npm-cli.js'),'--version'],{encoding:'utf8'}).trim(),npmVersion);
const { chromium }=await import(pathToFileURL(join(root,'current/default-agent/node_modules/playwright-core/index.mjs')).href);
const connections=[];
try {
 for(const profile of ['verification-a','verification-b']) {
  const connected=await call('/v1/browser/connect?profile='+profile,'POST');
  assert.match(connected.endpoint,/^ws:\/\/127\.0\.0\.1:/);
  connections.push(await chromium.connectOverCDP(connected.endpoint));
 }
 const [a,b]=connections.map(browser=>browser.contexts()[0]);
 await a.clearCookies(); await b.clearCookies();
 await a.addCookies([{name:'woven-profile-fixture',value:'first-profile',url:'https://woven-fixture.invalid'}]);
 assert.equal((await a.cookies()).some(c=>c.name==='woven-profile-fixture'),true);
 assert.equal((await b.cookies()).some(c=>c.name==='woven-profile-fixture'),false);
 const page=await a.newPage(); await page.goto('data:text/html,<title>Native host verification</title><p>Sandboxed Chromium</p>');
 assert.equal(await page.title(),'Native host verification');
 const tabs=await call('/v1/browser/tabs?profile=verification-a');
 assert.ok(tabs.tabs.some(tab=>tab.title==='Native host verification'));
 await page.close();
} finally { for(const browser of connections) await browser.close(); }
if(installation.accessMode==='fullRoot') {
 const uid=execFileSync(join(root,'current/bin/wm-exec'),['exec','sudo','-n','/usr/bin/id','-u'],{encoding:'utf8'}).trim();
 assert.equal(uid,'0','Full root must work without an operation approval or password prompt.');
} else {
 const status=execFileSync(join(root,'current/bin/wm-exec'),['exec','/bin/sh','-c','grep "^NoNewPrivs:" /proc/self/status'],{encoding:'utf8'});
 assert.match(status,/NoNewPrivs:\s+1/);
}
execFileSync('systemctl',['--user','restart','wovenmatter.service']);
let recovered;
for(let retry=0;retry<100;retry++) {
 try { recovered=await call('/v1/health'); break; } catch { await new Promise(resolve=>setTimeout(resolve,300)); }
}
assert.equal(recovered?.serviceFingerprint,initial.serviceFingerprint);
assert.equal(execFileSync('loginctl',['show-user',String(process.getuid()),'--property=Linger','--value'],{encoding:'utf8'}).trim(),'yes');
const checks=['health','verified native Chromium sandbox','separate persistent browser profiles',installation.accessMode+' execution','service restart','linger','private patched npm vendor graph + SDK installer binding'];
// Exercise Normal user through the production wrapper with an isolated HOME;
// never change the installed workspace's immutable Full root access choice.
const ordinaryHome=mkdtempSync(join(tmpdir(),'wovenmatter-normal-user-'));
try {
 for(const path of ['.config/wovenmatter','run','workspace']) mkdirSync(join(ordinaryHome,path),{recursive:true,mode:0o700});
 const ordinary={WOVENMATTER_RUNTIME_KIND:'host',WOVENMATTER_ACCESS_MODE:'user',
  WOVENMATTER_WORKSPACE:join(ordinaryHome,'workspace'),WOVENMATTER_STATE_DIRECTORY:join(ordinaryHome,'run')};
 writeFileSync(join(ordinaryHome,'.config/wovenmatter/service.env'),Object.entries(ordinary).map(([key,value])=>key+'='+JSON.stringify(value)+'\n').join(''),{mode:0o600});
 const options={env:{...process.env,HOME:ordinaryHome},encoding:'utf8'};
 const wrapper=join(root,'current/bin/wm-exec');
 assert.equal(execFileSync(wrapper,['exec','/usr/bin/id','-u'],options).trim(),String(process.getuid()));
 assert.match(execFileSync(wrapper,['exec','/bin/sh','-c','grep "^NoNewPrivs:" /proc/self/status'],options),/NoNewPrivs:\s+1/);
 const elevation=spawnSync(wrapper,['exec','sudo','-n','/usr/bin/id','-u'],options);
 assert.notEqual(elevation.status,0,'Normal user must reject direct sudo elevation.');
 checks.push('normal-user UID + inherited no-new-privileges + direct sudo refusal');
} finally {rmSync(ordinaryHome,{recursive:true,force:true});}
for(const path of ['workspace','databases','run','browser-profiles']) assert.equal(statSync(join(root,path)).mode&0o077,0,'Managed data directory is not private: '+path);
assert.equal(statSync(join(homedir(),'.config/wovenmatter/service.env')).mode&0o777,0o600);
const processes=execFileSync('ps',['-u',String(process.getuid()),'-o','args='],{encoding:'utf8'});
const journal=execFileSync('journalctl',['--user','-u','wovenmatter.service','-n','200','--no-pager','-o','cat'],{encoding:'utf8'});
assert.ok(!processes.includes(settings.WOVENMATTER_API_TOKEN),'A process argument exposed the service credential.');
assert.ok(!journal.includes(settings.WOVENMATTER_API_TOKEN),'The journal exposed the service credential.');
checks.push('private directories/environment + no credential in process arguments or journal');
const competingOwner=spawnSync(join(root,'current/bin/wm-exec'),[
 'exec',join(root,'node/current/bin/node'),join(root,'current/src/server.mjs'),
],{encoding:'utf8',timeout:15000});
assert.notEqual(competingOwner.status,0,'A second service acquired the active workspace owner lock.');
assert.match(competingOwner.stderr,/runtime_active_or_operation_in_progress|runtime.*lock|owner/i,'Competing startup failed for a reason other than ownership.');
checks.push('second service cannot acquire the durable execution owner lock');
if(process.argv[3]==='--offline-sync') {
 const {createClientExecution}=await import(pathToFileURL(join(root,'current/src/client-execution.mjs')).href);
 const directory=mkdtempSync(join(tmpdir(),'wovenmatter-host-offline-'));
 let online=false,requests=0,service; const accepted=new Map();
 const runtime={providers:async()=>[{id:'default_agent',runtimeKind:'default_agent',available:true,canStart:true}],create:async()=>({sessionID:randomUUID()}),run:async()=>{},close:async()=>{}};
 const fetchImpl=async(url,options)=>{
  requests++; if(!online)throw Error('Simulated disconnection');
  assert.ok(url.endsWith('/journal')); const body=JSON.parse(options.body);
  for(const entry of body.entries) {if(accepted.has(entry.eventID))assert.deepEqual(accepted.get(entry.eventID),entry);accepted.set(entry.eventID,entry);}
  return {ok:true,status:200,json:async()=>({libraryID:body.libraryID,acceptedEventIDs:body.entries.map(e=>e.eventID),cursor:accepted.size})};
 };
 const create=()=>createClientExecution({directory,runtime,publisherKey:'fixture-encryption-key-for-offline-test',publisherFetch:fetchImpl,publisherIntervalMilliseconds:0});
 try {
  service=create(); const enrollment={libraryID:randomUUID(),workspaceID:randomUUID(),ownerDeviceID:randomUUID(),deviceID:randomUUID(),scopes:['execution']};
  const client=service.provision(enrollment); const principal=service.principal('Bearer '+client.token,'execution');
  service.configurePublisher({grantID:randomUUID(),libraryID:enrollment.libraryID,workspaceID:enrollment.workspaceID,executionDeviceID:client.workspace.executionDeviceID,endpoint:'https://fixture.tail.ts.net/wovenmatter',token:'fixture-publication-token-that-never-leaves-this-process'});
  const result=await service.command({commandID:randomUUID(),deviceID:enrollment.deviceID,libraryID:enrollment.libraryID,workspaceID:enrollment.workspaceID,kind:'createSession'},principal);
  assert.equal(result.status,'completed'); await assert.rejects(service.synchronizePublisher(),/Simulated disconnection/);
  const before=service.events().entries; assert.ok(before.length>0); assert.equal(accepted.size,0);
  await service.close(); service=create(); online=true; await service.synchronizePublisher();
  assert.deepEqual([...accepted.values()],before);
  await service.close(); service=create(); const prior=requests; await service.synchronizePublisher(); assert.equal(requests,prior);
  checks.push('offline SQLite journal + restart + exact replay + durable acknowledgement');
 } finally {await service?.close(); rmSync(directory,{recursive:true,force:true});}
}
console.log(JSON.stringify({ok:true,kind:'host',workspaceID:installation.id,checks,selftest}));
JS
