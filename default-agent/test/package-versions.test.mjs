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
