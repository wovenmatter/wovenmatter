import SwiftUI

/// The Chat tab: the open chat, or a new one. The composer sits directly above
/// the bottom bar; the transcript scrolls beneath both.
struct ChatTab: View {
    @Bindable var model: MobileModel
    @Environment(\.wovenTheme) private var theme
    @State private var chooserPresented = false

    private var chat: ChatModel { model.chat }
    private var app: ApplicationModel { model.app }

    var body: some View {
        VStack(spacing: 0) {
            TabRootHeader(title: title, subtitle: subtitle, onTitleTap: { chooserPresented = true }) {
                Button { chat.newChat(chat.target) } label: {
                    LucideIcon(glyph: .squarePen, size: 20).frame(width: 44, height: 44)
                }
                .disabled(chat.sessionID == nil)
                .accessibilityLabel("New chat with this agent")
                .accessibilityIdentifier("chat-new-session")
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomStack }
        }
        .task(id: chat.sessionID) {
            guard let id = chat.sessionID else { return }
            app.workspace.markConversationRead(id: id)
            await app.sessions.follow(id)
        }
        // A new chat's model and thinking choices, read again once its machine
        // answers or Quick Chat's sign-ins change.
        .task(id: newChatOptionsKey) { await chat.loadNewChatOptions() }
        .sheet(isPresented: $chooserPresented) {
            ChatChooser(model: model).sheetTheme(theme)
        }
    }

    private var title: String {
        if let conversation = chat.conversation { return conversation.title }
        return chat.target.isQuickChat ? "Quick Chat" : "New Chat"
    }

    /// Where the chat runs: Quick Chat, or its agent on its workspace, and the
    /// folder a new chat starts in.
    private var subtitle: String? {
        let target = chat.target
        let folder = chat.sessionID == nil ? target.folderID.flatMap { app.workspace.folder(id: $0)?.name } : nil
        if target.isQuickChat { return chat.sessionID == nil ? folder : "Quick Chat" }
        let agent = AgentRuntimeKind(runtime: target.runtime)?.displayName ?? chat.conversation?.runtimeName ?? target.runtime.rawValue
        return (["\(agent) · \(chat.machineName(target))"] + [folder].compactMap { $0 }).joined(separator: " · ")
    }

    private var newChatOptionsKey: String {
        let target = chat.target
        let machineID = target.machineID ?? model.deviceID ?? ""
        let runtimes = app.machines.machineRuntimes[machineID]?.map { "\($0.runtime.rawValue):\(String(describing: $0.signedIn))" } ?? []
        return [target.runtime.rawValue, machineID, chat.sessionID == nil ? "new" : "open",
                app.machineConnections?.isConnected(machineID) == true ? "up" : "down"].joined(separator: "|") + runtimes.joined(separator: ",")
    }

    @ViewBuilder private var content: some View {
        if let session = chat.session {
            if session.hasLoaded || !session.messages.isEmpty {
                ChatTranscript(app: app, session: session)
            } else {
                Color.clear
            }
        } else {
            NewChatEmptyState(target: chat.target, name: title)
        }
    }

    private var bottomStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session = chat.session, let interaction = session.interactions.first {
                SessionInteractionCard(interaction: interaction) { response in
                    Task { await session.answer(interaction.id, with: response) }
                }
                .disabled(!session.isOwnerReachable)
                .id(interaction.id)
            }
            ChatNotices(model: model)
            ChatComposer(model: model)
        }
        .frame(maxWidth: 768)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background { MobileBottomFade() }
    }
}

/// A new chat before its first message: who it is with.
private struct NewChatEmptyState: View {
    let target: ChatTarget
    let name: String

    var body: some View {
        VStack(spacing: 12) {
            AgentIcon(runtime: AgentRuntimeKind(runtime: target.runtime), size: 40)
            Text(name).font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-empty-state")
    }
}

/// Quiet lines above the composer: Quick Chat's setup, where a chat's owner
/// is, progress of a message just sent, and a send that failed.
private struct ChatNotices: View {
    @Bindable var model: MobileModel
    @Environment(\.wovenTheme) private var theme

    private var chat: ChatModel { model.chat }
    private var app: ApplicationModel { model.app }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if chat.target.isQuickChat, let deviceID = model.deviceID {
                QuickChatSetupNotice(model: model, deviceID: deviceID)
            }
            if let caption = ownerCaption {
                caption.font(.caption).foregroundStyle(WovenPalette.mutedForeground)
                    .accessibilityIdentifier("chat-owner-caption")
            }
            if let progress = chat.progress {
                Text(progress).font(.caption).foregroundStyle(WovenPalette.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("chat-send-progress")
            }
            if let error = chat.error ?? chat.session?.error {
                Text(error).font(.caption).foregroundStyle(WovenPalette.danger)
                    .accessibilityIdentifier("chat-error")
            }
        }
        .padding(.horizontal, 6)
    }

    /// An open chat whose owner the device cannot reach now shows its saved
    /// items; this says why sending is off.
    private var ownerCaption: Text? {
        guard let session = chat.session, let conversation = chat.conversation, session.hasLoaded,
              !session.isOwnerReachable, !chat.isSending else { return nil }
        if conversation.machineID == model.deviceID { return nil }
        if let machine = app.machines.machine(id: conversation.machineID) {
            return Text("\(machine.name) is offline. This chat continues when it’s back.")
        }
        return Text("Quick Chat from another device")
    }
}

/// "Sign in to a model provider to use Quick Chat", then "Add a web search key
/// for answers from the web", each opening its Settings page.
private struct QuickChatSetupNotice: View {
    @Bindable var model: MobileModel
    let deviceID: String
    @Environment(\.wovenTheme) private var theme

    var body: some View {
        // The core reports Quick Chat signed out until a model provider is signed in on this device.
        let quickChat = model.app.machines.machineRuntimes[deviceID]?.first { $0.runtime == .piDurable }
        let signIns = model.app.machines.providerSignIns(on: deviceID)
        let searchKey = signIns.contains {
            $0.state == .credentialsPresent && ProviderConnectionID(rawValue: $0.id)?.isSearchProvider == true
        }
        Group {
            if quickChat?.signedIn == false {
                notice("Sign in to a model provider to use Quick Chat", identifier: "quick-chat-setup") {
                    model.openSettings(.modelProviders)
                }
            } else if quickChat != nil, model.chat.sessionID == nil, !searchKey {
                notice("Add a web search key for answers from the web", identifier: "quick-chat-web-search-setup") {
                    model.openSettings(.webSearch)
                }
            }
        }
        .task(id: deviceID) { await model.app.machines.refreshProviderSignIns(on: deviceID) }
    }

    private func notice(_ text: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text).font(.footnote).foregroundStyle(WovenPalette.mutedForeground)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                LucideIcon(glyph: .arrowRight, size: 12).foregroundStyle(WovenPalette.mutedForeground)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous).fill(theme.palette.workspace)
                    .overlay(RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous).fill(theme.palette.themeWhisper))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
