import { chmodSync, existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { chmod, mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { join, resolve } from 'node:path'

// Settings → GitHub on a Linux host (docs/architecture/GITHUB_IDENTITY.md). A Mac
// sends the key and identity with Pi Durable's configuration; this host writes the
// files git and ssh read, and every session, tool and bot on it uses them. Keep the
// file contents identical to the Mac's GitHubGitFiles and bots/src/host/git.ts.

// GitHub's published SSH host keys (https://api.github.com/meta, `ssh_keys`).
export const githubKnownHosts = `github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
`

export const githubDirectory = (configuration) => configuration?.stateDirectory ? resolve(configuration.stateDirectory, 'github') : null

const quoted = path => `"${path}"`
// ASCII control characters (line breaks included) are dropped: a value never starts a new section.
const gitQuoted = value => `"${String(value).replace(/[\u0000-\u001f\u007f]/g, '').replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`
const control = /[\u0000-\u001f\u007f]/

/** File name → contents, or null to remove it. */
export function githubFiles(value, directory) {
  // With a key, github.com gets it alone; every other host keeps the user's own settings.
  const files = {
    ssh_config: value?.sshKey ? `# Written by Woven Matter (Settings → GitHub).
Include ${quoted(join(directory, 'github.conf'))}
Match host "!github.com,*"
  Include ~/.ssh/config
  Include /etc/ssh/ssh_config
` : `# Written by Woven Matter (Settings → GitHub). No key is set: your own SSH settings apply.
Include ~/.ssh/config
Include /etc/ssh/ssh_config
`,
    known_hosts: githubKnownHosts,
    id_github: null, 'id_github.pub': null, 'github.conf': null, gitconfig: null,
  }
  if (value?.sshKey) {
    const key = value.sshKey.privateKey
    files.id_github = key.endsWith('\n') ? key : key + '\n'
    files['id_github.pub'] = value.sshKey.publicKey + '\n'
    files['github.conf'] = `Host github.com
  HostName github.com
  User git
  IdentityFile ${quoted(join(directory, 'id_github'))}
  IdentitiesOnly yes
  UserKnownHostsFile ${quoted(join(directory, 'known_hosts'))}
  StrictHostKeyChecking yes
`
  }
  const identity = value?.identity
  if (identity && (identity.name || identity.email)) {
    let text = '[user]\n'
    if (identity.name) text += `\tname = ${gitQuoted(identity.name)}\n`
    if (identity.email) text += `\temail = ${gitQuoted(identity.email)}\n`
    files.gitconfig = text
  }
  return files
}

/** The `github` member of a Pi Durable configuration, checked; throws `invalid_github`. */
export function validGitHubConfiguration(value) {
  const invalid = () => Object.assign(new Error('invalid_github'), { statusCode: 400 })
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw invalid()
  if (Object.keys(value).some(key => !['sshKey', 'identity', 'revision'].includes(key))) throw invalid()
  const revision = value.revision ?? 0
  if (!Number.isSafeInteger(revision) || revision < 0) throw invalid()
  const result = { sshKey: null, identity: null, revision }
  if (value.sshKey != null) {
    const { privateKey, publicKey } = value.sshKey
    if (typeof privateKey !== 'string' || privateKey.length > 16384 || !privateKey.startsWith('-----BEGIN ') || !privateKey.includes('PRIVATE KEY-----')) throw invalid()
    if (typeof publicKey !== 'string' || publicKey.length > 16384 || !/^[a-z0-9@.-]+ [A-Za-z0-9+/=]+( [^\r\n]*)?$/.test(publicKey)) throw invalid()
    result.sshKey = { privateKey, publicKey }
  }
  if (value.identity != null) {
    const { name = '', email = '' } = value.identity
    if (typeof name !== 'string' || typeof email !== 'string' || name.length > 200 || email.length > 254 || control.test(name) || control.test(email)) throw invalid()
    if (name || email) result.identity = { name, email }
  }
  return result
}

let writing = Promise.resolve()

/**
 * Applies a Mac's setting unless this host already has a newer one (Macs that have
 * not caught up yet send older revisions). Returns whether it was applied.
 */
export function applyGitHubConfiguration(value, directory) {
  const run = writing.then(async () => {
    const current = Number.parseInt(await readFile(join(directory, '.revision'), 'utf8').catch(() => '0'), 10) || 0
    if ((value.revision ?? 0) < current) return false
    await writeGitHubFiles(value, directory)
    await writeFile(join(directory, '.revision'), String(value.revision ?? 0), { mode: 0o600 })
    return true
  })
  writing = run.catch(() => {})
  return run
}

/** Writes the files (private, atomically) and removes what no longer applies. */
export async function writeGitHubFiles(value, directory) {
  await mkdir(directory, { recursive: true, mode: 0o700 })
  await chmod(directory, 0o700)
  for (const [name, text] of Object.entries(githubFiles(value, directory))) {
    const path = join(directory, name)
    if (text === null) { await rm(path, { force: true }); continue }
    if (await readFile(path, 'utf8').catch(() => null) === text) continue
    const temporary = join(directory, `.${name}.${randomUUID()}`)
    await writeFile(temporary, text, { mode: 0o600 })
    await rename(temporary, path)
  }
  await writeFile(join(directory, '.identity.json'), JSON.stringify(value?.identity ?? null), { mode: 0o600 })
}

/** What a bots runtime on this host receives (`POST /v1/bots-host/git`). */
export async function readGitHubConfiguration(directory) {
  if (!directory) return { sshKey: null, identity: null }
  const read = name => readFile(join(directory, name), 'utf8').catch(() => null)
  const [privateKey, publicKey, identity] = await Promise.all([read('id_github'), read('id_github.pub'), read('.identity.json')])
  let parsed = null
  try { parsed = identity ? JSON.parse(identity) : null } catch {}
  return {
    sshKey: privateKey && publicKey ? { privateKey, publicKey: publicKey.trim() } : null,
    identity: parsed && typeof parsed === 'object' ? { name: String(parsed.name ?? ''), email: String(parsed.email ?? '') } : null,
  }
}

/** The static files, written once so every session environment can point at them. */
export function ensureGitHubStaticFiles(directory) {
  if (!directory) return false
  try {
    const files = githubFiles(null, directory)
    mkdirSync(directory, { recursive: true, mode: 0o700 })
    for (const name of ['ssh_config', 'known_hosts']) {
      const path = join(directory, name)
      if (!existsSync(path)) { writeFileSync(path, files[name], { mode: 0o600 }); chmodSync(path, 0o600) }
    }
    return true
  } catch { return false }
}

const shellQuote = value => `'${String(value).replaceAll("'", "'\\''")}'`

/**
 * Points git at the files. The ssh command is set only while a key is saved (it outranks a
 * repository's own core.sshCommand), never over a GIT_SSH_COMMAND or GIT_SSH already set.
 */
export function githubEnvironment(environment, directory) {
  if (!directory) return {}
  const result = {}
  if (!environment.GIT_SSH_COMMAND && !environment.GIT_SSH && existsSync(join(directory, 'github.conf'))) result.GIT_SSH_COMMAND = `ssh -F ${shellQuote(join(directory, 'ssh_config'))}`
  const include = join(directory, 'gitconfig')
  const count = Number.parseInt(environment.GIT_CONFIG_COUNT ?? '', 10) || 0
  for (let index = 0; index < count; index++) {
    if (environment[`GIT_CONFIG_KEY_${index}`] === 'include.path' && environment[`GIT_CONFIG_VALUE_${index}`] === include) return result
  }
  result[`GIT_CONFIG_KEY_${count}`] = 'include.path'
  result[`GIT_CONFIG_VALUE_${count}`] = include
  result.GIT_CONFIG_COUNT = String(count + 1)
  return result
}
