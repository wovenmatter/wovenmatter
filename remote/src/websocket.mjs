import { existsSync } from 'node:fs'
import { createRequire } from 'node:module'

// The `ws` package, from the Built-in agent's locked graph
// (`default-agent/package.json` `ws`, `default-agent/package-lock.json`), the
// same selection the bots runtime uses. Every host release installs that graph
// with `npm ci` beside `src/`, as it does for the agent modules server.mjs
// loads; a checkout has default-agent/ beside remote/.
// docs/DEPENDENCIES.md, "Remote service".
const release = new URL('../default-agent/package.json', import.meta.url)
export const webSocketPackageOwner = existsSync(release) ? release : new URL('../../default-agent/package.json', import.meta.url)
const ws = createRequire(webSocketPackageOwner)('ws')

export const WebSocket = ws.WebSocket
export const WebSocketServer = ws.WebSocketServer
