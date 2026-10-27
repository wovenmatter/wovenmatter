import test from 'node:test';
import assert from 'node:assert/strict';
import { NativeToolStream } from '../src/native-tool-stream.mjs';

const text = update => update.content?.[0]?.content.text;
const progress = (stream, fields) => stream.update({type:'tool_execution_update',toolCallId:'shell',...fields});



test('watch overflow restores live output and settles missing slots from persisted results', () => {
  const stream = new NativeToolStream();
  progress(stream,{output:{set:'old'}});
  const restored = stream.snapshot({entries:[],tools:[{callId:'shell',name:'bash',status:'running',output:'current'}]});
  assert.equal(text(restored.at(-1)),'current');
  stream.update({type:'tool_execution_start',toolCallId:'manual-child',toolName:'bash'});
  const settled = stream.snapshot({entries:[{id:7,model:[{role:'toolResult',toolCallId:'shell',content:[{type:'text',text:'final'}]}]}]},new Set(['manual-child']));
  assert.equal(settled.length,1);
  assert.equal(settled[0].status,'completed');
  assert.equal(text(settled[0]),'final');
  assert.deepEqual([...stream.outputs.keys()],['manual-child']);
});
