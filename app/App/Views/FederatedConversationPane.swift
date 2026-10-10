import SwiftUI
import WovenMatterCore

/// Imported conversations retain native rendering and controls, while all actions
/// are routed through the execution owner (including background-service mode).
struct FederatedConversationPane: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    let conversation: WorkspaceConversationRecord
    let savedMessages: [WorkspaceMessageRecord]
    @Binding var draft: String
    let sendInProgress: Bool
    let onSend: () -> Void
    @State private var olderMessages: [CompanionMessage] = []
    @State private var olderCursor: String?
    @State private var loadingOlder = false
    @State private var hasLoadedEarlier = false
    private var snapshot: FederatedExecutionSnapshot? { model.federatedExecutionSnapshots[conversation.id] }
    private var runID: String? { snapshot?.transcript?.activeRunID }
    private var messages: [CompanionMessage] {
        let current = snapshot?.transcript?.messages ?? savedMessages.map {
            CompanionMessage(id: $0.id, conversationID: conversation.id, role: $0.role, content: $0.content)
        }
        let ids = Set(current.map(\.id))
        return olderMessages.filter { !ids.contains($0.id) } + current
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DashboardLucideIcon(glyph: .folder, size: 16)
                Text(snapshot?.workspace.name ?? "Execution workspace").font(.subheadline.weight(.medium))
                Spacer()
                Text(snapshot?.online == true ? "Connected" : "Saved history").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
            }.padding(.horizontal, 24).padding(.vertical, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if let cursor = hasLoadedEarlier ? olderCursor : snapshot?.transcript?.olderCursor {
                            Button(loadingOlder ? "Loading…" : "Load earlier messages") { Task { await loadEarlier(cursor) } }
                                .buttonStyle(DashboardQuietButtonStyle()).disabled(loadingOlder)
                        }
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message.role == "user" ? "You" : message.role == "tool" ? "Tool" : snapshot?.capability?.displayName ?? "Agent")
                                    .font(.caption.weight(.semibold)).foregroundStyle(DashboardPalette.mutedForeground)
                                ConversationMarkdown(document: .init(message.content), isStreaming: message.status == "streaming")
                                    .textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                        }
                        ForEach(snapshot?.transcript?.activities ?? []) { activity in
                            DisclosureGroup(activity.title) {
                                if let detail = activity.detail { Text(detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                            }.font(.subheadline)
                        }
                        Color.clear.frame(height: 1).id("federated-bottom")
                    }.padding(24)
                }
                .onChange(of: conversation.id, initial: true) { _, _ in proxy.scrollTo("federated-bottom", anchor: .bottom) }
            }
            VStack(alignment: .leading, spacing: 12) {
                if let error = snapshot?.error { Text(error).font(.caption).foregroundStyle(DashboardPalette.mutedForeground).textSelection(.enabled) }
                ForEach(snapshot?.interactions ?? []) { interaction in
                    FederatedInteractionCard(interaction: interaction) { response in
                        await model.actOnFederatedConversation(.respond(interaction, response), conversationID: conversation.id)
                    }
                }
                if let session = snapshot?.session, session.canConfigure {
                    HStack {
                        selectionMenu("Model", values: session.models, selected: session.model) { value in
                            .configureSession(id: conversation.id, model: value, thinking: nil, permission: nil)
                        }
                        selectionMenu("Thinking", values: session.thinkingLevels, selected: session.thinking) { value in
                            .configureSession(id: conversation.id, model: nil, thinking: value, permission: nil)
                        }
                        selectionMenu("Permissions", values: session.permissions, selected: session.permission) { value in
                            .configureSession(id: conversation.id, model: nil, thinking: nil, permission: value)
                        }
                        Spacer()
                    }.disabled(runID != nil || snapshot?.online != true)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Message", text: $draft, axis: .vertical).lineLimit(2...8).textFieldStyle(.plain)
                        .padding(12).background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius))
                        .accessibilityLabel("Message execution workspace")
                    if let runID {
                        Button("Stop") { Task { await model.actOnFederatedConversation(.stop(conversationID: conversation.id, runID: runID), conversationID: conversation.id) } }
                            .buttonStyle(DashboardQuietButtonStyle()).disabled(snapshot?.online != true)
                    }
                    Button(runID == nil ? "Send" : "Steer", action: onSend).buttonStyle(DashboardPrimaryButtonStyle())
                        .disabled(sendInProgress || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || snapshot?.online != true || (runID != nil && snapshot?.capability?.canSteer != true))
                }
            }.padding(20)
        }
        .task(id: conversation.id) {
            olderMessages = []; olderCursor = nil; hasLoadedEarlier = false
            while !Task.isCancelled {
                await model.refreshFederatedConversation(conversation.id)
                do { try await Task.sleep(for: .seconds(snapshot?.online == true ? 1 : 5)) } catch { return }
            }
        }
    }
    @ViewBuilder private func selectionMenu(_ title: String, values: [CompanionSelection], selected: String?, action: @escaping (String) -> CompanionWorkspaceAction) -> some View {
        if !values.isEmpty {
            Menu(values.first { $0.id == selected }?.label ?? title) {
                ForEach(values) { value in
                    Button(value.label) { Task { await model.actOnFederatedConversation(.configure(conversationID: conversation.id, action: action(value.id)), conversationID: conversation.id) } }
                }
            }.font(.caption)
        }
    }
    private func loadEarlier(_ cursor: String) async {
        loadingOlder = true; defer { loadingOlder = false }
        await model.actOnFederatedConversation(.earlier(conversationID: conversation.id, before: cursor), conversationID: conversation.id)
        if let page = snapshot?.transcript {
            let ids = Set(olderMessages.map(\.id))
            olderMessages = page.messages.filter { !ids.contains($0.id) } + olderMessages
            olderCursor = page.olderCursor; hasLoadedEarlier = true
        }
        await model.refreshFederatedConversation(conversation.id)
    }
}

