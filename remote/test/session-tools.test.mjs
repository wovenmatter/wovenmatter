import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { chmodSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { loadRuntimeConfiguration, nonInteractiveSessionEnvironment, runtimeHarnessEnvironment, sessionToolsDirectory, presentPermissionChoices } from '../src/config.mjs'

const tools = resolve(fileURLToPath(new URL('../host/session-tools', import.meta.url)))

// A fake sudo stands in for the real one: no test ever asks for a password.
function fakeSudo(t) {
  const directory = mkdtempSync(join(tmpdir(), 'woven-session-tools-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const path = join(directory, 'sudo')
  writeFileSync(path, `#!/bin/sh
[ "$1" = "-n" ] || { echo "expected -n" >&2; exit 99; }
shift
case "$FAKE_MODE" in
  nopasswd) exec "$@" ;;
  nnp) echo 'sudo: The "no new privileges" flag is set, which prevents sudo from running as root.' >&2; exit 1 ;;
  *) echo 'sudo: a password is required' >&2; exit 1 ;;
esac
`)
  chmodSync(path, 0o755)
  return path
}

const run = (command, args, env) => spawnSync(join(tools, command), args, { encoding: 'utf8', timeout: 10_000, stdio: ['ignore', 'pipe', 'pipe'],
  env: { PATH: '/usr/bin:/bin', WOVENMATTER_DEVICE_NAME: 'Mac Mini', ...env } })

test('session sudo runs passwordless rules non-interactively and keeps their exit status', t => {
  const result = run('sudo', ['/bin/sh', '-c', 'echo elevated; exit 3'], { WOVENMATTER_REAL_SUDO: fakeSudo(t), FAKE_MODE: 'nopasswd' })
  assert.equal(result.status, 3)
  assert.equal(result.stdout, 'elevated\n')
  assert.doesNotMatch(result.stderr, /password/)
})

test('session sudo fails at once with the device name when a password is needed', t => {
  const started = Date.now()
  const result = run('sudo', ['/usr/bin/id'], { WOVENMATTER_REAL_SUDO: fakeSudo(t), FAKE_MODE: 'password' })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /a password is required/)
  assert.match(result.stderr, /This command needs Mac Mini's password/)
  assert.ok(Date.now() - started < 5_000)
})

test('session sudo explains Normal user workspaces instead of a password', t => {
  const result = run('sudo', ['/usr/bin/id'], { WOVENMATTER_REAL_SUDO: fakeSudo(t), FAKE_MODE: 'nnp' })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /normal user permissions/)
  assert.doesNotMatch(result.stderr, /needs Mac Mini's password/)
})

test('session sudo streams a long command’s errors as they happen and writes no temporary file', async t => {
  const temporary = mkdtempSync(join(tmpdir(), 'woven-session-tmp-'))
  t.after(() => rmSync(temporary, { recursive: true, force: true }))
  const child = spawn(join(tools, 'sudo'), ['/bin/sh', '-c', 'echo early >&2; sleep 30'], { stdio: ['ignore', 'pipe', 'pipe'],
    env: { PATH: '/usr/bin:/bin', WOVENMATTER_DEVICE_NAME: 'Mac Mini', WOVENMATTER_REAL_SUDO: fakeSudo(t), FAKE_MODE: 'nopasswd', TMPDIR: temporary } })
  t.after(() => child.kill('SIGKILL'))
  let errors = ''
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('stderr was held back: ' + JSON.stringify(errors))), 5_000)
    child.stderr.on('data', data => { errors += data; if (errors.includes('early')) { clearTimeout(timer); resolve() } })
  })
  assert.deepEqual(readdirSync(temporary), [])
})

test('askpass refuses credential prompts immediately', () => {
  const result = run('askpass', ["Password for 'https://example.test': "], {})
  assert.equal(result.status, 1)
  assert.equal(result.stdout, '')
  assert.match(result.stderr, /Password for 'https:\/\/example.test'.*Mac Mini.*cannot answer password prompts/)
})

test('harness and Pi Durable environments put session tools first and disable interactive prompts', () => {
  const configuration = loadRuntimeConfiguration({ HOME: '/home/fixture', PATH: '/usr/bin:/bin' })
  const harness = runtimeHarnessEnvironment({ HOME: '/home/fixture', PATH: '/usr/bin:/bin' }, configuration)
  assert.equal(sessionToolsDirectory(configuration), tools)
  assert.equal(harness.PATH.split(':')[0], tools)
  for (const environment of [harness, nonInteractiveSessionEnvironment({ PATH: tools + ':/usr/bin' }, configuration)]) {
    assert.equal(environment.PATH.split(':').filter(path => path === tools).length, 1)
    assert.equal(environment.GIT_TERMINAL_PROMPT, '0')
    assert.equal(environment.SSH_ASKPASS_REQUIRE, 'force')
    for (const key of ['GIT_ASKPASS', 'SSH_ASKPASS', 'SUDO_ASKPASS']) assert.equal(environment[key], join(tools, 'askpass'))
  }
})

test('permission choices list Full access first and ask-for-approval last', () => {
  const grok = presentPermissionChoices('grok_build', ['default', 'auto', 'acceptEdits', 'dontAsk', 'bypassPermissions'].map(id => ({ id, label: id })))
  assert.deepEqual(grok.map(item => item.id), ['bypassPermissions', 'auto', 'acceptEdits', 'dontAsk', 'default'])
  assert.equal(grok[0].label, 'Full access')
  const codex = presentPermissionChoices('codex', [{ id: 'read-only', label: 'Read only' }, { id: 'workspace-write', label: 'Default' }, { id: 'agent', label: 'Auto-review' }, { id: 'agent-full-access', label: 'Bypass' }])
  assert.deepEqual(codex.map(item => [item.id, item.label]), [['agent-full-access', 'Full access'], ['agent', 'Auto-review'], ['read-only', 'Read only'], ['workspace-write', 'Default']])
  assert.deepEqual(presentPermissionChoices('opencode', ['ask', 'allow', 'deny'].map(id => ({ id, label: id }))).map(item => item.id), ['allow', 'deny', 'ask'])
})
