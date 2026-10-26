import { existsSync, readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { binding, consume, recordCallContext } from './binding.mjs';

export function handleHook(runtime, directory, event) {
  const session = event.session_id ?? event.sessionId ?? event.conversation_id;
  // Current supported Claude SDK BaseHookInput.prompt_id correlates every
  // hook with its native prompt; it is absent only before the first input.
  // Never fall back to a mutable latest-submission binding when it is absent.
  const inputID = event.turn_id ?? event.prompt_id ?? event.promptId ?? event.generation_id;
  if (!directory || !session || !inputID || !existsSync(directory + '/connection.json')) return {};
  const generation = session + ':' + inputID;
  const name = event.hook_event_name ?? event.hookEventName;
  if (['UserPromptSubmit', 'user_prompt_submit'].includes(name)) {
    consume(directory, generation, event.prompt ?? ''); return {};
  }
  if (!['PreToolUse', 'pre_tool_use'].includes(name)) return {};
  const tool = event.tool_name ?? event.toolName;
  if (typeof tool !== 'string' || !(tool === 'woven_context' || tool.endsWith('_woven_context'))) return {};
  const input = event.tool_input ?? event.toolInput;
  if (!input || typeof input !== 'object' || Array.isArray(input)) return {};
  const requestID = randomUUID();
  recordCallContext(directory, requestID, binding(directory, generation).captureID);
  // This optional catalog field correlates an exact call with transport-only
  // context. It grants no authority and leaves all native approval policy intact.
  return { hookSpecificOutput: { hookEventName: 'PreToolUse', updatedInput: { ...input, requestID } } };
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(JSON.stringify(handleHook(process.argv[2], process.env.WOVEN_MCP_BINDING_DIRECTORY, JSON.parse(readFileSync(0, 'utf8'))))); }
  catch (error) { process.stderr.write('Woven MCP input binding: ' + error.message + '\n'); process.exitCode = 1; }
}
