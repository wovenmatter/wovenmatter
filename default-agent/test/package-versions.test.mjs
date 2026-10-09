import test from 'node:test';
import assert from 'node:assert/strict';
import { latestSupportedPackage, compareVersions } from '../src/package-versions.mjs';
const registry = (latest, versions) => async url => new Response(JSON.stringify(url.endsWith('/latest') ? { version: latest } : { versions: Object.fromEntries(versions.map(v => [v, {}])) }));
test('latest supported stable major remains available after upstream latest advances', async () => {
  assert.equal(await latestSupportedPackage('@opencode/cli', { major: 2, fetchImplementation: registry('3.0.0', ['1.9.9', '2.0.9', '2.0.26', '2.1.0-beta.1', '3.0.0']) }), '2.0.26');
  assert.equal(await latestSupportedPackage('claude-sdk', { major: 0, minor: 3, fetchImplementation: registry('0.4.0', ['0.3.284', '0.3.296', '0.4.0']) }), '0.3.296');
});
test('Executor uses newest V2 beta only while no stable V2 exists', async () => {
  const options = { major: 2, prerelease: true };
  assert.equal(await latestSupportedPackage('executor', { ...options, fetchImplementation: registry('1.6.10', ['1.6.10', '2.0.0-beta.9', '2.0.0-beta.12']) }), '2.0.0-beta.12');
  assert.equal(await latestSupportedPackage('executor', { ...options, fetchImplementation: registry('2.1.0-beta.1', ['2.0.0', '2.1.0-beta.1']) }), '2.0.0');
  assert.ok(compareVersions('2.0.0-beta-hotfix.1', '2.0.0-beta-hotfix.2') < 0);
  await assert.rejects(latestSupportedPackage('executor', { ...options, fetchImplementation: registry('3.0.0', ['3.0.0']) }), /compatible/);
});

test('version and package metadata request the response formats npm supports', async () => {
  const requests = [];
  const fetchImplementation = async (url, options) => {
    requests.push({ url, accept: options.headers.Accept });
    if (url.endsWith('/latest')) {
      if (options.headers.Accept !== 'application/json') return new Response(null, { status: 406 });
      return new Response(JSON.stringify({ version: '1.6.10' }));
    }
    assert.equal(options.headers.Accept, 'application/vnd.npm.install-v1+json');
    return new Response(JSON.stringify({ versions: { '2.0.0-beta.12': {} } }));
  };
  assert.equal(await latestSupportedPackage('executor', { major: 2, prerelease: true, fetchImplementation }), '2.0.0-beta.12');
  assert.equal(requests.length, 2);
});

test('deprecated historical releases do not displace the supported runtime channel', async () => {
  const fetchImplementation = async url => new Response(JSON.stringify(url.endsWith('/latest')
    ? { version: '2.0.0', deprecated: 'Published in error from a stale historical tag' }
    : { versions: {
      '2.0.0': { deprecated: 'Published in error from a stale historical tag' },
      '2.0.0-beta.12': {},
    } }));
  assert.equal(await latestSupportedPackage('executor', { major: 2, prerelease: true, fetchImplementation }), '2.0.0-beta.12');
});

test('Executor resolves the portable CLI rather than architecture-only package releases', async () => {
  const fetchImplementation = async url => new Response(JSON.stringify(url.endsWith('/latest')
    ? { version: '1.6.10', bin: { executor: 'bin/executor' } }
    : { versions: {
      '2.0.0-beta.9-win32-x64': { os: ['win32'], cpu: ['x64'] },
      '2.0.0-beta.12': { bin: { executor: 'bin.mjs' } },
    } }));
  assert.equal(await latestSupportedPackage('executor', { major: 2, prerelease: true, executable: 'executor', fetchImplementation }), '2.0.0-beta.12');
});
