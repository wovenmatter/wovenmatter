import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

test('published Pi CLI answers the Woven RPC startup commands offline with stdin EOF', { timeout: 15000 }, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'woven-pi-rpc-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const cli = fileURLToPath(new URL('./bundle/cli.js', import.meta.resolve('@earendil-works/pi-coding-agent')));
  const commands = ['get_state', 'get_available_models', 'get_available_thinking_levels', 'get_commands'];
  const result = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [cli, '--mode', 'rpc', '--no-session', '--no-extensions',
      '--no-skills', '--no-prompt-templates', '--no-themes', '--offline'], {
      cwd: directory, env: { PATH: dirname(process.execPath) + ':/usr/bin:/bin',
        PI_CODING_AGENT_DIR: join(directory, 'agent'), TMPDIR: tmpdir() },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '', stderr = '';
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('Pi RPC startup timed out')); }, 10000);
    child.stdout.on('data', value => { stdout += value; });
    child.stderr.on('data', value => { stderr += value; });
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('close', code => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
    child.stdin.on('error', reject);
    child.stdin.end(commands.map((type, index) => JSON.stringify({ id: String(index), type })).join('\n') + '\n');
  });
  assert.equal(result.code, 0, result.stderr);
  const responses = result.stdout.trim().split('\n').map(line => JSON.parse(line));
  for (const [index, command] of commands.entries()) {
    const response = responses.find(value => value.id === String(index));
    assert.equal(response?.command, command);
    assert.equal(response?.success, true);
  }
});
