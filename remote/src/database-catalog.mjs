import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const helper = fileURLToPath(new URL('./database-catalog.py', import.meta.url))
const maximumResponseBytes = 6 * 1024 * 1024
let activeRequests = 0

// A separate, bounded process keeps SQLite queries off the service event loop.
export function databaseOperation(workspaceRoot, request) {
  if (activeRequests >= 4) return Promise.reject(Object.assign(new Error('Database service is busy. Try again.'), { statusCode: 429 }))
  activeRequests += 1
  return new Promise((resolve, reject) => {
    const child = spawn('/usr/bin/python3', ['-I', helper, workspaceRoot], { stdio: ['pipe', 'pipe', 'pipe'] })
    const chunks = []
    let size = 0
    let failure
    const stop = message => { failure = new Error(message); child.kill('SIGKILL') }
    const timer = setTimeout(() => stop('Database request timed out. Try again.'), 10000)
    child.stdout.on('data', chunk => {
      size += chunk.length
      if (size > maximumResponseBytes) stop('Database response is too large.')
      else chunks.push(chunk)
    })
    child.stderr.resume()
    child.stdin.on('error', () => {})
    child.on('error', error => { clearTimeout(timer); reject(error) })
    child.on('close', code => {
      clearTimeout(timer)
      if (failure) return reject(failure)
      try {
        const result = JSON.parse(Buffer.concat(chunks).toString('utf8'))
        if (code !== 0) return reject(Object.assign(new Error(result.error ?? 'Database unavailable.'), { statusCode: 400 }))
        resolve(result)
      } catch { reject(new Error('Database service unavailable.')) }
    })
    child.stdin.end(JSON.stringify(request))
  }).finally(() => { activeRequests -= 1 })
}
