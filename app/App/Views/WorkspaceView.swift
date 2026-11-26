import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WovenProtocol

final class ScrollHoverCoordinator: @unchecked Sendable {
    var isScrolling = false
    var hoveredToken: String?
    private var hoveredUpdate: ((Bool) -> Void)?

    func setScrolling(_ scrolling: Bool) {
        guard isScrolling != scrolling else { return }
        isScrolling = scrolling
        hoveredUpdate?(scrolling ? false : true)
    }

    func recordHover(_ hovering: Bool, token: String, update: @escaping (Bool) -> Void) {
        if hovering {
            // Entry can arrive before the previous row's exit. Clear it before
            // transferring ownership so its preview and pending delay end now.
            if hoveredToken != token {
                hoveredUpdate?(false)
            }
            hoveredToken = token
            hoveredUpdate = update
            if !isScrolling { update(true) }
        } else if hoveredToken == token {
            if !isScrolling { update(false) }
            hoveredToken = nil
            hoveredUpdate = nil
        }
    }

    func unregister(token: String) {
        guard hoveredToken == token else { return }
        hoveredToken = nil
        hoveredUpdate = nil
    }
}

struct ScrollHoverCoordinatorEnvironmentKey: EnvironmentKey {
    static let defaultValue = ScrollHoverCoordinator()
}

extension EnvironmentValues {
    var scrollHoverCoordinator: ScrollHoverCoordinator {
        get { self[ScrollHoverCoordinatorEnvironmentKey.self] }
        set { self[ScrollHoverCoordinatorEnvironmentKey.self] = newValue }
    }
}

struct WorkspaceView: View {
    @Bindable var model: ApplicationModel
    @State private var conversationToRename: WorkspaceConversationRecord?
    @State private var noteToRename: WorkspaceNoteRecord?
    @State private var showsWorkspaceTrash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(WovenTheme.storageKey) private var themeRawValue = WovenTheme.green.rawValue
    @AppStorage(SidebarStyle.storageKey) private var sidebarStyleRawValue = SidebarStyle.defaultStyle.rawValue
    @AppStorage(SidebarSide.storageKey) private var singleSidebarSideRawValue = SidebarSide.defaultSide.rawValue
    @AppStorage("wovenmatter.layout.left-rail") private var leftRailRequested = true
    @AppStorage("wovenmatter.layout.right-rail") private var rightRailRequested = true
    @AppStorage("wovenmatter.layout.single-rail") private var singleRailRequested = true
    @AppStorage("wovenmatter.layout.chat-width-percent") private var chatWidthPercent = 58.0
    @AppStorage("wovenmatter.layout.note-on-left") private var noteOnLeft = false
    @AppStorage(AgentDisclosureStore.storageKey) private var agentDisclosureRaw = "[]"
    @State private var selectedAgentID: String?
    /// Chats being started, by the id their panel holds, with the agent each
    /// is started with, so a new chat shows at once instead of after its start.
    @State private var startingChats: [String: WorkspaceAgent] = [:]
    @State private var chatPanels = ChatPanelState()
    private var assets: WorkspaceAssetSession { model.workspaceAssets }
    private var selectedNoteID: String? { assets.tabs.selectedNoteID }
    @State private var selectedFolderID: String?
    @State private var sidebarNavigation = SidebarNavigationState()
    @State private var destination = WindowDestination.workspace
    /// The one rail revealed while the window is too narrow for the requested rails.
    @State private var compactRail: SidebarSide?
    @State private var compactWorkspacePane = CompactWorkspacePane.chat
    @State private var noteFocusMode = false
    @State private var draftsByConversationID: [String: String] = [:]
    @State private var attachmentDraftsByConversation: [String: [AgentMessageAttachmentDraft]] = [:]
    @State private var submittingConversationIDs: Set<String> = []
    @State private var showsAttachmentImporter = false
    @State private var archivedLibrarySource: WorkspaceLibraryItem?
    @State private var attachmentPicker: AttachmentPickerKind?
    @State private var attachmentTargetConversationID: String?
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var showsNewChatChooser = false
    @State private var showsNewNoteChooser = false
    @State private var newlyCreatedNoteID: String?

    private var theme: WovenTheme {
        WovenTheme(rawValue: themeRawValue) ?? .green
    }

    private var allAgents: [WorkspaceAgent] {
        model.workspace.agents
    }

    private var overview: WorkspaceOverview? {
        model.workspace.workspaceOverview
    }

    private var selectedConversationID: String? {
        chatPanels.activeConversationID
    }

    private var surfacePreferenceSignature: String {
        [
            themeRawValue,
            sidebarStyleRawValue,
            singleSidebarSideRawValue,
            String(leftRailRequested),
            String(rightRailRequested),
            String(singleRailRequested),
            String(chatWidthPercent),
            String(noteOnLeft),
        ].joined(separator: "|")
    }

    private var sidebarStyle: SidebarStyle {
        SidebarStyle(rawValue: sidebarStyleRawValue) ?? .defaultStyle
    }

    private var singleSidebarSide: SidebarSide {
        get { SidebarSide(rawValue: singleSidebarSideRawValue) ?? .defaultSide }
        nonmutating set { singleSidebarSideRawValue = newValue.rawValue }
    }

    var body: some View {
        workspaceWithAttachments
        .focusedSceneValue(\.workspaceMenuActions, WorkspaceMenuActions(
            newChat: createConversation,
            newNote: openNewNoteChooser,
            newBrowserTab: openNewBrowserTab,
            refresh: { Task { await model.workspace.refresh() } }
        ))
        .environment(\.openDocumentPreview) { url, identity in
            do {
                try assets.openDocument(url, identity: identity)
                destination = .workspace
                compactWorkspacePane = .note
                chatPanels.presentAsset()
            } catch { showNotice(error.localizedDescription) }
        }
        .onChange(of: assets.notice) { _, message in
            if let message { showNotice(message); assets.notice = nil }
        }
        .onChange(of: model.bots.notice) { _, message in
            if let message { showNotice(message); model.bots.notice = nil }
        }
        .onChange(of: model.navigation.pendingDefaultAgentSettingsScope) { _, scope in
            if scope != nil { openUtility(.settings) }
        }
        .debugNavigation(openNote: selectNote, show: { destination = $0 })
        .debugRequest("trash") { showsWorkspaceTrash = true }
        // `chat:ID` opens a chat; `new:RUNTIME` starts one with this Mac's agent, `new:RUNTIME@MACHINE` there.
        .debugCommand("chat:") { selectConversation($0) }
        .debugCommand("new:", startDebugChat)
        // `bot:ID` opens a bot's chat (`bot:forum` the Forum); `bots-settings` Settings > Bots.
        .debugCommand("bot:") { selectBot(BotTarget(machineID: model.bots.hostMachineID ?? "", botID: $0)) }
        .debugRequest("bots-settings") { openBotSettings() }
        // `settings-page:NAME` opens a Settings page, as `--settings-page` does at launch.
        .debugCommand("settings-page:") { model.navigation.pendingConnectionsScope = $0 }
        .onChange(of: model.navigation.pendingConnectionsScope) { _, scope in
            if scope != nil { openUtility(.settings) }
        }
        .onReceive(NotificationCenter.default.publisher(for: MacAccessSetupModel.openSettingsNotification)) { _ in
            model.navigation.pendingConnectionsScope = "permissions"
            openUtility(.settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("wovenmatter.open-connections"))) { event in
            model.navigation.pendingConnectionsScope = event.object as? String ?? model.machines.thisMachine?.id
            openUtility(.settings)
        }
    }

