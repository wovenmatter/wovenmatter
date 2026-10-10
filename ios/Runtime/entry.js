import { nativeSync } from './platform.js';
import { createSubagents } from './subagents.js';
import { createCodeMode } from './codemode.js';
import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
import { Harness, createRegistry, defineExtension, defineTool, watchEvents } from '@earendil-works/pi-durable';
import { JsonlStorage } from '@earendil-works/pi-durable/storage/jsonl';
import { createModels, createProvider } from '@earendil-works/pi-ai/models';
import { AssistantMessageEventStream } from '@earendil-works/pi-ai/utils/event-stream';

let configuration, harness, root, watch, models, codemode;
let nextCall = 0;
const calls = new Map();
function hostCall(kind, value, signal, onEvent) {
  const id = String(++nextCall);
  return new Promise((resolve,reject) => {
    const abort = () => {
      calls.delete(id); globalThis.__wmCancel(id);
      reject(signal.reason ?? new DOMException('The operation was aborted','AbortError'));
    };
    if (signal?.aborted) { abort(); return; }
    calls.set(id,{resolve,reject,onEvent,cleanup:() => signal?.removeEventListener('abort',abort)});
    signal?.addEventListener('abort',abort,{once:true});
    globalThis.__wmAsync(kind,id,JSON.stringify(value));
  });
}
globalThis.__wmComplete = (id,json) => {
  const pending = calls.get(id); if (!pending) return;
  calls.delete(id); pending.cleanup();
  const result = JSON.parse(json);
  if (result.ok) pending.resolve(result.value); else pending.reject(new Error(result.error));
};
globalThis.__wmStreamEvent = (id,json) => calls.get(id)?.onEvent?.(JSON.parse(json));
function filesystem() {
  const fs = {id:'wovenmatter-ios-durable',cwd:'/'};
  for (const operation of ['absolutePath','joinPath','createDir','appendFile','writeFile','flushFile','remove','renameFile','truncateFile','listDir','readBinaryFile']) {
    fs[operation] = async (...args) => {
      args.pop(); // Chord Context stays in JavaScript; only data crosses the bridge.
      try {
        let value = nativeSync('filesystem',{operation,args});
        if (operation === 'readBinaryFile') value = new Uint8Array(value);
        return {ok:true,value};
      } catch (error) { return {ok:false,error:{code:error.code??'unknown',message:error.message}}; }
    };
  }
  return fs;
}
function errorMessage(model,error,signal) {
  return {role:'assistant',content:[],api:model.api,provider:model.provider,model:model.id,
    usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},
    stopReason:signal?.aborted?'aborted':'error',errorMessage:String(error?.message??error),timestamp:Date.now()};
}
function installModel(model) {
  const stream = (model,transcript,options = {}) => {
    const output = new AssistantMessageEventStream(); let terminal = false;
    const {signal,...serializableOptions} = options;
    // Native credentials never enter the JS heap, transcript or checkpoint files.
    delete serializableOptions.apiKey; delete serializableOptions.auth;
    void hostCall('inference',{model,context:transcript,options:serializableOptions,
      scope:{conversationID:`${configuration.conversationID}:${options.sessionId??'root'}`,externalConversationID:configuration.conversationID,requestID:`${configuration.conversationID}:${nativeSync('sha256',JSON.stringify({model,transcript,options:serializableOptions}))}`}},signal,event => {
      if (event.type === 'done' || event.type === 'error') terminal = true;
      output.push(event);
    }).then(() => {
      if (!terminal) throw new Error('Inference stream ended without a terminal result');
      output.end();
    }).catch(error => {
      if (!terminal) output.push({type:'error',reason:signal?.aborted?'aborted':'error',error:errorMessage(model,error,signal)});
      output.end();
    });
    return output;
  };
  models.setProvider(createProvider({id:model.provider,models:[model],auth:{apiKey:{name:'Native credentials',resolve:async () => ({auth:{apiKey:'native-managed'}})}},api:{stream,streamSimple:stream}}));
}
const methods = {
  async open(config) {
    if (harness) throw new Error('Pi Durable is already open');
    configuration = config;
    const model = JSON.parse(config.modelJSON);
    models = createModels({authContext:{env:async()=>undefined,fileExists:async()=>false}});
    installModel(model);
    const registry = createRegistry();
    const tools = JSON.parse(config.toolsJSON).map(descriptor => defineTool({
      ...descriptor,
      // An omitted replay policy intentionally keeps the SDK's interrupted error behavior.
      execute: (arguments_,api,toolContext) => hostCall('tool',{
        name:descriptor.name,arguments:arguments_,conversationID:config.conversationID,
        toolCallID:api.callId,taskID:api.taskId,nativeConversationID:api.conversationId,
      },toolContext.abortSignal),
    }));
    registry.install(defineExtension({name:'wovenmatter-ios',tools}));
    registry.install(createSubagents(() => root.id));
    codemode = createCodeMode({hostCall,getHarness:()=>harness});
    registry.install(codemode.extension);
    const storage = await JsonlStorage.open('/',filesystem(),context,{fsync:true});
    harness = await Harness.open(storage,{models,registry,
      settings:{progress:{partialIntervalMs:100,outputIntervalMs:100}},
      onReport:error => globalThis.__wmEvents(JSON.stringify({conversationID:config.conversationID,events:[{type:'runtime_error',message:String(error?.message??error)}]})),
    },context);
    root = await harness.root(context,{agent:{model:{provider:model.provider,modelId:model.id},instructions:config.instructions}});
    // Configure before resuming saved tasks: account selection is device local.
    await root.configure({model:{provider:model.provider,modelId:model.id},instructions:config.instructions},context);
    watch = await watchEvents(harness,root.id,context);
    globalThis.__wmEvents(JSON.stringify({conversationID:config.conversationID,events:[watch.snapshot]}));
    watch.start(async events => globalThis.__wmEvents(JSON.stringify({conversationID:config.conversationID,events})));
    return watch.snapshot;
  },
  async submit({text,requestID}) {
    const submission = await root.submit({type:'input',content:text,requestId:requestID,whenBusy:'followUp'},context);
    return submission.status(context);
  },
  async nestedTool(request) { return codemode.nestedTool(request); },
  async submission({requestID}) {
    return root.commit(tx => tx.submissionByRequest(root.id,requestID),context);
  },
  async history({nativeConversationID,cursorJSON,limit = 200}) {
    return harness.commit(tx => tx.scanEntries({conversationId:nativeConversationID??root.id},Math.min(500,Math.max(1,limit)),cursorJSON?JSON.parse(cursorJSON):undefined),context);
  },
  async conversations({cursorJSON,limit = 200}) {
    return harness.commit(tx => tx.scanConversations({},Math.min(500,Math.max(1,limit)),cursorJSON?JSON.parse(cursorJSON):undefined),context);
  },
  async wait({submissionID}) {
    const submission = await harness.submission(submissionID,context);
    if (!submission) throw new Error('Unknown submission');
    return submission.wait(context);
  },
  async snapshot() {
    const temporaryWatch = await watchEvents(harness,root.id,context);
    const snapshot = temporaryWatch.snapshot; await temporaryWatch.stop(); return snapshot;
  },
  async configure({modelJSON,instructions}) {
    const model = JSON.parse(modelJSON); installModel(model);
    await root.configure({model:{provider:model.provider,modelId:model.id},...(instructions===undefined?{}:{instructions})},context);
  },
  async resume() { harness.resume(); },
  async abort() { await root.abort(context,{background:true}); },
  async compact({instructions}) { return root.compact(instructions,context); },
  async close() {
    await watch?.stop(); watch = undefined;
    // close suspends pending work. Explicit user Stop uses abort instead.
    await harness?.close(context); harness = undefined; root = undefined;
  },
};
globalThis.__wmDispatch = (id,method,json) => {
  Promise.resolve().then(() => {
    if (!Object.hasOwn(methods,method)) throw new Error('Unknown runtime operation');
    return methods[method](JSON.parse(json));
  }).then(value => globalThis.__wmReply(id,JSON.stringify({ok:true,value:value??null})),
    error => globalThis.__wmReply(id,JSON.stringify({ok:false,error:`${error?.message??error}\n${error?.stack??""}`})));
};
