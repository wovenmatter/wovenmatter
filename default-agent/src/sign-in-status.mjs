import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec = promisify(execFile);
const checks = {
  codex: [['login', 'status']],
  claude_code: [['auth', 'status', '--json']],
  grok_build: [['models']],
  cursor: [['status', '--format', 'json']],
  hermes: ['openai-codex', 'anthropic', 'xai-oauth', 'xai', 'openai'].map(p => ['auth', 'status', p]),
  pi: ['openai-codex', 'xai', 'openai', 'openrouter'].map(p => ['auth', 'check', '--provider', p, '--json', '--no-refresh']),
  openclaw: [['models', 'status', '--json']],
  opencode: [['auth', 'list']],
};
// No login, model prompt, transport startup, or credential writes. Nonzero
// status alone cannot distinguish a network failure from a signed-out account.
export async function signInStatuses(harnesses, execute = exec) {
  return Promise.all(harnesses.map(async harness => {
    const base = { id: harness.id, name: harness.name ?? harness.displayName };
    if (harness.enabled === false) return { ...base, state: 'not_checked', detail: 'Enable credential access for this harness to check its sign-in.' };
    if (!harness.executable) return { ...base, state: 'not_installed', detail: 'This harness is not installed in this workspace.' };
    const commands = checks[harness.id];
    if (!commands) return { ...base, state: 'not_checked', detail: 'This harness does not expose a supported read-only sign-in check. Check its own settings.' };
    const outcomes = await Promise.all(commands.map(async args => {
      let output, success = false;
      try {
        const result = await execute(harness.executable, args, { timeout: 10000, killSignal: 'SIGKILL', maxBuffer: 65536, env: { ...process.env, NO_OPEN_BROWSER: '1', BROWSER: '/usr/bin/false' } });
        output = result.stdout; success = true;
      } catch (error) {
        if (error.code === 'ENOENT') return 'not_installed';
        if (error.killed || error.signal) return 'check_failed';
        output = String(error.stdout ?? '') + String(error.stderr ?? '');
      }
      output = String(output ?? '').replace(/\x1b\[[0-9;]*m/g, '');
      if (harness.id === 'opencode' && success) {
        const counts = [...output.matchAll(/\b(\d+) (?:credentials?|environment variables?)\b/g)].map(match => Number(match[1]));
        if (counts.length) return counts.some(count => count > 0) ? 'credentials_present' : 'sign_in_required';
      }
      if (/not (?:logged|signed) in|not authenticated|login required|"loggedIn"\s*:\s*false|"authenticated"\s*:\s*false/i.test(output)) return 'sign_in_required';
      if (success && /logged in|signed in|"loggedIn"\s*:\s*true|"authenticated"\s*:\s*true|"status"\s*:\s*"(?:ready|usable)"/i.test(output)) return 'verified';
      return success ? 'not_checked' : 'check_failed';
    }));
    const state = outcomes.includes('verified') ? 'verified' : outcomes.includes('credentials_present') ? 'credentials_present'
      : outcomes.every(v => v === 'not_installed') ? 'not_installed'
      : outcomes.every(v => v === 'sign_in_required') ? 'sign_in_required'
      : outcomes.every(v => v === 'not_checked') ? 'not_checked' : 'check_failed';
    const details = { verified: 'The harness reports that it is signed in; available usage is not checked.',
      credentials_present: 'The harness reports stored credentials; provider access has not been verified.',
      not_checked: 'The command did not report a recognized sign-in state. Check the harness settings.',
      sign_in_required: 'The harness reports that sign-in is required.', not_installed: 'This harness is not installed.',
      check_failed: 'Could not confirm sign-in. A failed check does not mean the account is signed out.' };
    return { ...base, state, detail: details[state] };
  }));
}
