import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The chat composer: a rounded theme-whisper surface with a growing text area
/// and the dictation microphone beside it, and beneath them the one compact
/// row of controls. Sending while a turn runs steers it; Stop interrupts it.
struct ChatComposer: View {
    @Bindable var model: MobileModel
    @State private var focused = false
    @State private var dictationEditor = MobileDictationEditor()
    @State private var importingFiles = false
    @State private var choosingPhotos = false
    @State private var photos: [PhotosPickerItem] = []

    private var chat: ChatModel { model.chat }
    private var session: SessionStore? { chat.session }
    private var isRunning: Bool { session?.isRunning == true }
    /// A new chat can always be written; an open one while its owner answers.
    private var reachable: Bool { session.map(\.isOwnerReachable) ?? (model.app.server?.isConnected == true || !chat.target.isQuickChat) }
    private var prompt: String { isRunning ? "Steer this run…" : "Chat…" }

    private var draft: Binding<String> {
        Binding(get: { chat.drafts[chat.draftKey, default: ""] }, set: { chat.drafts[chat.draftKey] = $0 })
    }

    private var staged: [AgentMessageAttachmentDraft] { chat.attachments[chat.draftKey] ?? [] }

    private var canSend: Bool {
        reachable && !chat.isSending && !DictationSession.shared.isBusy && session?.isUpdatingSettings != true
            && (!draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !staged.isEmpty { attachmentChips }
            HStack(alignment: .bottom, spacing: 8) {
                MobileDictationComposer(text: draft, focused: $focused, editor: dictationEditor,
                                        identity: "chat:\(chat.draftKey)", prompt: prompt)
                    .overlay(alignment: .topLeading) {
                        if draft.wrappedValue.isEmpty {
                            Text(prompt).foregroundStyle(WovenPalette.mutedForeground)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .accessibilityIdentifier("chat-composer")
                MobileDictationMicrophone(editor: dictationEditor)
            }
            ChatComposerControls(settings: session?.settings ?? chat.newChatSettings, sessionID: session?.sessionID,
                                 isUpdating: session?.isUpdatingSettings == true, error: session?.error,
                                 apply: { [chat] change in
                                     guard let session = chat.session else {
                                         chat.chooseForNewChat(change)
                                         return true
                                     }
                                     await session.updateSettings(change)
                                     return session.error == nil
                                 },
                                 tools: model.app.agentTools, configurable: reachable && !isRunning) {
                addMenu
            } submission: {
                submission
            }
        }
        .mobileComposerSurface()
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            attachFiles(urls)
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            attachPhotos(items)
        }
    }

    private var addMenu: some View {
        Menu {
            Button { choosingPhotos = true } label: { Label("Photos", systemImage: "photo") }
            Button { importingFiles = true } label: { Label("Files", systemImage: "doc") }
        } label: {
            LucideIcon(glyph: .plus, size: 20).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(WovenIconButtonStyle())
        .disabled(!reachable)
        .accessibilityLabel("Add to chat")
        .accessibilityIdentifier("chat-add")
    }

    @ViewBuilder private var submission: some View {
        if isRunning, let session {
            Button { Task { await session.stop() } } label: {
                Image(systemName: "stop.fill").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44)
            }
            .buttonStyle(WovenIconButtonStyle())
            .disabled(!reachable)
            .accessibilityLabel("Stop run")
            .accessibilityIdentifier("chat-stop")
        }
        MobileSendButton(enabled: canSend, label: isRunning ? "Steer run" : "Send message") {
            focused = isRunning && focused
            Task { await chat.send() }
        }
        .accessibilityIdentifier("chat-send")
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(staged) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.kind == .image ? "photo" : "doc")
                            .font(.caption.weight(.semibold)).foregroundStyle(WovenPalette.primary)
                        Text(attachment.displayName).font(.caption.weight(.medium)).lineLimit(1)
                        Button { chat.removeAttachment(attachment.id) } label: {
                            LucideIcon(glyph: .close, size: 12).frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.displayName)")
                    }
                    .padding(.leading, 9)
                    .background(WovenPalette.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func attachFiles(_ urls: [URL]) {
        Task {
            var files: [(url: URL, mimeType: String)] = []
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                // A copy the app owns, since the picked file is readable only now.
                let copy = URL.temporaryDirectory.appending(path: UUID().uuidString).appending(path: url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    files.append((copy, UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"))
                } catch {
                    chat.error = error.localizedDescription
                }
            }
            await chat.attach(files)
        }
    }

    private func attachPhotos(_ items: [PhotosPickerItem]) {
        Task {
            var files: [(url: URL, mimeType: String)] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first { $0.conforms(to: .image) } ?? .jpeg
                let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
                    .appendingPathExtension(type.preferredFilenameExtension ?? "jpg")
                do {
                    try data.write(to: url)
                    files.append((url, type.preferredMIMEType ?? "image/jpeg"))
                } catch {
                    chat.error = error.localizedDescription
                }
            }
            await chat.attach(files)
        }
    }
}

/// The composer's surface: rounded theme-whisper over the page colour, opaque so
/// the transcript scrolling beneath never shows through. Bot chats use it too.
private struct MobileComposerSurface: ViewModifier {
    @Environment(\.wovenTheme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: WovenMetrics.composerRadius, style: .continuous)
        content
            .padding(.horizontal, 15)
            .padding(.top, 13)
            .padding(.bottom, 6)
            .background {
                shape.fill(theme.palette.workspace)
                    .overlay(shape.fill(theme.palette.themeWhisper))
                    .overlay(shape.stroke(theme.palette.border, lineWidth: 0.5))
            }
    }
}

extension View {
    func mobileComposerSurface() -> some View { modifier(MobileComposerSurface()) }
}

/// The composer's round send button.
struct MobileSendButton: View {
    let enabled: Bool
    let label: String
    let action: () -> Void
    @Environment(\.wovenTheme) private var theme

    var body: some View {
        Button(action: action) {
            LucideIcon(glyph: .arrowUp, size: 20)
                .foregroundStyle(WovenPalette.primaryForeground)
                .frame(width: 40, height: 40)
                .background(WovenPalette.primaryFill, in: Circle())
                .overlay { if theme == .dark { Circle().stroke(theme.palette.themeRing, lineWidth: 1) } }
                .opacity(enabled ? 1 : 0.4)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
