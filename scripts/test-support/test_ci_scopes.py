"""CI routing regression cases: keep native coverage without unrelated fanout."""
import importlib.util
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('scopes', ROOT / 'scripts/ci-scopes.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def active(*paths):
    return {name for name, enabled in module.scopes(paths).items() if enabled and name != 'desktop'}


assert active('README.md', 'docs/guide/notes-and-data.md') == set()
assert active('app/App/Views/SettingsGeneralView.swift') == {'macos'}
assert active('app/Sources/WovenMatterClient/LocalACPManagedRuntime.swift') == {'macos', 'companion'}
assert active('app/Package.resolved') == {'macos', 'companion'}
assert active('shared/Sources/Protocol.swift') == {'macos', 'companion', 'ios'}
assert active('integration/Sources/Client.swift') == {'macos', 'companion'}
assert active('ios/App/Views/ConversationView.swift') == {'ios'}
assert active('default-agent/src/runtime.mjs') == {'macos', 'agent', 'service', 'pi'}
assert active('default-agent/package-lock.json') == {'macos', 'remote', 'agent', 'service', 'pi'}
assert active('remote/src/server.mjs') == {'service', 'scripts'}
for path in ['remote/Dockerfile', 'remote/Executor.Dockerfile', 'remote/entrypoint.sh',
             'remote/security/build-backports.py', 'remote/npm-runtime/package-lock.json',
             'remote/executor-runtime/package-lock.json']:
    assert active(path) == {'remote', 'service', 'scripts'}, (path, active(path))
assert active('.dockerignore') == {'remote', 'service'}
assert active('app/App/Services/CompanionCommandService.swift') == {'macos', 'companion'}
assert active('app/App/Services/DesktopUpdater.swift') == {'macos', 'updates'}
assert active('app/Updater/sparkle-version.json') == {'macos', 'updates', 'scripts'}
assert active('scripts/test-support/test_ios_runner.py') == {'ios', 'scripts'}
assert active('.github/workflows/release-cache.yml') == {'scripts'}
assert active('scripts/build-ios-pi-runtime.mjs') == {'ios', 'pi', 'scripts'}
assert active('scripts/build-ios-embedded-runtime.mjs') == {'ios', 'embedded', 'scripts'}
assert active('ios/Sources/EmbeddedExecution/Resources/provenance.json') == {'macos', 'companion', 'ios', 'embedded'}
assert active('ios/Sources/CompanionClient/Client.swift') == {'macos', 'companion', 'ios'}
for path in ['app/App/Views/SettingsGeneralView.swift', 'app/Sources/WovenMatterCore/Workspace.swift',
             'shared/Sources/Protocol.swift', 'default-agent/src/runtime.mjs']:
    assert module.scopes([path])['desktop'], path
for path in ['integration/Tests/ClientTests.swift', 'ios/App/Views/ConversationView.swift',
             'ios/Sources/CompanionClient/Client.swift', 'remote/src/server.mjs', 'README.md']:
    assert not module.scopes([path])['desktop'], path

# A rename must consider both deleted and added names (git diff --no-renames).
assert active('remote/src/server.mjs', 'remote/lib/server.mjs') == {'remote', 'service', 'scripts'}
assert active('README.md', 'remote/src/server.mjs', 'app/App/Views/SettingsGeneralView.swift') == {'macos', 'service', 'scripts'}
assert module.scopes(iter(['remote/src/server.mjs'])) == module.scopes(['remote/src/server.mjs'])

project = (ROOT / 'ios/project.yml').read_text()
desktop_sources = set(re.findall(r'^\s*-\s*path:\s*[\"\']?\.\./(app/[^\s\"\'#]+)', project, re.MULTILINE))
assert desktop_sources == module.IOS_DESKTOP_SOURCES, (desktop_sources, module.IOS_DESKTOP_SOURCES)
for path in desktop_sources:
    assert active(path) >= {'macos', 'ios'}, path
assert active('app/App/SharedAssets.xcassets/AccentColor.colorset/Contents.json') == {'macos', 'ios'}
assert active('app/App/Views/DashboardStyle.swift.backup') == {'macos'}

for path in ['.github/workflows/ci.yml', 'scripts/test-changes.sh', 'scripts/test-ci.sh',
             'scripts/ci-scopes.py', 'scripts/test-support/test_ci_scopes.py',
             'scripts/test-support/test_ci_runner.py']:
    assert active(path) == {'macos', 'companion', 'ios', 'remote', 'agent', 'service', 'pi', 'embedded', 'scripts'}, path

print('CI scopes passed: portable tests once; native, mobile and image inputs retain validation.')
