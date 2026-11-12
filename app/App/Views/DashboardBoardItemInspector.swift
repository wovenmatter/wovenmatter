import SwiftUI
import WovenMatterCore

extension BoardTaskStatus {
    var boardTitle: String {
        switch self {
        case .todo: "To do"
        case .doing: "In progress"
        case .blocked: "Blocked"
        case .done: "Done"
        case .canceled: "Canceled"
        }
    }
}

struct DashboardBoardItemInspector: View {
    @Binding var document: NoteDocument
    @Binding var viewState: DashboardCanvasViewState
    let itemID: String
    var conversations: [WorkspaceConversationRecord] = []
    var onSend: ((String, String) async throws -> Void)?
    var onOpenSession: ((String) -> Void)?
    @State private var sending = false
    @State private var sendResult: String?
    private var item: BoardItem { document.materializedPage().boardItems?[itemID] ?? BoardItem() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if document.materializedPage().pageNodes?[itemID]?.isSection != true {
                Toggle("Task", isOn: Binding(get: { item.task != nil }, set: { enabled in
                    update { $0.task = enabled ? BoardTask() : nil }
                }))
            }
            if let task = item.task {
                Picker("State", selection: Binding(get: { item.task?.status ?? .todo }, set: { status in
                    update { $0.task?.status = status }
                })) {
                    ForEach([BoardTaskStatus.todo, .doing, .blocked, .done, .canceled], id: \.self) { status in
                        Text(status.boardTitle).tag(status)
                    }
                }.pickerStyle(.menu)
                TextField("Assignee or agent", text: Binding(get: { item.task?.assignee ?? "" }, set: { value in
                    update { $0.task?.assignee = value }
                })).dashboardQuietTextInput().accessibilityLabel("Task assignee")
                Text("Assignment is a label. Use Send to chat to request work.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Outcome, findings, or next steps", text: Binding(get: { item.task?.outcome ?? "" }, set: { value in
                    update { $0.task?.outcome = value }
                }), axis: .vertical)
                    .lineLimit(3...7).dashboardQuietTextInput().accessibilityLabel("Task outcome")
                if task.status == .done && task.outcome.isEmpty {
                    Text("Leave an outcome so the next participant can pick up the work.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Instructions or skill reference", isOn: Binding(get: { item.role == .instructions }, set: { enabled in
                update { $0.role = enabled ? .instructions : .content }
            }))
            if item.role == .instructions {
                Text("Reference context only. This does not install a skill, run its contents, or grant permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(reviewLabel).font(.caption)
                Spacer()
                Menu("Review") {
                    Button("Request review") { update { $0.review = .needed } }
                    Button("Mark reviewed") { update { $0.review = .approved } }
                    Button("Dismiss recommendation") { update { $0.review = .dismissed } }
                    Button("Clear review marker") { update { $0.review = nil } }
                }.fixedSize()
            }
            TextField("Change summary", text: Binding(get: { item.lastChange ?? "" }, set: { value in
                update { $0.lastChange = value.isEmpty ? nil : value }
            }), axis: .vertical).lineLimit(1...3).dashboardQuietTextInput()
            if let actor = item.updatedBy {
                HStack {
                    Text("Updated by \(actorName(actor))").font(.caption).lineLimit(2)
                    if let id = actor.sessionID, let onOpenSession,
                       conversations.contains(where: { $0.id == id }) {
                        Button("Open chat") { onOpenSession(id) }
                    }
                }.foregroundStyle(.secondary)
            }
            if let date = updatedDate {
                Text(date, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            Text("Linked chats").font(.caption)
            ForEach(item.sessions, id: \.self) { id in
                HStack {
                    if let chat = conversations.first(where: { $0.id == id }), let onOpenSession {
                        Button(chat.title.isEmpty ? "Untitled chat" : chat.title) { onOpenSession(id) }
                            .lineLimit(1)
                    } else {
                        Text("Chat unavailable on this device").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { update { $0.sessions.removeAll { $0 == id } } } label: { Image(systemName: "xmark") }
                        .help("Remove link; keep the chat").accessibilityLabel("Remove chat link")
                }
            }
            if let onSend {
                Menu(sending ? "Sending…" : "Send to chat") {
                    ForEach(conversations, id: \.id) { chat in
                        Button(chat.title.isEmpty ? "Untitled chat" : chat.title) {
                            sending = true
                            sendResult = nil
                            Task { @MainActor in
                                defer { sending = false }
                                do {
                                    try await onSend(itemID, chat.id)
                                    viewState.error = nil
                                    sendResult = "Sent to \(chat.title.isEmpty ? "chat" : chat.title)."
                                } catch { viewState.error = error.localizedDescription }
                            }
                        }
                    }
                }.disabled(sending || conversations.isEmpty)
                if conversations.isEmpty {
                    Text("Create a chat to send this component to an agent.").font(.caption).foregroundStyle(.secondary)
                }
                if let sendResult { Text(sendResult).font(.caption).foregroundStyle(.secondary) }
                Text("Uses that chat's current agent and permissions. Its run does not change task state automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.font(.system(size: 12))
    }

    private var reviewLabel: String {
        switch item.review {
        case .needed: "Needs review"
        case .approved: "Reviewed"
        case .dismissed: "Dismissed"
        case nil: "No review requested"
        }
    }
    private func actorName(_ actor: BoardActor) -> String {
        switch actor.kind {
        case .user: "You"
        case .outside: actor.label ?? "External agent"
        case .session: actor.sessionID.flatMap { id in conversations.first { $0.id == id }?.title } ?? actor.label ?? "Agent"
        }
    }
    private var updatedDate: Date? {
        guard let value = item.updatedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private func update(_ change: (inout BoardItem) -> Void) {
        commitPage(document: $document, state: $viewState) { value in
            guard value.blocks.contains(where: { $0.id == itemID }) else { return }
            var item = value.boardItems?[itemID] ?? BoardItem()
            change(&item)
            if value.boardItems == nil { value.boardItems = [:] }
            value.boardItems?[itemID] = item
        }
    }
}
