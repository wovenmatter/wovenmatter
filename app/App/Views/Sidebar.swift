import AppKit
import SwiftUI
import WovenProtocol

enum WorkspaceListMode: String, CaseIterable {
    case chats
    case notes
}

enum CompactWorkspacePane: Equatable {
    case chat
    case note
}

struct FolderSections {
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

struct SidebarActions {
    let onCollapse: (SidebarSide) -> Void
    let onMoveSingleRail: () -> Void
    let onShowNavigation: () -> Void
    let onUtility: (WindowDestination) -> Void
    let onSelectFolder: (String?) -> Void
    let onSelectConversation: (String) -> Void
    let onSelectNote: (String) -> Void
    let onCreateAgent: () -> Void
    let onCreateConversation: () -> Void
    let onCreateNote: () -> Void
    /// Name, the machine that will own the folder, and an existing directory to link.
    let onCreateFolder: (String, String, URL?) -> Void
    let onRenameFolder: (String, String) -> Void
    let onSetFolderPinned: (String, Bool) -> Void
    let onMoveFolder: (String, WorkspaceFolderMoveDirection) -> Void
    let onDeleteFolder: (String, Bool) -> Void
    let onSetFolderReferencePaths: (String, [String]) -> Void
    let onCreateChatInFolder: (String?) -> Void
    let onShowTrash: () -> Void
    let onConversationAction: (WorkspaceConversationRecord, ConversationMenuAction) -> Void
    let onNoteAction: (WorkspaceNoteRecord, NoteMenuAction) -> Void
    let onUnavailableMutation: (String) -> Void
    let onSelectBot: (BotTarget) -> Void
    let onOpenBotSettings: () -> Void
}

struct SidebarRail: View {
    let model: ApplicationModel
    let side: SidebarSide
    let page: SidebarPage
    let style: SidebarStyle
    let adaptiveExpanded: Bool
    let agents: [WorkspaceAgent]
    /// This machine first, then the others.
    let machines: [Machine]
    let folders: [WorkspaceFolderRecord]
    let conversations: [WorkspaceConversationRecord]
    let notes: [WorkspaceNoteRecord]
    let runningConversationIDs: Set<String>
    let selectedFolderID: String?
    let selectedConversationID: String?
    let selectedNoteID: String?
    let bots: BotsStore
    let selectedBotTarget: BotTarget?
    let destination: WindowDestination
    @Binding var agentDisclosureRaw: String
    let actions: SidebarActions
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
        .environment(\.sidebarForeground, WovenPalette.foreground)
        .foregroundStyle(WovenPalette.foreground)
        .tint(WovenPalette.foreground)
    }

    private var navigationPage: some View {
        SidebarNavigationPage(
            model: model,
            side: side,
            machines: machines,
            folders: folders,
            conversations: conversations,
            notes: notes,
            runningConversationIDs: runningConversationIDs,
            selectedFolderID: selectedFolderID,
            selectedConversationID: selectedConversationID,
            bots: bots,
            selectedBotTarget: selectedBotTarget,
            destination: destination,
            agentDisclosureRaw: $agentDisclosureRaw,
            onCollapse: adaptiveExpanded ? nil : { actions.onCollapse(side) },
            onMove: style == .split ? nil : actions.onMoveSingleRail,
            actions: actions
        )
    }

