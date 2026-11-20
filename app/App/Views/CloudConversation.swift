import AppKit
import SwiftUI

private struct ConversationMessageRow: Identifiable {
    let message: WorkspaceMessageRecord
    let layout: ConversationMessageLayout.Row
    var id: String { layout.id }
}

struct CloudConversation: View {
    @Environment(\.openDocumentPreview) private var openPreview
    @Environment(\.wovenTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: ApplicationModel
    let agent: WorkspaceAgent?
    let conversation: WorkspaceConversationRecord?
    let attachedNoteTitle: String?
    @Binding var draft: String
    let attachments: [AgentMessageAttachmentDraft]
    let sendInProgress: Bool
    let startsComposerCollapsed: Bool
    let usesCompactPanelSpacing: Bool
    let showsClosePanel: Bool
    let showsAddPanel: Bool
    let focusRequestGeneration: Int?
    let onActivatePanel: () -> Void
    let onClosePanel: () -> Void
    let onAddPanel: () -> Void
    let onSend: () -> Void
    let onAttachmentAction: (ComposerAttachmentAction) -> Void
    let onRemoveAttachment: (String) -> Void
    let onDropFiles: ([URL]) -> Bool
    let onCommandNavigation: (ComposerNavigationDirection) -> Bool
    /// Starts a new chat in this one's place, when its native session is gone.
    var onNewSession: (() -> Void)? = nil
    @State private var scrollState = ConversationScrollState()
    @State private var transcriptOwnsScroll = false
    @State private var isPrependingHistory = false
    @State private var pendingBottomConversationID: String?
    @State private var bottomPositionRevision = 0
    @State private var scrollPositionID: String?
    @State private var composerCollapseOverride: Bool?
    @State private var bottomStackHeight: CGFloat = 0
    @State private var scrollInteractionRevision = 0
    @State private var isUserScrolling = false
    @State private var libraryHighlightID: String?
    @State private var attachmentOpenError: String?
    @State private var choosingFolder = false
    @State private var folderSelectionError: String?

    /// The open chat's live state; nil before a chat is chosen.
    private var session: SessionStore? {
        conversation.map { model.sessions.session(for: $0.id) }
    }

    private var messages: [WorkspaceMessageRecord] { session?.messages ?? [] }

    /// Archived, or its owner is unreachable: saved items show, controls are off.
    private var isReadOnly: Bool {
        conversation?.isArchived != false || session?.isOwnerReachable != true || session?.isNativeSessionGone == true
    }

    private var interaction: SessionInteraction? {
        guard conversation?.isArchived == false else { return nil }
        return session?.interactions.first
    }

    @ViewBuilder var body: some View {
        let runsByAssistantMessageID = self.runsByAssistantMessageID
        let activitiesByRunID = self.activitiesByRunID
        let visibleMessages = self.visibleMessages
        let rows = visibleMessages.flatMap { message in
            ConversationMessageLayout.rows(messageID: message.id, role: message.role)
                .map { ConversationMessageRow(message: message, layout: $0) }
        }
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    // This is the paged message window, not the full history.
                    // Native text changes height while it streams; lazy height
                    // estimates can strand the bottom anchor in blank space
                    // before those rows are measured.
                    VStack(spacing: 0) {
                        if conversation == nil {
                            ConversationEmptyState(
                                icon: .messageSquare,
                                title: agent.map { "New conversation with \(agentDisplayName($0))" } ?? "Choose a conversation",
                                detail: agent == nil
                                    ? "Choose New chat to select an agent, or open an existing conversation."
                                    : "Choose a conversation from All Workspaces."
                            )
                        } else if visibleMessages.isEmpty {
                            ConversationEmptyState(
                                icon: conversation?.runtimeKind == nil
                                    ? (agent.map { agentIconGlyph($0) } ?? .messageSquare)
                                    : .terminal,
                                title: conversation?.title ?? "Conversation",
                                detail: conversation?.runtimeKind == nil
                                    ? "This conversation has no messages yet."
                                    : "Send a message to start this chat."
                            )
                        } else {
                            if scrollState.positionedConversationID == conversation?.id,
                               session?.hasOlderMessages == true,
                               let oldestMessageID = messages.first?.id {
                                Color.clear
                                    .frame(height: 1)
                                    .padding(.bottom, 32)
                                    .id(historyLoaderID(oldestMessageID: oldestMessageID))
                                    .accessibilityIdentifier("conversation-history-loader")
                                    .onScrollVisibilityChange(threshold: 0.01) { visible in
                                        // Eager layout must not eagerly fetch history.
                                        guard visible else { return }
                                        Task { @MainActor in
                                            await prependOlderMessages(keeping: oldestMessageID, using: proxy)
                                        }
                                    }
                            }
                            ForEach(rows) { row in
                                VStack(spacing: 0) {
                                    messageRow(row, runs: runsByAssistantMessageID, activities: activitiesByRunID)
                                }
                                .id(row.id)
                                .background(row.id == libraryHighlightID ? theme.palette.themeWhisper : Color.clear)
                                .padding(.top, row.id == rows.first?.id ? 0 : row.layout.spacingBefore)
                            }
                        }
                        Color.clear
                            .frame(height: bottomScrollClearance)
                            .padding(.top, 32)
                            .id(chatEndID)
                    }
                    .frame(maxWidth: 768)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .scrollTargetLayout()
                }
                .scrollIndicators(.never)
                .task(id: [model.navigation.libraryMessageTarget?.id, conversation?.id]) {
                    await scrollToLibraryMessage(using: proxy)
                }
                .debugRequest("scroll-top") {
                    guard let first = rows.first?.id else { return }
                    transcriptOwnsScroll = true
                    scrollState.setNearBottom(false)
                    scrollWithoutAnimation(proxy, to: first, anchor: .top)
                }
                .environment(\.conversationTranscriptInteraction) {
                    transcriptOwnsScroll = true
                    scrollInteractionRevision += 1
                    bottomPositionRevision += 1
                    pendingBottomConversationID = nil
                    scrollPositionID = nil
                    scrollState.setNearBottom(false)
                }
                .environment(\.conversationActivityDetails) { runID, activityID in
                    guard let session else { return nil }
                    return try await session.activityDetails(runID: runID, activityID: activityID)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                // Following the latest reply, growth keeps the bottom in place
                // in the same layout pass; a later scroll would show each
                // chunk below the edge for a frame and then jump.
                .defaultScrollAnchor(followsBottom ? .bottom : .top, for: .sizeChanges)
                .scrollPosition(id: $scrollPositionID, anchor: .bottom)
                .onScrollPhaseChange { _, phase in
                    isUserScrolling = phase == .interacting || phase == .tracking || phase == .decelerating
                    if isUserScrolling {
                        transcriptOwnsScroll = false
                        scrollInteractionRevision += 1
                        pendingBottomConversationID = nil
                        bottomPositionRevision += 1
                    }
                }
                .onScrollGeometryChange(for: ConversationGeometry.self) { geometry in
                    ConversationGeometry(
                        contentHeight: geometry.contentSize.height,
                        isNearBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 80
                    )
                } action: { oldGeometry, newGeometry in
                    geometryChanged(from: oldGeometry, to: newGeometry, using: proxy)
                }
                .onChange(of: conversation?.id, initial: true) { _, conversationID in
                    conversationChanged(to: conversationID)
                }
                .onChange(of: newestPresentedMessageIdentity, initial: true) { _, identity in
                    newestMessageChanged(to: identity, hasMessages: !visibleMessages.isEmpty, using: proxy)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !scrollState.isNearBottom, conversation != nil {
                        Button("Latest reply", systemImage: "arrow.down") {
                            scrollInteractionRevision += 1
                            transcriptOwnsScroll = false
                            scrollState.setNearBottom(true)
                            scrollToConversationBottom(using: proxy)
                        }
                        .buttonStyle(WovenQuietButtonStyle())
                        .padding(.trailing, 32)
                        .padding(.bottom, bottomScrollClearance)
                    }
                }
            }
            .simultaneousGesture(TapGesture().onEnded(onActivatePanel))

            bottomStack
                .frame(maxWidth: .infinity)
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
        .environment(\.conversationTranscriptState, session?.transcriptState)
        .environment(\.conversationTaskProgress, interaction == nil ? session?.taskProgress : nil)
        .onChange(of: interaction?.id) { _, _ in session?.transcriptState.tasksExpanded = false }
        .alert("Could not open attachment", isPresented: Binding(
            get: { attachmentOpenError != nil },
            set: { if !$0 { attachmentOpenError = nil } }
        )) {
            Button("OK", role: .cancel) { attachmentOpenError = nil }
        } message: {
            Text(attachmentOpenError ?? "")
        }
    }

