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
    let onStartRemoteChat: (RemoteHarnessChatTarget) -> Void
    let onSelectFolder: (String?) -> Void
    let onSelectConversation: (String) -> Void
    let onSelectNote: (String) -> Void
    let onCreateAgent: () -> Void
    let onCreateConversation: () -> Void
    let onCreateNote: () -> Void
    let onCreateFolder: (String) -> Void
    let onRenameFolder: (String, String) -> Void
    let onSetFolderPinned: (String, Bool) -> Void
    let onMoveFolder: (String, WorkspaceFolderMoveDirection) -> Void
    let onDeleteFolder: (String) -> Void
    let onMoveConversation: (String, String?) -> Void
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
    let buzzWorkspaceSnapshot: BuzzWorkspaceSnapshot
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
        switch page {
        case .navigation:
            navigationPage
        case .workspace:
            workspacePage
        }
    }

    private var navigationPage: some View {
        DashboardSidebarNavigationPage(
            side: side,
            agents: navigationAgents,
            remoteWorkspaces: remoteWorkspaces,
            buzzWorkspaceSnapshot: buzzWorkspaceSnapshot,
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
            buzzWorkspaceSnapshot: buzzWorkspaceSnapshot,
            folders: folders,
            contentRevision: contentRevision,
            contentScopeID: selectedFolderID,
            selectedConversationID: selectedConversationID,
            selectedNoteID: selectedNoteID,
            selectedFolderName: folders.first(where: { $0.id == selectedFolderID })?.name,
            onCollapse: { actions.onCollapse(side) },
            onBack: style == .split ? nil : actions.onShowNavigation,
            onMove: style == .single ? actions.onMoveSingleRail : nil,
            collapseAtLeadingEdge: adaptiveExpanded && side == .right,
            showsQuickActions: !adaptiveExpanded,
            onCreateChat: actions.onCreateConversation,
            onCreateNote: actions.onCreateNote,
            onSelectConversation: actions.onSelectConversation,
            onSelectNote: actions.onSelectNote,
            onMoveConversation: actions.onMoveConversation,
            onUnavailableMutation: actions.onUnavailableMutation,
            onSurfaceProfileChange: onSurfaceProfileChange
        )
    }

    private var scopedConversations: [WorkspaceConversationRecord] {
        conversations.filter { conversation in
            guard !conversation.isArchived else { return false }
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
    let buzzWorkspaceSnapshot: BuzzWorkspaceSnapshot
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
    let onStartRemoteChat: (RemoteHarnessChatTarget) -> Void
    let onSelectFolder: (String?) -> Void
    let onSelectConversation: (String) -> Void
    let onSelectNote: (String) -> Void
    let onCreateAgent: () -> Void
    let onCreateConversation: () -> Void
    let onCreateNote: () -> Void
    let onCreateFolder: (String) -> Void
    let onRenameFolder: (String, String) -> Void
    let onSetFolderPinned: (String, Bool) -> Void
    let onMoveFolder: (String, WorkspaceFolderMoveDirection) -> Void
    let onDeleteFolder: (String) -> Void
    let onUnavailableMutation: (String) -> Void

    @State private var agentsOpen = true
    @State private var foldersOpen = true
    @State private var recentsOpen = true
    @State private var scrollHoverCoordinator = DashboardScrollHoverCoordinator()
    @State private var showsNewFolderPopover = false
    @State private var newFolderName = ""
    @State private var renamingFolderID: String?
    @State private var renamedFolderName = ""

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

    private var buzzWorkspaceLinks: [DashboardBuzzWorkspaceSidebarLink] {
        let customOrderByWorkspaceID = Dictionary(uniqueKeysWithValues:
            buzzWorkspaceSnapshot.links.map { link in
                (
                    link.id,
                    DashboardAgentOrderStore.order(
                        forKey: DashboardAgentOrderStore.buzzWorkspaceKey(link.id),
                        in: agentOrderRaw
                    )
                )
            }
        )
        return DashboardBuzzWorkspaceSidebarModel.links(
            snapshot: buzzWorkspaceSnapshot,
            agents: agents,
            pinnedIDs: pinnedAgentIDs,
            customOrderByWorkspaceID: customOrderByWorkspaceID
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            railHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    topActions
                    agentsSection
                    foldersSection
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
    }

    private var railHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Agents")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(agents.count) \(agents.count == 1 ? "agent" : "agents")")
                .font(.system(size: 11))
                .foregroundStyle(DashboardPalette.mutedForeground)
            }
            Spacer()
            if let onMove {
                Button(action: onMove) {
                    DashboardLucideIcon(
                        glyph: side == .left ? .panelRightOpen : .panelLeftOpen,
                        size: 16
                    )
                    .frame(
                        width: onCollapse == nil ? 36 : 32,
                        height: onCollapse == nil ? 36 : 32
                    )
                }
                .buttonStyle(DashboardIconButtonStyle())
                .help(side == .left ? "Move sidebar right" : "Move sidebar left")
            }
            if let onCollapse {
                Button(action: onCollapse) {
                    DashboardLucideIcon(
                        glyph: side == .left ? .leftCollapse : .rightCollapse,
                        size: 18
                    )
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(DashboardIconButtonStyle())
                .help(onMove == nil ? "Hide agents" : "Hide sidebar")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 68)
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
                title: "Cron Jobs",
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
                iconColor: DashboardPalette.primary
            ) {
                onUtility(.settings)
            }
        }
        .padding(.bottom, 10)
    }

    private var agentsSection: some View {
        let pinOrder = pinnedAgentOrder
        let pinIDs = pinnedAgentIDs
        return VStack(alignment: .leading, spacing: 0) {
            DashboardDisclosureHeading(title: "Agents", expanded: agentsOpen) { agentsOpen.toggle() }
            if agentsOpen {
                let pinnedAgents = groupAgents(in: .pinned, pinIDs: pinIDs, pinOrder: pinOrder)
                if !pinnedAgents.isEmpty {
                    ForEach(pinnedAgents) { agent in
                        agentRow(
                            agent,
                            moveScope: .pinned,
                            groupAgents: pinnedAgents,
                            isPinned: true
                        )
                    }
                }

                // Direct local agent workspace
                let workspaceAgents = groupAgents(
                    in: .localWorkspace,
                    pinIDs: pinIDs,
                    pinOrder: pinOrder
                )
                agentDisclosureHeading(
                    title: DashboardAgentSidebarGroup.localWorkspace.title,
                    key: DashboardAgentDisclosureKey.localWorkspace
                )
                if agentSectionExpanded(DashboardAgentDisclosureKey.localWorkspace) {
                    if workspaceAgents.isEmpty {
                        agentEmptyLabel("None on this Mac")
                    } else {
                        ForEach(workspaceAgents) { agent in
                            agentRow(
                                agent,
                                moveScope: .stored(
                                    DashboardAgentSidebarGroup.localWorkspace.orderKey
                                ),
                                groupAgents: workspaceAgents,
                                isPinned: false
                            )
                        }
                    }
                }

                agentDisclosureHeading(
                    title: DashboardAgentSidebarGroup.remoteWorkspaces.title,
                    key: DashboardAgentDisclosureKey.remoteWorkspaces
                )
                if agentSectionExpanded(DashboardAgentDisclosureKey.remoteWorkspaces) {
                    if remoteWorkspaceLinks.isEmpty {
                        agentEmptyLabel("No remote workspaces yet")
                    } else {
                        ForEach(remoteWorkspaceLinks) { workspace in
                            remoteWorkspaceSection(workspace)
                        }
                    }
                }

                agentDisclosureHeading(
                    title: DashboardAgentSidebarHeading.buzzWorkspaces,
                    key: DashboardAgentDisclosureKey.buzzWorkspaces
                )
                if agentSectionExpanded(DashboardAgentDisclosureKey.buzzWorkspaces) {
                    if buzzWorkspaceLinks.isEmpty {
                        agentEmptyLabel("No Buzz workspaces linked")
                    } else {
                        ForEach(buzzWorkspaceLinks) { workspace in
                            buzzWorkspaceSection(workspace)
                        }
                    }
                }
            }
        }
    }

    private func groupAgents(
        in group: DashboardAgentSidebarGroup,
        pinIDs: Set<UUID>,
        pinOrder: [UUID]
    ) -> [WorkspaceAgent] {
        let customOrder: [UUID]
        switch group {
        case .pinned:
            customOrder = pinOrder
        case .localWorkspace, .remoteWorkspaces:
            customOrder = DashboardAgentOrderStore.order(for: group, in: agentOrderRaw)
        }
        return DashboardAgentSidebarGroup.agents(
            from: agents,
            in: group,
            pinnedIDs: pinIDs,
            pinOrder: pinOrder,
            customOrder: customOrder
        )
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
        let visibleTargets = workspace.readyTargets.filter { target in
            guard let agent = remoteAgent(for: target) else { return true }
            return !pinnedAgentIDs.contains(agent.id)
        }
        agentDisclosureHeading(
            title: workspace.configuration.name,
            key: key,
            level: 1
        )
        if agentSectionExpanded(key) {
            if visibleTargets.isEmpty {
                agentEmptyLabel(
                    remoteWorkspaceEmptyLabel(
                        workspace,
                        hasPinnedReadyAgent: !workspace.readyTargets.isEmpty
                    ),
                    level: 2
                )
            } else {
                ForEach(visibleTargets) { target in
                    let agent = remoteAgent(for: target)
                    DashboardRailRow(
                        icon: .container,
                        harnessLogo: DashboardHarnessLogo(runtimeKind: target.harness.id),
                        title: target.harness.displayName,
                        hoverID: "remote-harness:\(target.id)",
                        selected: agent.map {
                            destination == .workspace && selectedAgentID == $0.id
                        } ?? false
                    ) {
                        if let agent {
                            onSelectAgent(agent.id)
                        } else {
                            onStartRemoteChat(target)
                        }
                    }
                    .padding(.leading, 16)
                }
            }
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
        _ workspace: DashboardRemoteWorkspaceSidebarLink,
        hasPinnedReadyAgent: Bool
    ) -> String {
        if hasPinnedReadyAgent { return "Ready agents are pinned above" }
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

    @ViewBuilder
    private func buzzWorkspaceSection(_ workspace: DashboardBuzzWorkspaceSidebarLink) -> some View {
        let key = DashboardAgentDisclosureKey.workspace(workspace.id)
        agentDisclosureHeading(
            title: workspace.link.displayName,
            key: key,
            level: 1
        )
        if agentSectionExpanded(key) {
            if workspace.agents.isEmpty {
                agentEmptyLabel(
                    workspace.enrollmentCount == 0
                        ? "No agents enrolled"
                        : "No available enrolled agents",
                    level: 2
                )
            } else {
                ForEach(workspace.agents) { agent in
                    agentRow(
                        agent,
                        moveScope: .stored(
                            DashboardAgentOrderStore.buzzWorkspaceKey(workspace.id)
                        ),
                        groupAgents: workspace.agents,
                        isPinned: false
                    )
                    .padding(.leading, 16)
                }
            }
        }
    }

    private func agentEmptyLabel(_ text: String, level: Int = 0) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(DashboardPalette.mutedForeground)
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
        return DashboardRailRow(
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

    private var foldersSection: some View {
        let itemCounts = folderItemCounts
        let sections = DashboardFolderSections(folders: folders)
        return VStack(alignment: .leading, spacing: 0) {
            DashboardDisclosureHeading(title: "Folders", expanded: foldersOpen) { foldersOpen.toggle() }
                .padding(.top, 8)
            if foldersOpen {
                DashboardRailRow(icon: .plus, title: "New folder", hoverID: "folder:create") {
                    newFolderName = ""
                    showsNewFolderPopover = true
                }
                .popover(isPresented: $showsNewFolderPopover, arrowEdge: .trailing) {
                    DashboardFolderNamePopover(
                        title: "New folder",
                        actionTitle: "Create",
                        name: $newFolderName,
                        onCancel: { showsNewFolderPopover = false },
                        onCommit: {
                            let name = newFolderName.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            guard !name.isEmpty else { return }
                            showsNewFolderPopover = false
                            onCreateFolder(name)
                        }
                    )
                }
                DashboardRailRow(
                    icon: .folderOpen,
                    title: "Workspace",
                    hoverID: "folder:all",
                    selected: selectedFolderID == nil
                ) { onSelectFolder(nil) }
                ForEach(sections.pinned) { folder in
                    folderRow(
                        folder,
                        sectionFolders: sections.pinned,
                        itemCount: itemCounts[folder.id, default: 0]
                    )
                }
                ForEach(sections.unpinned) { folder in
                    folderRow(
                        folder,
                        sectionFolders: sections.unpinned,
                        itemCount: itemCounts[folder.id, default: 0]
                    )
                }
                DashboardRailRow(
                    icon: .trash,
                    title: "Trash",
                    hoverID: "folder:trash"
                ) {
                    onUnavailableMutation("Trash management")
                }
            }
        }
    }

    private func folderRow(
        _ folder: WorkspaceFolderRecord,
        sectionFolders: [WorkspaceFolderRecord],
        itemCount: Int
    ) -> some View {
        let index = sectionFolders.firstIndex(where: { $0.id == folder.id })
        let canMoveUp = index.map { $0 > 0 } ?? false
        let canMoveDown = index.map { $0 < sectionFolders.count - 1 } ?? false
        return DashboardRailRow(
            icon: .folder,
            title: folder.name,
            hoverID: "folder:\(folder.id)",
            trailing: "\(itemCount)",
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
            destructiveMenuTitle: "Move to Trash",
            onDelete: { onDeleteFolder(folder.id) }
        ) {
            onSelectFolder(folder.id)
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
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardDisclosureHeading(title: "Recents", expanded: recentsOpen) { recentsOpen.toggle() }
                .padding(.top, 8)
            if recentsOpen {
                if recentItems.isEmpty {
                    Text("No recent items.")
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardPalette.mutedForeground)
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
                                isRunningConversation: runningConversationIDs.contains(conversation.id)
                            ) {
                                onSelectConversation(conversation.id)
                            }
                        case .note(let note):
                            DashboardRailRow(
                                icon: .fileText,
                                title: note.title,
                                hoverID: "recent-note:\(note.id)"
                            ) {
                                onSelectNote(note.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var folderItemCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for conversation in conversations where !conversation.isArchived {
            if let folderID = conversation.folderID {
                counts[folderID, default: 0] += 1
            }
        }
        for note in notes {
            if let folderID = note.folderID {
                counts[folderID, default: 0] += 1
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

        for conversation in conversations where !conversation.isArchived {
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

enum DashboardNewChatTarget {
    case acpDirect(AgentRuntimeKind)
    case remoteWorkspace(RemoteHarnessChatTarget)
    case buzzWorkspace(BuzzWorkspaceAgentEnrollment)
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
    let onClose: () -> Void
    let onOpenSettings: () -> Void
    let onSelect: (DashboardNewChatTarget) -> Void
    @State private var expandedSources = Set(DashboardNewChatSource.allCases)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Chat")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Choose a local, remote, or Buzz workspace agent")
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
                    DashboardNewChatSection(
                        source: .acpDirect,
                        summary: DashboardNewChatAvailabilitySummary.localCLIs(
                            readyRuntimeCount: model.localACPRuntimeAvailability
                                .filter {
                                    $0.isReady
                                        && model.isLocalACPAgentReady($0.runtimeKind)
                                        && !model.checkingLocalACPRuntimeKinds
                                            .contains($0.runtimeKind)
                                }
                                .count,
                            workspaceIsReady: model.localACPWorkspaceAvailability
                                .isReady
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
                                    detail: isChecking || availability == nil
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
                                isChecking
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

                    DashboardNewChatSection(
                        source: .remoteWorkspace,
                        summary: DashboardNewChatAvailabilitySummary.available(
                            count: model.remoteWorkspaces.readyChatTargets.count
                        ),
                        isExpanded: expansionBinding(for: .remoteWorkspace)
                    ) {
                        if model.remoteWorkspaces.readyChatTargets.isEmpty {
                            DashboardNewChatEmptyCard(
                                icon: .container,
                                title: "No remote harnesses ready",
                                detail: "Start a remote workspace, install a harness, finish setup, and refresh it in Settings."
                            )
                        } else {
                            ForEach(model.remoteWorkspaces.readyChatTargets) { target in
                                Button {
                                    onSelect(.remoteWorkspace(target))
                                } label: {
                                    DashboardNewChatOptionCard(
                                        icon: .container,
                                        harnessLogo: DashboardHarnessLogo(
                                            runtimeKind: target.harness.id
                                        ),
                                        title: target.harness.displayName,
                                        detail: target.configuration.name
                                    )
                                }
                                .buttonStyle(DashboardQuietButtonStyle())
                            }
                        }
                    }

                    DashboardNewChatSection(
                        source: .buzzWorkspace,
                        summary: DashboardNewChatAvailabilitySummary.available(
                            count: model.buzzWorkspaceAgentEnrollments.filter {
                                model.isBuzzWorkspaceAgentLaunchable($0)
                            }.count
                        ),
                        isExpanded: expansionBinding(for: .buzzWorkspace)
                    ) {
                        if model.buzzWorkspaceAgentEnrollments.isEmpty {
                            DashboardNewChatEmptyCard(
                                icon: .bot,
                                title: "No Buzz workspace agents enrolled",
                                detail: "Link a Buzz workspace and explicitly enroll an agent in Settings."
                            )
                        } else {
                            ForEach(model.buzzWorkspaceAgentEnrollments) { enrollment in
                                let context = DashboardBuzzWorkspaceAgentContext.resolve(
                                    enrollment: enrollment,
                                    snapshot: model.buzzWorkspaceSnapshot
                                )
                                Button {
                                    onSelect(.buzzWorkspace(enrollment))
                                } label: {
                                    DashboardNewChatOptionCard(
                                        icon: .bot,
                                        harnessLogo: DashboardHarnessLogo.resolve(
                                            harnessIdentifier: enrollment.harnessIdentifier,
                                            runtimeKind: enrollment.runtimeKind
                                        ),
                                        title: enrollment.displayNameSnapshot,
                                        detail: context?.workspaceLabel
                                            ?? "Linked Buzz workspace"
                                    )
                                }
                                .buttonStyle(DashboardQuietButtonStyle())
                                .disabled(
                                    !model.isBuzzWorkspaceAgentLaunchable(enrollment)
                                )
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
                Button("Workspace agent settings", action: onOpenSettings)
                    .buttonStyle(DashboardPrimaryButtonStyle())
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
                    Text("Choose a note, spreadsheet, or HTML view")
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
                VStack(alignment: .leading, spacing: 10) {
                    artifactButton(
                        "Note",
                        detail: "Create a rich text note",
                        icon: .fileText,
                        kind: .note
                    )
                    artifactButton(
                        "Spreadsheet",
                        detail: "Create an editable spreadsheet",
                        icon: .panelsTopLeft,
                        kind: .spreadsheet
                    )
                    artifactButton(
                        "HTML",
                        detail: "Create an HTML viewer",
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
        detail: String,
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
    let detail: String

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
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(2)
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
    let buzzWorkspaceSnapshot: BuzzWorkspaceSnapshot
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
    let collapseAtLeadingEdge: Bool
    let showsQuickActions: Bool
    let onCreateChat: () -> Void
    let onCreateNote: () -> Void
    let onSelectConversation: (String) -> Void
    let onSelectNote: (String) -> Void
    let onMoveConversation: (String, String?) -> Void
    let onUnavailableMutation: (String) -> Void
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
            let buzzWorkspaceSnapshot = buzzWorkspaceSnapshot
            let folders = folders
            let query = query
            let readFilter = readFilter
            let previous = content
            let buildTask = Task.detached(priority: .userInitiated) {
                let next = DashboardRightRailContent(
                    conversations: conversations,
                    notes: notes,
                    agents: agents,
                    buzzWorkspaceSnapshot: buzzWorkspaceSnapshot,
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
            buzzWorkspaceRevisions: buzzWorkspaceSnapshot.enrollments.map {
                "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)"
            }.joined(separator: ","),
            folderRevisions: folders.map { "\($0.id):\($0.name)" }.joined(separator: ","),
            timeContext: DashboardListTimeContext.current,
            query: query,
            readFilter: readFilter
        )
    }

    private var railHeader: some View {
        HStack(spacing: 8) {
            if collapseAtLeadingEdge {
                collapseButton
            }
            if let onBack {
                Button(action: onBack) {
                    DashboardLucideIcon(glyph: .arrowLeft, size: 16)
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
            VStack(alignment: .leading, spacing: 1) {
                Text(selectedFolderName ?? "Workspace")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(conversations.count) chats · \(notes.count) notes")
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            Spacer()
            if onBack == nil {
                filterMenu(inSearchRow: false)
            }
            if let onMove {
                Button(action: onMove) {
                    DashboardLucideIcon(
                        glyph: side == .left ? .panelRightOpen : .panelLeftOpen,
                        size: 16
                    )
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(DashboardIconButtonStyle())
                .help(side == .left ? "Move sidebar right" : "Move sidebar left")
            }
            if onBack != nil && !collapseAtLeadingEdge {
                collapseButton
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 68)
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
                    readFilter != nil
                        ? DashboardPalette.primary
                        : DashboardPalette.mutedForeground
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
            onMoveConversation: onMoveConversation,
            onUnavailableMutation: onUnavailableMutation
        ) {
            onSelectConversation(presentation.id)
        }
    }

    private func noteRow(_ presentation: DashboardNoteRowPresentation) -> some View {
        DashboardNoteRow(
            presentation: presentation,
            selected: selectedNoteID == presentation.id,
            onUnavailableMutation: onUnavailableMutation
        ) {
            onSelectNote(presentation.id)
        }
    }
}

struct DashboardRightRailContentTaskID: Hashable {
    let revision: Int64
    let scopeID: String?
    let agentRevisions: String
    let buzzWorkspaceRevisions: String
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
    /// Product location bucket, e.g. "Local workspace agents".
    let locationLabel: String
    let locationKind: DashboardConversationLocationKind
    /// Runtime product name when known, e.g. "Codex", "Claude Code".
    let runtimeLabel: String?
    let runtimeKind: AgentRuntimeKind?
    /// Linked workspace is present only for Buzz workspace agents.
    let buzzWorkspaceLabel: String?

    static func resolve(
        conversation: WorkspaceConversationRecord,
        agent: WorkspaceAgent?,
        foldersByID: [String: WorkspaceFolderRecord],
        buzzWorkspaceSnapshot: BuzzWorkspaceSnapshot? = nil
    ) -> DashboardConversationListMeta {
        let agentLabel: String
        let locationLabel: String
        let locationKind: DashboardConversationLocationKind
        let runtimeLabel: String?
        let runtimeKind: AgentRuntimeKind?
        let buzzContext = agent.flatMap { agent in
            buzzWorkspaceSnapshot.flatMap {
                DashboardBuzzWorkspaceAgentContext.resolve(
                    agent: agent,
                    snapshot: $0
                )
            }
        }

        if let agent {
            agentLabel = dashboardAgentDisplayName(agent)
            locationLabel = buzzContext == nil
                ? DashboardConversationLocationKind.resolve(agent.bucket).label
                : "Buzz workspace agent"
            locationKind = buzzContext == nil
                ? DashboardConversationLocationKind.resolve(agent.bucket)
                : .workspaceAgent
            runtimeLabel = agent.runtimeKind.displayName
            runtimeKind = agent.runtimeKind
        } else if let runtime = conversation.localRuntimeKind {
            agentLabel = runtime.displayName
            locationLabel = AgentBucket.localCLIAgents.label
            locationKind = .workspaceAgent
            runtimeLabel = runtime.displayName
            runtimeKind = runtime
        } else if let codename = conversation.agentCodename?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !codename.isEmpty {
            agentLabel = codename
            locationLabel = "Local workspace agents"
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
            folderLabel = "Workspace"
        }

        return DashboardConversationListMeta(
            agentLabel: agentLabel,
            folderLabel: folderLabel,
            locationLabel: locationLabel,
            locationKind: locationKind,
            runtimeLabel: runtimeLabel,
            runtimeKind: runtimeKind,
            buzzWorkspaceLabel: buzzContext?.workspaceLabel
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
            AgentBucket.localCLIAgents.label
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

struct DashboardBuzzWorkspaceAgentContext: Equatable, Sendable {
    let workspaceLabel: String

    static func resolve(
        agent: WorkspaceAgent,
        snapshot: BuzzWorkspaceSnapshot
    ) -> DashboardBuzzWorkspaceAgentContext? {
        guard let enrollment = snapshot.enrollments.first(where: {
            $0.id == agent.id
        }) else { return nil }
        return resolve(enrollment: enrollment, snapshot: snapshot)
    }

    static func resolve(
        enrollment: BuzzWorkspaceAgentEnrollment,
        snapshot: BuzzWorkspaceSnapshot
    ) -> DashboardBuzzWorkspaceAgentContext? {
        guard let link = snapshot.links.first(where: {
            $0.id == enrollment.workspaceLinkID
        }) else { return nil }
        return DashboardBuzzWorkspaceAgentContext(
            workspaceLabel: link.displayName
        )
    }
}

struct DashboardConversationDetailCardState: Equatable, Sendable {
    private(set) var focusedConversationID: String?
    private(set) var hoveredConversationID: String?

    var presentedConversationID: String? {
        hoveredConversationID ?? focusedConversationID
    }

    mutating func setFocused(_ focused: Bool, conversationID: String) {
        if focused {
            focusedConversationID = conversationID
        } else if focusedConversationID == conversationID {
            focusedConversationID = nil
        }
    }

    mutating func setHovered(_ hovered: Bool, conversationID: String) {
        if hovered {
            hoveredConversationID = conversationID
        } else if hoveredConversationID == conversationID {
            hoveredConversationID = nil
        }
    }

    mutating func remove(conversationID: String) {
        if focusedConversationID == conversationID {
            focusedConversationID = nil
        }
        if hoveredConversationID == conversationID {
            hoveredConversationID = nil
        }
    }

    mutating func dismiss() {
        focusedConversationID = nil
        hoveredConversationID = nil
    }

    mutating func completePrimaryAction(conversationID: String, hovered: Bool) {
        focusedConversationID = conversationID
        hoveredConversationID = hovered ? conversationID : nil
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
        if let workspace = meta.buzzWorkspaceLabel {
            details.append("Workspace \(workspace)")
        }
        if !preview.isEmpty {
            details.append("Last message \(preview)")
        }
        if !time.isEmpty {
            details.append("Updated \(time)")
        }
        return DashboardConversationRowAccessibility(
            label: title,
            value: details.joined(separator: ". "),
            hint: "Focus shows chat details. Press to open the chat."
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
        buzzWorkspaceSnapshot: BuzzWorkspaceSnapshot,
        foldersByID: [String: WorkspaceFolderRecord],
        timeContext: String
    ) -> DashboardConversationRowPresentation {
        let key = conversation.id as NSString
        let meta = DashboardConversationListMeta.resolve(
            conversation: conversation,
            agent: agent,
            foldersByID: foldersByID,
            buzzWorkspaceSnapshot: buzzWorkspaceSnapshot
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
        buzzWorkspaceSnapshot: BuzzWorkspaceSnapshot = BuzzWorkspaceSnapshot(
            links: [],
            enrollments: []
        ),
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
                foldersByID: foldersByID,
                buzzWorkspaceSnapshot: buzzWorkspaceSnapshot
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
                buzzWorkspaceSnapshot: buzzWorkspaceSnapshot,
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
