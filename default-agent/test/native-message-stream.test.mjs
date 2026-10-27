import test from 'node:test';
import assert from 'node:assert/strict';
import { NativeMessageStream } from '../src/native-message-stream.mjs';
import { NativeToolStream } from '../src/native-tool-stream.mjs';

const fixture = () => { const updates = [], tools = new NativeToolStream(); return { updates, tools, stream: new NativeMessageStream(update => updates.push(update), tools) }; };
const assistant = content => ({role:'assistant',content});
const rendered = updates => updates.filter(update => update.sessionUpdate === 'agent_message_chunk').reduce((value, update) => update._meta?.wovenAssistantSnapshot ? update.content.text : value + update.content.text, '');

test('native block order survives snapshots, repeated snapshots and incremental reasoning', () => {
  const { stream, updates } = fixture();
  const message = assistant([{type:'text',text:'Before'}, {type:'thinking',thinking:'Reason'}, {type:'text',text:'After'}]);
  stream.message(message); stream.message(message);
  assert.deepEqual(updates.map(update => update.content.text), ['Before', 'Reason', 'After']);
  stream.change({type:'thinking_delta',contentIndex:1,delta:' more'});
  assert.equal(updates.at(-1)._meta.wovenThoughtID, updates[1]._meta.wovenThoughtID);
  assert.equal(updates.at(-1).content.text, ' more');
  stream.end(assistant([{type:'text',text:'Before'}, {type:'thinking',thinking:'Reason more'}, {type:'text',text:'After'}]));
  assert.equal(rendered(updates), 'BeforeAfter');
  stream.begin(); stream.message(assistant([{type:'thinking',thinking:'Next'}]));
  assert.notEqual(updates.at(-1)._meta.wovenThoughtID, updates[1]._meta.wovenThoughtID);
});

test('replacement and block removal preserve prior assistant boundaries and Unicode', () => {
  const { stream, updates } = fixture();
  stream.end(assistant([{type:'text',text:'Prefix'}]));
  stream.message(assistant([{type:'text',text:'Old'}, {type:'thinking',thinking:'Removed'}, {type:'text',text:'tail'}]));
  stream.message(assistant([{type:'text',text:'🧵'}]));
  assert.equal(rendered(updates), 'Prefix🧵');
  assert.ok(updates.some(update => update._meta?.wovenThoughtSnapshot && update.content.text === ''));
  stream.reset(); stream.end(assistant([{type:'text',text:'Fresh'}]));
  assert.equal(stream.completed, 'Fresh');
});

test('nested incremental arguments update one pending tool and transition into execution', () => {
  const { stream, tools, updates } = fixture();
  const block = {type:'toolCall',id:'call',name:'bash',arguments:{command:'echo ',nested:[{value:'a'}]}};
  stream.message(assistant([block]));
  stream.change({type:'toolcall_delta',contentIndex:0,path:['command'],delta:'hello'});
  stream.change({type:'toolcall_delta',contentIndex:0,path:['nested',0,'value'],delta:'b'});
  assert.deepEqual(updates.map(update => update.sessionUpdate), ['tool_call','tool_call_update','tool_call_update']);
  assert.equal(updates[0].rawInput.command, 'echo ');
  assert.deepEqual(updates.at(-1).rawInput,{command:'echo hello',nested:[{value:'ab'}]});
  const started = tools.update({type:'tool_execution_start',toolCallId:'call',toolName:'bash',args:{command:'echo hello'}});
  assert.equal(started.sessionUpdate,'tool_call_update'); assert.equal(started.status,'in_progress');
  assert.deepEqual(tools.finishPending(), []);
  tools.update({type:'tool_execution_end',toolCallId:'call',result:{isError:false}});
  assert.equal(tools.inputs.size,0);
});

test('abandoned arguments settle and malformed argument paths cannot modify prototypes', () => {
  const { stream, tools, updates } = fixture();
  stream.message(assistant([{type:'toolCall',id:'call',name:'bash',arguments:{command:'a'}}]));
  for (const path of [['__proto__','polluted'], ['missing'], ['command','nested']]) stream.change({type:'toolcall_delta',contentIndex:0,path,delta:'unsafe'});
  assert.equal(updates.length,1); assert.equal({}.polluted,undefined);
  assert.deepEqual(tools.finishPending(),[{sessionUpdate:'tool_call_update',toolCallId:'call',status:'failed'}]);
  assert.deepEqual(tools.finishPending(),[]);
});

test('corrected snapshots place newly exposed thoughts and tools between their native text prefixes', () => {
  const {stream,updates} = fixture();
  stream.end(assistant([{type:'text',text:'Prior.'}]));
  stream.message(assistant([{type:'text',text:'Old answer'}]));
  const start = updates.length;
  stream.message(assistant([{type:'text',text:'Before'}, {type:'thinking',thinking:'Inserted'},
    {type:'text',text:'After'}, {type:'toolCall',id:'new-tool',name:'bash',arguments:{command:'echo'}}]));
  const corrected = updates.slice(start);
  assert.deepEqual(corrected.map(update => update.sessionUpdate), ['agent_message_chunk','agent_thought_chunk','agent_message_chunk','tool_call']);
  assert.equal(corrected[0].content.text,'Prior.Before');
  assert.equal(corrected[0]._meta.wovenAssistantSnapshot,true);
  assert.equal(corrected[2].content.text,'After');
  assert.equal(rendered(updates),'Prior.BeforeAfter');
});

test('redistributing unchanged answer text around new reasoning preserves its native prefix', () => {
  const {stream,updates} = fixture();
  stream.message(assistant([{type:'text',text:'ab'},{type:'text',text:'cd'}]));
  const start = updates.length;
  stream.message(assistant([{type:'text',text:'a'},{type:'thinking',thinking:'Inserted'},{type:'text',text:'bcd'}]));
  assert.deepEqual(updates.slice(start).map(update => update.content.text),['a','Inserted','bcd']);
  assert.equal(updates[start]._meta.wovenAssistantSnapshot,true);
  assert.equal(rendered(updates),'abcd');
});
