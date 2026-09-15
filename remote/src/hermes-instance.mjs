import { acquireHostLock } from './runtime-maintenance.mjs'
import { DatabaseSync } from 'node:sqlite'
import { fileURLToPath } from 'node:url'
import { spawn } from 'node:child_process'
import { mkdir, readFile, writeFile, rename, rm, access } from 'node:fs/promises'
import { randomBytes } from 'node:crypto'
import { resolve } from 'node:path'
import { request as httpRequest } from 'node:http'
import { connect } from 'node:net'

const prefix = '/v1/workspace-instances/hermes'
const fail = (message, statusCode = 503) => Object.assign(new Error(message), { statusCode })
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

// The container owns this backend. Client disconnects never stop its scheduler.
export function createHermesInstance({ environment, isEnabled, spawnProcess = spawn, acquireLock = acquireHostLock, pluginSource = fileURLToPath(new URL('../harnesses/hermes-delivery/', import.meta.url)) }) {
  const home = () => environment().HERMES_HOME ?? resolve(environment().HOME, '.hermes')
  const directory = () => resolve(home(), '.woven-matter')
  let child, info, starting
  let desired = false
  let lastError = null
  async function health(candidate) {
    const response = await fetch(`http://127.0.0.1:${candidate.port}/api/system/stats`, {
      headers: { authorization: `Bearer ${candidate.token}` }, redirect: 'error', signal: AbortSignal.timeout(5000),
    })
    if (!response.ok || (await response.json()).process?.pid !== candidate.pid) throw fail('hermes_identity_unavailable')
  }
  async function start() {
    if (!await isEnabled()) throw fail('hermes_runtime_disabled', 409)
    if (starting) return starting
    starting = (async () => {
      const release = await acquireLock(resolve(environment().HOME, '.wovenmatter/runtime-operation.lock'), environment(), environment().HOME, true)
      try {
        const unlock = await acquireLock(resolve(directory(),'launch.lock'),environment(),environment().HOME)
        try { await launch() } finally { unlock() }
      } finally { release() }
    })().finally(() => { starting = null })
    return starting
  }
  function alive(pid) { try { process.kill(pid,0); return true } catch(error) { return error.code !== 'ESRCH' } }
  async function launch() {
    if (info && !alive(info.pid)) info=null
    if (info) { await health(info); return }
    await mkdir(directory(), { recursive: true, mode: 0o700 })
    const plugin = resolve(home(), 'plugins/wovenmatter-delivery')
    await mkdir(plugin, { recursive: true, mode: 0o700 })
    for (const name of ['plugin.yaml', '__init__.py']) {
      const bytes = await readFile(resolve(pluginSource, name))
      const temporary = resolve(plugin, name + '.tmp')
      await writeFile(temporary, bytes, { mode: 0o600 })
      await rename(temporary, resolve(plugin, name))
    }
    let registered
    try {
      const bytes=await readFile(resolve(directory(),'service.json'),'utf8')
      if(bytes.length > 16384) throw fail('hermes_registration_invalid')
      registered=JSON.parse(bytes)
      if(!Number.isInteger(registered.pid) || registered.pid<=0 || registered.pid>2147483647 || !Number.isInteger(registered.port) || registered.port<1 || registered.port>65535 || typeof registered.token!=='string' || !registered.token) throw fail('hermes_registration_invalid')
    } catch(error) { if(error.code!=='ENOENT') throw error }
    if(registered && alive(registered.pid)) { await health(registered); info=registered;desired=true;return }
    desired = true
    await writeFile(resolve(directory(), 'enabled'), '1', { mode: 0o600 })
    const ready = resolve(directory(), `ready-${randomBytes(16).toString('hex')}.json`)
    const token = randomBytes(32).toString('hex')
    const env = { ...environment(), HERMES_HOME: home(), HERMES_DESKTOP: '1',
      HERMES_DASHBOARD_SESSION_TOKEN: token, HERMES_DESKTOP_READY_FILE: ready }
    for (const key of ['HERMES_DESKTOP_PARENT_PID', 'HERMES_DESKTOP_PARENT_IDENTITY', 'TERMINAL_CWD', 'HERMES_TUI_SIDECAR_URL']) delete env[key]
    const process = spawnProcess('hermes', ['serve', '--isolated', '--host', '127.0.0.1', '--port', '0'], { env, stdio: 'ignore' })
    child = process
    process.on('error', () => { lastError = 'Hermes could not start. Check its installation.' })
    process.on('exit', () => { if (child === process) { child = null; info = null; lastError = 'Hermes stopped. Reconnecting automatically.' } })
    try {
      for (let attempt = 0; attempt < 180; attempt++) {
        if (process.exitCode !== null || process.signalCode !== null) throw fail('hermes_backend_exited')
        let readyInfo
        try { readyInfo = JSON.parse(await readFile(ready, 'utf8')) } catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error }
        if (Number.isInteger(readyInfo?.port) && readyInfo.port > 0 && readyInfo.port <= 65535) {
          const candidate = { port: readyInfo.port, pid: process.pid, token }
          await health(candidate)
          const temporary=resolve(directory(),'service.json.tmp')
          await writeFile(temporary,JSON.stringify(candidate),{mode:0o600})
          await rename(temporary,resolve(directory(),'service.json'))
          info = candidate; lastError = null
          return
        }
        await sleep(250)
      }
      throw fail('hermes_start_timeout')
    } catch (error) { process.kill('SIGTERM'); throw error }
    finally { await rm(ready, { force: true }) }
  }
  async function rpc(method) {
    const current=info
    if (!current) throw fail('hermes_not_running')
    return new Promise((resolve,reject) => {
      const socket=new WebSocket(`ws://127.0.0.1:${current.port}/api/ws?token=${current.token}`)
      const timer=setTimeout(()=>finish(fail('hermes_rpc_timeout')),10000)
      function finish(error,result) { clearTimeout(timer); socket.close(); error ? reject(error) : resolve(result) }
      socket.onopen=()=>socket.send(JSON.stringify({jsonrpc:'2.0',id:'lifecycle',method,params:{}}))
      socket.onerror=()=>finish(fail('hermes_rpc_unavailable'))
      socket.onmessage=event=> {
        try { for (const line of String(event.data).split('\n').filter(Boolean)) {
          const frame=JSON.parse(line)
          if(frame.id==='lifecycle') { if(frame.error) finish(fail('hermes_rpc_rejected')); else finish(null,frame.result) }
        } } catch { finish(fail('hermes_rpc_invalid')) }
      }
    })
  }
  async function restore() {
    try { desired = (await readFile(resolve(directory(), 'enabled'), 'utf8')) === '1' }
    catch (error) { if (error.code !== 'ENOENT') lastError = 'Hermes startup preference could not be read.' }
    if (desired && await isEnabled()) { try { await start() } catch { lastError = 'Hermes is unavailable. Check its installation and profile.' } }
  }
  const timer = setInterval(() => {
    if(info && !alive(info.pid)) info=null
    if (desired && !info && !child && !starting) void start().catch(() => { lastError = 'Hermes is unavailable. Check its installation and profile.' })
  }, 15000)
  timer.unref()
  function status() {
    return { kind: 'hermes', state: info ? 'running' : starting ? 'starting' : 'stopped', pid: info?.pid ?? null,
      version: null, endpointPath: `${prefix}/socket`, lastError }
  }
  async function handle(request, response, url) {
    if (!url.pathname.startsWith(prefix)) return false
    if (url.pathname === prefix || [`${prefix}/start`, `${prefix}/restart`, `${prefix}/stop`].includes(url.pathname)) {
      if (['/start','/restart','/stop'].some(action=>url.pathname.endsWith(action))) {
        if (request.method !== 'POST') throw fail('method_not_allowed', 405)
        if (starting) {
          try { await starting } catch(error) { if(!url.pathname.endsWith('/stop')) throw error }
        }
        if ((url.pathname.endsWith('/restart') || url.pathname.endsWith('/stop')) && info) {
          await health(info)
          try {
            const ledgerPath=resolve(home(),'cron/executions.db')
            await access(ledgerPath)
            const ledger=new DatabaseSync(ledgerPath,{readOnly:true})
            try { if(ledger.prepare("SELECT 1 FROM executions WHERE status IN ('claimed','running') LIMIT 1").get()) throw fail('hermes_has_active_scheduled_jobs',409) }
            finally { ledger.close() }
          } catch(error) { if(error.code!=='ENOENT') throw error }
          const active = await rpc('session.active_list')
          if (active.sessions.some(session => !['idle','ready','completed'].includes(session.status))) throw fail('hermes_has_active_turns',409)
          const running = info.pid
          const registered=JSON.parse(await readFile(resolve(directory(),'service.json'),'utf8'))
          if(registered.pid!==running || registered.token!==info.token) throw fail('hermes_owner_changed',409)
          desired=false
          process.kill(running,'SIGTERM')
          for(let attempt=0;alive(running) && attempt<80;attempt++) await sleep(125)
          if(alive(running)) throw fail('hermes_stop_timeout')
          info=null
        }
        if(url.pathname.endsWith('/stop')) {
          desired=false
          await mkdir(directory(),{recursive:true,mode:0o700})
          await writeFile(resolve(directory(),'enabled'),'0',{mode:0o600})
        } else await start()
      } else if (request.method !== 'GET') throw fail('method_not_allowed', 405)
      response.writeHead(200, { 'content-type': 'application/json' }); response.end(JSON.stringify(status())); return true
    }
    if (!info || !await isEnabled()) throw fail('hermes_not_running', 409)
    if (url.pathname === `${prefix}/results` && request.method === 'GET') {
      const offset = Number(url.searchParams.get('offset') ?? '0')
      if (!Number.isSafeInteger(offset) || offset < 0) throw fail('invalid_offset', 400)
      const path = resolve(directory(), 'scheduled-results.sqlite')
      let results = []
      try {
        await access(path)
        const db = new DatabaseSync(path, { readOnly: true })
        try { results = db.prepare('SELECT job_id AS jobID,run_id AS runID,output,saved_at AS savedAt FROM results ORDER BY saved_at,job_id,run_id LIMIT 100 OFFSET ?').all(offset) }
        finally { db.close() }
      } catch (error) { if (error.code !== 'ENOENT') throw fail('hermes_results_unavailable') }
      response.writeHead(200, { 'content-type': 'application/json' }); response.end(JSON.stringify(results)); return true
    }
    if (!url.pathname.startsWith(`${prefix}/api/`)) throw fail('not_found', 404)
    const path = url.pathname.slice(prefix.length) + url.search
    // This authenticated proxy exposes the selected profile's native API only.
    await new Promise((done, reject) => {
      const upstream = httpRequest({ host: '127.0.0.1', port: info.port, path, method: request.method,
        headers: { authorization: `Bearer ${info.token}`, ...(request.headers['content-type'] ? { 'content-type': request.headers['content-type'] } : {}) } }, result => {
        response.writeHead(result.statusCode ?? 502, { 'content-type': result.headers['content-type'] ?? 'application/json' })
        result.pipe(response); result.on('end', done); result.on('error', reject)
      })
      upstream.setTimeout(45000, () => upstream.destroy(fail('hermes_request_timeout')))
      upstream.on('error', reject)
      response.on('close', () => upstream.destroy())
      request.pipe(upstream)
    })
    return true
  }
  async function upgrade(request, socket, head) {
    if (request.url !== `${prefix}/socket`) return false
    if (!info || !await isEnabled()) { socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n'); return true }
    const current = info
    const upstream = connect({ host: '127.0.0.1', port: current.port }, () => {
      const headers = Object.entries(request.headers).filter(([key]) => !['host', 'authorization', 'cookie'].includes(key.toLowerCase()))
        .map(([key, value]) => `${key}: ${value}`).join('\r\n')
      upstream.write(`GET /api/ws?token=${current.token} HTTP/1.1\r\nHost: 127.0.0.1:${current.port}\r\n${headers}\r\n\r\n`)
      if (head.length) upstream.write(head)
      socket.pipe(upstream).pipe(socket)
    })
    upstream.on('error', () => socket.destroy()); socket.on('error', () => upstream.destroy()); socket.on('close', () => upstream.destroy())
    return true
  }
  return { start, restore, status, handle, upgrade, hasActiveRuntime: () => Boolean(child || info || starting), close: () => { desired=false; clearInterval(timer); child?.kill('SIGTERM') } }
}
