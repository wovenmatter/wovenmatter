import { createServer } from 'node:http'
import { createInterface } from 'node:readline'
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto'

const digest = value => createHash('sha256').update(value).digest()
const MAX_BYTES = 4 * 1024 * 1024
const HTML_MAX_BYTES = 40 * 1024 * 1024

// This is an HTTP transport for an already-authorized Woven session. SSH only
// carries framed MCP requests; it never supplies model-visible shell commands.
export async function runMCPRelay({input = process.stdin, output = process.stdout, host = '127.0.0.1', maximumConnections = 4, timeoutMilliseconds = 120000} = {}) {
  let tokenHash, stopped = false, reading=0
  const calls = new Map(), reader = createInterface({input, crlfDelay: Infinity})
  const send = packet => output.write(JSON.stringify(packet) + '\n')
  const server = createServer(async (request, response) => {
    response.setHeader('cache-control', 'no-store')
    if (stopped || !tokenHash) { response.writeHead(503); response.end(); return }
    const supplied = request.headers.authorization?.startsWith('Bearer ') ? request.headers.authorization.slice(7) : ''
    if (!supplied || !timingSafeEqual(digest(supplied), tokenHash)) {
      response.writeHead(401, {'www-authenticate': 'Bearer'}); response.end(); return
    }
    if (request.url !== '/mcp') { response.writeHead(404); response.end(); return }
    if (request.method !== 'POST') { response.writeHead(405, {allow: 'POST'}); response.end(); return }
    const address = server.address(), allowedHosts = new Set([`127.0.0.1:${address.port}`, `localhost:${address.port}`])
    let originAllowed = !request.headers.origin
    try { if (request.headers.origin) originAllowed = allowedHosts.has(new URL(request.headers.origin).host) } catch {}
    if (!allowedHosts.has(request.headers.host) || !originAllowed) {
      response.writeHead(403); response.end(); return
    }
    if (calls.size + reading >= maximumConnections) { response.writeHead(429); response.end(); return }
    reading++
    const id = randomUUID(), chunks = []
    let bytes = 0
    try {
      for await (const chunk of request) {
        bytes += chunk.length
        if (bytes > HTML_MAX_BYTES) { response.writeHead(413); response.end(); return }
        chunks.push(chunk)
      }
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'))
      if (bytes > MAX_BYTES && !(body.method === 'tools/call' && ['woven_html_preview', 'woven_html_render'].includes(body.params?.name))) {
        response.writeHead(413); response.end(); return
      }
      const timer = setTimeout(() => {
        calls.delete(id); send({type: 'cancel', id}); response.writeHead(504); response.end()
      }, timeoutMilliseconds)
      timer.unref()
      calls.set(id, {response, timer})
      response.once('close', () => {
        const call = calls.get(id)
        if (call) { calls.delete(id); clearTimeout(call.timer); send({type: 'cancel', id}) }
      })
      send({type: 'request', id, body})
    } catch {
      if (!response.headersSent) response.writeHead(400)
      response.end()
    } finally {reading--}
  })
  const completion = new Promise((resolve, reject) => {
    server.once('error', reject)
    reader.on('line', line => {
      try {
        if (Buffer.byteLength(line) > MAX_BYTES * 2) throw new Error('Relay frame too large')
        const packet = JSON.parse(line)
        if (packet.type === 'configure') {
          if (tokenHash || typeof packet.bearerToken !== 'string' || packet.bearerToken.length < 32) throw new Error('Invalid relay binding')
          tokenHash = digest(packet.bearerToken)
          server.listen(0, host, () => send({type: 'ready', endpointURL: `http://${host}:${server.address().port}/mcp`}))
        } else if (packet.type === 'response') {
          const call = calls.get(packet.id)
          if (!call) return
          calls.delete(packet.id); clearTimeout(call.timer)
          const status = packet.status === 202 ? 202 : packet.status === 200 ? 200 : 502
          call.response.writeHead(status, {'content-type': 'application/json'})
          call.response.end(status === 202 ? undefined : JSON.stringify(packet.body))
        }
      } catch (error) { reject(error); reader.close() }
    })
    reader.once('close', () => { stopped = true; server.close(); resolve() })
    input.once('error', reject)
    output.once('error', reject)
  })
  try { await completion } finally {
    stopped = true
    for (const {response, timer} of calls.values()) { clearTimeout(timer); response.destroy() }
    calls.clear(); server.close(); reader.close()
  }
}
