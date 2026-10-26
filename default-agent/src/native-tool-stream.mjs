// Adapt Durable's live-window edits to ACP's readable tool-output snapshots.
// Canonical native records retain the full output; this is a bounded UI view.
export class NativeToolStream {
  constructor() { this.outputs = new Map(); }
  output(event) {
    let state = this.outputs.get(event.toolCallId) ?? {text:'',omitted:0};
    const snapshot = event.details?.wovenOutputSnapshot;
    if (Array.isArray(snapshot)) state = {text:snapshot.filter(block=>block.type==='text').map(block=>block.text).join('\n'),omitted:0};
    else if (typeof event.output?.set === 'string') state = {text:event.output.set,omitted:0};
    else if (event.output) {
      const trim = event.output.trimStart ?? 0;
      state = {text:state.text.slice(Math.max(0,trim-state.omitted)) + (event.output.append ?? ''),omitted:Math.max(0,state.omitted-trim)};
    } else return undefined;
    let dropped = Math.max(0,state.text.length-16384);
    if (dropped && state.text.charCodeAt(dropped)>=0xdc00 && state.text.charCodeAt(dropped)<=0xdfff) dropped++;
    state = {text:state.text.slice(dropped),omitted:state.omitted+dropped};
    this.outputs.set(event.toolCallId,state);
    return state.text;
  }
  update(event) {
    const toolCallId = event.toolCallId;
    if (event.type==='tool_execution_start') {
      this.outputs.set(toolCallId,{text:'',omitted:0});
      return {sessionUpdate:'tool_call',toolCallId,title:event.toolName,kind:event.toolName==='bash'?'execute':'other',status:'in_progress',rawInput:event.args};
    }
    if (event.type==='tool_execution_update') {
      const text = this.output(event);
      return {sessionUpdate:'tool_call_update',toolCallId,status:'in_progress',
        ...(text===undefined?{}:{content:[{type:'content',content:{type:'text',text}}]}),rawOutput:event};
    }
    const message = event.entry?.model?.find(value=>value.role==='toolResult');
    let content = message?.content;
    if (!message && event.result?.structuredOutput!==undefined) {
      const value = event.result.structuredOutput;
      content = Array.isArray(value) && value.every(block=>block && ['text','image','audio'].includes(block.type)) ? value
        : value?.type==='image' ? [value] : [{type:'text',text:typeof value==='string'?value:JSON.stringify(value)}];
    }
    const previous = this.outputs.get(toolCallId)?.text;
    if (!content?.length && previous) content = [{type:'text',text:previous}];
    this.outputs.delete(toolCallId);
    const result = message ?? event.result;
    return {sessionUpdate:'tool_call_update',toolCallId,status:result && result.isError!==true?'completed':'failed',
      ...(content===undefined?{}:{content:content.map(content=>({type:'content',content}))})};
  }
  snapshot(event, retained = new Set()) {
    const updates = [];
    const slots = [...(event.tools ?? []), ...(event.nestedTools ?? [])];
    const active = new Set(slots.map(slot => slot.callId));
    const end = slot => this.update({type:'tool_execution_end', toolCallId:slot.callId,
      entry:event.entries.find(entry => entry.id === slot.entry || entry.model?.some(message => message.role === 'toolResult' && message.toolCallId === slot.callId)),
      result:slot.summary});
    for (const slot of slots) {
      if (slot.status === 'running') {
        if (!this.outputs.has(slot.callId)) updates.push(this.update({type:'tool_execution_start',toolCallId:slot.callId,toolName:slot.name,args:slot.arguments}));
        updates.push(this.update({type:'tool_execution_update',toolCallId:slot.callId,output:{set:slot.output ?? ''},details:slot.details}));
      } else if (slot.status === 'done' && this.outputs.has(slot.callId)) updates.push(end(slot));
    }
    // A watch overflow replaces events with a snapshot. Retire missing slots
    // using their persisted results, rather than leaving stale running rows.
    // Synthetic code-mode children have their own publisher and no live slot.
    for (const callId of [...this.outputs.keys()]) if (!active.has(callId) && !retained.has(callId)) updates.push(end({callId}));
    return updates;
  }
}
