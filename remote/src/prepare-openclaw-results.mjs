import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { cpSync, mkdirSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { createHash } from 'node:crypto'

// Use OpenClaw's config writer so JSON5, validation and its write lock remain
// native-owned. This runs before starting an owned Gateway, never during a turn.
export async function prepareOpenClawResults({ executable = 'openclaw', environment = process.env,
  source = resolve(import.meta.dirname, 'openclaw-results'), execute = promisify(execFile) } = {}) {
  const id = 'wovenmatter-scheduled-results'
  const destination = resolve(environment.HOME, '.wovenmatter', id)
  const call = async args => (await execute(executable, args, { env: environment, encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024 })).stdout
  let plugins
  try { plugins = JSON.parse(await call(['config', 'get', 'plugins', '--json'])) }
  catch (error) {
    if (!String(error.stdout).includes('Config path is valid but unset: plugins.')) throw error
    plugins = {}
  }
  if (plugins.enabled === false || plugins.deny?.includes(id) || plugins.entries?.[id]?.enabled === false) {
    throw new Error('Scheduled result plugin is disabled by OpenClaw configuration.')
  }
  if (plugins.entries?.[id]?.hooks?.allowConversationAccess === false) {
    throw new Error('Scheduled result conversation access is disabled by OpenClaw configuration.')
  }
  mkdirSync(destination, { recursive: true, mode: 0o700 })
  // The installed path survives app moves and container image replacement.
  cpSync(source, destination, { recursive: true })
  const profile = environment.OPENCLAW_CONFIG_PATH ?? environment.OPENCLAW_STATE_DIR ?? environment.OPENCLAW_PROFILE ?? 'default'
  const scope = createHash('sha256').update(profile).digest('hex')
  const directory = resolve(environment.HOME, '.wovenmatter', 'scheduled-results', 'openclaw', scope)
  const paths = [...new Set([...(plugins.load?.paths ?? []), destination])]
  const entry = { enabled: true, hooks: { allowConversationAccess: true }, config: { directory } }
  // One native patch preserves unrelated (possibly redacted) plugin settings.
  if (JSON.stringify(paths) !== JSON.stringify(plugins.load?.paths)
      || plugins.entries?.[id]?.enabled !== true
      || plugins.entries?.[id]?.hooks?.allowConversationAccess !== true
      || plugins.entries?.[id]?.config?.directory !== directory
      || (plugins.allow && !plugins.allow.includes(id))) {
    const patch = { plugins: { load: { paths }, entries: { [id]: entry },
      ...(plugins.allow ? { allow: [...new Set([...plugins.allow, id])] } : {}) } }
    const temporary = mkdtempSync(resolve(tmpdir(), 'wovenmatter-openclaw-'))
    try {
      const file = resolve(temporary, 'patch.json')
      writeFileSync(file, JSON.stringify(patch), { mode: 0o600 })
      await call(['config', 'patch', '--file', file])
    } finally { rmSync(temporary, { recursive: true, force: true }) }
  }
  return directory
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(import.meta.filename)) {
  try { await prepareOpenClawResults({ executable: process.argv[2] ?? 'openclaw', source: process.argv[3] }) }
  catch { process.stderr.write('Could not enable durable OpenClaw results. Check the selected profile and its plugin configuration.\n'); process.exitCode = 1 }
}
