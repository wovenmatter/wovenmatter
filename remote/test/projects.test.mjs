import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdir, mkdtemp, readdir, writeFile, readFile, rm, realpath, symlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createProject, deleteProject, ensureScratchDirectory, scratchFolderName, linkHostProject, listHostDirectories } from '../src/projects.mjs'


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
