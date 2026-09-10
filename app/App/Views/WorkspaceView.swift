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

struct DashboardCreatedNotePresentation: Equatable {
    let selectedNoteID: String
    let titleFocusNoteID: String

    init(noteID: String) {
        selectedNoteID = noteID
        titleFocusNoteID = noteID
    }
}

struct DashboardSendResult: Equatable {
    let draft: String
    let accepted: Bool

    static func resolve(draft: String, accepted: Bool) -> DashboardSendResult {
        DashboardSendResult(draft: accepted ? "" : draft, accepted: accepted)
    }

    static func resolve(
        submittedDraft: String,
        currentDraft: String,
        accepted: Bool
    ) -> DashboardSendResult {
        DashboardSendResult(
            draft: accepted && currentDraft == submittedDraft ? "" : currentDraft,
            accepted: accepted
        )
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
    @State private var selectedNoteID: String?
    @State private var selectedFolderID: String?
    @State private var sidebarNavigation = DashboardSidebarNavigationState()
    @State private var destination = DashboardDestination.workspace
    @State private var compactDrawer = CompactDrawer.none
    @State private var compactWorkspacePane = CompactWorkspacePane.chat
    @State private var noteFocusMode = false
    @State private var draftsByConversationID: [String: String] = [:]
    @State private var attachmentDraftsByConversation: [String: [AgentMessageAttachmentDraft]] = [:]
    @State private var submittingConversationIDs: Set<String> = []
    @State private var showsAttachmentImporter = false
    @State private var attachmentPicker: DashboardAttachmentPickerKind?
    @State private var attachmentTargetPanelID: DashboardChatPanelID?
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
            + model.buzzWorkspaceAgents
    }

    private var selectedConversationID: String? {
        chatPanels.activeConversationID
    }