    private var workspacePage: some View {
        SidebarWorkspacePage(
            side: side,
            conversations: scopedConversations,
            notes: scopedNotes,
            runningConversationIDs: runningConversationIDs,
            agents: agents,
            machines: machines,
            folders: folders,
            contentScopeID: selectedFolderID,
            selectedConversationID: selectedConversationID,
            selectedNoteID: selectedNoteID,
            selectedFolderName: folders.first(where: { $0.id == selectedFolderID })?.name,
            onCollapse: { actions.onCollapse(side) },
            onBack: style == .split ? nil : actions.onShowNavigation,
            onMove: style == .single ? actions.onMoveSingleRail : nil,
            showsQuickActions: !adaptiveExpanded,
            actions: actions,
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

struct SidebarNavigationPage: View {
    @Environment(\.wovenTheme) private var theme
    let model: ApplicationModel
    let side: SidebarSide
    /// This machine first, then the others.
    let machines: [Machine]
    let folders: [WorkspaceFolderRecord]
    let conversations: [WorkspaceConversationRecord]
    let notes: [WorkspaceNoteRecord]
    let runningConversationIDs: Set<String>
    let selectedFolderID: String?
    let selectedConversationID: String?
    let bots: BotsStore
    let selectedBotTarget: BotTarget?
    let destination: WindowDestination
    @Binding var agentDisclosureRaw: String
    let onCollapse: (() -> Void)?
    let onMove: (() -> Void)?
    let actions: SidebarActions

    @AppStorage(WorkspaceSidebarVisibility.localWorkspace.storageKey)
    private var showsLocalWorkspace = true
    @AppStorage(WorkspaceSidebarVisibility.remoteWorkspaces.storageKey)
    private var showsRemoteWorkspaces = true
    @AppStorage(RemoteWorkspaceSidebarStore.namesKey)
    private var remoteWorkspaceNamesRaw = ""
    @AppStorage(RemoteWorkspaceSidebarStore.orderKey)
    private var remoteWorkspaceOrderRaw = ""

    @State private var presentedFolderID: String?
    @State private var recentsOpen = true
    @State private var scrollHoverCoordinator = ScrollHoverCoordinator()
    @State private var creatingFolderWorkspaceKey: String?
    @State private var renamingFolderID: String?
    @State private var renamedFolderName = ""
    @State private var deletingFolder: WorkspaceFolderRecord?
    @State private var editingReferenceFolderID: String?
    @State private var renamingMachineID: String?
    @State private var renamedMachineName = ""

    private var thisMachine: Machine? { machines.first(where: \.isThisMachine) }

    /// The remote workspaces in the order the person set in the sidebar.
    private var otherMachines: [Machine] {
        RemoteWorkspaceSidebarStore.ordered(machines.filter { !$0.isThisMachine }, in: remoteWorkspaceOrderRaw)
    }

    var body: some View {
        VStack(spacing: 0) {
            railHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    BotsSidebar(
                        bots: bots,
                        selectedTarget: selectedBotTarget,
                        isWorkspaceDestination: destination == .workspace,
                        disclosureRaw: $agentDisclosureRaw,
                        onSelect: actions.onSelectBot,
                        onOpenSettings: actions.onOpenBotSettings
                    )
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
            .environment(\.scrollHoverCoordinator, scrollHoverCoordinator)
            .onScrollPhaseChange { _, phase in
                scrollHoverCoordinator.setScrolling(phase.isScrolling)
            }
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
                let workspaceCount = otherMachines.count + 1
                Text("\(workspaceCount) \(workspaceCount == 1 ? "workspace" : "workspaces")")
                .font(.system(size: 11))
                .foregroundStyle(WovenPalette.foreground)
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
                LucideIcon(glyph: .arrowLeftRight, size: 16)
                    .frame(
                        width: onCollapse == nil ? 36 : 32,
                        height: onCollapse == nil ? 36 : 32
                    )
            }
            .buttonStyle(WovenIconButtonStyle())
            .help(side == .left ? "Move sidebar right" : "Move sidebar left")
        }
    }

    @ViewBuilder
    private var collapseButton: some View {
        if let onCollapse {
            Button(action: onCollapse) {
                LucideIcon(
                    glyph: side == .left ? .leftCollapse : .rightCollapse,
                    size: 18
                )
                .frame(width: 36, height: 36)
            }
            .buttonStyle(WovenIconButtonStyle())
            .help("Hide sidebar")
        }
    }

    private var topActions: some View {
        VStack(spacing: 1) {
            RailRow(icon: .squarePen, title: "New chat", hoverID: "action:new-chat") {
                actions.onCreateConversation()
            }
            NewArtifactButton(action: actions.onCreateNote)
            RailRow(
                icon: .calendarDays,
                title: "Calendar",
                hoverID: "destination:calendar",
                selected: destination == .calendar
            ) {
                actions.onUtility(.calendar)
            }
            RailRow(
                icon: .calendarClock,
                title: "Scheduled Tasks",
                hoverID: "destination:cron-jobs",
                selected: destination == .cronJobs
            ) {
                actions.onUtility(.cronJobs)
            }
            RailRow(
                icon: .libraryBig,
                title: "Library",
                hoverID: "destination:library",
                selected: destination == .library
            ) {
                actions.onUtility(.library)
            }
            RailRow(
                icon: .database,
                title: "Databases",
                hoverID: "destination:databases",
                selected: destination == .databases
            ) {
                actions.onUtility(.databases)
            }
            RailRow(
                icon: .barChart,
                title: "Usage",
                hoverID: "destination:usage",
                selected: destination == .usage
            ) {
                actions.onUtility(.usage)
            }
            RailRow(
                icon: .settings,
                title: "Settings",
                hoverID: "destination:settings",
                selected: destination == .settings,
                iconColor: WovenPalette.foreground
            ) {
                actions.onUtility(.settings)
            }
        }
        .padding(.bottom, 10)
    }

    private var workspacesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsLocalWorkspace {
                let key = AgentDisclosureKey.localWorkspace
                agentDisclosureHeading(title: "Local workspace", key: key)
                if agentSectionExpanded(key) {
                    workspaceContents(key: key, title: "Local workspace", machine: thisMachine)
                        .padding(.leading, 8)
                }
            }
            if showsRemoteWorkspaces {
                let key = AgentDisclosureKey.remoteWorkspaces
                agentDisclosureHeading(title: "Remote workspaces", key: key)
                if agentSectionExpanded(key) {
                    VStack(alignment: .leading, spacing: 0) {
                        if otherMachines.isEmpty {
                            agentEmptyLabel("No remote workspaces yet")
                        }
                        let ordered = otherMachines
                        ForEach(ordered) { machine in
                            machineSection(machine, ordered: ordered)
                        }
                    }
                    .padding(.leading, 8)
                }
            }
        }
    }

    /// One machine's folders. A new folder is created by that machine on its own disk.
    @ViewBuilder
    private func workspaceContents(
        key: String,
        title: String,
        machine: Machine?
    ) -> some View {
        let sections = FolderSections(folders: machine.map { machine in folders.filter { $0.machineID == machine.id } } ?? [])
        let counts = folderContentCounts
        let workspaceTitle = machine.map {
            $0.isThisMachine ? $0.name : RemoteWorkspaceSidebarStore.name(of: $0, in: remoteWorkspaceNamesRaw)
        } ?? title
        VStack(alignment: .leading, spacing: 0) {
            newFolderRow(key: key, machine: machine, workspaceTitle: workspaceTitle)
            ForEach(sections.pinned) { folder in
                folderRow(folder, sectionFolders: sections.pinned,
                          counts: counts[folder.id, default: .init()], workspaceTitle: workspaceTitle)
            }
            ForEach(sections.unpinned) { folder in
                folderRow(folder, sectionFolders: sections.unpinned,
                          counts: counts[folder.id, default: .init()], workspaceTitle: workspaceTitle)
            }
        }
    }

    private func agentSectionExpanded(_ key: String) -> Bool {
        AgentDisclosureStore.isExpanded(key, in: agentDisclosureRaw)
    }

    private func agentDisclosureHeading(
        title: String,
        key: String
    ) -> some View {
        DisclosureHeading(
            title: title,
            expanded: agentSectionExpanded(key)
        ) {
            AgentDisclosureStore.toggle(key, in: &agentDisclosureRaw)
        }
    }

