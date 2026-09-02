import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WovenMatterClient
import WovenMatterCore

private final class DashboardAttributedStringBox: @unchecked Sendable {
    let value: AttributedString

    init(_ value: AttributedString) {
        self.value = value
    }
}

private final class DashboardTextPresentationCache: @unchecked Sendable {
    static let shared = DashboardTextPresentationCache()

    private let richText = NSCache<NSString, DashboardAttributedStringBox>()

    private init() {
        richText.countLimit = 256
        richText.totalCostLimit = 16 * 1_024 * 1_024
    }

    @MainActor
    func richText(for content: String) -> AttributedString {
        if let cached = richText.object(forKey: content as NSString)?.value {
            return cached
        }
        let rendered = dashboardAttributedContent(content)
        richText.setObject(
            DashboardAttributedStringBox(rendered),
            forKey: content as NSString,
            cost: content.utf8.count
        )
        return rendered
    }
}

private final class DashboardScrollHoverCoordinator: @unchecked Sendable {
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

private struct DashboardScrollHoverCoordinatorEnvironmentKey: EnvironmentKey {
    static let defaultValue = DashboardScrollHoverCoordinator()
}

private extension EnvironmentValues {
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

    private var sidebarAgents: [WorkspaceAgent] {
        model.visibleOrderedLocalCLIAgents
            + model.remoteWorkspaceAgents
            + model.buzzWorkspaceAgents
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
        .onChange(of: selectedAgentID) { _, _ in
            selectConversationForCurrentAgent()
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
            selectedAgentCodenames: selectedAgent.map {
                [$0.codename, $0.platformCodename].compactMap { $0 }
            } ?? [],
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
            with: conversationsForSelectedAgent.first(where: \.isMain)?.id
                ?? conversationsForSelectedAgent.first?.id
        )
    }

    private func selectAgent(_ id: UUID) {
        selectedAgentID = id
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
        model.clearNewChatError()
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
        model.clearNewChatError()
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
        guard chatPanels.activatePanel(panelID) else { return }
        synchronizeSelectionToActivePanel()
    }

