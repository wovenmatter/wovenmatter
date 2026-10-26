import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { chmod, lstat, mkdir, readFile, readdir, readlink, realpath, rm, symlink, utimes, writeFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'

export const guardedShellFiles = ['.bashrc', '.bash_profile', '.bash_login', '.profile', '.zshrc', '.zprofile', '.zshenv', '.config/fish/config.fish']
export const guardedHarnessPaths = ['.codex', '.claude', '.claude.json', '.config/opencode', '.grok']
const failure = message => Object.assign(new Error(message), { statusCode: 409 })

async function snapshotFile(path) {
  let info
  try { info = await lstat(path) } catch (error) { if (error.code === 'ENOENT') return null; throw error }
  if (info.isSymbolicLink()) {
    const link = await readlink(path)
    let target = null, contents = null
    try { target = await realpath(path); contents = await snapshotFile(target) } catch (error) { if (error.code !== 'ENOENT') throw error }
    return { link, target, contents }
  }
  if (!info.isFile()) throw failure('installer_shell_config_not_regular_file')
  return { bytes: await readFile(path), mode: info.mode & 0o777, atime: info.atime, mtime: info.mtime }
}
function equalFile(a, b) {
  if (!a || !b) return a === b
  if (a.link !== undefined || b.link !== undefined) return a.link === b.link && a.target === b.target && equalFile(a.contents, b.contents)
  return a.mode === b.mode && a.bytes.equals(b.bytes)
}
async function restoreFile(path, snapshot) {
  if (!snapshot) { await rm(path, { force: true, recursive: true }); return }
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  if (snapshot.link !== undefined) {
    await rm(path, { force: true, recursive: true }); await symlink(snapshot.link, path)
    if (snapshot.target && snapshot.contents) await restoreFile(snapshot.target, snapshot.contents)
  } else {
    await rm(path, { force: true, recursive: true })
    await writeFile(path, snapshot.bytes, { mode: snapshot.mode })
    await chmod(path, snapshot.mode); await utimes(path, snapshot.atime, snapshot.mtime)
  }
}

// Hash in memory: credential bytes never enter logs, temporary files or errors.
async function fingerprint(path) {
  const hash = createHash('sha256')
  async function visit(current, depth = 0) {
    if (depth > 64) throw failure('installer_config_audit_depth_exceeded')
    let info
    try { info = await lstat(current) } catch (error) { if (error.code === 'ENOENT') { hash.update('missing'); return }; throw error }
    hash.update(JSON.stringify([current, info.mode, info.size, info.mtimeMs, info.ctimeMs]))
    if (info.isSymbolicLink()) {
      hash.update(await readlink(current))
      let target
      try { target = await realpath(current) } catch (error) { if (error.code !== 'ENOENT') throw error }
      if (target) {
        hash.update(target)
        // Follow a config-directory alias at the root, and aliased config files.
        // Nested directory aliases are not recursively expanded into unrelated
        // repository trees or the whole filesystem.
        if (depth === 0 || (await lstat(target)).isFile()) await visit(target, depth + 1)
      }
    }
    else if (info.isDirectory()) for (const entry of (await readdir(current)).sort()) await visit(resolve(current, entry), depth + 1)
    else if (info.isFile()) for await (const bytes of createReadStream(current)) hash.update(bytes)
  }
  await visit(path)
  return hash.digest('hex')
}

export async function withInstallerGuard(home, operation) {
  const shell = await Promise.all(guardedShellFiles.map(async name => [resolve(home, name), await snapshotFile(resolve(home, name))]))
  const harness = await Promise.all(guardedHarnessPaths.map(async name => [resolve(home, name), await fingerprint(resolve(home, name))]))
  let result, operationError
  try { result = await operation() } catch (error) { operationError = error }
  let shellChanged = false, restoreFailed = false
  for (const [path, before] of shell) {
    let after
    try { after = await snapshotFile(path) } catch { after = undefined }
    if (!equalFile(before, after)) {
      shellChanged = true
      try { await restoreFile(path, before) } catch { restoreFailed = true }
    }
  }
  const harnessChanged = (await Promise.all(harness.map(async ([path, before]) => before !== await fingerprint(path)))).some(Boolean)
  if (restoreFailed) throw failure('installer_shell_config_restore_failed')
  if (shellChanged) throw failure('installer_modified_shell_config')
  if (harnessChanged) throw failure('installer_modified_harness_config')
  if (operationError) throw operationError
  return result
}
