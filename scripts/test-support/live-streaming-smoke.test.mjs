import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const execute = promisify(execFile);
const runner = resolve(import.meta.dirname, '../live-streaming-smoke.mjs');

test('manual ACP probe counts streamed events, denies permissions and never retains response text', async t => {
  const root = await mkdtemp(join(tmpdir(), 'woven-smoke-fixture-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const adapter = join(root, 'adapter.mjs'), output = join(root, 'report.json');
  await writeFile(adapter, `#!${process.execPath}
import { createInterface } from 'node:readline';
const send = value => console.log(JSON.stringify(value));
let promptID;
createInterface({input:process.stdin}).on('line', line => {
 const m=JSON.parse(line), result=value=>send({jsonrpc:'2.0',id:m.id,result:value});
 if(m.method==='initialize')result({protocolVersion:1});
 if(m.method==='session/new')result({sessionId:'fixture',configOptions:[{id:'model',category:'model',options:[{value:'fixture-model'}]}]});
 if(m.method==='session/set_config_option')result({});
 if(m.method==='session/prompt') {promptID=m.id; send({jsonrpc:'2.0',id:'permission',method:'session/request_permission',params:{}});}
 if(m.id==='permission') {
  if(m.result?.outcome?.outcome!=='cancelled')process.exit(2);
  for(const type of ['agent_thought_chunk','agent_message_chunk','agent_message_chunk'])send({jsonrpc:'2.0',method:'session/update',params:{update:{sessionUpdate:type,content:{text:'PRIVATE_RESPONSE_SENTINEL'}}}});
  setTimeout(()=>send({jsonrpc:'2.0',id:promptID,result:{stopReason:'end_turn'}}),20);
 }
});
`, { mode: 0o700 });
  const { stdout, stderr } = await execute(process.execPath, [runner, '--live', '--harness', 'codex', '--model', 'fixture-model', '--executable', adapter, '--output', output], { timeout: 10000 });
  const reportText = await readFile(output, 'utf8'), report = JSON.parse(reportText);
  assert.equal(report.passed, true);
  assert.equal(report.permissionsDenied, 1);
  assert.equal(report.counts.agent_message_chunk, 2);
  assert.equal(report.counts.agent_thought_chunk, 1);
  assert.ok(report.firstMS.agent_message_chunk <= report.terminalMS);
  assert.equal((stdout + stderr + reportText).includes('PRIVATE_RESPONSE_SENTINEL'), false);
});

test('manual ACP probe refuses accidental invocation without explicit live intent', async () => {
  await assert.rejects(execute(process.execPath, [runner, '--harness', 'codex']), error => {
    assert.equal(error.code, 2);
    assert.match(error.stderr, /--live/);
    return true;
  });
});
