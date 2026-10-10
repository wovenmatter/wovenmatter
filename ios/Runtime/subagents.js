import { configure, defineExtension, defineTool } from '@earendil-works/pi-durable';

// Foreground owned children: the native SDK owns cancellation, recovery and task identity.
// Every child inherits the exact selected provider/model; no silent account switching.
export function createSubagents(rootID) {
  let active = 0;
  const extension = defineExtension({name:'wovenmatter-ios-subagents',tools:[defineTool({
    name:'subagent',
    description:'Delegate a self-contained task to an on-device Pi Durable child and return its answer. Children use this exact inference connection/model and workspace tools, cannot delegate further, and stop with the parent. Supply only the selected context needed for the task. Up to four children may work concurrently.',
    parameters:{type:'object',properties:{task:{type:'string',minLength:1},name:{type:'string'}},required:['task'],additionalProperties:false},
    replay:'safe',
    execute:async (args,api,context) => {
      if (api.conversationId !== rootID()) throw new Error('Subagents cannot delegate to further subagents.');
      if (active >= 4) return {isError:true,content:[{type:'text',text:'Four subagents are already working. Wait for their results before delegating more work.'}]};
      active++;
      try {
        const childID = await api.commit(async tx => {
          const existing = (await tx.scanConversations({ownerTaskId:api.taskId},1)).items[0];
          if (existing) return existing.id;
          const child = await tx.createConversation({ownership:{kind:'task',taskId:api.taskId}});
          await configure(tx,child.id,{extensions:{remove:[extension]},instructions:
            `You are the on-device subagent ${JSON.stringify(args.name??'assistant')}. Complete only the delegated task using the selected context. Your exact model/account is inherited; do not claim another execution location. You cannot delegate further. Return your result to the parent.`});
          return child.id;
        },context);
        await api.details({nativeConversationID:childID,name:args.name??'assistant'},context);
        const child = await api.conversation(childID,context);
        if (!child) throw new Error('The durable child conversation is unavailable.');
        const submission = await child.submit({type:'input',content:args.task,requestId:`subagent:${api.taskId}`},context);
        const settled = await submission.wait(context);
        if (settled.status !== 'done') return {isError:true,content:[{type:'text',text:`Subagent did not complete: ${settled.reason??settled.status}`}],details:{nativeConversationID:childID}};
        const answer = await api.commit(tx => tx.entry(settled.answer),context);
        const content = (answer?.model??[]).flatMap(message => Array.isArray(message.content)?message.content.filter(block=>block.type==='text'||block.type==='image'):[]);
        return {content:content.length?content:[{type:'text',text:'Subagent completed without a text answer.'}],details:{nativeConversationID:childID}};
      } finally { active--; }
    },
  })]});
  return extension;
}
