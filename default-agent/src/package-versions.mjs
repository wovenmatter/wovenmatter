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
// The dependency declarations are the compatibility policy. Only the forms used
// by this repository are accepted, so an unexpected range fails closed.
export function satisfiesRange(version, range) {
  const match = /^(>=|[~^]?)(\d+)\.(\d+)\.(\d+)$/.exec(range ?? '');
  if (!match || !releaseVersion(version) || version.includes('-')) return false;
  const [, operator, major, minor] = match, floor = range.slice(operator.length);
  const [vMajor, vMinor] = version.split('.').map(Number);
  if (compareVersions(version, floor) < 0) return false;
  if (operator === '>=') return true;
  // npm caret semantics: the first nonzero component is the compatibility line.
  if (!operator || (operator === '^' && Number(major) === 0 && Number(minor) === 0)) return version === floor;
  if (operator === '~' || Number(major) === 0) return vMajor === Number(major) && vMinor === Number(minor);
  return vMajor === Number(major);
}
export const rangeFloor = range => /^(?:>=|[~^]?)(\d+\.\d+\.\d+)$/.exec(range ?? '')?.[1] ?? null;

async function registry(name, suffix, { signal, fetchImplementation = fetch }) {
  const response = await fetchImplementation(`https://registry.npmjs.org/${encodeURIComponent(name)}${suffix}`, {
    signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(15000)]) : AbortSignal.timeout(15000),
    headers: { Accept: suffix ? 'application/json' : 'application/vnd.npm.install-v1+json' },
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
}
const usable = (metadata, executable) => metadata && !metadata.deprecated && (executable === undefined
  || typeof metadata.bin === 'string' || typeof metadata.bin?.[executable] === 'string');

// Returns the newest release accepted by the constraints and the newest stable
// upstream release, so a blocked newer line is reported rather than hidden.
// Several names (an SDK family) select one version published by all of them.
export async function selectPackageRelease(names, { range, major, minor, minimum, prerelease = false, executable, signal, fetchImplementation = fetch } = {}) {
  names = [names].flat();
  const supported = version => releaseVersion(version) && (prerelease || !version.includes('-'))
    && (range === undefined || satisfiesRange(version, range))
    && (major === undefined || Number(version.split('.')[0]) === major)
    && (minor === undefined || Number(version.split('.')[1]) === minor)
    && (minimum === undefined || compareVersions(version, minimum) >= 0);
  // A dist-tag can lag a newer stable publication. Select from version metadata
  // so "latest" means the newest eligible nondeprecated release.
  let common;
  for (const name of names) {
    const metadata = await registry(name, '', { signal, fetchImplementation });
    const versions = Object.keys(metadata.versions ?? {}).filter(version => releaseVersion(version) && usable(metadata.versions[version], executable));
    common = common ? common.filter(version => versions.includes(version)) : versions;
  }
  common.sort(compareVersions);
  const candidates = common.filter(supported);
  // Prefer stable releases; Executor currently needs its published V2 beta line.
  const selected = candidates.filter(version => !version.includes('-')).at(-1) ?? candidates.at(-1);
  if (!selected) throw new Error('No compatible package release is available.');
  const newest = common.filter(version => !version.includes('-')).at(-1);
  return { selected, latest: newest && compareVersions(newest, selected) > 0 ? newest : selected };
}
export async function latestSupportedPackage(name, options = {}) {
  return (await selectPackageRelease(name, options)).selected;
}
