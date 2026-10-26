import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WovenMatterClient
import WovenMatterCore

enum WorkspaceListMode: String, CaseIterable {
    case chats
    case notes
}

enum CompactDrawer: Equatable {
    case none
    case left
    case right
}

extension DashboardSidebarSide {
    var compactDrawer: CompactDrawer {
        switch self {
        case .left: .left
        case .right: .right
        }
    }
}

enum CompactWorkspacePane: Equatable {
    case chat
    case note
}

enum DashboardAgentMoveScope {
    case pinned
    case stored(String)
}

enum DashboardPinnedAgentsStore {
    static let storageKey = "wovenmatter.dashboard.pinned-agent-ids"

    static func decode(_ raw: String) -> [UUID] {
        guard let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        var seen = Set<UUID>()
        return values.compactMap { UUID(uuidString: $0) }.filter { seen.insert($0).inserted }
    }

    static func encode(_ ids: [UUID]) -> String {
        let values = ids.map { $0.uuidString.lowercased() }
        guard let data = try? JSONEncoder().encode(values),
              let raw = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return raw
    }

    static func toggle(id: UUID, in raw: inout String) {
        var ids = decode(raw)
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
        raw = encode(ids)
    }
}

struct DashboardFolderSections {
    let pinned: [WorkspaceFolderRecord]
    let unpinned: [WorkspaceFolderRecord]

    init(folders: [WorkspaceFolderRecord]) {
        let sorted = folders.sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            let nameComparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
            return $0.id < $1.id
        }
        pinned = sorted.filter(\.isPinned)
        unpinned = sorted.filter { !$0.isPinned }
    }
}

struct DashboardSidebarActions {
    let onCollapse: (DashboardSidebarSide) -> Void
    let onMoveSingleRail: () -> Void
    let onShowNavigation: () -> Void
    let onUtility: (DashboardDestination) -> Void
    let onSelectAgent: (UUID) -> Void
    let onCreateAgentChat: (UUID) -> Void
    let onSelectRemoteAgent: (RemoteHarnessChatTarget) -> Void
    let onStartRemoteChat: (RemoteHarnessChatTarget) -> Void
    let onSelectFolder: (String?) -> Void
    let onSelectConversation: (String) -> Void
    let onSelectNote: (String) -> Void
    let onCreateAgent: () -> Void
    let onCreateConversation: () -> Void
    let onCreateNote: () -> Void
    let onCreateFolder: (String, UUID?, URL?) -> Void
    let onRenameFolder: (String, String) -> Void
    let onSetFolderPinned: (String, Bool) -> Void
    let onMoveFolder: (String, WorkspaceFolderMoveDirection) -> Void
    let onDeleteFolder: (String, Bool) -> Void
    let onSetFolderReferencePaths: (String, [String]) -> Void
    let onCreateChatInFolder: (String?) -> Void
    let onShowTrash: () -> Void
    let onConversationAction: (WorkspaceConversationRecord, DashboardConversationMenuAction) -> Void
    let onNoteAction: (WorkspaceNoteRecord, DashboardNoteMenuAction) -> Void
    let onUnavailableMutation: (String) -> Void
}

struct DashboardSidebarRail: View {
    let side: DashboardSidebarSide
    let page: DashboardSidebarPage
    let style: DashboardSidebarStyle
    let adaptiveExpanded: Bool
    let agents: [WorkspaceAgent]
    let navigationAgents: [WorkspaceAgent]
    let remoteWorkspaces: RemoteWorkspacesModel
    let localWorkspaceReady: Bool
    let localExecutionWorkspaceID: String?
    let folders: [WorkspaceFolderRecord]
    let conversations: [WorkspaceConversationRecord]
    let notes: [WorkspaceNoteRecord]
    let runningConversationIDs: Set<String>
    let selectedAgentID: UUID?
    let selectedFolderID: String?
    let selectedConversationID: String?
    let selectedNoteID: String?
    let destination: DashboardDestination
    let contentRevision: Int64
    @Binding var pinnedAgentIDsRaw: String
    @Binding var agentOrderRaw: String
    @Binding var agentDisclosureRaw: String
    let actions: DashboardSidebarActions
    let onSurfaceProfileChange: () -> Void

    var body: some View {
        Group {
            switch page {
            case .navigation:
                navigationPage
            case .workspace:
                workspacePage
            }
        }
        .environment(\.dashboardSidebarForeground, DashboardPalette.foreground)
        .foregroundStyle(DashboardPalette.foreground)
        .tint(DashboardPalette.foreground)
    }

    private var navigationPage: some View {
        DashboardSidebarNavigationPage(
            side: side,
            agents: navigationAgents,
            remoteWorkspaces: remoteWorkspaces,
            localWorkspaceReady: localWorkspaceReady,
            localExecutionWorkspaceID: localExecutionWorkspaceID,
            folders: folders,
            conversations: conversations,
            notes: notes,
            runningConversationIDs: runningConversationIDs,
            selectedAgentID: selectedAgentID,
            selectedFolderID: selectedFolderID,
            selectedConversationID: selectedConversationID,
            destination: destination,
            pinnedAgentIDsRaw: $pinnedAgentIDsRaw,
            agentOrderRaw: $agentOrderRaw,
            agentDisclosureRaw: $agentDisclosureRaw,
            onCollapse: adaptiveExpanded ? nil : { actions.onCollapse(side) },
            onMove: style == .split ? nil : actions.onMoveSingleRail,
            onUtility: actions.onUtility,
            onSelectAgent: actions.onSelectAgent,
            onCreateAgentChat: actions.onCreateAgentChat,
            onSelectRemoteAgent: actions.onSelectRemoteAgent,
            onStartRemoteChat: actions.onStartRemoteChat,
            onSelectFolder: actions.onSelectFolder,
            onSelectConversation: actions.onSelectConversation,
            onSelectNote: actions.onSelectNote,
            onCreateAgent: actions.onCreateAgent,
            onCreateConversation: actions.onCreateConversation,
            onCreateNote: actions.onCreateNote,
            onCreateFolder: actions.onCreateFolder,
            onRenameFolder: actions.onRenameFolder,
            onSetFolderPinned: actions.onSetFolderPinned,
            onMoveFolder: actions.onMoveFolder,
            onDeleteFolder: actions.onDeleteFolder,
            onSetFolderReferencePaths: actions.onSetFolderReferencePaths,
            onCreateChatInFolder: actions.onCreateChatInFolder,
            onShowTrash: actions.onShowTrash,
            onConversationAction: actions.onConversationAction,
            onNoteAction: actions.onNoteAction,
            onUnavailableMutation: actions.onUnavailableMutation
        )
    }

    private var workspacePage: some View {
        DashboardSidebarWorkspacePage(
            side: side,
            conversations: scopedConversations,
            notes: scopedNotes,
            runningConversationIDs: runningConversationIDs,
            agents: agents,
            folders: folders,
            contentRevision: contentRevision,
            contentScopeID: selectedFolderID,
            selectedConversationID: selectedConversationID,
            selectedNoteID: selectedNoteID,
            selectedFolderName: folders.first(where: { $0.id == selectedFolderID })?.name,
            onCollapse: { actions.onCollapse(side) },
            onBack: style == .split ? nil : actions.onShowNavigation,
            onMove: style == .single ? actions.onMoveSingleRail : nil,
            showsQuickActions: !adaptiveExpanded,
            onCreateChat: actions.onCreateConversation,
            onCreateNote: actions.onCreateNote,
            onSelectConversation: actions.onSelectConversation,
            onSelectNote: actions.onSelectNote,
            onConversationAction: actions.onConversationAction,
            onNoteAction: actions.onNoteAction,
            onSurfaceProfileChange: onSurfaceProfileChange
        )
    }

    private var scopedConversations: [WorkspaceConversationRecord] {
        conversations.filter { conversation in
            return selectedFolderID == nil || conversation.folderID == selectedFolderID
        }
    }

    private var scopedNotes: [WorkspaceNoteRecord] {
        notes.filter { note in
            selectedFolderID == nil || note.folderID == selectedFolderID
        }
    }
}

struct DashboardSidebarNavigationPage: View {
    @Environment(\.dashboardTheme) private var theme
    let side: DashboardSidebarSide
    let agents: [WorkspaceAgent]
    let remoteWorkspaces: RemoteWorkspacesModel
    let localWorkspaceReady: Bool
    let localExecutionWorkspaceID: String?
    let folders: [WorkspaceFolderRecord]
    let conversations: [WorkspaceConversationRecord]
    let notes: [WorkspaceNoteRecord]
    let runningConversationIDs: Set<String>
    let selectedAgentID: UUID?
    let selectedFolderID: String?
    let selectedConversationID: String?
    let destination: DashboardDestination
    @Binding var pinnedAgentIDsRaw: String
    @Binding var agentOrderRaw: String
    @Binding var agentDisclosureRaw: String
    let onCollapse: (() -> Void)?
    let onMove: (() -> Void)?
    let onUtility: (DashboardDestination) -> Void
    let onSelectAgent: (UUID) -> Void
    let onCreateAgentChat: (UUID) -> Void
    let onSelectRemoteAgent: (RemoteHarnessChatTarget) -> Void
    let onStartRemoteChat: (RemoteHarnessChatTarget) -> Void
    let onSelectFolder: (String?) -> Void
    let onSelectConversation: (String) -> Void
    let onSelectNote: (String) -> Void
    let onCreateAgent: () -> Void
    let onCreateConversation: () -> Void
    let onCreateNote: () -> Void
    let onCreateFolder: (String, UUID?, URL?) -> Void
    let onRenameFolder: (String, String) -> Void
    let onSetFolderPinned: (String, Bool) -> Void
    let onMoveFolder: (String, WorkspaceFolderMoveDirection) -> Void
    let onDeleteFolder: (String, Bool) -> Void
    let onSetFolderReferencePaths: (String, [String]) -> Void
    let onCreateChatInFolder: (String?) -> Void
    let onShowTrash: () -> Void
    let onConversationAction: (WorkspaceConversationRecord, DashboardConversationMenuAction) -> Void
    let onNoteAction: (WorkspaceNoteRecord, DashboardNoteMenuAction) -> Void
    let onUnavailableMutation: (String) -> Void

