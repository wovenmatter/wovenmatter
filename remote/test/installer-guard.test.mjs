import test from 'node:test'
import assert from 'node:assert/strict'
import { chmod, lstat, mkdir, mkdtemp, readFile, readlink, rm, symlink, utimes, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { withInstallerGuard } from '../src/installer-guard.mjs'

async function fixture(t) {
  const home = await mkdtemp(resolve(tmpdir(), 'woven-installer-guard-'))
  t.after(() => rm(home, { recursive: true, force: true }))
  return home
}

test('host installer guard restores changed rc bytes and mode even on installer failure', async t => {
  const home = await fixture(t), path = resolve(home, '.bashrc')
  await writeFile(path, 'original shell setup\n', { mode: 0o640 })
  await assert.rejects(withInstallerGuard(home, async () => {
    await writeFile(path, 'installer export PATH=bad\n'); await chmod(path, 0o777)
    await writeFile(resolve(home, '.zshenv'), 'new shell setup')
    throw new Error('installer failed')
  }), /installer_modified_shell_config/)
  assert.equal(await readFile(path, 'utf8'), 'original shell setup\n')
  assert.equal((await lstat(path)).mode & 0o777, 0o640)
  await assert.rejects(lstat(resolve(home, '.zshenv')), { code: 'ENOENT' })
})

test('guard restores a symlinked shell configuration and its original target', async t => {
  const home = await fixture(t), target = resolve(home, 'dotfile'), path = resolve(home, '.zshrc')
  await writeFile(target, 'original\n'); await symlink('dotfile', path)
  await assert.rejects(withInstallerGuard(home, () => writeFile(path, 'changed\n')), /installer_modified_shell_config/)
  assert.equal(await readlink(path), 'dotfile')
  assert.equal(await readFile(target, 'utf8'), 'original\n')
})

test('guard detects nested harness credential changes when the directory timestamp is unchanged', async t => {
  const home = await fixture(t), directory = resolve(home, '.codex'), path = resolve(directory, 'auth.json')
  await mkdir(directory); await writeFile(path, 'original secret')
  const original = await lstat(directory)
  await assert.rejects(withInstallerGuard(home, async () => {
    await writeFile(path, 'changed secret!')
    await utimes(directory, original.atime, original.mtime)
  }), /installer_modified_harness_config/)
  assert.equal(await readFile(path, 'utf8'), 'changed secret!', 'guard reports credential changes without copying or restoring credentials')
})

test('guard detects newly created harness configuration and permits unrelated managed installations', async t => {
  const home = await fixture(t)
  const result = await withInstallerGuard(home, async () => {
    await mkdir(resolve(home, '.local/bin'), { recursive: true }); await writeFile(resolve(home, '.local/bin/tool'), 'tool')
    return 'installed'
  })
  assert.equal(result, 'installed')
  await assert.rejects(withInstallerGuard(home, () => mkdir(resolve(home, '.claude'))), /installer_modified_harness_config/)
  await assert.rejects(withInstallerGuard(home, async () => { throw new Error('original failure') }), /original failure/)
})

test('guard audits credential files behind an existing harness directory symlink', async t => {
  const home = await fixture(t), target = resolve(home, 'existing-codex-config')
  await mkdir(target); await writeFile(resolve(target, 'auth.json'), 'original account')
  await symlink(target, resolve(home, '.codex'))
  await assert.rejects(withInstallerGuard(home, () => writeFile(resolve(target, 'auth.json'), 'changed account!')), /installer_modified_harness_config/)
})
