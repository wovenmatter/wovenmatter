// Preserve the last exposed native partial if the Swift inference bridge fails
// or is cancelled before delivering a terminal provider event.
export async function forwardInferenceStream(output, model, signal, start) {
  let terminal = false, partial;
  try {
    await start(event => {
      if (terminal) return;
      if (event.type === 'done' || event.type === 'error') terminal = true;
      partial = event.error ?? event.message ?? event.partial ?? partial;
      output.push(event);
    });
    if (!terminal) throw new Error('Inference stream ended without a terminal result');
  } catch (error) {
    if (!terminal) {
      terminal = true;
      const message = {role:'assistant',content:[],api:model.api,provider:model.provider,model:model.id,
        usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},
        ...partial,stopReason:signal?.aborted?'aborted':'error',errorMessage:String(error?.message??error),timestamp:Date.now()};
      output.push({type:'error',reason:message.stopReason,error:message});
    }
  } finally { output.end(); }
}
