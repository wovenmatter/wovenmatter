import { createHash, timingSafeEqual } from 'node:crypto'

// Headers Tailscale Serve sets on every request it proxies to this server
// (X-Forwarded-Host always; X-Forwarded-For and the identity headers for
// tailnet users). The Mac that installed this host reaches it through its
// Tailscale SSH tunnel, a direct loopback connection that carries none of them.
const proxyHeaders = ['x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto', 'forwarded', 'via',
  'tailscale-user-login', 'tailscale-user-name', 'tailscale-user-profile-pic', 'tailscale-headers-info', 'tailscale-app-capabilities']

/**
 * True for a request a proxy forwarded. A host server listens on loopback only
 * (config.mjs), so the forwarded headers are what tells Serve from the SSH
 * tunnel; Serve replaces any client-sent copies, so they cannot be stripped.
 */
export function proxiedRequest(request) {
  return proxyHeaders.some(name => request.headers[name] !== undefined)
}

const digest = value => createHash('sha256').update(value).digest()

/**
 * The installer's bearer (docs/architecture/WOVEN_EVERYWHERE.md, "Installer
 * bearer"): the credential the installing Mac streams over Tailscale SSH. It
 * administers this host only on that SSH/loopback path, never through the
 * Serve route, and `rotate` replaces it (remote-host.sh `rotate-token` writes
 * the new value to service.env, which lifecycle health checks read).
 */
export function createInstallerBearer({ token, rotate }) {
  let current = digest(token)
  let rotating = null
  const listeners = new Set()
  function matches(request) {
    const value = request.headers.authorization ?? ''
    if (!value.startsWith('Bearer ')) return false
    return timingSafeEqual(digest(value.slice(7)), current)
  }
  return {
    matches,
    /** The installer bearer, presented on the SSH/loopback path. */
    authorizes: request => !proxiedRequest(request) && matches(request),
    /** Generates and installs a new bearer and returns it; the old one stops working at once. */
    rotate() {
      rotating ??= (async () => {
        try {
          const next = await rotate()
          if (typeof next !== 'string' || !/^[A-Za-z0-9+/=_-]{32,256}$/.test(next)) throw Object.assign(new Error('installer_rotation_failed'), { statusCode: 502 })
          current = digest(next)
          for (const listener of listeners) { try { listener() } catch {} }
          return next
        } finally { rotating = null }
      })()
      return rotating
    },
    /** Calls `listener` after each rotation, so what the old bearer opened can close; returns its removal. */
    onRotate(listener) { listeners.add(listener); return () => listeners.delete(listener) },
  }
}
