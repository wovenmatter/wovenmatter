import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WovenMatterClient
import WovenMatterCore

enum DashboardConversationScrollAction: Equatable {
    case none
    case jumpToBottom
    case followBottom
}

struct DashboardConversationGeometry: Equatable {
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

    mutating func sourceMessagePositioned(in conversationID: String) {
        positionedConversationID = conversationID
        isNearBottom = false
    }
}

private struct DashboardConversationMessageRow: Identifiable {
    let message: WorkspaceMessageRecord
    let layout: ConversationMessageLayout.Row
    var id: String { layout.id }
}

private enum DashboardConversationDisplayRow: Identifiable {
    case message(DashboardConversationMessageRow)
    case receipt(WorkspaceSessionDelivery)
    case incomingCommand(WorkspaceSessionDelivery)

    var id: String {
        switch self {
        case .message(let row): row.id
        case .receipt(let receipt): WorkspaceConversationTimelineItem.receipt(receipt).id
        case .incomingCommand(let receipt): WorkspaceConversationTimelineItem.incomingCommand(receipt).id
        }
    }

    var spacingBefore: Double {
        if case .message(let row) = self { return row.layout.spacingBefore }
        return 32
    }
}

struct DashboardCloudConversation: View {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    let startsComposerCollapsed: Bool
    let usesCompactPanelSpacing: Bool
    let showsClosePanel: Bool
    let showsAddPanel: Bool
    let focusRequestGeneration: Int?
    let onActivatePanel: () -> Void
    let onClosePanel: () -> Void
    let onAddPanel: () -> Void
    let onSend: () -> Void
    let onAttachmentAction: (DashboardComposerAttachmentAction) -> Void
    let onRemoveAttachment: (String) -> Void
    let onDropFiles: ([URL]) -> Bool
    let onCommandNavigation: (DashboardComposerNavigationDirection) -> Bool
    let onUnavailableComposerAction: (String) -> Void
    private var workspaceOpenCode: OpenCodeModel? {
        conversation.flatMap { model.openCodeModel(for: $0.id) }
    }
    @State private var toolObservationToken = UUID()
    @State private var scrollState = DashboardConversationScrollState()
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
    @State private var librarySourceMessageID: String?
    @State private var attachmentOpenError: String?

