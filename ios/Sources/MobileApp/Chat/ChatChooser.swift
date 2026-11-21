import SwiftUI

/// Opened from the chat's title: New Chat (Quick Chat first, then each
/// workspace reachable now, once under its own name with its agents) and
/// Recents.
struct ChatChooser: View {
    @Bindable var model: MobileModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.wovenTheme) private var theme
    @State private var search = ""

    private var app: ApplicationModel { model.app }

    var body: some View {
        NavigationStack {
            List {
                Section("New Chat") {
                    row(title: "Quick Chat", runtime: .defaultAgent, identifier: "new-chat-quick-chat") {
                        model.chat.newChat(.quickChat)
                    }
                }
                ForEach(app.machines.onlineMachines) { machine in
                    let agents = app.workspace.agents(on: machine.id)
                    if !agents.isEmpty {
                        Section(machine.name) {
                            ForEach(agents) { agent in
                                row(title: agent.displayName, runtime: agent.runtimeKind, identifier: "new-chat-\(agent.id)") {
                                    model.chat.newChat(ChatTarget(runtime: agent.runtimeKind.runtime, machineID: agent.machineID))
                                }
                            }
                        }
                    }
                }
                if !recents.isEmpty {
                    Section("Recents") {
                        ForEach(recents) { conversation in
                            Button {
                                model.open(sessionID: conversation.id)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conversation.title).lineLimit(1)
                                    Text(place(conversation)).font(.caption).foregroundStyle(WovenPalette.mutedForeground).lineLimit(1)
                                }
                                .frame(minHeight: 44, alignment: .leading)
                            }
                            .foregroundStyle(WovenPalette.foreground)
                            .listRowBackground(theme.palette.themeWhisper)
                            .accessibilityIdentifier("recent-\(conversation.id)")
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search chats")
            .mobilePageSurface()
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The newest chats first, with bots' chats left to the Bots tab.
    private var recents: [WorkspaceConversationRecord] {
        (app.workspace.workspaceOverview?.conversations ?? [])
            .filter { !$0.isArchived && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
            .sorted { ($0.lastMessageAt ?? .distantPast, $0.id) > ($1.lastMessageAt ?? .distantPast, $1.id) }
            .prefix(50).map { $0 }
    }

    private func place(_ conversation: WorkspaceConversationRecord) -> String {
        if conversation.machineID == model.deviceID { return "Quick Chat" }
        guard let machine = app.machines.machine(id: conversation.machineID) else { return "Quick Chat · another device" }
        return "\(conversation.runtimeName) · \(machine.name)"
    }

    private func row(title: String, runtime: AgentRuntimeKind, identifier: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            // Opened from another tab (Folders), the new chat shows in the Chat tab.
            model.tab = .chat
            dismiss()
        } label: {
            HStack(spacing: 12) {
                AgentIcon(runtime: runtime, size: 24)
                Text(title)
            }
            .frame(minHeight: 44, alignment: .leading)
        }
        .foregroundStyle(WovenPalette.foreground)
        .listRowBackground(theme.palette.themeWhisper)
        .accessibilityIdentifier(identifier)
    }
}