    @AppStorage(DashboardWorkspaceSidebarVisibility.localWorkspace.storageKey)
    private var showsLocalWorkspace = true
    @AppStorage(DashboardWorkspaceSidebarVisibility.remoteWorkspaces.storageKey)
    private var showsRemoteWorkspaces = true

    @State private var browserWorkspace: RemoteWorkspaceConfiguration?
    @State private var presentedFolderID: String?
    @State private var recentsOpen = true
    @State private var scrollHoverCoordinator = DashboardScrollHoverCoordinator()
    @State private var creatingFolderWorkspaceKey: String?
    @State private var renamingFolderID: String?
    @State private var renamedFolderName = ""
    @State private var deletingFolder: WorkspaceFolderRecord?
    @State private var editingReferenceFolderID: String?

    private var pinnedAgentOrder: [UUID] {
        DashboardPinnedAgentsStore.decode(pinnedAgentIDsRaw)
    }

    private var pinnedAgentIDs: Set<UUID> {
        Set(pinnedAgentOrder)
    }

    private var remoteWorkspaceLinks: [DashboardRemoteWorkspaceSidebarLink] {
        DashboardRemoteWorkspaceSidebarModel.links(
            workspaces: remoteWorkspaces.workspaces,
            readyTargets: remoteWorkspaces.readyChatTargets
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            railHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    topActions
                    allWorkspacesRow
                    workspacesSection
                    trashRow
                    recentsSection
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
            .environment(\.dashboardScrollHoverCoordinator, scrollHoverCoordinator)
            .onScrollPhaseChange { _, phase in
                scrollHoverCoordinator.setScrolling(phase.isScrolling)
            }
        }
        .sheet(item: $browserWorkspace) { configuration in
            RemoteBrowserView(workspaces: remoteWorkspaces, configuration: configuration)
        }
    }

    private var mirrorsHeader: Bool {
        side == .right && onMove != nil
    }

    private var railHeader: some View {
        HStack(spacing: 8) {
            if mirrorsHeader {
                collapseButton
                moveButton
                Spacer()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Workspaces")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(remoteWorkspaceLinks.count + 1) \(remoteWorkspaceLinks.isEmpty ? "workspace" : "workspaces")")
                .font(.system(size: 11))
                .foregroundStyle(DashboardPalette.foreground)
            }
            if !mirrorsHeader {
                Spacer()
                moveButton
                collapseButton
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 68)
    }

    @ViewBuilder
    private var moveButton: some View {
        if let onMove {
            Button(action: onMove) {
                DashboardLucideIcon(glyph: .arrowLeftRight, size: 16)
                    .frame(
                        width: onCollapse == nil ? 36 : 32,
                        height: onCollapse == nil ? 36 : 32
                    )
            }
            .buttonStyle(DashboardIconButtonStyle())
            .help(side == .left ? "Move sidebar right" : "Move sidebar left")
        }
    }

    @ViewBuilder
    private var collapseButton: some View {
        if let onCollapse {
            Button(action: onCollapse) {
                DashboardLucideIcon(
                    glyph: side == .left ? .leftCollapse : .rightCollapse,
                    size: 18
                )
                .frame(width: 36, height: 36)
            }
            .buttonStyle(DashboardIconButtonStyle())
            .help("Hide sidebar")
        }
    }

    private var topActions: some View {
        VStack(spacing: 1) {
            DashboardRailRow(icon: .squarePen, title: "New chat", hoverID: "action:new-chat") {
                onCreateConversation()
            }
            DashboardNewArtifactButton(action: onCreateNote)
            DashboardRailRow(
                icon: .calendarDays,
                title: "Calendar",
                hoverID: "destination:calendar",
                selected: destination == .calendar
            ) {
                onUtility(.calendar)
            }
            DashboardRailRow(
                icon: .calendarClock,
                title: "Scheduled Tasks",
                hoverID: "destination:cron-jobs",
                selected: destination == .cronJobs
            ) {
                onUtility(.cronJobs)
            }
            DashboardRailRow(
                icon: .libraryBig,
                title: "Library",
                hoverID: "destination:library",
                selected: destination == .library
            ) {
                onUtility(.library)
            }
            DashboardRailRow(
                icon: .database,
                title: "Databases",
                hoverID: "destination:databases",
                selected: destination == .databases
            ) {
                onUtility(.databases)
            }
            DashboardRailRow(
                icon: .barChart,
                title: "Usage",
                hoverID: "destination:usage",
                selected: destination == .usage
            ) {
                onUtility(.usage)
            }
            DashboardRailRow(
                icon: .settings,
                title: "Settings",
                hoverID: "destination:settings",
                selected: destination == .settings,
                iconColor: DashboardPalette.foreground
            ) {
                onUtility(.settings)
            }
        }
        .padding(.bottom, 10)
    }

