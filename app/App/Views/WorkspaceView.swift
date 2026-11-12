import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WovenMatterClient
import WovenMatterCore

final class DashboardScrollHoverCoordinator: @unchecked Sendable {
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

struct DashboardScrollHoverCoordinatorEnvironmentKey: EnvironmentKey {
    static let defaultValue = DashboardScrollHoverCoordinator()
}

extension EnvironmentValues {
    var dashboardScrollHoverCoordinator: DashboardScrollHoverCoordinator {
        get { self[DashboardScrollHoverCoordinatorEnvironmentKey.self] }
        set { self[DashboardScrollHoverCoordinatorEnvironmentKey.self] = newValue }
    }
}

struct DashboardRunDisplayPolicy {
    static func presentsStatus(_ run: WorkspaceRunRecord) -> Bool {
        run.status != "queued" && run.status != "accepted"
    }

    static func presentsMessage(
        _ message: WorkspaceMessageRecord,
        run: WorkspaceRunRecord?
    ) -> Bool {
        guard message.role == "assistant", message.content.isEmpty else { return true }
        guard let run else { return true }
        return presentsStatus(run)
    }
}

struct WorkspaceView: View {
    @Bindable var model: ApplicationModel
    @State private var conversationToRename: WorkspaceConversationRecord?
    @State private var noteToRename: WorkspaceNoteRecord?
    @State private var showsWorkspaceTrash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(DashboardTheme.storageKey) private var themeRawValue = DashboardTheme.green.rawValue
    @AppStorage(DashboardSidebarStyle.storageKey) private var sidebarStyleRawValue = DashboardSidebarStyle.defaultStyle.rawValue
    @AppStorage(DashboardSidebarSide.storageKey) private var singleSidebarSideRawValue = DashboardSidebarSide.defaultSide.rawValue
    @AppStorage("wovenmatter.dashboard.left-rail") private var leftRailRequested = true
    @AppStorage("wovenmatter.dashboard.right-rail") private var rightRailRequested = true
    @AppStorage("wovenmatter.dashboard.single-rail") private var singleRailRequested = true
    @AppStorage("wovenmatter.dashboard.chat-width-percent") private var chatWidthPercent = 58.0
    @AppStorage("wovenmatter.dashboard.note-on-left") private var noteOnLeft = false
    @AppStorage(DashboardPinnedAgentsStore.storageKey) private var pinnedAgentIDsRaw = "[]"
    @AppStorage(DashboardAgentOrderStore.storageKey) private var agentOrderRaw = "{}"
    @AppStorage(DashboardAgentDisclosureStore.storageKey) private var agentDisclosureRaw = "[]"
    @State private var selectedAgentID: UUID?
    @State private var chatPanels = DashboardChatPanelState()
    private var assets: WorkspaceAssetSession { model.workspaceAssets }
    private var selectedNoteID: String? { assets.tabs.selectedNoteID }
    @State private var selectedFolderID: String?
    @State private var localExecutionWorkspaceID: String?
    @State private var sidebarNavigation = DashboardSidebarNavigationState()
    @State private var destination = DashboardDestination.workspace
    /// The one rail revealed while the window is too narrow for the requested rails.
    @State private var compactRail: DashboardSidebarSide?
    @State private var compactWorkspacePane = CompactWorkspacePane.chat
    @State private var noteFocusMode = false
    @State private var draftsByConversationID: [String: String] = [:]
    @State private var attachmentDraftsByConversation: [String: [AgentMessageAttachmentDraft]] = [:]
    @State private var submittingConversationIDs: Set<String> = []
    @State private var showsAttachmentImporter = false
    @State private var archivedLibrarySource: WorkspaceLibraryItem?
    @State private var attachmentPicker: DashboardAttachmentPickerKind?
    @State private var attachmentTargetConversationID: String?
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var showsNewChatChooser = false
    @State private var showsNewNoteChooser = false
    @State private var newlyCreatedNoteID: String?

    private var theme: DashboardTheme {
        DashboardTheme(rawValue: themeRawValue) ?? .green
    }

    private var allAgents: [WorkspaceAgent] {
        model.orderedLocalCLIAgents
            + model.remoteWorkspaceAgents
    }

    private var selectedConversationID: String? {
        chatPanels.activeConversationID
    }

