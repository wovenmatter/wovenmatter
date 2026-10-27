import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdir, mkdtemp, readdir, writeFile, readFile, rm, realpath, symlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createProject, deleteProject, ensureScratchDirectory, scratchFolderName, linkHostProject, listHostDirectories } from '../src/projects.mjs'

test('host directory discovery canonicalizes linked external projects and bounds listing results', async t => {
  const root = await mkdtemp(join(tmpdir(), 'woven-directory-browser-'))
  const external = await mkdtemp(join(tmpdir(), 'woven-existing-repository-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  t.after(() => rm(external, { recursive: true, force: true }))
  await mkdir(join(root, 'beta')); await mkdir(join(root, 'alpha'))
  await writeFile(join(root, 'file.txt'), 'not a directory')
  await symlink(external, join(root, 'linked'))
  await symlink(join(root, 'missing'), join(root, 'stale'))
  const canonical = await realpath(root)
  const result = await listHostDirectories(root)
  assert.equal(result.path, canonical)
  assert.deepEqual(result.directories.map(item => item.name), ['alpha', 'beta', 'linked'])
  assert.equal(result.directories.find(item => item.name === 'linked').path, await realpath(external))
  assert.equal(result.truncated, false)
  assert.deepEqual(await linkHostProject(join(root, 'linked')), { path: await realpath(external) })
  assert.equal((await listHostDirectories(root, { limit: 2 })).truncated, true)
  assert.equal((await listHostDirectories(root, { limit: 1, scanLimit: 1 })).truncated, true)
  for (const path of ['relative/path', '\0', join(root, 'file.txt'), join(root, 'missing')]) await assert.rejects(linkHostProject(path), { statusCode: 400 })
  assert.equal(await readFile(join(root, 'file.txt'), 'utf8'), 'not a directory')
})

test('physical deletion only removes a managed direct project root', async t => {
  const root = await mkdtemp(join(tmpdir(), 'managed-project-delete-'))
  const external = await mkdtemp(join(tmpdir(), 'external-project-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  t.after(() => rm(external, { recursive: true, force: true }))
  const canonical = await realpath(root)
  await writeFile(join(external, 'user-file'), 'keep')
  await symlink(external, join(canonical, 'Linked project'))
  for (const path of [canonical, canonical + '/.', canonical + '/..', external, join(canonical, 'Linked project')]) {
    await assert.rejects(deleteProject(root, path))
  }
  assert.equal(await readFile(join(external, 'user-file'), 'utf8'), 'keep')
  const project = await createProject(root, 'Delete test project')
  await writeFile(join(project.path, 'test-file'), 'temporary test data')
  assert.deepEqual(await deleteProject(root, project.path), project)
  assert.deepEqual(await readdir(root), ['Linked project'])
})

test('chat scratch creation is empty, concurrent and retry-safe, and cannot escape its workspace', async t => {
  const root = await mkdtemp(join(tmpdir(), 'remote-scratch-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const name = scratchFolderName('11111111-1111-4111-8111-111112345678', '../../Convert these PNGs to WebP!', '2026-09-25T10:00:00Z')
  assert.equal(name, '2026-09-25-convert-these-pngs-to-webp-12345678')
  const path = join(root, 'scratch', name)
  await Promise.all([ensureScratchDirectory(root, path), ensureScratchDirectory(root, path)])
  assert.deepEqual(await readdir(path), [])
  await writeFile(join(path, 'report.txt'), 'Keep this file')
  await ensureScratchDirectory(root, path)
  assert.equal(await readFile(join(path, 'report.txt'), 'utf8'), 'Keep this file')
  await assert.rejects(createProject(root, 'scratch'))
  await assert.rejects(deleteProject(root, join(root, 'scratch')))
  const linked = join(root, 'scratch', 'linked')
  await symlink(root, linked)
  for (const invalid of [root, join(root, 'outside'), join(root, 'scratch', '..'), join(path, 'nested'), linked]) {
    await assert.rejects(ensureScratchDirectory(root, invalid))
  }
  assert.equal(await readFile(join(path, 'report.txt'), 'utf8'), 'Keep this file')
})