    /// Another machine, online or offline, titled by its sidebar name.
    @ViewBuilder
    private func machineSection(_ machine: Machine, ordered: [Machine]) -> some View {
        let key = AgentDisclosureKey.machine(machine.id)
        let name = RemoteWorkspaceSidebarStore.name(of: machine, in: remoteWorkspaceNamesRaw)
        let index = ordered.firstIndex(where: { $0.id == machine.id })
        agentDisclosureHeading(title: name, key: key)
            .contextMenu {
                Button {
                    RemoteWorkspaceSidebarStore.move(machine.id, by: -1, among: ordered, in: &remoteWorkspaceOrderRaw)
                } label: {
                    Label {
                        Text("Move up")
                    } icon: {
                        LucideIcon(glyph: .arrowUp, size: 12)
                    }
                }
                .disabled(index.map { $0 == 0 } ?? true)
                Button {
                    RemoteWorkspaceSidebarStore.move(machine.id, by: 1, among: ordered, in: &remoteWorkspaceOrderRaw)
                } label: {
                    Label {
                        Text("Move down")
                    } icon: {
                        LucideIcon(glyph: .arrowDown, size: 12)
                    }
                }
                .disabled(index.map { $0 == ordered.count - 1 } ?? true)
                Button("Rename") {
                    renamedMachineName = name
                    renamingMachineID = machine.id
                }
            }
            .popover(
                isPresented: Binding(
                    get: { renamingMachineID == machine.id },
                    set: { if !$0, renamingMachineID == machine.id { renamingMachineID = nil } }
                ),
                arrowEdge: .trailing
            ) {
                FolderNamePopover(
                    title: "Rename workspace",
                    placeholder: "Workspace name",
                    actionTitle: "Rename",
                    name: $renamedMachineName,
                    onCancel: { renamingMachineID = nil },
                    onCommit: {
                        renamingMachineID = nil
                        RemoteWorkspaceSidebarStore.rename(machine, to: renamedMachineName, in: &remoteWorkspaceNamesRaw)
                    }
                )
            }
        if agentSectionExpanded(key) {
            workspaceContents(key: key, title: name, machine: machine)
        }
    }