    private var sidebarAgents: [WorkspaceAgent] {
        model.installedOrderedLocalCLIAgents
            + model.remoteWorkspaceAgents
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

    private var sidebarStyle: DashboardSidebarStyle {
        DashboardSidebarStyle(rawValue: sidebarStyleRawValue) ?? .defaultStyle
    }

    private var singleSidebarSide: DashboardSidebarSide {
        get { DashboardSidebarSide(rawValue: singleSidebarSideRawValue) ?? .defaultSide }
        nonmutating set { singleSidebarSideRawValue = newValue.rawValue }
    }

    var body: some View {
        workspaceWithAttachments
        .focusedSceneValue(\.workspaceMenuActions, WorkspaceMenuActions(
            newChat: createConversation,
            newNote: openNewNoteChooser,
            newBrowserTab: openNewBrowserTab,
            refresh: { Task { await model.refreshWorkspace() } }
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
        .onChange(of: model.pendingDefaultAgentSettingsScope) { _, scope in
            if scope != nil { openUtility(.settings) }
        }
        .onChange(of: model.pendingConnectionsScope) { _, scope in
            if scope != nil { openUtility(.settings) }
        }
        .onReceive(NotificationCenter.default.publisher(for: MacAccessSetupModel.openSettingsNotification)) { _ in
            model.pendingConnectionsScope = "permissions"
            openUtility(.settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("wovenmatter.open-connections"))) { event in
            model.pendingConnectionsScope = event.object as? String ?? "global"
            openUtility(.settings)
        }
        .task(id: model.state == .ready) {
            localExecutionWorkspaceID = try? await model.executionWorkspaceIdentity(workspaceID: nil)
        }
    }

    // Keep presentation and routing as separate opaque expressions so the
    // supported Xcode toolchains do not solve one enormous modifier chain.
    private var workspaceLayout: some View {
        GeometryReader { geometry in
            let layout = DashboardLayoutState.resolve(
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
                .alert("Pi Durable switched models", isPresented: Binding(get: { model.defaultAgentFallbackNotice != nil }, set: { if !$0 { model.defaultAgentFallbackNotice = nil } })) {
                    Button("OK") { model.defaultAgentFallbackNotice = nil }
                } message: { Text(model.defaultAgentFallbackNotice ?? "") }

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
                    DashboardNewChatDrawer(
                        model: model,
                        folderOwnerID: model.workspaceOverview?.folders.first(where: { $0.id == selectedFolderID })?.executionWorkspaceID,
                        localExecutionWorkspaceID: localExecutionWorkspaceID,
                        onClose: closeNewChatChooser,
                        onSelect: startNewChat
                    )
                    .frame(width: min(440, max(360, geometry.size.width - 32)))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if showsNewNoteChooser {
                    DashboardNewNoteDrawer(
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
        .environment(\.dashboardTheme, theme)
        .environment(\.workspaceApplicationModel, model)
        .environment(\.openWorkspaceConversation, { id in
            destination = .workspace
            selectConversation(id)
        })
        .preferredColorScheme(theme.colorScheme)
        .tint(DashboardPalette.primary)
        .foregroundStyle(DashboardPalette.foreground)
    }

    private var workspaceConversationIDs: [String] {
        model.workspaceOverview?.conversations.map(\.id) ?? []
    }

    private var workspaceNoteIDs: [String] {
        model.workspaceOverview?.notes.map(\.id) ?? []
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
            model.startAutomationHost()
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
                model.markConversationRead(id: conversationID)
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
                  let oldSide = DashboardSidebarSide(rawValue: oldValue),
                  let newSide = DashboardSidebarSide(rawValue: newValue),
                  compactRail == oldSide else { return }
            compactRail = newSide
        }
        .onChange(of: surfacePreferenceSignature) { _, _ in
            model.persistMacSurfaceProfileFromUserDefaults()
        }
        .onDisappear { noticeTask?.cancel() }
        .sheet(item: $conversationToRename) { conversation in
            DashboardRenameSheet(heading: "Rename chat", placeholder: "Chat name", initialTitle: conversation.title) { title in
                try await model.mutateConversation(id: conversation.id, mutation: .rename(title))
            }
        }
        .sheet(item: $noteToRename) { note in
            DashboardRenameSheet(heading: "Rename note", placeholder: "Note name", initialTitle: model.noteDraft(for: note).title) { title in
                try await model.mutateNote(id: note.id, mutation: .rename(title))
            }
        }
        .sheet(isPresented: $showsWorkspaceTrash) {
            if let client = model.liveLibraryClient {
                LibraryClientTrashPane(model: client)
                    .frame(minWidth: 600, minHeight: 420)
            } else {
                DashboardWorkspaceTrashSheet(model: model)
            }
        }
        .sheet(item: $archivedLibrarySource) { item in
            DashboardLibrarySourceSheet(item: item, model: model)
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
            DashboardAttachmentPicker(
                kind: kind,
                notes: model.workspaceOverview?.notes ?? [],
                conversations: (model.workspaceOverview?.conversations ?? []).filter {
                    $0.id != attachmentTargetConversationID
                },
                onSelectNote: { note in
                    if let conversationID = attachmentTargetConversationID {
                        appendAttachment(model.noteAttachmentDraft(note), conversationID: conversationID)
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
                            appendAttachment(model.conversationAttachmentDraft(conversation), conversationID: conversationID)
                        }
                    }
                }
            )
        }
    }

    private func desktopShell(layout: DashboardLayoutState) -> some View {
        let showLeftRailButton = sidebarStyle != .split
            ? !layout.showsLeftRail && singleSidebarSide == .left
            : !layout.showsLeftRail
        let showRightRailButton = sidebarStyle != .split
            ? !layout.showsRightRail && singleSidebarSide == .right
            : !layout.showsRightRail

        return HStack(spacing: DashboardMetrics.shellGap) {
            if layout.showsLeftRail {
                railGroup(side: .left, collapsesAdaptivePages: layout.compact)
            }

            centerSurface(
                showLeftRailButton: showLeftRailButton,
                showRightRailButton: showRightRailButton,
                onLeftRail: { revealRail(side: .left, compact: layout.compact) },
                onRightRail: { revealRail(side: .right, compact: layout.compact) }
            )
            .frame(minWidth: DashboardMetrics.workspaceMinimumWidth)

            if layout.showsRightRail {
                railGroup(side: .right, collapsesAdaptivePages: layout.compact)
            }
        }
        .padding(.horizontal, DashboardMetrics.shellInset)
        .padding(.bottom, DashboardMetrics.shellInset)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: layout)
    }

    @ViewBuilder
    private func railGroup(
        side: DashboardSidebarSide,
        collapsesAdaptivePages: Bool
    ) -> some View {
        let pages = sidebarNavigation.pages(
            for: side,
            style: sidebarStyle,
            collapsesAdaptivePages: collapsesAdaptivePages
        )
        let usesUnifiedSurface = sidebarStyle == .adaptive && pages.count == 2

        let content = HStack(spacing: usesUnifiedSurface ? 0 : DashboardMetrics.shellGap) {
            ForEach(pages, id: \.self) { page in
                rail(side: side, page: page, adaptiveExpanded: usesUnifiedSurface)
                    .frame(width: DashboardMetrics.railWidth)
                    .background {
                        if !usesUnifiedSurface {
                            DashboardRailBackground()
                        }
                }
            }
        }

        if usesUnifiedSurface {
            content
                .background {
                    DashboardRailBackground()
                }
                .overlay {
                    Rectangle()
                        .fill(theme.palette.border)
                        .frame(width: 0.5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .clipShape(DashboardShapes.windowAlignedSurface)
        } else {
            content
        }
    }

    private func rail(
        side: DashboardSidebarSide,
        page: DashboardSidebarPage,
        adaptiveExpanded: Bool
    ) -> some View {
        DashboardSidebarRail(
            side: side,
            page: page,
            style: sidebarStyle,
            adaptiveExpanded: adaptiveExpanded,
            agents: allAgents,
            navigationAgents: sidebarAgents,
            remoteWorkspaces: model.remoteWorkspaces,
            localWorkspaceReady: model.localACPWorkspaceAvailability.isReady,
            localExecutionWorkspaceID: localExecutionWorkspaceID,
            executionWorkspaces: model.executionWorkspaceRegistry,
            conversationOwners: model.federatedExecutionOwners,
            folders: model.workspaceOverview?.folders ?? [],
            conversations: model.workspaceOverview?.conversations ?? [],
            notes: model.workspaceOverview?.notes ?? [],
            runningConversationIDs: model.localRunningConversationIDs,
            selectedAgentID: selectedAgentID,
            selectedFolderID: selectedFolderID,
            selectedConversationID: selectedConversationID,
            selectedNoteID: selectedNoteID,
            bots: model.bots,
            selectedBotTarget: chatPanels.activeBotTarget,
            destination: destination,
            contentRevision: model.workspaceListRevision,
            pinnedAgentIDsRaw: $pinnedAgentIDsRaw,
            agentOrderRaw: $agentOrderRaw,
            agentDisclosureRaw: $agentDisclosureRaw,
            actions: DashboardSidebarActions(
                onCollapse: collapseRail,
                onMoveSingleRail: moveSingleSidebar,
                onShowNavigation: showSidebarNavigation,
                onUtility: openUtility,
                onSelectAgent: selectAgent,
                onCreateAgentChat: createAgentChat,
                onSelectRemoteAgent: selectRemoteAgent,
                onStartRemoteChat: startRemoteChat,
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
                model.persistMacSurfaceProfileFromUserDefaults()
            }
        )
    }

    private func collapseRail(side: DashboardSidebarSide) {
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

    private func revealRail(side: DashboardSidebarSide, compact: Bool) {
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
                    DashboardWorkspaceSurface(
                        model: model,
                        agents: allAgents,
                        conversations: model.workspaceOverview?.conversations ?? [],
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
                        onSend: send,
                        onAttachmentAction: handleAttachmentAction,
                        onRemoveAttachment: removeAttachment,
                        onDropFiles: attachFiles,
                        onBotRoute: { target, panelID in
                            _ = chatPanels.setBot(target, in: panelID)
                        },
                        onOpenBotLink: { url, panelID in openBotLink(url, from: panelID) },
                        onOpenBotSettings: openBotSettings
                    )
                case .calendar:
                    DashboardCalendarSurface(model: model, onOpenSession: { id in
                        destination = .workspace
                        selectConversation(id)
                    })
                case .cronJobs:
                    DashboardCronSurface(
                        model: model,
                        onOpenConversation: { conversationID in
                            destination = .workspace
                            selectConversation(conversationID)
                        }
                    )
                case .library:
                    if let client = model.liveLibraryClient {
                        LibraryClientLibraryPane(model: client)
                    } else {
                    DashboardLibrarySurface(library: model.library, configuredWorkspaces: model.remoteWorkspaces.workspaces.map {
                        (id: $0.id.uuidString.lowercased(), name: $0.name)
                    }) { item in
                        if model.workspaceOverview?.conversations.contains(where: { $0.id == item.conversationID }) == true {
                            model.libraryMessageTarget = item
                            destination = .workspace
                            selectConversation(item.conversationID)
                        } else {
                            archivedLibrarySource = item
                        }
                    }
                    }
                case .databases:
                    DashboardDatabasesView(model: model)
                case .usage:
                    DashboardUsageView(
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
                    DashboardRevealRailButton(side: .left,
                        width: presentsAssets ? DashboardMetrics.assetToolbarControlWidth : 36,
                        height: presentsAssets ? DashboardMetrics.assetToolbarControlHeight : 36,
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
                    .buttonStyle(DashboardIconButtonStyle())
                    .help(assets.tabs.selected == nil ? "Open browser" : "Show assets")
                    .accessibilityLabel(assets.tabs.selected == nil ? "Open browser" : "Show assets")
                }
                if showRightRailButton {
                    DashboardRevealRailButton(side: .right,
                        width: presentsAssets ? DashboardMetrics.assetToolbarControlWidth : 36,
                        height: presentsAssets ? DashboardMetrics.assetToolbarControlHeight : 36,
                        action: onRightRail)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, presentsAssets ? DashboardMetrics.assetToolbarVerticalPadding : 12)

            if let notice {
                Text(notice)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DashboardPalette.foreground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(DashboardPalette.background.opacity(0.94))
                    .clipShape(Capsule())
                    .overlay { Capsule().stroke(theme.palette.border, lineWidth: 1) }
                    .shadow(color: DashboardPalette.foreground.opacity(0.08), radius: 16, y: 8)
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
        model.workspaceOverview?.conversations.first { $0.id == selectedConversationID }
    }

    private var selectedNote: WorkspaceNoteRecord? {
        model.workspaceOverview?.notes.first { $0.id == selectedNoteID }
    }

    private var conversationsForSelectedAgent: [WorkspaceConversationRecord] {
        guard let agent = selectedAgent else { return [] }
        return (model.workspaceOverview?.conversations ?? []).filter { conversation in
            return conversation.agentID == agent.id.uuidString.lowercased()
        }
    }

    private func selectDefaults() {
        // A bot channel is a complete selection; there is no chat to restore.
        if chatPanels.activeBotTarget != nil { return }
        // A successful creation may arrive before the read projection. Keep its
        // selected ID until the next snapshot instead of restoring an older chat.
        if selectedConversationID != nil && selectedConversation == nil { return }
        if selectedConversation?.localRuntimeKind != nil {
            selectedAgentID = selectedConversation?.agentID.flatMap { agentID in
                allAgents.first {
                    $0.id.uuidString.lowercased() == agentID
                }?.id
            }
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
        if selectedAgent == nil,
           selectedConversation?.localRuntimeKind != nil {
            return
        }
        if let selectedConversation, conversationsForSelectedAgent.contains(where: { $0.id == selectedConversation.id }) {
            return
        }
        _ = chatPanels.replaceActiveConversation(
            with: conversationsForSelectedAgent.first?.id
        )
    }

    private func selectAgent(_ id: UUID) {
        selectedAgentID = id
        let latest = conversationsForSelectedAgent.max {
            ($0.lastMessageAt ?? "", $0.id) < ($1.lastMessageAt ?? "", $1.id)
        }
        _ = chatPanels.replaceActiveConversation(with: latest?.id)
        destination = .workspace
        compactWorkspacePane = .chat
    }

    private func selectRemoteAgent(_ target: RemoteHarnessChatTarget) {
        let latest = (model.workspaceOverview?.conversations ?? []).filter {
            $0.remoteWorkspaceID == target.configuration.id && $0.localRuntimeKind == target.harness.id
        }.max { ($0.lastMessageAt ?? "", $0.id) < ($1.lastMessageAt ?? "", $1.id) }
        if let latest { selectConversation(latest.id) }
        else {
            _ = chatPanels.replaceActiveConversation(with: nil)
            selectedAgentID = nil
            destination = .workspace
            compactWorkspacePane = .chat
        }
    }

    private func createAgentChat(_ id: UUID) {
        if let agent = allAgents.first(where: { $0.id == id }) {
            if model.peerAgentWorkspaces[agent.id] != nil {
                let folder = selectedFolderID
                let selection = beginChatCreation(agentID: agent.id)
                Task {
                    do {
                        let id = try await model.createPairedMacSession(agentID: agent.id, conversationID: selection.id, folderID: folder)
                        finishChatCreation(selection, conversationID: id)
                    } catch { finishChatCreation(selection, conversationID: nil); showNotice(error.localizedDescription) }
                }
            } else if agent.governingPlane == .remoteWorkspace,
               let target = model.remoteWorkspaces.readyChatTargets.first(where: {
                   $0.configuration.id == agent.runtimeDeviceID && $0.harness.id == agent.runtimeKind
               }) {
                startRemoteChat(target)

            } else if agent.governingPlane != .remoteWorkspace {
                startDirectChat(agent.runtimeKind)
            } else {
                showNotice("Connect this workspace before starting a chat.")
            }
        }
        destination = .workspace
        compactWorkspacePane = .chat
    }

    private func selectBot(_ target: DashboardBotTarget) {
        _ = chatPanels.replaceActiveBot(with: target)
        selectedAgentID = nil
        destination = .workspace
        compactWorkspacePane = .chat
    }

    private func openBotSettings() {
        model.pendingBotsSettings = true
        openUtility(.settings)
    }

    /// Links from a bot open beside it, the same way a chat's browser tabs do.
    private func openBotLink(_ url: URL, from panelID: DashboardChatPanelID) {
        if let page = WovenAppLink(url) {
            switch page {
            case .accounts:
                model.pendingConnectionsScope = "global"
            case .botProfiles:
                model.pendingBotProfilesMachine = chatPanels.panel(id: panelID)?.botTarget?.machineID
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
        guard let conversation = model.workspaceOverview?.conversations.first(where: { $0.id == id }) else { return }
        _ = chatPanels.replaceActiveConversation(with: id)
        if conversation.localRuntimeKind != nil {
            selectedAgentID = conversation.agentID.flatMap { agentID in
                allAgents.first {
                    $0.id.uuidString.lowercased() == agentID
                }?.id
            }
        }
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
        model.clearNoteMutationError()
        Task {
            guard let noteID = await model.createNote(
                folderID: selectedFolderID,
                kind: kind
            ) else {
                showNotice(model.noteMutationError ?? "The note could not be created.")
                return
            }
            newlyCreatedNoteID = noteID
            selectNote(noteID)
        }
    }

    private func createFolder(name: String, workspaceID: UUID?, externalRoot: URL?) {
        model.clearFolderMutationError()
        Task {
            guard let folderID = await model.createFolder(name: name, workspaceID: workspaceID, externalRoot: externalRoot) else {
                showNotice(model.folderMutationError ?? "The folder could not be created.")
                return
            }
            selectFolder(folderID)
        }
    }

    private func renameFolder(id: String, name: String) {
        model.clearFolderMutationError()
        Task {
            guard await model.renameFolder(id: id, name: name) else {
                showNotice(model.folderMutationError ?? "The folder could not be renamed.")
                return
            }
        }
    }

    private func setFolderPinned(id: String, isPinned: Bool) {
        model.clearFolderMutationError()
        Task {
            guard await model.setFolderPinned(id: id, isPinned: isPinned) else {
                showNotice(model.folderMutationError ?? "The folder could not be updated.")
                return
            }
        }
    }

    private func moveFolder(id: String, direction: WorkspaceFolderMoveDirection) {
        model.clearFolderMutationError()
        Task {
            guard await model.moveFolder(id: id, direction: direction) else {
                showNotice(model.folderMutationError ?? "The folder could not be moved.")
                return
            }
        }
    }

    private func deleteFolder(id: String, deleteRoot: Bool) {
        model.clearFolderMutationError()
        Task {
            guard await model.deleteFolder(id: id, deleteRoot: deleteRoot) else {
                showNotice(model.folderMutationError ?? "The folder could not be removed.")
                return
            }
            if selectedFolderID == id {
                selectFolder(nil)
            }
        }
    }

    private func setFolderReferencePaths(id: String, paths: [String]) {
        model.clearFolderMutationError()
        Task {
            guard await model.setFolderReferencePaths(id: id, paths: paths) else {
                showNotice(model.folderMutationError ?? "The reference locations could not be updated.")
                return
            }
        }
    }

    private func createChatInFolder(_ id: String?) {
        selectFolder(id)
        showsNewNoteChooser = false
        showsNewChatChooser = true
    }

    private func handleConversationAction(_ conversation: WorkspaceConversationRecord, action: DashboardConversationMenuAction) {
        if case .rename = action {
            conversationToRename = conversation
            return
        }
        Task {
            do {
                switch action {
                case .rename: break
                case .setPinned(let pinned):
                    try await model.mutateConversation(id: conversation.id, mutation: .setPinned(pinned))
                case .moveToTrash:
                    try await model.mutateConversation(id: conversation.id, mutation: .moveToTrash)
                    for panel in chatPanels.panels where panel.conversationID == conversation.id {
                        _ = chatPanels.setConversation(nil, in: panel.id)
                    }
                    selectDefaults()
                    showNotice("Chat moved to Trash.")
                case .export(let format):
                    let url = try await model.exportConversation(id: conversation.id, format: format)
                    if try await DashboardConversationExport.save(url: url, title: conversation.title, format: format) {
                        showNotice("Chat exported.")
                    }
                }
            } catch {
                showNotice(error.localizedDescription)
            }
        }
    }

    private func handleNoteAction(_ note: WorkspaceNoteRecord, action: DashboardNoteMenuAction) {
        if case .rename = action {
            noteToRename = note
            return
        }
        Task {
            do {
                switch action {
                case .rename: break
                case .setPinned(let pinned):
                    try await model.mutateNote(id: note.id, mutation: .setPinned(pinned))
                case .moveToFolder(let folderID):
                    try await model.mutateNote(id: note.id, mutation: .moveToFolder(folderID))
                case .moveToTrash:
                    try await model.mutateNote(id: note.id, mutation: .moveToTrash)
                    assets.close(.note(note.id))
                    showNotice("Note moved to Trash.")
                case .export(let format):
                    let export = try await model.exportNote(id: note.id, format: format)
                    if try await DashboardNoteExport.save(export) {
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

    private func startNewChat(_ target: DashboardNewChatTarget) {
        switch target {
        case .acpDirect(let runtimeKind):
            startDirectChat(runtimeKind)
        case .remoteWorkspace(let target):
            startRemoteChat(target)
        case .peerAgent(let id):
            createAgentChat(id)
        }
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
        let previousAgentID: UUID?
        var conversationID: String { id.uuidString.lowercased() }
    }

    private func beginChatCreation(agentID: UUID?) -> ChatCreationSelection {
        let selection = ChatCreationSelection(previousConversationID: selectedConversationID, previousAgentID: selectedAgentID)
        selectedAgentID = agentID
        closeNewChatChooser()
        presentCreatedConversation(selection.conversationID)
        return selection
    }

    private func finishChatCreation(_ selection: ChatCreationSelection, conversationID: String?) {
        // A late setup response must not take focus from a newer navigation action.
        guard selectedConversationID == selection.conversationID else { return }
        if let conversationID { presentCreatedConversation(conversationID) }
        else {
            _ = chatPanels.replaceActiveConversation(with: selection.previousConversationID)
            selectedAgentID = selection.previousAgentID
        }
    }

    private func startDirectChat(_ runtimeKind: AgentRuntimeKind) {
        let requestedFolderID = selectedFolderID
        let selection = beginChatCreation(agentID: allAgents.first {
            $0.governingPlane != .remoteWorkspace && $0.runtimeKind == runtimeKind
        }?.id)
        Task {
            guard let conversationID = await model.createLocalACPSession(
                runtimeKind: runtimeKind, requestedConversationID: selection.id, folderID: requestedFolderID
            ) else {
                finishChatCreation(selection, conversationID: nil)
                showNotice(
                    model.localRunError
                        ?? "The local CLI chat could not be created."
                )
                return
            }
            await model.analytics.record(.active)
            finishChatCreation(selection, conversationID: conversationID)
        }
    }

    private func startRemoteChat(_ target: RemoteHarnessChatTarget) {
        let requestedFolderID = selectedFolderID
        let selection = beginChatCreation(agentID: allAgents.first {
            $0.governingPlane == .remoteWorkspace && $0.runtimeDeviceID == target.configuration.id && $0.runtimeKind == target.harness.id
        }?.id)
        Task {
            guard let conversationID = await model.createRemoteACPSession(
                target: target, requestedConversationID: selection.id, folderID: requestedFolderID
            ) else {
                finishChatCreation(selection, conversationID: nil)
                showNotice(
                    model.localRunError
                        ?? "The remote workspace chat could not be created."
                )
                return
            }
            await model.analytics.record(.active)
            finishChatCreation(selection, conversationID: conversationID)
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

    private func openUtility(_ next: DashboardDestination) {
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

    private func activatePanel(_ panelID: DashboardChatPanelID) {
        guard chatPanels.activePanelID != panelID else { return }
        guard chatPanels.activatePanel(panelID) else { return }
        synchronizeSelectionToActivePanel()
    }

    private func addPanel(from panelID: DashboardChatPanelID) {
        let newPanelID = DashboardChatPanelID(rawValue: UUID().uuidString.lowercased())
        let openConversationIDs = Set(chatPanels.panels.compactMap(\.conversationID))
        let conversationID = DashboardConversationSelection
            .mostRecentAvailableConversationID(
                in: model.workspaceOverview?.conversations ?? [],
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

    private func closePanel(_ panelID: DashboardChatPanelID) {
        guard chatPanels.closePanel(panelID) else { return }
        synchronizeSelectionToActivePanel()
    }

    private func navigatePanel(_ direction: DashboardChatPanelDirection) -> Bool {
        guard chatPanels.navigate(direction) != nil else { return false }
        synchronizeSelectionToActivePanel()
        return true
    }

    private func synchronizeSelectionToActivePanel() {
        guard let conversation = selectedConversation else { return }
        if conversation.localRuntimeKind != nil {
            selectedAgentID = conversation.agentID.flatMap { agentID in
                allAgents.first {
                    $0.id.uuidString.lowercased() == agentID
                }?.id
            }
        }
        model.markConversationRead(id: conversation.id)
    }

    private func send(from panelID: DashboardChatPanelID) {
        if let selectedConversation = conversation(in: panelID) {
            let conversationID = selectedConversation.id
            guard submittingConversationIDs.insert(conversationID).inserted else {
                return
            }
            let content = draftsByConversationID[conversationID, default: ""]
            let submittedAttachments = attachmentDraftsByConversation[conversationID] ?? []
            let capturedNote = panelID == .primary && assets.tabs.isPresented ? selectedNote : nil
            let capturedWorkspace = panelID == .primary
                ? assets.snapshot(notes: model.workspaceOverview?.notes ?? [], title: { model.noteDraft(for: $0).title })
                : nil
            Task { @MainActor in
                let notesSaved = capturedWorkspace?.notes.isEmpty != false ? true : await model.flushNoteDrafts()
                guard notesSaved else {
                    submittingConversationIDs.remove(conversationID)
                    showNotice("Save the open assets before sending. Your draft is preserved.")
                    return
                }
                let accepted = await model.sendAgentMessage(
                    conversation: selectedConversation,
                    input: AgentMessageInput(
                        text: content,
                        attachments: submittedAttachments,
                        visibleWorkspace: capturedWorkspace
                    ),
                    note: capturedNote
                )
                let currentDraft = draftsByConversationID[conversationID, default: ""]
                draftsByConversationID[conversationID] = accepted && currentDraft == content ? "" : currentDraft
                if accepted {
                    let submittedIDs = Set(submittedAttachments.map(\.id))
                    attachmentDraftsByConversation[conversationID, default: []]
                        .removeAll { submittedIDs.contains($0.id) }
                }
                submittingConversationIDs.remove(conversationID)
                if !accepted, chatPanels.activeConversationID == conversationID {
                    showNotice(
                        model.conversationError(for: conversationID)
                            ?? "The agent connection is unavailable. Your draft is preserved."
                    )
                }
            }
            return
        } else {
            showNotice("Choose a conversation before sending. Your draft is preserved.")
        }
    }

    private func handleAttachmentAction(
        from panelID: DashboardChatPanelID,
        _ action: DashboardComposerAttachmentAction
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
        to panelID: DashboardChatPanelID
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
                DashboardComposerNativeTextView.releaseTemporaryAttachments(urls)
            }
            do {
                let files = urls.map { url in
                    let type = UTType(filenameExtension: url.pathExtension)
                    return (url: url, mimeType: type?.preferredMIMEType ?? "application/octet-stream")
                }
                for attachment in try await model.stageMessageAttachments(files) {
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
        from panelID: DashboardChatPanelID
    ) {
        guard let conversationID = chatPanels.panel(id: panelID)?.conversationID else { return }
        attachmentDraftsByConversation[conversationID, default: []]
            .removeAll { $0.id == id }
    }

    private func conversation(
        in panelID: DashboardChatPanelID
    ) -> WorkspaceConversationRecord? {
        guard let conversationID = chatPanels.panel(id: panelID)?.conversationID else {
            return nil
        }
        return model.workspaceOverview?.conversations.first { $0.id == conversationID }
    }

}

enum DashboardDestination: String, Equatable {
    case workspace
    case calendar
    case cronJobs
    case library
    case databases
    case usage
    case settings
}

struct DashboardWorkspaceSurface: View {
    @Bindable var model: ApplicationModel
    let agents: [WorkspaceAgent]
    let conversations: [WorkspaceConversationRecord]
    let chatPanels: DashboardChatPanelState
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
    let onActivatePanel: (DashboardChatPanelID) -> Void
    let onAddPanel: (DashboardChatPanelID) -> Void
    let onClosePanel: (DashboardChatPanelID) -> Void
    let onNavigatePanel: (DashboardChatPanelDirection) -> Bool
    let onSend: (DashboardChatPanelID) -> Void
    let onAttachmentAction: (DashboardChatPanelID, DashboardComposerAttachmentAction) -> Void
    let onRemoveAttachment: (String, DashboardChatPanelID) -> Void
    let onDropFiles: ([URL], DashboardChatPanelID) -> Bool
    let onBotRoute: (DashboardBotTarget, DashboardChatPanelID) -> Void
    let onOpenBotLink: (URL, DashboardChatPanelID) -> Void
    let onOpenBotSettings: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let splitCompact = geometry.size.width < DashboardMetrics.splitBreakpoint
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
                                .frame(minWidth: DashboardMetrics.assetPaneMinimumWidth)
                            splitSeparator(totalWidth: geometry.size.width)
                            chatPanel(.primary, showNoteButton: false)
                                .frame(width: chatWidth(for: geometry.size.width))
                        } else {
                            chatPanel(.primary, showNoteButton: false)
                                .frame(width: chatWidth(for: geometry.size.width))
                            splitSeparator(totalWidth: geometry.size.width)
                            assetPane()
                                .frame(minWidth: DashboardMetrics.assetPaneMinimumWidth)
                        }
                    }
                    .coordinateSpace(name: "dashboard-workspace-split")
                }
            } else {
                DashboardChatPanelGrid(state: chatPanels) { panelID in
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

    private func conversationState(
        for conversation: WorkspaceConversationRecord?
    ) -> DashboardConversationState? {
        guard let conversation else { return nil }
        return model.conversationState(for: conversation.id)
    }

    private func assetPane(compact: Bool = false) -> some View {
        DashboardAssetPane(
            model: model, assets: assets, compact: compact, noteOnLeft: $noteOnLeft,
            focused: $noteFocusMode,
            reservesLeadingRailControlSpace: reservesLeadingRailControlSpace,
            reservesTrailingRailControlSpace: reservesTrailingRailControlSpace,
            newlyCreatedNoteID: newlyCreatedNoteID, onNewNoteFocusHandled: onNewNoteFocusHandled,
            onBack: { compactPane = .chat }
        )
    }

    private func splitSeparator(totalWidth: CGFloat) -> some View {
        DashboardSplitSeparator(
            totalWidth: totalWidth,
            noteOnLeft: noteOnLeft,
            chatWidthPercent: $chatWidthPercent
        )
    }

    private var workspaceContextLabel: String? {
        _ = assets.pageRevision
        var labels: [String] = []
        let count = assets.tabs.noteIDs.count
        if count > 0 { labels.append("\(count) open asset\(count == 1 ? "" : "s")") }
        let pageCount = assets.tabs.browserIDs.compactMap { assets.pages[$0] }
            .filter { $0.url.hasPrefix("https://") || $0.url.hasPrefix("http://") }.count
        if pageCount > 0 { labels.append("\(pageCount) browser URL\(pageCount == 1 ? "" : "s")") }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }

    /// Open notes and pages at send time, from the same snapshot regular chats use.
    /// A note reference is offered only while bots hold the Notes tool group.
    private func botContext(for panelID: DashboardChatPanelID) -> String? {
        guard panelID == .primary else { return nil }
        _ = assets.pageRevision
        let notes = model.workspaceOverview?.notes ?? []
        let snapshot = assets.snapshot(notes: notes) { $0.title }
        guard let context = snapshot?.promptContext else { return nil }
        return context.count <= 4_000 ? context : nil
    }

    @ViewBuilder private func chatPanel(
        _ panelID: DashboardChatPanelID,
        showNoteButton: Bool
    ) -> some View {
        if let target = chatPanels.panel(id: panelID)?.botTarget {
            botPanel(panelID, target: target, showNoteButton: showNoteButton)
        } else {
            conversationPanel(panelID, showNoteButton: showNoteButton)
        }
    }

    /// The reveal-rail and assets buttons float over the panels at the window's top edges.
    private func botHeaderInsets(for panelID: DashboardChatPanelID) -> BotHeaderInsets {
        let reachesLeadingEdge = panelID == .primary && !(assets.tabs.isPresented && noteOnLeft)
        let reachesTrailingEdge = panelID == .primary ? !chatPanels.hasAuxiliaryPanels && !(assets.tabs.isPresented && !noteOnLeft) : true
        return BotHeaderInsets(
            left: reachesLeadingEdge && reservesLeadingRailControlSpace ? 44 : 0,
            right: !reachesTrailingEdge ? 0 : (reservesTrailingRailControlSpace ? 88 : 44)
        )
    }

    private func botPanel(
        _ panelID: DashboardChatPanelID,
        target: DashboardBotTarget,
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
                onOpenConnections: { model.pendingConnectionsScope = "global" },
                onOpenProfiles: {
                    model.pendingBotProfilesMachine = target.machineID
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
            Label("Assets", systemImage: "rectangle.on.rectangle")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 32)
        }
        .buttonStyle(DashboardPillButtonStyle())
        .padding(.trailing, 52)
        .padding(.top, 12)
    }

    private func conversationPanel(
        _ panelID: DashboardChatPanelID,
        showNoteButton: Bool
    ) -> some View {
        let conversation = conversation(for: panelID)
        let conversationState = conversationState(for: conversation)
        let attachments = conversation.flatMap {
            attachmentDraftsByConversation[$0.id]
        } ?? []
        return ZStack(alignment: .topTrailing) {
            DashboardCloudConversation(
                model: model,
                agent: agent(for: conversation),
                conversation: conversation,
                messages: conversationState?.content?.messages ?? [],
                messageAttachments: conversationState?.content?.attachments ?? [],
                messageReferences: conversationState?.content?.references ?? [],
                messagePresentations: conversationState?.messagePresentations ?? [:],
                activeRuns: conversationState?.content?.runs ?? [],
                runActivities: conversationState?.runActivities ?? [],
                runPresentations: conversationState?.runPresentations ?? [:],
                attachedNoteTitle: panelID == .primary && assets.tabs.isPresented
                    ? workspaceContextLabel : nil,
                draft: draftBinding(for: panelID),
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
                onSend: { onSend(panelID) },
                onAttachmentAction: { onAttachmentAction(panelID, $0) },
                onRemoveAttachment: { onRemoveAttachment($0, panelID) },
                onDropFiles: { onDropFiles($0, panelID) },
                onCommandNavigation: handleComposerNavigation
            )
            if showNoteButton { compactAssetsButton }
        }
        .task(id: conversation?.id) {
            guard let conversation, model.libraryMessageTarget?.conversationID != conversation.id else { return }
            await model.refreshConversation(id: conversation.id)
        }
    }

    private func conversation(
        for panelID: DashboardChatPanelID
    ) -> WorkspaceConversationRecord? {
        guard let conversationID = chatPanels.panel(id: panelID)?.conversationID else {
            return nil
        }
        return conversations.first { $0.id == conversationID }
    }

    private func agent(
        for conversation: WorkspaceConversationRecord?
    ) -> WorkspaceAgent? {
        guard let agentID = conversation?.agentID else { return nil }
        return agents.first { $0.id.uuidString.lowercased() == agentID }
    }

    private func draftBinding(for panelID: DashboardChatPanelID) -> Binding<String> {
        let conversationID = chatPanels.panel(id: panelID)?.conversationID ?? ""
        return Binding(
            get: { draftsByConversationID[conversationID, default: ""] },
            set: { draftsByConversationID[conversationID] = $0 }
        )
    }

    private func handleNavigationKey(
        _ press: KeyPress,
        direction: DashboardChatPanelDirection
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
        _ direction: DashboardComposerNavigationDirection
    ) -> Bool {
        let panelDirection: DashboardChatPanelDirection = switch direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
        return onNavigatePanel(panelDirection)
    }

    private func chatWidth(for totalWidth: CGFloat) -> CGFloat {
        let contentWidth = max(1, totalWidth - DashboardMetrics.separatorWidth)
        let bounds = dashboardChatWidthBounds(totalWidth: totalWidth)
        let normalized = min(max(chatWidthPercent, bounds.lowerBound), bounds.upperBound)
        return contentWidth * CGFloat(normalized / 100)
    }
}

struct DashboardChatPanelGrid<Content: View>: View {
    @Environment(\.dashboardTheme) private var theme
    let state: DashboardChatPanelState
    @ViewBuilder let content: (DashboardChatPanelID) -> Content

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

    private func panelRow(_ row: [DashboardChatPanel]) -> some View {
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
            .frame(width: DashboardChatPanelMetrics.dividerThickness)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var horizontalDivider: some View {
        Rectangle()
            .fill(theme.palette.border)
            .frame(height: DashboardChatPanelMetrics.dividerThickness)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
