import { createPrivateKey, sign as cryptoSign } from 'node:crypto'
import { chmod, rm } from 'node:fs/promises'
import { createServer } from 'node:net'

// Settings → GitHub's signing agent on a Linux host (docs/architecture/GITHUB_IDENTITY.md):
// the SSH agent protocol (draft-miller-ssh-agent), listing and signing only. Agents and bots
// ask it to sign GitHub logins; they never get the key, so turning a place off stops them at
// once with nothing to take back. The Mac's agent is `SSHSigningAgent` and answers the same.

const FAILURE = 5, REQUEST_IDENTITIES = 11, IDENTITIES_ANSWER = 12, SIGN_REQUEST = 13, SIGN_RESPONSE = 14
const RSA_SHA2_256 = 2, RSA_SHA2_512 = 4
const MAXIMUM_MESSAGE = 256 * 1024

const u32 = value => { const buffer = Buffer.alloc(4); buffer.writeUInt32BE(value >>> 0); return buffer }
const string = value => { const bytes = Buffer.from(value); return Buffer.concat([u32(bytes.length), bytes]) }
const unsigned = bytes => { let start = 0; while (start < bytes.length - 1 && bytes[start] === 0) start++; return bytes.subarray(start) }
const mpint = bytes => { const value = unsigned(Buffer.from(bytes)); return string(value[0] & 0x80 ? Buffer.concat([Buffer.from([0]), value]) : value) }
const base64url = bytes => Buffer.from(bytes).toString('base64url')
const bigint = bytes => BigInt('0x' + (Buffer.from(bytes).toString('hex') || '0'))
const bigintBytes = value => { const hex = value.toString(16); return Buffer.from(hex.length % 2 ? '0' + hex : hex, 'hex') }

class Reader {
  constructor(buffer) { this.buffer = buffer; this.offset = 0 }
  u32() { if (this.offset + 4 > this.buffer.length) throw new Error('short'); const value = this.buffer.readUInt32BE(this.offset); this.offset += 4; return value }
  bytes(length) { if (this.offset + length > this.buffer.length) throw new Error('short'); const value = this.buffer.subarray(this.offset, this.offset + length); this.offset += length; return value }
  string() { return this.bytes(this.u32()) }
  text() { return this.string().toString('utf8') }
}

const curves = {
  'ecdsa-sha2-nistp256': { crv: 'P-256', size: 32, hash: 'sha256' },
  'ecdsa-sha2-nistp384': { crv: 'P-384', size: 48, hash: 'sha384' },
  'ecdsa-sha2-nistp521': { crv: 'P-521', size: 66, hash: 'sha512' },
}
const pad = (bytes, size) => { const value = unsigned(Buffer.from(bytes)); return value.length >= size ? value.subarray(value.length - size) : Buffer.concat([Buffer.alloc(size - value.length), value]) }

/**
 * An unencrypted OpenSSH private key (`openssh-key-v1`, as Settings → GitHub saves every key):
 * `{type, publicBlob, sign(data, flags)}`. Ed25519, ECDSA and RSA; throws on anything else.
 */
