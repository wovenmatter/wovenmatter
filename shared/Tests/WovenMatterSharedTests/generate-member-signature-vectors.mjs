// Regenerates MemberSignatureVectors.json: node generate-member-signature-vectors.mjs > MemberSignatureVectors.json
// Ed25519 (RFC 8032) is deterministic, so the output is byte-identical on every run.
import crypto from 'node:crypto';

const seed = Buffer.from('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60', 'hex');
const priv = crypto.createPrivateKey({
  key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]), format: 'der', type: 'pkcs8',
});
const pub = crypto.createPublicKey(priv).export({ format: 'der', type: 'spki' }).subarray(-32);
const b64u = (bytes) => Buffer.from(bytes).toString('base64url');
const deviceID = '6f1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b';
// The destination member: every verifier refuses a request addressed to another device.
const audience = 'a3b4c5d6-e7f8-4a09-9b1c-2d3e4f5a6b7c';
const otherAudience = 'c0ffee00-1234-4abc-8def-0123456789ab';

const cases = [
  { name: 'post-with-body', method: 'POST', target: '/v1/peers/sync', time: 1762646400000,
    nonce: 'AAECAwQFBgcICQoLDA0ODw', body: '{"deviceID":"6f1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b","after":0}' },
  { name: 'get-empty-body-with-query', method: 'GET', target: '/v1/changes?after=12&limit=200', time: 1762646400123,
    nonce: 'EBESExQVFhcYGRobHB0eHw', body: '' },
  { name: 'websocket-upgrade', method: 'GET', target: '/v1/bots/ws', time: 1762646401000, nonce: 'ICEiIyQlJicoKSorLC0uLw', body: '' },
  { name: 'unicode-body', method: 'POST', target: '/v1/mutations', time: 1762646402000, nonce: 'MDEyMzQ1Njc4OTo7PD0-Pw',
    body: '{"title":"Café — notes 📝"}' },
];

const message = (c) => {
  const bodySHA256 = crypto.createHash('sha256').update(Buffer.from(c.body, 'utf8')).digest('hex');
  return { bodySHA256, text: ['woven-member-v2', c.audience ?? audience, c.method, c.target, String(c.time), c.nonce, bodySHA256].join('\n') };
};

const signed = cases.map((c) => {
  const { bodySHA256, text } = message(c);
  const signature = crypto.sign(null, Buffer.from(text, 'utf8'), priv);
  if (!crypto.verify(null, Buffer.from(text, 'utf8'), crypto.createPublicKey(priv), signature)) throw new Error('self-check failed');
  return {
    ...c, bodyBase64: Buffer.from(c.body, 'utf8').toString('base64'), bodySHA256, message: text, signature: b64u(signature),
    headers: {
      'X-Woven-Member-Device': deviceID, 'X-Woven-Member-Audience': audience, 'X-Woven-Member-Time': String(c.time),
      'X-Woven-Member-Nonce': c.nonce, 'X-Woven-Member-Signature': b64u(signature),
    },
  };
});

// Each reject reuses the named case's signature with one field changed; every verifier must refuse it.
const rejects = [
  { name: 'method-changed', case: 'post-with-body', method: 'PUT' },
  { name: 'target-changed', case: 'post-with-body', target: '/v1/peers/files' },
  { name: 'query-changed', case: 'get-empty-body-with-query', target: '/v1/changes?after=13&limit=200' },
  { name: 'time-changed', case: 'post-with-body', time: 1762646400001 },
  { name: 'nonce-changed', case: 'post-with-body', nonce: 'AAECAwQFBgcICQoLDA0OEA' },
  { name: 'body-changed', case: 'post-with-body', body: '{"deviceID":"6f1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b","after":1}' },
  // The same signature presented to another member under its own audience.
  { name: 'audience-changed', case: 'post-with-body', audience: otherAudience },
];
for (const reject of rejects) {
  const original = signed.find((c) => c.name === reject.case);
  const { text } = message({ ...original, ...reject });
  if (crypto.verify(null, Buffer.from(text, 'utf8'), crypto.createPublicKey(priv), Buffer.from(original.signature, 'base64url'))) {
    throw new Error('tampered vector verified: ' + reject.name);
  }
}

process.stdout.write(JSON.stringify({
  description: 'Signed member request vectors (docs/architecture/WOVEN_EVERYWHERE.md, "Membership and device keys"). '
    + 'Signatures are deterministic RFC 8032 Ed25519 over the UTF-8 message; Node regenerates them byte for byte. '
    + 'CryptoKit signatures are randomized, so Swift checks the message bytes and verification. '
    + 'Each reject reuses the named case\'s signature with one field changed and must be refused. '
    + 'The message is woven-member-v2, audience, method, canonical target, time, nonce and body SHA-256, joined by newlines; '
    + 'a verifier whose own device ID is not the audience refuses the request before checking the signature.',
  privateKeySeedHex: seed.toString('hex'),
  publicKeyBase64: Buffer.from(pub).toString('base64'),
  publicKeyHex: Buffer.from(pub).toString('hex'),
  deviceID,
  audience,
  windowMilliseconds: 300000,
  cases: signed,
  rejects,
}, null, 2) + '\n');
