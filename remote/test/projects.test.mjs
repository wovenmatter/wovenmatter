import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readdir, writeFile, readFile, rm, realpath, symlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createProject, deleteProject } from '../src/projects.mjs'

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
