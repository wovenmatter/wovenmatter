"""Portable CI selection never starts native, simulator or image validation."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('scopes', ROOT / 'scripts/ci-scopes.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def active(*paths):
    return {name for name, enabled in module.scopes(paths).items() if enabled}


for path in ['README.md', 'docs/guide/notes-and-data.md', 'app/App/Views/SettingsGeneralView.swift',
             'app/Sources/WovenMatterCore/Workspace.swift', 'app/Package.resolved',
             'shared/Sources/Protocol.swift', 'integration/Tests/ClientTests.swift',
             'ios/App/Views/ConversationView.swift', 'ios/Sources/CompanionClient/Client.swift']:
    assert active(path) == set(), (path, active(path))
for path in ['default-agent/src/runtime.mjs', 'default-agent/package-lock.json', 'harnesses/catalog.json']:
    assert active(path) == {'agent', 'service', 'pi'}, (path, active(path))
for path in ['remote/src/server.mjs', 'remote/Dockerfile', 'remote/Executor.Dockerfile',
             'remote/entrypoint.sh', 'remote/security/build-backports.py',
             'remote/npm-runtime/package-lock.json', 'remote/executor-runtime/package-lock.json']:
    assert active(path) == {'service', 'scripts'}, (path, active(path))
assert active('.dockerignore') == {'service'}
assert active('app/Updater/sparkle-version.json') == {'scripts'}
assert active('scripts/test-support/test_ios_runner.py') == {'scripts'}
assert active('.github/workflows/release-cache.yml') == {'scripts'}
assert active('scripts/build-ios-pi-runtime.mjs') == {'pi', 'scripts'}
assert active('scripts/build-ios-embedded-runtime.mjs') == {'embedded', 'scripts'}
assert active('ios/Sources/EmbeddedExecution/Resources/provenance.json') == {'embedded'}
assert active('ios/Sources/PiDurableRuntime/Resources/provenance.json') == {'pi'}
assert active('ios/Sources/CompanionInference/PiSDKVersion.swift') == {'pi'}
assert active('scripts/test-support/native-mcp.test.mjs') == {'agent', 'scripts'}
assert active('README.md', 'remote/src/server.mjs', 'app/App/Views/SettingsGeneralView.swift') == {'service', 'scripts'}
assert module.scopes(iter(['remote/src/server.mjs'])) == module.scopes(['remote/src/server.mjs'])

portable = {'agent', 'service', 'pi', 'embedded', 'scripts'}
assert set(module.scopes([])) == portable
for path in ['.github/workflows/ci.yml', '.github/workflows/validation.yml',
             'scripts/test-changes.sh', 'scripts/test-ci.sh', 'scripts/ci-scopes.py',
             'scripts/test-support/test_ci_scopes.py', 'scripts/test-support/test_ci_runner.py']:
    assert active(path) == portable, path

print('CI scopes passed: one portable PR check; platform validation is manual.')
