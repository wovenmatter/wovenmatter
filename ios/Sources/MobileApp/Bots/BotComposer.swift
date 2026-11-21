import SwiftUI
import UniformTypeIdentifiers

/// A bot chat's or the Forum's composer: the Chat tab's surface, text area and
/// dictation microphone, with one row beneath of attach, stop and send. Bots
/// take text and code files as message text, as on the Mac, and have no model
/// controls. Typing "@" lists `mentions` inline, narrowing as the name is typed.
struct BotComposer: View {
    @Binding var draft: BotDraftStore.Draft
    /// Keeps dictation with this conversation's draft.
    let identity: String
    let prompt: String
    /// The conversation takes a message now.
    let canSend: Bool
    /// Stop interrupts the bots working here; nil when nothing runs.
    let onStop: (() -> Void)?
    var mentions: [ComposerMention] = []
    let onSend: () -> Void
    let onAttachFailed: (String) -> Void
    @State private var focused = false
    @State private var dictationEditor = MobileDictationEditor()
    @State private var importing = false

    private var matches: [ComposerMention] { Array(ComposerMention.matching(draft.text, among: mentions).prefix(6)) }

    private var sendable: Bool {
        canSend && !DictationSession.shared.isBusy
            && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !matches.isEmpty { mentionList }
            if !draft.attachments.isEmpty { attachmentChips }
            HStack(alignment: .bottom, spacing: 8) {
                MobileDictationComposer(text: $draft.text, focused: $focused, editor: dictationEditor,
                                        identity: identity, prompt: prompt)
                    .overlay(alignment: .topLeading) {
                        if draft.text.isEmpty {
                            Text(prompt).foregroundStyle(WovenPalette.mutedForeground)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .accessibilityIdentifier("bot-composer")
                MobileDictationMicrophone(editor: dictationEditor)
            }
            HStack(spacing: 2) {
                Button { importing = true } label: {
                    LucideIcon(glyph: .plus, size: 20).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(WovenIconButtonStyle())
                .accessibilityLabel("Attach text or code files")
                .accessibilityIdentifier("bot-attach")
                Spacer(minLength: 0)
                if let onStop {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(WovenIconButtonStyle())
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("bot-stop")
                }
                MobileSendButton(enabled: sendable, label: "Send message", action: onSend)
                    .accessibilityIdentifier("bot-send")
            }
            .foregroundStyle(WovenPalette.foreground)
        }
        .mobileComposerSurface()
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.attachable, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            attach(urls)
        }
    }

    private static let attachable: [UTType] = [.text, .sourceCode, .json, .xml, .yaml, .commaSeparatedText, .html, .shellScript]

    /// Who "@" offers, written out in full when chosen.
    private var mentionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches, id: \.name) { mention in
                Button { complete(mention) } label: {
                    HStack(spacing: 8) {
                        Text("@\(mention.name)").font(.callout.weight(.medium)).lineLimit(1)
                        if let detail = mention.detail {
                            Text(detail).font(.caption).foregroundStyle(WovenPalette.mutedForeground).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(WovenPalette.foreground)
                .keepsKeyboard()
                .accessibilityIdentifier("bot-mention-\(mention.name)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mentions")
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(draft.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "doc").font(.caption.weight(.semibold)).foregroundStyle(WovenPalette.primary)
                        Text(attachment.name).font(.caption.weight(.medium)).lineLimit(1)
                        Button { draft.attachments.removeAll { $0.id == attachment.id } } label: {
                            LucideIcon(glyph: .close, size: 12).frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .padding(.leading, 9)
                    .background(WovenPalette.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
        }
        .scrollIndicators(.never)
    }

    /// Writes the chosen name out through the text view's own input, so the
    /// keyboard's pending correction of the typed part cannot put it back.
    private func complete(_ mention: ComposerMention) {
        let completed = ComposerMention.completing(draft.text, with: mention)
        guard let view = dictationEditor.textView, view.text == draft.text, let at = draft.text.lastIndex(of: "@"),
              let start = view.position(from: view.beginningOfDocument, offset: draft.text[..<at].utf16.count),
              let range = view.textRange(from: start, to: view.endOfDocument) else {
            draft.text = completed
            return
        }
        view.unmarkText()
        view.replace(range, withText: "@\(mention.name) ")
        draft.text = view.text
    }

    private func attach(_ urls: [URL]) {
        do {
            let added = try urls.map { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try PiBotAttachmentDraft.read(url)
            }
            draft.attachments += added
        } catch {
            onAttachFailed(error.localizedDescription)
        }
    }
}
