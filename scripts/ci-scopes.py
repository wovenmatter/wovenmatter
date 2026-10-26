#!/usr/bin/env python3
"""Keep desktop source checks separate from companion/mobile and container work."""
import re
import sys

# Desktop sources also compiled by the iOS target. The classifier test checks
# this list against ios/project.yml so new shared sources cannot silently skip CI.
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
    def changed(pattern):
        return any(re.search(pattern, path) for path in paths)
    # Changes to the orchestrator must exercise every lane it controls.
    infrastructure = changed(r'^(\.github/workflows/ci\.yml|scripts/(test-changes\.sh|ci-scopes\.py|test-support/test_(ci_scopes|ios_runner)\.py))$')
    shared_desktop = any(path == source or path.startswith(source + '/')
                         for path in paths for source in IOS_DESKTOP_SOURCES)
    return dict(
        macos=changed(r'^(app/|shared/|ios/|integration/|default-agent/|harnesses/|scripts/|\.github/(workflows/|release-refresh\.json))'),
        # Integration consumes DashboardStore -> Client -> Core. Conservatively
        # cover package sources as the target graph evolves, plus its manifests
        # and lockfile. The companion job also compiles iOS shared desktop files.
        companion=infrastructure or shared_desktop or changed(r'^(shared/|ios/|integration/|default-agent/|harnesses/|app/App/(Services/Companion|Models/.*Companion)|app/Sources/|app/Package\.(swift|resolved)$|scripts/(test-companion|test-ios|build-ios))'),
        ios=infrastructure or shared_desktop or changed(r'^(shared/|ios/|integration/|default-agent/|harnesses/|scripts/(test-ios|build-ios))'),
        remote=infrastructure or changed(r'^(remote/|default-agent/|harnesses/|\.dockerignore$|scripts/(remote-workspace|scan-public-tree|test-container|test-remote-workspace)\.sh$)'),
        updates=changed(r'^(scripts/.*(release|update|sparkle|delta)|app/Updater/|app/App/Services/DesktopUpdater\.swift|\.github/(release-refresh\.json|workflows/(refresh-release|release)\.yml))'),
    )

if __name__ == '__main__':
    for name, enabled in scopes(sys.stdin.read().splitlines()).items():
        print(f'{name}={str(enabled).lower()}')
