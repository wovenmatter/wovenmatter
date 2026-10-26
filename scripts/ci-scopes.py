#!/usr/bin/env python3
"""Select portable suites for the single automatic PR check."""
import re
import sys


def scopes(paths):
    paths = tuple(paths)

    def changed(pattern):
        return any(re.search(pattern, path) for path in paths)

    infrastructure = changed(
        r'^(\.github/workflows/(ci|validation)\.yml|scripts/(test-changes\.sh|'
        r'test-ci\.sh|ci-scopes\.py|test-support/test_ci_(scopes|runner)\.py))$')
    agent = infrastructure or changed(r'^(default-agent/|harnesses/)')
    return dict(
        agent=agent or changed(r'^scripts/test-support/native-mcp\.test\.mjs$'),
        service=agent or changed(r'^(remote/|\.dockerignore$|scripts/(remote-workspace|'
                                r'test-remote-workspace|test-container)\.sh$)'),
        pi=agent or changed(r'^(ios/Runtime/|ios/Sources/PiDurableRuntime/Resources/|'
                            r'ios/Sources/CompanionInference/PiSDKVersion\.swift$|'
                            r'scripts/build-ios-pi-runtime\.mjs$|THIRD_PARTY_NOTICES\.md$)'),
        embedded=infrastructure or changed(r'^(ios/EmbeddedRuntime/|'
                                          r'ios/Sources/EmbeddedExecution/Resources/|'
                                          r'scripts/build-ios-embedded-runtime\.mjs$)'),
        scripts=infrastructure or changed(r'^(scripts/|remote/|app/Updater/|'
                                         r'\.github/workflows/|\.github/release-refresh\.json$)'),
    )


if __name__ == '__main__':
    for name, enabled in scopes(sys.stdin.read().splitlines()).items():
        print(f'{name}={str(enabled).lower()}')
