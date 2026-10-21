import importlib.util
import re
from pathlib import Path
spec = importlib.util.spec_from_file_location('scopes', Path(__file__).resolve().parents[1] / 'ci-scopes.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

updater = module.scopes(['app/App/Services/DesktopUpdater.swift', 'app/App/Views/SettingsGeneralView.swift',
                        'scripts/stage-update.py', '.github/workflows/release.yml',
                        '.github/release-refresh.json'])
assert updater == dict(macos=True, companion=False, ios=False, remote=False, updates=True), updater
# The updater's downloader and dependency lockfile are package changes, and
# therefore require integration coverage even though the UI itself is desktop.
updater_package = module.scopes(['app/Sources/WovenMatterClient/LocalACPManagedRuntime.swift',
                                'app/Package.resolved', 'app/App/Services/DesktopUpdater.swift'])
assert updater_package == dict(macos=True, companion=True, ios=False, remote=False, updates=True), updater_package
for path in ['app/Sources/WovenMatterDashboardStore/CompanionService.swift',
             'app/Sources/WovenMatterClient/LocalACPManagedRuntime.swift',
             'app/Sources/WovenMatterCore/Workspace.swift',
             'app/Sources/WovenMatterAutomation/Automation.swift',
             'app/Package.swift', 'app/Package.resolved']:
    assert module.scopes([path])['companion'], path
for path in ['ios/App/Views/ConversationView.swift', 'shared/Sources/Protocol.swift', 'integration/Sources/Client.swift', 'default-agent/src/runtime.mjs', 'harnesses/catalog.json']:
    value = module.scopes([path])
    assert value['macos'] and value['companion'] and value['ios'], (path, value)
assert module.scopes(['app/App/Services/CompanionCommandService.swift'])['companion']
assert module.scopes(['remote/Dockerfile'])['remote']
assert not module.scopes(['README.md'])['macos']
# Keep the explicit classifier contract synchronized with XcodeGen's shared
# desktop inputs, including directories whose children are changed by git.
project = (Path(__file__).resolve().parents[2] / 'ios/project.yml').read_text()
desktop_sources = set(re.findall(r'^\s*-\s*path:\s*[\"\']?\.\./(app/[^\s\"\'#]+)', project, re.MULTILINE))
assert desktop_sources == module.IOS_DESKTOP_SOURCES, (desktop_sources, module.IOS_DESKTOP_SOURCES)
for path in desktop_sources:
    assert module.scopes([path])['ios'], path
    assert module.scopes([path])['companion'], path
asset = 'app/App/SharedAssets.xcassets/AccentColor.colorset/Contents.json'
assert module.scopes([asset])['ios'], asset
assert not module.scopes(['app/App/Views/DashboardStyle.swift.backup'])['ios']

for path in ['.github/workflows/ci.yml', 'scripts/test-changes.sh', 'scripts/ci-scopes.py',
             'scripts/test-support/test_ci_scopes.py', 'scripts/test-support/test_ios_runner.py']:
    assert module.scopes([path]) == dict(macos=True, companion=True, ios=True, remote=True, updates=False), path

print('CI scopes passed: desktop UI stays scoped; orchestrator changes exercise every lane.')