    private var sidebarAgents: [WorkspaceAgent] {
        model.visibleOrderedLocalCLIAgents
            + model.remoteWorkspaceAgents
            + model.buzzWorkspaceAgents
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
        GeometryReader { geometry in
            let layout = DashboardLayoutState.resolve(
                width: geometry.size.width,
                leftRailRequested: leftRailRequested,
                rightRailRequested: rightRailRequested,
                sidebarStyle: sidebarStyle,
                singleSidebarSide: singleSidebarSide,
                singleRailRequested: singleRailRequested
            )

            ZStack(alignment: .trailing) {
                Group {
                    if layout.compact {
                        compactShell(width: geometry.size.width)
                    } else {
                        desktopShell(layout: layout)
                    }
                }
                .background(theme.palette.workspace)

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
                        onClose: closeNewChatChooser,
                        onOpenSettings: {
                            closeNewChatChooser()
                            openUtility(.settings)
                        },
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
        .preferredColorScheme(.light)
        .tint(DashboardPalette.primary)
        .foregroundStyle(DashboardPalette.foreground)
        .onAppear {
            selectDefaults()
        }
        .onChange(of: allAgents.map(\.id)) { _, _ in selectDefaults() }
        .onChange(of: model.workspaceOverview?.conversations.map(\.id) ?? []) { _, ids in
            selectDefaults()
        }
        .onChange(of: selectedConversationID) { _, conversationID in
            if let conversationID {
                model.markConversationRead(id: conversationID)
            }
        }
        .onChange(of: selectedNoteID) { _, noteID in
            if noteID == nil {
                chatPanels.dismissAsset()
            } else {
                chatPanels.presentAsset()
                synchronizeSelectionToActivePanel()
            }
        }
        .onChange(of: sidebarStyleRawValue) { _, _ in
            compactDrawer = .none
        }
        .onChange(of: singleSidebarSideRawValue) { oldValue, newValue in
            guard sidebarStyle != .split,
                  let oldSide = DashboardSidebarSide(rawValue: oldValue),
                  let newSide = DashboardSidebarSide(rawValue: newValue),
                  compactDrawer == oldSide.compactDrawer else { return }
            compactDrawer = newSide.compactDrawer
        }
        .onChange(of: surfacePreferenceSignature) { _, _ in
            model.persistMacSurfaceProfileFromUserDefaults()
        }
        .onDisappear { noticeTask?.cancel() }
        .fileImporter(
            isPresented: $showsAttachmentImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                if let panelID = attachmentTargetPanelID {
                    _ = attachFiles(urls, to: panelID)
                }
                attachmentTargetPanelID = nil
            case .failure(let error):
                attachmentTargetPanelID = nil
                showNotice(error.localizedDescription)
            }
        }
        .sheet(item: $attachmentPicker) { kind in
            DashboardAttachmentPicker(
                kind: kind,
                notes: model.workspaceOverview?.notes ?? [],
                conversations: (model.workspaceOverview?.conversations ?? []).filter {
                    $0.id != attachmentTargetPanelID.flatMap {
                        chatPanels.panel(id: $0)?.conversationID
                    }
                },
                onSelectNote: { note in
                    if let panelID = attachmentTargetPanelID {
                        appendAttachment(model.noteAttachmentDraft(note), to: panelID)
                    }
                    attachmentPicker = nil
                    attachmentTargetPanelID = nil
                },
                onSelectConversation: { conversation in
                    attachmentPicker = nil
                    Task { @MainActor in
                        do {
                            if let panelID = attachmentTargetPanelID {
                                appendAttachment(
                                    try await model.conversationAttachmentDraft(conversation),
                                    to: panelID
                                )
                            }
                        } catch {
                            showNotice(error.localizedDescription)
                        }
                        attachmentTargetPanelID = nil
                    }
                }
            )
        }
        .confirmationDialog(
            "Connect the OpenClaw Gateway?",
            isPresented: Binding(
                get: { model.pendingOpenClawGatewayAgentID != nil },
                set: { if !$0 { model.dismissPendingOpenClawGatewayLink() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Connect Gateway") {
                model.confirmPendingOpenClawGatewayLink()
            }
            Button("Use ACP for now", role: .cancel) {
                model.dismissPendingOpenClawGatewayLink()
            }
        } message: {
            Text("ACP is ready. Connect this remote OpenClaw Gateway for durable sessions, events, models, attachments, cron, and heartbeat features.")
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
                railGroup(side: .left)
            }

            centerSurface(
                showLeftRailButton: showLeftRailButton,
                showRightRailButton: showRightRailButton,
                onLeftRail: { revealRail(side: .left) },
                onRightRail: { revealRail(side: .right) }
            )
            .frame(minWidth: DashboardMetrics.workspaceMinimumWidth)

            if layout.showsRightRail {
                railGroup(side: .right)
            }
        }
        .padding(.horizontal, DashboardMetrics.shellInset)
        .padding(.bottom, DashboardMetrics.shellInset)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: layout)
    }

    private func compactShell(width: CGFloat) -> some View {
        let drawerWidth = min(width * 0.82, 320)
        let showLeftRailButton = sidebarStyle == .split || singleSidebarSide == .left
        let showRightRailButton = sidebarStyle == .split || singleSidebarSide == .right
        let drawerPageCount = sidebarNavigation.pages(
            for: singleSidebarSide,
            style: sidebarStyle
        ).count
        let drawerTotalWidth = drawerWidth * CGFloat(drawerPageCount)
        let workspaceOffset: CGFloat = switch compactDrawer {
        case .none: 0
        case .left: drawerTotalWidth
        case .right: -drawerTotalWidth
        }

        return ZStack(alignment: compactDrawer == .right ? .trailing : .leading) {
            centerSurface(
                showLeftRailButton: showLeftRailButton,
                showRightRailButton: showRightRailButton,
                onLeftRail: { toggleCompactRail(side: .left) },
                onRightRail: { toggleCompactRail(side: .right) }
            )
            .offset(x: workspaceOffset)
            .opacity(compactDrawer == .none ? 1 : 0.58)
            .clipShape(compactWorkspaceShape)
            .shadow(
                color: compactDrawer == .none ? .clear : DashboardPalette.foreground.opacity(0.12),
                radius: 22,
                x: compactDrawer == .left ? -18 : 18
            )
            .onTapGesture {
                if compactDrawer != .none { compactDrawer = .none }
            }

            if compactDrawer == .left {
                railGroup(side: .left, railWidth: drawerWidth, compact: true)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else if compactDrawer == .right {
                railGroup(side: .right, railWidth: drawerWidth, compact: true)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: compactDrawer)
    }

    private var compactWorkspaceShape: UnevenRoundedRectangle {
        switch compactDrawer {
        case .left:
            UnevenRoundedRectangle(
                topLeadingRadius: 28,
                bottomLeadingRadius: 28,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        case .right:
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 28,
                topTrailingRadius: 28,
                style: .continuous
            )
        case .none:
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        }
    }

    @ViewBuilder
    private func railGroup(
        side: DashboardSidebarSide,
        railWidth: CGFloat = DashboardMetrics.railWidth,
        compact: Bool = false
    ) -> some View {
        let pages = sidebarNavigation.pages(for: side, style: sidebarStyle)
        let usesUnifiedSurface = sidebarStyle == .adaptive && pages.count == 2

        let content = HStack(spacing: usesUnifiedSurface ? 0 : DashboardMetrics.shellGap) {
            ForEach(pages, id: \.self) { page in
                rail(side: side, page: page, adaptiveExpanded: usesUnifiedSurface)
                    .frame(width: railWidth)
                    .background {
                        if !usesUnifiedSurface {
                            railBackground(compact: compact)
                        }
                }
            }
        }

        if usesUnifiedSurface {
            content
                .background {
                    railBackground(compact: compact)
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

    @ViewBuilder
    private func railBackground(compact: Bool) -> some View {
        if compact {
            DashboardShapes.windowAlignedSurface
                .fill(theme.palette.railFill)
        } else {
            DashboardRailBackground()
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
            buzzWorkspaceSnapshot: model.buzzWorkspaceSnapshot,
            folders: model.workspaceOverview?.folders ?? [],
            conversations: model.workspaceOverview?.conversations ?? [],
            notes: model.workspaceOverview?.notes ?? [],
            runningConversationIDs: model.localRunningConversationIDs,
            selectedAgentID: selectedAgentID,
            selectedFolderID: selectedFolderID,
            selectedConversationID: selectedConversationID,
            selectedNoteID: selectedNoteID,
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
                onMoveConversation: moveConversation,
                onUnavailableMutation: showUnavailableMutation
            ),
            onSurfaceProfileChange: {
                model.persistMacSurfaceProfileFromUserDefaults()
            }
        )
    }

    private func collapseRail(side: DashboardSidebarSide) {
        if compactDrawer == side.compactDrawer {
            compactDrawer = .none
        } else if sidebarStyle != .split {
            singleRailRequested = false
        } else if side == .left {
            leftRailRequested = false
        } else {
            rightRailRequested = false
        }
    }

    private func revealRail(side: DashboardSidebarSide) {
        if sidebarStyle != .split {
            singleRailRequested = true
        } else if side == .left {
            leftRailRequested = true
        } else {
            rightRailRequested = true
        }
    }

    private func toggleCompactRail(side: DashboardSidebarSide) {
        singleRailRequested = true
        compactDrawer = compactDrawer == side.compactDrawer ? .none : side.compactDrawer
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
        ZStack(alignment: .top) {
            Group {
                switch destination {
                case .workspace:
                    DashboardWorkspaceSurface(
                        model: model,
                        agents: allAgents,
                        conversations: model.workspaceOverview?.conversations ?? [],
                        chatPanels: chatPanels,
                        note: selectedNote,
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
                        onCloseNote: {
                            selectedNoteID = nil
                            compactWorkspacePane = .chat
                            noteFocusMode = false
                        },
                        onActivatePanel: activatePanel,
                        onAddPanel: addPanel,
                        onClosePanel: closePanel,
                        onNavigatePanel: navigatePanel,
                        onSend: send,
                        onAttachmentAction: handleAttachmentAction,
                        onRemoveAttachment: removeAttachment,
                        onDropFiles: attachFiles,
                        onUnavailableComposerAction: showUnavailableMutation
                    )
                case .calendar:
                    DashboardCalendarSurface(model: model)
                case .cronJobs:
                    OpenClawCronSurface(
                        model: model,
                        onOpenConversation: { conversationID in
                            destination = .workspace
                            selectConversation(conversationID)
                        }
                    )
                case .library:
                    DashboardUnavailableUtility(
                        icon: .libraryBigControl,
                        title: "Library",
                        detail: "Attachments are not shown in this view yet."
                    )
                case .databases:
                    DashboardDatabasesView(model: model)
                case .usage:
                    DashboardUsageView(model: model)
                case .settings:
                    SettingsView(
                        model: model,
                        reservesRailControlSpace: showLeftRailButton || showRightRailButton
                    )
                }
            }

            HStack {
                if showLeftRailButton {
                    DashboardRevealRailButton(side: .left, action: onLeftRail)
                }
                Spacer()
                if showRightRailButton {
                    DashboardRevealRailButton(side: .right, action: onRightRail)
                }
            }
            .padding(12)

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
            guard !conversation.isArchived else { return false }
            return conversation.agentID == agent.id.uuidString.lowercased()
        }
    }

    private func selectDefaults() {
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
        selectConversationForCurrentAgent()
        destination = .workspace
        compactWorkspacePane = .chat
        compactDrawer = .none
    }

    private func selectFolder(_ id: String?) {
        selectedFolderID = id
        sidebarNavigation.selectFolder()
        destination = .workspace
        if sidebarStyle == .split {
            compactDrawer = .none
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
        compactDrawer = .none
    }

    private func selectNote(_ id: String) {
        chatPanels.presentAsset()
        selectedNoteID = id
        destination = .workspace
        compactWorkspacePane = .note
        compactDrawer = .none
    }

    private func createNote(kind: NoteArtifactKind = .note) {
        model.clearNoteMutationError()
        Task {
            guard let noteID = await model.createNote(
                folderID: selectedFolderID,
                kind: kind
            ) else {
                showNotice(model.noteMutationError ?? "The note could not be created.")
                return
            }
            let presentation = DashboardCreatedNotePresentation(noteID: noteID)
            newlyCreatedNoteID = presentation.titleFocusNoteID
            selectNote(presentation.selectedNoteID)
        }
    }

    private func createFolder(name: String) {
        model.clearFolderMutationError()
        Task {
            guard let folderID = await model.createFolder(name: name) else {
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

    private func deleteFolder(id: String) {
        model.clearFolderMutationError()
        Task {
            guard await model.deleteFolder(id: id) else {
                showNotice(model.folderMutationError ?? "The folder could not be moved to Trash.")
                return
            }
            if selectedFolderID == id {
                selectFolder(nil)
            }
        }
    }

    private func moveConversation(id: String, toFolderID folderID: String?) {
        model.clearFolderMutationError()
        Task {
            guard await model.moveConversation(id: id, toFolderID: folderID) else {
                showNotice(model.folderMutationError ?? "The chat could not be moved.")
                return
            }
        }
    }

    private func createConversation() {
        showsNewNoteChooser = false
        showsNewChatChooser = true
        compactDrawer = .none
    }

    private func startNewChat(_ target: DashboardNewChatTarget) {
        switch target {
        case .acpDirect(let runtimeKind):
            startDirectChat(runtimeKind)
        case .remoteWorkspace(let target):
            startRemoteChat(target)
        case .buzzWorkspace(let enrollment):
            startBuzzWorkspaceChat(enrollment)
        }
    }

    private func startDirectChat(_ runtimeKind: AgentRuntimeKind) {
        Task {
            guard let conversationID = await model.createLocalACPSession(
                runtimeKind: runtimeKind
            ) else {
                showNotice(
                    model.localRunError
                        ?? "The local CLI chat could not be created."
                )
                return
            }
            closeNewChatChooser()
            selectConversation(conversationID)
        }
    }

    private func startRemoteChat(_ target: RemoteHarnessChatTarget) {
        Task {
            guard let conversationID = await model.createRemoteACPSession(
                target: target
            ) else {
                showNotice(
                    model.localRunError
                        ?? "The remote workspace chat could not be created."
                )
                return
            }
            closeNewChatChooser()
            selectConversation(conversationID)
        }
    }

    private func startBuzzWorkspaceChat(
        _ enrollment: BuzzWorkspaceAgentEnrollment
    ) {
        Task {
            guard let conversationID = await model
                .createBuzzWorkspaceLocalACPSession(enrollment: enrollment) else {
                showNotice(
                    model.localRunError
                        ?? "The linked Buzz agent chat could not be created."
                )
                return
            }
            closeNewChatChooser()
            selectConversation(conversationID)
        }
    }

    private func closeNewChatChooser() {
        showsNewChatChooser = false
    }

    private func openNewNoteChooser() {
        showsNewChatChooser = false
        showsNewNoteChooser = true
        compactDrawer = .none
    }

    private func closeNewNoteChooser() {
        showsNewNoteChooser = false
    }

    private func openUtility(_ next: DashboardDestination) {
        destination = next
        compactDrawer = .none
    }

    private func showUnavailableMutation(_ label: String) {
        showNotice("\(label) is not available yet.")
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        withAnimation(.easeOut(duration: 0.2)) { compactDrawer = .none }
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
        if selectedNoteID != nil {
            selectedNoteID = nil
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
            Task { @MainActor in
                let accepted = await model.sendAgentMessage(
                    conversation: selectedConversation,
                    input: AgentMessageInput(
                        text: content,
                        attachments: submittedAttachments
                    ),
                    note: panelID == .primary ? selectedNote : nil
                )
                let result = DashboardSendResult.resolve(
                        submittedDraft: content,
                        currentDraft: draftsByConversationID[conversationID, default: ""],
                        accepted: accepted
                    )
                draftsByConversationID[conversationID] = result.draft
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
        attachmentTargetPanelID = panelID
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
        guard chatPanels.panel(id: panelID)?.conversationID != nil else { return false }
        Task { @MainActor in
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            do {
                let files = urls.map { url in
                    let type = UTType(filenameExtension: url.pathExtension)
                    return (url: url, mimeType: type?.preferredMIMEType ?? "application/octet-stream")
                }
                for attachment in try await model.stageMessageAttachments(files) {
                    appendAttachment(attachment, to: panelID)
                }
            } catch {
                showNotice(error.localizedDescription)
            }
        }
        return true
    }

    private func appendAttachment(
        _ attachment: AgentMessageAttachmentDraft,
        to panelID: DashboardChatPanelID
    ) {
        guard let conversationID = chatPanels.panel(id: panelID)?.conversationID else { return }
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
    let note: WorkspaceNoteRecord?
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
    let onCloseNote: () -> Void
    let onActivatePanel: (DashboardChatPanelID) -> Void
    let onAddPanel: (DashboardChatPanelID) -> Void
    let onClosePanel: (DashboardChatPanelID) -> Void
    let onNavigatePanel: (DashboardChatPanelDirection) -> Bool
    let onSend: (DashboardChatPanelID) -> Void
    let onAttachmentAction: (DashboardChatPanelID, DashboardComposerAttachmentAction) -> Void
    let onRemoveAttachment: (String, DashboardChatPanelID) -> Void
    let onDropFiles: ([URL], DashboardChatPanelID) -> Bool
    let onUnavailableComposerAction: (String) -> Void

    var body: some View {
        GeometryReader { geometry in
            let splitCompact = geometry.size.width < DashboardMetrics.splitBreakpoint
            if let note {
                if splitCompact {
                    if compactPane == .note {
                        DashboardNotePane(
                            model: model,
                            note: note,
                            showBack: true,
                            noteOnLeft: noteOnLeft,
                            isFocused: true,
                            reservesLeadingRailControlSpace: reservesLeadingRailControlSpace,
                            reservesTrailingRailControlSpace: reservesTrailingRailControlSpace,
                            focusesTitleOnAppear: note.id == newlyCreatedNoteID,
                            onInitialFocusHandled: { onNewNoteFocusHandled(note.id) },
                            onBack: { compactPane = .chat },
                            onMove: { noteOnLeft.toggle() },
                            onToggleFocus: {},
                            onClose: onCloseNote
                        )
                        .id(note.id)
                    } else {
                        chatPanel(.primary, showNoteButton: true)
                    }
                } else if noteFocusMode {
                    notePane(note)
                } else {
                    HStack(spacing: 0) {
                        if noteOnLeft {
                            notePane(note)
                                .frame(minWidth: DashboardMetrics.companionMinimumWidth)
                            splitSeparator(totalWidth: geometry.size.width)
                            chatPanel(.primary, showNoteButton: false)
                                .frame(width: chatWidth(for: geometry.size.width))
                        } else {
                            chatPanel(.primary, showNoteButton: false)
                                .frame(width: chatWidth(for: geometry.size.width))
                            splitSeparator(totalWidth: geometry.size.width)
                            notePane(note)
                                .frame(minWidth: DashboardMetrics.companionMinimumWidth)
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

    private func notePane(_ note: WorkspaceNoteRecord) -> some View {
        DashboardNotePane(
            model: model,
            note: note,
            showBack: false,
            noteOnLeft: noteOnLeft,
            isFocused: noteFocusMode,
            reservesLeadingRailControlSpace: reservesLeadingRailControlSpace,
            reservesTrailingRailControlSpace: reservesTrailingRailControlSpace,
            focusesTitleOnAppear: note.id == newlyCreatedNoteID,
            onInitialFocusHandled: { onNewNoteFocusHandled(note.id) },
            onBack: {},
            onMove: { noteOnLeft.toggle() },
            onToggleFocus: { noteFocusMode.toggle() },
            onClose: onCloseNote
        )
        .id(note.id)
    }

    private func splitSeparator(totalWidth: CGFloat) -> some View {
        DashboardSplitSeparator(
            totalWidth: totalWidth,
            noteOnLeft: noteOnLeft,
            chatWidthPercent: $chatWidthPercent
        )
    }

    private func chatPanel(
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
                attachedNoteTitle: panelID == .primary && model.canAgentEditOpenNote(conversation)
                    ? note.map { model.noteDraft(for: $0).title }
                    : nil,
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
                onCommandNavigation: handleComposerNavigation,
                onUnavailableComposerAction: onUnavailableComposerAction
            )
            if showNoteButton {
                Button {
                    compactPane = .note
                } label: {
                    Label("Note", systemImage: "doc.text")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                }
                .buttonStyle(DashboardPillButtonStyle())
                .padding(12)
            }
        }
        .task(id: conversation?.id) {
            guard let conversation else { return }
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
