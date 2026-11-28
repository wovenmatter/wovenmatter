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
    /// The agent of a chat being started: it shows as a new chat until its first view arrives.
    var startingAgent: WorkspaceAgent? = nil
    let attachedNoteTitle: String?
    @Binding var draft: String
    let attachments: [AgentMessageAttachmentDraft]
    let sendInProgress: Bool
    let startsComposerCollapsed: Bool
    let showsClosePanel: Bool
    let showsAddPanel: Bool
    let focusRequestGeneration: Int?
    /// The panel debug requests that act on one chat (`send:`, `status:`) go to.
    var isActivePanel = true
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
    /// Older rows are being paged in, or are settling under the held row.
    @State private var isPrependingHistory = false
    /// The row that keeps its place on screen while older rows are laid out above it.
    @State private var heldRowID: String?
    @State private var hold = HeldRowPosition()
    /// The history loader at the top while it is on screen.
    @State private var visibleLoaderID: String?
    /// Counts chat changes, so a page-in begun in one chat never acts in another.
    @State private var historyGeneration = 0
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    /// The scroll view `scrollPosition` was set for.
    @State private var scrollPositionOwner: TranscriptIdentity?
    @State private var composerCollapseOverride: Bool?
    @State private var bottomStackHeight: CGFloat = 0
    /// The transcript's visible height, the least its content takes.
    @State private var viewportHeight: CGFloat = 0
    /// This transcript's own scope for Copy reading its visual replies.
    @State private var copyScope = UUID()
    /// Rows lie below what shows (measured; it never changes whether the transcript follows).
    @State private var hasContentBelow = false
    /// Raw scroll measurements, read in callbacks and never observed: a value
    /// that changes with every scroll tick must not rebuild the transcript.
    @State private var measured = TranscriptMeasurements()
    /// Counts the reader's and the app's explicit scroll actions (Latest
    /// reply, send, opening a chat, the reader's own scroll): positioning
    /// begun before the latest one (a Library source, a page-in's held row)
    /// gives way to it.
    @State private var scrollGeneration = 0
    @State private var isUserScrolling = false
    /// Counts put-back requests that have waited for the layout that queued
    /// them to end; each runs against whatever the transcript is then.
    @State private var endRepairs = 0
    @State private var libraryHighlightID: String?
    @State private var attachmentOpenError: String?
    @State private var choosingFolder = false
    @State private var folderSelectionError: String?
    /// What the rows and the transcript's views ask this chat to do; one
    /// object for the view's life, its actions set again on every pass.
    @State private var rowActions = ConversationRowActions()

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
        let actions = refreshedRowActions()
        let runsByAssistantMessageID = self.runsByAssistantMessageID
        let activitiesByRunID = self.activitiesByRunID
        let visibleMessages = self.visibleMessages(runs: runsByAssistantMessageID)
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
                        if let startingAgent, session?.hasLoaded != true {
                            newChatEmptyState(runtimeKind: startingAgent.runtimeKind)
                        } else if conversation == nil {
                            ConversationEmptyState(
                                icon: .messageSquare,
                                title: agent.map { "New conversation with \(agentDisplayName($0))" } ?? "Choose a conversation",
                                detail: agent == nil
                                    ? "Choose New chat to select an agent, or open an existing conversation."
                                    : "Choose a conversation from All Workspaces."
                            )
                        } else if session?.hasLoaded != true {
                            // Its first view has not arrived: nothing yet, then the chat whole.
                            Color.clear.frame(height: 1)
                        } else if visibleMessages.isEmpty {
                            if let runtimeKind = conversation?.runtimeKind {
                                newChatEmptyState(runtimeKind: runtimeKind)
                            } else {
                                ConversationEmptyState(
                                    icon: agent.map { agentIconGlyph($0) } ?? .messageSquare,
                                    title: conversation?.title ?? "Conversation",
                                    detail: "This conversation has no messages yet."
                                )
                            }
                        } else {
                            if session?.hasOlderMessages == true,
                               let oldestMessageID = messages.first?.id {
                                let loaderID = historyLoaderID(oldestMessageID: oldestMessageID)
                                Color.clear
                                    .frame(height: 1)
                                    .padding(.bottom, ConversationMetrics.turnGap)
                                    .id(loaderID)
                                    .accessibilityIdentifier("conversation-history-loader")
                                    .onScrollVisibilityChange(threshold: 0.01) { visible in
                                        if visible { visibleLoaderID = loaderID }
                                        else if visibleLoaderID == loaderID { visibleLoaderID = nil }
                                        // Eager layout must not eagerly fetch history.
                                        guard visible else { return }
                                        Task { @MainActor in
                                            await prependOlderMessages()
                                        }
                                    }
                            }
                            ForEach(rows) { row in
                                VStack(spacing: 0) {
                                    messageRow(row, runs: runsByAssistantMessageID, activities: activitiesByRunID, actions: actions)
                                }
                                .id(row.id)
                                .background {
                                    if row.id == heldRowID {
                                        Color.clear.onGeometryChange(for: CGFloat.self) { geometry in
                                            geometry.frame(in: .named(Self.contentSpace)).minY
                                        } action: { top in
                                            heldRowMoved(to: top)
                                        }
                                    }
                                }
                                .background(row.id == libraryHighlightID ? theme.palette.themeWhisper : Color.clear)
                                .padding(.top, row.id == rows.first?.id ? 0 : row.layout.spacingBefore)
                            }
                        }
                        Color.clear
                            .frame(height: bottomScrollClearance)
                            // Which scroll view and window are this transcript's, for the reader's input.
                            .background(ConversationScrollViewReader { measured.scrollView = $0 })
                            .id(chatEndID)
                    }
                    .coordinateSpace(.named(Self.contentSpace))
                    .frame(maxWidth: ConversationMetrics.column)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, ConversationMetrics.sideInset)
                    .padding(.top, ConversationMetrics.topInset)
                    // Never shorter than the viewport: the transcript first
                    // growing past the window then keeps the bottom through
                    // the size-change anchor in the same pass, as any later
                    // growth does, instead of a scroll after the layout.
                    .frame(minHeight: viewportHeight, alignment: .top)
                    .scrollTargetLayout()
                }
                // Each chat gets its own scroll view, which opens at the bottom
                // in its first layout; reusing one would lay the new chat out
                // at the old offset and move it a turn later.
                .id(transcriptIdentity)
                .scrollIndicators(.never)
                .task(id: [model.navigation.libraryMessageTarget?.id, conversation?.id]) {
                    await scrollToLibraryMessage(using: proxy)
                }
                .debugRequest("scroll-top") {
                    transcriptOwnsScroll = true
                    scrollState.setNearBottom(false)
                    // The very top, with the transcript's inset above the first row.
                    scroll { $0.scrollTo(edge: .top) }
                }
                // `scroll-end` goes to the end as Latest reply does, and follows it again.
                .debugRequest("scroll-end") {
                    takeOverScrolling()
                    transcriptOwnsScroll = false
                    scrollState.setNearBottom(true)
                    scrollToEnd()
                }
                // `work:open` and `work:fold` open or fold the work of every turn, as
                // its header does; a running turn's fold is flipped from open.
                .debugCommand("work:") { action in
                    guard let session else { return }
                    for run in session.runs {
                        let running = run.status == .running
                        session.transcriptState.setExpanded(
                            ConversationTranscriptState.disclosureKey(runID: run.id, itemID: running ? "turn:running" : "turn"),
                            running ? action != "open" : action == "open")
                    }
                }
                // `send:TEXT` sends TEXT from this chat's composer.
                .debugCommand("send:") { text in
                    // Only the active panel's chat, and only if it is still that chat.
                    guard isActivePanel, let target = conversation?.id else { return }
                    draft = text
                    Task { @MainActor in
                        await Task.yield()
                        guard isActivePanel, conversation?.id == target else { return }
                        sendFromComposer()
                    }
                }
                // `stop` stops this chat's running turn, as the composer's stop button does.
                .debugRequest("stop") {
                    guard isActivePanel, let session, session.isRunning else { return }
                    Task { await session.stop() }
                }
                // `status:PATH` writes whether this chat's turn is still running.
                .debugCommand("status:") { path in
                    guard isActivePanel else { return }
                    let running = session?.isRunning == true
                    // How far the end is below what shows, and whether the transcript follows it.
                    let text = "{\"chat\":\"\(conversation?.id ?? "")\",\"running\":\(running)," +
                        "\"endDistance\":\(Int(measured.endDistance)),\"following\":\(followsBottom)}"
                    try? text.write(toFile: path.trimmingCharacters(in: .whitespaces), atomically: true, encoding: .utf8)
                }
                // `scroll-y:POINTS` sets the offset, as a reader scrolling away would.
                .debugCommand("scroll-y:") { value in
                    guard let y = Double(value.trimmingCharacters(in: .whitespaces)) else { return }
                    transcriptOwnsScroll = true
                    scrollState.setNearBottom(false)
                    scroll { $0.scrollTo(y: y) }
                }
                // The same two closures on every pass, so the views reading
                // them are not drawn again for it; each calls this pass's action.
                .environment(\.conversationTranscriptInteraction, actions.forwardedInteraction)
                .environment(\.conversationActivityDetails, actions.forwardedActivityDetails)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                // Following the latest reply, growth keeps the bottom in place
                // in the same layout pass; a later scroll would show each
                // chunk below the edge for a frame and then jump.
                .defaultScrollAnchor(followsBottom ? .bottom : .top, for: .sizeChanges)
                // Away from the live edge, what the reader sees stays put when
                // something above or below it opens, folds or grows.
                .scrollPosition(transcriptPosition, anchor: followsBottom ? .bottom : .top)
                .onScrollPhaseChange { _, phase, context in
                    let wasScrolling = isUserScrolling
                    isUserScrolling = phase == .interacting || phase == .tracking || phase == .decelerating
                    let end = TranscriptEnd(context.geometry)
                    if isUserScrolling, !wasScrolling {
                        measured.readerScrollStart = end.offset
                        // The reader's scroll outranks a pending Library jump;
                        // a page-in they scrolled to keeps holding their row.
                        scrollGeneration += 1
                    } else if wasScrolling, !isUserScrolling, end.offset != measured.readerScrollStart {
                        // Where the reader's own scroll stopped decides whether
                        // the latest reply stays in view; a tap that moved
                        // nothing decides nothing.
                        readerMoved(to: end)
                    } else if wasScrolling, !isUserScrolling {
                        // A touch that moved nothing leaves following as it was,
                        // and the end it may have kept from being put back.
                        restoreEndAfterLayout()
                    }
                }
                .onChange(of: endRepairs) { repairEnd() }
                .onScrollGeometryChange(for: TranscriptEnd.self) { geometry in
                    TranscriptEnd(geometry)
                } action: { before, after in
                    endChanged(from: before, to: after)
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
                    viewportHeight = height
                }
                // Back from paging history, a library jump or a reader's
                // scroll, still following: make up for anything missed meanwhile.
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    // The offset as `scrollTo(y:)` takes it.
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, offset in
                    scrolled(to: offset)
                }
                .onAppear { ConversationReaderInput.start() }
                .onDisappear { ConversationReaderInput.stop() }
                .onChange(of: conversation?.id, initial: true) { _, conversationID in
                    conversationChanged(to: conversationID)
                }
                .onChange(of: transcriptIdentity, initial: true) { _, identity in measured.shown = identity }
                .conversationEdges(stackHeight: bottomStackHeight,
                                   jumpLabel: !scrollState.isNearBottom && hasContentBelow && conversation != nil
                                       ? "Latest reply" : nil) {
                    takeOverScrolling()
                    transcriptOwnsScroll = false
                    scrollState.setNearBottom(true)
                    scrollToEnd()
                }
            }
            .simultaneousGesture(TapGesture().onEnded(onActivatePanel))

            bottomStack
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ConversationMetrics.sideInset)
                .conversationPanelControls { leadingPanelControl } trailing: { trailingPanelControl }
                .padding(.top, 8)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    bottomStackHeight = max(0, height)
                }
                .padding(.bottom, ConversationBottomOverlayLayout.bottomOffset)
        }
        .background(theme.palette.workspace)
        .environment(\.conversationCopyScope, copyScope)
        .environment(\.conversationTranscriptState, session?.transcriptState)
        .environment(\.conversationFolder, sessionFolder)
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
        activities: [String: [WorkspaceRunActivityRecord]],
        actions: ConversationRowActions
    ) -> some View {
        let message = fragment.message
        let run = runs[message.id]
        // A row whose data is the same as in the last pass is not drawn again.
        MessageRow(
            message: message,
            run: run.flatMap { $0.status == .queued ? nil : $0 },
            activities: run.map { activities[$0.id] ?? [] } ?? [],
            layout: fragment.layout,
            offersNewSession: message.id == session?.goneNoticeID && conversation?.isArchived == false && onNewSession != nil,
            actions: actions
        )
        .equatable()
    }

    /// `rowActions`, set to act for the chat as it is in this pass.
    private func refreshedRowActions() -> ConversationRowActions {
        let actions = rowActions
        actions.openAttachment = { attachment in openAttachment(attachment) }
        actions.resolveFile = { libraryItemID, source in
            try await model.library.fileURL(id: WorkspaceLibraryItem.identifier(messageID: libraryItemID, source: source))
        }
        actions.newSession = { onNewSession?() }
        actions.transcriptInteraction = {
            transcriptOwnsScroll = true
            // Pin where the reader is now, so what they opened or chose
            // stays where it is while it changes size.
            scroll { $0.scrollTo(y: hold.offset) }
            scrollState.setNearBottom(false)
        }
        actions.activityDetails = { runID, activityID in
            guard let session else { return nil }
            return try await session.activityDetails(runID: runID, activityID: activityID)
        }
        return actions
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
                .frame(maxWidth: ConversationMetrics.column, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            if let error = session?.error {
                InlineError(text: error)
                    .frame(maxWidth: ConversationMetrics.column)
            }
            if let interaction, let session {
                SessionInteractionCard(interaction: interaction) { response in
                    Task { await session.answer(interaction.id, with: response) }
                }
                .disabled(!session.isOwnerReachable)
                .conversationCoverSnapshot()
                .id(interaction.id)
            }
            // The transcript's column, so the composer and the messages share
            // edges; the panel buttons sit in the margins beside it.
            VStack(spacing: 8) {
                notices
                composer
            }
            .frame(maxWidth: ConversationMetrics.column)
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
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let conversation, let notice = model.macAccessNotice(for: conversation) {
            MacAccessNotice(message: notice, openSettings: { model.navigation.pendingConnectionsScope = "permissions" })
        }
        if let conversation, !conversation.isArchived, session?.isOwnerDisconnected == true {
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
            .background(WovenPalette.background,
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
        return ConversationComposer(
            placeholder: composerPlaceholder(agent: agent, runtimeKind: conversation?.runtimeKind),
            draft: $draft,
            attachedNoteTitle: attachedNoteTitle,
            attachments: attachments,
            // A chat still on its way to this Mac's library has no tools to set yet.
            agentTools: conversation == nil || model.workspace.isArriving(conversation?.id) ? nil : model.agentTools,
            sessionID: conversation?.id,
            supportsGoals: WorkspaceGoal.supports(conversation?.runtimeKind),
            showsSessionControls: hasRuntime,
            showsPermissionControl: hasRuntime,
            sessionMetadataLoading: hasRuntime && session?.settings == nil,
            sessionMetadata: hasRuntime ? session?.settings : nil,
            sessionControlsDisabled: !hasRuntime || isReadOnly,
            sendDisabled: sendInProgress || (conversation != nil && (isReadOnly || !hasRuntime)),
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
            onSend: { sendFromComposer() },
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
            // This Mac's server moves it, once its library holds the chat.
            folderSelectionDisabled: isReadOnly || choosingFolder || sendInProgress || session?.hasUserMessage != false
                || model.workspace.isArriving(conversation?.id),
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

    private var transcriptIdentity: TranscriptIdentity {
        TranscriptIdentity(conversationID: conversation?.id, hasLoaded: session?.hasLoaded == true)
    }

    /// The position of the scroll view on screen. A new chat's scroll view
    /// starts with none, so a scroll set in the last chat never opens it
    /// away from the bottom.
    private var transcriptPosition: Binding<ScrollPosition> {
        let identity = transcriptIdentity
        return Binding(
            get: { scrollPositionOwner == identity ? scrollPosition : ScrollPosition(idType: String.self) },
            set: { position in
                // A scroll view that no longer shows the current transcript writes nothing back.
                guard identity == measured.shown else { return }
                if scrollPosition != position { scrollPosition = position }
                if scrollPositionOwner != identity { scrollPositionOwner = identity }
            })
    }

    private func scroll(_ change: (inout ScrollPosition) -> Void) {
        // The app scrolls only the transcript it shows now.
        measured.shown = transcriptIdentity
        var position = transcriptPosition.wrappedValue
        change(&position)
        transcriptPosition.wrappedValue = position
    }

    /// The one way the app puts the view at the end (Latest reply, send,
    /// following): the bottom edge, asked again whenever the end has moved
    /// while following. One request per action: a second scroll target set
    /// inside the update the first one started (as a change of follow intent
    /// used to) left SwiftUI resolving between them forever, and the app
    /// hung. No end row or proxy scroll beside it, and no measured offset,
    /// which chases a lazy stack's estimate of its own height.
    private func scrollToEnd() {
        scroll { $0.scrollTo(edge: .bottom) }
    }

    /// An explicit jump takes over: a Library source jump or a page-in still
    /// positioning the view gives way, and the Library target it replaces is
    /// dropped.
    private func takeOverScrolling() {
        scrollGeneration += 1
        historyGeneration += 1
        isPrependingHistory = false
        releaseHeldRow()
        if model.navigation.libraryMessageTarget?.conversationID == conversation?.id {
            model.navigation.libraryMessageTarget = nil
            libraryHighlightID = nil
        }
    }

    /// What the composer's Send does, and the debug `send:` with it.
    private func sendFromComposer() {
        guard conversation?.isArchived != true else { return }
        takeOverScrolling()
        transcriptOwnsScroll = false
        isUserScrolling = false
        scrollState.setNearBottom(true)
        scrollToEnd()
        onSend()
    }

    private var chatEndID: String {
        "chat-end:\(conversation?.id ?? "none")"
    }

    private var bottomScrollClearance: CGFloat {
        CGFloat(ConversationBottomOverlayLayout.scrollClearance(stackHeight: Double(bottomStackHeight)))
    }

    private var runsByAssistantMessageID: [String: WorkspaceRunRecord] {
        session?.runsByAssistantMessageID ?? [:]
    }

    private var activitiesByRunID: [String: [WorkspaceRunActivityRecord]] {
        session?.activitiesByRunID ?? [:]
    }

    /// An empty reply to a run that has not started yet is not shown.
    private func visibleMessages(runs: [String: WorkspaceRunRecord]) -> [WorkspaceMessageRecord] {
        messages.filter { message in
            message.role != .assistant || !message.content.isEmpty || runs[message.id]?.status != .queued
        }
    }

    private func historyLoaderID(oldestMessageID: String) -> String {
        "chat-history:\(conversation?.id ?? "none"):\(oldestMessageID)"
    }

    /// The loader the transcript draws now, if it has older rows to page in.
    private var currentLoaderID: String? {
        guard session?.hasOlderMessages == true, let oldest = messages.first?.id else { return nil }
        return historyLoaderID(oldestMessageID: oldest)
    }

    private static let contentSpace = "conversation-content"

    /// A harness chat with no messages: its logo, and whom a message goes to.
    private func newChatEmptyState(runtimeKind: AgentRuntimeKind) -> some View {
        ConversationEmptyState(
            icon: .terminal,
            harnessLogo: HarnessLogo(runtimeKind: runtimeKind),
            title: conversation?.title ?? "New Chat",
            detail: "Send a message to \(agent.map(agentDisplayName) ?? runtimeKind.displayName) to start this chat."
        )
    }

    private func conversationChanged(to conversationID: String?) {
        session?.transcriptState.tasksExpanded = false
        isUserScrolling = false
        let targetsLibraryMessage = conversationID != nil
            && model.navigation.libraryMessageTarget?.conversationID == conversationID
        transcriptOwnsScroll = targetsLibraryMessage
        scrollState.conversationChanged(to: conversationID)
        if transcriptOwnsScroll { scrollState.setNearBottom(false) }
        scrollPosition = ScrollPosition(idType: String.self)
        scrollGeneration += 1
        // A page-in begun in the last chat ends there.
        historyGeneration += 1
        isPrependingHistory = false
        visibleLoaderID = nil
        releaseHeldRow()
    }

    /// The folder the session works in, when it has one.
    private var sessionFolder: String? {
        model.workspace.folder(id: conversation?.folderID)?.rootPath
    }

    private static let liveEdgeTolerance = ConversationEnd.liveEdge
    /// How long after a viewport change the scroll view's own moves belong to
    /// it (its follow-up pass came about 8 to 13 ms after).
    private static let viewportSettle: CFTimeInterval = 0.1

    /// Geometry is only measured here. Whether the transcript follows the end
    /// is the reader's: their own scroll, Latest reply, or opening or
    /// selecting something decide it, never a layout pass. Growth and
    /// shrinking at the live edge keep the bottom through the size-change
    /// anchor in the same pass; when a resize leaves the end out of view
    /// anyway, it is put back. Keyboard, wheel and accessibility
    /// scrolls report no scroll phase, so the view moving right after the
    /// reader's own input is the reader too when it leaves the end or arrives
    /// at it; with no such input it is the layout (a resize can move the view
    /// again a pass later), and only puts the end back.
    private func endChanged(from before: TranscriptEnd, to after: TranscriptEnd) {
        // Only what changes something visible is published.
        let obscured = ConversationEnd.isObscured(distance: after.distance)
        if obscured != hasContentBelow { hasContentBelow = obscured }
        measured.endDistance = after.distance
        let resized = after.contentHeight != before.contentHeight || after.viewportHeight != before.viewportHeight
        if resized { measured.resizes += 1 }
        // The view moving with no scroll phase is the reader only when the
        // reader just used a wheel, a navigation key or the pointer on this
        // transcript, or VoiceOver is on: the scroll view also moves on its
        // own (after a window resize it can put back an offset it had before,
        // in a pass with no size change), and a layout never changes
        // following. With that input: when nothing resized, any move away
        // from the end or onto it; when something resized in the same
        // update, one that left the end further away (keeping the bottom
        // never does), or one that reached the end.
        // The scroll view's own move in the passes right after a viewport
        // change is the layout's, even with VoiceOver on.
        let now = CACurrentMediaTime()
        if after.viewportHeight != before.viewportHeight { measured.viewportChangedAt = now }
        let readerInput = ConversationReaderInput.isRecent(for: measured.scrollView, isActivePanel: isActivePanel,
            countsVoiceOver: now - measured.viewportChangedAt > Self.viewportSettle)
        let movedAway = after.distance > max(before.distance, Self.liveEdgeTolerance)
        let arrived = after.distance <= Self.liveEdgeTolerance && before.distance > Self.liveEdgeTolerance
        let moved = after.offset != before.offset
        if !isUserScrolling, !isPrependingHistory, moved, readerInput,
           resized ? movedAway || arrived : after.distance > before.distance || after.distance <= Self.liveEdgeTolerance {
            readerMoved(to: after)
        }
        // The scroll view moved on its own and left the end out of view while following: put it back.
        if !resized, moved, !readerInput, followsBottom, after.distance > 0 {
            measured.restoredResize = nil
            restoreEndAfterLayout()
        }
        // Back at the live edge, the bottom holds instead.
        if after.distance <= Self.liveEdgeTolerance, !isPrependingHistory, heldRowID != nil { releaseHeldRow() }
        if followsBottom, resized, after.distance > 0 { restoreEndAfterLayout() }
    }

    /// Puts the end back after this layout, not inside it. The request only
    /// waits for the layout to end; what it does is decided then, from the
    /// transcript as it is (see `repairEnd`), never from the one that asked.
    private func restoreEndAfterLayout() {
        guard !measured.restoreQueued else { return }
        measured.restoreQueued = true
        Task { @MainActor in
            measured.restoreQueued = false
            endRepairs &+= 1
        }
    }

    /// Puts the end back if the transcript showing now follows it, has it out
    /// of view and is not being scrolled by the reader: at most once for each
    /// change of content or viewport size, so it cannot repeat itself. A
    /// request that finds the reader scrolling does nothing; their scroll
    /// ending asks again.
    private func repairEnd() {
        guard followsBottom, measured.endDistance > 0, measured.restoredResize != measured.resizes else { return }
        measured.restoredResize = measured.resizes
        scrollToEnd()
    }

    /// The reader moved the view: at the live edge it follows again, away from it it stays where they put it.
    private func readerMoved(to end: TranscriptEnd) {
        transcriptOwnsScroll = false
        let atLiveEdge = end.distance <= Self.liveEdgeTolerance
        // A move with no scroll phase leaves the last position the app set (the
        // end, while following) in place, and that would keep pulling the view
        // down: hold it where the reader put it instead.
        if !atLiveEdge, scrollState.isNearBottom { scroll { $0.scrollTo(y: end.offset) } }
        scrollState.setNearBottom(atLiveEdge)
    }

    private func scrolled(to offset: CGFloat) {
        hold.offset = offset
        measured.offset = offset
        // The reader moved the held row; it holds where they put it.
        if isUserScrolling, heldRowID != nil, let top = hold.top { hold.screenTop = top - offset }
    }

    /// Rows above the held one were laid out or measured again: scroll by
    /// what they moved it, so it stays where it was on screen, whatever
    /// else grows below.
    private func heldRowMoved(to top: CGFloat) {
        hold.top = top
        guard let screenTop = hold.screenTop, !followsBottom else {
            hold.screenTop = top - hold.offset
            return
        }
        let offset = top - screenTop
        guard abs(offset - hold.offset) >= 0.5 else { return }
        hold.offset = offset
        scroll { $0.scrollTo(y: offset) }
    }

    /// Holds the topmost row whose identity survives older rows arriving: a
    /// reply's first part can join a turn that starts above it.
    private func holdTopRow() {
        let shown = visibleMessages(runs: runsByAssistantMessageID)
        let message = shown.first { $0.role != .assistant } ?? shown.first
        hold.top = nil
        hold.screenTop = nil
        heldRowID = message.flatMap { ConversationMessageLayout.rows(messageID: $0.id, role: $0.role).first?.id }
    }

    private func releaseHeldRow() {
        heldRowID = nil
        hold.top = nil
        hold.screenTop = nil
    }

    @MainActor
    private func scrollToLibraryMessage(using proxy: ScrollViewProxy) async {
        guard let item = model.navigation.libraryMessageTarget, item.conversationID == conversation?.id,
              let session else { return }
        let generation = scrollGeneration
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
        // Anything the reader or the app did meanwhile wins over this jump.
        guard !Task.isCancelled, model.navigation.libraryMessageTarget?.id == item.id,
              conversation?.id == item.conversationID, generation == scrollGeneration else { return }
        // A run's reply shows several of its items.
        guard let shownID = session.messages.first(where: { $0.shows(item.messageID) })?.id else {
            session.setError("This source message is no longer available.")
            model.navigation.libraryMessageTarget = nil
            return
        }
        libraryHighlightID = shownID
        scrollState.sourceMessagePositioned(in: item.conversationID)
        scrollPosition = ScrollPosition(idType: String.self)
        scrollWithoutAnimation(proxy, to: shownID, anchor: .top)
        // Clear of the floating buttons over the top edge, where it can be
        // seen; in a later update, so it is never a second target beside the first.
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled, generation == scrollGeneration else { return }
        scroll { $0.scrollTo(y: max(0, measured.offset - ConversationMetrics.topInset)) }
        try? await Task.sleep(for: .seconds(2))
        if libraryHighlightID == shownID { libraryHighlightID = nil }
        if !Task.isCancelled, model.navigation.libraryMessageTarget?.id == item.id {
            model.navigation.libraryMessageTarget = nil
        }
    }

    /// Pages in older rows above the reader. The row at the top keeps its
    /// place on screen as they are laid out and measured, and the next page
    /// loads only if the loader is still on screen once they have settled.
    @MainActor
    private func prependOlderMessages() async {
        guard let session, !isPrependingHistory else { return }
        let generation = historyGeneration
        isPrependingHistory = true
        repeat {
            holdTopRow()
            // Where the held row is before anything arrives above it.
            var waited = 0
            while hold.screenTop == nil, heldRowID != nil, waited < 50, generation == historyGeneration {
                try? await Task.sleep(for: .milliseconds(10))
                waited += 1
            }
            guard generation == historyGeneration else { return }
            guard await session.loadOlderMessages() else { break }
            try? await Task.sleep(for: .milliseconds(300))
            guard generation == historyGeneration else { return }
        } while visibleLoaderID != nil && visibleLoaderID == currentLoaderID
        if generation == historyGeneration { isPrependingHistory = false }
    }

    private func scrollWithoutAnimation(_ proxy: ScrollViewProxy, to id: some Hashable, anchor: UnitPoint) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

}

func nonemptyString(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else { return nil }
    return trimmed
}

/// What a transcript's rows and views ask its chat to do. One object for the
/// chat view's life, so rows compare equal from pass to pass; the chat sets
/// its actions again on every pass, so each acts for the chat as it is then.
/// Rows pass what is theirs (the item a file belongs to) as arguments.
@MainActor
final class ConversationRowActions {
    var openAttachment: (SessionMessageAttachment) -> Void = { _ in }
    /// The URL of a file a reply refers to: the item whose library entries carry it, and its source.
    var resolveFile: (_ libraryItemID: String, _ source: String) async throws -> URL = { _, _ in throw CancellationError() }
    var newSession: () -> Void = {}
    var transcriptInteraction: @MainActor () -> Void = {}
    var activityDetails: @MainActor (_ runID: String, _ activityID: String) async throws -> AgentRunActivity? = { _, _ in nil }

    /// The two the transcript's environment carries, each made once, so the
    /// views reading them see the same closure on every pass.
    private(set) lazy var forwardedInteraction: @MainActor () -> Void = { [weak self] in
        self?.transcriptInteraction()
    }
    private(set) lazy var forwardedActivityDetails: @MainActor (_ runID: String, _ activityID: String) async throws
        -> AgentRunActivity? = { [weak self] runID, activityID in
            try await self?.activityDetails(runID, activityID)
        }
}

struct MessageRow: View, Equatable {
    /// What Copy puts before a reply's text: its visual replies' text, if any.
    static func copyLead(_ keys: [String]) -> (@MainActor @Sendable () async -> String?)? {
        guard !keys.isEmpty else { return nil }
        return { @MainActor @Sendable in await ConversationVisualReplyText.text(of: keys) }
    }

    let message: WorkspaceMessageRecord
    let run: WorkspaceRunRecord?
    let activities: [WorkspaceRunActivityRecord]
    let layout: ConversationMessageLayout.Row
    /// The notice that the chat's native session is gone offers a new chat.
    let offersNewSession: Bool
    let actions: ConversationRowActions
    @Environment(\.conversationCopyScope) private var copyScope

    /// The same data draws the same row: a pass of the transcript for its
    /// scroll or layout leaves the row as it is.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.run == rhs.run && lhs.activities == rhs.activities && lhs.layout == rhs.layout
            && lhs.offersNewSession == rhs.offersNewSession && lhs.actions === rhs.actions
    }

    private var isStreaming: Bool {
        AssistantStreamingText.isStreaming(messageStatus: message.status, runStatus: run?.status)
    }

    var body: some View {
        if message.role == .system {
            HStack(spacing: ConversationMetrics.labelGap) {
                Image(systemName: "info.circle")
                Text(message.content)
                    .lineLimit(1)
                if offersNewSession {
                    ConversationTextButton("New Chat") { actions.newSession() }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(WovenPalette.mutedForeground)
        } else if layout.content == .fileChanges {
            HStack {
                ConversationChangedFilesCard(records: activities)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if message.role == .user {
            ConversationMessageRowLayout {
                VStack(alignment: .trailing, spacing: ConversationMetrics.labelGap) {
                    WorkspaceIncomingAgentHeader(message: message)
                    ConversationUserMessage(
                        content: message.senderKind == .goal ? "Continuing toward the goal." : message.content,
                        attachments: message.attachments,
                        references: message.references,
                        onOpenAttachment: { actions.openAttachment($0) }
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            assistantTurn(AssistantTurnDisplays.display(
                sessionID: message.conversationID, messageID: message.id, content: message.content,
                isStreaming: isStreaming, records: activities))
        }
    }

    /// The display is worked out once for each change of the reply or its
    /// run's records, and shared by every part.
    @ViewBuilder
    private func assistantTurn(_ display: AssistantTurnDisplay) -> some View {
        let reply = display.reply
        // Text the work transcript leaves to the response below it.
        let hasResponseText = display.hasResponseText
        let showsReply = ConversationMessageLayout.showsAssistantBody(
            content: message.content,
            displayedBody: reply,
            failedRunError: run?.status == .failed ? run?.error : nil
        )
        // This answer's visual replies, in the order they show, as Copy reads them.
        let visualKeys: [String] = activities.compactMap(\.activity.htmlRender)
            .map { ConversationVisualReplyText.key(scope: copyScope, item: $0.id) }
        HStack {
            // Each part owns the gap above it: the work log ends with the
            // gap to the reply, and the previews and card start with theirs.
            VStack(alignment: .leading, spacing: 0) {
                if let run {
                    ConversationWorkTranscript(
                        run: run,
                        records: activities,
                        commentaryIDs: display.commentaryIDs,
                        hasFollowingResponse: hasResponseText && showsReply,
                        replyStartsWithBox: display.replyStartsWithBox,
                        timeline: display.timeline,
                        orderedActivities: display.orderedActivities
                    )
                }
                if showsReply {
                    ConversationResponse(
                        content: reply,
                        isStreaming: isStreaming,
                        isCut: !isStreaming && (run?.status == .cancelled || run?.status == .failed),
                        // The running turn's dots, under the text it is writing.
                        showsRunningDots: run?.status == .running && hasResponseText,
                        fileRow: ConversationFileRow(messageID: message.libraryItemID) { [actions, libraryItemID = message.libraryItemID] source in
                            try await actions.resolveFile(libraryItemID, source)
                        }
                    )
                    // Copy takes the whole answer: the visual replies' text above the reply's.
                    .environment(\.conversationCopyLead, Self.copyLead(visualKeys))
                } else if !hasResponseText, let run, run.status != .running, !visualKeys.isEmpty {
                    // An answer that is only a visual reply can be copied too:
                    // the page's readable text, from the same action row.
                    ConversationVisualReplyCopyButton(keys: visualKeys)
                        .frame(minHeight: ConversationMetrics.actionRowHeight)
                        // Its hover box reaches past the row; the gap keeps it clear of the page.
                        .padding(.top, ConversationMetrics.entryGap)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
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
                    columns: [GridItem(.adaptive(minimum: 150), spacing: ConversationMetrics.labelGap)],
                    spacing: ConversationMetrics.labelGap
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
/// Notices above the composer sit on the window's colour under their tint:
/// the chat scrolls beneath them and must not show through.
private struct MacAccessNotice: View {
    @Environment(\.wovenTheme) private var theme
    let message: String
    let openSettings: (() -> Void)?

    var body: some View {
        // Opaque over the chat, so a debug still draws it over web pictures too.
        Group {
            if let openSettings {
                Button(action: openSettings) { label(showsArrow: true) }
                    .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 12, minimumHeight: 32))
                    .background(theme.palette.themeWhisper,
                        in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
                    .background(WovenPalette.background,
                        in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
                    .help("Open Settings → Permissions & Access")
            } else {
                label(showsArrow: false)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(theme.palette.themeWhisper,
                        in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
                    .background(WovenPalette.background,
                        in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
            }
        }
        .conversationCoverSnapshot(radius: WovenMetrics.controlRadius)
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

/// Scroll measurements read in callbacks, and so not observed.
private final class TranscriptMeasurements {
    /// How far the end is below what shows.
    var endDistance: CGFloat = 0
    /// The offset, as `scrollTo(y:)` takes it.
    var offset: CGFloat = 0
    /// Where the reader's own scroll began.
    var readerScrollStart: CGFloat = 0
    /// How many times the content or viewport has changed size, the change
    /// the end was last put back for, and whether a put-back is queued.
    var resizes = 0
    /// When the viewport last changed size.
    var viewportChangedAt: CFTimeInterval = 0
    var restoredResize: Int?
    var restoreQueued = false
    /// The transcript the scroll view on screen shows; a position written
    /// back for any other is ignored.
    var shown: TranscriptIdentity?
    /// The scroll view that shows this transcript.
    weak var scrollView: NSScrollView?
}

/// Where the held row is, read in layout callbacks and so not observed.
private final class HeldRowPosition {
    /// The scroll offset, as `scrollTo(y:)` takes it.
    var offset: CGFloat = 0
    /// The held row's top in the content.
    var top: CGFloat?
    /// The held row's top from the top of the visible area.
    var screenTop: CGFloat?
}

/// A transcript's scroll view: one per chat, made again when its first view
/// arrives, so each opens at the bottom in its first layout.
/// The end of a transcript as its scroll view measures it: how far the end
/// is below what shows, where the view is, and the sizes that move them.
private struct TranscriptEnd: Equatable {
    let distance: CGFloat
    let offset: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat

    init(_ geometry: ScrollGeometry) {
        distance = max(0, geometry.contentSize.height - geometry.visibleRect.maxY).rounded()
        // As `scrollTo(y:)` takes it.
        offset = (geometry.contentOffset.y + geometry.contentInsets.top).rounded()
        contentHeight = geometry.contentSize.height.rounded()
        viewportHeight = geometry.containerSize.height.rounded()
    }
}

private struct TranscriptIdentity: Hashable {
    let conversationID: String?
    let hasLoaded: Bool
}

/// Copy for an answer that is only a visual reply: the page's readable text,
/// with the reply's own quiet Copy look.
private struct ConversationVisualReplyCopyButton: View {
    let keys: [String]
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WovenPalette.foreground.opacity(0.72))
                // The hover box of the other icon buttons (the panel buttons).
                .frame(width: PanelControlButton.size, height: PanelControlButton.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(WovenIconButtonStyle())
        // It takes the action row's height in the layout, its hover box
        // reaching past it, and its glyph lines up with the text edge.
        .padding(.vertical, -(PanelControlButton.size - ConversationMetrics.actionRowHeight) / 2)
        .padding(.leading, -(PanelControlButton.size - 13) / 2)
        .help("Copy complete response")
        .accessibilityLabel(copied ? "Response copied" : "Copy response")
        // `copy-visual` presses it (debug builds only).
        .debugRequest("copy-visual", copy)
    }

    private func copy() {
        let press = ConversationVisualReplyText.press()
        Task { @MainActor in
            guard let text = await ConversationVisualReplyText.text(of: keys),
                  ConversationVisualReplyText.claim(press) else { return }
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// When the reader last scrolled by wheel or key, and where: a transcript move
/// in the same moment is theirs, even when the content resized in the same
/// update. A wheel counts for the transcript under the pointer, a navigation
/// key for the active panel of the key window.
@MainActor enum ConversationReaderInput {
    private static var lastWheel = Date.distantPast
    private static var wheelScrollViews: [ObjectIdentifier] = []
    private static var lastKey = Date.distantPast
    private static weak var keyWindow: NSWindow?
    private static var monitor: Any?
    private static var users = 0
    /// Where the views `wheelScrollViews` holds were found under the pointer.
    private static var lastHit: (window: ObjectIdentifier, location: NSPoint)?

    /// A wheel or the pointer over this transcript, or a navigation key in its
    /// window while it is the active panel, within the last half second; or
    /// VoiceOver, whose scrolls come with no event the app sees.
    static func isRecent(for scrollView: NSScrollView?, isActivePanel: Bool, countsVoiceOver: Bool = true) -> Bool {
        guard let scrollView else { return false }
        if countsVoiceOver, NSWorkspace.shared.isVoiceOverEnabled { return true }
        let now = Date()
        if now.timeIntervalSince(lastWheel) < 0.5, wheelScrollViews.contains(ObjectIdentifier(scrollView)) { return true }
        return isActivePanel && now.timeIntervalSince(lastKey) < 0.5 && keyWindow != nil && keyWindow === scrollView.window
    }

    /// A move of these scroll views (and those around them) as a wheel makes.
    static func noteWheel(over view: NSView?) {
        var scrollViews: [ObjectIdentifier] = []
        var current = view
        while let next = current {
            if let scroll = next as? NSScrollView { scrollViews.append(ObjectIdentifier(scroll)) }
            current = next.superview
        }
        wheelScrollViews = scrollViews
        lastWheel = Date()
        // Found for no pointer location the monitor knows (the monitor sets its own).
        lastHit = nil
    }

    /// Watches the app's own wheel and navigation-key events while any
    /// transcript is shown. A key counts only outside text editing: a space
    /// typed in the composer is not the reader scrolling; one with a reply's
    /// read-only text focused is.
    static func start() {
        users += 1
        guard monitor == nil else { return }
        let keys: Set<UInt16> = [115, 116, 119, 121, 125, 126, 49]   // home, page up, end, page down, down, up, space
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown, .leftMouseDragged]) { event in
            // A drag on the scroller, or one selecting text past the edge, scrolls
            // too; one resizing the window does not.
            if event.type != .keyDown, let window = event.window, let content = window.contentView, !window.inLiveResize {
                // Within one trackpad scroll the pointer stays where it was,
                // over the same scroll views: those found for it still hold.
                let continuing = event.type == .scrollWheel && (event.phase == .changed || event.momentumPhase == .changed)
                if continuing, let lastHit, lastHit.window == ObjectIdentifier(window), lastHit.location == event.locationInWindow {
                    lastWheel = Date()
                } else {
                    // `hitTest` takes a point in the receiver's superview's coordinates.
                    let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                    noteWheel(over: content.hitTest(point))
                    lastHit = (ObjectIdentifier(window), event.locationInWindow)
                }
            } else if event.type == .keyDown, keys.contains(event.keyCode), let window = NSApp.keyWindow,
                      (window.firstResponder as? NSText)?.isEditable != true {
                keyWindow = window
                lastKey = Date()
            }
            return event
        }
    }

    static func stop() {
        users = max(0, users - 1)
        guard users == 0, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}

/// Hands back the scroll view a transcript's content sits in.
private struct ConversationScrollViewReader: NSViewRepresentable {
    let found: (NSScrollView?) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { found(view.enclosingScrollView) }
    }
}
