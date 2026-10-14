import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readdir, writeFile, readFile, rm, realpath, symlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createProject, deleteProject, ensureScratchDirectory, scratchFolderName } from '../src/projects.mjs'

test('project creation is blank and never modifies an existing root', async t => {
  const root = await mkdtemp(join(tmpdir(), 'blank-remote-projects-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const project = await createProject(root, 'First project')
  assert.deepEqual(await readdir(project.path), [])
  await writeFile(join(project.path, 'AGENTS.md'), 'Personal instructions\n')
  await assert.rejects(createProject(root, 'First project'))
  assert.equal(await readFile(join(project.path, 'AGENTS.md'), 'utf8'), 'Personal instructions\n')
  for (const name of ['', '../escape', '.hidden', 'a/b', 'a\\b', 'a:b', 'bad\0name', 'a'.repeat(256)]) {
    await assert.rejects(createProject(root, name))
  }
  assert.deepEqual(await readdir(root), ['First project'])
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
