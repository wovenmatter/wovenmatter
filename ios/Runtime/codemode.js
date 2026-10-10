import { defineExtension, defineTool, ToolTask } from '@earendil-works/pi-durable';

export function createCodeMode({hostCall,getHarness}) {
  const invocations = new Map();
  const extension = defineExtension({name:'wovenmatter-ios-codemode',tools:[defineTool({
    name:'codemode',
    description:'Run JavaScript in an isolated on-device worker with tools, ALL_TOOLS, text(), store() and load(). Only the listed native tools are available; no network, filesystem, shell or model access exists outside those tools. Await tool calls. Code has a two-minute total time limit. Stored JSON values persist in this conversation after successful execution.',
    parameters:{type:'object',properties:{code:{type:'string',minLength:1,maxLength:131072}},required:['code'],additionalProperties:false},
    replay:'unsafe',
    execute:async ({code},api,context) => {
      const allowed = (await api.agent(context)).tools.filter(tool=>tool.name!=='codemode');
      const id = String(api.taskId);
      const prior = await api.commit(async tx => {
        let cursor;
        do {
          const page = await tx.scanEntries({conversationId:api.conversationId},100,cursor);
          const stored = page.items.find(entry=>entry.kind==='woven.ios-codemode-store');
          if (stored) return stored.data;
          cursor = page.next;
        } while (cursor);
        return {};
      },context);
      const pending = new Set();
      invocations.set(id,{api,context,allowed,pending,next:0,taskIDs:new Set(),closing:false});
      let result;
      try {
        result = await hostCall('codemode',{invocationID:id,source:code,tools:allowed.map(({name,description,parameters})=>({name,description,parameters})),state:prior},context.abortSignal);
      } finally {
        // The SDK retains ownership until every nested call is settled or cancelled.
        const invocation = invocations.get(id); invocations.delete(id);
        if (invocation) {
          invocation.closing = true;
          await Promise.allSettled([...invocation.taskIDs].map(id=>getHarness().abortTask(id,context)));
          await Promise.allSettled([...invocation.pending]);
        }
      }
      if (result.state) await api.commit(tx=>tx.appendEntry(api.conversationId,{kind:'woven.ios-codemode-store',data:result.state}),context);
      return {content:result.content??[],isError:!!result.isError};
    },
  })]});
  async function nestedTool({invocationID,name,arguments:arguments_}) {
    const invocation = invocations.get(invocationID);
    if (!invocation) throw new Error('Code execution has ended.');
    const {api,context,allowed,pending} = invocation;
    if (!allowed.some(tool=>tool.name===name)) throw new Error('Tool is not available in this code execution.');
    context.abortSignal?.throwIfAborted();
    if (invocation.next >= 256) throw new Error("Code execution exceeded 256 tool calls.");
    if (pending.size >= 32) throw new Error("Code execution exceeded 32 simultaneous tool calls.");
    const work = (async () => {
      const model = (await api.agent(context)).model;
      const callID = `${api.callId}/nested/${++invocation.next}`;
      const nested = await api.commit(async tx => {
        const assistant = await tx.appendEntry(api.conversationId,{kind:'pi.assistant',data:{wovenNestedCall:true},model:[{
          role:'assistant',content:[{type:'toolCall',id:callID,name,arguments:arguments_}],api:'woven-ios-nested',provider:model?.provider??'native',model:model?.modelId??'native',
          stopReason:'toolUse',timestamp:Date.now(),usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},
        }]});
        const taskID = await tx.createTask(ToolTask,{assistant:assistant.id,callId:callID},{conversationId:api.conversationId,ownership:{kind:'task',taskId:api.taskId}});
        await tx.appendEntry(api.conversationId,{kind:'woven.ios-codemode-context',edits:[{target:assistant.id,action:'omit'}]});
        return {taskID,assistantID:assistant.id};
      },context);
      invocation.taskIDs.add(nested.taskID);
      if (invocation.closing) await getHarness().abortTask(nested.taskID,context);
      const settled = await api.waitForTask(nested.taskID,context);
      invocation.taskIDs.delete(nested.taskID);
      const outcome = settled.state.outcome;
      if (outcome.status !== 'completed' || !outcome.result?.entryId) throw new Error('Nested tool did not complete.');
      const result = await api.commit(async tx => {
        const entry = await tx.entry(outcome.result.entryId);
        await tx.appendEntry(api.conversationId,{kind:'woven.ios-codemode-context',edits:[{target:outcome.result.entryId,action:'omit'}]});
        return entry?.model?.[0];
      },context);
      return {content:result?.content??[],isError:!!result?.isError};
    })();
    pending.add(work); work.then(()=>pending.delete(work),()=>pending.delete(work));
    return work;
  }
  return {extension,nestedTool};
}
