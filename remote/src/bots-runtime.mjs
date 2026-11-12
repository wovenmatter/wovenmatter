import { spawn } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { existsSync } from 'node:fs'
import { mkdir, open, rename } from 'node:fs/promises'
import { createServer } from 'node:net'
import { dirname, join } from 'node:path'

// The bots package ships beside src/ in host releases and at the top of a checkout.
export function botsPackageRoot(serviceRoot) {
  for (const candidate of [join(serviceRoot, 'bots'), join(serviceRoot, '..', 'bots')]) {
    if (existsSync(join(candidate, 'src/cli.ts'))) return candidate
  }
  return null
}

export function freeLoopbackPort() {
  return new Promise((resolve, reject) => {
    const probe = createServer()
    probe.once('error', reject)
    probe.listen(0, '127.0.0.1', () => { const { port } = probe.address(); probe.close(() => resolve(port)) })
  })
}

async function writePrivateJSON(path, value) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = path + '.' + process.pid + '.' + randomBytes(4).toString('hex')
  const handle = await open(temporary, 'wx', 0o600)
  try { await handle.writeFile(JSON.stringify(value, null, 2) + '\n'); await handle.sync() } finally { await handle.close() }
  await rename(temporary, path)
}

/**
 * Supervises `node bots/src/cli.ts serve --config <file>`. Every start writes a
 * fresh config with a new runtime token; a crash restarts with backoff.
 * `configuration()` supplies everything except the listener and token.
 */
export function createBotsRuntime({ packageRoot, configPath, configuration, nodePath = process.execPath, environment = process.env,
  spawnImpl = spawn, portImpl = freeLoopbackPort, log = () => {}, minimumBackoff = 1000, maximumBackoff = 30000, healthyAfter = 60000 } = {}) {
  let child = null, stopping = false, timer = null, backoff = minimumBackoff, startedAt = 0, restarts = 0, lastExit = null
  let listen = null, runtimeToken = null, generation = 0

  async function launch() {
    timer = null
    if (stopping) return
    const current = ++generation
    try {
      listen = { host: '127.0.0.1', port: await portImpl() }
      runtimeToken = randomBytes(32).toString('base64url')
      const config = { ...await configuration(), listen, runtimeToken }
      await writePrivateJSON(configPath, config)
      if (stopping || current !== generation) return
      // Node 26 strips TypeScript types natively; there is no build step.
      const env = { ...environment, NODE_ENV: 'production' }
      delete env.WOVENMATTER_API_TOKEN
      child = spawnImpl(nodePath, [join(packageRoot, 'src/cli.ts'), 'serve', '--config', configPath], { cwd: packageRoot, env, stdio: ['ignore', 'inherit', 'inherit'] })
      startedAt = Date.now()
      child.once('error', () => {})
      child.once('exit', (code, signal) => {
        lastExit = { code, signal, at: new Date().toISOString() }
        child = null
        if (stopping || current !== generation) return
        if (Date.now() - startedAt >= healthyAfter) backoff = minimumBackoff
        restarts++
        log(`Bots runtime exited (${signal ?? code}); restarting in ${backoff} ms`)
        timer = setTimeout(launch, backoff); timer.unref?.()
        backoff = Math.min(maximumBackoff, backoff * 2)
      })
    } catch (error) {
      log('Bots runtime could not start: ' + error.message)
      if (!stopping) { timer = setTimeout(launch, backoff); timer.unref?.(); backoff = Math.min(maximumBackoff, backoff * 2) }
    }
  }

  function start() { stopping = false; if (!child && !timer) void launch() }

  async function stop({ timeout = 10000 } = {}) {
    stopping = true; generation++
    clearTimeout(timer); timer = null
    const running = child
    if (!running) return
    await new Promise(resolve => {
      const kill = setTimeout(() => running.kill('SIGKILL'), timeout); kill.unref?.()
      running.once('exit', () => { clearTimeout(kill); resolve() })
      running.kill('SIGTERM')
    })
  }

  async function restart() { await stop(); start() }

  return {
    start, stop, restart,
    endpoint: () => child && listen ? { ...listen, token: runtimeToken } : null,
    status: () => ({ running: !!child, pid: child?.pid ?? null, port: child ? listen?.port ?? null : null, restarts, lastExit, startedAt: child ? new Date(startedAt).toISOString() : null }),
  }
}