    private func agentEmptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(WovenPalette.foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    private func newChatButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LucideIcon(glyph: .plus, size: 12)
                .frame(width: 24, height: WovenMetrics.rowHeight)
        }
        .buttonStyle(WovenIconButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    private func newFolderRow(key: String, machine: Machine?, workspaceTitle: String) -> some View {
        RailRow(icon: .plus, title: "New folder", hoverID: "folder:create:" + key) {
            creatingFolderWorkspaceKey = key
        }
        .popover(isPresented: Binding(
            get: { creatingFolderWorkspaceKey == key },
            set: { if !$0 { creatingFolderWorkspaceKey = nil } }
        ), arrowEdge: .trailing) {
            NewFolderPopover(
                workspace: model.workspace,
                machine: machine,
                workspaceTitle: workspaceTitle,
                onCancel: { creatingFolderWorkspaceKey = nil },
                onCreate: { name, machineID, externalRoot in
                    creatingFolderWorkspaceKey = nil
                    actions.onCreateFolder(name, machineID, externalRoot)
                }
            )
        }
    }

    private var allWorkspacesRow: some View {
        HStack(spacing: 0) {
            RailRow(
                icon: .folderOpen, title: "All Workspaces", hoverID: "folder:all",
                selected: selectedFolderID == nil
            ) { actions.onSelectFolder(nil) }
            newChatButton(label: "New chat in All Workspaces") { actions.onCreateChatInFolder(nil) }
        }
        .padding(.bottom, 8)
    }

    private var trashRow: some View {
        RailRow(icon: .trash, title: "Trash", hoverID: "folder:trash") {
            actions.onShowTrash()
        }
        .padding(.top, 8)
    }

    private func folderRow(
        _ folder: WorkspaceFolderRecord,
        sectionFolders: [WorkspaceFolderRecord],
        counts: FolderContentCounts,
        workspaceTitle: String
    ) -> some View {
        let index = sectionFolders.firstIndex(where: { $0.id == folder.id })
        let canMoveUp = index.map { $0 > 0 } ?? false
        let canMoveDown = index.map { $0 < sectionFolders.count - 1 } ?? false
        return HStack(spacing: 0) {
            RailRow(
                icon: .folder,
                title: folder.name,
                hoverID: "folder:\(folder.id)",
                trailing: "\(counts.total)",
                showsPin: folder.isPinned,
                selected: selectedFolderID == folder.id,
                pinMenuTitle: folder.isPinned ? "Unpin" : "Pin",
                onTogglePin: { actions.onSetFolderPinned(folder.id, !folder.isPinned) },
                moveUpTitle: "Move up",
                moveUpEnabled: canMoveUp,
                onMoveUp: { actions.onMoveFolder(folder.id, .up) },
                moveDownTitle: "Move down",
                moveDownEnabled: canMoveDown,
                onMoveDown: { actions.onMoveFolder(folder.id, .down) },
                renameMenuTitle: "Rename",
                onRename: {
                    renamedFolderName = folder.name
                    renamingFolderID = folder.id
                },
                exportMenuTitle: "Export content",
                onExport: { actions.onUnavailableMutation("Folder export") },
                referenceMenuTitle: "Reference locations…",
                onManageReferences: { editingReferenceFolderID = folder.id },
                destructiveMenuTitle: "Remove folder…",
                onDelete: { deletingFolder = folder },
                folderDetails: FolderHoverDetails(
                    folder: folder, workspaceTitle: workspaceTitle, counts: counts
                ),
                presentedFolderID: $presentedFolderID
            ) {
                actions.onSelectFolder(folder.id)
            }
            newChatButton(label: "New chat in \(folder.name)") { actions.onCreateChatInFolder(folder.id) }
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
            FolderNamePopover(
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
                    actions.onRenameFolder(folder.id, name)
                }
            )
        }
        .popover(isPresented: Binding(
            get: { editingReferenceFolderID == folder.id },
            set: { if !$0 { editingReferenceFolderID = nil } }
        ), arrowEdge: .trailing) {
            FolderReferencesPopover(
                folder: folder,
                isOnThisMac: folder.machineID == thisMachine?.id,
                onClose: { editingReferenceFolderID = nil },
                onChange: { actions.onSetFolderReferencePaths(folder.id, $0) }
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
                actions.onDeleteFolder(folder.id, false)
            }
            if folder.managedRoot {
                Button("Delete Folder and Directory", role: .destructive) {
                    deletingFolder = nil
                    actions.onDeleteFolder(folder.id, true)
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
            DisclosureHeading(title: "Recents", expanded: recentsOpen) { recentsOpen.toggle() }
                .padding(.top, 8)
            if recentsOpen {
                if recentItems.isEmpty {
                    Text("No recent items.")
                        .font(.system(size: 12))
                        .foregroundStyle(WovenPalette.foreground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                } else {
                    ForEach(recentItems) { item in
                        switch item {
                        case .conversation(let conversation):
                            RailRow(
                                icon: .messageSquare,
                                title: conversation.title,
                                hoverID: "recent-conversation:\(conversation.id)",
                                selected: selectedConversationID == conversation.id,
                                isRunningConversation: runningConversationIDs.contains(conversation.id),
                                conversationID: conversation.id
                            ) {
                                actions.onSelectConversation(conversation.id)
                            }
                            .modifier(ConversationContextMenu(
                                conversation: conversation,
                                folders: folders,
                                isRunning: runningConversationIDs.contains(conversation.id),
                                onAction: actions.onConversationAction
                            ))
                        case .note(let note):
                            RailRow(
                                icon: .fileText,
                                title: note.title,
                                hoverID: "recent-note:\(note.id)"
                            ) {
                                actions.onSelectNote(note.id)
                            }
                            .modifier(NoteContextMenu(
                                note: note,
                                folders: folders,
                                onAction: actions.onNoteAction
                            ))
                        }
                    }
                }
            }
        }
    }

    private var folderContentCounts: [String: FolderContentCounts] {
        var counts: [String: FolderContentCounts] = [:]
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

    private var recentItems: [RecentItem] {
        var items: [RecentItem] = []

        func insert(_ item: RecentItem) {
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

enum RecentItem: Identifiable {
    case conversation(WorkspaceConversationRecord)
    case note(WorkspaceNoteRecord)

    var id: String {
        switch self {
        case .conversation(let value): "conversation:\(value.id)"
        case .note(let value): "note:\(value.id)"
        }
    }

    var activityTimestamp: Date {
        let timestamp: Date? = switch self {
        case .conversation(let conversation): conversation.lastMessageAt
        case .note(let note): note.updatedAt ?? note.createdAt
        }
        return timestamp ?? .distantPast
    }

    func ranksBefore(_ other: RecentItem) -> Bool {
        if activityTimestamp != other.activityTimestamp {
            return activityTimestamp > other.activityTimestamp
        }
        return id > other.id
    }
}

struct NewFolderPopover: View {
    let workspace: WorkspaceStore
    /// The machine that will own the folder.
    let machine: Machine?
    let workspaceTitle: String
    let onCancel: () -> Void
    let onCreate: (String, String, URL?) -> Void
    @State private var name = ""
    @State private var linksExistingDirectory = false
    @State private var externalRoot: URL?
    @State private var browsingMachine = false
    @FocusState private var nameFocused: Bool

    private var ownerIsAvailable: Bool {
        machine?.isOnline == true
    }

    private var canCreate: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ownerIsAvailable && !trimmed.isEmpty
            && (linksExistingDirectory ? externalRoot != nil : !trimmed.contains("/") && trimmed != "." && trimmed != "..")
    }

    /// Another machine's directories are browsed through its server; this
    /// Mac's through the open panel.
    private var otherMachine: Machine? {
        machine.flatMap { $0.isThisMachine ? nil : $0 }
    }

    var body: some View {
        Group {
            if browsingMachine, let otherMachine {
                MachineDirectoryBrowser(
                    workspaceTitle: workspaceTitle,
                    load: { try await workspace.directories(on: otherMachine.id, path: $0) },
                    initialPath: externalRoot?.path,
                    onChoose: { path in
                        externalRoot = URL(fileURLWithPath: path)
                        if name.isEmpty { name = externalRoot?.lastPathComponent ?? "" }
                        browsingMachine = false
                    },
                    onBack: { browsingMachine = false }
                )
            } else {
                form
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(WovenPalette.foreground)
        .padding(16)
        .frame(width: 340)
        .formFocusDismissal { nameFocused = false }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Folder").font(.system(size: 14, weight: .semibold))
            Text(workspaceTitle)
                .font(.system(size: 11.5))
                .foregroundStyle(WovenPalette.mutedForeground)
            if machine != nil {
                Picker("Directory", selection: $linksExistingDirectory) {
                    Text("Create New").tag(false)
                    Text("Link Existing").tag(true)
                }
                .pickerStyle(.segmented)
            }
            TextField("Folder name", text: $name)
                .focused($nameFocused)
                .quietTextInput()
                .onSubmit { if canCreate { create() } }
            if linksExistingDirectory {
                Button(externalRoot?.path ?? "Choose directory…") {
                    if otherMachine == nil { chooseDirectory() } else { browsingMachine = true }
                }
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Woven uses this directory as the project root. Existing files are preserved.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
            } else {
                Text("Creates a blank directory in this workspace. Later renaming changes only its name in Woven.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
            if !ownerIsAvailable {
                Text("Connect this workspace before creating a folder.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(WovenPalette.danger)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(linksExistingDirectory ? "Link" : "Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        // Runs each time the form shows, so returning from the browser focuses the name again.
        .task { nameFocused = true }
    }

    private func create() {
        guard canCreate, let machine else { return }
        onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines), machine.id,
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

struct FolderReferencesPopover: View {
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
                .foregroundStyle(WovenPalette.mutedForeground)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(paths, id: \.self) { path in
                        HStack(spacing: 8) {
                            Text(path).font(.system(size: 11.5)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { paths.removeAll { $0 == path } } label: {
                                LucideIcon(glyph: .close, size: 12).frame(width: 24, height: 24)
                            }
                            .buttonStyle(WovenIconButtonStyle())
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
                        .quietTextInput()
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
        .formFocusDismissal { pathFocused = false }
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

enum NewChatAvailabilitySummary {
    static func available(count: Int) -> String {
        "\(count) available"
    }
}

struct DrawerChrome<Heading: View, Content: View>: View {
    @Environment(\.wovenTheme) private var theme
    let onClose: () -> Void
    let heading: Heading
    let content: Content

    init(
        onClose: @escaping () -> Void,
        @ViewBuilder heading: () -> Heading,
        @ViewBuilder content: () -> Content
    ) {
        self.onClose = onClose
        self.heading = heading()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    heading
                }
                Spacer()
                Button(action: onClose) {
                    LucideIcon(glyph: .close, size: 16)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(WovenIconButtonStyle())
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 72)

            Divider().overlay(theme.palette.border)

            ScrollView {
                content
            }
            .scrollIndicators(.never)

            Divider().overlay(theme.palette.border)
            HStack {
                Button("Cancel", action: onClose)
                    .buttonStyle(WovenQuietButtonStyle())
                Spacer()
            }
            .padding(16)
        }
        .background(theme.palette.workspace)
        .clipShape(DesktopShapes.windowAlignedSurface)
        .overlay {
            DesktopShapes.windowAlignedSurface
                .stroke(theme.palette.border, lineWidth: 1)
        }
        .shadow(
            color: WovenPalette.foreground.opacity(0.16),
            radius: 34,
            x: -10
        )
        .padding(8)
    }
}

struct NewChatDrawer: View {
    @Bindable var model: ApplicationModel
    /// The machine of the selected folder: only its agents can start a chat there.
    let folderMachineID: String?
    let onClose: () -> Void
    let onSelect: (WorkspaceAgent) -> Void
    @State private var expandedSources = Set(NewChatSource.allCases)

    private var thisMachine: Machine? { model.machines.thisMachine }

    private var localAgents: [WorkspaceAgent] {
        guard let thisMachine else { return [] }
        return model.workspace.agents(on: thisMachine.id).sorted { $0.runtimeKind.presentationRank < $1.runtimeKind.presentationRank }
    }

    /// Every other machine's agents, listed under that machine's name.
    private var remoteAgents: [(agent: WorkspaceAgent, machine: Machine)] {
        model.machines.otherMachines.flatMap { machine in
            model.workspace.agents(on: machine.id)
                .filter { _ in folderMachineID == nil || folderMachineID == machine.id }
                .sorted { $0.runtimeKind.presentationRank < $1.runtimeKind.presentationRank }
                .map { (agent: $0, machine: machine) }
        }
    }

    private func isReady(_ agent: WorkspaceAgent) -> Bool {
        agent.status == .ready || agent.status == .running
    }

    private func detail(_ agent: WorkspaceAgent, on machine: Machine?) -> String {
        switch agent.status {
        case .ready, .running: machine?.name ?? agent.runtimeKind.displayName
        case .needsAuthentication: "Sign in — see Settings"
        case .settingUp: "Setting up — see Settings"
        case .adapterRequired: "Adapter required — see Settings"
        case .starting: "Workspace is starting"
        case .offline: machine?.connection == .offline ? "Workspace is offline" : "Workspace is stopped"
        case .failed: "Unavailable — see Settings"
        }
    }

    var body: some View {
        DrawerChrome(onClose: onClose) {
            Text("New Chat")
                .font(.system(size: 18, weight: .semibold))
            Text("Choose an agent.")
                .font(.system(size: 11.5))
                .foregroundStyle(WovenPalette.mutedForeground)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if folderMachineID == nil || folderMachineID == thisMachine?.id {
                    NewChatSection(
                        source: .acpDirect,
                        summary: NewChatAvailabilitySummary.available(count: localAgents.filter(isReady).count),
                        isExpanded: expansionBinding(for: .acpDirect)
                    ) {
                        ForEach(localAgents) { agent in
                            Button {
                                onSelect(agent)
                            } label: {
                                NewChatOptionCard(
                                    icon: .terminal,
                                    harnessLogo: HarnessLogo(runtimeKind: agent.runtimeKind),
                                    title: agentDisplayName(agent),
                                    detail: detail(agent, on: nil)
                                )
                            }
                            .buttonStyle(WovenQuietButtonStyle())
                            .disabled(!isReady(agent))
                        }
                    }
                }
                NewChatSection(
                    source: .remoteWorkspace,
                    summary: NewChatAvailabilitySummary.available(count: remoteAgents.filter { isReady($0.agent) }.count),
                    isExpanded: expansionBinding(for: .remoteWorkspace)
                ) {
                    if remoteAgents.isEmpty {
                        NewChatEmptyCard(
                            icon: .container,
                            title: "No remote agents ready",
                            detail: "Set up a remote agent in Settings."
                        )
                    } else {
                        ForEach(remoteAgents, id: \.agent.id) { target in
                            Button {
                                onSelect(target.agent)
                            } label: {
                                NewChatOptionCard(
                                    icon: target.machine.platform == .mac ? .monitor : .container,
                                    harnessLogo: HarnessLogo(runtimeKind: target.agent.runtimeKind),
                                    title: agentDisplayName(target.agent),
                                    detail: detail(target.agent, on: target.machine)
                                )
                            }
                            .buttonStyle(WovenQuietButtonStyle())
                            .disabled(!isReady(target.agent))
                            .accessibilityLabel("\(agentDisplayName(target.agent)) on \(target.machine.name)")
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func expansionBinding(
        for source: NewChatSource
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

struct NewNoteDrawer: View {
    let onClose: () -> Void
    let onSelect: (NoteArtifactKind) -> Void

    var body: some View {
        DrawerChrome(onClose: onClose) {
            Text("New Artifact")
                .font(.system(size: 18, weight: .semibold))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                // Each kind uses the same icon as its asset rows.
                artifactButton("Note", detail: "A rich text note with lists, tables and links", icon: .fileText, kind: .note)
                artifactButton("Page", detail: "A fluid document for your work with agents", icon: .panelsTopLeft, kind: .canvas)
                artifactButton("Sheet", detail: "Rows and columns for data and calculations", systemImage: "tablecells", kind: .spreadsheet)
                artifactButton("App", detail: "Interactive apps your agent builds on live data",
                    systemImage: "chevron.left.forwardslash.chevron.right", kind: .html)
            }
            .padding(20)
        }
    }

    private func artifactButton(
        _ title: String,
        detail: String? = nil,
        icon: LucideGlyph = .fileText,
        systemImage: String? = nil,
        kind: NoteArtifactKind
    ) -> some View {
        Button {
            onClose()
            onSelect(kind)
        } label: {
            NewChatOptionCard(
                icon: icon,
                systemImage: systemImage,
                title: title,
                detail: detail
            )
        }
        .buttonStyle(WovenQuietButtonStyle())
        .accessibilityLabel(title)
    }
}

struct NewChatSection<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let source: NewChatSource
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
                        .foregroundStyle(WovenPalette.mutedForeground)
                    LucideIcon(glyph: .chevronDown, size: 14)
                        .foregroundStyle(WovenPalette.mutedForeground)
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

struct NewChatOptionCard: View {
    let icon: LucideGlyph
    /// A system symbol in place of `icon`, matching assets whose rows use one.
    var systemImage: String? = nil
    var harnessLogo: HarnessLogo? = nil
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let harnessLogo {
                    HarnessLogoIcon(logo: harnessLogo, size: 20)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(WovenPalette.primary)
                } else {
                    LucideIcon(glyph: icon, size: 16)
                        .foregroundStyle(WovenPalette.primary)
                }
            }
            .frame(width: 36, height: 36)
            .background(WovenPalette.muted)
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
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .lineLimit(2)
                }
            }
            Spacer()
            LucideIcon(glyph: .arrowRight, size: 14)
        }
        .padding(12)
        .contentShape(Rectangle())
    }
}

struct NewChatEmptyCard: View {
    let icon: LucideGlyph
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            LucideIcon(glyph: icon, size: 16)
                .foregroundStyle(WovenPalette.mutedForeground)
                .frame(width: 36, height: 36)
                .background(WovenPalette.muted)
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
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(12)
        .background(WovenPalette.muted.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SidebarWorkspacePage: View {
    @Environment(\.wovenTheme) private var theme
    let side: SidebarSide
    let conversations: [WorkspaceConversationRecord]
    let notes: [WorkspaceNoteRecord]
    let runningConversationIDs: Set<String>
    let agents: [WorkspaceAgent]
    let machines: [Machine]
    let folders: [WorkspaceFolderRecord]
    let contentScopeID: String?
    let selectedConversationID: String?
    let selectedNoteID: String?
    let selectedFolderName: String?
    @AppStorage("wovenmatter.layout.workspace-mode") private var modeRawValue = WorkspaceListMode.chats.rawValue
    let onCollapse: () -> Void
    let onBack: (() -> Void)?
    let onMove: (() -> Void)?
    let showsQuickActions: Bool
    let actions: SidebarActions
    let onSurfaceProfileChange: () -> Void

    @State private var query = ""
    @State private var readFilter: ReadFilter?
    @State private var filterHovered = false
    @State private var showsReadFilterMenu = false
    @State private var pinnedOpen = true
    @State private var recentsOpen = true
    @State private var scrollHoverCoordinator = ScrollHoverCoordinator()
    @State private var content = RightRailContent.empty
    @State private var assetKind: NoteArtifactKind?
    @State private var conversationDetailCardState = ConversationDetailCardState()

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
                    if mode == .notes {
                        Menu {
                            Button("All artifacts") { assetKind = nil }
                            ForEach(NoteArtifactKind.allCases, id: \.self) { kind in
                                Button(kind.displayName + "s") { assetKind = kind }
                            }
                        } label: {
                            Image(systemName: assetKind == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                                .frame(width: 28, height: 28)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Artifact type: \(assetKind.map { $0.displayName + "s" } ?? "All artifacts")")
                        .help("Filter by Notes, Pages, Sheets, or Apps")
                    }
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
                        ListSectionHeader(title: "Pinned chats", expanded: pinnedOpen) {
                            pinnedOpen.toggle()
                        }
                        if pinnedOpen {
                            if content.pinnedChats.isEmpty {
                                EmptyListRow(text: "No pinned chats.")
                            } else {
                                ForEach(content.pinnedChats) { presentation in
                                    conversationRow(presentation)
                                }
                            }
                        }

                        ListSectionHeader(title: "Recents", expanded: recentsOpen) {
                            recentsOpen.toggle()
                        }
                        if recentsOpen {
                            if content.recentChats.isEmpty {
                                EmptyListRow(text: "No recent chats.")
                            } else {
                                ForEach(content.recentChats) { presentation in
                                    conversationRow(presentation)
                                }
                            }
                        }
                    } else {
                        ListSectionHeader(title: "Pinned artifacts", expanded: pinnedOpen) {
                            pinnedOpen.toggle()
                        }
                        if pinnedOpen {
                            if content.pinnedNotes.filter({ assetKind == nil || $0.kind == assetKind }).isEmpty {
                                EmptyListRow(text: "No pinned artifacts.")
                            } else {
                                ForEach(content.pinnedNotes.filter { assetKind == nil || $0.kind == assetKind }) { presentation in
                                    noteRow(presentation)
                                }
                            }
                        }

                        ListSectionHeader(title: "Artifacts", expanded: recentsOpen) {
                            recentsOpen.toggle()
                        }
                        if recentsOpen {
                            if content.notes.filter({ assetKind == nil || $0.kind == assetKind }).isEmpty {
                                EmptyListRow(text: "No artifacts.")
                            } else {
                                ForEach(content.notes.filter { assetKind == nil || $0.kind == assetKind }) { presentation in
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
            .environment(\.scrollHoverCoordinator, scrollHoverCoordinator)
            .onScrollPhaseChange { _, phase in
                scrollHoverCoordinator.setScrolling(phase.isScrolling)
            }
        }
        .task(id: contentTaskID) {
            let conversations = conversations
            let notes = notes
            let agents = agents
            let machines = machines
            let folders = folders
            let query = query
            let readFilter = readFilter
            let previous = content
            let buildTask = Task.detached(priority: .userInitiated) {
                let next = RightRailContent(
                    conversations: conversations,
                    notes: notes,
                    agents: agents,
                    machines: machines,
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

    private var contentTaskID: RightRailContentTaskID {
        RightRailContentTaskID(
            conversations: conversations,
            notes: notes,
            scopeID: contentScopeID,
            agents: agents,
            machines: machines,
            folderRevisions: folders.map { "\($0.id):\($0.name)" }.joined(separator: ","),
            timeContext: ListTimeContext.current,
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
                Text("\(conversations.count) chats · \(notes.count) artifacts")
                    .font(.system(size: 11))
                    .foregroundStyle(WovenPalette.foreground)
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
                LucideIcon(
                    glyph: side == .left ? .arrowLeft : .arrowRight,
                    size: 16
                )
                .frame(width: 32, height: 32)
            }
            .buttonStyle(WovenIconButtonStyle())
            .help("Back to Workspace")
            .accessibilityLabel("Back to Workspace")
        } else {
            Button(action: onCollapse) {
                LucideIcon(glyph: .rightCollapse, size: 18)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(WovenIconButtonStyle())
            .help("Hide workspace")
        }
    }

    @ViewBuilder
    private var moveButton: some View {
        if let onMove {
            Button(action: onMove) {
                LucideIcon(glyph: .arrowLeftRight, size: 16)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(WovenIconButtonStyle())
            .help(side == .left ? "Move sidebar right" : "Move sidebar left")
        }
    }

    private var collapseButton: some View {
        Button(action: onCollapse) {
            LucideIcon(
                glyph: side == .left ? .leftCollapse : .rightCollapse,
                size: 18
            )
            .frame(width: 36, height: 36)
        }
        .buttonStyle(WovenIconButtonStyle())
        .help("Hide sidebar")
    }

    private func filterMenu(inSearchRow: Bool) -> some View {
        Button {
            showsReadFilterMenu.toggle()
        } label: {
            LucideIcon(glyph: .listFilter, size: 14)
                .foregroundStyle(
                    WovenPalette.foreground
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

    private func readFilterButton(_ value: ReadFilter, title: String) -> some View {
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
            RailRow(
                icon: .squarePen,
                title: "New chat",
                hoverID: "folder-action:new-chat",
                action: actions.onCreateConversation
            )
            NewArtifactButton(
                hoverID: "folder-action:new-note",
                action: actions.onCreateNote
            )
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }

    private var modePicker: some View {
        WovenSegmentedSelector(
            options: WorkspaceListMode.allCases,
            selection: modeBinding
        ) { value in
            value == .chats ? "Chats" : "Artifacts"
        }
    }

    private var searchField: some View {
        WovenSearchField(
            text: $query,
            prompt: mode == .chats ? "Search chats" : "Search artifacts"
        )
    }

    private func conversationRow(_ presentation: ConversationRowPresentation) -> some View {
        ConversationRow(
            presentation: presentation,
            selected: selectedConversationID == presentation.id,
            isRunning: runningConversationIDs.contains(presentation.id),
            detailCardState: $conversationDetailCardState,
            folders: folders,
            onConversationAction: actions.onConversationAction
        ) {
            actions.onSelectConversation(presentation.id)
        }
    }

    private func noteRow(_ presentation: NoteRowPresentation) -> some View {
        NoteRow(
            presentation: presentation,
            selected: selectedNoteID == presentation.id,
            folders: folders,
            onNoteAction: actions.onNoteAction
        ) {
            actions.onSelectNote(presentation.id)
        }
    }
}

struct RightRailContentTaskID: Equatable {
    let conversations: [WorkspaceConversationRecord]
    let notes: [WorkspaceNoteRecord]
    let scopeID: String?
    let agents: [WorkspaceAgent]
    let machines: [Machine]
    let folderRevisions: String
    let timeContext: String
    let query: String
    let readFilter: ReadFilter?
}

enum ReadFilter: String, Hashable, Sendable {
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
struct ConversationListMeta: Equatable, Sendable {
    let agentLabel: String
    let folderLabel: String
    /// The name of the machine that owns the chat.
    let locationLabel: String
    let locationKind: ConversationLocationKind
    /// Runtime product name when known, e.g. "Codex", "Claude Code".
    let runtimeLabel: String?
    let runtimeKind: AgentRuntimeKind?

    static func resolve(
        conversation: WorkspaceConversationRecord,
        agent: WorkspaceAgent?,
        machine: Machine?,
        foldersByID: [String: WorkspaceFolderRecord]
    ) -> ConversationListMeta {
        let runtime = agent?.runtimeKind ?? conversation.runtimeKind
        let agentLabel = agent.map(agentDisplayName) ?? conversation.runtimeName

        let folderLabel: String
        if let folderID = conversation.folderID,
           let folder = foldersByID[folderID] {
            let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            folderLabel = name.isEmpty ? "Untitled folder" : name
        } else {
            folderLabel = "All Workspaces"
        }

        return ConversationListMeta(
            agentLabel: agentLabel,
            folderLabel: folderLabel,
            locationLabel: machine?.name ?? "Unknown",
            locationKind: machine?.isThisMachine == false ? .remoteWorkspace : .workspaceAgent,
            runtimeLabel: runtime?.displayName ?? conversation.runtimeName,
            runtimeKind: runtime
        )
    }
}

enum ConversationLocationKind: Equatable, Sendable {
    /// This machine.
    case workspaceAgent
    /// Another machine.
    case remoteWorkspace

    var glyph: LucideGlyph {
        switch self {
        case .workspaceAgent:
            .panelsTopLeft
        case .remoteWorkspace:
            .container
        }
    }
}

struct ConversationRowAccessibility: Equatable, Sendable {
    let label: String
    let value: String
    let hint: String

    static func resolve(
        conversation: WorkspaceConversationRecord,
        title: String,
        meta: ConversationListMeta,
        preview: String,
        time: String
    ) -> ConversationRowAccessibility {
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
        return ConversationRowAccessibility(
            label: title,
            value: details.joined(separator: ". "),
            hint: "Press to open the chat."
        )
    }
}

struct ConversationRowPresentation: Equatable, Identifiable, Sendable {
    let conversation: WorkspaceConversationRecord
    let agent: WorkspaceAgent?
    let title: String
    let meta: ConversationListMeta
    let preview: String
    let time: String
    let timeContext: String

    var id: String { conversation.id }
}

struct NoteRowPresentation: Equatable, Identifiable, Sendable {
    let note: WorkspaceNoteRecord
    let kind: NoteArtifactKind
    let title: String
    let preview: String

    var id: String { note.id }
}

final class ConversationRowPresentationBox: NSObject {
    let value: ConversationRowPresentation

    init(_ value: ConversationRowPresentation) {
        self.value = value
    }
}

final class NoteRowPresentationBox: NSObject {
    let value: NoteRowPresentation

    init(_ value: NoteRowPresentation) {
        self.value = value
    }
}

final class ListPresentationCache: @unchecked Sendable {
    static let shared = ListPresentationCache()

    private let conversations = NSCache<NSString, ConversationRowPresentationBox>()
    private let notes = NSCache<NSString, NoteRowPresentationBox>()

    private init() {
        conversations.countLimit = 4_096
        notes.countLimit = 4_096
    }

    func presentation(
        for conversation: WorkspaceConversationRecord,
        agent: WorkspaceAgent?,
        machine: Machine?,
        foldersByID: [String: WorkspaceFolderRecord],
        timeContext: String
    ) -> ConversationRowPresentation {
        let key = conversation.id as NSString
        let meta = ConversationListMeta.resolve(
            conversation: conversation,
            agent: agent,
            machine: machine,
            foldersByID: foldersByID
        )
        if let cached = conversations.object(forKey: key)?.value,
           cached.conversation == conversation,
           cached.agent == agent,
           cached.meta == meta,
           cached.timeContext == timeContext {
            return cached
        }

        let fallbackPreview = agent.map(agentDisplayName) ?? conversation.runtimeName
        let presentation = ConversationRowPresentation(
            conversation: conversation,
            agent: agent,
            title: listPreview(conversation.title, limit: 160),
            meta: meta,
            preview: ConversationMarkdownDocument.preview(
                conversation.lastMessagePreview?.isEmpty == false
                    ? conversation.lastMessagePreview!
                    : fallbackPreview,
                limit: 160
            ),
            time: shortTime(conversation.lastMessageAt),
            timeContext: timeContext
        )
        conversations.setObject(ConversationRowPresentationBox(presentation), forKey: key)
        return presentation
    }

    func presentation(for note: WorkspaceNoteRecord) -> NoteRowPresentation {
        let key = note.id as NSString
        if let cached = notes.object(forKey: key)?.value, cached.note == note {
            return cached
        }

        let presentation = NoteRowPresentation(
            note: note,
            kind: note.kind,
            title: listPreview(note.title.isEmpty ? "Untitled note" : note.title, limit: 160),
            preview: listPreview(note.preview, limit: 180)
        )
        notes.setObject(NoteRowPresentationBox(presentation), forKey: key)
        return presentation
    }
}

struct RightRailContent: Equatable, Sendable {
    static let empty = RightRailContent(
        pinnedChats: [],
        recentChats: [],
        pinnedNotes: [],
        notes: []
    )

    let pinnedChats: [ConversationRowPresentation]
    let recentChats: [ConversationRowPresentation]
    let pinnedNotes: [NoteRowPresentation]
    let notes: [NoteRowPresentation]

    private init(
        pinnedChats: [ConversationRowPresentation],
        recentChats: [ConversationRowPresentation],
        pinnedNotes: [NoteRowPresentation],
        notes: [NoteRowPresentation]
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
        machines: [Machine] = [],
        folders: [WorkspaceFolderRecord] = [],
        query: String,
        readFilter: ReadFilter?
    ) {
        let presentationCache = ListPresentationCache.shared
        let timeContext = ListTimeContext.current
        let agentsByID = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let machinesByID = Dictionary(machines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let foldersByID = Dictionary(
            uniqueKeysWithValues: folders.map { ($0.id, $0) }
        )

        var pinnedChats: [ConversationRowPresentation] = []
        var recentChats: [ConversationRowPresentation] = []

        for conversation in conversations {
            if Task.isCancelled { break }
            guard readFilter?.includes(unread: conversation.unread) != false else { continue }

            let agent = conversation.agentID.flatMap { agentsByID[$0] }
            let machine = machinesByID[conversation.machineID]
            let meta = ConversationListMeta.resolve(
                conversation: conversation,
                agent: agent,
                machine: machine,
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
                machine: machine,
                foldersByID: foldersByID,
                timeContext: timeContext
            )
            if conversation.isPinned {
                pinnedChats.append(presentation)
            } else {
                recentChats.append(presentation)
            }
        }

        var pinnedNotes: [NoteRowPresentation] = []
        var unpinnedNotes: [NoteRowPresentation] = []
        for note in notes {
            if Task.isCancelled { break }
            guard query.isEmpty
                    || note.title.localizedCaseInsensitiveContains(query)
                    || note.preview.localizedCaseInsensitiveContains(query)
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

enum ListTimeContext {
    static var current: String {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date()).timeIntervalSinceReferenceDate
        return "\(day):\(calendar.timeZone.identifier):\(Locale.current.identifier)"
    }
}