    // Keep presentation and routing as separate opaque expressions so the
    // supported Xcode toolchains do not solve one enormous modifier chain.
    private var workspaceLayout: some View {
        GeometryReader { geometry in
            let layout = WorkspaceLayoutState.resolve(
                width: geometry.size.width,
                leftRailRequested: leftRailRequested,
                rightRailRequested: rightRailRequested,
                sidebarStyle: sidebarStyle,
                singleSidebarSide: singleSidebarSide,
                singleRailRequested: singleRailRequested,
                compactRail: compactRail
            )

            ZStack(alignment: .trailing) {
                desktopShell(layout: layout)
                .background(theme.palette.workspace)
                // Narrowing the window hides the rails again; widening restores
                // the rails the person requested.
                .onChange(of: layout.compact) { _, _ in compactRail = nil }
                .alert("Pi Durable switched models", isPresented: Binding(get: { model.sessions.defaultAgentFallbackNotice != nil }, set: { if !$0 { model.sessions.defaultAgentFallbackNotice = nil } })) {
                    Button("OK") { model.sessions.defaultAgentFallbackNotice = nil }
                } message: { Text(model.sessions.defaultAgentFallbackNotice ?? "") }

                if showsNewChatChooser || showsNewNoteChooser {
                    Color.black.opacity(0.20)
                        .ignoresSafeArea()
                        .onTapGesture {
                            closeNewChatChooser()
                            closeNewNoteChooser()
                        }
                        .transition(.opacity)
                }
                if showsNewChatChooser {
                    NewChatDrawer(
                        model: model,
                        folderMachineID: model.workspace.folder(id: selectedFolderID)?.machineID,
                        onClose: closeNewChatChooser,
                        onSelect: { startChat(with: $0) }
                    )
                    .frame(width: min(440, max(360, geometry.size.width - 32)))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if showsNewNoteChooser {
                    NewNoteDrawer(
                        onClose: closeNewNoteChooser,
                        onSelect: createNote
                    )
                    .frame(width: min(440, max(360, geometry.size.width - 32)))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(
                reduceMotion ? nil : .snappy(duration: 0.3),
                value: showsNewChatChooser
            )
            .animation(
                reduceMotion ? nil : .snappy(duration: 0.3),
                value: showsNewNoteChooser
            )
        }
        .environment(\.wovenTheme, theme)
        .environment(\.workspaceApplicationModel, model)
        .environment(\.openWorkspaceConversation, { id in
            destination = .workspace
            selectConversation(id)
        })
        .preferredColorScheme(theme.colorScheme)
        .tint(WovenPalette.primary)
        .foregroundStyle(WovenPalette.foreground)
    }

    private var workspaceConversationIDs: [String] {
        overview?.conversations.map(\.id) ?? []
    }

    private var workspaceNoteIDs: [String] {
        overview?.notes.map(\.id) ?? []
    }

    private func reconcileConversations(oldIDs: [String], ids: [String]) {
        let removed: Set<String> = Set(oldIDs).subtracting(ids)
        for panel in chatPanels.panels where panel.conversationID.map(removed.contains) == true {
            _ = chatPanels.setConversation(nil, in: panel.id)
        }
        selectDefaults()
    }

    private func reconcileNotes(oldIDs: [String], ids: [String]) {
        let removed: Set<String> = Set(oldIDs).subtracting(ids)
        for id in removed { assets.close(.note(id)) }
    }

    private var workspaceNavigation: some View {
        workspaceLayout
        .onAppear {
            selectDefaults()
        }
        .overlay(alignment: .top) { DictationFeedback().padding(.top, 12) }
        .onChange(of: destination) { _, value in
            if value != .workspace { DictationModel.shared.leaveWorkspace() }
        }
        .onChange(of: allAgents.map(\.id)) { _, _ in selectDefaults() }
        .onChange(of: workspaceConversationIDs) { oldIDs, ids in
            reconcileConversations(oldIDs: oldIDs, ids: ids)
        }
        .onChange(of: workspaceNoteIDs) { oldIDs, ids in
            reconcileNotes(oldIDs: oldIDs, ids: ids)
        }
        .onChange(of: selectedConversationID) { _, conversationID in
            if let conversationID {
                model.workspace.markConversationRead(id: conversationID)
            }
        }
        // A reply that arrives in the open chat is seen as it arrives.
        .onChange(of: selectedConversation?.unread) { _, unread in
            if unread == true, let conversationID = selectedConversationID {
                model.workspace.markConversationRead(id: conversationID)
            }
        }
    }

    private var workspaceSurface: some View {
        workspaceNavigation
        .onChange(of: assets.tabs.isPresented) { _, presented in
            if !presented {
                compactWorkspacePane = .chat
                noteFocusMode = false
                chatPanels.dismissAsset()
            } else {
                chatPanels.presentAsset()
                synchronizeSelectionToActivePanel()
            }
        }
        .onChange(of: sidebarStyleRawValue) { _, _ in
            compactRail = nil
        }
        .onChange(of: singleSidebarSideRawValue) { oldValue, newValue in
            guard sidebarStyle != .split,
                  let oldSide = SidebarSide(rawValue: oldValue),
                  let newSide = SidebarSide(rawValue: newValue),
                  compactRail == oldSide else { return }
            compactRail = newSide
        }
        .onChange(of: surfacePreferenceSignature) { _, _ in
            model.settings.persistMacSurfaceProfileFromUserDefaults()
        }
        .onDisappear { noticeTask?.cancel() }
        .sheet(item: $conversationToRename) { conversation in
            RenameSheet(heading: "Rename chat", placeholder: "Chat name", initialTitle: conversation.title) { title in
                try await model.workspace.mutateConversation(id: conversation.id, mutation: .rename(title))
            }
        }
        .sheet(item: $noteToRename) { note in
            RenameSheet(heading: "Rename artifact", placeholder: "Artifact name", initialTitle: note.title) { title in
                try await model.workspace.mutateNote(id: note.id, mutation: .rename(title))
            }
        }
        .sheet(isPresented: $showsWorkspaceTrash) {
            WorkspaceTrashSheet(model: model)
        }
        .sheet(item: $archivedLibrarySource) { item in
            LibrarySourceSheet(item: item, model: model)
        }
    }

    private var workspaceWithAttachments: some View {
        workspaceSurface
        .fileImporter(
            isPresented: $showsAttachmentImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                if let conversationID = attachmentTargetConversationID {
                    _ = attachFiles(urls, conversationID: conversationID)
                }
                attachmentTargetConversationID = nil
            case .failure(let error):
                attachmentTargetConversationID = nil
                showNotice(error.localizedDescription)
            }
        }
        .sheet(item: $attachmentPicker) { kind in
            AttachmentPicker(
                kind: kind,
                notes: overview?.notes ?? [],
                conversations: (overview?.conversations ?? []).filter {
                    $0.id != attachmentTargetConversationID
                },
                onSelectNote: { note in
                    if let conversationID = attachmentTargetConversationID {
                        appendAttachment(.reference(AgentMessageReferenceDraft(
                            kind: .note, resourceID: note.id, titleSnapshot: note.title)), conversationID: conversationID)
                    }
                    attachmentPicker = nil
                    attachmentTargetConversationID = nil
                },
                onSelectConversation: { conversation in
                    let targetConversationID = attachmentTargetConversationID
                    attachmentTargetConversationID = nil
                    attachmentPicker = nil
                    Task { @MainActor in
                        if let conversationID = targetConversationID {
                            appendAttachment(.reference(AgentMessageReferenceDraft(
                                kind: .conversation, resourceID: conversation.id, titleSnapshot: conversation.title)), conversationID: conversationID)
                        }
                    }
                }
            )
        }
    }

    private func desktopShell(layout: WorkspaceLayoutState) -> some View {
        let showLeftRailButton = sidebarStyle != .split
            ? !layout.showsLeftRail && singleSidebarSide == .left
            : !layout.showsLeftRail
        let showRightRailButton = sidebarStyle != .split
            ? !layout.showsRightRail && singleSidebarSide == .right
            : !layout.showsRightRail

        return HStack(spacing: WovenMetrics.shellGap) {
            if layout.showsLeftRail {
                railGroup(side: .left, collapsesAdaptivePages: layout.compact)
            }

            centerSurface(
                showLeftRailButton: showLeftRailButton,
                showRightRailButton: showRightRailButton,
                onLeftRail: { revealRail(side: .left, compact: layout.compact) },
                onRightRail: { revealRail(side: .right, compact: layout.compact) }
            )
            .frame(minWidth: WovenMetrics.workspaceMinimumWidth)

            if layout.showsRightRail {
                railGroup(side: .right, collapsesAdaptivePages: layout.compact)
            }
        }
        // A Page is a document like any other artifact, inside the same shell.
        .padding(.horizontal, WovenMetrics.shellInset)
        .padding(.bottom, WovenMetrics.shellInset)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: layout)
    }

    @ViewBuilder
    private func railGroup(
        side: SidebarSide,
        collapsesAdaptivePages: Bool
    ) -> some View {
        let pages = sidebarNavigation.pages(
            for: side,
            style: sidebarStyle,
            collapsesAdaptivePages: collapsesAdaptivePages
        )
        let usesUnifiedSurface = sidebarStyle == .adaptive && pages.count == 2

        let content = HStack(spacing: usesUnifiedSurface ? 0 : WovenMetrics.shellGap) {
            ForEach(pages, id: \.self) { page in
                rail(side: side, page: page, adaptiveExpanded: usesUnifiedSurface)
                    .frame(width: WovenMetrics.railWidth)
                    .background {
                        if !usesUnifiedSurface {
                            RailBackground()
                        }
                }
            }
        }

        if usesUnifiedSurface {
            content
                .background {
                    RailBackground()
                }
                .overlay {
                    Rectangle()
                        .fill(theme.palette.border)
                        .frame(width: 0.5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .clipShape(DesktopShapes.windowAlignedSurface)
        } else {
            content
        }
    }

    private func rail(
        side: SidebarSide,
        page: SidebarPage,
        adaptiveExpanded: Bool
    ) -> some View {
        SidebarRail(
            model: model,
            side: side,
            page: page,
            style: sidebarStyle,
            adaptiveExpanded: adaptiveExpanded,
            agents: allAgents,
            machines: model.machines.machines,
            folders: overview?.folders ?? [],
            conversations: overview?.conversations ?? [],
            notes: overview?.notes ?? [],
            runningConversationIDs: model.workspace.runningConversationIDs,
            selectedFolderID: selectedFolderID,
            selectedConversationID: selectedConversationID,
            selectedNoteID: selectedNoteID,
            bots: model.bots,
            selectedBotTarget: chatPanels.activeBotTarget,
            destination: destination,
            agentDisclosureRaw: $agentDisclosureRaw,
            actions: SidebarActions(
                onCollapse: collapseRail,
                onMoveSingleRail: moveSingleSidebar,
                onShowNavigation: showSidebarNavigation,
                onUtility: openUtility,
                onSelectFolder: selectFolder,
                onSelectConversation: selectConversation,
                onSelectNote: selectNote,
                onCreateAgent: {
                    openUtility(.settings)
                },
                onCreateConversation: createConversation,
                onCreateNote: openNewNoteChooser,
                onCreateFolder: createFolder,
                onRenameFolder: renameFolder,
                onSetFolderPinned: setFolderPinned,
                onMoveFolder: moveFolder,
                onDeleteFolder: deleteFolder,
                onSetFolderReferencePaths: setFolderReferencePaths,
                onCreateChatInFolder: createChatInFolder,
                onShowTrash: { showsWorkspaceTrash = true },
                onConversationAction: handleConversationAction,
                onNoteAction: handleNoteAction,
                onUnavailableMutation: showUnavailableMutation,
                onSelectBot: selectBot,
                onOpenBotSettings: openBotSettings
            ),
            onSurfaceProfileChange: {
                model.settings.persistMacSurfaceProfileFromUserDefaults()
            }
        )
    }

    private func collapseRail(side: SidebarSide) {
        if compactRail == side {
            compactRail = nil
        } else if sidebarStyle != .split {
            singleRailRequested = false
        } else if side == .left {
            leftRailRequested = false
        } else {
            rightRailRequested = false
        }
    }

    private func revealRail(side: SidebarSide, compact: Bool) {
        if compact {
            // A compact window has room for one rail beside the conversation.
            singleRailRequested = true
            compactRail = side
        } else if sidebarStyle != .split {
            singleRailRequested = true
        } else if side == .left {
            leftRailRequested = true
        } else {
            rightRailRequested = true
        }
    }

    private func moveSingleSidebar() {
        singleRailRequested = true
        singleSidebarSide = singleSidebarSide.opposite
    }

    private func showSidebarNavigation() {
        sidebarNavigation.showNavigation()
        destination = .workspace
    }

    private func centerSurface(
        showLeftRailButton: Bool,
        showRightRailButton: Bool,
        onLeftRail: @escaping () -> Void,
        onRightRail: @escaping () -> Void
    ) -> some View {
        let presentsAssets = destination == .workspace && assets.tabs.isPresented
        return ZStack(alignment: .top) {
            Group {
                switch destination {
                case .workspace:
                    WorkspaceSurface(
                        model: model,
                        agents: allAgents,
                        conversations: overview?.conversations ?? [],
                        chatPanels: chatPanels,
                        assets: assets,
                        draftsByConversationID: $draftsByConversationID,
                        attachmentDraftsByConversation: attachmentDraftsByConversation,
                        submittingConversationIDs: submittingConversationIDs,
                        compactPane: $compactWorkspacePane,
                        noteFocusMode: $noteFocusMode,
                        chatWidthPercent: $chatWidthPercent,
                        noteOnLeft: $noteOnLeft,
                        reservesLeadingRailControlSpace: showLeftRailButton,
                        reservesTrailingRailControlSpace: showRightRailButton,
                        newlyCreatedNoteID: newlyCreatedNoteID,
                        onNewNoteFocusHandled: { noteID in
                            if newlyCreatedNoteID == noteID {
                                newlyCreatedNoteID = nil
                            }
                        },
                        onActivatePanel: activatePanel,
                        onAddPanel: addPanel,
                        onClosePanel: closePanel,
                        onNavigatePanel: navigatePanel,
                        onOpenBoardSession: { id in
                            // A Page task's bot thread opens beside the chats.
                            if let bot = BotTarget(pageTaskLink: id) { selectBot(bot) } else { selectConversation(id) }
                        },
                        onSend: send,
                        onAttachmentAction: handleAttachmentAction,
                        onRemoveAttachment: removeAttachment,
                        onDropFiles: attachFiles,
                        onReplaceSession: startChat(replacing:),
                        startingChats: $startingChats,
                        onBotRoute: { target, panelID in
                            _ = chatPanels.setBot(target, in: panelID)
                        },
                        onOpenBotLink: { url, panelID in openBotLink(url, from: panelID) },
                        onOpenBotSettings: openBotSettings
                    )
                case .calendar:
                    CalendarSurface(model: model, onOpenSession: { id in
                        destination = .workspace
                        selectConversation(id)
                    })
                case .cronJobs:
                    CronSurface(
                        model: model,
                        onOpenConversation: { conversationID in
                            destination = .workspace
                            selectConversation(conversationID)
                        }
                    )
                case .library:
                    LibrarySurface(library: model.library, machines: model.machines.machines) { item in
                        if overview?.conversations.contains(where: { $0.id == item.conversationID }) == true {
                            model.navigation.libraryMessageTarget = item
                            destination = .workspace
                            selectConversation(item.conversationID)
                        } else {
                            archivedLibrarySource = item
                        }
                    }
                case .databases:
                    DatabasesView(model: model)
                case .usage:
                    UsageView(
                        model: model,
                        reservesRailControlSpace: showLeftRailButton || showRightRailButton
                    )
                case .settings:
                    SettingsView(
                        model: model,
                        reservesRailControlSpace: showLeftRailButton || showRightRailButton
                    )
                }
            }

            HStack {
                if showLeftRailButton {
                    RevealRailButton(side: .left,
                        width: presentsAssets ? WovenMetrics.assetToolbarControlWidth : 36,
                        height: presentsAssets ? WovenMetrics.assetToolbarControlHeight : 36,
                        action: onLeftRail)
                }
                Spacer()
                if destination == .workspace && !assets.tabs.isPresented {
                    Button {
                        let opened: Bool
                        if let existing = assets.tabs.selected {
                            assets.tabs.select(existing)
                            opened = true
                        } else {
                            opened = assets.openBrowser() != nil
                        }
                        if opened {
                            compactWorkspacePane = .note
                        }
                    } label: {
                        Image(systemName: "rectangle.on.rectangle").font(.system(size: 16)).frame(width: 32, height: 32)
                    }
                    .buttonStyle(WovenIconButtonStyle())
                    .help(assets.tabs.selected == nil ? "Open browser" : "Show artifacts")
                    .accessibilityLabel(assets.tabs.selected == nil ? "Open browser" : "Show artifacts")
                }
                if showRightRailButton {
                    RevealRailButton(side: .right,
                        width: presentsAssets ? WovenMetrics.assetToolbarControlWidth : 36,
                        height: presentsAssets ? WovenMetrics.assetToolbarControlHeight : 36,
                        action: onRightRail)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, presentsAssets ? WovenMetrics.assetToolbarVerticalPadding : 12)

            if let notice {
                Text(notice)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(WovenPalette.foreground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(WovenPalette.background.opacity(0.94))
                    .clipShape(Capsule())
                    .overlay { Capsule().stroke(theme.palette.border, lineWidth: 1) }
                    .shadow(color: WovenPalette.foreground.opacity(0.08), radius: 16, y: 8)
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(theme.palette.workspace)
        .clipped()
    }

    private var selectedAgent: WorkspaceAgent? {
        allAgents.first { $0.id == selectedAgentID }
    }

    private var selectedConversation: WorkspaceConversationRecord? {
        overview?.conversations.first { $0.id == selectedConversationID }
    }

    private var conversationsForSelectedAgent: [WorkspaceConversationRecord] {
        guard let agent = selectedAgent else { return [] }
        return (overview?.conversations ?? []).filter { conversation in
            return conversation.agentID == agent.id
        }
    }

    private func selectDefaults() {
        // A bot channel is a complete selection; there is no chat to restore.
        if chatPanels.activeBotTarget != nil { return }
        // A successful creation may arrive before the read projection. Keep its
        // selected ID until the next snapshot instead of restoring an older chat.
        if selectedConversationID != nil && selectedConversation == nil { return }
        if let selectedConversation {
            selectedAgentID = model.workspace.agent(id: selectedConversation.agentID)?.id
            return
        }
        if selectedConversation == nil,
           chatPanels.activePanelID != .primary || chatPanels.hasAuxiliaryPanels {
            return
        }
        if selectedAgent == nil {
            selectedAgentID = allAgents.first?.id
        }
        if selectedConversation == nil { selectConversationForCurrentAgent() }
    }

    private func selectConversationForCurrentAgent() {
        if selectedAgent == nil, selectedConversation != nil {
            return
        }
        if let selectedConversation, conversationsForSelectedAgent.contains(where: { $0.id == selectedConversation.id }) {
            return
        }
        _ = chatPanels.replaceActiveConversation(
            with: conversationsForSelectedAgent.first?.id
        )
    }

    private func selectBot(_ target: BotTarget) {
        _ = chatPanels.replaceActiveBot(with: target)
        selectedAgentID = nil
        destination = .workspace
        compactWorkspacePane = .chat
    }

    private func openBotSettings() {
        model.navigation.pendingBotsSettings = true
        openUtility(.settings)
    }

    /// Links from a bot open beside it, the same way a chat's browser tabs do.
    private func openBotLink(_ url: URL, from panelID: ChatPanelID) {
        if let page = WovenAppLink(url) {
            switch page {
            case .accounts:
                // Subscriptions & API Keys of the machine a bot runs on: its bots use that machine's sign-ins.
                model.navigation.pendingConnectionsScope = chatPanels.panel(id: panelID)?.botTarget?.machineID ?? model.machines.thisMachine?.id
            case .botProfiles:
                model.navigation.pendingBotProfilesMachine = chatPanels.panel(id: panelID)?.botTarget?.machineID
                openBotSettings()
            }
            return
        }
        guard assets.openBrowser(url: url.absoluteString) != nil else {
            NSWorkspace.shared.open(url)
            return
        }
        // The side area sits beside the primary panel, so the bot that was reading moves there.
        if panelID != .primary, let target = chatPanels.panel(id: panelID)?.botTarget {
            _ = chatPanels.setBot(target, in: .primary)
        }
        chatPanels.presentAsset()
        destination = .workspace
        compactWorkspacePane = .note
    }

    private func selectFolder(_ id: String?) {
        selectedFolderID = id
        sidebarNavigation.selectFolder()
        destination = .workspace
        // Only one rail fits a compact window; show the folder's contents.
        if sidebarStyle == .split, compactRail == .left {
            compactRail = .right
        }
    }

    private func selectConversation(_ id: String) {
        guard let conversation = overview?.conversations.first(where: { $0.id == id }) else { return }
        _ = chatPanels.replaceActiveConversation(with: id)
        selectedAgentID = model.workspace.agent(id: conversation.agentID)?.id
        destination = .workspace
        compactWorkspacePane = .chat
    }

    private func selectNote(_ id: String) {
        assets.openNote(id)
        guard assets.tabs.selectedNoteID == id else { return }
        chatPanels.presentAsset()
        destination = .workspace
        compactWorkspacePane = .note
    }

    private func createNote(kind: NoteArtifactKind = .note) {
        guard assets.tabs.noteIDs.count < WorkspaceAssetTabs.maximumNotes else {
            showNotice(WorkspaceAssetTabs.Capacity.notes.localizedDescription)
            return
        }
        model.workspace.clearNoteMutationError()
        Task {
            guard let noteID = await model.workspace.createNote(
                folderID: selectedFolderID,
                kind: kind
            ) else {
                showNotice(model.workspace.noteMutationError ?? "The note could not be created.")
                return
            }
            newlyCreatedNoteID = noteID
            selectNote(noteID)
        }
    }

    private func createFolder(name: String, machineID: String, externalRoot: URL?) {
        model.workspace.clearFolderMutationError()
        Task {
            guard let folderID = await model.workspace.createFolder(name: name, machineID: machineID, externalRoot: externalRoot) else {
                showNotice(model.workspace.folderMutationError ?? "The folder could not be created.")
                return
            }
            selectFolder(folderID)
        }
    }

    private func renameFolder(id: String, name: String) {
        model.workspace.clearFolderMutationError()
        Task {
            guard await model.workspace.renameFolder(id: id, name: name) else {
                showNotice(model.workspace.folderMutationError ?? "The folder could not be renamed.")
                return
            }
        }
    }

    private func setFolderPinned(id: String, isPinned: Bool) {
        model.workspace.clearFolderMutationError()
        Task {
            guard await model.workspace.setFolderPinned(id: id, isPinned: isPinned) else {
                showNotice(model.workspace.folderMutationError ?? "The folder could not be updated.")
                return
            }
        }
    }

    private func moveFolder(id: String, direction: WorkspaceFolderMoveDirection) {
        model.workspace.clearFolderMutationError()
        Task {
            guard await model.workspace.moveFolder(id: id, direction: direction) else {
                showNotice(model.workspace.folderMutationError ?? "The folder could not be moved.")
                return
            }
        }
    }

    private func deleteFolder(id: String, deleteRoot: Bool) {
        model.workspace.clearFolderMutationError()
        Task {
            guard await model.workspace.deleteFolder(id: id, deleteRoot: deleteRoot) else {
                showNotice(model.workspace.folderMutationError ?? "The folder could not be removed.")
                return
            }
            if selectedFolderID == id {
                selectFolder(nil)
            }
        }
    }

    private func setFolderReferencePaths(id: String, paths: [String]) {
        model.workspace.clearFolderMutationError()
        Task {
            guard await model.workspace.setFolderReferencePaths(id: id, paths: paths) else {
                showNotice(model.workspace.folderMutationError ?? "The reference locations could not be updated.")
                return
            }
        }
    }

    private func createChatInFolder(_ id: String?) {
        selectFolder(id)
        showsNewNoteChooser = false
        showsNewChatChooser = true
    }

    private func handleConversationAction(_ conversation: WorkspaceConversationRecord, action: ConversationMenuAction) {
        if case .rename = action {
            conversationToRename = conversation
            return
        }
        Task {
            do {
                switch action {
                case .rename: break
                case .setPinned(let pinned):
                    try await model.workspace.mutateConversation(id: conversation.id, mutation: .setPinned(pinned))
                case .moveToTrash:
                    try await model.workspace.mutateConversation(id: conversation.id, mutation: .moveToTrash)
                    for panel in chatPanels.panels where panel.conversationID == conversation.id {
                        _ = chatPanels.setConversation(nil, in: panel.id)
                    }
                    selectDefaults()
                    showNotice("Chat moved to Trash.")
                case .export(let format):
                    let url = try await model.workspace.exportConversation(id: conversation.id, format: format)
                    if try await ConversationExport.save(url: url, title: conversation.title, format: format) {
                        showNotice("Chat exported.")
                    }
                }
            } catch {
                showNotice(error.localizedDescription)
            }
        }
    }

    private func handleNoteAction(_ note: WorkspaceNoteRecord, action: NoteMenuAction) {
        if case .rename = action {
            noteToRename = note
            return
        }
        Task {
            do {
                switch action {
                case .rename: break
                case .setPinned(let pinned):
                    try await model.workspace.mutateNote(id: note.id, mutation: .setPinned(pinned))
                case .moveToFolder(let folderID):
                    try await model.workspace.mutateNote(id: note.id, mutation: .moveToFolder(folderID))
                case .moveToTrash:
                    try await model.workspace.mutateNote(id: note.id, mutation: .moveToTrash)
                    assets.close(.note(note.id))
                    showNotice("Note moved to Trash.")
                case .export(let format):
                    let export = try await model.workspace.exportNote(id: note.id, format: format)
                    if try await NoteExport.save(export) {
                        showNotice("Note exported.")
                    }
                }
            } catch {
                showNotice(error.localizedDescription)
            }
        }
    }

    private func openNewBrowserTab() {
        guard assets.openBrowser() != nil else { return }
        closeNewChatChooser()
        closeNewNoteChooser()
        destination = .workspace
        compactWorkspacePane = .note
        chatPanels.presentAsset()
    }

    private func createConversation() {
        showsNewNoteChooser = false
        showsNewChatChooser = true
    }

    private func presentCreatedConversation(_ id: String) {
        // A successful command can precede the next read-projection snapshot.
        _ = chatPanels.replaceActiveConversation(with: id)
        selectDefaults()
        destination = .workspace
        compactWorkspacePane = .chat
    }

    private struct ChatCreationSelection {
        let id = UUID()
        let previousConversationID: String?
        let previousAgentID: String?
        var conversationID: String { id.uuidString.lowercased() }
    }

    private func beginChatCreation(agentID: String?) -> ChatCreationSelection {
        let selection = ChatCreationSelection(previousConversationID: selectedConversationID, previousAgentID: selectedAgentID)
        selectedAgentID = agentID
        startingChats[selection.conversationID] = agentID.flatMap { id in model.workspace.agents.first { $0.id == id } }
        closeNewChatChooser()
        presentCreatedConversation(selection.conversationID)
        return selection
    }

    private func finishChatCreation(_ selection: ChatCreationSelection, conversationID: String?) {
        let agent = startingChats.removeValue(forKey: selection.conversationID)
        // A late setup response must not take focus from a newer navigation action.
        guard selectedConversationID == selection.conversationID else { return }
        if let conversationID {
            startingChats[conversationID] = agent
            presentCreatedConversation(conversationID)
        }
        else {
            _ = chatPanels.replaceActiveConversation(with: selection.previousConversationID)
            selectedAgentID = selection.previousAgentID
        }
    }

    /// Starts a chat with `agent` on the machine that runs it, in the selected
    /// folder. The new chat is shown at once and replaced if the start fails.
    private func startChat(with agent: WorkspaceAgent) {
        let requestedFolderID = selectedFolderID
        let selection = beginChatCreation(agentID: agent.id)
        Task {
            do {
                let conversationID = try await model.workspace.startSession(agent: agent, folderID: requestedFolderID)
                finishChatCreation(selection, conversationID: conversationID)
            } catch {
                finishChatCreation(selection, conversationID: nil)
                showNotice(error.localizedDescription)
            }
        }
    }

    /// `RUNTIME@MACHINE` starts one with any runtime that machine's server
    /// offers (a dev instance's stand-in, say) through the usual start path.
    private func startDebugChat(_ runtime: String) {
        let parts = runtime.split(separator: "@", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            let selection = beginChatCreation(agentID: nil)
            Task {
                let id = try? await model.workspace.startSession(runtime: RuntimeKind(rawValue: parts[0]), on: parts[1], folderID: nil)
                finishChatCreation(selection, conversationID: id)
            }
            return
        }
        let here = model.machines.thisMachine?.id
        guard let agent = model.workspace.agents.first(where: { $0.runtimeKind.rawValue == runtime && $0.machineID == here }) else { return }
        startChat(with: agent)
    }

    /// Starts a chat with the same runtime, machine and folder as one whose
    /// native session is gone.
    private func startChat(replacing conversation: WorkspaceConversationRecord) {
        let selection = beginChatCreation(agentID: conversation.agentID)
        Task {
            do {
                let conversationID = try await model.workspace.startSession(
                    runtime: conversation.runtime, on: conversation.machineID, folderID: conversation.folderID)
                finishChatCreation(selection, conversationID: conversationID)
            } catch {
                finishChatCreation(selection, conversationID: nil)
                showNotice(error.localizedDescription)
            }
        }
    }

    private func closeNewChatChooser() {
        showsNewChatChooser = false
    }

    private func openNewNoteChooser() {
        showsNewChatChooser = false
        showsNewNoteChooser = true
    }

    private func closeNewNoteChooser() {
        showsNewNoteChooser = false
    }

    private func openUtility(_ next: WindowDestination) {
        destination = next
    }

    private func showUnavailableMutation(_ label: String) {
        showNotice("\(label) is not available yet.")
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { notice = nil }
        }
    }

    private func activatePanel(_ panelID: ChatPanelID) {
        guard chatPanels.activePanelID != panelID else { return }
        guard chatPanels.activatePanel(panelID) else { return }
        synchronizeSelectionToActivePanel()
    }

    private func addPanel(from panelID: ChatPanelID) {
        let newPanelID = ChatPanelID(rawValue: UUID().uuidString.lowercased())
        let openConversationIDs = Set(chatPanels.panels.compactMap(\.conversationID))
        let conversationID = ConversationSelection
            .mostRecentAvailableConversationID(
                in: overview?.conversations ?? [],
                excluding: openConversationIDs
            )
        guard chatPanels.addPanel(
            from: panelID,
            newPanelID: newPanelID,
            conversationID: conversationID
        ) else { return }
        if assets.tabs.isPresented {
            assets.tabs.hide()
            compactWorkspacePane = .chat
            noteFocusMode = false
        }
        synchronizeSelectionToActivePanel()
    }

    private func closePanel(_ panelID: ChatPanelID) {
        guard chatPanels.closePanel(panelID) else { return }
        synchronizeSelectionToActivePanel()
    }

    private func navigatePanel(_ direction: ChatPanelDirection) -> Bool {
        guard chatPanels.navigate(direction) != nil else { return false }
        synchronizeSelectionToActivePanel()
        return true
    }

    private func synchronizeSelectionToActivePanel() {
        guard let conversation = selectedConversation else { return }
        selectedAgentID = model.workspace.agent(id: conversation.agentID)?.id
        model.workspace.markConversationRead(id: conversation.id)
    }

    /// Sends the draft of the chat a panel shows, to that chat. While a
    /// chosen chat loads, the one still on screen is the one its composer shows.
    private func send(from panelID: ChatPanelID, shownConversationID: String?) {
        if let selectedConversation = overview?.conversations.first(where: { $0.id == shownConversationID }) {
            let conversationID = selectedConversation.id
            guard submittingConversationIDs.insert(conversationID).inserted else {
                return
            }
            let content = draftsByConversationID[conversationID, default: ""]
            let submittedAttachments = attachmentDraftsByConversation[conversationID] ?? []
            let capturedWorkspace = panelID == .primary
                ? assets.snapshot(notes: overview?.notes ?? [], title: \.title)
                : nil
            let session = model.sessions.session(for: selectedConversation.id)
            Task { @MainActor in
                var sendError: String?
                do {
                    try await session.send(AgentMessageInput(
                        text: content,
                        attachments: submittedAttachments,
                        visibleWorkspace: capturedWorkspace
                    ))
                } catch { sendError = error.localizedDescription }
                let accepted = sendError == nil
                let currentDraft = draftsByConversationID[conversationID, default: ""]
                draftsByConversationID[conversationID] = accepted && currentDraft == content ? "" : currentDraft
                if accepted {
                    let submittedIDs = Set(submittedAttachments.map(\.id))
                    attachmentDraftsByConversation[conversationID, default: []]
                        .removeAll { submittedIDs.contains($0.id) }
                }
                submittingConversationIDs.remove(conversationID)
                if !accepted, chatPanels.activeConversationID == conversationID {
                    showNotice(sendError ?? "The agent connection is unavailable. Your draft is preserved.")
                }
            }
            return
        } else {
            showNotice("Choose a conversation before sending. Your draft is preserved.")
        }
    }

    private func handleAttachmentAction(
        from panelID: ChatPanelID,
        _ action: ComposerAttachmentAction
    ) {
        guard chatPanels.panel(id: panelID)?.conversationID != nil else {
            showNotice("Choose a conversation before attaching something.")
            return
        }
        activatePanel(panelID)
        attachmentTargetConversationID = chatPanels.panel(id: panelID)?.conversationID
        switch action {
        case .upload: showsAttachmentImporter = true
        case .note: attachmentPicker = .note
        case .conversation: attachmentPicker = .conversation
        }
    }

    @discardableResult
    private func attachFiles(
        _ urls: [URL],
        to panelID: ChatPanelID
    ) -> Bool {
        guard let conversationID = chatPanels.panel(id: panelID)?.conversationID else { return false }
        return attachFiles(urls, conversationID: conversationID)
    }

    @discardableResult
    private func attachFiles(_ urls: [URL], conversationID: String) -> Bool {
        Task { @MainActor in
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer {
                scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                ComposerNativeTextView.releaseTemporaryAttachments(urls)
            }
            do {
                let files = urls.map { url in
                    let type = UTType(filenameExtension: url.pathExtension)
                    return (url: url, mimeType: type?.preferredMIMEType ?? "application/octet-stream")
                }
                for attachment in try await model.sessions.stageMessageAttachments(files) {
                    appendAttachment(attachment, conversationID: conversationID)
                }
            } catch {
                showNotice(error.localizedDescription)
            }
        }
        return true
    }

    private func appendAttachment(
        _ attachment: AgentMessageAttachmentDraft,
        conversationID: String
    ) {
        var current = attachmentDraftsByConversation[conversationID] ?? []
        let duplicate = current.contains { existing in
            switch (existing, attachment) {
            case (.file(let lhs), .file(let rhs)): lhs.contentHash == rhs.contentHash
            case (.reference(let lhs), .reference(let rhs)):
                lhs.kind == rhs.kind && lhs.resourceID == rhs.resourceID
            default: false
            }
        }
        guard !duplicate else { return }
        let files = (current + [attachment]).compactMap { draft -> AgentFileAttachmentDraft? in
            guard case .file(let file) = draft else { return nil }
            return file
        }
        guard files.count <= AgentMessageAttachmentLimits.maximumCount else {
            showNotice(AgentMessageAttachmentError.tooManyFiles(
                maximum: AgentMessageAttachmentLimits.maximumCount
            ).localizedDescription)
            return
        }
        guard files.reduce(Int64(0), { $0 + $1.sizeBytes })
                <= AgentMessageAttachmentLimits.maximumTotalBytes else {
            showNotice(AgentMessageAttachmentError.totalTooLarge(
                maximumBytes: AgentMessageAttachmentLimits.maximumTotalBytes
            ).localizedDescription)
            return
        }
        current.append(attachment)
        attachmentDraftsByConversation[conversationID] = current
    }

    private func removeAttachment(
        _ id: String,
        from panelID: ChatPanelID
    ) {
        guard let conversationID = chatPanels.panel(id: panelID)?.conversationID else { return }
        attachmentDraftsByConversation[conversationID, default: []]
            .removeAll { $0.id == id }
    }

    private func conversation(
        in panelID: ChatPanelID
    ) -> WorkspaceConversationRecord? {
        guard let conversationID = chatPanels.panel(id: panelID)?.conversationID else {
            return nil
        }
        return overview?.conversations.first { $0.id == conversationID }
    }

}

enum WindowDestination: String, Equatable {
    case workspace
    case calendar
    case cronJobs
    case library
    case databases
    case usage
    case settings
}

struct WorkspaceSurface: View {
    @Bindable var model: ApplicationModel
    let agents: [WorkspaceAgent]
    let conversations: [WorkspaceConversationRecord]
    let chatPanels: ChatPanelState
    @Bindable var assets: WorkspaceAssetSession
    @Binding var draftsByConversationID: [String: String]
    let attachmentDraftsByConversation: [String: [AgentMessageAttachmentDraft]]
    let submittingConversationIDs: Set<String>
    @Binding var compactPane: CompactWorkspacePane
    @Binding var noteFocusMode: Bool
    @Binding var chatWidthPercent: Double
    @Binding var noteOnLeft: Bool
    let reservesLeadingRailControlSpace: Bool
    let reservesTrailingRailControlSpace: Bool
    let newlyCreatedNoteID: String?
    let onNewNoteFocusHandled: (String) -> Void
    let onActivatePanel: (ChatPanelID) -> Void
    let onAddPanel: (ChatPanelID) -> Void
    let onClosePanel: (ChatPanelID) -> Void
    let onNavigatePanel: (ChatPanelDirection) -> Bool
    let onOpenBoardSession: (String) -> Void
    /// Sends from a panel, naming the chat it shows.
    let onSend: (ChatPanelID, String?) -> Void
    let onAttachmentAction: (ChatPanelID, ComposerAttachmentAction) -> Void
    let onRemoveAttachment: (String, ChatPanelID) -> Void
    let onDropFiles: ([URL], ChatPanelID) -> Bool
    /// Starts a new chat in place of one whose native session is gone.
    let onReplaceSession: (WorkspaceConversationRecord) -> Void
    /// Chats being started, with their agents, until their first view arrives.
    @Binding var startingChats: [String: WorkspaceAgent]
    let onBotRoute: (BotTarget, ChatPanelID) -> Void
    let onOpenBotLink: (URL, ChatPanelID) -> Void
    let onOpenBotSettings: () -> Void
    /// The chat each panel shows now, nil for none (see `conversation(for:)`).
    @State private var shownConversationIDs: [ChatPanelID: String?] = [:]

    var body: some View {
        GeometryReader { geometry in
            let splitCompact = geometry.size.width < WovenMetrics.splitBreakpoint
            if assets.tabs.isPresented {
                if splitCompact {
                    if compactPane == .note {
                        assetPane(compact: true)
                    } else {
                        chatPanel(.primary, showNoteButton: true)
                    }
                } else if noteFocusMode {
                    assetPane()
                } else {
                    HStack(spacing: 0) {
                        if noteOnLeft {
                            assetPane()
                                .frame(minWidth: WovenMetrics.assetPaneMinimumWidth)
                            splitSeparator(totalWidth: geometry.size.width)
                            chatPanel(.primary, showNoteButton: false)
                                .frame(width: chatWidth(for: geometry.size.width))
                        } else {
                            chatPanel(.primary, showNoteButton: false)
                                .frame(width: chatWidth(for: geometry.size.width))
                            splitSeparator(totalWidth: geometry.size.width)
                            assetPane()
                                .frame(minWidth: WovenMetrics.assetPaneMinimumWidth)
                        }
                    }
                    .coordinateSpace(name: "workspace-split")
                }
            } else {
                ChatPanelGrid(state: chatPanels) { panelID in
                    chatPanel(panelID, showNoteButton: false)
                }
            }
        }
        .onKeyPress(.leftArrow, phases: .down) { press in
            handleNavigationKey(press, direction: .left)
        }
        .onKeyPress(.rightArrow, phases: .down) { press in
            handleNavigationKey(press, direction: .right)
        }
        .onKeyPress(.upArrow, phases: .down) { press in
            handleNavigationKey(press, direction: .up)
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            handleNavigationKey(press, direction: .down)
        }
    }

    private func assetPane(compact: Bool = false) -> some View {
        AssetPane(
            model: model, assets: assets, compact: compact, noteOnLeft: $noteOnLeft,
            focused: $noteFocusMode,
            reservesLeadingRailControlSpace: reservesLeadingRailControlSpace,
            reservesTrailingRailControlSpace: reservesTrailingRailControlSpace,
            newlyCreatedNoteID: newlyCreatedNoteID, onNewNoteFocusHandled: onNewNoteFocusHandled,
            onBack: { compactPane = .chat }, onOpenSession: onOpenBoardSession
        )
    }

    private func splitSeparator(totalWidth: CGFloat) -> some View {
        SplitSeparator(
            totalWidth: totalWidth,
            noteOnLeft: noteOnLeft,
            chatWidthPercent: $chatWidthPercent
        )
    }

    private var workspaceContextLabel: String? {
        _ = assets.pageRevision
        var labels: [String] = []
        let count = assets.tabs.noteIDs.count
        if count > 0 { labels.append("\(count) open artifact\(count == 1 ? "" : "s")") }
        let pageCount = assets.tabs.browserIDs.compactMap { assets.pages[$0] }
            .filter { $0.url.hasPrefix("https://") || $0.url.hasPrefix("http://") }.count
        if pageCount > 0 { labels.append("\(pageCount) browser URL\(pageCount == 1 ? "" : "s")") }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }

    /// Open artifacts and browser tabs at send time, from the same snapshot regular chats use.
    private func botContext(for panelID: ChatPanelID) -> String? {
        guard panelID == .primary else { return nil }
        _ = assets.pageRevision
        let notes = model.workspace.workspaceOverview?.notes ?? []
        return assets.snapshot(notes: notes) { $0.title }?.promptContext
    }

    @ViewBuilder private func chatPanel(
        _ panelID: ChatPanelID,
        showNoteButton: Bool
    ) -> some View {
        if let target = chatPanels.panel(id: panelID)?.botTarget {
            botPanel(panelID, target: target, showNoteButton: showNoteButton)
        } else {
            conversationPanel(panelID, showNoteButton: showNoteButton)
        }
    }

    /// The reveal-rail and assets buttons float over the panels at the window's top edges.
    private func botHeaderInsets(for panelID: ChatPanelID) -> BotHeaderInsets {
        let reachesLeadingEdge = panelID == .primary && !(assets.tabs.isPresented && noteOnLeft)
        let reachesTrailingEdge = panelID == .primary ? !chatPanels.hasAuxiliaryPanels && !(assets.tabs.isPresented && !noteOnLeft) : true
        return BotHeaderInsets(
            left: reachesLeadingEdge && reservesLeadingRailControlSpace ? 44 : 0,
            right: !reachesTrailingEdge ? 0 : (reservesTrailingRailControlSpace ? 88 : 44)
        )
    }

    private func botPanel(
        _ panelID: ChatPanelID,
        target: BotTarget,
        showNoteButton: Bool
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            BotConversationSurface(
                bots: model.bots,
                panelID: panelID,
                target: target,
                context: botContext(for: panelID),
                headerInsets: botHeaderInsets(for: panelID),
                focusGeneration: chatPanels.focusRequest?.panelID == panelID ? chatPanels.focusRequest?.generation : nil,
                startsComposerCollapsed: panelID != .primary,
                usesCompactSpacing: chatPanels.hasAuxiliaryPanels,
                showsClosePanel: chatPanels.canClosePanel(panelID),
                showsAddPanel: chatPanels.canAddPanel(from: panelID),
                onActivate: { onActivatePanel(panelID) },
                onClosePanel: { onClosePanel(panelID) },
                onAddPanel: { onAddPanel(panelID) },
                onRoute: { onBotRoute($0, panelID) },
                onOpenLink: { onOpenBotLink($0, panelID) },
                onOpenSettings: onOpenBotSettings,
                onOpenConnections: {
                    // Bots use the sign-ins of the machine they run on.
                    model.navigation.pendingConnectionsScope = target.machineID
                },
                onOpenProfiles: {
                    model.navigation.pendingBotProfilesMachine = target.machineID
                    onOpenBotSettings()
                }
            )
            if showNoteButton { compactAssetsButton }
        }
    }

    private var compactAssetsButton: some View {
        Button {
            compactPane = .note
        } label: {
            Label("Artifacts", systemImage: "rectangle.on.rectangle")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 32)
        }
        .buttonStyle(PillButtonStyle())
        .padding(.trailing, 52)
        .padding(.top, 12)
    }

    private func conversationPanel(
        _ panelID: ChatPanelID,
        showNoteButton: Bool
    ) -> some View {
        let chosenID = chatPanels.panel(id: panelID)?.conversationID
        let startingAgent = chosenID.flatMap { startingChats[$0] }
        // A chat being started shows at once, as the new chat it is.
        let conversation = startingAgent == nil
            ? conversation(for: panelID)
            : conversations.first { $0.id == chosenID }
        let attachments = conversation.flatMap {
            attachmentDraftsByConversation[$0.id]
        } ?? []
        return ZStack(alignment: .topTrailing) {
            CloudConversation(
                model: model,
                agent: agent(for: conversation) ?? startingAgent,
                conversation: conversation,
                startingAgent: startingAgent,
                attachedNoteTitle: panelID == .primary && assets.tabs.isPresented
                    ? workspaceContextLabel : nil,
                draft: draftBinding(for: conversation?.id),
                attachments: attachments,
                sendInProgress: conversation.map {
                    submittingConversationIDs.contains($0.id)
                } ?? false,
                startsComposerCollapsed: panelID != .primary,
                usesCompactPanelSpacing: chatPanels.hasAuxiliaryPanels,
                showsClosePanel: chatPanels.canClosePanel(panelID),
                showsAddPanel: chatPanels.canAddPanel(from: panelID),
                focusRequestGeneration: chatPanels.focusRequest?.panelID == panelID
                    ? chatPanels.focusRequest?.generation
                    : nil,
                onActivatePanel: { onActivatePanel(panelID) },
                onClosePanel: { onClosePanel(panelID) },
                onAddPanel: { onAddPanel(panelID) },
                onSend: { onSend(panelID, conversation?.id) },
                onAttachmentAction: { onAttachmentAction(panelID, $0) },
                onRemoveAttachment: { onRemoveAttachment($0, panelID) },
                onDropFiles: { onDropFiles($0, panelID) },
                onCommandNavigation: handleComposerNavigation,
                onNewSession: conversation.map { gone in { onReplaceSession(gone) } }
            )
            if showNoteButton { compactAssetsButton }
        }
        .task(id: conversation?.id) {
            guard let conversation else { return }
            // The open chat follows its live state until it closes.
            await model.sessions.follow(conversation.id)
        }
        .task(id: chatPanels.panel(id: panelID)?.conversationID) {
            // The chosen chat loads while the one on screen stays.
            guard let chosen = chatPanels.panel(id: panelID)?.conversationID else { return }
            await model.sessions.follow(chosen)
        }
        .onChange(of: conversation?.id, initial: true) { _, shown in shownConversationIDs[panelID] = .some(shown) }
        .onChange(of: startingAgent != nil && conversation?.id == chosenID
                  && conversation.flatMap { model.sessions.conversationState(for: $0.id)?.hasLoaded } == true) { _, started in
            if started, let chosenID { startingChats[chosenID] = nil }
        }
    }

    /// The chat a panel shows. A chosen chat replaces the one on screen, or
    /// the panel's empty state, once its first view has arrived, so the
    /// transcript changes in one step instead of showing an empty chat first.
    private func conversation(
        for panelID: ChatPanelID
    ) -> WorkspaceConversationRecord? {
        guard let conversationID = chatPanels.panel(id: panelID)?.conversationID else {
            return nil
        }
        let chosen = conversations.first { $0.id == conversationID }
        guard let shownID = shownConversationIDs[panelID], shownID != conversationID,
              !model.sessions.session(for: conversationID).hasLoaded else { return chosen }
        guard let shownID else { return nil }
        return conversations.first { $0.id == shownID } ?? chosen
    }

    private func agent(
        for conversation: WorkspaceConversationRecord?
    ) -> WorkspaceAgent? {
        guard let agentID = conversation?.agentID else { return nil }
        return agents.first { $0.id == agentID }
    }

    private func draftBinding(for conversationID: String?) -> Binding<String> {
        let conversationID = conversationID ?? ""
        return Binding(
            get: { draftsByConversationID[conversationID, default: ""] },
            set: { draftsByConversationID[conversationID] = $0 }
        )
    }

    private func handleNavigationKey(
        _ press: KeyPress,
        direction: ChatPanelDirection
    ) -> KeyPress.Result {
        guard press.modifiers == .command,
              chatPanels.hasAuxiliaryPanels,
              !chatPanels.assetPresented else {
            return .ignored
        }
        _ = onNavigatePanel(direction)
        return .handled
    }

    private func handleComposerNavigation(
        _ direction: ComposerNavigationDirection
    ) -> Bool {
        let panelDirection: ChatPanelDirection = switch direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
        return onNavigatePanel(panelDirection)
    }

    private func chatWidth(for totalWidth: CGFloat) -> CGFloat {
        let contentWidth = max(1, totalWidth - WovenMetrics.separatorWidth)
        let bounds = chatWidthBounds(totalWidth: totalWidth)
        let normalized = min(max(chatWidthPercent, bounds.lowerBound), bounds.upperBound)
        return contentWidth * CGFloat(normalized / 100)
    }
}

struct ChatPanelGrid<Content: View>: View {
    @Environment(\.wovenTheme) private var theme
    let state: ChatPanelState
    @ViewBuilder let content: (ChatPanelID) -> Content

    var body: some View {
        if state.auxiliaryRows.isEmpty {
            content(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                content(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                verticalDivider
                VStack(spacing: 0) {
                    ForEach(Array(state.auxiliaryRows.enumerated()), id: \.offset) { index, row in
                        panelRow(row)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if index < state.auxiliaryRows.count - 1 {
                            horizontalDivider
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func panelRow(_ row: [ChatPanel]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.element.id) { index, panel in
                content(panel.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if index < row.count - 1 {
                    verticalDivider
                }
            }
        }
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(theme.palette.border)
            .frame(width: ChatPanelMetrics.dividerThickness)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var horizontalDivider: some View {
        Rectangle()
            .fill(theme.palette.border)
            .frame(height: ChatPanelMetrics.dividerThickness)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
