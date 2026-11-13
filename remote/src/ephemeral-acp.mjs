import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { randomUUID } from 'node:crypto'
import { harnessLaunch } from './durable-acp.mjs'

const fail = message => Object.assign(new Error(message), { statusCode: 409 })

// One short-lived ACP process for a question that needs no conversation: a
// harness's options before a session exists, or a conversation title. It has
// no Woven MCP connection, denies every permission request, refuses client
// RPCs, and is stopped when the caller closes it. Nothing is journaled.
export function openEphemeralACP({ harness, runtimeKind = harness.id, cwd, environment = () => process.env, permission,
  spawnProcess = spawn, timeoutMilliseconds = 30000, onUpdate = () => {} }) {
  const launch = harnessLaunch(harness, runtimeKind, permission)
  const child = spawnProcess(launch.command, launch.arguments, { cwd, env: environment(harness), stdio: ['pipe', 'pipe', 'pipe'] })
  const pending = new Map()
  let closed = false, failure = null
  const write = message => { if (!closed && child.stdin.writable) child.stdin.write(JSON.stringify(message) + '\n') }
  const settle = error => {
    failure ??= error
    for (const request of pending.values()) request.reject(failure)
    pending.clear()
  }
  child.stderr?.on('data', () => {})
  child.stdin.on('error', () => settle(fail('The agent process closed its input.')))
  child.once('error', () => settle(fail('The agent process could not start.')))
  child.once('close', () => { closed = true; settle(fail('The agent process exited.')) })
  const lines = createInterface({ input: child.stdout })
  lines.on('line', line => {
    if (Buffer.byteLength(line) > 8 * 1024 * 1024) { child.kill('SIGTERM'); return }
    let message
    try { message = JSON.parse(line) } catch { return }
    if (message.id != null && !message.method) {
      const request = pending.get(String(message.id))
      if (!request) return
      pending.delete(String(message.id))
      if (message.error) request.reject(fail('The agent rejected this operation.'))
      else request.resolve(message.result ?? {})
    } else if (message.method === 'session/update') {
      try { onUpdate(message.params?.update ?? {}) } catch {}
    } else if (message.method === 'session/request_permission' && message.id != null) {
      write({ jsonrpc: '2.0', id: message.id, result: { outcome: { outcome: 'cancelled' } } })
    } else if (message.method && message.id != null) {
      write({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'This client operation is unavailable.' } })
    }
  })
  function request(method, params = {}, timeout = timeoutMilliseconds) {
    if (failure) return Promise.reject(failure)
    const id = randomUUID()
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(fail('The agent did not answer in time.')) }, timeout)
      timer.unref?.()
      pending.set(id, { resolve: value => { clearTimeout(timer); resolve(value) }, reject: error => { clearTimeout(timer); reject(error) } })
      write({ jsonrpc: '2.0', id, method, params })
    })
  }
  async function close() {
    if (closed) return
    lines.close()
    await new Promise(resolve => {
      const timer = setTimeout(() => { child.kill('SIGKILL'); resolve() }, 1500)
      timer.unref?.()
      child.once('close', () => { clearTimeout(timer); resolve() })
      child.stdin.destroy()
      child.kill('SIGTERM')
    })
  }
  return { request, close }
}

// `initialize` then `session/new` with no MCP servers: the session's native
// configuration (models, modes, config options).
export async function ephemeralSession(connection, cwd) {
  const initialized = await connection.request('initialize', { protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false }, clientInfo: { name: 'Woven Matter Workspace', version: '1' } })
  if (initialized.protocolVersion !== 1) throw fail('Unsupported native agent protocol.')
  const session = await connection.request('session/new', { cwd, mcpServers: [] })
  if (typeof session.sessionId !== 'string' || !session.sessionId) throw fail('The native agent did not create a session.')
  return session
}
