import SwiftUI
import UIKit

/// A bot conversation's scrolling transcript. It opens at the newest message
/// (a new thread at its top, with its starting message in view), follows new
/// output only while the reader is at the end, and offers a way back there.
struct BotTranscriptScroll<Content: View>: View {
    /// A new thread opens at its top.
    let startsAtTop: Bool
    let loading: Bool
    @Binding var following: Bool
    @ViewBuilder var content: (ScrollViewProxy) -> Content
    @State private var isUserScrolling = false

    static var endID: String { "bot-transcript-end" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content(proxy)
                    Color.clear.frame(height: 1).id(Self.endID)
                }
                .frame(maxWidth: 768)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(startsAtTop ? .top : .bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .onScrollPhaseChange { _, phase in
                isUserScrolling = phase == .interacting || phase == .tracking || phase == .decelerating
            }
            .onScrollGeometryChange(for: ConversationGeometry.self) { geometry in
                ConversationGeometry(contentHeight: geometry.contentSize.height,
                                     isNearBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 80,
                                     viewportHeight: geometry.containerSize.height)
            } action: { old, new in
                let resized = old.contentHeight != new.contentHeight || old.viewportHeight != new.viewportHeight
                if startsAtTop {
                    // A new thread stays at its top, with its starting message in view.
                } else if resized, following, !isUserScrolling {
                    jumpToEnd(proxy)
                } else if !resized || isUserScrolling {
                    // The reader's own movement decides whether the newest message stays in view.
                    following = new.isNearBottom
                }
            }
            .onChange(of: loading) { _, loading in
                if !loading, following, !startsAtTop { jumpToEnd(proxy) }
            }
            .onAppear {
                if !loading, following, !startsAtTop { jumpToEnd(proxy) }
            }
            .overlay(alignment: .bottom) {
                if !following {
                    LatestReplyButton {
                        following = true
                        jumpToEnd(proxy)
                    }
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private func jumpToEnd(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            guard !isUserScrolling else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(Self.endID, anchor: .bottom) }
        }
    }
}

/// One message of a bot's chat: the person's in the shared user bubble, the
/// bot's under its name in the shared transcript text, with its visual
/// replies, a stop or failure, and the threads started from it.
struct BotEntryRow: View {
    let entry: PiBotDisplayEntry
    let botName: String
    let replies: [PiBotThread]
    let canStartThread: Bool
    let onStartThread: () -> Void
    let onOpenThread: (Int) -> Void

    private var visualReplyOnly: Bool { entry.text.isEmpty && !entry.visualReplies.isEmpty && entry.error == nil }

    var body: some View {
        BotMessageLayout(isUser: entry.isUser) {
            // A visual reply on its own continues the reply above it.
            if !entry.isUser && !visualReplyOnly { BotAuthorName(name: botName) }
            if !entry.text.isEmpty {
                if entry.isUser {
                    ConversationUserBubble(content: entry.text.trimmingCharacters(in: .whitespacesAndNewlines)) { EmptyView() }
                        .contextMenu { menu }
                } else {
                    ConversationResponse(content: entry.text, isStreaming: false, showsCopyButton: false)
                        .padding(.horizontal, 4)
                }
            }
            ForEach(entry.visualReplies, id: \.id) { reply in
                ConversationHTMLRenderView(reference: reply).padding(.horizontal, 4)
            }
            if entry.isStopped { BotQuietLine(text: "Stopped") }
            if let error = entry.error { BotInlineError(text: error) }
            if !replies.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(replies) { reply in
                        BotThreadLink(title: reply.label, isTitled: reply.title?.isEmpty == false) { onOpenThread(reply.conversationId) }
                    }
                }
            }
            if !entry.isUser && !entry.text.isEmpty {
                BotMessageActions(text: entry.text, threadTitle: canStartThread ? "Start thread" : nil,
                                  threadGlyph: .gitBranch, onThread: onStartThread)
            }
        }
        .accessibilityAction(named: "Copy message") { UIPasteboard.general.string = entry.text }
        .accessibilityActions {
            if canStartThread, !visualReplyOnly { Button("Start thread", action: onStartThread) }
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.text }
        if canStartThread {
            Button { onStartThread() } label: { Label("Start thread", glyph: .gitBranch) }
        }
    }
}

/// The reply being written: the bot's name, its text so far or a static
/// Thinking label, and the running dots under it.
struct BotStreamingRow: View {
    let botName: String
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BotAuthorName(name: botName)
            if let text, !text.isEmpty {
                ConversationResponse(content: text, isStreaming: true, showsCopyButton: false)
                    .padding(.horizontal, 4)
            } else {
                BotThinkingLabel(text: "Thinking…")
            }
            ConversationRunningDots().padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The person's message on its way, before the host records it.
struct BotPendingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 56)
            ConversationUserBubble(content: text) { EmptyView() }.opacity(0.6)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A message's place: the person's on the trailing side, a bot's full width.
