import { chmodSync, existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { chmod, mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { join, resolve } from 'node:path'
import { agentReply, parseOpenSSHPrivateKey, startAgentServer } from './ssh-agent.mjs'

// Settings → GitHub on a Linux host (docs/architecture/GITHUB_IDENTITY.md). The host's library
// keeps its own sealed copy of the key, synced from any device; this server opens it through
// the library's local socket, signs for the host's sessions and bots while each is on (the
// signing agent, ssh-agent.mjs), and writes the files git and ssh read: only the public key,
// never the private one. Keep the file contents identical to the Mac's GitHubGitFiles and
// bots/src/host/git.ts.

// GitHub's published SSH host keys (https://api.github.com/meta, `ssh_keys`).
export const githubKnownHosts = `github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
`

export const githubDirectory = (configuration) => configuration?.stateDirectory ? resolve(configuration.stateDirectory, 'github') : null
export const githubAgentSocket = directory => join(directory, 'agent.sock')

const quoted = path => `"${path}"`
// ASCII control characters (line breaks included) are dropped: a value never starts a new section.
const gitQuoted = value => `"${String(value).replace(/[\u0000-\u001f\u007f]/g, '').replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`

/**
 * File name → contents, or null to remove it. `value.publicKey` is set while this place uses
 * the key: github.com then asks the agent at `agentSocket`, and only the public key is on disk.
 */
export function githubFiles(value, directory, agentSocket = githubAgentSocket(directory)) {
  // With a key, github.com gets it alone; every other host keeps the user's own settings.
  const files = {
    ssh_config: value?.publicKey ? `# Written by Woven Matter (Settings → GitHub).
Include ${quoted(join(directory, 'github.conf'))}
Match host "!github.com,*"
  Include ~/.ssh/config
  Include /etc/ssh/ssh_config
` : `# Written by Woven Matter (Settings → GitHub). No key is set: your own SSH settings apply.
Include ~/.ssh/config
Include /etc/ssh/ssh_config
`,
    known_hosts: githubKnownHosts,
    // The files that depend on what is set; one that no longer applies is removed.
    'id_github.pub': null, 'github.conf': null, gitconfig: null,
  }
  if (value?.publicKey) {
    files['id_github.pub'] = value.publicKey + '\n'
    files['github.conf'] = `Host github.com
  HostName github.com
  User git
  IdentityAgent ${quoted(agentSocket)}
  IdentityFile ${quoted(join(directory, 'id_github.pub'))}
  IdentitiesOnly yes
  UserKnownHostsFile ${quoted(join(directory, 'known_hosts'))}
  StrictHostKeyChecking yes
`
  }
  const identity = value?.identity
  let text = ''
  if (identity && (identity.name || identity.email)) {
    text += '[user]\n'
    if (identity.name) text += `\tname = ${gitQuoted(identity.name)}\n`
    if (identity.email) text += `\temail = ${gitQuoted(identity.email)}\n`
  }
  // With a key, HTTPS remotes on GitHub use it too.
  if (value?.publicKey) text += '[url "git@github.com:"]\n\tinsteadOf = https://github.com/\n'
  if (text) files.gitconfig = text
  return files
}

/** Whether `access` lets the place (a machine's device ID or a bot's ID) use the key; no list lets every place. */
export const githubAllows = (access, id) => access?.places?.[String(id).toLowerCase()] ?? access?.newPlaces ?? true

/** Writes the files (private, atomically) and removes what no longer applies. */
export async function writeGitHubFiles(value, directory, agentSocket = githubAgentSocket(directory)) {
  await mkdir(directory, { recursive: true, mode: 0o700 })
  await chmod(directory, 0o700)
  for (const [name, text] of Object.entries(githubFiles(value, directory, agentSocket))) {
    const path = join(directory, name)
    if (text === null) { await rm(path, { force: true }); continue }
    if (await readFile(path, 'utf8').catch(() => null) === text) continue
    const temporary = join(directory, `.${name}.${randomUUID()}`)
    await writeFile(temporary, text, { mode: 0o600 })
    await rename(temporary, path)
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

const identityOf = value => value && (value.name || value.email) ? { name: String(value.name ?? ''), email: String(value.email ?? '') } : null

/**
 * This host's Settings → GitHub: its copy from the library (`GET /github` on the library's
 * local socket, `{deviceID, sshKey, identity, access, revision}`), asked again every
 * `intervalMs`. The key stays in this process; sessions and bots reach it only through the
 * agent, which checks the host (and the bot) is on at every request. A library that is
 * briefly unavailable leaves the last copy in place.
 */
export function createGitHubService({ directory, fetchCopy, intervalMs = 5_000, log = () => {} }) {
  let copy = null, key = null, keyText = null, server = null, timer = null
  const hostOn = () => !!key && githubAllows(copy?.access, copy?.deviceID)
  const botOn = botID => hostOn() && githubAllows(copy?.access, botID)
  const socket = githubAgentSocket(directory)

  async function refresh() {
    let next
    try { next = await fetchCopy() } catch { return false }
    if (!next || typeof next.deviceID !== 'string') return false
    const text = typeof next.sshKey?.privateKey === 'string' ? next.sshKey.privateKey : null
    if (text !== keyText) {
      try { key = text ? parseOpenSSHPrivateKey(text) : null } catch (error) { key = null; log('The GitHub key could not be read: ' + error.message) }
      keyText = text
    }
    copy = next
    await writeGitHubFiles({ publicKey: hostOn() ? String(next.sshKey.publicKey).trim() : null, identity: identityOf(next.identity) }, directory, socket)
    return true
  }

  return {
    socket,
    async start() {
      ensureGitHubStaticFiles(directory)
      server ??= await startAgentServer(socket, message => agentReply(message, hostOn() ? key : null))
      await refresh()
      timer ??= setInterval(() => { refresh().catch(() => {}) }, intervalMs)
      timer.unref?.()
    },
    refresh,
    stop() { clearInterval(timer); timer = null; server?.close(); server = null },
    /** What a bot's container receives (`POST /bots-host/git`). */
    botSetup(botID) {
      return { publicKey: botOn(botID) ? String(copy.sshKey.publicKey).trim() : null, identity: identityOf(copy?.identity) }
    },
    /** One agent request from a bot's container (`POST /bots-host/ssh-agent`). */
    botAgent(botID, message) { return agentReply(message, botOn(botID) ? key : null) },
  }
}

const shellQuote = value => `'${String(value).replaceAll("'", "'\\''")}'`

/**
 * Points git at the files, key or not, so a process started before a key was saved (Pi
 * Durable's worker, a long build) uses it as soon as it is. Without a key, ssh_config holds
 * only the user's own settings. Never over a GIT_SSH_COMMAND or GIT_SSH already set.
 */
export function githubEnvironment(environment, directory) {
  if (!directory) return {}
  const result = {}
  if (!environment.GIT_SSH_COMMAND && !environment.GIT_SSH && existsSync(join(directory, 'ssh_config'))) result.GIT_SSH_COMMAND = `ssh -F ${shellQuote(join(directory, 'ssh_config'))}`
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