    var body: some View {
        let runsByAssistantMessageID = self.runsByAssistantMessageID
        let activitiesByRunID = self.activitiesByRunID
        let attachmentsByMessageID = Dictionary(grouping: messageAttachments, by: \.messageID)
        let referencesByMessageID = Dictionary(grouping: messageReferences, by: \.messageID)
        let visibleMessages = messages.filter { record in
            DashboardRunDisplayPolicy.presentsMessage(record, run: runsByAssistantMessageID[record.id])
                && (record.id == librarySourceMessageID || conversation?.localRuntimeKind != .opencode || workspaceOpenCode?.links[record.conversationID] == nil
                    || workspaceOpenCode?.snapshots[record.conversationID]?.messages.contains(where: { $0["id"].text == record.clientMessageID && OpenCodeSessionSnapshot.presentsMessage($0) }) == true)
        }
        let openCodeOrder = Dictionary((conversation.flatMap { workspaceOpenCode?.snapshots[$0.id]?.messages } ?? []).enumerated().map { ($0.element["id"].text, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let orderedMessages = openCodeOrder.isEmpty ? visibleMessages : visibleMessages.sorted {
            (openCodeOrder[$0.clientMessageID ?? ""] ?? 0) < (openCodeOrder[$1.clientMessageID ?? ""] ?? 0)
        }
        let timeline = WorkspaceConversationTimelineItem.weave(messages: orderedMessages,
            receipts: conversation.flatMap { model.agentTools?.receipts[$0.id] } ?? [], sessionID: conversation?.id ?? "")
        let rows = timeline.flatMap { item -> [DashboardConversationDisplayRow] in
            let message: WorkspaceMessageRecord
            switch item {
            case .receipt(let receipt): return [.receipt(receipt)]
            case .incomingCommand(let receipt): return [.incomingCommand(receipt)]
            case .message(let value): message = value
            }
            let mediaCount: Int
            if let openCode = workspaceOpenCode, openCode.links[message.conversationID] != nil,
               let nativeMessage = openCode.snapshots[message.conversationID]?.messages.first(where: { $0["id"].text == message.clientMessageID }) {
                mediaCount = OpenCodeMessageMedia.files(in: nativeMessage).count
            } else { mediaCount = 0 }
            return ConversationMessageLayout.rows(
                messageID: message.id,
                role: message.role,
                mediaCount: mediaCount
            ).map { .message(DashboardConversationMessageRow(message: message, layout: $0)) }
        }
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if conversation == nil {
                            DashboardConversationEmptyState(
                                icon: .messageSquare,
                                title: agent.map { "New conversation with \(dashboardAgentDisplayName($0))" } ?? "Choose a conversation",
                                detail: agent == nil
                                    ? "Choose New chat for a direct local workspace session, or select a synced conversation."
                                    : "Choose a synced conversation from Workspace."
                            )
                        } else if timeline.isEmpty {
                            DashboardConversationEmptyState(
                                icon: conversation?.localRuntimeKind == nil
                                    ? (agent.map { dashboardAgentGlyph($0) }
                                        ?? .messageSquare)
                                    : .terminal,
                                title: conversation?.title ?? "Conversation",
                                detail: conversation?.localRuntimeKind == nil
                                    ? "This conversation has no messages yet."
                                    : conversation?.localRuntimeKind == .opencode ? "This session uses its workspace on the connected OpenCode host." : "This direct chat is ready in the shared ~/.woven-matter workspace."
                            )
                        } else {
                            if scrollState.positionedConversationID == conversation?.id,
                               (conversationState?.hasOlderMessages == true || conversation.flatMap { workspaceOpenCode?.isLocalSession($0.id) == true ? workspaceOpenCode?.snapshots[$0.id]?.olderCursor : nil } != nil),
                               let oldestMessageID = messages.first?.id {
                                Color.clear
                                    .frame(height: 1)
                                    .padding(.bottom, 32)
                                    .id(historyLoaderID(oldestMessageID: oldestMessageID))
                                    .accessibilityIdentifier("dashboard-history-loader")
                                    .task(id: historyLoaderID(oldestMessageID: oldestMessageID)) {
                                        await prependOlderMessages(
                                            keeping: oldestMessageID,
                                            using: proxy
                                        )
                                    }
                            }
                            if let sessionID = conversation?.id, model.agentTools?.hasOlderReceipts.contains(sessionID) == true {
                                Button("Load earlier session activity") {
                                    Task { await model.agentTools?.loadOlderReceipts(sessionID: sessionID) }
                                }
                                .buttonStyle(SettingsQuietButtonStyle())
                                .padding(.bottom, 32)
                            }
                            ForEach(rows) { row in
                                VStack(spacing: 0) {
                                    switch row {
                                    case .receipt(let receipt):
                                        WorkspaceOutgoingReceipt(receipt: receipt)
                                    case .incomingCommand(let receipt):
                                        WorkspaceIncomingCommandReceipt(receipt: receipt)
                                    case .message(let fragment):
                                        let message = fragment.message
                                        let presentation = messagePresentations[message.id]
                                        let run = runsByAssistantMessageID[message.id]
                                        if case .media(let index) = fragment.layout.content {
                                            if let openCode = workspaceOpenCode {
                                                OpenCodeMessageMedia(model: openCode, conversationID: message.conversationID, messageID: message.clientMessageID ?? "", fileIndex: index)
                                            }
                                        } else {
                                            DashboardMessageRow(
                                                message: message,
                                                attachments: attachmentsByMessageID[message.id] ?? [],
                                                references: referencesByMessageID[message.id] ?? [],
                                                renderedDocument: presentation?.document,
                                                run: run.flatMap {
                                                    DashboardRunDisplayPolicy.presentsStatus($0) ? $0 : nil
                                                },
                                                runPresentation: run.flatMap { runPresentations[$0.id] },
                                                activities: run.map { activitiesByRunID[$0.id] ?? [] } ?? [],
                                                onOpenAttachment: { attachment in
                                                    openAttachment(contentHash: attachment.contentHash,
                                                        fileName: attachment.fileName, mimeType: attachment.mimeType)
                                                },
                                                layout: fragment.layout,
                                                displayedBody: presentation?.displayedBody,
                                                commentaryIDs: presentation?.commentaryIDs,
                                                workTimeline: presentation?.workTimeline
                                            )
                                        }
                                    }
                                }
                                .id(row.id)
                                .background(row.id == libraryHighlightID ? theme.palette.themeWhisper : Color.clear)
                                .padding(.top, row.id == rows.first?.id ? 0 : row.spacingBefore)
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
                .task(id: [model.libraryMessageTarget?.id, conversation?.id]) {
                    await scrollToLibraryMessage(using: proxy)
                }
                .onDisappear { model.agentTools?.observeSessionFromUI(nil, token: toolObservationToken) }
                .environment(\.conversationSubagentHistory) { request in
                    try await model.builtInSubagentHistory(request)
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
                    guard let conversationID = conversation?.id, let store = model.dashboardStore else { return nil }
                    return try await store.database.conversationActivityDetails(
                        conversationID: conversationID, runID: runID, activityID: activityID)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .sizeChanges)
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
                .onScrollGeometryChange(for: DashboardConversationGeometry.self) { geometry in
                    DashboardConversationGeometry(
                        contentHeight: geometry.contentSize.height,
                        isNearBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 80
                    )
                } action: { oldGeometry, newGeometry in
                    let followedBottomBeforeGrowth = oldGeometry.contentHeight != newGeometry.contentHeight
                        && scrollState.isNearBottom && !isUserScrolling && !isPrependingHistory
                        && model.libraryMessageTarget?.conversationID != conversation?.id
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
                .onChange(of: conversation.flatMap { model.pendingComposerPrefills[$0.id] }, initial: true) { _, text in
                    guard let text, let conversationID = conversation?.id else { return }
                    model.consumeComposerPrefill(conversationID: conversationID, expected: text)
                    guard !text.isEmpty else { return }
                    draft = draft.isEmpty ? text : draft + "\n" + text
                }
                .onChange(of: conversation?.id, initial: true) { _, conversationID in
                    conversationState?.transcriptState.tasksExpanded = false
                    model.agentTools?.observeSessionFromUI(conversationID, token: toolObservationToken)
                    isUserScrolling = false
                    transcriptOwnsScroll = model.libraryMessageTarget?.conversationID == conversationID
                    scrollInteractionRevision += 1
                    scrollState.conversationChanged(to: conversationID)
                    if transcriptOwnsScroll { scrollState.setNearBottom(false) }
                    pendingBottomConversationID = model.libraryMessageTarget?.conversationID == conversationID ? nil : conversationID
                    bottomPositionRevision += 1
                    scrollPositionID = nil
                }
                .onChange(of: newestPresentedMessageIdentity, initial: true) { _, identity in
                    guard identity != nil, model.libraryMessageTarget?.conversationID != conversation?.id else { return }
                    let action = scrollState.contentChanged(
                        conversationID: conversation?.id,
                        hasMessages: !visibleMessages.isEmpty,
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
                .overlay(alignment: .bottomTrailing) {
                    if !scrollState.isNearBottom, conversation != nil {
                        Button("Latest reply", systemImage: "arrow.down") {
                            scrollInteractionRevision += 1
                            transcriptOwnsScroll = false
                            scrollState.setNearBottom(true)
                            scrollToConversationBottom(using: proxy)
                        }
                        .buttonStyle(DashboardQuietButtonStyle())
                        .padding(.trailing, 32)
                        .padding(.bottom, bottomScrollClearance)
                    }
                }
            }
            .simultaneousGesture(TapGesture().onEnded(onActivatePanel))

            VStack(spacing: 8) {
                if let conversation, conversation.localRuntimeKind == .opencode, let openCode = workspaceOpenCode {
                    OpenCodeConversationControls(model: openCode, conversationID: conversation.id)
                        .frame(maxWidth: 768)
                }
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
                // Side buttons sit on the composer's bottom control row; the
                // composer grows upward with its draft and Tasks badge.
                HStack(alignment: .bottom, spacing: 8) {
                    Group {
                        if showsClosePanel {
                            DashboardPanelControlButton(
                                glyph: .panelRightOpen,
                                accessibilityLabel: "Remove panel",
                                help: "Remove panel",
                                action: onClosePanel
                            )
                        } else if let conversation, conversation.localRuntimeKind == .defaultAgent {
                            DashboardPanelControlButton(
                                glyph: .settings,
                                accessibilityLabel: "Pi Durable settings",
                                help: "Pi Durable settings"
                            ) {
                                model.pendingDefaultAgentSettingsScope = conversation.remoteWorkspaceID?.uuidString.lowercased() ?? "local"
                            }
                        } else if showsAddPanel {
                            Color.clear
                                .frame(width: DashboardPanelControlButton.size, height: DashboardPanelControlButton.size)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.bottom, DashboardComposer.verticalPadding)
                    DashboardComposer(
                        placeholder: dashboardComposerPlaceholder(
                            agent: agent,
                            runtimeKind: conversation?.localRuntimeKind
                        ),
                        draft: $draft,
                        attachedNoteTitle: attachedNoteTitle,
                        attachments: attachments,
                        agentTools: model.agentTools,
                        sessionID: conversation?.id,
                        showsSessionControls: conversation.map {
                            model.isOpenClawGatewayConversation($0.id) || $0.localRuntimeKind != nil
                        } ?? false,
                        showsPermissionControl: conversation.map {
                            model.isOpenClawGatewayConversation($0.id)
                                || ($0.localRuntimeKind != nil && $0.localRuntimeKind != .pi)
                        } ?? false,
                        sessionMetadataLoading: conversation.map {
                            if $0.localRuntimeKind == .opencode { return workspaceOpenCode?.metadata($0.id) == nil }
                            if model.isOpenClawGatewayConversation($0.id) {
                                return model.openClawGatewaySessionMetadata[$0.id] == nil
                            }
                            return model.loadingLocalACPSessionIDs.contains($0.id)
                                || model.localACPSessionMetadata[$0.id] == nil
                        } ?? false,
                        sessionMetadata: conversation.flatMap {
                            if $0.localRuntimeKind == .opencode { return workspaceOpenCode?.metadata($0.id) }
                            if model.isOpenClawGatewayConversation($0.id) {
                                return model.openClawGatewaySessionMetadata[$0.id]
                            }
                            return model.localACPSessionMetadata[$0.id]
                        },
                        sessionControlsDisabled: conversation.map {
                            if $0.localRuntimeKind == .opencode {
                                return workspaceOpenCode?.isLocalSession($0.id) != true
                                    || workspaceOpenCode?.statuses[$0.id] != "Connected"
                                    || workspaceOpenCode?.updatingSessions.contains($0.id) == true
                                    || model.localRunningConversationIDs.contains($0.id)
                            }
                            if model.isOpenClawGatewayConversation($0.id) {
                                return model.localRunningConversationIDs.contains($0.id)
                                    || model.updatingLocalACPSessionIDs.contains($0.id)
                            }
                            if $0.localRuntimeKind != nil {
                                return model.loadingLocalACPSessionIDs.contains($0.id)
                                    || model.updatingLocalACPSessionIDs.contains($0.id)
                                    || model.localRunningConversationIDs.contains($0.id)
                            }
                            return true
                        } ?? true,
                        sendDisabled: sendInProgress || (conversation.map {
                            if $0.localRuntimeKind == .opencode { return workspaceOpenCode?.isLocalSession($0.id) != true || workspaceOpenCode?.statuses[$0.id] != "Connected" }
                            guard $0.localRuntimeKind != nil else { return true }
                            return model.loadingLocalACPSessionIDs.contains($0.id)
                                || model.updatingLocalACPSessionIDs.contains($0.id)
                        } ?? false),
                        startsCollapsed: startsComposerCollapsed,
                        collapseOverride: $composerCollapseOverride,
                        focusRequestGeneration: focusRequestGeneration,
                        onActivate: onActivatePanel,
                        onSelectModel: { selection in
                            guard let conversation else { return }
                            if conversation.localRuntimeKind == .opencode { workspaceOpenCode?.updateSelection(conversation.id, model: selection); return }
                            if model.isOpenClawGatewayConversation(conversation.id) {
                                model.patchOpenClawGatewaySession(
                                    conversationID: conversation.id,
                                    model: selection,
                                    thinkingLevel: nil
                                )
                                return
                            }
                            if conversation.localRuntimeKind != nil {
                                Task { await model.updateLocalACPSession(
                                    conversation: conversation, model: selection
                                ) }
                                return
                            }
                        },
                        onSelectThinking: { selection in
                            guard let conversation else { return }
                            if conversation.localRuntimeKind == .opencode { workspaceOpenCode?.updateSelection(conversation.id, thinking: selection); return }
                            if model.isOpenClawGatewayConversation(conversation.id) {
                                model.patchOpenClawGatewaySession(
                                    conversationID: conversation.id,
                                    model: nil,
                                    thinkingLevel: selection
                                )
                                return
                            }
                            if conversation.localRuntimeKind != nil {
                                Task { await model.updateLocalACPSession(
                                    conversation: conversation, thinking: selection
                                ) }
                                return
                            }
                        },
                        onSelectPermission: { selection in
                            guard let conversation else { return }
                            if conversation.localRuntimeKind == .opencode {
                                workspaceOpenCode?.updateSelection(conversation.id, permission: selection)
                                return
                            }
                            if model.isOpenClawGatewayConversation(conversation.id) {
                                model.patchOpenClawGatewaySession(
                                    conversationID: conversation.id,
                                    model: nil,
                                    thinkingLevel: nil,
                                    permission: selection
                                )
                                return
                            }
                            if let runtimeKind = conversation.localRuntimeKind, runtimeKind != .pi {
                                Task { await model.updateLocalACPSession(conversation: conversation, permission: selection) }
                            }
                        },
                        onAttachmentAction: onAttachmentAction,
                        onRemoveAttachment: onRemoveAttachment,
                        onOpenAttachment: { file in
                            openAttachment(contentHash: file.contentHash,
                                fileName: file.fileName, mimeType: file.mimeType)
                        },
                        onDropFiles: onDropFiles,
                        onUnavailableAction: onUnavailableComposerAction,
                        onCommandNavigation: onCommandNavigation,
                        onSend: {
                            transcriptOwnsScroll = false
                            isUserScrolling = false
                            scrollInteractionRevision += 1
                            scrollState.setNearBottom(true)
                            scrollPositionID = chatEndID
                            onSend()
                        },
                        onStop: conversation.flatMap { current in
                            guard model.localRunningConversationIDs.contains(current.id) else { return nil }
                            return { model.cancelLocalACPPrompt(conversationID: current.id) }
                        }
                    )
                    Group {
                        if showsAddPanel {
                            DashboardPanelControlButton(
                                glyph: .panelLeftOpen,
                                accessibilityLabel: "Add panel",
                                help: "Add panel",
                                action: onAddPanel
                            )
                        } else if showsClosePanel {
                            Color.clear
                                .frame(width: DashboardPanelControlButton.size, height: DashboardPanelControlButton.size)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.bottom, DashboardComposer.verticalPadding)
                }
                // Animate the whole row so the outside buttons follow the
                // composer height in the same layout transaction.
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.15),
                    value: composerCollapseOverride ?? startsComposerCollapsed
                )
            }
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
        .environment(\.conversationTranscriptState, conversationState?.transcriptState)
        .environment(\.conversationTaskProgress, localPermission == nil && localInteraction == nil
            ? conversationState?.taskProgress : nil)
        .onChange(of: localPermission?.id) { _, _ in conversationState?.transcriptState.tasksExpanded = false }
        .onChange(of: localInteraction?.id) { _, _ in conversationState?.transcriptState.tasksExpanded = false }
        .alert("Could not open attachment", isPresented: Binding(
            get: { attachmentOpenError != nil },
            set: { if !$0 { attachmentOpenError = nil } }
        )) {
            Button("OK", role: .cancel) { attachmentOpenError = nil }
        } message: {
            Text(attachmentOpenError ?? "")
        }
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

    private func openAttachment(contentHash: String?, fileName: String, mimeType: String) {
        guard let contentHash else {
            attachmentOpenError = "This attachment is not available on this Mac."
            return
        }
        Task {
            do {
                try await model.library.openAttachment(
                    contentHash: contentHash, fileName: fileName, mimeType: mimeType)
            } catch { attachmentOpenError = error.localizedDescription }
        }
    }

    private var sessionIdentity: LocalACPSessionMetadataTaskIdentity? {
        guard let conversation else { return nil }
        return LocalACPSessionMetadataTaskIdentity(
            conversationID: conversation.id,
            runtimeKind: conversation.localRuntimeKind,
            usesOpenClawGateway: model.isOpenClawGatewayConversation(conversation.id),
            launchAvailable: model.isLocalACPSessionLaunchAvailable(conversation)
        )
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
        let runsByAssistantMessageID = self.runsByAssistantMessageID
        return messages.filter {
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
    private func scrollToLibraryMessage(using proxy: ScrollViewProxy) async {
        guard let item = model.libraryMessageTarget, item.conversationID == conversation?.id else { return }
        pendingBottomConversationID = nil
        bottomPositionRevision += 1
        scrollInteractionRevision += 1
        transcriptOwnsScroll = true
        scrollState.setNearBottom(false)
        // A Library source can outlive the live OpenCode snapshot's message window.
        librarySourceMessageID = item.messageID
        await model.refreshConversation(id: item.conversationID)
        while !Task.isCancelled,
              model.conversationState(for: item.conversationID)?.content?.messages.contains(where: { $0.id == item.messageID }) != true {
            if model.conversationState(for: item.conversationID)?.isLoadingOlderMessages == true {
                try? await Task.sleep(for: .milliseconds(25))
                continue
            }
            guard await model.loadOlderConversationMessages(id: item.conversationID) else { break }
        }
        guard !Task.isCancelled, conversation?.id == item.conversationID else { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled, model.libraryMessageTarget?.id == item.id,
              conversation?.id == item.conversationID else { return }
        guard model.conversationState(for: item.conversationID)?.content?.messages.contains(where: { $0.id == item.messageID }) == true else {
            model.conversationState(for: item.conversationID)?.setError("This source message is no longer available.")
            model.libraryMessageTarget = nil
            return
        }
        libraryHighlightID = item.messageID
        scrollState.sourceMessagePositioned(in: item.conversationID)
        scrollPositionID = nil
        scrollWithoutAnimation(proxy, to: item.messageID, anchor: .top)
        pendingBottomConversationID = nil
        try? await Task.sleep(for: .seconds(2))
        if libraryHighlightID == item.messageID { libraryHighlightID = nil }
        if !Task.isCancelled, model.libraryMessageTarget?.id == item.id {
            model.libraryMessageTarget = nil
        }
    }

    @MainActor
    private func prependOlderMessages(
        keeping anchorMessageID: String,
        using proxy: ScrollViewProxy
    ) async {
        guard let conversation, !isPrependingHistory else { return }
        isPrependingHistory = true
        if conversationState?.hasOlderMessages != true,
           let openCode = workspaceOpenCode, openCode.isLocalSession(conversation.id),
           let link = openCode.links[conversation.id], openCode.snapshots[conversation.id]?.olderCursor != nil {
            do {
                try await openCode.loadOlder(link)
                await model.refreshConversation(id: conversation.id)
            } catch { openCode.error = error.localizedDescription }
        }
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

struct DashboardLocalPermissionCard: View {
    @Environment(\.dashboardTheme) private var theme
    let permission: PendingLocalACPPermission
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    private var allowOnce: LocalACPPermissionOption? {
        permission.options.first { $0.kind == "allow_once" }
    }

    private var otherOptions: [LocalACPPermissionOption] {
        permission.options.filter { $0.id != allowOnce?.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Approval needed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .textCase(.uppercase)
                .tracking(0.8)
            Text(permission.title)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
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

    @ViewBuilder
    private var actions: some View {
        if let option = allowOnce {
            Button("Allow once") { onSelect(option.id) }
                .buttonStyle(DashboardPrimaryButtonStyle())
                .help(option.name)
                .accessibilityLabel(option.name)
        }
        if !otherOptions.isEmpty {
            Menu(allowOnce == nil ? "Choose response" : "More options") {
                // Keep the provider's complete labels: persistent choices may
                // apply only to a domain, command, or project, not every tool.
                ForEach(otherOptions) { option in
                    Button(option.name) { onSelect(option.id) }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(DashboardPalette.foreground)
            .fixedSize()
            .padding(.horizontal, 8)
            .accessibilityLabel("Other permission responses")
        }
        Button("Cancel", role: .cancel, action: onCancel)
            .buttonStyle(DashboardQuietButtonStyle())
    }
}

struct DashboardLocalInteractionCard: View {
    let interaction: PendingLocalACPInteraction
    let onResolve: (LocalACPInteractionResponse) -> Void

    var body: some View {
        switch interaction.request {
        case .form(let request):
            DashboardLocalFormCard(request: request, onResolve: onResolve)
        case .questions(let request):
            DashboardLocalQuestionCard(request: request, onResolve: onResolve)
        case .plan(let request):
            DashboardLocalPlanCard(request: request, onResolve: onResolve)
        case .secret(let prompt):
            DashboardLocalSecretCard(prompt: prompt, onResolve: onResolve)
        }
    }
}

struct DashboardLocalQuestionCard: View {
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

struct DashboardLocalPlanCard: View {
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
            .scrollIndicators(.never)
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

func dashboardNonemptyString(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else { return nil }
    return trimmed
}

struct DashboardMessageRow: View {
    let message: WorkspaceMessageRecord
    let attachments: [WorkspaceMessageAttachmentRecord]
    let references: [WorkspaceMessageReferenceRecord]
    let renderedDocument: ConversationMarkdownDocument?
    let run: WorkspaceRunRecord?
    let runPresentation: DashboardRunPresentation?
    let activities: [WorkspaceRunActivityRecord]
    let onOpenAttachment: (WorkspaceMessageAttachmentRecord) -> Void
    var layout: ConversationMessageLayout.Row? = nil
    var displayedBody: String? = nil
    var commentaryIDs: Set<String>? = nil
    var workTimeline: ConversationWorkTimeline? = nil

    private var assistantBody: String { displayedBody ?? transcript.body }

    /// Fallback for a row without a prepared presentation.
    private var transcript: (body: String, commentaryIDs: Set<String>) {
        let work = activities.map(\.activity)
        return ConversationWorkTimeline.displayPartition(
            AssistantTranscriptProjection(messageID: message.id, content: message.content, activities: work),
            activities: work, isLive: message.status == "streaming")
    }

    var body: some View {
        if message.role == "system" {
            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                Text(message.content)
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(DashboardPalette.mutedForeground)
        } else if layout?.content == .fileChanges {
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
            let isUser = message.role == "user"
            HStack {
                if isUser { Spacer(minLength: 72) }
                VStack(alignment: isUser ? .trailing : .leading, spacing: 18) {
                    if !isUser, let run {
                        ConversationWorkTranscript(
                            run: run,
                            presentation: runPresentation,
                            records: activities,
                            commentaryIDs: commentaryIDs ?? transcript.commentaryIDs,
                            hasFinalReply: !assistantBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            timeline: projectedTimeline
                        )
                    }
                    if isUser {
                        WorkspaceIncomingAgentHeader(message: message)
                        ConversationUserMessage(
                            content: message.content,
                            attachments: attachments,
                            references: references,
                            onOpenAttachment: onOpenAttachment
                        )
                    } else if showsAssistantBody {
                        ConversationResponse(
                            content: RemoteNoteEditEnvelope.redactingEnvelopes(in: assistantBody),
                            document: renderedDocument,
                            isStreaming: message.status == "streaming"
                        )
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                    }
                    if !isUser, layout == nil {
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
        ConversationMessageLayout.showsAssistantBody(
            content: message.content,
            displayedBody: assistantBody,
            failedRunError: run?.status == "failed" ? run?.error : nil
        )
    }

    private var projectedTimeline: ConversationWorkTimeline {
        workTimeline ?? ConversationWorkTimeline(records: activities,
            commentaryIDs: commentaryIDs ?? transcript.commentaryIDs)
    }
}

struct ConversationUserMessage: View {
    let content: String
    let attachments: [WorkspaceMessageAttachmentRecord]
    let references: [WorkspaceMessageReferenceRecord]
    var onOpenAttachment: ((WorkspaceMessageAttachmentRecord) -> Void)? = nil
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
                        Button { onOpenAttachment?(attachment) } label: {
                            DashboardPersistedAttachmentChip(
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

struct DashboardPersistedAttachmentChip: View {
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

struct DashboardLocalFormCard: View {
    @Environment(\.dashboardTheme) private var theme
    let request: LocalACPFormRequest
    let onResolve: (LocalACPInteractionResponse) -> Void
    @State private var included: Set<String> = []
    @State private var text: [String: String] = [:]
    @State private var flags: [String: Bool] = [:]
    @State private var selections: [String: Set<String>] = [:]
    @State private var initialized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                formFields
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 260)
            HStack(spacing: 8) {
                Button("Submit") { if let values { onResolve(.formValues(values)) } }
                    .buttonStyle(DashboardPrimaryButtonStyle()).disabled(values == nil)
                Button("Cancel", role: .cancel) { onResolve(.cancelled) }.buttonStyle(DashboardQuietButtonStyle())
            }
        }
        .padding(13).frame(maxWidth: 768, alignment: .leading)
        .background(theme.palette.themeWhisper).clipShape(DashboardShapes.card)
        .overlay { DashboardShapes.card.stroke(theme.palette.border, lineWidth: 1) }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            for field in request.fields {
                guard let value = field.initialValue else { continue }
                included.insert(field.id)
                switch value {
                case .string(let value):
                    if field.kind == .singleChoice { selections[field.id] = [value] } else { text[field.id] = value }
                case .strings(let values): selections[field.id] = Set(values)
                case .number(let value): text[field.id] = String(value)
                case .boolean(let value): flags[field.id] = value
                }
            }
        }
    }

    private var formFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.message).font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(request.fields) { field in
                VStack(alignment: .leading, spacing: 7) {
                    if field.required { Text(field.title).font(.system(size: 12.5, weight: .medium)) }
                    else {
                        Toggle(field.title, isOn: Binding(get: { included.contains(field.id) }, set: { value in
                            if value { included.insert(field.id) } else { included.remove(field.id) }
                        })).toggleStyle(DashboardSwitchToggleStyle())
                    }
                    if let detail = field.detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground) }
                    Group {
                        switch field.kind {
                        case .boolean:
                            Toggle("Yes", isOn: Binding(get: { flags[field.id] ?? false }, set: { included.insert(field.id); flags[field.id] = $0 }))
                                .toggleStyle(DashboardSwitchToggleStyle())
                        case .singleChoice, .multipleChoice:
                            ForEach(field.options) { option in
                                Button {
                                    var selected = selections[field.id] ?? []
                                    if field.kind == .singleChoice { selected = [option.id] }
                                    else if selected.contains(option.id) { selected.remove(option.id) }
                                    else { selected.insert(option.id) }
                                    included.insert(field.id)
                                    selections[field.id] = selected
                                } label: {
                                    HStack(alignment: .top, spacing: 7) {
                                        Image(systemName: selections[field.id]?.contains(option.id) == true ? "checkmark.circle.fill" : "circle")
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(option.label)
                                            if let detail = option.detail { Text(detail).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground) }
                                        }
                                        Spacer(minLength: 0)
                                    }.font(.system(size: 12.5)).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        case .text, .number, .integer:
                            if field.multiline {
                                TextEditor(text: textBinding(field.id)).frame(minHeight: 90, maxHeight: 200)
                                    .scrollIndicators(.never)
                            } else {
                                TextField(field.placeholder ?? "Answer", text: textBinding(field.id)).textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
            }
        }
    }

    private func textBinding(_ id: String) -> Binding<String> {
        Binding(get: { text[id] ?? "" }, set: { included.insert(id); text[id] = $0 })
    }
    private var values: [String: LocalACPFormValue]? {
        var result: [String: LocalACPFormValue] = [:]
        for field in request.fields where field.required || included.contains(field.id) {
            switch field.kind {
            case .text: result[field.id] = .string(text[field.id] ?? "")
            case .number, .integer:
                guard let value = Double(text[field.id] ?? ""), value.isFinite else { return nil }
                result[field.id] = .number(value)
            case .boolean: result[field.id] = .boolean(flags[field.id] ?? false)
            case .singleChoice:
                guard let value = selections[field.id]?.first else { return nil }; result[field.id] = .string(value)
            case .multipleChoice:
                result[field.id] = .strings(field.options.filter { selections[field.id]?.contains($0.id) == true }.map(\.id))
            }
        }
        return request.accepts(result) ? result : nil
    }
}
