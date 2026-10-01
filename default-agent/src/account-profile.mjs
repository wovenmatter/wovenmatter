// Profile metadata shares the credential's storage and never authorizes access.
// Failure to fetch a display label must not discard a successful OAuth sign-in.
export async function grokAccountProfile(credential, fetcher = fetch) {
  if (credential?.type !== 'oauth' || !credential.access) return {};
  try {
    const response = await fetcher('https://auth.x.ai/oauth2/userinfo', {
      headers: { Authorization: `Bearer ${credential.access}` }, redirect: 'error', signal: AbortSignal.timeout(10000),
    });
    if (!response.ok || !response.body) return {};
    const reader = response.body.getReader(); const chunks = []; let length = 0;
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      length += value.length;
      if (length > 65536) { await reader.cancel(); return {}; }
      chunks.push(value);
    }
    const profile = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    const displayName = [profile?.email, profile?.name, profile?.sub].find(v => typeof v === 'string' && v.length > 0 && v.length <= 320);
    return displayName ? { displayName } : {};
  } catch { return {}; }
}
