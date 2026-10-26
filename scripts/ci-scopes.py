#!/usr/bin/env python3
"""Scope portable tests and native/image validation to their actual inputs."""
import re
import sys

# Keep this contract synchronized with the iOS target's desktop sources.
IOS_DESKTOP_SOURCES = frozenset({
    'app/App/Views/DashboardStyle.swift',
    'app/App/Views/DashboardColors.swift',
    'app/App/Models/ConversationMarkdownDocument.swift',
    'app/App/Views/ConversationResponse.swift',
    'app/App/Views/ConversationHTMLRenderView.swift',
    'app/Sources/WovenMatterCore/ConversationHTMLRender.swift',
    'app/Sources/WovenMatterCore/AgentRunActivity.swift',
    'app/Sources/WovenMatterCore/AssistantTranscriptProjection.swift',
    'app/Sources/WovenMatterCore/ConversationWorkTimeline.swift',
    'app/Sources/WovenMatterCore/ProgramStatus.swift',
    'app/Sources/WovenMatterCore/WorkspaceHistory.swift',
    'app/App/Models/ConversationMessageLayout.swift',
    'app/App/Models/ConversationTranscriptState.swift',
    'app/App/Views/ConversationWorkTranscript.swift',
    'app/App/Views/ConversationSubagentRow.swift',
    'app/App/SharedAssets.xcassets',
})


def scopes(paths):
    paths = tuple(paths)

    def changed(pattern):
        return any(re.search(pattern, path) for path in paths)

    infrastructure = changed(
        r'^(\.github/workflows/ci\.yml|scripts/(test-changes\.sh|test-ci\.sh|'
        r'ci-scopes\.py|test-support/test_ci_(scopes|runner)\.py))$')
    shared_desktop = any(path == source or path.startswith(source + '/')
                         for path in paths for source in IOS_DESKTOP_SOURCES)
    agent = infrastructure or changed(r'^(default-agent/|harnesses/)')
    ios = infrastructure or shared_desktop or changed(
        r'^(shared/|ios/|scripts/(test-ios\.sh|build-ios[^/]*|test-support/test_ios_runner\.py)$)')
    companion = infrastructure or changed(
        r'^(shared/|integration/|ios/Sources/|app/Sources/|app/Package\.(swift|resolved)$|'
        r'app/App/(Services/Companion|Models/.*Companion)|'
        r'scripts/test-companion[^/]*$)')
    # JavaScript changes are tested once on Linux. Image builds exercise packaging
    # inputs, including everything installed/copied by the Dockerfiles.
    containers = infrastructure or changed(
        r'^(remote/(?!src/|test/)|default-agent/(package[^/]*\.json$|\.node-version$)|'
        r'harnesses/|\.dockerignore$|scripts/(test-container\.sh|'
        r'test-support/(test-executor-(image\.sh|runtime\.mjs)|summarize-trivy\.py))$)')
    updates = changed(r'^(scripts/.*(release|update|sparkle|delta)|app/Updater/|'
                      r'app/App/Services/DesktopUpdater\.swift|'
                      r'\.github/(release-refresh\.json|workflows/(refresh-release|release)\.yml))')
    native_scripts = changed(
        r'^scripts/(test-(app-termination|composer-text-editor|conversation-layout|appearance|'
        r'note-editor|note-drafts|embedded-runtime-macos|application-usage|backend-process|'
        r'desktop-updater)\.sh|test-support/[^/]+\.swift|build_and_run\.sh|'
        r'prepare-(browser|default-agent|sparkle-tools)\.sh|validate-native-app\.sh|'
        r'browser-build-cache\.py|cached-download\.py)$')
    desktop = infrastructure or shared_desktop or agent or updates or native_scripts or changed(
        r'^(app/|shared/|ios/(EmbeddedRuntime/|Sources/EmbeddedExecution/))')
    return dict(
        macos=desktop or companion,
        desktop=desktop,
        companion=companion,
        ios=ios,
        remote=containers,
        updates=updates,
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
