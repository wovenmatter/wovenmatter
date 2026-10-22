import test from 'node:test';
import assert from 'node:assert/strict';
import { latestSupportedPackage, compareVersions, satisfiesRange, rangeFloor, selectPackageRelease } from '../src/package-versions.mjs';
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

test('Executor resolves the portable CLI rather than architecture-only package releases', async () => {
  const fetchImplementation = async url => new Response(JSON.stringify(url.endsWith('/latest')
    ? { version: '1.6.10', bin: { executor: 'bin/executor' } }
    : { versions: {
      '2.0.0-beta.9-win32-x64': { os: ['win32'], cpu: ['x64'] },
      '2.0.0-beta.12': { bin: { executor: 'bin.mjs' } },
    } }));
  assert.equal(await latestSupportedPackage('executor', { major: 2, prerelease: true, executable: 'executor', fetchImplementation }), '2.0.0-beta.12');
});

test('declared minimums have no upper cap; explicit caret and tilde limits still apply', () => {
  const cases = {
    '>=1.3.0': [['1.3.0', true], ['1.2.9', false], ['2.0.0', true], ['20.0.0', true], ['2.0.0-beta.1', false]],
    '>=0.3.306': [['0.3.306', true], ['0.3.305', false], ['0.4.0', true], ['1.0.0', true]],
    '^1.3.0': [['1.3.0', true], ['1.9.4', true], ['1.2.9', false], ['2.0.0', false], ['1.4.0-beta.1', false]],
    '^0.3.302': [['0.3.302', true], ['0.3.400', true], ['0.3.301', false], ['0.4.0', false], ['1.0.0', false]],
    '^0.0.3': [['0.0.3', true], ['0.0.4', false], ['0.0.2', false], ['0.1.0', false]],
    '~0.0.3': [['0.0.3', true], ['0.0.9', true], ['0.1.0', false]],
    '~1.4.2': [['1.4.9', true], ['1.5.0', false]],
    '314.0.7': [['314.0.7', true], ['314.0.8', false]],
  };
  for (const [range, versions] of Object.entries(cases)) for (const [version, expected] of versions) {
    assert.equal(satisfiesRange(version, range), expected, `${version} in ${range}`);
  }
  // Unsupported range forms fail closed instead of matching everything.
  for (const range of ['>1.0.0', '1.x', 'latest', '*', '', undefined]) assert.equal(satisfiesRange('1.0.0', range), false, String(range));
  assert.equal(rangeFloor('>=0.3.306'), '0.3.306');
});

test('a minimum selects the newest stable major even when the latest tag lags', async () => {
  const fetchImplementation = async () => new Response(JSON.stringify({ versions: {
    '1.3.0': {}, '2.0.0': {}, '3.0.0': { deprecated: 'withdrawn' }, '4.0.0-beta.1': {},
  }, 'dist-tags': { latest: '1.3.0' } }));
  assert.deepEqual(await selectPackageRelease('sdk', { range: '>=1.3.0', fetchImplementation }), { selected: '2.0.0', latest: '2.0.0' });
});

test('range selection returns the newest compatible release and the newer blocked line', async () => {
  const fetchImplementation = registry('2.1.0', ['1.3.0', '1.4.2', '1.5.0-beta.1', '2.0.0', '2.1.0']);
  assert.deepEqual(await selectPackageRelease('sdk', { range: '^1.3.0', fetchImplementation }), { selected: '1.4.2', latest: '2.1.0' });
  assert.deepEqual(await selectPackageRelease('sdk', { range: '^2.0.0', fetchImplementation }), { selected: '2.1.0', latest: '2.1.0' });
  await assert.rejects(selectPackageRelease('sdk', { range: '^3.0.0', fetchImplementation }), /compatible/);
});
