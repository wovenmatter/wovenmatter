import test from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, statSync, existsSync, readdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { loadRuntimeConfiguration, nonInteractiveSessionEnvironment } from '../src/config.mjs'
import { applyGitHubConfiguration, ensureGitHubStaticFiles, githubDirectory, githubEnvironment, readGitHubConfiguration, validGitHubConfiguration, writeGitHubFiles } from '../src/github-identity.mjs'

// Settings → GitHub on a Linux host. Nothing here connects to GitHub.
function scratch(t) {
  const directory = mkdtempSync(join(tmpdir(), 'woven-github-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  return directory
}

function generatedKey(t) {
  const directory = scratch(t)
  const result = spawnSync('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-C', 'woven-matter', '-f', join(directory, 'key')], { encoding: 'utf8' })
  if (result.status !== 0) return null
  return { privateKey: readFileSync(join(directory, 'key'), 'utf8'), publicKey: readFileSync(join(directory, 'key.pub'), 'utf8').trim() }
}

test('configurations from a Mac are checked before anything is written', () => {
  // Split so the public-tree secret scan matches only real keys.
  const sshKey = { privateKey: '-----BEGIN OPENSSH ' + 'PRIVATE KEY-----\nx\n-----END OPENSSH ' + 'PRIVATE KEY-----\n', publicKey: 'ssh-ed25519 AAAA woven-matter' }
  assert.deepEqual(validGitHubConfiguration({ sshKey: null, identity: null }), { sshKey: null, identity: null, revision: 0 })
  assert.deepEqual(validGitHubConfiguration({ sshKey, identity: { name: 'Ada', email: '' }, revision: 5 }), { sshKey, identity: { name: 'Ada', email: '' }, revision: 5 })
  for (const value of [null, [], { other: 1 }, { sshKey: { privateKey: 'nope', publicKey: sshKey.publicKey } },
    { sshKey: { ...sshKey, publicKey: 'ssh-ed25519 AAAA\nInclude /etc/passwd' } }, { identity: { name: 'Ada\n[core]', email: '' } }, { revision: -1 }, { revision: 1.5 }]) {
    assert.throws(() => validGitHubConfiguration(value), /invalid_github/)
  }
})

test('the files are private, follow the setting, and point ssh and git at the key', async t => {
  const key = generatedKey(t)
  if (!key) return t.skip('ssh-keygen is not installed')
  const directory = join(scratch(t), 'github files')
  await writeGitHubFiles({ sshKey: key, identity: { name: 'Ada "The" Lovelace', email: 'ada@example.com' } }, directory)
  for (const name of ['id_github', 'github.conf', 'gitconfig', 'ssh_config', 'known_hosts']) assert.equal(statSync(join(directory, name)).mode & 0o777, 0o600, name)
  assert.equal(statSync(directory).mode & 0o777, 0o700)
  assert.deepEqual(await readGitHubConfiguration(directory), { sshKey: key, identity: { name: 'Ada "The" Lovelace', email: 'ada@example.com' } })

  const environment = { PATH: process.env.PATH, ...githubEnvironment({}, directory) }
  assert.equal(environment.GIT_SSH_COMMAND, `ssh -F '${join(directory, 'ssh_config')}'`)
  const ssh = host => spawnSync('ssh', ['-G', '-F', join(directory, 'ssh_config'), host], { encoding: 'utf8' })
  const resolved = ssh('github.com')
  if (resolved.status === 0) {
    assert.match(resolved.stdout, new RegExp(`identityfile ${join(directory, 'id_github').replaceAll('/', '\\/')}`))
    assert.doesNotMatch(ssh('example.com').stdout, /id_github/)
  }
  const git = args => spawnSync('git', args, { encoding: 'utf8', env: { ...environment, HOME: directory, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' } })
  if (git(['--version']).status === 0) assert.equal(git(['config', 'user.name']).stdout, 'Ada "The" Lovelace\n')

  // A removal from the Mac removes the key and identity, and nothing is left behind.
  await writeGitHubFiles({ sshKey: null, identity: null }, directory)
  assert.equal(existsSync(join(directory, 'id_github')), false)
  assert.equal(existsSync(join(directory, 'gitconfig')), false)
  assert.deepEqual(await readGitHubConfiguration(directory), { sshKey: null, identity: null })
  assert.deepEqual(readdirSync(directory).filter(name => name.includes('.tmp') || /^\.[a-z_.]+\.[0-9a-f-]{36}$/.test(name)), [])
})

test('a Mac with an older copy never replaces a newer one on the host', async t => {
  const directory = join(scratch(t), 'github')
  const key = { privateKey: '-----BEGIN OPENSSH ' + 'PRIVATE KEY-----\nnew\n', publicKey: 'ssh-ed25519 AAAA new' }
  assert.equal(await applyGitHubConfiguration({ sshKey: key, identity: null, revision: 20 }, directory), true)
  assert.equal(await applyGitHubConfiguration({ sshKey: null, identity: null, revision: 10 }, directory), false)
  assert.equal((await readGitHubConfiguration(directory)).sshKey?.publicKey, 'ssh-ed25519 AAAA new')
  // Concurrent configurations apply in order; the newest wins.
  await Promise.all([30, 25].map(revision => applyGitHubConfiguration({ sshKey: null, identity: { name: String(revision), email: '' }, revision }, directory)))
  assert.deepEqual(await readGitHubConfiguration(directory), { sshKey: null, identity: { name: '30', email: '' } })
})

test('session environments use the key only while one is saved', async t => {
  const home = scratch(t)
  const configuration = loadRuntimeConfiguration({ HOME: home, PATH: '/usr/bin:/bin' })
  const directory = githubDirectory(configuration)
  assert.equal(directory, join(home, '.wovenmatter/github'))
  assert.equal(nonInteractiveSessionEnvironment({ PATH: '/usr/bin' }, configuration).GIT_SSH_COMMAND, undefined)
  assert.equal(ensureGitHubStaticFiles(directory), true)
  // Without a key the user's own ssh setup (core.sshCommand, GIT_SSH) stays in charge.
  assert.equal(nonInteractiveSessionEnvironment({ PATH: '/usr/bin' }, configuration).GIT_SSH_COMMAND, undefined)
  await writeGitHubFiles({ sshKey: { privateKey: '-----BEGIN OPENSSH ' + 'PRIVATE KEY-----\nx\n', publicKey: 'ssh-ed25519 AAAA' }, identity: null }, directory)
  assert.equal(nonInteractiveSessionEnvironment({ GIT_SSH: '/usr/bin/my-ssh' }, configuration).GIT_SSH_COMMAND, undefined)
  const environment = nonInteractiveSessionEnvironment({ PATH: '/usr/bin', GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: 'core.editor', GIT_CONFIG_VALUE_0: 'vi' }, configuration)
  assert.equal(environment.GIT_SSH_COMMAND, `ssh -F '${join(directory, 'ssh_config')}'`)
  assert.equal(environment.GIT_CONFIG_COUNT, '2')
  assert.equal(environment.GIT_CONFIG_KEY_1, 'include.path')
  assert.equal(environment.GIT_CONFIG_VALUE_1, join(directory, 'gitconfig'))
  assert.equal(nonInteractiveSessionEnvironment({ GIT_SSH_COMMAND: 'ssh -i mine' }, configuration).GIT_SSH_COMMAND, 'ssh -i mine')
})

test('wm-exec gives SSH launches the same environment', t => {
  const source = readFileSync(new URL('../host/bin/wm-exec', import.meta.url), 'utf8')
  assert.match(source, /github=Path\(settings\['WOVENMATTER_STATE_DIRECTORY'\]\)\/'github'/)
  assert.match(source, /"ssh -F '"\+str\(github\/'ssh_config'\)/)
  assert.match(source, /include\.path/)
})
