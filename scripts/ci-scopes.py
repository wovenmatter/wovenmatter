#!/usr/bin/env python3
"""Keep desktop source checks separate from companion/mobile and container work."""
import re
import sys

def scopes(paths):
    def changed(pattern):
        return any(re.search(pattern, path) for path in paths)
    return dict(
        macos=changed(r'^(app/|shared/|ios/|integration/|default-agent/|harnesses/|scripts/|\.github/(workflows/|release-refresh\.json))'),
        companion=changed(r'^(shared/|ios/|integration/|default-agent/|harnesses/|app/App/(Services/Companion|Models/.*Companion)|app/Sources/WovenMatterClient/(Backend|Companion)|scripts/(test-companion|test-ios|build-ios))'),
        ios=changed(r'^(shared/|ios/|integration/|default-agent/|harnesses/|scripts/(test-ios|build-ios))'),
        remote=changed(r'^(remote/|default-agent/|harnesses/|\.dockerignore$|scripts/(remote-workspace|scan-public-tree|test-container|test-remote-workspace)\.sh$)'),
        updates=changed(r'^(scripts/.*(release|update|sparkle|delta)|app/App/Services/DesktopUpdater\.swift|\.github/(release-refresh\.json|workflows/(refresh-release|release)\.yml))'),
    )

if __name__ == '__main__':
    for name, enabled in scopes(sys.stdin.read().splitlines()).items():
        print(f'{name}={str(enabled).lower()}')