    @ViewBuilder
    private func messageRow(
        _ fragment: ConversationMessageRow,
        runs: [String: WorkspaceRunRecord],
        activities: [String: [WorkspaceRunActivityRecord]]
    ) -> some View {
        let message = fragment.message
        let presentation = session?.messagePresentations[message.id]
        let run = runs[message.id]
        MessageRow(
            message: message,
            renderedDocument: presentation?.document,
            run: run.flatMap { $0.status == .queued ? nil : $0 },
            runPresentation: run.flatMap { session?.runPresentations[$0.id] },
            activities: run.map { activities[$0.id] ?? [] } ?? [],
            onOpenAttachment: openAttachment,
            resolveFile: { source in
                try await model.library.fileURL(id: WorkspaceLibraryItem.identifier(messageID: message.libraryItemID, source: source))
            },
            layout: fragment.layout,
            displayedBody: presentation?.displayedBody,
            commentaryIDs: presentation?.commentaryIDs,
            workTimeline: presentation?.workTimeline,
            streaming: presentation?.isStreaming,
            onNewSession: message.id == session?.goneNoticeID && conversation?.isArchived == false ? onNewSession : nil
        )
    }

    // MARK: Bottom stack

    private var bottomStack: some View {
        VStack(spacing: 8) {
            if conversation?.isArchived == true {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Archived History", systemImage: "archivebox")
                        .font(.system(size: 12, weight: .semibold))
                    Text("This chat is readable but cannot be resumed. Start a new chat to continue.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(WovenPalette.mutedForeground)
                }
                .frame(maxWidth: 768, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            if let error = session?.error {
                InlineError(text: error)
                    .frame(maxWidth: 768)
            }
            if let interaction, let session {
                SessionInteractionCard(interaction: interaction) { response in
                    Task { await session.answer(interaction.id, with: response) }
                }
                .disabled(!session.isOwnerReachable)
                .id(interaction.id)
            }
            // Side buttons sit on the composer's bottom control row; the
            // composer grows upward with its draft and Tasks badge.
            HStack(alignment: .bottom, spacing: 8) {
                leadingPanelControl
                    .padding(.bottom, ConversationComposer.verticalPadding)
                VStack(spacing: 8) {
                    notices
                    composer
                }
                trailingPanelControl
                    .padding(.bottom, ConversationComposer.verticalPadding)
            }
            // Animate the whole row so the outside buttons follow the
            // composer height in the same layout transaction.
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.15),
                value: composerCollapseOverride ?? startsComposerCollapsed
            )
        }
    }

