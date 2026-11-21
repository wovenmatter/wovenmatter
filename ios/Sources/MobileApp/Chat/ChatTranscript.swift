import QuickLook
import SwiftUI

/// One row of the transcript: a message, or one part of it.
private struct TranscriptRow: Identifiable {
    let message: WorkspaceMessageRecord
    let layout: ConversationMessageLayout.Row
    var id: String { layout.id }
}

/// The open chat's transcript, drawn with the Mac's own message, reply and
/// work views. It follows the live edge only while the reader is there; a
/// control returns to the latest reply. Older messages page in on request.
struct ChatTranscript: View {
    let app: ApplicationModel
    let session: SessionStore
    @State private var scrollState = ConversationScrollState()
    @State private var isUserScrolling = false
    @State private var transcriptOwnsScroll = false
    @State private var scrollRevision = 0
    @State private var isLoadingOlder = false
    @State private var preview: URL?
    @State private var previewError: String?

    var body: some View {
        let runs = runsByAssistantMessageID
        let activities = Dictionary(grouping: session.runActivities, by: \.runID)
        let rows = visibleMessages.flatMap { message in
            ConversationMessageLayout.rows(messageID: message.id, role: message.role)
                .map { TranscriptRow(message: message, layout: $0) }
        }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if session.hasOlderMessages {
                        Button(isLoadingOlder ? "Loading…" : "Load older messages", systemImage: "arrow.up") {
                            loadOlder()
                        }
                        .font(.caption)
                        .buttonStyle(WovenQuietButtonStyle())
                        .disabled(isLoadingOlder)
                        .padding(.bottom, 24)
                        .accessibilityIdentifier("chat-load-older")
                    }
                    ForEach(rows) { row in
                        let run = runs[row.message.id]
                        MessageRow(
                            message: row.message,
                            run: run.flatMap { $0.status == .queued ? nil : $0 },
                            activities: run.map { activities[$0.id] ?? [] } ?? [],
                            onOpenAttachment: openAttachment,
                            resolveFile: { source in
                                try await app.library.fileURL(id: WorkspaceLibraryItem.identifier(
                                    messageID: row.message.libraryItemID, source: source))
                            },
                            layout: row.layout)
                        .id(row.id)
                        .padding(.top, row.id == rows.first?.id ? 0 : row.layout.spacingBefore)
                    }
                    Color.clear.frame(height: 1).id(Self.end)
                }
                .frame(maxWidth: 768)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .environment(\.conversationTranscriptInteraction) { takeScroll() }
            .environment(\.conversationActivityDetails) { runID, activityID in
                try await session.activityDetails(runID: runID, activityID: activityID)
            }
            .onScrollPhaseChange { _, phase in
                isUserScrolling = phase == .interacting || phase == .tracking || phase == .decelerating
                if isUserScrolling {
                    transcriptOwnsScroll = false
                    scrollRevision += 1
                }
            }
            .onScrollGeometryChange(for: ConversationGeometry.self) { geometry in
                ConversationGeometry(contentHeight: geometry.contentSize.height,
                                     isNearBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 80,
                                     viewportHeight: geometry.visibleRect.height)
            } action: { old, new in
                if scrollState.geometryChanged(from: old, to: new, isUserScrolling: isUserScrolling,
                                               transcriptOwnsScroll: transcriptOwnsScroll, isPrependingHistory: isLoadingOlder) {
                    followBottom(proxy)
                }
            }
            .onChange(of: session.sessionID, initial: true) { _, id in
                scrollRevision += 1
                isUserScrolling = false
                transcriptOwnsScroll = false
                scrollState.conversationChanged(to: id)
                contentChanged(proxy)
            }
            .onChange(of: session.messages.last?.id) { _, _ in contentChanged(proxy) }
            .onChange(of: session.hasLoaded) { _, _ in contentChanged(proxy) }
            .overlay(alignment: .bottom) {
                if !scrollState.isNearBottom, !rows.isEmpty {
                    LatestReplyButton { showLatest(proxy) }.padding(.bottom, 10)
                }
            }
        }
        .environment(\.conversationTranscriptState, session.transcriptState)
        .quickLookPreview($preview)
        .alert("Could not open attachment", isPresented: Binding(
            get: { previewError != nil }, set: { if !$0 { previewError = nil } })) {
            Button("OK", role: .cancel) { previewError = nil }
        } message: { Text(previewError ?? "") }
    }

    private static let end = "chat-end"

    private var runsByAssistantMessageID: [String: WorkspaceRunRecord] {
        session.runs.reduce(into: [:]) { if let id = $1.assistantMessageID { $0[id] = $1 } }
    }

    /// An empty reply to a run that has not started yet is not shown.
    private var visibleMessages: [WorkspaceMessageRecord] {
        let runs = runsByAssistantMessageID
        return session.messages.filter { $0.role != .assistant || !$0.content.isEmpty || runs[$0.id]?.status != .queued }
    }

    private func openAttachment(_ attachment: SessionMessageAttachment) {
        guard let digest = attachment.contentHash else { return previewError = "This attachment is not on this device." }
        Task {
            do { preview = try await app.library.attachmentURL(contentHash: digest, fileName: attachment.fileName, mimeType: attachment.mimeType) }
            catch { previewError = error.localizedDescription }
        }
    }

    private func loadOlder() {
        guard !isLoadingOlder else { return }
        takeScroll()
        isLoadingOlder = true
        Task {
            await session.loadOlderMessages()
            try? await Task.sleep(for: .milliseconds(300))
            isLoadingOlder = false
        }
    }

    /// The reader acted inside the transcript (opened work, selected text):
    /// new output no longer moves it.
    private func takeScroll() {
        transcriptOwnsScroll = true
        scrollRevision += 1
        scrollState.setNearBottom(false)
    }

    private func contentChanged(_ proxy: ScrollViewProxy) {
        guard !isUserScrolling else { return }
        let action = scrollState.contentChanged(conversationID: session.sessionID, hasMessages: !session.messages.isEmpty,
                                                isPrependingHistory: isLoadingOlder)
        if action != .none { followBottom(proxy) }
    }

    private func showLatest(_ proxy: ScrollViewProxy) {
        transcriptOwnsScroll = false
        scrollRevision += 1
        scrollState.setNearBottom(true)
        followBottom(proxy)
    }

    private func followBottom(_ proxy: ScrollViewProxy) {
        let revision = scrollRevision
        Task { @MainActor in
            await Task.yield()
            guard revision == scrollRevision, !isUserScrolling, !isLoadingOlder else { return }
            scrollState.setNearBottom(true)
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }
}

/// Returns to the newest reply, floating over the transcript. Bot chats use it too.
struct LatestReplyButton: View {
    @Environment(\.wovenTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LucideIcon(glyph: .arrowDown, size: 16)
                .foregroundStyle(WovenPalette.foreground)
                .frame(width: 40, height: 40)
                .background {
                    if reduceTransparency {
                        Circle().fill(theme.palette.workspace).overlay(Circle().fill(theme.palette.themeSoft))
                    } else {
                        Circle().fill(.regularMaterial)
                    }
                }
                .overlay(Circle().stroke(theme.palette.border, lineWidth: 0.5))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel("Latest reply")
        .accessibilityIdentifier("chat-latest-reply")
    }
}
