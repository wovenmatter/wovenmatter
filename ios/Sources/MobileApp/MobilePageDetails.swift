import SwiftUI
import LibraryClient
import WovenMatterShared

/// Component details, as on a Mac: task state, assignment label, outcome,
/// instructions role, review, change summary and linked chats.
struct MobilePageComponentDetails: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: MobileModel
  let note: LibraryNote
  let page: NoteDocument
  let componentID: String
  let commit: (String, (inout NoteDocument) throws -> Void) -> String?
  @State private var sending = false
  @State private var sendResult: String?
  @State private var problem: String?
  private var exists: Bool { page.blocks.contains { $0.id == componentID } }
  private var item: BoardItem { page.boardItems?[componentID] ?? BoardItem() }
  private var isSection: Bool { page.pageNodes?[componentID]?.isSection == true }
  private var conversations: [LibraryConversation] { model.conversations }

  var body: some View {
    NavigationStack {
      Form {
        if !exists {
          Text("This component is no longer on the Page.").foregroundStyle(WovenPalette.mutedForeground)
        } else {
          taskSection
          Section {
            Toggle("Instructions or skill reference", isOn: Binding(get: { item.role == .instructions }, set: { enabled in
              update("Instructions") { $0.role = enabled ? .instructions : .content }
            })).accessibilityIdentifier("page-details-instructions")
            if item.role == .instructions {
              caption("Reference context only. This does not install a skill, run its contents, or grant permission.")
            }
            HStack {
              Text(reviewLabel)
              Spacer()
              Menu("Review") {
                Button("Request review") { update("Review") { $0.review = .needed } }
                Button("Mark reviewed") { update("Review") { $0.review = .approved } }
                Button("Dismiss recommendation") { update("Review") { $0.review = .dismissed } }
                Button("Clear review marker") { update("Review") { $0.review = nil } }
              }.accessibilityIdentifier("page-details-review")
            }
            TextField("Change summary", text: Binding(get: { item.lastChange ?? "" }, set: { value in
              update("Change summary") { $0.lastChange = value.isEmpty ? nil : value }
            }), axis: .vertical).lineLimit(1...3).accessibilityIdentifier("page-details-change")
            if let actor = item.updatedBy {
              HStack {
                Text("Updated by \(actorName(actor))").font(.caption).lineLimit(2)
                if let id = actor.sessionID, model.state.conversations[id] != nil {
                  Spacer()
                  Button("Open chat") { openChat(id) }.font(.caption)
                }
              }.foregroundStyle(WovenPalette.mutedForeground)
            }
            if let date = updatedDate {
              Text(date, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(WovenPalette.mutedForeground)
            }
          }
          chatSection
        }
        if let problem {
          Text(problem).font(.caption).foregroundStyle(WovenPalette.danger).textSelection(.enabled)
            .accessibilityIdentifier("page-details-error")
        }
      }.scrollIndicators(.never)
        .navigationTitle("Component details").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("page-details-done") } }
    }.presentationDetents([.medium, .large])
  }

  @ViewBuilder private var taskSection: some View {
    if !isSection {
      Section {
        Toggle("Task", isOn: Binding(get: { item.task != nil }, set: { enabled in
          update("Task") { $0.task = enabled ? BoardTask() : nil }
        })).accessibilityIdentifier("page-details-task")
        if let task = item.task {
          Picker("State", selection: Binding(get: { item.task?.status ?? .todo }, set: { status in
            update("Task state") { $0.task?.status = status }
          })) {
            ForEach(BoardTaskStatus.allCases, id: \.self) { status in Text(status.mobileTitle).tag(status) }
          }.accessibilityIdentifier("page-details-state")
          TextField("Assignee or agent", text: Binding(get: { item.task?.assignee ?? "" }, set: { value in
            update("Assignee") { $0.task?.assignee = value }
          })).textInputAutocapitalization(.words)
            .accessibilityLabel("Task assignee").accessibilityIdentifier("page-details-assignee")
          caption("Assignment is a label. Use Send to chat to request work.")
          TextField("Outcome, findings, or next steps", text: Binding(get: { item.task?.outcome ?? "" }, set: { value in
            update("Outcome") { $0.task?.outcome = value }
          }), axis: .vertical).lineLimit(3...7)
            .accessibilityLabel("Task outcome").accessibilityIdentifier("page-details-outcome")
          if task.status == .done && task.outcome.isEmpty {
            caption("Leave an outcome so the next participant can pick up the work.")
          }
        }
      }
    }
  }

  @ViewBuilder private var chatSection: some View {
    Section("Linked chats") {
      ForEach(item.sessions, id: \.self) { id in
        HStack {
          if let chat = model.state.conversations[id] {
            Button(chat.title.isEmpty ? "Untitled chat" : chat.title) { openChat(id) }.lineLimit(1)
          } else {
            Text("Chat unavailable on this device").font(.caption).foregroundStyle(WovenPalette.mutedForeground)
          }
          Spacer()
          Button { unlink(id) } label: { LucideIcon(glyph: .close, size: 14).frame(width: 44, height: 44) }
            .buttonStyle(.plain).accessibilityLabel("Remove chat link").accessibilityHint("Keeps the chat")
            .accessibilityIdentifier("page-details-unlink-\(id)")
        }
      }
      Menu(sending ? "Sending…" : "Send to chat") {
        ForEach(conversations) { chat in
          Button(chat.title.isEmpty ? "Untitled chat" : chat.title) { send(chat) }
        }
      }.disabled(sending || conversations.isEmpty).accessibilityIdentifier("page-details-send")
      if conversations.isEmpty { caption("Create a chat to send this component to an agent.") }
      if let sendResult { caption(sendResult).accessibilityIdentifier("page-details-sent") }
      caption("Uses that chat's current agent and permissions. Its run does not change task state automatically.")
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(WovenPalette.mutedForeground)
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
    case .session: actor.sessionID.flatMap { model.state.conversations[$0]?.title } ?? actor.label ?? "Agent"
    }
  }
  private var updatedDate: Date? {
    guard let value = item.updatedAt else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
  /// Details edit the component's own metadata; the shared edit checks the result.
  private func update(_ action: String, _ change: @escaping (inout BoardItem) -> Void) {
    problem = commit(action) { value in
      guard value.blocks.contains(where: { $0.id == componentID }) else { throw MobilePageDispatchError.unavailable }
      var item = value.boardItems?[componentID] ?? BoardItem()
      change(&item)
      if value.boardItems == nil { value.boardItems = [:] }
      value.boardItems?[componentID] = item
    }
  }
  private func unlink(_ sessionID: String) {
    problem = commit("Remove chat link") { try $0.applyPageEdit(.init(action: .unlinkSession, id: componentID, sessionID: sessionID)) }
  }
  private func openChat(_ id: String) {
    dismiss()
    Task { await model.selectConversation(id) }
  }
  /// The link is saved before the message is sent, so an uncertain handoff never loses it.
  private func send(_ chat: LibraryConversation) {
    sendResult = nil; problem = nil
    if !item.sessions.contains(chat.id) {
      if let refusal = commit("Link chat", { try $0.applyPageEdit(.init(action: .linkSession, id: componentID, sessionID: chat.id)) }) {
        problem = refusal; return
      }
    }
    sending = true
    Task { @MainActor in
      defer { sending = false }
      do {
        try await model.sendPageComponent(pageID: note.id, componentID: componentID, to: chat.id)
        sendResult = "Sent to \(chat.title.isEmpty ? "chat" : chat.title)."
      } catch { problem = error.localizedDescription }
    }
  }
}