    private var workspacesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsLocalWorkspace {
                let key = DashboardAgentDisclosureKey.localWorkspace
                agentDisclosureHeading(title: "Local agent workspace", key: key)
                if agentSectionExpanded(key) {
                    workspaceContents(
                        key: key,
                        title: "Local agent workspace",
                        workspaceAgents: agents.filter { $0.bucket == .localCLIAgents },
                        workspaceFolders: localExecutionWorkspaceID.map { owner in
                            folders.filter { $0.executionWorkspaceID == owner }
                        } ?? []
                    )
                }
            }
            if showsRemoteWorkspaces {
                let key = DashboardAgentDisclosureKey.remoteWorkspaces
                agentDisclosureHeading(title: "Remote agent workspaces", key: key)
                if agentSectionExpanded(key) {
                    if remoteWorkspaceLinks.isEmpty {
                        agentEmptyLabel("No remote workspaces yet")
                    }
                    ForEach(remoteWorkspaceLinks) { workspace in
                        remoteWorkspaceSection(workspace)
                    }
                }
            }
            // A disconnected workspace retains its captured folder ownership.
            ForEach(unavailableFolderOwnerIDs, id: \.self) { ownerID in
                let key = "unavailable-workspace:" + ownerID
                let title = "Unavailable workspace"
                agentDisclosureHeading(title: title, key: key)
                if agentSectionExpanded(key) {
                    workspaceContents(
                        key: key,
                        title: title, workspaceAgents: [],
                        workspaceFolders: folders.filter { ($0.executionWorkspaceID ?? "") == ownerID },
                        canCreateFolders: false
                    )
                }
            }
        }
    }

    private var unavailableFolderOwnerIDs: [String] {
        let known = Set(remoteWorkspaceLinks.map { "remote:" + $0.id.uuidString.lowercased() }
            + [localExecutionWorkspaceID].compactMap { $0 })
        return Set(folders.compactMap { $0.executionWorkspaceID }.filter { !$0.isEmpty }).subtracting(known).sorted()
    }

    @ViewBuilder
    private func workspaceContents(
        key: String,
        title: String,
        workspaceAgents: [WorkspaceAgent],
        workspaceFolders: [WorkspaceFolderRecord],
        remoteWorkspace: DashboardRemoteWorkspaceSidebarLink? = nil,
        canCreateFolders: Bool = true
    ) -> some View {
        let sections = DashboardFolderSections(folders: workspaceFolders)
        let counts = folderContentCounts
        let pinned = DashboardAgentSidebarGroup.applyOrder(
            workspaceAgents.filter { pinnedAgentIDs.contains($0.id) }, preferred: pinnedAgentOrder
        )
        let regular = DashboardAgentSidebarGroup.agents(
            from: workspaceAgents,
            in: remoteWorkspace == nil ? .localWorkspace : .remoteWorkspaces,
            pinnedIDs: pinnedAgentIDs,
            customOrder: DashboardAgentOrderStore.order(
                forKey: remoteWorkspace == nil ? DashboardAgentSidebarGroup.localWorkspace.orderKey : key,
                in: agentOrderRaw
            )
        )
        VStack(alignment: .leading, spacing: 0) {
            agentDisclosureHeading(title: "Agents", key: key + ":agents")
            if agentSectionExpanded(key + ":agents") {
                ForEach(pinned) { agent in
                    agentRow(agent, moveScope: .pinned, groupAgents: pinned, isPinned: true)
                }
                ForEach(regular) { agent in
                    agentRow(agent, moveScope: .stored(remoteWorkspace == nil
                        ? DashboardAgentSidebarGroup.localWorkspace.orderKey : key),
                        groupAgents: regular, isPinned: false)
                }
                if let remoteWorkspace {
                    let pendingTargets = remoteWorkspace.readyTargets.filter { remoteAgent(for: $0) == nil }
                    ForEach(pendingTargets) { target in
                        remoteTargetRow(target)
                    }
                    if pinned.isEmpty && regular.isEmpty && pendingTargets.isEmpty {
                        agentEmptyLabel(remoteWorkspaceEmptyLabel(remoteWorkspace))
                    }
                } else if pinned.isEmpty && regular.isEmpty {
                    agentEmptyLabel("No agents")
                }
            }
            agentDisclosureHeading(title: "Folders", key: key + ":folders")
            if agentSectionExpanded(key + ":folders") {
                if canCreateFolders {
                    newFolderRow(key: key, workspaceID: remoteWorkspace?.id, workspaceTitle: title)
                }
                ForEach(sections.pinned) { folder in
                    folderRow(folder, sectionFolders: sections.pinned,
                              counts: counts[folder.id, default: .init()], workspaceTitle: title)
                }
                ForEach(sections.unpinned) { folder in
                    folderRow(folder, sectionFolders: sections.unpinned,
                              counts: counts[folder.id, default: .init()], workspaceTitle: title)
                }
            }
        }
        .padding(.leading, 8)
    }

    private func agentSectionExpanded(_ key: String) -> Bool {
        DashboardAgentDisclosureStore.isExpanded(key, in: agentDisclosureRaw)
    }

    private func agentDisclosureHeading(
        title: String,
        key: String,
        level: Int = 0
    ) -> some View {
        DashboardDisclosureHeading(
            title: title,
            expanded: agentSectionExpanded(key)
        ) {
            DashboardAgentDisclosureStore.toggle(key, in: &agentDisclosureRaw)
        }
        .padding(.leading, CGFloat(level * 8))
    }

    @ViewBuilder
    private func remoteWorkspaceSection(
        _ workspace: DashboardRemoteWorkspaceSidebarLink
    ) -> some View {
        let key = DashboardAgentDisclosureKey.workspace(workspace.id)
        let ownerID = "remote:" + workspace.id.uuidString.lowercased()
        // Remote workspace names deliberately align with the local heading.
        agentDisclosureHeading(title: workspace.configuration.name, key: key)
            .contextMenu {
                Button("View browser") { browserWorkspace = workspace.configuration }
            }
        if agentSectionExpanded(key) {
            workspaceContents(
                key: key, title: workspace.configuration.name,
                workspaceAgents: DashboardRemoteWorkspaceSidebarModel.agents(agents, in: workspace.id),
                workspaceFolders: folders.filter { $0.executionWorkspaceID == ownerID },
                remoteWorkspace: workspace
            )
        }
    }

    private func remoteTargetRow(_ target: RemoteHarnessChatTarget) -> some View {
        HStack(spacing: 0) {
            DashboardRailRow(
                icon: .container,
                harnessLogo: DashboardHarnessLogo(runtimeKind: target.harness.id),
                title: target.harness.presentationName,
                hoverID: "remote-harness:\(target.id)"
            ) {
                onSelectRemoteAgent(target)
            }
            newChatButton(label: "New chat with \(target.harness.presentationName) in \(target.configuration.name)") {
                onStartRemoteChat(target)
            }
            .disabled(!canCreateChat(workspaceID: "remote:" + target.configuration.id.uuidString.lowercased()))
        }
    }

    private func remoteAgent(for target: RemoteHarnessChatTarget) -> WorkspaceAgent? {
        agents.first {
            $0.governingPlane == .remoteWorkspace
                && $0.runtimeDeviceID == target.configuration.id
                && $0.runtimeKind == target.harness.id
        }
    }

    private func remoteWorkspaceEmptyLabel(
        _ workspace: DashboardRemoteWorkspaceSidebarLink
    ) -> String {
        let id = workspace.id
        if remoteWorkspaces.busyWorkspaceIDs.contains(id) {
            return "Refreshing workspace…"
        }
        guard let status = remoteWorkspaces.statuses[id] else {
            return "Checking workspace…"
        }
        guard status.running else { return "Workspace is stopped" }
        if remoteWorkspaces.harnesses[id] == nil { return "Checking agents…" }
        return "No ready agents"
    }

    private func agentEmptyLabel(_ text: String, level: Int = 0) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(DashboardPalette.foreground)
            .padding(.horizontal, 12)
            .padding(.leading, CGFloat(level * 8))
            .padding(.vertical, 4)
    }

    private func agentRow(
        _ agent: WorkspaceAgent,
        moveScope: DashboardAgentMoveScope,
        groupAgents: [WorkspaceAgent],
        isPinned: Bool
    ) -> some View {
        let presentation = dashboardAgentPresentation(agent)
        let presentIDs = groupAgents.map(\.id)
        let canMoveUp = DashboardAgentOrderStore.canMove(
            id: agent.id,
            direction: .up,
            presentIDs: presentIDs
        )
        let canMoveDown = DashboardAgentOrderStore.canMove(
            id: agent.id,
            direction: .down,
            presentIDs: presentIDs
        )
        return HStack(spacing: 0) {
            DashboardRailRow(
                icon: dashboardAgentGlyph(agent, iconKey: presentation.iconKey),
                harnessLogo: DashboardHarnessLogo(runtimeKind: agent.runtimeKind),
                title: presentation.displayName,
                hoverID: "agent:\(agent.id.uuidString)",
                trailing: agent.runtimeStatus == .running ? "Running" : nil,
                showsPin: isPinned,
                selected: destination == .workspace && selectedAgentID == agent.id,
                pinMenuTitle: isPinned ? "Unpin agent" : "Pin agent",
                onTogglePin: {
                    DashboardPinnedAgentsStore.toggle(
                        id: agent.id,
                        in: &pinnedAgentIDsRaw
                    )
                },
                moveUpTitle: "Move up",
                moveUpEnabled: canMoveUp,
                onMoveUp: {
                    moveAgent(agent.id, in: moveScope, direction: .up, presentIDs: presentIDs)
                },
                moveDownTitle: "Move down",
                moveDownEnabled: canMoveDown,
                onMoveDown: {
                    moveAgent(agent.id, in: moveScope, direction: .down, presentIDs: presentIDs)
                }
            ) {
                onSelectAgent(agent.id)
            }
            newChatButton(label: "New chat with \(presentation.displayName)") { onCreateAgentChat(agent.id) }
                .disabled(!canCreateChat(workspaceID: agent.governingPlane == .remoteWorkspace
                    ? agent.runtimeDeviceID.map { "remote:" + $0.uuidString.lowercased() } : localExecutionWorkspaceID))
        }
    }

    private func canCreateChat(workspaceID: String?) -> Bool {
        let owner = folders.first { $0.id == selectedFolderID }?.executionWorkspaceID
        return selectedFolderID == nil || (owner != nil && owner == workspaceID)
    }

    private func newChatButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DashboardLucideIcon(glyph: .plus, size: 12)
                .frame(width: 24, height: DashboardMetrics.rowHeight)
        }
        .buttonStyle(DashboardIconButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    private func moveAgent(
        _ id: UUID,
        in scope: DashboardAgentMoveScope,
        direction: DashboardAgentListMoveDirection,
        presentIDs: [UUID]
    ) {
        switch scope {
        case .pinned:
            // Pinned order lives in the pin-IDs list.
            var order = DashboardPinnedAgentsStore.decode(pinnedAgentIDsRaw)
            // Restrict to currently visible pinned agents' order.
            order = DashboardAgentOrderStore.mergePreferred(order, present: presentIDs)
            guard let index = order.firstIndex(of: id) else { return }
            let target: Int
            switch direction {
            case .up:
                guard index > 0 else { return }
                target = index - 1
            case .down:
                guard index < order.count - 1 else { return }
                target = index + 1
            }
            order.swapAt(index, target)
            // Preserve any pin IDs not currently visible after the reordered present set.
            let presentSet = Set(presentIDs)
            let hiddenPins = DashboardPinnedAgentsStore.decode(pinnedAgentIDsRaw)
                .filter { !presentSet.contains($0) }
            pinnedAgentIDsRaw = DashboardPinnedAgentsStore.encode(order + hiddenPins)
        case .stored(let key):
            DashboardAgentOrderStore.move(
                id: id,
                direction: direction,
                inKey: key,
                presentIDs: presentIDs,
                raw: &agentOrderRaw
            )
        }
    }

    private func newFolderRow(key: String, workspaceID: UUID?, workspaceTitle: String) -> some View {
        DashboardRailRow(icon: .plus, title: "New folder", hoverID: "folder:create:" + key) {
            creatingFolderWorkspaceKey = key
        }
        .popover(isPresented: Binding(
            get: { creatingFolderWorkspaceKey == key },
            set: { if !$0 { creatingFolderWorkspaceKey = nil } }
        ), arrowEdge: .trailing) {
            DashboardNewFolderPopover(
                remoteWorkspaces: remoteWorkspaces,
                localWorkspaceReady: localWorkspaceReady,
                workspaceID: workspaceID,
                workspaceTitle: workspaceTitle,
                onCancel: { creatingFolderWorkspaceKey = nil },
                onCreate: { name, workspaceID, externalRoot in
                    creatingFolderWorkspaceKey = nil
                    onCreateFolder(name, workspaceID, externalRoot)
                }
            )
        }
    }

    private var allWorkspacesRow: some View {
        HStack(spacing: 0) {
            DashboardRailRow(
                icon: .folderOpen, title: "All Workspaces", hoverID: "folder:all",
                selected: selectedFolderID == nil
            ) { onSelectFolder(nil) }
            newChatButton(label: "New chat in All Workspaces") { onCreateChatInFolder(nil) }
        }
        .padding(.bottom, 8)
    }

    private var trashRow: some View {
        DashboardRailRow(icon: .trash, title: "Trash", hoverID: "folder:trash") {
            onShowTrash()
        }
        .padding(.top, 8)
    }

    private func folderRow(
        _ folder: WorkspaceFolderRecord,
        sectionFolders: [WorkspaceFolderRecord],
        counts: DashboardFolderContentCounts,
        workspaceTitle: String
    ) -> some View {
        let index = sectionFolders.firstIndex(where: { $0.id == folder.id })
        let canMoveUp = index.map { $0 > 0 } ?? false
        let canMoveDown = index.map { $0 < sectionFolders.count - 1 } ?? false
        return HStack(spacing: 0) {
            DashboardRailRow(
                icon: .folder,
                title: folder.name,
                hoverID: "folder:\(folder.id)",
                trailing: "\(counts.total)",
                showsPin: folder.isPinned,
                selected: selectedFolderID == folder.id,
                pinMenuTitle: folder.isPinned ? "Unpin" : "Pin",
                onTogglePin: { onSetFolderPinned(folder.id, !folder.isPinned) },
                moveUpTitle: "Move up",
                moveUpEnabled: canMoveUp,
                onMoveUp: { onMoveFolder(folder.id, .up) },
                moveDownTitle: "Move down",
                moveDownEnabled: canMoveDown,
                onMoveDown: { onMoveFolder(folder.id, .down) },
                renameMenuTitle: "Rename",
                onRename: {
                    renamedFolderName = folder.name
                    renamingFolderID = folder.id
                },
                exportMenuTitle: "Export content",
                onExport: { onUnavailableMutation("Folder export") },
                referenceMenuTitle: "Reference locations…",
                onManageReferences: { editingReferenceFolderID = folder.id },
                destructiveMenuTitle: "Remove folder…",
                onDelete: { deletingFolder = folder },
                folderDetails: DashboardFolderHoverDetails(
                    folder: folder, workspaceTitle: workspaceTitle, counts: counts
                ),
                presentedFolderID: $presentedFolderID
            ) {
                onSelectFolder(folder.id)
            }
            newChatButton(label: "New chat in \(folder.name)") { onCreateChatInFolder(folder.id) }
        }
        .popover(
            isPresented: Binding(
                get: { renamingFolderID == folder.id },
                set: { presented in
                    if !presented, renamingFolderID == folder.id {
                        renamingFolderID = nil
                    }
                }
            ),
            arrowEdge: .trailing
        ) {
            DashboardFolderNamePopover(
                title: "Rename folder",
                actionTitle: "Rename",
                name: $renamedFolderName,
                onCancel: { renamingFolderID = nil },
                onCommit: {
                    let name = renamedFolderName.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard !name.isEmpty else { return }
                    renamingFolderID = nil
                    onRenameFolder(folder.id, name)
                }
            )
        }
        .popover(isPresented: Binding(
            get: { editingReferenceFolderID == folder.id },
            set: { if !$0 { editingReferenceFolderID = nil } }
        ), arrowEdge: .trailing) {
            DashboardFolderReferencesPopover(
                folder: folder,
                isOnThisMac: localExecutionWorkspaceID != nil && folder.executionWorkspaceID == localExecutionWorkspaceID,
                onClose: { editingReferenceFolderID = nil },
                onChange: { onSetFolderReferencePaths(folder.id, $0) }
            )
        }
        .confirmationDialog(
            "Remove \(folder.name)?",
            isPresented: Binding(
                get: { deletingFolder?.id == folder.id },
                set: { if !$0 { deletingFolder = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Folder Only", role: .destructive) {
                deletingFolder = nil
                onDeleteFolder(folder.id, false)
            }
            if folder.managedRoot {
                Button("Delete Folder and Directory", role: .destructive) {
                    deletingFolder = nil
                    onDeleteFolder(folder.id, true)
                }
            }
            Button("Cancel", role: .cancel) { deletingFolder = nil }
        } message: {
            if folder.managedRoot, let rootPath = folder.rootPath {
                Text("Remove the folder from Woven, or also delete its directory and every file in it: \(rootPath). Chats and notes remain in Woven.")
            } else {
                Text("Remove the folder from Woven. Its directory, files, chats and notes are preserved.")
            }
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardDisclosureHeading(title: "Recents", expanded: recentsOpen) { recentsOpen.toggle() }
                .padding(.top, 8)
            if recentsOpen {
                if recentItems.isEmpty {
                    Text("No recent items.")
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardPalette.foreground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                } else {
                    ForEach(recentItems) { item in
                        switch item {
                        case .conversation(let conversation):
                            DashboardRailRow(
                                icon: .messageSquare,
                                title: conversation.title,
                                hoverID: "recent-conversation:\(conversation.id)",
                                selected: selectedConversationID == conversation.id,
                                isRunningConversation: runningConversationIDs.contains(conversation.id),
                                conversationID: conversation.id
                            ) {
                                onSelectConversation(conversation.id)
                            }
                            .modifier(DashboardConversationContextMenu(
                                conversation: conversation,
                                folders: folders,
                                isRunning: runningConversationIDs.contains(conversation.id),
                                onAction: onConversationAction
                            ))
                        case .note(let note):
                            DashboardRailRow(
                                icon: .fileText,
                                title: note.title,
                                hoverID: "recent-note:\(note.id)"
                            ) {
                                onSelectNote(note.id)
                            }
                            .modifier(DashboardNoteContextMenu(
                                note: note,
                                folders: folders,
                                onAction: onNoteAction
                            ))
                        }
                    }
                }
            }
        }
    }

    private var folderContentCounts: [String: DashboardFolderContentCounts] {
        var counts: [String: DashboardFolderContentCounts] = [:]
        for conversation in conversations {
            if let folderID = conversation.folderID {
                counts[folderID, default: .init()].chats += 1
            }
        }
        for note in notes {
            if let folderID = note.folderID {
                counts[folderID, default: .init()].notes += 1
            }
        }
        return counts
    }

    private var recentItems: [DashboardRecentItem] {
        var items: [DashboardRecentItem] = []

        func insert(_ item: DashboardRecentItem) {
            if let index = items.firstIndex(where: { item.ranksBefore($0) }) {
                items.insert(item, at: index)
            } else if items.count < 14 {
                items.append(item)
            }
            if items.count > 14 {
                items.removeLast()
            }
        }

        for conversation in conversations {
            insert(.conversation(conversation))
        }
        for note in notes {
            insert(.note(note))
        }
        return items
    }
}

enum DashboardRecentItem: Identifiable {
    case conversation(WorkspaceConversationRecord)
    case note(WorkspaceNoteRecord)

    var id: String {
        switch self {
        case .conversation(let value): "conversation:\(value.id)"
        case .note(let value): "note:\(value.id)"
        }
    }

    var activityTimestamp: String {
        let timestamp: String? = switch self {
        case .conversation(let conversation): conversation.lastMessageAt
        case .note(let note): note.updatedAt ?? note.createdAt
        }
        return timestamp ?? ""
    }

    func ranksBefore(_ other: DashboardRecentItem) -> Bool {
        if activityTimestamp != other.activityTimestamp {
            return activityTimestamp > other.activityTimestamp
        }
        return id > other.id
    }
}

struct DashboardNewFolderPopover: View {
    let remoteWorkspaces: RemoteWorkspacesModel
    let localWorkspaceReady: Bool
    let workspaceID: UUID?
    let workspaceTitle: String
    let onCancel: () -> Void
    let onCreate: (String, UUID?, URL?) -> Void
    @State private var name = ""
    @State private var linksExistingDirectory = false
    @State private var externalRoot: URL?
    @State private var hostDirectoryPath = ""
    @State private var hostDirectoryFilter = ""
    @State private var hostDirectoryListing: RemoteHostDirectoryListing?
    @State private var loadingHostDirectories = false
    @State private var hostDirectoryError: String?
    @State private var hostDirectoryRequest = UUID()
    @FocusState private var nameFocused: Bool

    private var ownerIsAvailable: Bool {
        guard let workspaceID else { return localWorkspaceReady }
        return remoteWorkspaces.statuses[workspaceID]?.running == true
            && !remoteWorkspaces.busyWorkspaceIDs.contains(workspaceID)
    }

    private var canCreate: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ownerIsAvailable && !trimmed.isEmpty
            && (linksExistingDirectory ? externalRoot != nil : !trimmed.contains("/") && trimmed != "." && trimmed != "..")
    }

    private var nativeHost: RemoteWorkspaceConfiguration? {
        guard let workspaceID, let configuration = remoteWorkspaces.configuration(id: workspaceID), configuration.kind == .host else { return nil }
        return configuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Folder").font(.system(size: 14, weight: .semibold))
            Text(workspaceTitle)
                .font(.system(size: 11.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
            if workspaceID == nil || nativeHost != nil {
                Picker("Directory", selection: $linksExistingDirectory) {
                    Text("Create New").tag(false)
                    Text("Link Existing").tag(true)
                }
                .pickerStyle(.segmented)
            }
            TextField("Folder name", text: $name)
                .focused($nameFocused)
                .dashboardQuietTextInput()
                .onSubmit { if canCreate { create() } }
            if linksExistingDirectory {
                if nativeHost != nil { hostDirectoryBrowser }
                else {
                    Button(externalRoot?.path ?? "Choose directory…", action: chooseDirectory)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Woven uses this directory as the project root. Existing files are preserved.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            } else {
                Text("Creates a blank directory in this workspace. Later renaming changes only its name in Woven.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            if !ownerIsAvailable {
                Text("Connect this workspace before creating a folder.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.danger)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(linksExistingDirectory ? "Link" : "Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(DashboardPalette.foreground)
        .padding(16)
        .frame(width: 340)
        .dashboardFormFocusDismissal { nameFocused = false }
        .task { nameFocused = true }
        .task(id: linksExistingDirectory) {
            if linksExistingDirectory, nativeHost != nil, hostDirectoryListing == nil {
                await browseHostDirectory(nil)
            }
        }
    }

    private var hostDirectoryBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Absolute directory on host", text: $hostDirectoryPath)
                .dashboardQuietTextInput()
                .onSubmit { Task { await browseHostDirectory(hostDirectoryPath) } }
            HStack {
                Button("Up") { Task { await browseHostDirectory(hostDirectoryListing?.parent) } }
                    .disabled(hostDirectoryListing?.parent == nil || loadingHostDirectories)
                Button("Browse") { Task { await browseHostDirectory(hostDirectoryPath) } }
                    .disabled(loadingHostDirectories || !hostDirectoryPath.hasPrefix("/"))
                Spacer()
                if loadingHostDirectories { ProgressView().controlSize(.small) }
            }
            if let listing = hostDirectoryListing {
                TextField("Find a directory here", text: $hostDirectoryFilter).dashboardQuietTextInput()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(listing.directories.filter { hostDirectoryFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(hostDirectoryFilter) }) { directory in
                            Button(directory.name) { Task { await browseHostDirectory(directory.path) } }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.scrollIndicators(.never).frame(maxHeight: 150)
                if listing.truncated {
                    Text("More directories are available. Enter a more specific path to browse them.")
                        .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                }
                Button("Use this directory") {
                    externalRoot = URL(fileURLWithPath: listing.path)
                    if name.isEmpty { name = externalRoot?.lastPathComponent ?? "" }
                }.disabled(loadingHostDirectories)
            }
            if let externalRoot {
                Text("Selected: \(externalRoot.path)").font(.system(size: 11.5)).textSelection(.enabled)
            }
            if let hostDirectoryError {
                Text(hostDirectoryError).font(.system(size: 11.5)).foregroundStyle(DashboardPalette.danger)
            }
        }
        .buttonStyle(SettingsQuietButtonStyle())
    }

    @MainActor
    private func browseHostDirectory(_ path: String?) async {
        guard let nativeHost else { return }
        let request = UUID()
        hostDirectoryRequest = request
        loadingHostDirectories = true
        hostDirectoryError = nil
        defer { if hostDirectoryRequest == request { loadingHostDirectories = false } }
        do {
            let listing = try await remoteWorkspaces.hostDirectories(path: path, in: nativeHost)
            guard hostDirectoryRequest == request, !Task.isCancelled else { return }
            hostDirectoryListing = listing
            hostDirectoryPath = listing.path
            hostDirectoryFilter = ""
        } catch {
            guard hostDirectoryRequest == request, !Task.isCancelled else { return }
            hostDirectoryError = error.localizedDescription
        }
    }

    private func create() {
        guard canCreate else { return }
        onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines), workspaceID,
            linksExistingDirectory ? externalRoot : nil)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Link Project Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            externalRoot = url
            if name.isEmpty { name = url.lastPathComponent }
        }
    }
}

struct DashboardFolderReferencesPopover: View {
    let folder: WorkspaceFolderRecord
    let isOnThisMac: Bool
    let onClose: () -> Void
    let onChange: ([String]) -> Void
    @State private var paths: [String]
    @State private var newPath = ""
    @FocusState private var pathFocused: Bool

    init(folder: WorkspaceFolderRecord, isOnThisMac: Bool, onClose: @escaping () -> Void,
         onChange: @escaping ([String]) -> Void) {
        self.folder = folder; self.isOnThisMac = isOnThisMac
        self.onClose = onClose; self.onChange = onChange
        _paths = State(initialValue: folder.referencePaths)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reference Locations").font(.system(size: 14, weight: .semibold))
            if let rootPath = folder.rootPath {
                Text("Root: \(rootPath)").font(.system(size: 11.5)).textSelection(.enabled)
            }
            Text("Additional locations on this workspace are available to its sessions. Linking does not read project instruction files. Unlinking does not revoke operating system permissions.")
                .font(.system(size: 11.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(paths, id: \.self) { path in
                        HStack(spacing: 8) {
                            Text(path).font(.system(size: 11.5)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { paths.removeAll { $0 == path } } label: {
                                DashboardLucideIcon(glyph: .close, size: 12).frame(width: 24, height: 24)
                            }
                            .buttonStyle(DashboardIconButtonStyle())
                            .help("Unlink \(path)")
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 160)
            if isOnThisMac {
                Button("Link location…", action: chooseLocations)
            } else {
                HStack {
                    TextField("Absolute path in this workspace", text: $newPath)
                        .dashboardQuietTextInput()
                        .focused($pathFocused)
                        .onSubmit(addPath)
                    Button("Link", action: addPath)
                        .disabled(!newPath.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/"))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save") { onChange(paths); onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .dashboardFormFocusDismissal { pathFocused = false }
    }

    private func addPath() {
        let path = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return }
        if path != folder.rootPath, !paths.contains(path) { paths.append(path) }
        newPath = ""
    }

    private func chooseLocations() {
        let panel = NSOpenPanel()
        panel.title = "Link Reference Locations"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls where url.path != folder.rootPath && !paths.contains(url.path) {
                paths.append(url.path)
            }
        }
    }
}

enum DashboardNewChatTarget {
    case acpDirect(AgentRuntimeKind)
    case remoteWorkspace(RemoteHarnessChatTarget)
}

enum DashboardNewChatAvailabilitySummary {
    static func available(count: Int) -> String {
        "\(count) available"
    }

    static func localCLIs(
        readyRuntimeCount: Int,
        workspaceIsReady: Bool
    ) -> String {
        available(count: workspaceIsReady ? readyRuntimeCount : 0)
    }
}

struct DashboardNewChatDrawer: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    let folderOwnerID: String?
    let localExecutionWorkspaceID: String?
    let onClose: () -> Void
    let onSelect: (DashboardNewChatTarget) -> Void
    @State private var expandedSources = Set(DashboardNewChatSource.allCases)

    private var remoteChatTargets: [RemoteHarnessChatTarget] {
        model.remoteWorkspaces.readyChatTargets.filter {
            folderOwnerID == nil || folderOwnerID == "remote:" + $0.configuration.id.uuidString.lowercased()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Chat")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Choose an agent.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }
                Spacer()
                Button(action: onClose) {
                    DashboardLucideIcon(glyph: .close, size: 16)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(DashboardIconButtonStyle())
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 72)

            Divider().overlay(theme.palette.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if folderOwnerID == nil || folderOwnerID == localExecutionWorkspaceID {
                        DashboardNewChatSection(
                            source: .acpDirect,
                            summary: DashboardNewChatAvailabilitySummary.localCLIs(
                                readyRuntimeCount: model.localACPRuntimeAvailability
                                    .filter {
                                        $0.runtimeKind == .opencode ? (model.openCode?.isEnabled == true && model.openCode?.canConnect == true) : $0.isReady
                                            && model.isLocalACPAgentReady($0.runtimeKind)
                                            && !model.checkingLocalACPRuntimeKinds
                                                .contains($0.runtimeKind)
                                    }
                                    .count,
                                workspaceIsReady: model.localACPWorkspaceAvailability
                                    .isReady || model.openCode?.isReady == true
                            ),
                            isExpanded: expansionBinding(for: .acpDirect)
                        ) {
                            ForEach(model.orderedLocalACPRuntimeDefinitions) { definition in
                                let availability = model.localACPRuntimeAvailability
                                    .first {
                                        $0.runtimeKind == definition.runtimeKind
                                    }
                                let isChecking = model.checkingLocalACPRuntimeKinds
                                    .contains(definition.runtimeKind)
                                Button {
                                    onSelect(.acpDirect(definition.runtimeKind))
                                } label: {
                                    DashboardNewChatOptionCard(
                                        icon: .terminal,
                                        harnessLogo: DashboardHarnessLogo(
                                            runtimeKind: definition.runtimeKind
                                        ),
                                        title: definition.displayName,
                                        detail: definition.runtimeKind == .opencode
                                            ? ((model.openCode?.isEnabled == true && model.openCode?.canConnect == true) ? "Local OpenCode v2" : "Set up OpenCode in Settings")
                                            : isChecking || availability == nil
                                            ? "Checking…"
                                            : availability?.isReady == true
                                                && !model.isLocalACPAgentReady(definition.runtimeKind)
                                                ? model.localACPAgentReconciliationError
                                                    ?? "Local workspace unavailable — see Settings"
                                            : availability?.compactDetail
                                                ?? "Unavailable — see Settings"
                                    )
                                }
                                .buttonStyle(DashboardQuietButtonStyle())
                                .disabled(
                                    definition.runtimeKind == .opencode ? (model.openCode?.isEnabled != true || model.openCode?.canConnect != true || model.openCode?.busy == true || !model.localACPWorkspaceAvailability.isReady) : isChecking
                                        || availability?.isReady != true
                                        || !model.isLocalACPAgentReady(definition.runtimeKind)
                                        || !model.localACPWorkspaceAvailability.isReady
                                )
                            }

                            if !model.localACPWorkspaceAvailability.isReady {
                                DashboardInlineError(
                                    text: model.localACPWorkspaceAvailability.detail
                                )
                            }
                        }

                    }
                    DashboardNewChatSection(
                        source: .remoteWorkspace,
                        summary: DashboardNewChatAvailabilitySummary.available(
                            count: remoteChatTargets.count
                        ),
                        isExpanded: expansionBinding(for: .remoteWorkspace)
                    ) {
                        if remoteChatTargets.isEmpty {
                            DashboardNewChatEmptyCard(
                                icon: .container,
                                title: "No remote agents ready",
                                detail: "Set up a remote agent in Settings."
                            )
                        } else {
                            ForEach(remoteChatTargets) { target in
                                Button {
                                    onSelect(.remoteWorkspace(target))
                                } label: {
                                    DashboardNewChatOptionCard(
                                        icon: .container,
                                        harnessLogo: DashboardHarnessLogo(
                                            runtimeKind: target.harness.id
                                        ),
                                        title: target.harness.presentationName,
                                        detail: target.configuration.name
                                    )
                                }
                                .buttonStyle(DashboardQuietButtonStyle())
                            }
                        }
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.never)

            Divider().overlay(theme.palette.border)
            HStack {
                Button("Cancel", action: onClose)
                    .buttonStyle(DashboardQuietButtonStyle())
                Spacer()
            }
            .padding(16)
        }
        .background(theme.palette.workspace)
        .clipShape(DashboardShapes.windowAlignedSurface)
        .overlay {
            DashboardShapes.windowAlignedSurface
                .stroke(theme.palette.border, lineWidth: 1)
        }
        .shadow(
            color: DashboardPalette.foreground.opacity(0.16),
            radius: 34,
            x: -10
        )
        .padding(8)
    }

    private func expansionBinding(
        for source: DashboardNewChatSource
    ) -> Binding<Bool> {
        Binding(
            get: { expandedSources.contains(source) },
            set: { isExpanded in
                if isExpanded {
                    expandedSources.insert(source)
                } else {
                    expandedSources.remove(source)
                }
            }
        )
    }
}

struct DashboardNewNoteDrawer: View {
    @Environment(\.dashboardTheme) private var theme
    let onClose: () -> Void
    let onSelect: (NoteArtifactKind) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Note")
                        .font(.system(size: 18, weight: .semibold))
                }
                Spacer()
                Button(action: onClose) {
                    DashboardLucideIcon(glyph: .close, size: 16)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(DashboardIconButtonStyle())
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 72)

            Divider().overlay(theme.palette.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    artifactButton(
                        "Note",
                        icon: .fileText,
                        kind: .note
                    )
                    artifactButton(
                        "Spreadsheet",
                        icon: .panelsTopLeft,
                        kind: .spreadsheet
                    )
                    artifactButton(
                        "HTML",
                        detail: "View HTML",
                        icon: .panelTop,
                        kind: .html
                    )
                }
                .padding(20)
            }
            .scrollIndicators(.never)

            Divider().overlay(theme.palette.border)
            HStack {
                Button("Cancel", action: onClose)
                    .buttonStyle(DashboardQuietButtonStyle())
                Spacer()
            }
            .padding(16)
        }
        .background(theme.palette.workspace)
        .clipShape(DashboardShapes.windowAlignedSurface)
        .overlay {
            DashboardShapes.windowAlignedSurface
                .stroke(theme.palette.border, lineWidth: 1)
        }
        .shadow(
            color: DashboardPalette.foreground.opacity(0.16),
            radius: 34,
            x: -10
        )
        .padding(8)
    }

    private func artifactButton(
        _ title: String,
        detail: String? = nil,
        icon: DashboardLucideGlyph,
        kind: NoteArtifactKind
    ) -> some View {
        Button {
            onClose()
            onSelect(kind)
        } label: {
            DashboardNewChatOptionCard(
                icon: icon,
                title: title,
                detail: detail
            )
        }
        .buttonStyle(DashboardQuietButtonStyle())
        .accessibilityLabel(title)
    }
}

struct DashboardNewChatSection<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let source: DashboardNewChatSource
    let summary: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text(source.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                    DashboardLucideIcon(glyph: .chevronDown, size: 14)
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 2)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(source.title), \(summary)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct DashboardNewChatOptionCard: View {
    let icon: DashboardLucideGlyph
    var harnessLogo: DashboardHarnessLogo? = nil
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let harnessLogo {
                    DashboardHarnessLogoIcon(logo: harnessLogo, size: 20)
                } else {
                    DashboardLucideIcon(glyph: icon, size: 16)
                        .foregroundStyle(DashboardPalette.primary)
                }
            }
            .frame(width: 36, height: 36)
            .background(DashboardPalette.muted)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 10,
                    style: .continuous
                )
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .lineLimit(2)
                }
            }
            Spacer()
            DashboardLucideIcon(glyph: .arrowRight, size: 14)
        }
        .padding(12)
        .contentShape(Rectangle())
    }
}

