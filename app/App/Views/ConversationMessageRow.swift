import SwiftUI

/// One message of a chat, as the Mac and the iPhone and iPad draw it: a user
/// bubble, a reply with its work, or a notice.
struct MessageRow: View {
    let message: WorkspaceMessageRecord
    let run: WorkspaceRunRecord?
    let activities: [WorkspaceRunActivityRecord]
    let onOpenAttachment: (SessionMessageAttachment) -> Void
    let resolveFile: (String) async throws -> URL
    let layout: ConversationMessageLayout.Row
    var onNewSession: (() -> Void)? = nil

    private var isStreaming: Bool {
        AssistantStreamingText.isStreaming(messageStatus: message.status, runStatus: run?.status)
    }
    private var assistantBody: String {
        isStreaming ? AssistantStreamingText.readyPrefix(of: transcript.body) : transcript.body
    }

    /// The reply's text, apart from the commentary the work log shows.
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
                            records: activities,
                            commentaryIDs: transcript.commentaryIDs,
                            hasFollowingResponse: hasResponseText,
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
                        VStack(alignment: .leading, spacing: 0) {
                            ConversationResponse(
                                content: assistantBody,
                                document: nil,
                                isStreaming: isStreaming
                            )
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            // The running turn's dots, under the text it is writing.
                            if run?.status == .running && hasResponseText {
                                ConversationRunningDots().padding(.top, 4)
                            }
                        }
                        #if os(macOS)
                        if !isStreaming {
                            ConversationFilePreviews(content: assistantBody, messageID: message.libraryItemID, resolveFile: resolveFile)
                        }
                        #endif
                    }
                }
                .frame(maxWidth: isUser ? nil : .infinity, alignment: isUser ? .trailing : .leading)
                if !isUser { Spacer(minLength: 0) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Text the work transcript leaves to the response below it.
    private var hasResponseText: Bool {
        !assistantBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsAssistantBody: Bool {
        ConversationMessageLayout.showsAssistantBody(
            content: message.content,
            displayedBody: assistantBody,
            failedRunError: run?.status == .failed ? run?.error : nil
        )
    }

    private var projectedTimeline: ConversationWorkTimeline {
        ConversationWorkTimeline(records: activities, commentaryIDs: transcript.commentaryIDs)
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