    private func addPanel(from panelID: DashboardChatPanelID) {
        let newPanelID = DashboardChatPanelID(rawValue: UUID().uuidString.lowercased())
        guard chatPanels.addPanel(
            from: panelID,
            newPanelID: newPanelID
        ) else { return }
        if selectedNoteID != nil {
            selectedNoteID = nil
            compactWorkspacePane = .chat
            noteFocusMode = false
        }
        synchronizeSelectionToActivePanel()
        // A button participates in the panel's simultaneous click gesture.
        // Reassert the newly created panel after that gesture has completed.
        Task { @MainActor in
            await Task.yield()
            guard chatPanels.panel(id: newPanelID) != nil else { return }
            _ = chatPanels.activatePanel(newPanelID)
            synchronizeSelectionToActivePanel()
        }
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

private enum WorkspaceListMode: String, CaseIterable {
    case chats
    case notes
}

private enum CompactDrawer: Equatable {
    case none
    case left
    case right
}

private extension DashboardSidebarSide {
    var compactDrawer: CompactDrawer {
        switch self {
        case .left: .left
        case .right: .right
        }
    }
}

private enum CompactWorkspacePane: Equatable {
    case chat
    case note
}

private enum DashboardAgentMoveScope {
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

private struct DashboardSidebarActions {
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

private struct DashboardSidebarRail: View {
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
    let selectedAgentCodenames: [String]
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
            selectedAgentCodenames: selectedAgentCodenames,
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

private struct DashboardSidebarNavigationPage: View {
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

        for conversation in conversations where !conversation.isArchived && !conversation.isMain {
            insert(.conversation(conversation))
        }
        for note in notes {
            insert(.note(note))
        }
        return items
    }
}

private enum DashboardRecentItem: Identifiable {
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

private enum DashboardNewChatTarget {
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

private struct DashboardNewChatDrawer: View {
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

private struct DashboardNewNoteDrawer: View {
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

private struct DashboardNewChatSection<Content: View>: View {
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

private struct DashboardNewChatOptionCard: View {
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

private struct DashboardNewChatEmptyCard: View {
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

private struct DashboardSidebarWorkspacePage: View {
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
    let selectedAgentCodenames: [String]
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

private struct DashboardRightRailContentTaskID: Hashable {
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

private final class DashboardConversationRowPresentationBox: NSObject {
    let value: DashboardConversationRowPresentation

    init(_ value: DashboardConversationRowPresentation) {
        self.value = value
    }
}

private final class DashboardNoteRowPresentationBox: NSObject {
    let value: DashboardNoteRowPresentation

    init(_ value: DashboardNoteRowPresentation) {
        self.value = value
    }
}

private final class DashboardListPresentationCache: @unchecked Sendable {
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

private enum DashboardListTimeContext {
    static var current: String {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date()).timeIntervalSinceReferenceDate
        return "\(day):\(calendar.timeZone.identifier):\(Locale.current.identifier)"
    }
}

private struct DashboardWorkspaceSurface: View {
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
                usesCompactPanelSpacing: chatPanels.hasAuxiliaryPanels,
                showsClosePanel: chatPanels.canClosePanel(panelID),
                showsAddPanel: chatPanels.canAddPanel(from: panelID),
                focusRequestGeneration: chatPanels.focusRequest?.panelID == panelID
                    ? chatPanels.focusRequest?.generation
                    : nil,
                onClosePanel: { onClosePanel(panelID) },
                onAddPanel: { onAddPanel(panelID) },
                onSend: { onSend(panelID) },
                onAttachmentAction: { onAttachmentAction(panelID, $0) },
                onRemoveAttachment: { onRemoveAttachment($0, panelID) },
                onDropFiles: { onDropFiles($0, panelID) },
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
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            onActivatePanel(panelID)
        })
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

    private func chatWidth(for totalWidth: CGFloat) -> CGFloat {
        let contentWidth = max(1, totalWidth - DashboardMetrics.separatorWidth)
        let bounds = dashboardChatWidthBounds(totalWidth: totalWidth)
        let normalized = min(max(chatWidthPercent, bounds.lowerBound), bounds.upperBound)
        return contentWidth * CGFloat(normalized / 100)
    }
}

private struct DashboardChatPanelGrid<Content: View>: View {
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

enum DashboardConversationScrollAction: Equatable {
    case none
    case jumpToBottom
    case followBottom
}

private struct DashboardConversationGeometry: Equatable {
    let contentHeight: CGFloat
    let isNearBottom: Bool
}

struct DashboardConversationScrollState: Equatable {
    private(set) var positionedConversationID: String?
    private(set) var isNearBottom = true

    mutating func conversationChanged(to conversationID: String?) {
        guard positionedConversationID != conversationID else { return }
        positionedConversationID = nil
        isNearBottom = true
    }

    mutating func contentChanged(
        conversationID: String?,
        hasMessages: Bool,
        isPrependingHistory: Bool
    ) -> DashboardConversationScrollAction {
        guard let conversationID, hasMessages else { return .none }
        if positionedConversationID != conversationID {
            positionedConversationID = conversationID
            isNearBottom = true
            return .jumpToBottom
        }
        guard !isPrependingHistory, isNearBottom else { return .none }
        return .followBottom
    }

    mutating func setNearBottom(_ isNearBottom: Bool) {
        self.isNearBottom = isNearBottom
    }
}

private struct DashboardCloudConversation: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    let agent: WorkspaceAgent?
    let conversation: WorkspaceConversationRecord?
    let messages: [WorkspaceMessageRecord]
    let messageAttachments: [WorkspaceMessageAttachmentRecord]
    let messageReferences: [WorkspaceMessageReferenceRecord]
    let messagePresentations: [String: DashboardMessagePresentation]
    let activeRuns: [WorkspaceRunRecord]
    let runActivities: [WorkspaceRunActivityRecord]
    let runPresentations: [String: DashboardRunPresentation]
    let attachedNoteTitle: String?
    @Binding var draft: String
    let attachments: [AgentMessageAttachmentDraft]
    let sendInProgress: Bool
    let usesCompactPanelSpacing: Bool
    let showsClosePanel: Bool
    let showsAddPanel: Bool
    let focusRequestGeneration: Int?
    let onClosePanel: () -> Void
    let onAddPanel: () -> Void
    let onSend: () -> Void
    let onAttachmentAction: (DashboardComposerAttachmentAction) -> Void
    let onRemoveAttachment: (String) -> Void
    let onDropFiles: ([URL]) -> Bool
    let onUnavailableComposerAction: (String) -> Void
    @State private var scrollState = DashboardConversationScrollState()
    @State private var isPrependingHistory = false
    @State private var pendingBottomConversationID: String?
    @State private var bottomPositionRevision = 0
    @State private var scrollPositionID: String?
    @State private var bottomStackHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 32) {
                        if conversation == nil {
                            DashboardConversationEmptyState(
                                icon: .messageSquare,
                                title: agent.map { "New conversation with \(dashboardAgentDisplayName($0))" } ?? "Choose a conversation",
                                detail: agent == nil
                                    ? "Choose New chat for a direct local workspace session, or select a synced conversation."
                                    : "Choose a synced conversation from Workspace."
                            )
                        } else if visibleMessages.isEmpty {
                            DashboardConversationEmptyState(
                                icon: conversation?.localRuntimeKind == nil
                                    ? (agent.map { dashboardAgentGlyph($0) }
                                        ?? .messageSquare)
                                    : .terminal,
                                title: conversation?.title ?? "Conversation",
                                detail: conversation?.localRuntimeKind == nil
                                    ? "This conversation has no messages yet."
                                    : "This direct chat is ready in the shared ~/.woven-matter workspace."
                            )
                        } else {
                            if scrollState.positionedConversationID == conversation?.id,
                               conversationState?.hasOlderMessages == true,
                               let oldestMessageID = messages.first?.id {
                                Color.clear
                                    .frame(height: 1)
                                    .id(historyLoaderID(oldestMessageID: oldestMessageID))
                                    .accessibilityIdentifier("dashboard-history-loader")
                                    .task(id: historyLoaderID(oldestMessageID: oldestMessageID)) {
                                        await prependOlderMessages(
                                            keeping: oldestMessageID,
                                            using: proxy
                                        )
                                    }
                            }
                            ForEach(visibleMessages) { message in
                                let presentation = messagePresentations[message.id]
                                let run = runsByAssistantMessageID[message.id]
                                DashboardMessageRow(
                                    message: message,
                                    attachments: messageAttachments.filter { $0.messageID == message.id },
                                    references: messageReferences.filter { $0.messageID == message.id },
                                    renderedDocument: presentation?.document,
                                    run: run.flatMap {
                                        DashboardRunDisplayPolicy.presentsStatus($0) ? $0 : nil
                                    },
                                    runPresentation: run.flatMap { runPresentations[$0.id] },
                                    activities: run.map { activitiesByRunID[$0.id] ?? [] } ?? []
                                )
                                .id(message.id)
                            }
                        }
                        Color.clear
                            .frame(height: bottomScrollClearance)
                            .id(chatEndID)
                    }
                    .frame(maxWidth: 768)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .scrollTargetLayout()
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.bottom)
                .scrollPosition(id: $scrollPositionID, anchor: .bottom)
                .onScrollGeometryChange(for: DashboardConversationGeometry.self) { geometry in
                    DashboardConversationGeometry(
                        contentHeight: geometry.contentSize.height,
                        isNearBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 80
                    )
                } action: { oldGeometry, newGeometry in
                    let followedBottomBeforeGrowth = oldGeometry.contentHeight != newGeometry.contentHeight
                        && scrollState.isNearBottom
                    let isPositioningConversation = pendingBottomConversationID == conversation?.id
                        && newestPresentedMessageIdentity != nil
                    scrollState.setNearBottom(newGeometry.isNearBottom)

                    if isPositioningConversation {
                        bottomPositionRevision += 1
                        let revision = bottomPositionRevision
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(50))
                            guard revision == bottomPositionRevision,
                                  pendingBottomConversationID == conversation?.id else { return }
                            scrollToConversationBottom(using: proxy)
                            pendingBottomConversationID = nil
                        }
                    } else if followedBottomBeforeGrowth {
                        Task { @MainActor in
                            await Task.yield()
                            scrollToConversationBottom(using: proxy)
                        }
                    }
                }
                .onChange(of: conversation?.id, initial: true) { _, conversationID in
                    scrollState.conversationChanged(to: conversationID)
                    pendingBottomConversationID = conversationID
                    bottomPositionRevision += 1
                    scrollPositionID = nil
                }
                .onChange(of: newestPresentedMessageIdentity, initial: true) { _, identity in
                    guard identity != nil else { return }
                    let action = scrollState.contentChanged(
                        conversationID: conversation?.id,
                        hasMessages: !visibleMessages.isEmpty,
                        isPrependingHistory: isPrependingHistory
                    )
                    switch action {
                    case .none:
                        break
                    case .jumpToBottom, .followBottom:
                        Task { @MainActor in
                            await Task.yield()
                            try? await Task.sleep(for: .milliseconds(50))
                            guard identity == newestPresentedMessageIdentity else { return }
                            scrollToConversationBottom(using: proxy)
                        }
                    }
                }
            }

            VStack(spacing: 8) {
                if let error = model.workspaceError
                    ?? conversationState?.error {
                    DashboardInlineError(text: error)
                        .frame(maxWidth: 768)
                }
                if let permission = localPermission {
                    DashboardLocalPermissionCard(
                        permission: permission,
                        onSelect: { optionID in
                            model.resolveLocalACPPermission(
                                id: permission.id,
                                optionID: optionID
                            )
                        },
                        onCancel: {
                            model.resolveLocalACPPermission(
                                id: permission.id,
                                optionID: nil
                            )
                        }
                    )
                }
                if let interaction = localInteraction {
                    DashboardLocalInteractionCard(
                        interaction: interaction,
                        onResolve: { response in
                            model.resolveLocalACPInteraction(
                                id: interaction.id,
                                response: response
                            )
                        }
                    )
                    .id(interaction.id)
                }
                if let conversation,
                   model.localRunningConversationIDs.contains(conversation.id) {
                    HStack(spacing: 9) {
                        Image(systemName: "bolt")
                            .foregroundStyle(DashboardPalette.primary)
                        Text("Agent is working")
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Button("Stop") {
                            if model.isOpenClawGatewayConversation(
                                conversation.id
                            ) {
                                model.cancelOpenClawGatewayPrompt(
                                    conversationID: conversation.id
                                )
                            } else {
                                model.cancelLocalACPPrompt(
                                    conversationID: conversation.id
                                )
                            }
                        }
                        .buttonStyle(DashboardQuietButtonStyle())
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: 768, minHeight: 38)
                    .background(theme.palette.themeWhisper)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                HStack(alignment: .bottom, spacing: 8) {
                    if showsClosePanel {
                        DashboardPanelControlButton(
                            systemImage: "minus",
                            accessibilityLabel: "Close Panel",
                            help: "Close this chat panel",
                            action: onClosePanel
                        )
                    }
                    DashboardComposer(
                        placeholder: dashboardComposerPlaceholder(
                            agent: agent,
                            runtimeKind: conversation?.localRuntimeKind
                        ),
                        draft: $draft,
                        attachedNoteTitle: attachedNoteTitle,
                        attachments: attachments,
                        showsSessionControls: conversation.map {
                            model.isOpenClawGatewayConversation($0.id)
                                || $0.localRuntimeKind != nil
                        } ?? false,
                        sessionMetadata: conversation.flatMap {
                            if model.isOpenClawGatewayConversation($0.id) {
                                return model.openClawGatewaySessionMetadata[$0.id]
                            }
                            return model.localACPSessionMetadata[$0.id]
                        },
                        sessionControlsDisabled: conversation.map {
                            if model.isOpenClawGatewayConversation($0.id) {
                                return model.localRunningConversationIDs.contains($0.id)
                            }
                            if $0.localRuntimeKind != nil {
                                return model.loadingLocalACPSessionIDs.contains($0.id)
                                    || model.updatingLocalACPSessionIDs.contains($0.id)
                                    || model.localRunningConversationIDs.contains($0.id)
                            }
                            return true
                        } ?? true,
                        sendDisabled: sendInProgress || (conversation.map {
                            guard $0.localRuntimeKind != nil else { return true }
                            return model.loadingLocalACPSessionIDs.contains($0.id)
                                || model.updatingLocalACPSessionIDs.contains($0.id)
                        } ?? false),
                        focusRequestGeneration: focusRequestGeneration,
                        onSelectModel: { selection in
                            guard let conversation else { return }
                            if model.isOpenClawGatewayConversation(conversation.id) {
                                model.patchOpenClawGatewaySession(
                                    conversationID: conversation.id,
                                    model: selection,
                                    thinkingLevel: nil
                                )
                                return
                            }
                            if conversation.localRuntimeKind != nil {
                                model.updateLocalACPSession(
                                    conversation: conversation,
                                    model: selection
                                )
                                return
                            }
                        },
                        onSelectThinking: { selection in
                            guard let conversation else { return }
                            if model.isOpenClawGatewayConversation(conversation.id) {
                                model.patchOpenClawGatewaySession(
                                    conversationID: conversation.id,
                                    model: nil,
                                    thinkingLevel: selection
                                )
                                return
                            }
                            if conversation.localRuntimeKind != nil {
                                model.updateLocalACPSession(
                                    conversation: conversation,
                                    thinking: selection
                                )
                                return
                            }
                        },
                        onAttachmentAction: onAttachmentAction,
                        onRemoveAttachment: onRemoveAttachment,
                        onDropFiles: onDropFiles,
                        onUnavailableAction: onUnavailableComposerAction,
                        onSend: onSend
                    )
                    if showsAddPanel {
                        DashboardPanelControlButton(
                            systemImage: "plus",
                            accessibilityLabel: "Add Panel",
                            help: "Add another chat panel",
                            action: onAddPanel
                        )
                    }
                }
            }
            .frame(maxWidth: 768)
            .padding(.horizontal, usesCompactPanelSpacing ? 12 : 32)
            .padding(.top, 8)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                bottomStackHeight = max(0, height)
            }
            .padding(.bottom, ConversationBottomOverlayLayout.bottomOffset)
        }
        .background(theme.palette.workspace)
        .task(id: sessionIdentity) {
            guard let conversation else { return }
            if model.isOpenClawGatewayConversation(conversation.id) {
                await model.refreshOpenClawGatewaySession(conversationID: conversation.id)
                return
            }
            if conversation.localRuntimeKind != nil {
                await model.refreshLocalACPSession(conversation: conversation)
            }
        }
    }

    private var sessionIdentity: String? {
        guard let conversation else { return nil }
        if conversation.localRuntimeKind != nil {
            return "local:\(conversation.id)"
        }
        return nil
    }

    private var conversationState: DashboardConversationState? {
        guard let conversation else { return nil }
        return model.conversationState(for: conversation.id)
    }

    private var localPermission: PendingLocalACPPermission? {
        guard let conversation else { return nil }
        return model.pendingLocalACPPermissions.first {
            $0.conversationID == conversation.id
        }
    }

    private var localInteraction: PendingLocalACPInteraction? {
        guard let conversation else { return nil }
        return model.pendingLocalACPInteractions.first {
            $0.conversationID == conversation.id
        }
    }

    private var chatEndID: String {
        "chat-end:\(conversation?.id ?? "none")"
    }

    private var bottomScrollClearance: CGFloat {
        CGFloat(ConversationBottomOverlayLayout.scrollClearance(
            stackHeight: Double(bottomStackHeight)
        ))
    }

    private var runsByAssistantMessageID: [String: WorkspaceRunRecord] {
        activeRuns.reduce(into: [:]) {
            if let assistantMessageID = $1.assistantMessageID {
                $0[assistantMessageID] = $1
            }
        }
    }

    private var activitiesByRunID: [String: [WorkspaceRunActivityRecord]] {
        Dictionary(grouping: runActivities, by: \.runID)
    }

    private var visibleMessages: [WorkspaceMessageRecord] {
        messages.filter {
            DashboardRunDisplayPolicy.presentsMessage(
                $0,
                run: runsByAssistantMessageID[$0.id]
            )
        }
    }

    private var newestPresentedMessageIdentity: String? {
        guard let conversation,
              let message = visibleMessages.last,
              let presentation = messagePresentations[message.id],
              presentation.source == message.content else { return nil }
        return [
            conversation.id,
            message.id,
            message.updatedAt ?? "",
            message.status ?? "",
            String(message.content.utf8.count)
        ].joined(separator: ":")
    }

    private func historyLoaderID(oldestMessageID: String) -> String {
        "chat-history:\(conversation?.id ?? "none"):\(oldestMessageID)"
    }

    @MainActor
    private func prependOlderMessages(
        keeping anchorMessageID: String,
        using proxy: ScrollViewProxy
    ) async {
        guard let conversation, !isPrependingHistory else { return }
        isPrependingHistory = true
        let loaded = await model.loadOlderConversationMessages(id: conversation.id)
        if loaded, !Task.isCancelled {
            await Task.yield()
            await Task.yield()
            scrollWithoutAnimation(proxy, to: anchorMessageID, anchor: .top)
        }
        isPrependingHistory = false
    }

    private func scrollWithoutAnimation(
        _ proxy: ScrollViewProxy,
        to id: some Hashable,
        anchor: UnitPoint
    ) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

    private func scrollToConversationBottom(using proxy: ScrollViewProxy) {
        scrollPositionID = chatEndID
        scrollWithoutAnimation(
            proxy,
            to: chatEndID,
            anchor: .bottom
        )
    }

}

private struct DashboardLocalPermissionCard: View {
    @Environment(\.dashboardTheme) private var theme
    let permission: PendingLocalACPPermission
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permission requested")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .textCase(.uppercase)
                .tracking(0.8)
            Text(permission.title)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(permission.options) { option in
                    if option.kind.hasPrefix("allow") {
                        Button(option.name) { onSelect(option.id) }
                            .buttonStyle(DashboardPrimaryButtonStyle())
                    } else {
                        Button(option.name) { onSelect(option.id) }
                            .buttonStyle(DashboardQuietButtonStyle())
                    }
                }
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(DashboardQuietButtonStyle())
            }
        }
        .padding(13)
        .frame(maxWidth: 768, alignment: .leading)
        .background(theme.palette.themeWhisper)
        .clipShape(DashboardShapes.card)
        .overlay {
            DashboardShapes.card
                .stroke(theme.palette.border, lineWidth: 1)
        }
    }
}

private struct DashboardLocalInteractionCard: View {
    let interaction: PendingLocalACPInteraction
    let onResolve: (LocalACPInteractionResponse) -> Void