struct DashboardNewChatEmptyCard: View {
    let icon: DashboardLucideGlyph
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            DashboardLucideIcon(glyph: icon, size: 16)
                .foregroundStyle(DashboardPalette.mutedForeground)
                .frame(width: 36, height: 36)
                .background(DashboardPalette.muted)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 10,
                        style: .continuous
                    )
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(12)
        .background(DashboardPalette.muted.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct DashboardSidebarWorkspacePage: View {
    @Environment(\.dashboardTheme) private var theme
    let side: DashboardSidebarSide
    let conversations: [WorkspaceConversationRecord]
    let notes: [WorkspaceNoteRecord]
    let runningConversationIDs: Set<String>
    let agents: [WorkspaceAgent]
    let folders: [WorkspaceFolderRecord]
    let contentRevision: Int64
    let contentScopeID: String?
    let selectedConversationID: String?
    let selectedNoteID: String?
    let selectedFolderName: String?
    @AppStorage("wovenmatter.dashboard.workspace-mode") private var modeRawValue = WorkspaceListMode.chats.rawValue
    let onCollapse: () -> Void
    let onBack: (() -> Void)?
    let onMove: (() -> Void)?
    let showsQuickActions: Bool
    let onCreateChat: () -> Void
    let onCreateNote: () -> Void
    let onSelectConversation: (String) -> Void
    let onSelectNote: (String) -> Void
    let onConversationAction: (WorkspaceConversationRecord, DashboardConversationMenuAction) -> Void
    let onNoteAction: (WorkspaceNoteRecord, DashboardNoteMenuAction) -> Void
    let onSurfaceProfileChange: () -> Void

    @State private var query = ""
    @State private var readFilter: DashboardReadFilter?
    @State private var filterHovered = false
    @State private var showsReadFilterMenu = false
    @State private var pinnedOpen = true
    @State private var recentsOpen = true
    @State private var scrollHoverCoordinator = DashboardScrollHoverCoordinator()
    @State private var content = DashboardRightRailContent.empty
    @State private var conversationDetailCardState = DashboardConversationDetailCardState()

    private var mode: WorkspaceListMode {
        get { WorkspaceListMode(rawValue: modeRawValue) ?? .chats }
        nonmutating set { modeRawValue = newValue.rawValue }
    }

    private var modeBinding: Binding<WorkspaceListMode> {
        Binding(
            get: { mode },
            set: { mode = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            railHeader
            if showsQuickActions {
                quickActions
            }
            VStack(spacing: 8) {
                modePicker
                HStack(spacing: 8) {
                    searchField
                    if onBack != nil {
                        filterMenu(inSearchRow: true)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if mode == .chats {
                        DashboardListSectionHeader(title: "Pinned chats", expanded: pinnedOpen) {
                            pinnedOpen.toggle()
                        }
                        if pinnedOpen {
                            if content.pinnedChats.isEmpty {
                                DashboardEmptyListRow(text: "No pinned chats.")
                            } else {
                                ForEach(content.pinnedChats) { presentation in
                                    conversationRow(presentation)
                                }
                            }
                        }

                        DashboardListSectionHeader(title: "Recents", expanded: recentsOpen) {
                            recentsOpen.toggle()
                        }
                        if recentsOpen {
                            if content.recentChats.isEmpty {
                                DashboardEmptyListRow(text: "No recent chats.")
                            } else {
                                ForEach(content.recentChats) { presentation in
                                    conversationRow(presentation)
                                }
                            }
                        }
                    } else {
                        DashboardListSectionHeader(title: "Pinned notes", expanded: pinnedOpen) {
                            pinnedOpen.toggle()
                        }
                        if pinnedOpen {
                            if content.pinnedNotes.isEmpty {
                                DashboardEmptyListRow(text: "No pinned notes.")
                            } else {
                                ForEach(content.pinnedNotes) { presentation in
                                    noteRow(presentation)
                                }
                            }
                        }

                        DashboardListSectionHeader(title: "Notes", expanded: recentsOpen) {
                            recentsOpen.toggle()
                        }
                        if recentsOpen {
                            if content.notes.isEmpty {
                                DashboardEmptyListRow(text: "No notes.")
                            } else {
                                ForEach(content.notes) { presentation in
                                    noteRow(presentation)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
            .environment(\.dashboardScrollHoverCoordinator, scrollHoverCoordinator)
            .onScrollPhaseChange { _, phase in
                scrollHoverCoordinator.setScrolling(phase.isScrolling)
            }
        }
        .task(id: contentTaskID) {
            let conversations = conversations
            let notes = notes
            let agents = agents
            let folders = folders
            let query = query
            let readFilter = readFilter
            let previous = content
            let buildTask = Task.detached(priority: .userInitiated) {
                let next = DashboardRightRailContent(
                    conversations: conversations,
                    notes: notes,
                    agents: agents,
                    folders: folders,
                    query: query,
                    readFilter: readFilter
                )
                return next == previous ? nil : next
            }
            let update = await withTaskCancellationHandler {
                await buildTask.value
            } onCancel: {
                buildTask.cancel()
            }
            guard !Task.isCancelled, let update else { return }
            content = update
        }
        .onChange(of: modeRawValue) { _, _ in
            onSurfaceProfileChange()
        }
    }

    private var contentTaskID: DashboardRightRailContentTaskID {
        DashboardRightRailContentTaskID(
            revision: contentRevision,
            scopeID: contentScopeID,
            agentRevisions: agents.map { "\($0.id.uuidString):\($0.revision)" }.joined(separator: ","),
            folderRevisions: folders.map { "\($0.id):\($0.name)" }.joined(separator: ","),
            timeContext: DashboardListTimeContext.current,
            query: query,
            readFilter: readFilter
        )
    }

    private var mirrorsHeader: Bool {
        side == .right && onBack != nil
    }

    private var railHeader: some View {
        HStack(spacing: 8) {
            if mirrorsHeader {
                collapseButton
                moveButton
                Spacer()
            } else {
                headerNavigationButton
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(selectedFolderName ?? "All Workspaces")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(conversations.count) chats · \(notes.count) notes")
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardPalette.foreground)
            }
            if mirrorsHeader {
                headerNavigationButton
            } else {
                Spacer()
                if onBack == nil {
                    filterMenu(inSearchRow: false)
                }
                moveButton
                if onBack != nil {
                    collapseButton
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 68)
    }

    @ViewBuilder
    private var headerNavigationButton: some View {
        if let onBack {
            Button(action: onBack) {
                DashboardLucideIcon(
                    glyph: side == .left ? .arrowLeft : .arrowRight,
                    size: 16
                )
                .frame(width: 32, height: 32)
            }
            .buttonStyle(DashboardIconButtonStyle())
            .help("Back to Workspace")
            .accessibilityLabel("Back to Workspace")
        } else {
            Button(action: onCollapse) {
                DashboardLucideIcon(glyph: .rightCollapse, size: 18)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(DashboardIconButtonStyle())
            .help("Hide workspace")
        }
    }

    @ViewBuilder
    private var moveButton: some View {
        if let onMove {
            Button(action: onMove) {
                DashboardLucideIcon(glyph: .arrowLeftRight, size: 16)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(DashboardIconButtonStyle())
            .help(side == .left ? "Move sidebar right" : "Move sidebar left")
        }
    }

    private var collapseButton: some View {
        Button(action: onCollapse) {
            DashboardLucideIcon(
                glyph: side == .left ? .leftCollapse : .rightCollapse,
                size: 18
            )
            .frame(width: 36, height: 36)
        }
        .buttonStyle(DashboardIconButtonStyle())
        .help("Hide sidebar")
    }

    private func filterMenu(inSearchRow: Bool) -> some View {
        Button {
            showsReadFilterMenu.toggle()
        } label: {
            DashboardLucideIcon(glyph: .listFilter, size: 14)
                .foregroundStyle(
                    DashboardPalette.foreground
                )
                .frame(width: 36, height: 36)
                .background(
                    filterHovered ? theme.palette.themeSoft : inSearchRow ? theme.palette.themeWhisper : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { filterHovered = $0 }
        .popover(isPresented: $showsReadFilterMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                readFilterButton(.read, title: "Read")
                readFilterButton(.unread, title: "Unread")
            }
            .padding(6)
            .frame(width: 132)
        }
        .accessibilityLabel("Filter")
        .help("Filter")
    }

    private func readFilterButton(_ value: DashboardReadFilter, title: String) -> some View {
        Button {
            readFilter = value
            showsReadFilterMenu = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .frame(width: 12)
                    .opacity(readFilter == value ? 1 : 0)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var quickActions: some View {
        VStack(spacing: 1) {
            DashboardRailRow(
                icon: .squarePen,
                title: "New chat",
                hoverID: "folder-action:new-chat",
                action: onCreateChat
            )
            DashboardNewArtifactButton(
                hoverID: "folder-action:new-note",
                action: onCreateNote
            )
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }

    private var modePicker: some View {
        DashboardSegmentedSelector(
            options: WorkspaceListMode.allCases,
            selection: modeBinding
        ) { value in
            value == .chats ? "Chats" : "Notes"
        }
    }

    private var searchField: some View {
        DashboardSearchField(
            text: $query,
            prompt: mode == .chats ? "Search chats" : "Search notes"
        )
    }

    private func conversationRow(_ presentation: DashboardConversationRowPresentation) -> some View {
        DashboardConversationRow(
            presentation: presentation,
            selected: selectedConversationID == presentation.id,
            isRunning: runningConversationIDs.contains(presentation.id),
            detailCardState: $conversationDetailCardState,
            folders: folders,
            onConversationAction: onConversationAction
        ) {
            onSelectConversation(presentation.id)
        }
    }

    private func noteRow(_ presentation: DashboardNoteRowPresentation) -> some View {
        DashboardNoteRow(
            presentation: presentation,
            selected: selectedNoteID == presentation.id,
            folders: folders,
            onNoteAction: onNoteAction
        ) {
            onSelectNote(presentation.id)
        }
    }
}

struct DashboardRightRailContentTaskID: Hashable {
    let revision: Int64
    let scopeID: String?
    let agentRevisions: String
    let folderRevisions: String
    let timeContext: String
    let query: String
    let readFilter: DashboardReadFilter?
}

enum DashboardReadFilter: String, Hashable, Sendable {
    case read
    case unread

    func includes(unread: Bool) -> Bool {
        switch self {
        case .read: !unread
        case .unread: unread
        }
    }
}

/// Secondary metadata for workspace chat list rows and their detail cards.
struct DashboardConversationListMeta: Equatable, Sendable {
    let agentLabel: String
    let folderLabel: String
    /// Product location bucket, e.g. "Local agent workspace".
    let locationLabel: String
    let locationKind: DashboardConversationLocationKind
    /// Runtime product name when known, e.g. "Codex", "Claude Code".
    let runtimeLabel: String?
    let runtimeKind: AgentRuntimeKind?

    static func resolve(
        conversation: WorkspaceConversationRecord,
        agent: WorkspaceAgent?,
        foldersByID: [String: WorkspaceFolderRecord]
    ) -> DashboardConversationListMeta {
        let agentLabel: String
        let locationLabel: String
        let locationKind: DashboardConversationLocationKind
        let runtimeLabel: String?
        let runtimeKind: AgentRuntimeKind?
        if let agent {
            agentLabel = dashboardAgentDisplayName(agent)
            locationLabel = DashboardConversationLocationKind.resolve(agent.bucket).label
            locationKind = DashboardConversationLocationKind.resolve(agent.bucket)
            runtimeLabel = agent.runtimeKind.displayName
            runtimeKind = agent.runtimeKind
        } else if let runtime = conversation.localRuntimeKind {
            agentLabel = runtime.displayName
            locationLabel = DashboardConversationLocationKind.workspaceAgent.label
            locationKind = .workspaceAgent
            runtimeLabel = runtime.displayName
            runtimeKind = runtime
        } else if let codename = conversation.agentCodename?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !codename.isEmpty {
            agentLabel = codename
            locationLabel = "Local agent workspace"
            locationKind = .workspaceAgent
            runtimeLabel = nil
            runtimeKind = nil
        } else {
            agentLabel = "Unknown agent"
            locationLabel = "Unknown"
            locationKind = .workspaceAgent
            runtimeLabel = nil
            runtimeKind = nil
        }

        let folderLabel: String
        if let folderID = conversation.folderID,
           let folder = foldersByID[folderID] {
            let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            folderLabel = name.isEmpty ? "Untitled folder" : name
        } else {
            folderLabel = "All Workspaces"
        }

        return DashboardConversationListMeta(
            agentLabel: agentLabel,
            folderLabel: folderLabel,
            locationLabel: locationLabel,
            locationKind: locationKind,
            runtimeLabel: runtimeLabel,
            runtimeKind: runtimeKind
        )
    }
}

enum DashboardConversationLocationKind: Equatable, Sendable {
    case workspaceAgent
    case remoteWorkspace

    static func resolve(_ bucket: AgentBucket) -> Self {
        switch bucket {
        case .localCLIAgents:
            .workspaceAgent
        case .remoteWorkspaceAgents:
            .remoteWorkspace
        }
    }

    var label: String {
        switch self {
        case .workspaceAgent:
            "Local agent workspace"
        case .remoteWorkspace:
            "Remote workspace"
        }
    }

    var glyph: DashboardLucideGlyph {
        switch self {
        case .workspaceAgent:
            .panelsTopLeft
        case .remoteWorkspace:
            .container
        }
    }
}

struct DashboardConversationRowAccessibility: Equatable, Sendable {
    let label: String
    let value: String
    let hint: String

    static func resolve(
        conversation: WorkspaceConversationRecord,
        title: String,
        meta: DashboardConversationListMeta,
        preview: String,
        time: String
    ) -> DashboardConversationRowAccessibility {
        var details: [String] = []
        if conversation.unread {
            details.append("Unread")
        }
        details.append("Folder \(meta.folderLabel)")
        details.append("Agent \(meta.agentLabel)")
        if let runtime = meta.runtimeLabel {
            details.append("Runtime \(runtime)")
        }
        details.append("Location \(meta.locationLabel)")
        if !preview.isEmpty {
            details.append("Last message \(preview)")
        }
        if !time.isEmpty {
            details.append("Updated \(time)")
        }
        return DashboardConversationRowAccessibility(
            label: title,
            value: details.joined(separator: ". "),
            hint: "Press to open the chat."
        )
    }
}

struct DashboardConversationRowPresentation: Equatable, Identifiable, Sendable {
    let conversation: WorkspaceConversationRecord
    let agent: WorkspaceAgent?
    let title: String
    let meta: DashboardConversationListMeta
    let preview: String
    let time: String
    let timeContext: String

    var id: String { conversation.id }
}

struct DashboardNoteRowPresentation: Equatable, Identifiable, Sendable {
    let note: WorkspaceNoteRecord
    let kind: NoteArtifactKind
    let title: String
    let preview: String

    var id: String { note.id }
}

final class DashboardConversationRowPresentationBox: NSObject {
    let value: DashboardConversationRowPresentation

    init(_ value: DashboardConversationRowPresentation) {
        self.value = value
    }
}

final class DashboardNoteRowPresentationBox: NSObject {
    let value: DashboardNoteRowPresentation

    init(_ value: DashboardNoteRowPresentation) {
        self.value = value
    }
}

final class DashboardListPresentationCache: @unchecked Sendable {
    static let shared = DashboardListPresentationCache()

    private let conversations = NSCache<NSString, DashboardConversationRowPresentationBox>()
    private let notes = NSCache<NSString, DashboardNoteRowPresentationBox>()

    private init() {
        conversations.countLimit = 4_096
        notes.countLimit = 4_096
    }

    func presentation(
        for conversation: WorkspaceConversationRecord,
        agent: WorkspaceAgent?,
        foldersByID: [String: WorkspaceFolderRecord],
        timeContext: String
    ) -> DashboardConversationRowPresentation {
        let key = conversation.id as NSString
        let meta = DashboardConversationListMeta.resolve(
            conversation: conversation,
            agent: agent,
            foldersByID: foldersByID
        )
        if let cached = conversations.object(forKey: key)?.value,
           cached.conversation == conversation,
           cached.agent == agent,
           cached.meta == meta,
           cached.timeContext == timeContext {
            return cached
        }

        let fallbackPreview = conversation.localRuntimeKind?.displayName
            ?? agent.map(dashboardAgentDisplayName)
            ?? "Conversation"
        let presentation = DashboardConversationRowPresentation(
            conversation: conversation,
            agent: agent,
            title: dashboardListPreview(conversation.title, limit: 160),
            meta: meta,
            preview: ConversationMarkdownDocument.preview(
                conversation.lastMessagePreview?.isEmpty == false
                    ? conversation.lastMessagePreview!
                    : fallbackPreview,
                limit: 160
            ),
            time: dashboardShortTime(conversation.lastMessageAt),
            timeContext: timeContext
        )
        conversations.setObject(DashboardConversationRowPresentationBox(presentation), forKey: key)
        return presentation
    }

    func presentation(for note: WorkspaceNoteRecord) -> DashboardNoteRowPresentation {
        let key = note.id as NSString
        if let cached = notes.object(forKey: key)?.value, cached.note == note {
            return cached
        }

        let document = NoteDocument.decode(note.content)
        let preview: String = switch document.kind {
        case .note:
            dashboardListPreview(document.plainText, limit: 180)
        case .spreadsheet:
            document.blocks.compactMap { block -> String? in
                guard case .table(let table) = block else { return nil }
                return "Spreadsheet · \(table.rows.count) rows × \(table.columns.count) columns"
            }.first ?? "Spreadsheet"
        case .html:
            "Agent-rendered HTML artifact"
        }
        let presentation = DashboardNoteRowPresentation(
            note: note,
            kind: document.kind,
            title: dashboardListPreview(note.title.isEmpty ? "Untitled note" : note.title, limit: 160),
            preview: preview
        )
        notes.setObject(DashboardNoteRowPresentationBox(presentation), forKey: key)
        return presentation
    }
}

struct DashboardRightRailContent: Equatable, Sendable {
    static let empty = DashboardRightRailContent(
        pinnedChats: [],
        recentChats: [],
        pinnedNotes: [],
        notes: []
    )

    let pinnedChats: [DashboardConversationRowPresentation]
    let recentChats: [DashboardConversationRowPresentation]
    let pinnedNotes: [DashboardNoteRowPresentation]
    let notes: [DashboardNoteRowPresentation]

    private init(
        pinnedChats: [DashboardConversationRowPresentation],
        recentChats: [DashboardConversationRowPresentation],
        pinnedNotes: [DashboardNoteRowPresentation],
        notes: [DashboardNoteRowPresentation]
    ) {
        self.pinnedChats = pinnedChats
        self.recentChats = recentChats
        self.pinnedNotes = pinnedNotes
        self.notes = notes
    }

    init(
        conversations: [WorkspaceConversationRecord],
        notes: [WorkspaceNoteRecord],
        agents: [WorkspaceAgent],
        folders: [WorkspaceFolderRecord] = [],
        query: String,
        readFilter: DashboardReadFilter?
    ) {
        let presentationCache = DashboardListPresentationCache.shared
        let timeContext = DashboardListTimeContext.current
        var agentsByCodename: [String: WorkspaceAgent] = [:]
        for agent in agents {
            if Task.isCancelled { break }
            agentsByCodename[agent.codename] = agent
            if let platformCodename = agent.platformCodename {
                agentsByCodename[platformCodename] = agent
            }
        }
        let foldersByID = Dictionary(
            uniqueKeysWithValues: folders.map { ($0.id, $0) }
        )

        var pinnedChats: [DashboardConversationRowPresentation] = []
        var recentChats: [DashboardConversationRowPresentation] = []

        for conversation in conversations {
            if Task.isCancelled { break }
            guard readFilter?.includes(unread: conversation.unread) != false else { continue }

            let agent = conversation.agentCodename.flatMap { agentsByCodename[$0] }
            let meta = DashboardConversationListMeta.resolve(
                conversation: conversation,
                agent: agent,
                foldersByID: foldersByID
            )
            guard query.isEmpty
                    || conversation.title.localizedCaseInsensitiveContains(query)
                    || (conversation.lastMessagePreview?.localizedCaseInsensitiveContains(query) ?? false)
                    || meta.agentLabel.localizedCaseInsensitiveContains(query)
                    || meta.folderLabel.localizedCaseInsensitiveContains(query)
            else { continue }

            let presentation = presentationCache.presentation(
                for: conversation,
                agent: agent,
                foldersByID: foldersByID,
                timeContext: timeContext
            )
            if conversation.isPinned {
                pinnedChats.append(presentation)
            } else {
                recentChats.append(presentation)
            }
        }

        var pinnedNotes: [DashboardNoteRowPresentation] = []
        var unpinnedNotes: [DashboardNoteRowPresentation] = []
        for note in notes {
            if Task.isCancelled { break }
            guard query.isEmpty
                    || note.title.localizedCaseInsensitiveContains(query)
                    || note.content.localizedCaseInsensitiveContains(query)
            else { continue }
            let presentation = presentationCache.presentation(for: note)
            if note.isPinned {
                pinnedNotes.append(presentation)
            } else {
                unpinnedNotes.append(presentation)
            }
        }

        self.pinnedChats = pinnedChats
        self.recentChats = recentChats
        self.pinnedNotes = pinnedNotes
        self.notes = unpinnedNotes
    }
}

enum DashboardListTimeContext {
    static var current: String {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date()).timeIntervalSinceReferenceDate
        return "\(day):\(calendar.timeZone.identifier):\(Locale.current.identifier)"
    }
}