export function parseOpenSSHPrivateKey(text) {
  const body = String(text).replace(/-----(BEGIN|END) OPENSSH PRIVATE KEY-----/g, '').replace(/\s+/g, '')
  const reader = new Reader(Buffer.from(body, 'base64'))
  const magic = 'openssh-key-v1\0'
  let header = ''
  try { header = reader.bytes(magic.length).toString('latin1') } catch {}
  if (header !== magic) throw new Error('not an OpenSSH private key')
  if (reader.text() !== 'none' || reader.text() !== 'none') throw new Error('the key has a passphrase')
  reader.string()
  if (reader.u32() !== 1) throw new Error('one key expected')
  const publicBlob = Buffer.from(reader.string())
  const secret = new Reader(reader.string())
  if (secret.u32() !== secret.u32()) throw new Error('the key could not be read')
  const type = secret.text()
  if (type === 'ssh-ed25519') {
    const publicKey = secret.string(), privateKey = secret.string()
    const key = createPrivateKey({ format: 'jwk', key: { kty: 'OKP', crv: 'Ed25519', d: base64url(privateKey.subarray(0, 32)), x: base64url(publicKey) } })
    return { type, publicBlob, sign: data => Buffer.concat([string(type), string(cryptoSign(null, data, key))]) }
  }
  if (curves[type]) {
    const { crv, size, hash } = curves[type]
    secret.string()
    const point = secret.string(), d = secret.string()
    if (point[0] !== 4 || point.length !== 1 + 2 * size) throw new Error('the key could not be read')
    const key = createPrivateKey({ format: 'jwk', key: { kty: 'EC', crv, x: base64url(point.subarray(1, 1 + size)), y: base64url(point.subarray(1 + size)), d: base64url(pad(d, size)) } })
    return { type, publicBlob, sign: data => {
      const signature = cryptoSign(hash, data, { key, dsaEncoding: 'ieee-p1363' })
      return Buffer.concat([string(type), string(Buffer.concat([mpint(signature.subarray(0, size)), mpint(signature.subarray(size))]))])
    } }
  }
  if (type === 'ssh-rsa') {
    const [n, e, d, iqmp, p, q] = [secret.string(), secret.string(), secret.string(), secret.string(), secret.string(), secret.string()]
    const [D, P, Q] = [bigint(d), bigint(p), bigint(q)]
    const key = createPrivateKey({ format: 'jwk', key: { kty: 'RSA', n: base64url(unsigned(n)), e: base64url(unsigned(e)), d: base64url(unsigned(d)),
      p: base64url(unsigned(p)), q: base64url(unsigned(q)), dp: base64url(bigintBytes(D % (P - 1n))), dq: base64url(bigintBytes(D % (Q - 1n))), qi: base64url(unsigned(iqmp)) } })
    return { type, publicBlob, sign: (data, flags = 0) => {
      const [name, hash] = flags & RSA_SHA2_512 ? ['rsa-sha2-512', 'sha512'] : flags & RSA_SHA2_256 ? ['rsa-sha2-256', 'sha256'] : ['ssh-rsa', 'sha1']
      return Buffer.concat([string(name), string(cryptoSign(hash, data, key))])
    } }
  }
  throw new Error('unsupported key type ' + type)
}

/**
 * One agent request (without its length prefix) → the reply. `key` is null while the asking
 * place may not use it: the agent then lists nothing and refuses to sign.
 */
export function agentReply(message, key, comment = 'woven-matter') {
  try {
    const reader = new Reader(message)
    const kind = reader.bytes(1)[0]
    if (kind === REQUEST_IDENTITIES) {
      return key ? Buffer.concat([Buffer.from([IDENTITIES_ANSWER]), u32(1), string(key.publicBlob), string(comment)]) : Buffer.concat([Buffer.from([IDENTITIES_ANSWER]), u32(0)])
    }
    if (kind === SIGN_REQUEST && key) {
      const blob = reader.string(), data = reader.string(), flags = reader.offset < message.length ? reader.u32() : 0
      if (blob.equals(key.publicBlob)) return Buffer.concat([Buffer.from([SIGN_RESPONSE]), string(key.sign(data, flags))])
    }
  } catch {}
  return Buffer.from([FAILURE])
}

/** Serves `reply(message)` on a Unix socket only the user can open. */
export async function startAgentServer(path, reply) {
  await rm(path, { force: true })
  const server = createServer(socket => {
    let pending = Buffer.alloc(0), replies = Promise.resolve()
    socket.on('data', chunk => {
      pending = Buffer.concat([pending, chunk])
      while (pending.length >= 4) {
        const length = pending.readUInt32BE(0)
        if (length === 0 || length > MAXIMUM_MESSAGE) { socket.destroy(); return }
        if (pending.length < 4 + length) return
        const message = Buffer.from(pending.subarray(4, 4 + length))
        pending = pending.subarray(4 + length)
        // Replies go back in request order, even when one takes longer.
        replies = replies.then(async () => {
          const answer = await Promise.resolve().then(() => reply(message)).catch(() => Buffer.from([FAILURE]))
          if (!socket.destroyed) socket.write(Buffer.concat([u32(answer.length), answer]))
        })
      }
    })
    socket.on('error', () => {})
  })
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(path, () => { server.off('error', reject); resolve() }) })
  await chmod(path, 0o600)
  return server
}
