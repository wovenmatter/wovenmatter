// Resolve a moving supported channel once, before an install transaction.
export const releaseVersion = value => typeof value === 'string' && /^\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.test(value);
export function compareVersions(a, b) {
  const split = value => { const i = value.indexOf('-'); return i < 0 ? [value, undefined] : [value.slice(0, i), value.slice(i + 1)]; };
  const [ac, ap] = split(a), [bc, bp] = split(b);
  const aa = ac.split('.').map(Number), bb = bc.split('.').map(Number);
  for (let i = 0; i < 3; i++) if (aa[i] !== bb[i]) return aa[i] - bb[i];
  if (ap === undefined || bp === undefined) return ap === bp ? 0 : ap === undefined ? 1 : -1;
  const ai = ap.split('.'), bi = bp.split('.');
  for (let i = 0; i < Math.max(ai.length, bi.length); i++) {
    if (ai[i] === bi[i]) continue;
    if (ai[i] === undefined || bi[i] === undefined) return ai[i] === undefined ? -1 : 1;
    const an = /^\d+$/.test(ai[i]), bn = /^\d+$/.test(bi[i]);
    if (an && bn) return Number(ai[i]) - Number(bi[i]);
    if (an !== bn) return an ? -1 : 1;
    return ai[i] < bi[i] ? -1 : 1;
  }
  return 0;
}
export async function latestSupportedPackage(name, { major, minor, prerelease = false, signal, fetchImplementation = fetch } = {}) {
  const supported = version => releaseVersion(version) && (prerelease || !version.includes('-'))
    && (major === undefined || Number(version.split('.')[0]) === major)
    && (minor === undefined || Number(version.split('.')[1]) === minor);
  const request = async suffix => {
    const response = await fetchImplementation(`https://registry.npmjs.org/${encodeURIComponent(name)}${suffix}`, {
      signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(15000)]) : AbortSignal.timeout(15000),
      headers: { Accept: 'application/vnd.npm.install-v1+json' },
    });
    if (!response.ok) throw new Error('The package update source is unavailable.');
    if (!response.body) return response.json(); // Injected metadata fixtures.
    let bytes = 0; const chunks = [];
    for await (const chunk of response.body) {
      bytes += chunk.length;
      if (bytes > 32 * 1024 * 1024) throw new Error('The package update source returned too much data.');
      chunks.push(Buffer.from(chunk));
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  };
  const latest = (await request('/latest')).version;
  if (supported(latest) && !latest.includes('-')) return latest;
  const metadata = await request('');
  const versions = Object.keys(metadata.versions ?? {}).filter(supported).sort(compareVersions);
  // Prefer stable releases; Executor currently needs its published V2 beta line.
  const stable = versions.filter(version => !version.includes('-'));
  const selected = stable.at(-1) ?? versions.at(-1);
  if (!selected) throw new Error('No compatible package release is available.');
  return selected;
}
