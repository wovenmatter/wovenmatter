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

test('overflow preserves generating arguments and resolves a skipped execution from its persisted result', () => {
  const stream = new NativeToolStream(), block = {type:'toolCall',id:'pending',name:'bash',arguments:{command:'echo'}};
  assert.equal(stream.input(block).status,'pending');
  assert.deepEqual(stream.snapshot({entries:[],generation:{message:{content:[block]}}}),[]);
  const settled = stream.snapshot({entries:[{id:9,model:[{role:'toolResult',toolCallId:'pending',content:[{type:'text',text:'done'}]}]}]});
  assert.equal(settled.length,1); assert.equal(settled[0].status,'completed');
  assert.equal(text(settled[0]),'done'); assert.equal(stream.inputs.size,0);
  assert.deepEqual(stream.snapshot({entries:[]}),[]);
});