    @ViewBuilder
    private var leadingPanelControl: some View {
        if showsClosePanel {
            PanelControlButton(
                glyph: .panelRightOpen,
                accessibilityLabel: "Remove panel",
                help: "Remove panel",
                action: onClosePanel
            )
        } else if let conversation, !conversation.isArchived, conversation.runtimeKind == .defaultAgent {
            PanelControlButton(
                glyph: .settings,
                accessibilityLabel: "Pi Durable settings",
                help: "Pi Durable settings"
            ) {
                model.navigation.pendingDefaultAgentSettingsScope = conversation.machineID
            }
        } else if showsAddPanel {
            Color.clear
                .frame(width: PanelControlButton.size, height: PanelControlButton.size)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var trailingPanelControl: some View {
        if showsAddPanel {
            PanelControlButton(
                glyph: .panelLeftOpen,
                accessibilityLabel: "Add panel",
                help: "Add panel",
                action: onAddPanel
            )
        } else if showsClosePanel {
            Color.clear
                .frame(width: PanelControlButton.size, height: PanelControlButton.size)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let conversation, let notice = model.macAccessNotice(for: conversation) {
            MacAccessNotice(message: notice, openSettings: { model.navigation.pendingConnectionsScope = "permissions" })
        }
        if let conversation, !conversation.isArchived, session?.isOwnerReachable == false {
            // Its saved history shows; controls return when its owner reconnects.
            MacAccessNotice(message: "\(model.machines.machine(id: conversation.machineID)?.name ?? "Its machine") is not connected. Woven Matter reconnects automatically.",
                openSettings: nil)
                .accessibilityIdentifier("remote-conversation-offline")
        }
        if let conversation, !conversation.isArchived, conversation.runtimeKind == .defaultAgent,
           session?.settings?.selectableModels.isEmpty == true {
            Button {
                model.navigation.pendingDefaultAgentSettingsScope =
                    model.connections.settings.machines[conversation.machineID] == nil ? "global" : conversation.machineID
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("No models configured for Pi Durable. Go to settings to complete setup.")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 12, minimumHeight: 32))
            .background(theme.palette.themeWhisper,
                in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
            .help("Open Pi Durable settings")
        }
        if let conversation, !conversation.isArchived, WorkspaceGoal.supports(conversation.runtimeKind),
           let session, session.goal != nil {
            ConversationGoalControls(session: session)
                .disabled(!session.isOwnerReachable)
        }
    }

    private var composer: some View {
        let hasRuntime = conversation.map { !$0.isArchived && $0.runtimeKind != nil } ?? false
        let settingsBusy = session?.isUpdatingSettings ?? false
        return ConversationComposer(
            placeholder: composerPlaceholder(agent: agent, runtimeKind: conversation?.runtimeKind),
            draft: $draft,
            attachedNoteTitle: attachedNoteTitle,
            attachments: attachments,
            agentTools: conversation == nil ? nil : model.agentTools,
            sessionID: conversation?.id,
            supportsGoals: WorkspaceGoal.supports(conversation?.runtimeKind),
            showsSessionControls: hasRuntime,
            showsPermissionControl: hasRuntime,
            sessionMetadataLoading: hasRuntime && session?.settings == nil,
            sessionMetadata: hasRuntime ? session?.settings : nil,
            sessionControlsDisabled: !hasRuntime || isReadOnly || settingsBusy || session?.isRunning == true,
            sendDisabled: sendInProgress || (conversation != nil && (isReadOnly || !hasRuntime || settingsBusy)),
            startsCollapsed: startsComposerCollapsed,
            collapseOverride: $composerCollapseOverride,
            focusRequestGeneration: focusRequestGeneration,
            onActivate: onActivatePanel,
            onSelectModel: { selection in updateSettings(SessionSettingsChange(model: selection)) },
            onSelectThinking: { selection in updateSettings(SessionSettingsChange(thinking: selection)) },
            onSelectPermission: { selection in updateSettings(SessionSettingsChange(permission: selection)) },
            onAttachmentAction: onAttachmentAction,
            onRemoveAttachment: onRemoveAttachment,
            onOpenAttachment: { file in
                openAttachment(contentHash: file.contentHash, fileName: file.fileName, mimeType: file.mimeType)
            },
            onDropFiles: { urls in
                guard conversation?.isArchived != true else { return false }
                return onDropFiles(urls)
            },
            onCommandNavigation: onCommandNavigation,
            onSend: {
                guard conversation?.isArchived != true else { return }
                transcriptOwnsScroll = false
                isUserScrolling = false
                scrollInteractionRevision += 1
                scrollState.setNearBottom(true)
                scrollPositionID = chatEndID
                onSend()
            },
            onStop: session.flatMap { session in
                guard !isReadOnly, session.isRunning else { return nil }
                return { Task { await session.stop() } }
            },
            folderLabel: conversation.map { current in
                model.workspace.folder(id: current.folderID)?.name ?? "All Workspaces"
            },
            availableFolders: conversation.map { model.workspace.folders(on: $0.machineID) } ?? [],
            selectedFolderID: conversation?.folderID,
            folderMachineID: conversation?.machineID,
            folderSelectionDisabled: isReadOnly || choosingFolder || sendInProgress || session?.hasUserMessage != false,
            onSelectFolder: { folderID in
                guard let session, !isReadOnly, !choosingFolder else { return }
                choosingFolder = true
                folderSelectionError = nil
                Task {
                    do { try await session.chooseFolder(folderID) }
                    catch { folderSelectionError = error.localizedDescription }
                    choosingFolder = false
                }
            }
        )
        .disabled(conversation?.isArchived == true)
        .alert("Folder could not be changed", isPresented: Binding(
            get: { folderSelectionError != nil },
            set: { if !$0 { folderSelectionError = nil } }
        )) { Button("OK") { folderSelectionError = nil } } message: {
            Text(folderSelectionError ?? "")
        }
    }

    private func updateSettings(_ change: SessionSettingsChange) {
        guard let session, !isReadOnly else { return }
        Task { await session.updateSettings(change) }
    }

    private func openAttachment(_ attachment: SessionMessageAttachment) {
        openAttachment(contentHash: attachment.contentHash, fileName: attachment.fileName, mimeType: attachment.mimeType)
    }

    /// Opens a message file, fetched by its content the first time.
    private func openAttachment(contentHash: String?, fileName: String, mimeType: String) {
        guard let contentHash else {
            attachmentOpenError = "This attachment is not available on this Mac."
            return
        }
        Task {
            do {
                let url = try await model.library.attachmentURL(contentHash: contentHash, fileName: fileName, mimeType: mimeType)
                openPreview?(url, nil)
            } catch { attachmentOpenError = error.localizedDescription }
        }
    }

    // MARK: Transcript

    /// The reader is at the live edge and nothing else owns the scroll.
    private var followsBottom: Bool {
        scrollState.isNearBottom && !transcriptOwnsScroll && !isUserScrolling && !isPrependingHistory
            && model.navigation.libraryMessageTarget?.conversationID != conversation?.id
    }

    private var chatEndID: String {
        "chat-end:\(conversation?.id ?? "none")"
    }

    private var bottomScrollClearance: CGFloat {
        CGFloat(ConversationBottomOverlayLayout.scrollClearance(stackHeight: Double(bottomStackHeight)))
    }

    private var runsByAssistantMessageID: [String: WorkspaceRunRecord] {
        (session?.runs ?? []).reduce(into: [:]) {
            if let assistantMessageID = $1.assistantMessageID {
                $0[assistantMessageID] = $1
            }
        }
    }

    private var activitiesByRunID: [String: [WorkspaceRunActivityRecord]] {
        Dictionary(grouping: session?.runActivities ?? [], by: \.runID)
    }

    /// An empty reply to a run that has not started yet is not shown.
    private var visibleMessages: [WorkspaceMessageRecord] {
        let runs = runsByAssistantMessageID
        return messages.filter { message in
            message.role != .assistant || !message.content.isEmpty || runs[message.id]?.status != .queued
        }
    }

    private var newestPresentedMessageIdentity: String? {
        guard let conversation,
              let message = visibleMessages.last,
              let presentation = session?.messagePresentations[message.id],
              presentation.source == message.content else { return nil }
        return [
            conversation.id,
            message.id,
            String(describing: message.status),
            String(message.content.utf8.count)
        ].joined(separator: ":")
    }

    private func historyLoaderID(oldestMessageID: String) -> String {
        "chat-history:\(conversation?.id ?? "none"):\(oldestMessageID)"
    }

    private func conversationChanged(to conversationID: String?) {
        session?.transcriptState.tasksExpanded = false
        isUserScrolling = false
        let targetsLibraryMessage = model.navigation.libraryMessageTarget?.conversationID == conversationID
        transcriptOwnsScroll = targetsLibraryMessage
        scrollInteractionRevision += 1
        scrollState.conversationChanged(to: conversationID)
        if transcriptOwnsScroll { scrollState.setNearBottom(false) }
        pendingBottomConversationID = targetsLibraryMessage ? nil : conversationID
        bottomPositionRevision += 1
        scrollPositionID = nil
    }

    private func geometryChanged(from oldGeometry: ConversationGeometry, to newGeometry: ConversationGeometry,
                                 using proxy: ScrollViewProxy) {
        let followedBottomBeforeGrowth = oldGeometry.contentHeight != newGeometry.contentHeight
            && scrollState.isNearBottom && !isUserScrolling && !isPrependingHistory
            && model.navigation.libraryMessageTarget?.conversationID != conversation?.id
        let isPositioningConversation = pendingBottomConversationID == conversation?.id
            && newestPresentedMessageIdentity != nil
        scrollState.setNearBottom(newGeometry.isNearBottom && !transcriptOwnsScroll)

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
            let interactionRevision = scrollInteractionRevision
            let owner = conversation?.id
            Task { @MainActor in
                await Task.yield()
                guard interactionRevision == scrollInteractionRevision,
                      owner == conversation?.id, !isPrependingHistory else { return }
                scrollToConversationBottom(using: proxy)
            }
        }
    }

    private func newestMessageChanged(to identity: String?, hasMessages: Bool, using proxy: ScrollViewProxy) {
        guard identity != nil, model.navigation.libraryMessageTarget?.conversationID != conversation?.id else { return }
        let action = scrollState.contentChanged(
            conversationID: conversation?.id,
            hasMessages: hasMessages,
            isPrependingHistory: isPrependingHistory
        )
        switch action {
        case .none:
            break
        case .jumpToBottom, .followBottom:
            let interactionRevision = scrollInteractionRevision
            let owner = conversation?.id
            Task { @MainActor in
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(50))
                guard identity == newestPresentedMessageIdentity,
                      owner == conversation?.id,
                      interactionRevision == scrollInteractionRevision,
                      !isPrependingHistory else { return }
                scrollToConversationBottom(using: proxy)
            }
        }
    }

    @MainActor
    private func scrollToLibraryMessage(using proxy: ScrollViewProxy) async {
        guard let item = model.navigation.libraryMessageTarget, item.conversationID == conversation?.id,
              let session else { return }
        pendingBottomConversationID = nil
        bottomPositionRevision += 1
        scrollInteractionRevision += 1
        transcriptOwnsScroll = true
        scrollState.setNearBottom(false)
        await session.refresh()
        while !Task.isCancelled, !session.messages.contains(where: { $0.shows(item.messageID) }) {
            if session.isLoadingOlderMessages {
                try? await Task.sleep(for: .milliseconds(25))
                continue
            }
            guard await session.loadOlderMessages() else { break }
        }
        guard !Task.isCancelled, conversation?.id == item.conversationID else { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled, model.navigation.libraryMessageTarget?.id == item.id,
              conversation?.id == item.conversationID else { return }
        // A run's reply shows several of its items.
        guard let shownID = session.messages.first(where: { $0.shows(item.messageID) })?.id else {
            session.setError("This source message is no longer available.")
            model.navigation.libraryMessageTarget = nil
            return
        }
        libraryHighlightID = shownID
        scrollState.sourceMessagePositioned(in: item.conversationID)
        scrollPositionID = nil
        scrollWithoutAnimation(proxy, to: shownID, anchor: .top)
        pendingBottomConversationID = nil
        try? await Task.sleep(for: .seconds(2))
        if libraryHighlightID == shownID { libraryHighlightID = nil }
        if !Task.isCancelled, model.navigation.libraryMessageTarget?.id == item.id {
            model.navigation.libraryMessageTarget = nil
        }
    }

    @MainActor
    private func prependOlderMessages(keeping anchorMessageID: String, using proxy: ScrollViewProxy) async {
        guard let session, !isPrependingHistory else { return }
        isPrependingHistory = true
        let loaded = await session.loadOlderMessages()
        if loaded, !Task.isCancelled {
            await Task.yield()
            await Task.yield()
            scrollWithoutAnimation(proxy, to: anchorMessageID, anchor: .top)
        }
        isPrependingHistory = false
    }

    private func scrollWithoutAnimation(_ proxy: ScrollViewProxy, to id: some Hashable, anchor: UnitPoint) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

    private func scrollToConversationBottom(using proxy: ScrollViewProxy) {
        scrollPositionID = chatEndID
        scrollWithoutAnimation(proxy, to: chatEndID, anchor: .bottom)
    }
}

func nonemptyString(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else { return nil }
    return trimmed
}

struct MessageRow: View {
    let message: WorkspaceMessageRecord
    let renderedDocument: ConversationMarkdownDocument?
    let run: WorkspaceRunRecord?
    let runPresentation: RunPresentation?
    let activities: [WorkspaceRunActivityRecord]
    let onOpenAttachment: (SessionMessageAttachment) -> Void
    let resolveFile: (String) async throws -> URL
    let layout: ConversationMessageLayout.Row
    var displayedBody: String? = nil
    var commentaryIDs: Set<String>? = nil
    var workTimeline: ConversationWorkTimeline? = nil
    var streaming: Bool? = nil
    var onNewSession: (() -> Void)? = nil

    private var isStreaming: Bool {
        streaming ?? AssistantStreamingText.isStreaming(messageStatus: message.status, runStatus: run?.status)
    }
    private var assistantBody: String {
        displayedBody ?? (isStreaming ? AssistantStreamingText.readyPrefix(of: transcript.body) : transcript.body)
    }

    /// Fallback for a row without a prepared presentation.
    private var transcript: (body: String, commentaryIDs: Set<String>) {
        let work = activities.map(\.activity)
        return ConversationWorkTimeline.displayPartition(
            AssistantTranscriptProjection(messageID: message.id, content: message.content, activities: work),
            activities: work)
    }

    var body: some View {
        if message.role == .system {
            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                Text(message.content)
                    .lineLimit(1)
                if let onNewSession {
                    Button("New Chat", action: onNewSession)
                        .buttonStyle(WovenQuietButtonStyle())
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(WovenPalette.mutedForeground)
        } else if layout.content == .fileChanges {
            HStack {
                ConversationChangedFilesCard(records: activities, topSpacing: {
                    if showsAssistantBody { return 18 }
                    guard let run else { return 0 }
                    return ConversationWorkTranscript.hasVisibleContent(run: run, timeline: projectedTimeline) ? 18 : 0
                })
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            let isUser = message.role == .user
            HStack {
                if isUser { Spacer(minLength: 72) }
                VStack(alignment: isUser ? .trailing : .leading, spacing: 18) {
                    if !isUser, let run {
                        ConversationWorkTranscript(
                            run: run,
                            presentation: runPresentation,
                            records: activities,
                            commentaryIDs: commentaryIDs ?? transcript.commentaryIDs,
                            hasFollowingResponse: !assistantBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            timeline: projectedTimeline
                        )
                    }
                    if isUser {
                        WorkspaceIncomingAgentHeader(message: message)
                        ConversationUserMessage(
                            content: message.senderKind == .goal ? "Continuing toward the goal." : message.content,
                            attachments: message.attachments,
                            references: message.references,
                            onOpenAttachment: onOpenAttachment
                        )
                    } else if showsAssistantBody {
                        ConversationResponse(
                            content: assistantBody,
                            document: renderedDocument,
                            isStreaming: isStreaming
                        )
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        if !isStreaming {
                            ConversationFilePreviews(content: assistantBody, messageID: message.libraryItemID, resolveFile: resolveFile)
                        }
                    }
                }
                .frame(maxWidth: isUser ? nil : .infinity, alignment: isUser ? .trailing : .leading)
                if !isUser { Spacer(minLength: 0) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var showsAssistantBody: Bool {
        ConversationMessageLayout.showsAssistantBody(
            content: message.content,
            displayedBody: assistantBody,
            failedRunError: run?.status == .failed ? run?.error : nil
        )
    }

    private var projectedTimeline: ConversationWorkTimeline {
        workTimeline ?? ConversationWorkTimeline(records: activities,
            commentaryIDs: commentaryIDs ?? transcript.commentaryIDs)
    }
}

struct ConversationUserMessage: View {
    let content: String
    let attachments: [SessionMessageAttachment]
    let references: [SessionMessageReference]
    var onOpenAttachment: ((SessionMessageAttachment) -> Void)? = nil
    var body: some View {
        ConversationUserBubble(content: content, hasAttachments: !attachments.isEmpty || !references.isEmpty) {
            if !attachments.isEmpty || !references.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(attachments) { attachment in
                        Button { onOpenAttachment?(attachment) } label: {
                            PersistedAttachmentChip(
                                icon: attachment.kind == .image ? "photo" : "doc",
                                title: attachment.fileName,
                                detail: ByteCountFormatter.string(
                                    fromByteCount: attachment.sizeBytes,
                                    countStyle: .file
                                )
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(onOpenAttachment == nil)
                        .accessibilityLabel("Open \(attachment.fileName)")
                        .help("Open \(attachment.fileName)")
                    }
                    ForEach(references) { reference in
                        PersistedAttachmentChip(
                            icon: reference.kind == .note ? "note.text" : "bubble.left.and.bubble.right",
                            title: reference.title,
                            detail: reference.kind == .note ? "Note" : "Conversation"
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct PersistedAttachmentChip: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WovenPalette.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(WovenPalette.background.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// A session on a Mac that is missing a permission it needs. Full-width quiet
/// notice above the composer, matching the composer setup notices.
private struct MacAccessNotice: View {
    @Environment(\.wovenTheme) private var theme
    let message: String
    let openSettings: (() -> Void)?

    var body: some View {
        if let openSettings {
            Button(action: openSettings) { label(showsArrow: true) }
                .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 12, minimumHeight: 32))
                .background(theme.palette.themeWhisper,
                    in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
                .help("Open Settings → Permissions & Access")
        } else {
            label(showsArrow: false)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(theme.palette.themeWhisper,
                    in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
        }
    }

    private func label(showsArrow: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(WovenPalette.mutedForeground)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if showsArrow {
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}
