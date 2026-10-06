import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtempSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { PiBindings } from './pi-bindings.mjs';
import { join, dirname } from 'node:path';
import { tmpdir, homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { connect, enqueue, quote, writeJSON } from './binding.mjs';

const root = dirname(fileURLToPath(import.meta.url));
export function promptCandidates(runtime, params) {
  if (runtime === 'pi') return [params.message ?? ''];
  if (typeof params.text === 'string') return [params.text];
  const text = [], context = [];
  const link = (uri, name) => name ? `[@${name}](${uri})`
    : /^(file|zed):/.test(uri) ? `[@${uri.split('/').at(-1)}](${uri})` : uri;
  for (const part of params.prompt ?? []) {
    if (part.type === 'text') text.push(part.text);
    if (part.type === 'resource_link') text.push(link(part.uri, runtime === 'codex' ? part.name : undefined));
    if (part.type === 'resource' && typeof part.resource?.text === 'string') {
      const { uri, text: body } = part.resource;
      const label = link(uri), embedded = `\n<context ref="${uri}">\n${body}\n</context>`;
      if (runtime === 'claude_code') { text.push(label); context.push(embedded); }
      else text.push(label + embedded);
    }
  }
  return [...new Set(['\n', '\n\n', ''].map(separator => [...text, ...context].join(separator)))];
}

export function configure(runtime, directory, args, env) {
  const command = [process.execPath, join(root, 'hook.mjs'), runtime].map(quote).join(' ');
  const hooks = Object.fromEntries(['UserPromptSubmit', 'PreToolUse'].map(name => [name, [{ hooks: [{ type: 'command', command }] }]]));
  const plugin = join(directory, 'plugin');
  if (runtime === 'codex') {
    for (const [name, label] of [['UserPromptSubmit', 'user_prompt_submit'], ['PreToolUse', 'pre_tool_use']]) {
      args.push('-c', `hooks.${name}=[{hooks=[{type="command",command=${JSON.stringify(command)}}]}]`);
      // Trust only this bundled hook in this invocation, not unrelated user hooks.
      // Codex fingerprints the normalized TOML value as canonical JSON.
      const identity = { event_name: label, hooks: [{ async: false, command, timeout: 600, type: 'command' }] };
      const hash = 'sha256:' + createHash('sha256').update(JSON.stringify(identity)).digest('hex');
      const state = `/<session-flags>/config.toml:${label}:0:0`;
      args.push('-c', `hooks.state.${JSON.stringify(state)}.trusted_hash=${JSON.stringify(hash)}`);
    }
  } else if (runtime === 'claude_code') {
    writeJSON(join(plugin, '.claude-plugin', 'plugin.json'), { name: 'wovenmatter-cli', version: '1.0.0' });
    writeJSON(join(plugin, 'hooks', 'hooks.json'), { hooks });
  } else if (runtime === 'cursor') {
    writeJSON(join(plugin, '.cursor-plugin', 'plugin.json'), { name: 'wovenmatter-cli', version: '1.0.0' });
    writeJSON(join(plugin, 'hooks', 'hooks.json'), { version: 1, hooks: {
      beforeSubmitPrompt: [{ command }], preToolUse: [{ command }],
    } });
    args.unshift('--plugin-dir', plugin);
  } else if (runtime === 'grok_build') {
    // Grok intentionally excludes hooks from its environment config overlay.
    // This additive native hook is inert outside Woven Matter's transport.
    writeJSON(join(env.GROK_HOME ?? join(homedir(), '.grok'), 'hooks', 'wovenmatter-cli.json'), { hooks });
  } else if (runtime === 'pi') args.push('--extension', join(root, 'pi.mjs'));
  env.WOVENMATTER_BINDING_DIRECTORY = directory;
  return plugin;
}

async function main() {
  const [runtime, executable, ...args] = process.argv.slice(2);
  const directory = mkdtempSync(join(tmpdir(), 'wovenmatter-cli-'));
  const env = { ...process.env };
  const plugin = configure(runtime, directory, args, env);
  const child = spawn(executable, args, { env, stdio: ['pipe', 'pipe', 'inherit', ...(runtime === 'pi' ? ['pipe'] : [])] });
  const pi = runtime === 'pi' ? new PiBindings(directory, value => child.stdio[3].write(JSON.stringify(value) + '\n')) : undefined;
  const pending = new Map();
  let promptID;
  const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
  const output = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const admission = [];
  let admitting;
  function forward(message) {
    if (pi && ['prompt', 'steer', 'follow_up'].includes(message.type)) {
      admission.push(message);
      pump();
    } else child.stdin.write(JSON.stringify(message) + '\n');
  }
  function pump() {
    if (admitting || !admission.length) return;
    admitting = admission.shift();
    pi.submit(admitting._wovenContext);
    delete admitting._wovenContext;
    child.stdin.write(JSON.stringify(admitting) + '\n');
  }
  input.on('line', line => {
    try {
      const message = JSON.parse(line);
      const params = runtime === 'pi' ? message : message.params;
      const meta = params?._meta;
      if (meta?.wovenToolsConnection) connect(directory, meta.wovenToolsConnection);
      if (message.method === 'woven/cli') { connect(directory, message.params); return; }
      if (message.method === 'session/prompt') promptID = message.id;
      if (meta?.wovenTools) {
        if (pi) {
          connect(directory, meta.wovenTools);
          message._wovenContext = meta.wovenTools;
        } else {
          const remove = enqueue(directory, meta.wovenTools, promptCandidates(runtime, params));
          if (message.id !== undefined) pending.set(message.id, { remove, promptID, method: message.method });
        }
      }
      if (meta) {
        delete meta.wovenTools; delete meta.wovenToolsConnection;
        delete meta.wovenRunID; delete meta.wovenInputID;
        if (runtime === 'pi' && !Object.keys(meta).length) delete params._meta;
      }
      if (runtime === 'claude_code' && ['session/new', 'session/load'].includes(message.method)) {
        const metadata = params._meta ??= {};
        const options = (metadata.claudeCode ??= {}).options ??= {};
        options.plugins = [...(options.plugins ?? []), { type: 'local', path: plugin }];
      }
      forward(message);
    } catch (error) { process.stderr.write('Woven Matter transport: ' + error.message + '\n'); child.kill(); }
  });
  output.on('line', line => {
    try {
      const message = JSON.parse(line);
      if (pi?.observe(message)) return;
      if (pi && admitting && message.id === admitting.id && message.type === 'response') {
        admitting = undefined;
        pump();
      }
      // Rejected native input must not be mistaken for a later identical input.
      if (message.id !== undefined && (message.error || message.result !== undefined || message.type === 'response')) {
        const entry = pending.get(message.id);
        if (message.error || message.success === false || entry?.method === 'session/prompt'
            || message.result?.outcome === 'promptRequired') {
          entry?.remove(); pending.delete(message.id);
        }
        if (entry?.method === 'session/prompt') {
          for (const [id, input] of pending) if (input.promptID === message.id) {
            input.remove(); pending.delete(id);
          }
        }
      }
    } catch (error) {
      if (line.includes('wovenmatter_cli')) {
        process.stderr.write('Woven Matter context binding failed: ' + error.message + '\n');
        child.kill(); return;
      }
      // Native diagnostics retain their existing transport behavior.
    }
    process.stdout.write(line + '\n');
  });
  input.on('close', () => child.stdin.end());
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(signal, () => child.kill(signal));
  child.on('error', error => { process.stderr.write(error.message + '\n'); process.exitCode = 1; input.close(); });
  child.on('exit', (code, signal) => {
    rmSync(directory, { recursive: true, force: true });
    input.close(); process.exitCode = code ?? (signal ? 1 : 0);
  });
}
if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
