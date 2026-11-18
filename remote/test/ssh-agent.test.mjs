import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { agentReply, parseOpenSSHPrivateKey, startAgentServer } from '../src/ssh-agent.mjs'

// Settings → GitHub's signing agent, checked with the real ssh tools. Nothing connects to GitHub.
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
function scratch(t) {
  const directory = mkdtempSync(join(tmpdir(), 'woven-agent-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  return directory
}

for (const [type, bits] of [['ed25519'], ['ecdsa', '256'], ['ecdsa', '384'], ['ecdsa', '521'], ['rsa', '2048']]) {
  test(`ssh signs through the agent with a ${type}${bits ? ' ' + bits : ''} key it never sees`, async t => {
    const directory = scratch(t)
    const file = join(directory, 'key')
    const made = spawnSync('ssh-keygen', ['-q', '-t', type, ...(bits ? ['-b', bits] : []), '-N', '', '-C', 'woven-matter', '-f', file], { encoding: 'utf8' })
    if (made.status !== 0) return t.skip('ssh-keygen is not installed')
    const key = parseOpenSSHPrivateKey(readFileSync(file, 'utf8'))
    // As on every machine: only the public key is on disk.
    rmSync(file)
    let allowed = true
    const socket = join(directory, 'agent.sock')
    const server = await startAgentServer(socket, message => agentReply(message, allowed ? key : null))
    t.after(() => server.close())
    assert.equal(statSync(socket).mode & 0o777, 0o600)
    const env = { ...process.env, SSH_AUTH_SOCK: socket }
    const listed = await run('ssh-add', ['-L'], { env })
    assert.equal(listed.stdout.trim(), readFileSync(file + '.pub', 'utf8').trim())

    // ssh-keygen -Y sign asks the agent when given only the public key.
    writeFileSync(join(directory, 'message'), 'hello')
    const signed = await run('ssh-keygen', ['-Y', 'sign', '-f', file + '.pub', '-n', 'git', join(directory, 'message')], { env })
    assert.equal(signed.status, 0, signed.stderr)
    const checked = await run('ssh-keygen', ['-Y', 'check-novalidate', '-n', 'git', '-f', file + '.pub', '-s', join(directory, 'message.sig')], { input: 'hello' })
    assert.equal(checked.status, 0, checked.stderr)

    // Turned off: nothing to list, nothing signed, at once.
    allowed = false
    assert.notEqual((await run('ssh-add', ['-L'], { env })).status, 0)
    rmSync(join(directory, 'message.sig'), { force: true })
    assert.notEqual((await run('ssh-keygen', ['-Y', 'sign', '-f', file + '.pub', '-n', 'git', join(directory, 'message')], { env })).status, 0)
  })
}

test('requests the agent does not serve, and malformed ones, are refused', () => {
  assert.deepEqual(agentReply(Buffer.from([17]), null), Buffer.from([5]))
  assert.deepEqual(agentReply(Buffer.from([13, 0, 0]), null), Buffer.from([5]))
  assert.deepEqual(agentReply(Buffer.alloc(0), null), Buffer.from([5]))
  assert.throws(() => parseOpenSSHPrivateKey('nope'), /not an OpenSSH private key/)
})
