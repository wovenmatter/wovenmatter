import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { binding, consume, shellInput } from './binding.mjs';

export function handleHook(runtime, directory, event) {
  const session = event.session_id ?? event.sessionId ?? event.conversation_id;
  const inputID = event.turn_id ?? event.prompt_id ?? event.promptId ?? event.generation_id;
  if (!directory || !session || !inputID || !existsSync(directory + '/connection.json')) return {};
  const generation = session + ':' + inputID;
  const name = event.hook_event_name ?? event.hookEventName;
  if (['UserPromptSubmit', 'user_prompt_submit', 'beforeSubmitPrompt'].includes(name)) {
    consume(directory, generation, event.prompt ?? '');
    return {};
  }
  if (!['PreToolUse', 'pre_tool_use', 'preToolUse'].includes(name)) return {};
  const tool = event.tool_name ?? event.toolName;
  if (!['Bash', 'Shell', 'bash', 'shell', 'shell_command', 'exec_command', 'run_terminal_cmd'].includes(tool)) return {};
  const input = event.tool_input ?? event.toolInput;
  if (!input || typeof input !== 'object') return {};
  const updated = shellInput(input, binding(directory, generation));
  // Deliberately express no permission decision and no additional model context.
  return runtime === 'cursor' ? { updated_input: updated }
    : { hookSpecificOutput: { hookEventName: 'PreToolUse', updatedInput: updated } };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const result = handleHook(process.argv[2], process.env.WOVENMATTER_BINDING_DIRECTORY,
      JSON.parse(readFileSync(0, 'utf8')));
    process.stdout.write(JSON.stringify(result));
  } catch (error) { process.stderr.write('Woven Matter CLI binding: ' + error.message + '\n'); process.exitCode = 1; }
}
