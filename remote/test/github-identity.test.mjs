import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { loadRuntimeConfiguration, nonInteractiveSessionEnvironment } from '../src/config.mjs'
import { createGitHubService, ensureGitHubStaticFiles, githubAllows, githubDirectory, githubEnvironment, githubFiles, writeGitHubFiles } from '../src/github-identity.mjs'

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

// The agent runs in this process, so the tools run asynchronously.
function run(command, args, { env = process.env, input } = {}) {
  return new Promise(resolve => {
    const child = spawn(command, args, { env })
    let stdout = '', stderr = ''
    child.stdout.on('data', chunk => { stdout += chunk })
    child.stderr.on('data', chunk => { stderr += chunk })
    child.on('close', status => resolve({ status, stdout, stderr }))
    child.stdin.end(input ?? '')
  })
}

const HOST = 'b0b0b0b0-0000-4000-8000-0000000000aa'
const BOT = 'b0b0b0b0-0000-4000-8000-000000000001', OTHER_BOT = 'b0b0b0b0-0000-4000-8000-000000000002'

test('only the public key is ever on disk, and ssh and git point at the agent for github.com alone', async t => {
  const directory = join(scratch(t), 'github files')
  const publicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixture woven-matter'
  await writeGitHubFiles({ publicKey, identity: { name: 'Ada "The" Lovelace', email: 'ada@example.com' } }, directory)
  for (const name of ['id_github.pub', 'github.conf', 'gitconfig', 'ssh_config', 'known_hosts']) assert.equal(statSync(join(directory, name)).mode & 0o777, 0o600, name)
  assert.equal(statSync(directory).mode & 0o777, 0o700)
  assert.equal(existsSync(join(directory, 'id_github')), false)
  assert.match(readFileSync(join(directory, 'github.conf'), 'utf8'), new RegExp(`IdentityAgent "${join(directory, 'agent.sock').replaceAll('/', '\\/')}"`))

  const ssh = host => spawnSync('ssh', ['-G', '-F', join(directory, 'ssh_config'), host], { encoding: 'utf8' })
  const resolved = ssh('github.com')
  if (resolved.status === 0) {
    assert.match(resolved.stdout, /identityagent .*agent\.sock/)
    assert.doesNotMatch(ssh('example.com').stdout, /agent\.sock|id_github/)
  }
  const environment = { PATH: process.env.PATH, ...githubEnvironment({}, directory) }
  const git = args => spawnSync('git', args, { encoding: 'utf8', env: { ...environment, HOME: directory, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' } })
  if (git(['--version']).status === 0) {
    assert.equal(git(['config', 'user.name']).stdout, 'Ada "The" Lovelace\n')
    // HTTPS remotes on GitHub use the key too; other hosts are left alone.
    assert.equal(git(['ls-remote', '--get-url', 'https://github.com/o/r.git']).stdout, 'git@github.com:o/r.git\n')
    assert.equal(git(['ls-remote', '--get-url', 'https://example.com/o/r.git']).stdout, 'https://example.com/o/r.git\n')
  }

  // A key file an earlier build wrote is removed; turned off, only the identity stays.
  writeFileSync(join(directory, 'id_github'), 'old')
  await writeGitHubFiles({ publicKey: null, identity: { name: 'Ada', email: '' } }, directory)
  for (const name of ['id_github', 'id_github.pub', 'github.conf']) assert.equal(existsSync(join(directory, name)), false, name)
  assert.equal(readFileSync(join(directory, 'gitconfig'), 'utf8'), '[user]\n\tname = "Ada"\n')
  assert.deepEqual(readdirSync(directory).filter(name => /^\.[a-z_.]+\.[0-9a-f-]{36}$/.test(name)), [])
})

test('the host signs for its sessions and bots only while each is on, and stops at once', async t => {
  const key = generatedKey(t)
  if (!key) return t.skip('ssh-keygen is not installed')
  const directory = join(scratch(t), 'github')
  let copy = { deviceID: HOST, sshKey: key, identity: { name: 'Ada', email: '' }, access: { newPlaces: true, places: {} }, revision: 5 }
  const service = createGitHubService({ directory, fetchCopy: async () => copy, intervalMs: 60_000 })
  await service.start()
  t.after(() => service.stop())
  assert.equal(statSync(service.socket).mode & 0o777, 0o600)
  assert.equal(readFileSync(join(directory, 'id_github.pub'), 'utf8').trim(), key.publicKey)
  assert.equal(existsSync(join(directory, 'id_github')), false)

  const env = { ...process.env, SSH_AUTH_SOCK: service.socket }
  assert.equal((await run('ssh-add', ['-L'], { env })).stdout.trim(), key.publicKey)
  writeFileSync(join(directory, 'message'), 'hello')
  const sign = () => { rmSync(join(directory, 'message.sig'), { force: true }); return run('ssh-keygen', ['-Y', 'sign', '-f', join(directory, 'id_github.pub'), '-n', 'git', join(directory, 'message')], { env }) }
  assert.equal((await sign()).status, 0)

  // Bots: the public key and signatures while the bot is on; nothing for one turned off.
  copy = { ...copy, access: { newPlaces: true, places: { [OTHER_BOT]: false } }, revision: 6 }
  await service.refresh()
  assert.equal(service.botSetup(BOT).publicKey, key.publicKey)
  assert.equal(service.botSetup(OTHER_BOT).publicKey, null)
  assert.deepEqual(service.botSetup(OTHER_BOT).identity, { name: 'Ada', email: '' })
  assert.equal(service.botAgent(BOT, Buffer.from([11]))[0], 12)
  assert.deepEqual(service.botAgent(OTHER_BOT, Buffer.from([11])), Buffer.from([12, 0, 0, 0, 0]))

  // The host turned off: its sessions and every bot on it stop, and the files say so.
  copy = { ...copy, access: { newPlaces: true, places: { [HOST]: false } }, revision: 7 }
  await service.refresh()
  assert.notEqual((await sign()).status, 0)
  assert.equal(service.botSetup(BOT).publicKey, null)
  assert.equal(existsSync(join(directory, 'github.conf')), false)
  // Turned back on, it signs again.
  copy = { ...copy, access: { newPlaces: true, places: { [HOST]: true } }, revision: 8 }
  await service.refresh()
  assert.equal((await sign()).status, 0)
  // A library that is briefly unavailable leaves the last copy in place.
  copy = null
  assert.equal(await service.refresh(), false)
  assert.equal((await sign()).status, 0)
})

test('new places follow the switch; a listed place keeps its own choice', () => {
  assert.equal(githubAllows(null, BOT), true)
  assert.equal(githubAllows({ newPlaces: false, places: { [BOT]: true } }, BOT.toUpperCase()), true)
  assert.equal(githubAllows({ newPlaces: false, places: {} }, OTHER_BOT), false)
})

test('session environments point ssh at the files, key or not, so a running process gets a later key', async t => {
  const home = scratch(t)
  const configuration = loadRuntimeConfiguration({ HOME: home, PATH: '/usr/bin:/bin' })
  const directory = githubDirectory(configuration)
  assert.equal(directory, join(home, '.wovenmatter/github'))
  assert.equal(nonInteractiveSessionEnvironment({ PATH: '/usr/bin' }, configuration).GIT_SSH_COMMAND, undefined)
  assert.equal(ensureGitHubStaticFiles(directory), true)
  assert.equal(nonInteractiveSessionEnvironment({ PATH: '/usr/bin' }, configuration).GIT_SSH_COMMAND, `ssh -F '${join(directory, 'ssh_config')}'`)
  assert.doesNotMatch(readFileSync(join(directory, 'ssh_config'), 'utf8'), /github\.conf/)
  assert.equal(nonInteractiveSessionEnvironment({ GIT_SSH: '/usr/bin/my-ssh' }, configuration).GIT_SSH_COMMAND, undefined)
  const environment = nonInteractiveSessionEnvironment({ PATH: '/usr/bin', GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: 'core.editor', GIT_CONFIG_VALUE_0: 'vi' }, configuration)
  assert.equal(environment.GIT_CONFIG_COUNT, '2')
  assert.equal(environment.GIT_CONFIG_KEY_1, 'include.path')
  assert.equal(environment.GIT_CONFIG_VALUE_1, join(directory, 'gitconfig'))
  assert.equal(nonInteractiveSessionEnvironment({ GIT_SSH_COMMAND: 'ssh -i mine' }, configuration).GIT_SSH_COMMAND, 'ssh -i mine')
  assert.ok(githubFiles(null, directory).ssh_config)
})

test('wm-exec gives SSH launches the same environment', () => {
  const source = readFileSync(new URL('../host/bin/wm-exec', import.meta.url), 'utf8')
  assert.match(source, /github=Path\(settings\['WOVENMATTER_STATE_DIRECTORY'\]\)\/'github'/)
  assert.match(source, /"ssh -F '"\+str\(github\/'ssh_config'\)/)
  assert.match(source, /include\.path/)
})
