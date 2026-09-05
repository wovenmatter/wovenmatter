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
}

struct DashboardCloudConversation: View {
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
    @State private var scrollState = DashboardConversationScrollState()
    @State private var isPrependingHistory = false
    @State private var pendingBottomConversationID: String?
    @State private var bottomPositionRevision = 0
    @State private var scrollPositionID: String?
    @State private var bottomStackHeight: CGFloat = 0

    var body: some View {
        let runsByAssistantMessageID = self.runsByAssistantMessageID
        let activitiesByRunID = self.activitiesByRunID
        let attachmentsByMessageID = Dictionary(grouping: messageAttachments, by: \.messageID)
        let referencesByMessageID = Dictionary(grouping: messageReferences, by: \.messageID)
        let visibleMessages = messages.filter {
            DashboardRunDisplayPolicy.presentsMessage($0, run: runsByAssistantMessageID[$0.id])
        }
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
                                    attachments: attachmentsByMessageID[message.id] ?? [],
                                    references: referencesByMessageID[message.id] ?? [],
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
            .simultaneousGesture(TapGesture().onEnded(onActivatePanel))

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
                HStack(alignment: .center, spacing: 8) {
                    if showsClosePanel {
                        DashboardPanelControlButton(
                            glyph: .panelRightOpen,
                            accessibilityLabel: "Remove panel",
                            help: "Remove panel",
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
                        startsCollapsed: startsComposerCollapsed,
                        focusRequestGeneration: focusRequestGeneration,
                        onActivate: onActivatePanel,
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
                        onCommandNavigation: onCommandNavigation,
                        onSend: onSend
                    )
                    if showsAddPanel {
                        DashboardPanelControlButton(
                            glyph: .panelLeftOpen,
                            accessibilityLabel: "Add panel",
                            help: "Add panel",
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

struct DashboardLocalPermissionCard: View {
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

struct DashboardLocalInteractionCard: View {
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

struct ConversationUserMessage: View {
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
