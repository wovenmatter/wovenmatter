import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
const exec = promisify(execFile);
const checks = {
  codex: [['login', 'status']],
  claude_code: [['auth', 'status', '--json']],
  grok_build: [['models']],
  opencode: [['auth', 'list']],
};
// No login, model prompt, transport startup, or credential writes. Nonzero
// status alone cannot distinguish a network failure from a signed-out account.
export async function signInStatuses(harnesses, execute = exec, readAccount = readCodexAccount) {
  return Promise.all(harnesses.map(async harness => {
    const base = { id: harness.id, name: harness.name ?? harness.displayName };
    if (harness.enabled === false) return { ...base, state: 'not_checked', detail: 'Enable credential access for this harness to check its sign-in.' };
    if (!harness.executable) return { ...base, state: 'not_installed', detail: 'This harness is not installed in this workspace.' };
    const commands = checks[harness.id];
    if (!commands) return { ...base, state: 'not_checked', detail: 'This harness does not expose a supported read-only sign-in check. Check its own settings.' };
    const accounts = [];
    const outcomes = await Promise.all(commands.map(async args => {
      let output, success = false;
      try {
        const result = await execute(harness.executable, args, { timeout: 10000, killSignal: 'SIGKILL', maxBuffer: 65536, env: { ...process.env, NO_OPEN_BROWSER: '1', BROWSER: '/usr/bin/false' } });
        output = String(result.stdout ?? '') + String(result.stderr ?? ''); success = true;
      } catch (error) {
        if (error.code === 'ENOENT') return 'not_installed';
        if (error.killed || error.signal) return 'check_failed';
        output = String(error.stdout ?? '') + String(error.stderr ?? '');
      }
      output = String(output ?? '').replace(/\x1b\[[0-9;]*m/g, '');
      if (success) accounts.push(...accountDetails(harness.id, output));
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
    if (state === 'verified' && harness.id === 'codex') {
      const account = await readAccount(harness.executable);
      if (account.length) accounts.splice(0, accounts.length, ...account);
    }
    return { ...base, state, detail: details[state], accounts:
      ['verified', 'credentials_present'].includes(state) ? [...new Map(accounts.map(a => [JSON.stringify(a), a])).values()] : [] };
  }));
}


const safeLabel = value => typeof value === 'string' && value.length > 0 && value.length <= 160
  && !/[\x00-\x1f\x7f]|sk-|Bearer |^eyJ/.test(value) ? value : undefined;
export function accountDetails(id, text) {
  if (id === 'claude_code') {
    try {
      const value = JSON.parse(text), name = safeLabel(value.email) ?? safeLabel(value.apiKeyName);
      if (value.authMethod === 'claude.ai') return [{ method: 'Claude subscription', name }];
      if (['api_key', 'apiKey', 'api-key'].includes(value.authMethod)) return [{ method: 'API key', name }];
    } catch {}
  }
  if (id === 'opencode') {
    return [...text.matchAll(/^[│┃\s]*[●•]\s+([\p{L}0-9 ._()/-]+?)\s+(oauth|api|api_key|[A-Z][A-Z0-9_]*(?:API_KEY|TOKEN))\s*$/gmu)]
      .flatMap(([, name, method]) => safeLabel(name) ? [{ name, method: method === 'oauth' ? 'OAuth'
        : /API_KEY$|TOKEN$/.test(method) ? 'Environment key · ' + method : 'API key' }] : []);
  }
  if (/using ChatGPT/i.test(text)) return [{ method: 'ChatGPT' }];
  if (/API key/i.test(text)) return [{ method: 'API key' }];
  if (/OAuth/i.test(text)) return [{ method: 'OAuth' }];
  return [];
}

// Codex exposes the selected account's public metadata via account/read. Do not
// inspect token files, refresh credentials, or retain an app-server after reading.
export function readCodexAccount(executable) {
  return new Promise(resolve => {
    const child = spawn(executable, ['app-server'], { detached: true, stdio: ['pipe', 'pipe', 'ignore'],
      env: { ...process.env, NO_OPEN_BROWSER: '1', BROWSER: '/usr/bin/false' } });
    let buffer = '', bytes = 0, answer = [], finished = false, killTimer;
    const signal = value => { try { process.kill(-child.pid, value); } catch {} };
    const finish = () => {
      if (finished) return;
      finished = true; clearTimeout(timer); child.stdin.end(); signal('SIGTERM');
      killTimer = setTimeout(() => signal('SIGKILL'), 500);
    };
    const timer = setTimeout(finish, 8000);
    const send = value => { if (!finished) child.stdin.write(JSON.stringify(value) + '\n'); };
    child.stdin.on('error', finish);
    child.on('error', () => { clearTimeout(timer); clearTimeout(killTimer); resolve([]); });
    child.on('close', () => { clearTimeout(timer); clearTimeout(killTimer); resolve(answer); });
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      bytes += Buffer.byteLength(chunk);
      if (bytes > 131072) { finish(); return; }
      buffer += chunk;
      let newline;
      while (!finished && (newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
        let message; try { message = JSON.parse(line); } catch { continue; }
        if (message.id === 1) {
          if (message.error) { finish(); return; }
          send({ method: 'initialized' });
          send({ id: 2, method: 'account/read', params: { refreshToken: false } });
        } else if (message.id === 2) {
          const account = message.result?.account;
          if (account?.type === 'chatgpt') answer = [{ method: 'ChatGPT', name: safeLabel(account.email) }];
          if (account?.type === 'apiKey') answer = [{ method: 'API key' }];
          finish();
        }
      }
    });
    send({ id: 1, method: 'initialize', params: { clientInfo: { name: 'wovenmatter_status', version: '1.0' } } });
  });
}

if (process.argv[2] === '--codex-account') {
  const account = await readCodexAccount(process.argv[3]);
  process.stdout.write(JSON.stringify(account) + '\n');
}
