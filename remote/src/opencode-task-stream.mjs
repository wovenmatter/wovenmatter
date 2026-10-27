// The background executor receives authoritative history snapshots. Keep live
// presentation incremental without changing native archive or replay ownership.
export class OpenCodeTaskStream {
  constructor(publish) { this.publish=publish; this.text=''; this.parts=new Map(); this.tools=new Map(); this.finished=false }
  assistant(text, snapshot=false) {
    if (text===this.text) return
    this.publish({sessionUpdate:'agent_message_chunk',content:{type:'text',text:snapshot?text:text.slice(this.text.length)},...(snapshot?{_meta:{wovenAssistantSnapshot:true}}:{})})
    this.text=text
  }
  reconcile(messages) {
    const parts=messages.flatMap(message=>(message.content??message.parts??[]).map((part,index)=>({id:message.id+':'+(part.id??index),part})))
    const text=parts.filter(({part})=>part.type==='text').map(({part})=>part.text??'').join('')
    let replacing=!text.startsWith(this.text),prefix=''
    // Moving a text boundary can expose a new reasoning block in the middle of
    // an unchanged answer. Rebuild that prefix before publishing the activity.
    const byID=new Map(parts.map(({id,part})=>[id,part]))
    replacing ||= [...this.parts].some(([id,part])=>part.type==='text' && (byID.get(id)?.type!=='text'||!(byID.get(id).text??'').startsWith(part.text??'')))
    const flush=()=>{
      if (replacing) {this.assistant(prefix,true);replacing=false}
      else if(prefix.length>this.text.length&&prefix.startsWith(this.text)) this.assistant(prefix)
    }
    const next=new Map()
    for(const {id,part} of parts) {
      const previous=this.parts.get(id);next.set(id,structuredClone(part))
      if(part.type==='text'){prefix+=part.text??'';continue}
      flush()
      if(JSON.stringify(previous)===JSON.stringify(part))continue
      if(part.type==='reasoning')this.publish({sessionUpdate:'agent_thought_chunk',content:{type:'text',text:part.text??''},_meta:{wovenThoughtID:id,wovenThoughtSnapshot:true}})
      if(part.type==='tool') {
        const state=part.state??{},nativeStatus=state.status??state.type
        const status={pending:'pending',running:'in_progress',in_progress:'in_progress',completed:'completed',error:'failed',failed:'failed',cancelled:'failed'}[nativeStatus]??'pending'
        const output=state.output??state.error??(Array.isArray(state.content)?state.content:[]).map(item=>item.text??'').join('\n')
        this.publish({sessionUpdate:this.tools.has(id)?'tool_call_update':'tool_call',toolCallId:id,title:state.title??part.tool??part.name??'Tool',
          status,rawInput:state.input??state.arguments??part.input??part.arguments,
          ...(output===undefined?{}:{rawOutput:output,content:[{type:'content',content:{type:'text',text:typeof output==='string'?output:JSON.stringify(output)}}]})})
        this.tools.set(id,status)
      }
    }
    flush()
    if(this.text!==text)this.assistant(text,true)
    for(const [id,part] of this.parts)if(!next.has(id)) {
      if(part.type==='reasoning')this.publish({sessionUpdate:'agent_thought_chunk',content:{type:'text',text:''},_meta:{wovenThoughtID:id,wovenThoughtSnapshot:true}})
      if(['pending','in_progress'].includes(this.tools.get(id))){this.publish({sessionUpdate:'tool_call_update',toolCallId:id,status:'failed'});this.tools.set(id,'failed')}
    }
    this.parts=next
  }
  finish() {
    if(this.finished)return
    this.finished=true
    for(const [id,status] of this.tools)if(['pending','in_progress'].includes(status))this.publish({sessionUpdate:'tool_call_update',toolCallId:id,status:'failed'})
    this.publish({sessionUpdate:'woven_assistant_boundary'})
  }
}