    var body: some View {
        switch interaction.request {
        case .questions(let request):
            DashboardLocalQuestionCard(request: request, onResolve: onResolve)
        case .plan(let request):
            DashboardLocalPlanCard(request: request, onResolve: onResolve)
        }
    }
}

private struct DashboardLocalQuestionCard: View {
    @Environment(\.dashboardTheme) private var theme
    let request: LocalACPQuestionRequest
    let onResolve: (LocalACPInteractionResponse) -> Void
    @State private var selections: [String: Set<String>] = [:]
    @State private var customAnswers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(dashboardNonemptyString(request.title) ?? "Agent has a question")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .textCase(.uppercase)
                .tracking(0.8)

            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.prompt)
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if question.allowsMultiple {
                        Text("Select one or more options.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 132), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(question.options) { option in
                            let selected = selections[question.id]?.contains(option.id) == true
                            Button {
                                toggle(option: option, for: question)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: selected
                                        ? "checkmark.circle.fill"
                                        : "circle")
                                    Text(option.label)
                                        .lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(selected
                                    ? DashboardPalette.primary
                                    : DashboardPalette.foreground)
                                .padding(.horizontal, 10)
                                .frame(minHeight: 34)
                                .background(
                                    selected
                                        ? theme.palette.themeSoft
                                        : DashboardPalette.background.opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField(
                        "Other response",
                        text: customAnswerBinding(for: question.id)
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 8) {
                Button("Submit") { onResolve(.answers(answers)) }
                    .buttonStyle(DashboardPrimaryButtonStyle())
                    .disabled(!canSubmit)
                Button("Cancel", role: .cancel) { onResolve(.cancelled) }
                    .buttonStyle(DashboardQuietButtonStyle())
            }
        }
        .padding(13)
        .frame(maxWidth: 768, alignment: .leading)
        .background(theme.palette.themeWhisper)
        .clipShape(DashboardShapes.card)
        .overlay {
            DashboardShapes.card.stroke(theme.palette.border, lineWidth: 1)
        }
    }

    private var canSubmit: Bool {
        request.questions.allSatisfy { question in
            dashboardNonemptyString(customAnswers[question.id]) != nil
                || selections[question.id]?.isEmpty == false
        }
    }

    private var answers: [String: LocalACPQuestionAnswer] {
        request.questions.reduce(into: [:]) { result, question in
            if let customAnswer = dashboardNonemptyString(customAnswers[question.id]) {
                result[question.id] = .single(customAnswer)
                return
            }
            let selectedIDs = selections[question.id] ?? []
            let labels = question.options.compactMap { option in
                selectedIDs.contains(option.id) ? option.label : nil
            }
            result[question.id] = question.allowsMultiple
                ? .multiple(labels)
                : .single(labels.first ?? "")
        }
    }

    private func toggle(
        option: LocalACPQuestionOption,
        for question: LocalACPQuestion
    ) {
        customAnswers[question.id] = ""
        if question.allowsMultiple {
            var selected = selections[question.id] ?? []
            if selected.contains(option.id) {
                selected.remove(option.id)
            } else {
                selected.insert(option.id)
            }
            selections[question.id] = selected
        } else {
            selections[question.id] = [option.id]
        }
    }

    private func customAnswerBinding(for questionID: String) -> Binding<String> {
        Binding(
            get: { customAnswers[questionID] ?? "" },
            set: { value in
                customAnswers[questionID] = value
                if dashboardNonemptyString(value) != nil {
                    selections[questionID] = []
                }
            }
        )
    }
}

private struct DashboardLocalPlanCard: View {
    @Environment(\.dashboardTheme) private var theme
    let request: LocalACPPlanRequest
    let onResolve: (LocalACPInteractionResponse) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(dashboardNonemptyString(request.name) ?? "Cursor proposed a plan")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .textCase(.uppercase)
                .tracking(0.8)
            if let overview = dashboardNonemptyString(request.overview) {
                Text(overview)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                ConversationMarkdown(
                    document: ConversationMarkdownDocument(request.markdown),
                    isStreaming: false
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 260)

            HStack(spacing: 8) {
                Button("Accept plan") { onResolve(.planAccepted(true)) }
                    .buttonStyle(DashboardPrimaryButtonStyle())
                Button("Reject", role: .cancel) { onResolve(.planAccepted(false)) }
                    .buttonStyle(DashboardQuietButtonStyle())
            }
        }
        .padding(13)
        .frame(maxWidth: 768, alignment: .leading)
        .background(theme.palette.themeWhisper)
        .clipShape(DashboardShapes.card)
        .overlay {
            DashboardShapes.card.stroke(theme.palette.border, lineWidth: 1)
        }
    }
}

private func dashboardNonemptyString(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else { return nil }
    return trimmed
}

private struct DashboardMessageRow: View {
    let message: WorkspaceMessageRecord
    let attachments: [WorkspaceMessageAttachmentRecord]
    let references: [WorkspaceMessageReferenceRecord]
    let renderedDocument: ConversationMarkdownDocument?
    let run: WorkspaceRunRecord?
    let runPresentation: DashboardRunPresentation?
    let activities: [WorkspaceRunActivityRecord]