private struct FederatedInteractionCard: View {
    let interaction: CompanionPendingInteraction
    let respond: (CompanionInteractionResponse) async -> Void
    @State private var selected: [String: Set<String>] = [:]
    @State private var freeText: [String: String] = [:]
    @State private var submitting = false
    private var answers: [String: [String]] {
        Dictionary(uniqueKeysWithValues: interaction.questions.map { question in
            var values = Array(selected[question.id] ?? []).sorted()
            let text = freeText[question.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { values.append(text) }
            return (question.id, values)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(interaction.title).font(.headline)
            if let detail = interaction.detail { Text(detail).font(.subheadline) }
            ForEach(interaction.questions) { question in
                Text(question.prompt).font(.subheadline.weight(.medium))
                ForEach(question.options) { option in
                    Toggle(option.label, isOn: Binding(get: { selected[question.id]?.contains(option.id) == true }, set: { value in
                        if question.allowsMultiple {
                            if value { selected[question.id, default: []].insert(option.id) } else { selected[question.id]?.remove(option.id) }
                        } else { selected[question.id] = value ? [option.id] : [] }
                    })).toggleStyle(.checkbox)
                }
                if question.allowsFreeText { TextField("Answer", text: Binding(get: { freeText[question.id, default: ""] }, set: { freeText[question.id] = $0 })).textFieldStyle(.roundedBorder) }
            }
            HStack {
                ForEach(interaction.options) { option in
                    Button(option.label) { send(.init(optionID: option.id)) }.buttonStyle(DashboardQuietButtonStyle())
                }
                if !interaction.questions.isEmpty {
                    Button("Submit answers") { send(.init(answers: answers)) }.buttonStyle(DashboardPrimaryButtonStyle())
                        .disabled(interaction.questions.contains { $0.isRequired && answers[$0.id]?.isEmpty != false })
                }
                Button("Cancel") { send(.init(cancelled: true)) }.buttonStyle(DashboardQuietButtonStyle())
            }.disabled(submitting)
        }.padding(14).background(DashboardPalette.muted, in: RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius))
    }
    private func send(_ response: CompanionInteractionResponse) {
        submitting = true
        Task { await respond(response); submitting = false }
    }
}
