import { appendWovenInstructions } from './instructions.mjs';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdtempSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
import { tmpdir, homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { connect, enqueue, quote, writeJSON } from './binding.mjs';

const root = dirname(fileURLToPath(import.meta.url));
export function promptCandidates(runtime, params) {
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
  if (!['codex', 'claude_code', 'grok_build'].includes(runtime)) throw new Error('Unsupported Woven harness');
  const command = [process.execPath, join(root, 'hook.mjs'), runtime].map(quote).join(' ');
  const hooks = Object.fromEntries(['UserPromptSubmit', 'PreToolUse'].map(name => [name, [{ hooks: [{ type: 'command', command }] }]]));
  const plugin = join(directory, 'plugin');
  if (runtime === 'codex') {
    const config = JSON.parse(env.CODEX_CONFIG ?? '{}');
    config.approvals_reviewer = 'auto_review';
    config['tools.update_plan.enabled'] = true;
    const additions = [config.developer_instructions, env.WOVENMATTER_ADDITIONAL_INSTRUCTIONS].filter(Boolean).join('\n\n');
    config.developer_instructions = appendWovenInstructions(additions);
    delete env.WOVENMATTER_ADDITIONAL_INSTRUCTIONS;
    env.CODEX_CONFIG = JSON.stringify(config);
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
  } else if (runtime === 'grok_build') {
    // Grok intentionally excludes hooks from its environment config overlay.
    // This additive native hook is inert outside Woven Matter's transport.
    writeJSON(join(env.GROK_HOME ?? join(homedir(), '.grok'), 'hooks', 'wovenmatter-cli.json'), { hooks });
  }
  env.WOVENMATTER_BINDING_DIRECTORY = directory;
  return plugin;
}

export function nativeSessionInstructions(runtime, message, plugin) {
  if (!['session/new', 'session/load'].includes(message.method)) return message;
  const metadata = (message.params ??= {})._meta ??= {};
  if (message.method === 'session/new' && runtime === 'grok_build') {
    metadata.rules = appendWovenInstructions(metadata.rules);
  }
  if (runtime === 'claude_code') {
    if (message.method === 'session/new') {
      const supplied = metadata.systemPrompt;
      metadata.systemPrompt = { ...(typeof supplied === 'object' && supplied !== null ? supplied : {}),
        append: appendWovenInstructions(typeof supplied === 'string' ? supplied : supplied?.append) };
    }
    const options = (metadata.claudeCode ??= {}).options ??= {};
    const native = { type: 'local', path: plugin };
    options.plugins = [...(options.plugins ?? []).filter(value => value.path !== plugin), native];
  }
  return message;
}

async function main() {
  const [runtime, executable, ...args] = process.argv.slice(2);
  const directory = mkdtempSync(join(tmpdir(), 'wovenmatter-cli-'));
  const env = { ...process.env };
  const plugin = configure(runtime, directory, args, env);
  const child = spawn(executable, args, { env, stdio: ['pipe', 'pipe', 'inherit'] });
  const pending = new Map();
  let promptID;
  const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
  const output = createInterface({ input: child.stdout, crlfDelay: Infinity });
  input.on('line', line => {
    try {
      const message = JSON.parse(line);
      const params = message.params;
      const meta = params?._meta;
      if (meta?.wovenToolsConnection) connect(directory, meta.wovenToolsConnection);
      if (message.method === 'woven/cli') { connect(directory, message.params); return; }
      if (message.method === 'session/prompt') promptID = message.id;
      if (meta?.wovenTools) {
        const remove = enqueue(directory, meta.wovenTools, promptCandidates(runtime, params));
        if (message.id !== undefined) pending.set(message.id, { remove, promptID, method: message.method });
      }
      if (meta) {
        delete meta.wovenTools; delete meta.wovenToolsConnection;
        delete meta.wovenRunID; delete meta.wovenInputID;
      }
      nativeSessionInstructions(runtime, message, plugin);
      child.stdin.write(JSON.stringify(message) + '\n');
    } catch (error) { process.stderr.write('Woven Matter transport: ' + error.message + '\n'); child.kill(); }
  });
  output.on('line', line => {
    try {
      const message = JSON.parse(line);
      // Rejected native input must not be mistaken for a later identical input.
      if (message.id !== undefined && (message.error || message.result !== undefined)) {
        const entry = pending.get(message.id);
        if (message.error || entry?.method === 'session/prompt'
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
