import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location('scopes', Path(__file__).resolve().parents[1] / 'ci-scopes.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

updater = module.scopes(['app/App/Services/DesktopUpdater.swift', 'app/App/Views/SettingsGeneralView.swift',
                        'scripts/stage-update.py', '.github/workflows/release.yml', '.github/workflows/ci.yml',
                        '.github/release-refresh.json', 'scripts/test-changes.sh'])
assert updater == dict(macos=True, companion=False, ios=False, remote=False, updates=True), updater
for path in ['ios/App/Views/ConversationView.swift', 'shared/Sources/Protocol.swift', 'integration/Sources/Client.swift', 'default-agent/src/runtime.mjs', 'harnesses/catalog.json']:
    value = module.scopes([path])
    assert value['macos'] and value['companion'] and value['ios'], (path, value)
assert module.scopes(['app/App/Services/CompanionCommandService.swift'])['companion']
assert module.scopes(['remote/Dockerfile'])['remote']
assert not module.scopes(['README.md'])['macos']
print('CI scopes passed: desktop updater skips mobile/containers; shared/mobile changes retain their validation.')
