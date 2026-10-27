import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile, symlink, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { browserSelfTest, verifySandboxProcesses, missingLibrariesFromLdd } from '../src/browser-selftest.mjs'

async function fixture(t, { seccomp = 2, noNewPrivileges = 1, isolated = true, browserUID = 1000, rendererUID = 1000, parent = 101, flattened = false } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'wovenmatter-proc-fixture-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  for (const [pid, ppid, uid, filter, nnp] of [[100, 1, browserUID, 0, 0], [101, 100, 1000, 0, 0], [102, parent, rendererUID, seccomp, noNewPrivileges]]) {
    await mkdir(join(root, String(pid), 'ns'), { recursive: true })
    await writeFile(join(root, String(pid), 'status'), `Name:\tchrome\nPPid:\t${ppid}\nUid:\t${uid}\t${uid}\t${uid}\t${uid}\nSeccomp:\t${filter}\nNoNewPrivs:\t${nnp}\n`)
    await writeFile(join(root, String(pid), 'cmdline'), pid === 102 ? flattened ? 'chrome --type=renderer --headless=old\0' : 'chrome\0--type=renderer\0' : 'chrome\0')
    for (const ns of ['user', 'pid']) await symlink(`${ns}:[${pid === 102 && isolated ? 2 : 1}]`, join(root, String(pid), 'ns', ns))
  }
  const processInfo = [{ type: 'browser', id: 100 }, { type: 'renderer', id: 102 }]
  return { root, processInfo }
}

test('sandbox proof needs namespaces, renderer seccomp, no-new-privileges and exact browser ancestry', async t => {
  const f = await fixture(t)
  const result = await verifySandboxProcesses(f.processInfo, { procRoot: f.root })
  assert.equal(result.ok, true)
  assert.deepEqual(result.evidence.rendererPIDs, [102])
  assert.deepEqual(result.evidence.namespaces, ['user', 'pid'])
})

test('sandbox proof accepts pinned headless shell process-title rewriting and still rejects disabled sandbox flags', async t => {
  const f = await fixture(t, { flattened: true })
  assert.equal((await verifySandboxProcesses(f.processInfo, { procRoot: f.root })).ok, true)
  await writeFile(join(f.root, '102', 'cmdline'), 'chrome --type=renderer --' + 'no-sandbox\0')
  const disabled = await verifySandboxProcesses(f.processInfo, { procRoot: f.root })
  assert.equal(disabled.ok, false)
  assert.equal(disabled.diagnostic.check, 'process_identity_or_flags')
})

for (const [name, options] of [
  ['inherited filter without namespace isolation', { isolated: false }],
  ['missing renderer filter', { seccomp: 0 }],
  ['missing renderer no-new-privileges', { noNewPrivileges: 0 }],
  ['root browser', { browserUID: 0 }],
  ['root renderer', { rendererUID: 0 }],
  ['unrelated renderer', { parent: 1 }],
]) test(`sandbox proof rejects ${name}`, async t => {
  const f = await fixture(t, options)
  const result = await verifySandboxProcesses(f.processInfo, { procRoot: f.root })
  assert.equal(result.ok, false); assert.equal(result.reason, 'sandbox_inactive')
})

test('missing or unreadable process evidence never produces success', async t => {
  const f = await fixture(t)
  await rm(join(f.root, '102', 'ns', 'user'))
  assert.equal((await verifySandboxProcesses(f.processInfo, { procRoot: f.root })).ok, false)
  assert.equal((await verifySandboxProcesses([{ type: 'browser', id: 100 }], { procRoot: f.root })).ok, false)
})

test('self-test uses a throwaway production sandbox, loads data and closes it before cleanup', async t => {
  const f = await fixture(t), calls = []
  let profile
  const result = await browserSelfTest({ procRoot: f.root, platform: 'linux', launch: async (directory, options) => {
    profile = directory; assert.deepEqual(options, { runtimeKind: 'host' })
    return { context: {
      newPage: async () => ({ goto: async url => { assert.ok(url.startsWith('data:')); calls.push('load') } }),
      browser: () => ({ newBrowserCDPSession: async () => ({
        send: async method => { assert.equal(method, 'SystemInfo.getProcessInfo'); return { processInfo: f.processInfo } },
        detach: async () => calls.push('detach'),
      }) }),
      close: async () => calls.push('close'),
    } }
  } })
  assert.equal(result.ok, true); assert.deepEqual(calls, ['load', 'detach', 'close'])
  const { stat } = await import('node:fs/promises')
  await assert.rejects(stat(profile), { code: 'ENOENT' })
})

test('self-test classifies blocked namespaces and missing libraries without leaking launcher diagnostics', async () => {
  const blocked = await browserSelfTest({ platform: 'linux', launch: async () => { throw Error('No usable sandbox. sensitive command output') } })
  assert.equal(blocked.reason, 'sandbox_blocked'); assert.match(blocked.hint, /Prepare host.*AppArmor/)
  assert.ok(!JSON.stringify(blocked).includes('sensitive'))
  const missing = await browserSelfTest({ platform: 'linux', launch: async () => { throw Error('error while loading shared libraries: libnss3.so: cannot open shared object file') } })
  assert.equal(missing.reason, 'missing_libraries'); assert.deepEqual(missing.missingLibraries, ['libnss3.so'])
})

test('ldd parsing is bounded to missing libraries and de-duplicates loader errors', () => {
  assert.deepEqual(missingLibrariesFromLdd('linux-vdso.so.1 (0x0)\nlibnss3.so => not found\nlibX11.so.6 => /lib/libX11.so.6 (0x0)\nlibnss3.so => not found\nlibatk.so => not found\n'), ['libatk.so', 'libnss3.so'])
})

test('CLI runs through the installed current symlink and cannot silently report success', async t => {
  const root = await mkdtemp(join(tmpdir(), 'wovenmatter-selftest-entrypoint-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  await symlink(fileURLToPath(new URL('..', import.meta.url)), join(root, 'current'))
  const result = spawnSync(process.execPath, [join(root, 'current', 'src', 'browser-selftest.mjs'), '--json'], {
    encoding: 'utf8', timeout: 20000,
    env: { ...process.env, PLAYWRIGHT_BROWSERS_PATH: join(root, 'missing-browser-binaries') },
  })
  assert.equal(result.error, undefined)
  assert.equal(result.status, 1)
  const output = JSON.parse(result.stdout)
  assert.equal(output.ok, false)
  assert.ok(['sandbox_inactive', 'sandbox_blocked', 'missing_libraries'].includes(output.reason))
})