struct BotMessageLayout<Content: View>: View {
    let isUser: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 56) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) { content() }
                .frame(maxWidth: isUser ? nil : .infinity, alignment: isUser ? .trailing : .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct BotAuthorName: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(WovenPalette.foreground)
            .padding(.horizontal, 4)
    }
}

struct BotThinkingLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            LucideIcon(glyph: .brain, size: 15).foregroundStyle(WovenPalette.mutedForeground)
            Text(text).font(.subheadline).foregroundStyle(WovenPalette.mutedForeground)
        }
        .padding(.horizontal, 4)
    }
}

struct BotQuietLine: View {
    let text: String

    var body: some View {
        Text(text).font(.caption).foregroundStyle(WovenPalette.mutedForeground).padding(.horizontal, 4)
    }
}

/// A failed reply's own words, on the message it ended.
struct BotInlineError: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            LucideIcon(glyph: .alertCircle, size: 14).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(WovenPalette.danger)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(WovenPalette.danger.opacity(0.07), in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
    }
}

/// A thread hanging off the message it started from.
struct BotThreadLink: View {
    let title: String
    /// Titled threads, and threads with replies, read as links; others stay quiet.
    let isTitled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                LucideIcon(glyph: .messageSquareReply, size: 13)
                Text(title).font(.footnote.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(isTitled ? WovenPalette.success : WovenPalette.mutedForeground)
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open thread: \(title)")
    }
}

/// Under a bot's reply: copy it, and start or open its thread. On a phone they
/// stay in view, where the Mac shows them on hover.
struct BotMessageActions: View {
    let text: String
    let threadTitle: String?
    let threadGlyph: LucideGlyph
    let onThread: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                UIPasteboard.general.string = text
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                LucideIcon(glyph: copied ? .check : .copy, size: 15).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(copied ? "Copied" : "Copy")
            if let threadTitle {
                Button(action: onThread) {
                    HStack(spacing: 5) {
                        LucideIcon(glyph: threadGlyph, size: 14)
                        Text(threadTitle).font(.footnote.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
            }
        }
        .buttonStyle(WovenIconButtonStyle())
        .padding(.top, -8)
        .padding(.leading, -8)
        .accessibilityElement(children: .contain)
    }
}

/// The message a thread started from, above its own messages.
struct BotThreadOrigin<Origin: View>: View {
    @ViewBuilder var content: () -> Origin
    @Environment(\.wovenTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Started from").font(.caption.weight(.medium)).foregroundStyle(WovenPalette.mutedForeground)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: WovenMetrics.cardRadius, style: .continuous))
        .padding(.bottom, 20)
    }
}

/// "New thread" and what it picks up from, before a thread's first message.
struct BotNewThreadNote: View {
    let detail: String

    var body: some View {
        VStack(spacing: 4) {
            Text("New thread").font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(WovenPalette.mutedForeground)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}

/// A bot on a fallback model, out of usage, or back on its main model, in the
/// words the Mac's banner uses. It can be dismissed until the status changes.
struct BotModelStatusBanner: View {
    let text: PiBotModelStatusText
    let onDismiss: () -> Void

    private var tint: Color {
        switch text.tone {
        case .success: WovenPalette.success
        case .warning: WovenPalette.warning
        case .error: WovenPalette.danger
        }
    }

    var body: some View {
        BotBanner(glyph: text.tone == .success ? .circleCheck : .alertCircle, tint: tint, title: text.title, lines: text.lines,
                  actionTitle: "Dismiss", action: onDismiss)
            .accessibilityIdentifier("bot-model-status")
    }
}

/// A tinted note at the top of a conversation, with one action.
struct BotBanner: View {
    let glyph: LucideGlyph
    let tint: Color
    let title: String
    let lines: [String]
    let actionTitle: String
    var busy = false
    let action: () -> Void
    @Environment(\.wovenTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            LucideIcon(glyph: glyph, size: 15)
                .foregroundStyle(tint)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button(actionTitle, action: action)
                .font(.subheadline.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(WovenPalette.foreground)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(busy)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        // Opaque, so the transcript never shows through.
        .background(theme.palette.workspace, in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// The quiet lines above a bot composer: what the bots are doing when they
/// cannot take a message, and a send that failed.
struct BotComposerNotes: View {
    let caption: String?
    let error: String?
    let onDismissError: () -> Void

    var body: some View {
        if caption != nil || error != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(WovenPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("bot-composer-caption")
                }
                if let error {
                    Button(action: onDismissError) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(error).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            LucideIcon(glyph: .close, size: 11)
                        }
                        .font(.caption)
                        .foregroundStyle(WovenPalette.danger)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Dismisses this message")
                    .accessibilityIdentifier("bot-composer-error")
                }
            }
            .padding(.horizontal, 6)
        }
    }
}