    var body: some View {
        if message.role == "system" {
            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                Text(message.content)
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(DashboardPalette.mutedForeground)
        } else {
            let isUser = message.role == "user"
            HStack {
                if isUser { Spacer(minLength: 72) }
                VStack(alignment: isUser ? .trailing : .leading, spacing: 18) {
                    if !isUser, let run {
                        ConversationWorkTranscript(
                            run: run,
                            presentation: runPresentation,
                            records: activities
                        )
                    }
                    if isUser {
                        ConversationUserMessage(
                            content: message.content,
                            attachments: attachments,
                            references: references
                        )
                    } else if showsAssistantBody {
                        if let renderedDocument {
                            ConversationMarkdown(
                                document: renderedDocument,
                                isStreaming: message.status == "streaming"
                            )
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .textSelection(.enabled)
                        } else {
                            Text(RemoteNoteEditEnvelope.redactingEnvelopes(
                                in: message.content
                            ))
                                .font(.system(size: 15))
                                .lineSpacing(4)
                                .foregroundStyle(
                                    message.status == "streaming"
                                        ? DashboardPalette.mutedForeground
                                        : DashboardPalette.foreground
                                )
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .textSelection(.enabled)
                        }
                    }
                    if !isUser {
                        ConversationChangedFilesCard(records: activities)
                    }
                }
                .frame(maxWidth: isUser ? nil : .infinity, alignment: isUser ? .trailing : .leading)
                if !isUser { Spacer(minLength: 0) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var showsAssistantBody: Bool {
        guard message.content.isEmpty == false else { return false }
        guard run?.status == "failed", let error = run?.error else { return true }
        return message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            != error.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ConversationUserMessage: View {
    let content: String
    let attachments: [WorkspaceMessageAttachmentRecord]
    let references: [WorkspaceMessageReferenceRecord]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !content.isEmpty {
                Text(content)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .lineLimit(isLong && !expanded ? 6 : nil)
                    .foregroundStyle(DashboardPalette.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if !attachments.isEmpty || !references.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(attachments) { attachment in
                        DashboardPersistedAttachmentChip(
                            icon: attachment.kind == .image ? "photo" : "doc",
                            title: attachment.fileName,
                            detail: ByteCountFormatter.string(
                                fromByteCount: attachment.sizeBytes,
                                countStyle: .file
                            )
                        )
                    }
                    ForEach(references) { reference in
                        DashboardPersistedAttachmentChip(
                            icon: reference.kind == .note ? "note.text" : "bubble.left.and.bubble.right",
                            title: reference.titleSnapshot,
                            detail: reference.kind == .note ? "Note" : "Conversation"
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isLong {
                Button(expanded ? "Show less" : "Show full message") {
                    withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DashboardPalette.mutedForeground)
            }
        }
        .frame(maxWidth: preferredContentWidth, alignment: .trailing)
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
        .background(DashboardPalette.primary.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var isLong: Bool {
        content.count > 420 || content.filter { $0 == "\n" }.count > 5
    }

    private var preferredContentWidth: CGFloat {
        if !attachments.isEmpty || !references.isEmpty { return 420 }
        let font = NSFont.systemFont(ofSize: 15)
        let longestLine = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        // 586 points of content plus the 34 points of horizontal padding
        // preserves the 620-point T3-style maximum without stretching short
        // messages to that width.
        return min(586, max(isLong ? 118 : 1, ceil(longestLine)))
    }
}

private struct DashboardPersistedAttachmentChip: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DashboardPalette.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(DashboardPalette.background.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct DashboardPanelControlButton: View {
    @Environment(\.dashboardTheme) private var theme
    let systemImage: String
    let accessibilityLabel: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(DashboardComposerControlButtonStyle())
        .foregroundStyle(DashboardPalette.mutedForeground)
        .background(.regularMaterial, in: Circle())
        .overlay {
            Circle().stroke(theme.palette.border, lineWidth: 1)
        }
        .accessibilityLabel(accessibilityLabel)
        .help(help)
    }
}

private struct DashboardComposer: View {
    let placeholder: String
    @Binding var draft: String
    let attachedNoteTitle: String?
    let attachments: [AgentMessageAttachmentDraft]
    let showsSessionControls: Bool
    let sessionMetadata: LocalACPSessionMetadata?
    let sessionControlsDisabled: Bool
    let sendDisabled: Bool
    let focusRequestGeneration: Int?
    let onSelectModel: ((String) -> Void)?
    let onSelectThinking: ((String) -> Void)?
    let onAttachmentAction: (DashboardComposerAttachmentAction) -> Void
    let onRemoveAttachment: (String) -> Void
    let onDropFiles: ([URL]) -> Bool
    let onUnavailableAction: (String) -> Void
    let onSend: () -> Void
    @FocusState private var focused: Bool
    @State private var openMenu: DashboardComposerMenuKind?
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 6) {
            if let attachedNoteTitle {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                    Text(attachedNoteTitle)
                        .lineLimit(1)
                    Text("available to agent")
                        .foregroundStyle(DashboardPalette.mutedForeground)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DashboardPalette.foreground)
                .accessibilityLabel("Open note \(attachedNoteTitle) is available to the agent")
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(attachments) { attachment in
                            DashboardDraftAttachmentChip(
                                attachment: attachment,
                                onRemove: { onRemoveAttachment(attachment.id) }
                            )
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField(
                "",
                text: $draft,
                prompt: Text(placeholder).foregroundStyle(DashboardPalette.mutedForeground),
                axis: .vertical
            )
            .font(.system(size: 15))
            .lineSpacing(4)
            .textFieldStyle(.plain)
            .lineLimit(1...7)
            .focused($focused)
            .frame(minHeight: 32, alignment: .topLeading)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) { return .ignored }
                if applyFirstSlashCommandIfNeeded() { return .handled }
                guard canSend else { return .handled }
                onSend()
                return .handled
            }
            .onKeyPress(.tab, phases: .down) { _ in
                applyFirstSlashCommandIfNeeded() ? .handled : .ignored
            }
            .simultaneousGesture(TapGesture().onEnded { openMenu = nil })

            if !matchingSlashCommands.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matchingSlashCommands.prefix(8)) { command in
                        Button {
                            applySlashCommand(command)
                        } label: {
                            HStack(spacing: 8) {
                                Text("/\(command.name)")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(DashboardPalette.foreground)
                                if let detail = command.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(DashboardPalette.background.opacity(0.96))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DashboardPalette.foreground.opacity(0.08), lineWidth: 1)
                }
            }

            ViewThatFits(in: .horizontal) {
                regularControls
                compactControls
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(
                cornerRadius: DashboardMetrics.composerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: DashboardMetrics.composerRadius, style: .continuous)
                .stroke(
                    isDropTarget
                        ? DashboardPalette.primary
                        : DashboardPalette.foreground.opacity(0.06),
                    lineWidth: isDropTarget ? 2 : 1
                )
        }
        .shadow(
            color: focused ? DashboardPalette.primary.opacity(0.18) : DashboardPalette.foreground.opacity(0.04),
            radius: focused ? 14 : 2,
            y: focused ? 8 : 1
        )
        .background {
            RoundedRectangle(cornerRadius: DashboardMetrics.composerRadius, style: .continuous)
                .fill(.clear)
                .contentShape(
                    RoundedRectangle(cornerRadius: DashboardMetrics.composerRadius, style: .continuous)
                )
                .onTapGesture {
                    openMenu = nil
                    focused = true
                }
        }
        .background {
            DashboardComposerClickAwayMonitor(isActive: focused || openMenu != nil) {
                focused = false
                openMenu = nil
            }
            .allowsHitTesting(false)
        }
        .onExitCommand {
            focused = false
            openMenu = nil
        }
        .dropDestination(for: URL.self) { urls, _ in
            onDropFiles(urls)
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .onChange(of: focusRequestGeneration) { _, generation in
            guard generation != nil else { return }
            focused = true
        }
        .onAppear {
            if focusRequestGeneration != nil {
                focused = true
            }
        }
        .animation(.easeOut(duration: 0.15), value: openMenu)
    }

    private var canSend: Bool {
        !sendDisabled
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
    }

    private var slashQuery: String? {
        let line = draft.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).last.map(String.init) ?? draft
        guard line.hasPrefix("/"), !line.contains(" ") else { return nil }
        return String(line.dropFirst())
    }

    private var matchingSlashCommands: [LocalACPSlashCommand] {
        guard let query = slashQuery,
              let commands = sessionMetadata?.slashCommands,
              !commands.isEmpty else {
            return []
        }
        let needle = query.lowercased()
        return commands.filter { command in
            needle.isEmpty || command.name.lowercased().hasPrefix(needle)
        }
    }

    private func applyFirstSlashCommandIfNeeded() -> Bool {
        guard let command = matchingSlashCommands.first else { return false }
        applySlashCommand(command)
        return true
    }

    private func applySlashCommand(_ command: LocalACPSlashCommand) {
        let lines = draft.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var next = lines
        if next.isEmpty {
            next = ["/\(command.name) "]
        } else {
            next[next.count - 1] = "/\(command.name) "
        }
        draft = next.joined(separator: "\n")
        openMenu = nil
    }

    private func composerIconButton(
        icon: DashboardLucideGlyph,
        accessibilityLabel: String,
        menu: DashboardComposerMenuKind
    ) -> some View {
        Button {
            focused = false
            openMenu = openMenu == menu ? nil : menu
        } label: {
            DashboardLucideIcon(glyph: icon, size: 16)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(DashboardComposerControlButtonStyle(active: openMenu == menu))
        .foregroundStyle(DashboardPalette.mutedForeground)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(openMenu == menu ? "Expanded" : "Collapsed")
    }

    private var regularControls: some View {
        HStack(spacing: 4) {
            attachmentControl

            if showsSessionControls {
                sessionMenu(
                    kind: .model,
                    icon: .cpu,
                    title: sessionMetadata?.model ?? "Model",
                    menuTitle: "Model",
                    accessibilityLabel: "Choose session model",
                    options: sessionMetadata?.selectableModels ?? [],
                    selection: sessionMetadata?.model,
                    action: onSelectModel
                )
                sessionMenu(
                    kind: .thinking,
                    icon: .brain,
                    title: sessionMetadata?.thinking.map(dashboardSessionThinkingLabel) ?? "Thinking",
                    menuTitle: "Thinking",
                    accessibilityLabel: "Choose thinking level",
                    options: sessionMetadata?.selectableThinkingLevels ?? [],
                    selection: sessionMetadata?.thinking,
                    capitalizeOptions: true,
                    action: onSelectThinking
                )
            }

            Spacer(minLength: 8)
            voiceControl
            sendControl
        }
    }

    private var compactControls: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                attachmentControl
                if showsSessionControls {
                    compactSessionMenu(
                        kind: .model,
                        icon: .cpu,
                        title: sessionMetadata?.model ?? "Model",
                        menuTitle: "Model",
                        accessibilityLabel: "Choose session model",
                        options: sessionMetadata?.selectableModels ?? [],
                        selection: sessionMetadata?.model,
                        action: onSelectModel
                    )
                } else {
                    voiceControl
                }
            }
            if showsSessionControls {
                GridRow {
                    compactSessionMenu(
                        kind: .thinking,
                        icon: .brain,
                        title: sessionMetadata?.thinking.map(dashboardSessionThinkingLabel) ?? "Thinking",
                        menuTitle: "Thinking",
                        accessibilityLabel: "Choose thinking level",
                        options: sessionMetadata?.selectableThinkingLevels ?? [],
                        selection: sessionMetadata?.thinking,
                        capitalizeOptions: true,
                        action: onSelectThinking
                    )
                    voiceControl
                }
            }
            GridRow {
                Color.clear.frame(width: 36, height: 36)
                sendControl
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var attachmentControl: some View {
        composerIconButton(
            icon: .plus,
            accessibilityLabel: "Add attachment",
            menu: .attachments
        )
        .overlay(alignment: .bottomLeading) {
            if openMenu == .attachments {
                DashboardComposerAttachmentMenu { action in
                    openMenu = nil
                    onAttachmentAction(action)
                }
                .offset(y: -44)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            }
        }
        .zIndex(openMenu == .attachments ? 3 : 0)
    }

    private var voiceControl: some View {
        Button {
            openMenu = nil
            focused = false
            onUnavailableAction("Voice input")
        } label: {
            DashboardLucideIcon(glyph: .mic, size: 16)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(DashboardComposerControlButtonStyle())
        .foregroundStyle(DashboardPalette.mutedForeground)
        .accessibilityLabel("Voice input unavailable")
    }

    private var sendControl: some View {
        Button(action: onSend) {
            DashboardLucideIcon(glyph: .arrowUp, size: 16)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(DashboardPalette.primary)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.4)
        .accessibilityLabel("Send")
    }

    private func compactSessionMenu(
        kind: DashboardComposerMenuKind,
        icon: DashboardLucideGlyph,
        title: String,
        menuTitle: String,
        accessibilityLabel: String,
        options: [String],
        selection: String?,
        capitalizeOptions: Bool = false,
        action: ((String) -> Void)?
    ) -> some View {
        let unavailable = sessionControlsDisabled || options.count < 2 || action == nil
        return Button {
            guard !unavailable else { return }
            focused = false
            openMenu = openMenu == kind ? nil : kind
        } label: {
            DashboardLucideIcon(glyph: icon, size: 16)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(DashboardComposerControlButtonStyle(active: openMenu == kind))
        .foregroundStyle(DashboardPalette.mutedForeground)
        .disabled(unavailable)
        .opacity(unavailable ? 0.4 : 1)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(title), \(openMenu == kind ? "Expanded" : "Collapsed")")
        .overlay(alignment: .bottomLeading) {
            if openMenu == kind {
                DashboardComposerOptionMenu(
                    title: menuTitle,
                    options: options,
                    selection: selection,
                    capitalizeOptions: capitalizeOptions
                ) { option in
                    openMenu = nil
                    action?(option)
                }
                .offset(y: -44)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            }
        }
        .zIndex(openMenu == kind ? 3 : 0)
    }

    private func sessionMenu(
        kind: DashboardComposerMenuKind,
        icon: DashboardLucideGlyph,
        title: String,
        menuTitle: String,
        accessibilityLabel: String,
        options: [String],
        selection: String?,
        capitalizeOptions: Bool = false,
        action: ((String) -> Void)?
    ) -> some View {
        let unavailable = sessionControlsDisabled || options.count < 2 || action == nil
        return Button {
            guard !unavailable else { return }
            focused = false
            openMenu = openMenu == kind ? nil : kind
        } label: {
            DashboardComposerSessionLabel(icon: icon, title: title)
        }
        .buttonStyle(DashboardComposerControlButtonStyle(active: openMenu == kind))
        .disabled(unavailable)
        .opacity(unavailable ? 0.4 : 1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(title), \(openMenu == kind ? "Expanded" : "Collapsed")")
        .overlay(alignment: .bottomLeading) {
            if openMenu == kind {
                DashboardComposerOptionMenu(
                    title: menuTitle,
                    options: options,
                    selection: selection,
                    capitalizeOptions: capitalizeOptions
                ) { option in
                    openMenu = nil
                    action?(option)
                }
                .offset(y: -44)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            }
        }
        .zIndex(openMenu == kind ? 3 : 0)
    }
}

private struct DashboardComposerClickAwayMonitor: NSViewRepresentable {
    let isActive: Bool
    let onClickAway: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(view: view, isActive: isActive, onClickAway: onClickAway)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(view: nsView, isActive: isActive, onClickAway: onClickAway)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private weak var view: NSView?
        private var eventMonitor: Any?
        private var onClickAway: () -> Void = {}

        func update(view: NSView, isActive: Bool, onClickAway: @escaping () -> Void) {
            self.view = view
            self.onClickAway = onClickAway

            if isActive, eventMonitor == nil {
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                    [weak self] event in
                    guard let self,
                          let view = self.view,
                          event.window === view.window
                    else { return event }

                    let point = view.convert(event.locationInWindow, from: nil)
                    guard !view.bounds.contains(point) else { return event }

                    DispatchQueue.main.async { [weak self] in
                        self?.onClickAway()
                    }
                    return event
                }
            } else if !isActive {
                stop()
            }
        }

        func stop() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }
    }
}

private enum DashboardComposerMenuKind {
    case attachments
    case model
    case thinking
}

private enum DashboardComposerAttachmentAction {
    case upload
    case note
    case conversation
}

private enum DashboardAttachmentPickerKind: String, Identifiable {
    case note
    case conversation

    var id: String { rawValue }
}

private struct DashboardDraftAttachmentChip: View {
    let attachment: AgentMessageAttachmentDraft
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            preview
            Text(attachment.displayName)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.displayName)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(DashboardPalette.foreground.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private var preview: some View {
        switch attachment {
        case .file(let file):
            if file.kind == .image, let image = NSImage(contentsOf: file.localURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 25, height: 25)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(DashboardPalette.primary)
                    .frame(width: 25, height: 25)
            }
        case .reference(let reference):
            Image(systemName: reference.kind == .note ? "note.text" : "bubble.left.and.bubble.right")
                .foregroundStyle(DashboardPalette.primary)
                .frame(width: 25, height: 25)
        }
    }
}

private struct DashboardComposerSessionLabel: View {
    let icon: DashboardLucideGlyph
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            DashboardLucideIcon(glyph: icon, size: 14)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            DashboardLucideIcon(glyph: .chevronDown, size: 14)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(DashboardPalette.mutedForeground)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .contentShape(Capsule())
    }
}

private struct DashboardComposerControlButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                (active || configuration.isPressed ? theme.palette.themeSoft : .clear),
                in: Capsule()
            )
    }
}

private struct DashboardComposerAttachmentMenu: View {
    let onSelect: (DashboardComposerAttachmentAction) -> Void

    var body: some View {
        VStack(spacing: 2) {
            menuRow(icon: .upload, title: "Upload photos or files", action: .upload)
            menuRow(icon: .fileText, title: "Attach note", action: .note)
            menuRow(icon: .messageSquare, title: "Attach conversation", action: .conversation)
        }
        .padding(8)
        .frame(width: 224)
        .dashboardComposerPopover()
    }

    private func menuRow(
        icon: DashboardLucideGlyph,
        title: String,
        action: DashboardComposerAttachmentAction
    ) -> some View {
        DashboardComposerPopoverRow(action: { onSelect(action) }) {
            HStack(spacing: 12) {
                DashboardLucideIcon(glyph: icon, size: 16)
                    .foregroundStyle(DashboardPalette.primary)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DashboardPalette.foreground)
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
    }
}

private struct DashboardAttachmentPicker: View {
    @Environment(\.dismiss) private var dismiss
    let kind: DashboardAttachmentPickerKind
    let notes: [WorkspaceNoteRecord]
    let conversations: [WorkspaceConversationRecord]
    let onSelectNote: (WorkspaceNoteRecord) -> Void
    let onSelectConversation: (WorkspaceConversationRecord) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if kind == .note {
                    ForEach(filteredNotes) { note in
                        Button { onSelectNote(note) } label: {
                            pickerRow(
                                icon: "note.text",
                                title: note.title,
                                detail: note.content
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ForEach(filteredConversations) { conversation in
                        Button { onSelectConversation(conversation) } label: {
                            pickerRow(
                                icon: "bubble.left.and.bubble.right",
                                title: conversation.title,
                                detail: conversation.agentCodename ?? "Conversation"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $query, prompt: kind == .note ? "Search notes" : "Search conversations")
            .navigationTitle(kind == .note ? "Attach note" : "Attach conversation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private var filteredNotes: [WorkspaceNoteRecord] {
        guard !query.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.content.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredConversations: [WorkspaceConversationRecord] {
        guard !query.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.agentCodename?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func pickerRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(DashboardPalette.primary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(DashboardPalette.foreground)
                Text(detail.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

private struct DashboardComposerOptionMenu: View {
    let title: String
    let options: [String]
    let selection: String?
    let capitalizeOptions: Bool
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(DashboardPalette.mutedForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(options, id: \.self) { option in
                        DashboardComposerPopoverRow(action: { onSelect(option) }) {
                            HStack(spacing: 12) {
                                Text(optionLabel(option))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if option == selection {
                                    DashboardLucideIcon(glyph: .check, size: 14)
                                        .foregroundStyle(DashboardPalette.primary)
                                }
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(DashboardPalette.foreground)
                            .padding(.horizontal, 10)
                            .frame(height: 38)
                            .background(
                                option == selection ? DashboardPalette.muted.opacity(0.55) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: min(CGFloat(options.count) * 40, 248))
        }
        .padding(6)
        .frame(width: 288)
        .dashboardComposerPopover()
    }

    private func optionLabel(_ option: String) -> String {
        capitalizeOptions ? dashboardSessionThinkingLabel(option) : option
    }
}

private struct DashboardComposerPopoverRow<Content: View>: View {
    @Environment(\.dashboardTheme) private var theme
    let action: () -> Void
    let content: Content
    @State private var hovered = false

    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            hovered ? theme.palette.themeSoft : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .onHover { hovered = $0 }
    }
}

private struct DashboardComposerPopoverModifier: ViewModifier {
    @Environment(\.dashboardTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(
                DashboardPalette.background.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.palette.border.opacity(0.45), lineWidth: 1)
            }
            .shadow(color: DashboardPalette.foreground.opacity(0.12), radius: 24, y: 14)
    }
}

private extension View {
    func dashboardComposerPopover() -> some View {
        modifier(DashboardComposerPopoverModifier())
    }
}

private func dashboardSessionThinkingLabel(_ value: String) -> String {
    value.replacingOccurrences(of: "_", with: " ").capitalized
}

private struct DashboardNotePane: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    let note: WorkspaceNoteRecord
    let showBack: Bool
    let noteOnLeft: Bool
    let isFocused: Bool
    let reservesLeadingRailControlSpace: Bool
    let reservesTrailingRailControlSpace: Bool
    let focusesTitleOnAppear: Bool
    let onInitialFocusHandled: () -> Void
    let onBack: () -> Void
    let onMove: () -> Void
    let onToggleFocus: () -> Void
    let onClose: () -> Void
    @FocusState private var titleFocused: Bool
    @State private var editorController = DashboardNoteEditorController()
    @State private var showsFormatting = false
    @State private var linkedDataJSON: String?
    @State private var linkedDataError: String?
    @State private var isRefreshingLinkedData = false
    @State private var activeLinkedDataRefreshID: UUID?

    private var draft: DashboardNoteDraft {
        model.noteDraft(for: note)
    }

    private var title: Binding<String> {
        Binding(
            get: { model.noteDraft(for: note).title },
            set: { model.updateNoteDraft(note: note, title: $0) }
        )
    }

    private var document: Binding<NoteDocument> {
        Binding(
            get: { NoteDocument.decode(model.noteDraft(for: note).content) },
            set: { updated in
                guard let content = try? updated.encoded() else { return }
                model.updateNoteDraft(note: note, content: content)
            }
        )
    }

    private var currentDocument: NoteDocument {
        document.wrappedValue
    }

    private var hasDatabaseLinks: Bool {
        if currentDocument.databaseLink != nil { return true }
        return currentDocument.blocks.contains { block in
            guard case .table(let table) = block else { return false }
            return table.databaseLink != nil
        }
    }

    private var databaseLinkSignature: String {
        let links = [currentDocument.databaseLink]
            + currentDocument.blocks.map { block -> DatabaseArtifactLink? in
                guard case .table(let table) = block else { return nil }
                return table.databaseLink
            }
        return links.compactMap { link in
            link.map {
                "\($0.sourceID)|\($0.databaseID)|\($0.relativePath)|\($0.sqliteQuery ?? "")"
            }
        }.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if showBack {
                    Button {
                        model.flushNoteDrafts()
                        onBack()
                    } label: {
                        DashboardLucideIcon(glyph: .arrowLeft, size: 16).frame(width: 32, height: 32)
                    }
                    .buttonStyle(DashboardIconButtonStyle())
                }
                TextField(
                    currentDocument.kind == .note
                        ? "Untitled Note"
                        : "Untitled \(currentDocument.kind.displayName)",
                    text: title
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.3)
                    .lineLimit(1)
                    .focused($titleFocused)
                    .accessibilityLabel("Note title")
                    .layoutPriority(1)
                Spacer()
                DashboardDatabaseLinkControl(
                    document: document,
                    snapshot: model.databasesSnapshot
                )
                if hasDatabaseLinks {
                    Button {
                        Task { await refreshLinkedData() }
                    } label: {
                        if isRefreshingLinkedData {
                            ProgressView().controlSize(.small).frame(width: 32, height: 32)
                        } else {
                            DashboardLucideIcon(glyph: .rotate, size: 14)
                                .frame(width: 32, height: 32)
                        }
                    }
                    .buttonStyle(DashboardIconButtonStyle())
                    .help("Refresh linked data")
                    .disabled(isRefreshingLinkedData)
                }
                if currentDocument.kind == .note {
                    Button {
                        showsFormatting.toggle()
                    } label: {
                        Image(systemName: "textformat")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(DashboardIconButtonStyle())
                    .help("Format note")
                }
                if !showBack {
                    Button(action: onMove) {
                        DashboardLucideIcon(glyph: noteOnLeft ? .arrowRight : .arrowLeft, size: 16)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(DashboardIconButtonStyle())
                    .help(noteOnLeft ? "Move note right" : "Move note left")
                    Button(action: onToggleFocus) {
                        Image(systemName: isFocused
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(DashboardIconButtonStyle())
                    .help(isFocused ? "Restore chat and note" : "Focus note")
                }
                Button {
                    model.flushNoteDrafts()
                    onClose()
                } label: {
                    DashboardLucideIcon(glyph: noteOnLeft ? .panelLeftClose : .panelRightClose, size: 16)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(DashboardIconButtonStyle())
            }
            .padding(.leading, reservesLeadingRailControlSpace ? 56 : 12)
            .padding(.trailing, reservesTrailingRailControlSpace ? 56 : 12)
            .frame(height: 56)

            if showsFormatting && currentDocument.kind == .note {
                DashboardNoteFormattingBar(controller: editorController)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 8) {
                Group {
                    switch currentDocument.kind {
                    case .note:
                        DashboardNoteEditor(document: document, controller: editorController)
                            .accessibilityLabel("Note body")
                    case .spreadsheet:
                        DashboardSpreadsheetEditor(document: document)
                            .accessibilityLabel("Spreadsheet")
                    case .html:
                        DashboardHTMLArtifactView(
                            html: currentDocument.html,
                            linkedDataJSON: linkedDataJSON
                        )
                        .accessibilityLabel("HTML artifact")
                    }
                }

                if let linkedDataError {
                    HStack(spacing: 6) {
                        DashboardLucideIcon(glyph: .alertTriangle, size: 12)
                        Text(linkedDataError).lineLimit(2)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardPalette.warning)
                }

                switch draft.saveState {
                case .failed(let message):
                    HStack(spacing: 6) {
                        DashboardLucideIcon(glyph: .alertCircle, size: 12)
                        Text(message)
                            .lineLimit(2)
                        Button("Retry") { model.retryNoteDraft(note: note) }
                            .buttonStyle(.plain)
                            .underline()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardPalette.danger)
                case .saved, .saving:
                    EmptyView()
                }
            }
            .frame(
                maxWidth: currentDocument.kind == .note ? 768 : .infinity,
                maxHeight: .infinity,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .background(theme.palette.workspace)
        .onAppear {
            model.prepareNoteDraft(note)
            if focusesTitleOnAppear {
                titleFocused = true
                onInitialFocusHandled()
            }
        }
        .onChange(of: note) { _, updated in model.prepareNoteDraft(updated) }
        .task(id: "\(note.id):\(databaseLinkSignature)") {
            guard hasDatabaseLinks else {
                linkedDataJSON = nil
                linkedDataError = nil
                return
            }
            await refreshLinkedData()
        }
        .onDisappear { model.flushNoteDrafts() }
    }

    private func refreshLinkedData() async {
        let refreshID = UUID()
        activeLinkedDataRefreshID = refreshID
        isRefreshingLinkedData = true
        defer {
            if activeLinkedDataRefreshID == refreshID {
                activeLinkedDataRefreshID = nil
                isRefreshingLinkedData = false
            }
        }
        let snapshot = currentDocument
        linkedDataError = nil
        do {
            switch snapshot.kind {
            case .html:
                if let link = snapshot.databaseLink {
                    let data = try await model.linkedData(for: link)
                    guard !Task.isCancelled,
                          activeLinkedDataRefreshID == refreshID,
                          currentDocument.kind == .html,
                          currentDocument.databaseLink == link else { return }
                    linkedDataJSON = data.json
                }
            case .spreadsheet:
                if let link = snapshot.databaseLink {
                    let original = snapshot.blocks.compactMap { block -> NoteTableBlock? in
                        guard case .table(let table) = block else { return nil }
                        return table
                    }.first
                    let data = try await model.linkedData(for: link)
                    guard !Task.isCancelled,
                          activeLinkedDataRefreshID == refreshID else { return }
                    var latest = currentDocument
                    guard latest.kind == .spreadsheet,
                          latest.databaseLink == link,
                          let original,
                          let index = latest.blocks.firstIndex(where: { $0.id == original.id }),
                          case .table(let existing) = latest.blocks[index],
                          existing == original else {
                        linkedDataError = linkedDataChangedMessage
                        return
                    }
                    latest.blocks[index] = .table(data.applying(to: existing))
                    if latest != currentDocument { document.wrappedValue = latest }
                }
            case .note:
                var loaded: [(table: NoteTableBlock, data: DatabaseTabularData)] = []
                for block in snapshot.blocks {
                    guard case .table(let table) = block,
                          let link = table.databaseLink ?? snapshot.databaseLink else { continue }
                    let data = try await model.linkedData(for: link)
                    guard !Task.isCancelled,
                          activeLinkedDataRefreshID == refreshID else { return }
                    loaded.append((table, data))
                }
                guard activeLinkedDataRefreshID == refreshID else { return }
                var latest = currentDocument
                var skippedChangedTable = false
                for item in loaded {
                    guard let index = latest.blocks.firstIndex(where: { $0.id == item.table.id }),
                          case .table(let existing) = latest.blocks[index],
                          existing == item.table else {
                        skippedChangedTable = true
                        continue
                    }
                    latest.blocks[index] = .table(item.data.applying(to: existing))
                }
                if latest != currentDocument { document.wrappedValue = latest }
                if skippedChangedTable { linkedDataError = linkedDataChangedMessage }
            }
        } catch {
            guard !Task.isCancelled,
                  activeLinkedDataRefreshID == refreshID else { return }
            linkedDataError = error.localizedDescription
        }
    }

    private var linkedDataChangedMessage: String {
        "The artifact changed while data was loading. Refresh again to avoid overwriting your edits."
    }

}

private struct DashboardSplitSeparator: View {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let totalWidth: CGFloat
    let noteOnLeft: Bool
    @Binding var chatWidthPercent: Double
    @State private var hovered = false
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: DashboardMetrics.separatorWidth)
            .overlay {
                Capsule()
                    .fill(dragging ? theme.palette.themeRing : hovered ? theme.palette.themeStrong : theme.palette.border)
                    .frame(width: 2, height: 32)
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("dashboard-workspace-split"))
                    .onChanged { value in
                        dragging = true
                        updateWidth(dividerCenter: value.location.x)
                    }
                    .onEnded { value in
                        updateWidth(dividerCenter: value.location.x)
                        dragging = false
                    }
            )
            .onTapGesture(count: 2) {
                if reduceMotion {
                    chatWidthPercent = Double(DashboardMetrics.defaultChatWidthPercent)
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        chatWidthPercent = Double(DashboardMetrics.defaultChatWidthPercent)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Resize chat and note panes")
            .accessibilityValue("Chat \(chatWidthPercent, specifier: "%.1f") percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: commit(chatWidthPercent + 1)
                case .decrement: commit(chatWidthPercent - 1)
                @unknown default: break
                }
            }
            .help("Drag to resize · double-click to reset")
    }

    private func updateWidth(dividerCenter: CGFloat) {
        let contentWidth = max(1, totalWidth - DashboardMetrics.separatorWidth)
        let chatPixels = noteOnLeft
            ? totalWidth - dividerCenter - DashboardMetrics.separatorWidth / 2
            : dividerCenter - DashboardMetrics.separatorWidth / 2
        commit(Double((chatPixels / contentWidth) * 100))
    }

    private func commit(_ proposed: Double) {
        let bounds = dashboardChatWidthBounds(totalWidth: totalWidth)
        chatWidthPercent = (min(max(proposed, bounds.lowerBound), bounds.upperBound) * 10).rounded() / 10
    }
}

private struct OpenClawCronSurface: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    let onOpenConversation: (String) -> Void
    @State private var showsDeleted = false
    @State private var selectedAgentID: UUID?

    private var agents: [WorkspaceAgent] {
        let all = model.localCLIAgents
            + model.remoteWorkspaceAgents
            + model.buzzWorkspaceAgents
        return all.filter {
            $0.runtimeKind == .openclaw && model.isOpenClawGatewayLinked(agentID: $0.id)
        }
    }

    private var jobs: [OpenClawCronJob] {
        let filtered = model.openClawCronJobs.filter {
            (showsDeleted ? $0.archiveState == .deleted : $0.archiveState == .active)
                && (selectedAgentID == nil || $0.agentID == selectedAgentID)
        }
        return OpenClawCronOrdering.latestExecutionFirst(
            jobs: filtered,
            runs: model.openClawCronRuns
        )
    }

    private var heartbeatAgent: WorkspaceAgent? {
        if let selectedAgentID {
            return agents.first { $0.id == selectedAgentID }
        }
        return agents.count == 1 ? agents.first : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                DashboardLucideIcon(glyph: .calendarClockControl, size: 18)
                    .foregroundStyle(DashboardPalette.primary)
                    .frame(width: 36, height: 36)
                    .background(DashboardPalette.muted)
                    .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cron Jobs").font(.system(size: 22, weight: .semibold))
                    Text("OpenClaw Heartbeat, schedules, history, and output")
                        .font(.system(size: 12.5)).foregroundStyle(DashboardPalette.mutedForeground)
                }
                Spacer()
                Picker("OpenClaw", selection: $selectedAgentID) {
                    Text("All OpenClaws").tag(nil as UUID?)
                    ForEach(agents) { Text($0.displayName).tag(agentOptional($0.id)) }
                }
                .frame(maxWidth: 190)
                Toggle("Deleted", isOn: $showsDeleted).toggleStyle(.button)
                if showsDeleted {
                    Button("Empty Trash") { model.emptyOpenClawCronTrash() }
                        .buttonStyle(DashboardQuietButtonStyle())
                }
                Button(model.isRefreshingOpenClawCron ? "Refreshing…" : "Refresh") {
                    Task { await model.refreshOpenClawCron() }
                }
                .buttonStyle(DashboardQuietButtonStyle())
                .disabled(model.isRefreshingOpenClawCron)
                if agents.count == 1, let agent = agents.first {
                    Button("New Cron") { createConversation(agentID: agent.id, context: nil) }
                        .buttonStyle(DashboardPrimaryButtonStyle())
                } else {
                    Menu("New Cron") {
                        ForEach(agents) { agent in
                            Button(agent.displayName) { createConversation(agentID: agent.id, context: nil) }
                        }
                    }
                    .buttonStyle(DashboardPrimaryButtonStyle())
                    .disabled(agents.isEmpty)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 48)
            .padding(.bottom, 20)

            if let error = model.openClawCronError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.danger)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            heartbeatSection
                .padding(.horizontal, 32)
                .padding(.bottom, 16)

            if jobs.isEmpty {
                DashboardConversationEmptyState(
                    icon: .calendarClockControl,
                    title: showsDeleted ? "Cron Trash is empty" : "No scheduled jobs",
                    detail: "Refresh imports jobs and execution history from each linked OpenClaw. Woven Matter never creates, edits, or deletes remote cron jobs here."
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(jobs) { job in cronJob(job) }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
            }
        }
        .background(theme.palette.workspace)
        .task(id: heartbeatAgent?.id) {
            guard let agentID = heartbeatAgent?.id else { return }
            await model.loadOpenClawHeartbeat(agentID: agentID)
        }
    }

    @ViewBuilder
    private var heartbeatSection: some View {
        if let agent = heartbeatAgent {
            OpenClawHeartbeatCard(
                agent: agent,
                configuration: model.openClawHeartbeatConfigurations[agent.id],
                isSaving: model.openClawHeartbeatSavingAgentIDs.contains(agent.id),
                message: model.openClawHeartbeatMessages[agent.id],
                messageIsError: model.openClawHeartbeatErrorAgentIDs.contains(agent.id),
                onSave: { configuration in
                    model.saveOpenClawHeartbeat(
                        agentID: agent.id,
                        configuration: configuration
                    )
                }
            )
            .id(agent.id)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("Heartbeat")
                    .font(.system(size: 14, weight: .semibold))
                Text(agents.isEmpty
                     ? "Link an OpenClaw Gateway to configure its Heartbeat."
                     : "Choose an OpenClaw above to configure its Heartbeat.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(DashboardPalette.background)
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous)
                    .stroke(DashboardPalette.foreground.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private func cronJob(_ job: OpenClawCronJob) -> some View {
        let run = model.openClawCronRuns.first { $0.agentID == job.agentID && $0.jobID == job.id }
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.name).font(.system(size: 13.5, weight: .semibold))
                    Text(job.schedule).font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                }
                Spacer()
                DashboardCronPill(job.enabled ? "Enabled" : "Disabled", warning: !job.enabled)
                if let run { DashboardCronPill(run.status.capitalized, warning: run.status != "ok") }
            }
            if let run {
                Text(run.output?.isEmpty == false ? run.output! : "No captured output")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Text("Latest execution first · \((run.startedAt ?? run.completedAt)?.formatted(date: .abbreviated, time: .shortened) ?? "Time unavailable")")
                    .font(.system(size: 10.5)).foregroundStyle(DashboardPalette.mutedForeground)
            }
            DisclosureGroup("Job details and run history") {
                VStack(alignment: .leading, spacing: 8) {
                    if let description = cronText(job.remotePayload, keys: ["description", "message", "text", "script", "argv"]) {
                        Text(description).font(.system(size: 11.5)).textSelection(.enabled)
                    }
                    if let model = cronText(job.remotePayload, keys: ["model", "modelId"]) {
                        Text("Model: \(model)").font(.system(size: 11.5))
                    }
                    Text("Job ID: \(job.id)").font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                    ForEach(jobRuns(job)) { historyRun in
                        DisclosureGroup("\(historyRun.status.capitalized) · \((historyRun.startedAt ?? historyRun.completedAt)?.formatted(date: .abbreviated, time: .shortened) ?? "Time unavailable")") {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Run ID: \(historyRun.id)").font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                                Text(historyRun.output?.isEmpty == false ? historyRun.output! : "No captured output")
                                    .font(.system(size: 11.5)).textSelection(.enabled)
                                if job.archiveState == .active {
                                    Button("Continue from Output") {
                                        createConversation(agentID: job.agentID, context: jobContext(job, run: historyRun, action: "Continue from this cron output"))
                                    }.buttonStyle(DashboardQuietButtonStyle())
                                }
                            }.padding(.top, 5)
                        }
                    }
                }.padding(.top, 6)
            }
            if job.archiveState == .active {
                HStack {
                    Button("Edit with Agent") {
                        createConversation(agentID: job.agentID, context: jobContext(job, run: nil, action: "Edit this cron job"))
                    }
                    .buttonStyle(DashboardQuietButtonStyle())
                    if let run {
                        Button("Continue from Output") {
                            createConversation(agentID: job.agentID, context: jobContext(job, run: run, action: "Continue from this cron output"))
                        }
                        .buttonStyle(DashboardQuietButtonStyle())
                    }
                }
            }
        }
        .padding(14)
        .background(DashboardPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous)
                .stroke(DashboardPalette.foreground.opacity(0.12), lineWidth: 1)
        }
    }

    private func agentOptional(_ id: UUID) -> UUID? { id }

    private func jobRuns(_ job: OpenClawCronJob) -> [OpenClawCronRun] {
        model.openClawCronRuns.filter { $0.agentID == job.agentID && $0.jobID == job.id }
            .sorted { ($0.startedAt ?? $0.completedAt ?? .distantPast) > ($1.startedAt ?? $1.completedAt ?? .distantPast) }
    }

    private func cronText(_ data: Data, keys: [String]) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let values = object[key] as? [String], !values.isEmpty { return values.joined(separator: " ") }
            if let payload = object["payload"] as? [String: Any],
               let value = payload[key] as? String, !value.isEmpty { return value }
            if let payload = object["payload"] as? [String: Any],
               let values = payload[key] as? [String], !values.isEmpty { return values.joined(separator: " ") }
        }
        return nil
    }

    private func createConversation(agentID: UUID, context: String?) {
        Task {
            if let id = await model.createOpenClawContextConversation(
                agentID: agentID,
                context: context
            ) {
                onOpenConversation(id)
            }
        }
    }

    private func jobContext(
        _ job: OpenClawCronJob,
        run: OpenClawCronRun?,
        action: String
    ) -> String {
        [
            action,
            "Job ID: \(job.id)",
            "Schedule: \(job.schedule)",
            cronText(job.remotePayload, keys: ["description", "message", "text", "script", "argv"]).map { "What it does: \($0)" },
            cronText(job.remotePayload, keys: ["model", "modelId"]).map { "Model: \($0)" },
            "Original cron session ID: \(run?.nativeSessionID ?? job.nativeSessionID ?? "unavailable")",
            "Original cron session key: \(run?.nativeSessionKey ?? job.nativeSessionKey ?? "unavailable")",
            run?.output.map { "Output:\n\($0)" },
        ].compactMap { $0 }.joined(separator: "\n")
    }
}

private struct OpenClawHeartbeatCard: View {
    let agent: WorkspaceAgent
    let configuration: OpenClawHeartbeatConfiguration?
    let isSaving: Bool
    let message: String?
    let messageIsError: Bool
    let onSave: (OpenClawHeartbeatConfiguration) -> Void

    @State private var draft = OpenClawHeartbeatConfiguration()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Heartbeat")
                        .font(.system(size: 14, weight: .semibold))
                    Text("OpenClaw's recurring check-in for \(agent.displayName)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }
                Spacer()
                Toggle("Enabled", isOn: $draft.isEnabled)
                    .toggleStyle(.switch)
                    .disabled(configuration == nil || isSaving)
            }

            if configuration == nil {
                if let message {
                    Text(message)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(
                            messageIsError
                                ? DashboardPalette.danger
                                : DashboardPalette.mutedForeground
                        )
                        .textSelection(.enabled)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading Heartbeat from OpenClaw…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    heartbeatField("Interval") {
                        TextField("30m", text: $draft.interval)
                    }
                    heartbeatField("Active from") {
                        TextField("09:00", text: $draft.activeFrom)
                    }
                    heartbeatField("Active until") {
                        TextField("17:00", text: $draft.activeUntil)
                    }
                    heartbeatField("Timezone") {
                        TextField("America/New_York", text: $draft.timezone)
                    }
                }
                .disabled(!draft.isEnabled || isSaving)

                heartbeatField("Prompt") {
                    TextField("Heartbeat prompt", text: $draft.prompt, axis: .vertical)
                        .lineLimit(2...4)
                }
                .disabled(isSaving)

                HStack {
                    Button(isSaving ? "Saving Heartbeat…" : "Save Heartbeat") {
                        onSave(draft)
                    }
                    .buttonStyle(DashboardPrimaryButtonStyle())
                    .disabled(isSaving || !canSave)
                    if let message {
                        Text(message)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(
                                messageIsError
                                    ? DashboardPalette.danger
                                    : DashboardPalette.mutedForeground
                            )
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(16)
        .background(DashboardPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous)
                .stroke(DashboardPalette.foreground.opacity(0.12), lineWidth: 1)
        }
        .onAppear { if let configuration { draft = configuration } }
        .onChange(of: configuration) { _, configuration in
            if let configuration { draft = configuration }
        }
    }

    private var canSave: Bool {
        !draft.interval.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.activeFrom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.activeUntil.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.timezone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func heartbeatField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DashboardPalette.mutedForeground)
            content()
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardCronPill: View {
    let label: String
    let warning: Bool

    init(_ label: String, warning: Bool) {
        self.label = label
        self.warning = warning
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(warning ? DashboardPalette.warning : DashboardPalette.mutedForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((warning ? DashboardPalette.warning : DashboardPalette.mutedForeground).opacity(0.08))
            .clipShape(Capsule())
    }
}

private struct DashboardUnavailableUtility: View {
    @Environment(\.dashboardTheme) private var theme
    let icon: DashboardLucideGlyph
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                HStack(spacing: 10) {
                    DashboardLucideIcon(glyph: icon, size: 18)
                        .foregroundStyle(DashboardPalette.primary)
                        .frame(width: 36, height: 36)
                        .background(DashboardPalette.muted)
                        .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 22, weight: .semibold))
                            .tracking(-0.3)
                        Text(utilitySubtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 56)
            DashboardConversationEmptyState(icon: icon, title: emptyTitle, detail: detail)
                .frame(maxHeight: .infinity)
        }
        .background(theme.palette.workspace)
    }

    private var emptyTitle: String {
        switch title {
        case "Calendar": "No calendar items yet"
        case "Cron Jobs": "No scheduled jobs"
        default: "No library items yet"
        }
    }

    private var utilitySubtitle: String {
        switch title {
        case "Calendar": "Events, reminders, and scheduled agent work."
        case "Cron Jobs": "Scheduled jobs and cron deliveries across agents."
        default: "Files and images shared across conversations."
        }
    }

}

private struct DashboardConversationEmptyState: View {
    let icon: DashboardLucideGlyph
    let title: String
    let detail: String
    var loading = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(DashboardPalette.primary)
                    .frame(width: 56, height: 56)
                    .shadow(color: DashboardPalette.primary.opacity(0.30), radius: 15, y: 8)
                if loading {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    DashboardLucideIcon(glyph: icon, size: 22)
                        .foregroundStyle(.white)
                }
            }
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DashboardPalette.foreground)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

private struct DashboardInlineError: View {
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            DashboardLucideIcon(glyph: .alertCircle, size: 15)
            Text(text).lineLimit(3)
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(DashboardPalette.danger)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(DashboardPalette.danger.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
    }
}

private struct DashboardRevealRailButton: View {
    enum Side { case left, right }
    let side: Side
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DashboardLucideIcon(glyph: side == .left ? .panelLeftOpen : .panelRightOpen, size: 16)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(DashboardFloatingButtonStyle())
        .help(side == .left ? "Show agents" : "Show workspace")
    }
}

private struct DashboardFolderNamePopover: View {
    let title: String
    let actionTitle: String
    @Binding var name: String
    let onCancel: () -> Void
    let onCommit: () -> Void
    @FocusState private var nameFocused: Bool

    private var canCommit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit {
                    if canCommit { onCommit() }
                }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(16)
        .frame(width: 280)
        .task { nameFocused = true }
    }
}

private struct DashboardNewArtifactButton: View {
    @Environment(\.dashboardTheme) private var theme
    @State private var hovered = false
    var hoverID = "action:new-note"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                DashboardLucideIcon(glyph: .fileText, size: 13)
                    .foregroundStyle(DashboardPalette.foreground)
                    .frame(width: 15, height: 15)
                Text("New note")
                    .lineLimit(1)
                Spacer()
            }
            .font(.system(size: 13))
            .foregroundStyle(DashboardPalette.foreground)
            .padding(.horizontal, 12)
            .frame(height: DashboardMetrics.rowHeight)
            .background(
                hovered ? theme.palette.themeSoft : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(DashboardRailButtonStyle())
        .dashboardScrollAwareHover($hovered, token: hoverID)
        .accessibilityLabel("Create note or artifact")
    }
}

private struct DashboardRailRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    let icon: DashboardLucideGlyph
    var harnessLogo: DashboardHarnessLogo? = nil
    let title: String
    let hoverID: String
    var trailing: String? = nil
    var showsPin = false
    var selected = false
    var isRunningConversation = false
    var iconColor: Color? = nil
    var pinMenuTitle: String? = nil
    var onTogglePin: (() -> Void)? = nil
    var moveUpTitle: String? = nil
    var moveUpEnabled = true
    var onMoveUp: (() -> Void)? = nil
    var moveDownTitle: String? = nil
    var moveDownEnabled = true
    var onMoveDown: (() -> Void)? = nil
    var renameMenuTitle: String? = nil
    var onRename: (() -> Void)? = nil
    var exportMenuTitle: String? = nil
    var onExport: (() -> Void)? = nil
    var destructiveMenuTitle: String? = nil
    var onDelete: (() -> Void)? = nil
    let action: () -> Void

    private var hasContextMenu: Bool {
        onTogglePin != nil || onMoveUp != nil || onMoveDown != nil
            || onRename != nil || onExport != nil || onDelete != nil
    }

    var body: some View {
        let activityPresentation = ConversationActivityPresentation.resolve(
            isRunning: isRunningConversation,
            reduceMotion: reduceMotion
        )
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let harnessLogo {
                        DashboardHarnessLogoIcon(logo: harnessLogo, size: 15)
                    } else {
                        DashboardLucideIcon(glyph: icon, size: 13)
                            .foregroundStyle(iconColor ?? DashboardPalette.foreground)
                    }
                }
                .frame(width: 15, height: 15)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showsPin {
                    DashboardLucideIcon(glyph: .pin, size: 11)
                        .foregroundStyle(DashboardPalette.primary)
                        .accessibilityLabel("Pinned")
                }
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }
            }
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .foregroundStyle(DashboardPalette.foreground)
            .padding(.horizontal, 12)
            .frame(height: DashboardMetrics.rowHeight)
            .background {
                DashboardActiveConversationRowBackground(
                    presentation: activityPresentation,
                    selected: selected,
                    hovered: hovered,
                    cornerRadius: 8
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(DashboardRailButtonStyle())
        .dashboardScrollAwareHover($hovered, token: hoverID)
        .contextMenu {
            if hasContextMenu {
                if let pinMenuTitle, let onTogglePin {
                    Button(pinMenuTitle, action: onTogglePin)
                }
                if let moveUpTitle, let onMoveUp {
                    Button(action: onMoveUp) {
                        Label {
                            Text(moveUpTitle)
                        } icon: {
                            DashboardLucideIcon(glyph: .arrowUp, size: 12)
                        }
                    }
                    .disabled(!moveUpEnabled)
                }
                if let moveDownTitle, let onMoveDown {
                    Button(action: onMoveDown) {
                        Label {
                            Text(moveDownTitle)
                        } icon: {
                            DashboardLucideIcon(glyph: .arrowDown, size: 12)
                        }
                    }
                    .disabled(!moveDownEnabled)
                }
                if let renameMenuTitle, let onRename {
                    Button(renameMenuTitle, action: onRename)
                }
                if let exportMenuTitle, let onExport {
                    Divider()
                    Button(exportMenuTitle, action: onExport)
                }
                if let destructiveMenuTitle, let onDelete {
                    Divider()
                    Button(destructiveMenuTitle, role: .destructive, action: onDelete)
                }
            }
        }
    }
}

private struct DashboardDisclosureHeading: View {
    let title: String
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                DashboardLucideIcon(glyph: .chevronDown, size: 12)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DashboardPalette.mutedForeground)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DashboardListSectionHeader: View {
    let title: String
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                DashboardLucideIcon(glyph: .chevronDown, size: 12)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                Spacer()
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DashboardPalette.mutedForeground)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DashboardEmptyListRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(DashboardPalette.mutedForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}

private struct DashboardConversationRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var hoverCardTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    let presentation: DashboardConversationRowPresentation
    let selected: Bool
    let isRunning: Bool
    @Binding var detailCardState: DashboardConversationDetailCardState
    let folders: [WorkspaceFolderRecord]
    let onMoveConversation: (String, String?) -> Void
    let onUnavailableMutation: (String) -> Void
    let action: () -> Void

    var body: some View {
        let conversation = presentation.conversation
        let activityPresentation = ConversationActivityPresentation.resolve(
            isRunning: isRunning,
            reduceMotion: reduceMotion
        )
        let meta = presentation.meta
        let accessibility = DashboardConversationRowAccessibility.resolve(
            conversation: conversation,
            title: presentation.title,
            meta: meta,
            preview: presentation.preview,
            time: presentation.time
        )

        // AppKit focuses a Button on mouse-down. Keep the popover state stable
        // until this native action receives the matching mouse-up.
        Button {
            action()
            detailCardState.completePrimaryAction(
                conversationID: conversation.id,
                hovered: hovered
            )
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(presentation.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(DashboardPalette.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if conversation.unread {
                        Circle()
                            .fill(DashboardPalette.primary)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("Unread")
                    }
                    Text(presentation.time)
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .monospacedDigit()
                }
                HStack(spacing: 5) {
                    Group {
                        if let harnessLogo {
                            DashboardHarnessLogoIcon(logo: harnessLogo, size: 13)
                        } else {
                            DashboardLucideIcon(glyph: agentGlyph, size: 12)
                                .foregroundStyle(
                                    DashboardPalette.mutedForeground.opacity(0.95)
                                )
                        }
                    }
                    .frame(width: 13, height: 13)
                    Text(meta.agentLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground.opacity(0.95))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 54)
            .background {
                DashboardActiveConversationRowBackground(
                    presentation: activityPresentation,
                    selected: selected,
                    hovered: hovered,
                    cornerRadius: DashboardMetrics.controlRadius
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(DashboardRailButtonStyle())
        .focused($focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
        .accessibilityHint(accessibility.hint)
        .dashboardScrollAwareHover($hovered, token: "conversation:\(conversation.id)")
        .onChange(of: hovered) { _, isHovered in
            hoverCardTask?.cancel()
            if isHovered {
                hoverCardTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(380))
                    guard !Task.isCancelled, hovered, !Self.isMouseButtonPressed else { return }
                    detailCardState.setHovered(true, conversationID: conversation.id)
                }
            } else if !Self.isMouseButtonPressed {
                detailCardState.setHovered(false, conversationID: conversation.id)
            }
        }
        .onChange(of: focused) { _, isFocused in
            guard !Self.isMouseButtonPressed else { return }
            detailCardState.setFocused(isFocused, conversationID: conversation.id)
        }
        .popover(isPresented: detailCardPresented, arrowEdge: .trailing) {
            DashboardConversationHoverCard(presentation: presentation)
        }
        .contextMenu {
            Button(conversation.isPinned ? "Unpin" : "Pin") { onUnavailableMutation("Conversation pinning") }
            Button("Rename") { onUnavailableMutation("Conversation renaming") }
            Menu("Move to Folder") {
                moveTargetRow(title: "Workspace", folderID: nil, conversation: conversation)
                ForEach(folders) { folder in
                    moveTargetRow(title: folder.name, folderID: folder.id, conversation: conversation)
                }
            }
            Divider()
            Button("Export messages") { onUnavailableMutation("Conversation export") }
            Button("Export full run") { onUnavailableMutation("Conversation export") }
            Divider()
            Button("Move to Trash", role: .destructive) { onUnavailableMutation("Conversation trash management") }
        }
        .onDisappear {
            hoverCardTask?.cancel()
            detailCardState.remove(conversationID: conversation.id)
        }
    }

    private var agentGlyph: DashboardLucideGlyph {
        if let agent = presentation.agent {
            return dashboardAgentGlyph(agent)
        }
        return presentation.conversation.localRuntimeKind == nil ? .bot : .terminal
    }

    private static var isMouseButtonPressed: Bool {
        NSEvent.pressedMouseButtons != 0
    }

    private var harnessLogo: DashboardHarnessLogo? {
        if let agent = presentation.agent {
            return DashboardHarnessLogo(runtimeKind: agent.runtimeKind)
        }
        return presentation.conversation.localRuntimeKind.map {
            DashboardHarnessLogo(runtimeKind: $0)
        }
    }

    private var detailCardPresented: Binding<Bool> {
        Binding(
            get: {
                detailCardState.presentedConversationID == presentation.id
            },
            set: { presented in
                if !presented {
                    detailCardState.dismiss()
                }
            }
        )
    }

    private func moveTargetRow(
        title: String,
        folderID: String?,
        conversation: WorkspaceConversationRecord
    ) -> some View {
        let isCurrent = conversation.folderID == folderID
        return Button {
            onMoveConversation(conversation.id, folderID)
        } label: {
            if isCurrent {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .disabled(isCurrent)
    }
}

/// Hover pop-out for a workspace chat row — folder, agent, runtime (not git/device).
private struct DashboardConversationHoverCard: View {
    let presentation: DashboardConversationRowPresentation

    var body: some View {
        let meta = presentation.meta
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DashboardPalette.foreground)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                hoverRow(icon: .folder, text: meta.folderLabel)
                hoverRow(icon: .bot, text: meta.agentLabel)
                if let runtime = meta.runtimeLabel {
                    hoverRow(
                        icon: .terminal,
                        harnessLogo: meta.runtimeKind.map {
                            DashboardHarnessLogo(runtimeKind: $0)
                        },
                        text: runtime
                    )
                }
                hoverRow(icon: meta.locationKind.glyph, text: meta.locationLabel)
                if let workspace = meta.buzzWorkspaceLabel {
                    hoverRow(icon: .panelTop, text: workspace)
                }
            }

            if !presentation.preview.isEmpty {
                Divider().opacity(0.35)
                Text(presentation.preview)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(presentation.time)
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardPalette.mutedForeground.opacity(0.9))
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }

    private func hoverRow(
        icon: DashboardLucideGlyph,
        harnessLogo: DashboardHarnessLogo? = nil,
        text: String
    ) -> some View {
        HStack(spacing: 8) {
            Group {
                if let harnessLogo {
                    DashboardHarnessLogoIcon(logo: harnessLogo, size: 14)
                } else {
                    DashboardLucideIcon(glyph: icon, size: 13)
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }
            }
            .frame(width: 14, height: 14)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(DashboardPalette.foreground.opacity(0.92))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

private struct DashboardNoteRow: View {
    @Environment(\.dashboardTheme) private var theme
    @State private var hovered = false
    let presentation: DashboardNoteRowPresentation
    let selected: Bool
    let onUnavailableMutation: (String) -> Void
    let action: () -> Void

    var body: some View {
        let note = presentation.note

        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    switch presentation.kind {
                    case .note:
                        DashboardLucideIcon(glyph: .fileText, size: 18)
                    case .spreadsheet:
                        Image(systemName: "tablecells")
                            .font(.system(size: 15, weight: .medium))
                    case .html:
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .foregroundStyle(note.isPinned ? DashboardPalette.primary : DashboardPalette.foreground)
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                    Text(presentation.preview)
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(
                selected ? theme.palette.themeStrong : hovered ? theme.palette.themeSoft : .clear,
                in: RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(DashboardRailButtonStyle())
        .dashboardScrollAwareHover($hovered, token: "note:\(note.id)")
        .contextMenu {
            Button(note.isPinned ? "Unpin" : "Pin") { onUnavailableMutation("Note pinning") }
            Button("Rename") { onUnavailableMutation("Note renaming") }
            Button("Move to folder…") { onUnavailableMutation("Note moving") }
            Divider()
            Button("Export note") { onUnavailableMutation("Note export") }
            Button("Move to Trash", role: .destructive) { onUnavailableMutation("Note trash management") }
        }
    }
}

private struct DashboardRailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct DashboardScrollAwareHoverModifier: ViewModifier {
    @Environment(\.dashboardScrollHoverCoordinator) private var coordinator
    @Binding var hovered: Bool
    let token: String

    func body(content: Content) -> some View {
        content
            .onHover { next in
                coordinator.recordHover(next, token: token) { next in
                    if hovered != next {
                        hovered = next
                    }
                }
            }
            .onDisappear {
                coordinator.unregister(token: token)
            }
    }
}

private extension View {
    func dashboardScrollAwareHover(_ hovered: Binding<Bool>, token: String) -> some View {
        modifier(DashboardScrollAwareHoverModifier(hovered: hovered, token: token))
    }
}

struct DashboardIconButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                isEnabled
                    ? DashboardPalette.mutedForeground
                    : DashboardPalette.mutedForeground.opacity(0.68)
            )
            .background(
                isEnabled && (configuration.isPressed || hovered)
                    ? theme.palette.themeSoft
                    : .clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovered = $0 }
    }
}

private struct DashboardFloatingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DashboardPalette.mutedForeground)
            .background(DashboardPalette.background.opacity(configuration.isPressed ? 0.95 : 0.75))
            .clipShape(Circle())
            .overlay { Circle().stroke(DashboardPalette.foreground.opacity(0.04), lineWidth: 1) }
            .shadow(color: DashboardPalette.foreground.opacity(0.05), radius: 2, y: 1)
    }
}

private struct DashboardPillButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DashboardPalette.mutedForeground)
            .background(configuration.isPressed ? theme.palette.themeSoft : DashboardPalette.background.opacity(0.7))
            .clipShape(Capsule())
    }
}

private func dashboardAgentPresentation(_ agent: WorkspaceAgent) -> DashboardAgentPresentation {
    DashboardAgentPresentation(
        displayName: agent.displayName,
        iconKey: agent.iconKey
    )
}

private func dashboardAgentDisplayName(_ agent: WorkspaceAgent) -> String {
    dashboardAgentPresentation(agent).displayName
}

func dashboardComposerPlaceholder(
    agent: WorkspaceAgent?,
    runtimeKind: AgentRuntimeKind?
) -> String {
    let recipient = agent.map(dashboardAgentDisplayName)
        ?? runtimeKind?.displayName
        ?? "agent"
    return "Message \(recipient)…"
}

private func dashboardAgentGlyph(
    _ agent: WorkspaceAgent,
    iconKey: String? = nil
) -> DashboardLucideGlyph {
    let key = (iconKey ?? dashboardAgentPresentation(agent).iconKey).lowercased()
    switch key {
    case "monitor": return .monitor
    case "circle-user": return .circleUser
    case "user-round": return .userRound
    case "bot": return .bot
    case "cpu": return .cpu
    case "terminal": return .terminal
    case "briefcase": return .briefcase
    case "compass": return .compass
    case "flame": return .flame
    case "rocket": return .rocket
    case "sparkles": return .sparkles
    case "brain": return .brain
    default:
        if key.contains("terminal") || key.contains("codex") { return .terminal }
        if key.contains("briefcase") { return .briefcase }
        if key.contains("compass") { return .compass }
        if key.contains("flame") { return .flame }
        if key.contains("rocket") { return .rocket }
        if key.contains("spark") { return .sparkles }
        if key.contains("brain") { return .brain }
        if key.contains("user") { return .userRound }
        if key.contains("cpu") || agent.runtimeKind == .pi { return .cpu }
        return agent.executionLocation == .local ? .monitor : .bot
    }
}

private func dashboardChatWidthBounds(totalWidth: CGFloat) -> ClosedRange<Double> {
    let contentWidth = max(1, totalWidth - DashboardMetrics.separatorWidth)
    let minimum = max(
        Double(DashboardMetrics.minimumChatWidthPercent),
        Double(DashboardMetrics.chatMinimumWidth / contentWidth * 100)
    )
    let maximum = min(
        Double(DashboardMetrics.maximumChatWidthPercent),
        100 - Double(DashboardMetrics.companionMinimumWidth / contentWidth * 100)
    )
    if minimum > maximum {
        let midpoint = (minimum + maximum) / 2
        return midpoint...midpoint
    }
    return minimum...maximum
}

private func dashboardAttributedContent(_ content: String) -> AttributedString {
    guard content.range(of: "<[^>]+>", options: .regularExpression) != nil else {
        return (try? AttributedString(markdown: content)) ?? AttributedString(content)
    }
    let styledHTML = """
    <style>
      body { font-family: -apple-system; font-size: 14px; line-height: 1.6; color: #0a1f16; }
      p { margin: 0 0 12px 0; } ul, ol { margin: 0 0 12px 20px; }
      code { font-family: ui-monospace; font-size: 13px; }
    </style>
    \(content)
    """
    guard let data = styledHTML.data(using: .utf8),
          let rich = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
          ) else {
        return AttributedString(content)
    }
    return AttributedString(rich)
}

private func dashboardListPreview(_ content: String, limit: Int) -> String {
    guard limit > 0 else { return "" }

    var preview = ""
    preview.reserveCapacity(min(content.utf8.count, limit))
    var characterCount = 0
    var insideTag = false
    var pendingSpace = false

    for character in content {
        if character == "<" {
            insideTag = true
            pendingSpace = true
            continue
        }
        if insideTag {
            if character == ">" {
                insideTag = false
            }
            continue
        }
        if character.isWhitespace {
            pendingSpace = true
            continue
        }
        if pendingSpace, !preview.isEmpty {
            preview.append(" ")
            characterCount += 1
            if characterCount >= limit { break }
        }
        pendingSpace = false
        preview.append(character)
        characterCount += 1
        if characterCount >= limit { break }
    }

    return preview.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func dashboardShortTime(_ value: String?) -> String {
    guard let value, let date = dashboardParsedDate(value) else { return "" }
    if Calendar.current.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

func dashboardRunDuration(_ interval: TimeInterval) -> String {
    let milliseconds = max(0, interval * 1_000)
    if milliseconds < 1_000 {
        return "\(max(1, Int(milliseconds.rounded())))ms"
    }
    if milliseconds < 10_000 {
        let tenths = (milliseconds / 100).rounded() / 10
        return tenths >= 10 ? "10s" : String(format: "%.1fs", tenths)
    }
    if milliseconds < 60_000 {
        return "\(Int((milliseconds / 1_000).rounded()))s"
    }
    let minutes = Int(milliseconds / 60_000)
    let seconds = Int(((milliseconds.truncatingRemainder(dividingBy: 60_000)) / 1_000).rounded())
    if seconds == 0 { return "\(minutes)m" }
    if seconds == 60 { return "\(minutes + 1)m" }
    return "\(minutes)m \(seconds)s"
}

func dashboardParsedDate(_ value: String) -> Date? {
    (try? dashboardFractionalDateStyle.parse(value))
        ?? (try? dashboardDateStyle.parse(value))
}

private let dashboardFractionalDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
private let dashboardDateStyle = Date.ISO8601FormatStyle()
