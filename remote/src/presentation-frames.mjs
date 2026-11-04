// Assemble replacement previews before exposing them. The caller chooses an
// in-memory or checkpointed dictionary; raw native frames remain unchanged.
export function assemblePresentationFrame(update, pending) {
  const kind=update.sessionUpdate
  if(!['agent_message_chunk','agent_thought_chunk'].includes(kind))return update
  const key=kind+':'+String(update._meta?.wovenThoughtID??'assistant'),meta=update._meta??{}
  const snapshot=kind==='agent_message_chunk'?meta.wovenAssistantSnapshot:meta.wovenThoughtSnapshot
  if(!snapshot || meta.wovenSnapshotStart===undefined&&meta.wovenSnapshotEnd===undefined){delete pending[key];return update}
  if(meta.wovenSnapshotStart===true)pending[key]=''
  if(!Object.hasOwn(pending,key))return undefined
  pending[key]+=update.content?.text??''
  if(meta.wovenSnapshotEnd!==true)return undefined
  const text=pending[key];delete pending[key]
  return {...update,content:{...update.content,text},_meta:{...meta,wovenSnapshotStart:true,wovenSnapshotEnd:true}}
}

// Split text into transport-sized parts without separating a surrogate pair.
export function textParts(value) {
  const parts=[]
  for(let start=0;start<value.length;) {
    let end=Math.min(start+16384,value.length)
    const last=value.charCodeAt(end-1),next=value.charCodeAt(end)
    if(last>=0xd800&&last<=0xdbff&&next>=0xdc00&&next<=0xdfff)end--
    parts.push(value.slice(start,end));start=end
  }
  return parts.length?parts:['']
}
