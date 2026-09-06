import SwiftUI

@main struct WovenMatterCompanionApp: App {
  @State private var model = CompanionModel()
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      CompanionShell(model: model)
        .task(id: scenePhase) { if scenePhase == .active { await model.run() } }
        .onOpenURL { url in Task { await model.pair(url: url) } }
    }
  }
}

enum MobileTheme {
  static let green = Color(red: 0, green: 0.259, blue: 0.145)
  static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .init(red: 0.9, green: 0.95, blue: 0.92, alpha: 1) : .init(red: 0.039, green: 0.122, blue: 0.086, alpha: 1) })
  static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemBackground : .init(red: 0.969, green: 0.965, blue: 0.953, alpha: 1) })
  static let muted = Color.secondary
}

struct CompanionShell: View {
  @Bindable var model: CompanionModel
  @State private var keyboardVisible = false
  var body: some View {
    VStack(spacing: 0) {
      Group {
        switch model.tab {
        case .home: HomePane(model: model)
        case .folders: FoldersPane(model: model)
        case .content: ContentPane(model: model)
        case .chat: ChatPane(model: model)
        case .note:
          if let note = model.selectedNote { NotePane(model: model, note: note).id(note.id) }
          else { EmptyNotePane(model: model) }
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      if !keyboardVisible {
        HStack(spacing: 0) {
          ForEach(CompanionModel.Tab.allCases, id: \.self) { tab in
            Button { model.tab = tab } label: {
              VStack(spacing: 5) {
                Image(systemName: tab.icon + (model.tab == tab && tab != .content ? ".fill" : ""))
                  .font(.system(size: 23, weight: .regular)).frame(height: 26)
                Text(tab.rawValue).font(.caption2)
              }.frame(maxWidth: .infinity).padding(.vertical, 11)
                .foregroundStyle(model.tab == tab ? MobileTheme.green : MobileTheme.muted)
            }.accessibilityIdentifier("tab-\(tab.rawValue.lowercased())")
              .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
          }
        }.background(MobileTheme.surface)
      }
    }
    .foregroundStyle(MobileTheme.ink).tint(MobileTheme.green)
    .background(Color(uiColor: .systemBackground))
    .sheet(isPresented: $model.pairingPresented) { PairingPane(model: model) }
    .alert("Woven Matter", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
      Button("OK") { model.errorMessage = nil }
    } message: { Text(model.errorMessage ?? "") }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
  }
}

struct PaneHeader<Trailing: View>: View {
  let title: String
  @ViewBuilder var trailing: Trailing
  var body: some View { HStack(alignment: .center) { Text(title).font(.largeTitle.bold()); Spacer(); trailing }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14) }
}
struct WorkspaceRow: View {
  var icon: String
  var title: String
  var detail: String? = nil
  var selected = false
  var action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: icon).font(.system(size: 22)).frame(width: 26)
        Text(title).font(.body).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
      }.padding(.horizontal, 14).padding(.vertical, 13).frame(minHeight: 48)
        .background(selected ? MobileTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}
struct GroupLabel: View {
  var text: String
  var body: some View { Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 22).padding(.bottom, 6) }
}

struct HomePane: View {
  @Bindable var model: CompanionModel
  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(title: "Woven Matter") {
        Button { model.pairingPresented = true } label: { Image(systemName: "qrcode").font(.title2) }.accessibilityLabel("Pair with Mac")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          VStack(alignment: .leading, spacing: 10) {
            Label(model.connectionLabel, systemImage: model.online ? "checkmark.circle.fill" : "laptopcomputer").font(.subheadline.weight(.medium))
            Text(model.online ? "Your Mac owns this workspace. Keep it running to use agents from your iPhone." : "Capture ideas and edit saved notes here. Reconnect to your running Mac to sync and use agents.")
              .font(.subheadline).foregroundStyle(.secondary)
            if model.credential == nil && !model.fixture { Button("Pair your Mac") { model.pairingPresented = true }.buttonStyle(.borderedProminent).foregroundStyle(.white) }
            else { Button(model.connecting ? "Connecting…" : "Reconnect") { Task { await model.refresh() } }.disabled(model.connecting || model.fixture) }
          }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 16))
          WorkspaceRow(icon: "square.and.pencil", title: "New chat") { model.newChat() }
          WorkspaceRow(icon: "doc.badge.plus", title: "New note", detail: "Works offline") { Task { await model.newNote() } }.accessibilityIdentifier("action-new-note")
          if !model.pending.isEmpty {
            GroupLabel(text: "Needs your attention")
            ForEach(model.pending) { request in WorkspaceRow(icon: "hand.raised", title: request.title, detail: "Respond") { Task { await model.selectConversation(request.conversationID) } } }
          }
          if !model.state.conflicts.isEmpty {
            GroupLabel(text: "Saved conflicts")
            ForEach(Array(model.state.conflicts.keys).sorted(), id: \.self) { id in
              WorkspaceRow(icon: "doc.on.doc", title: model.state.notes[id]?.title ?? "Note", detail: "Keep both versions") { Task { await model.openNote(id) } }
            }
          }
          ForEach(model.state.launches.filter { !$0.accepted }) { launch in
            VStack(alignment: .leading, spacing: 8) {
              Text(launch.initialSend.text ?? "New conversation").lineLimit(3)
              Text(launch.sendReceipt?.message ?? launch.createReceipt?.message ?? "New chat request saved · awaiting acknowledgement").font(.caption).foregroundStyle(.secondary)
              if !launch.terminalFailure { Button("Continue this saved request") { Task { await model.continueLaunch(launch) } }.disabled(!model.online) }
            }.padding(14).background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 12))
          }
          if !model.unresolvedCommands.isEmpty {
            GroupLabel(text: "Command acknowledgements")
            ForEach(model.unresolvedCommands) { record in
              VStack(alignment: .leading, spacing: 8) {
                Text(record.command.text ?? record.command.kind.rawValue).lineLimit(3)
                Text(record.receipt?.message ?? "Waiting to learn whether the Mac accepted this command.").font(.caption).foregroundStyle(.secondary)
                if record.receipt == nil {
                  Button("Retry this same command") { Task { await model.retry(record) } }.disabled(!model.online)
                }
              }.padding(14).background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
          }
          GroupLabel(text: "Recent notes")
          ForEach(model.notes.prefix(5)) { note in WorkspaceRow(icon: "doc.text", title: note.title, detail: model.state.isDirty(note.id) ? "On iPhone" : nil) { Task { await model.openNote(note.id) } } }
          if model.notes.isEmpty { Text("Your ideas start here. Create a note, even before pairing.").foregroundStyle(.secondary).padding(14) }
          if !model.state.outbox.isEmpty { Text("\(model.state.outbox.count) saved changes waiting to sync").font(.caption).foregroundStyle(.secondary).padding(14) }
        }.padding(.horizontal, 18).padding(.bottom, 20)
      }.refreshable { await model.refresh() }
    }
  }
}

struct FoldersPane: View {
  @Bindable var model: CompanionModel
  @State private var newFolderPresented = false
  @State private var folderName = ""
  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(title: "Folders") { EmptyView() }
      ScrollView {
        VStack(spacing: 0) {
          WorkspaceRow(icon: "square.and.pencil", title: "New chat") { model.newChat() }
          WorkspaceRow(icon: "doc.text", title: "New note") { Task { await model.newNote() } }.accessibilityIdentifier("action-new-note")
          GroupLabel(text: "Folders")
          WorkspaceRow(icon: "plus", title: "New folder") { newFolderPresented = true }
          WorkspaceRow(icon: "folder", title: "All workspace", selected: model.selectedFolderID == nil) { model.selectedFolderID = nil }
          ForEach(model.folders) { folder in
            WorkspaceRow(icon: "folder", title: folder.name,
              detail: String(model.notes.filter { $0.folderID == folder.id }.count + model.conversations.filter { $0.folderID == folder.id }.count), selected: model.selectedFolderID == folder.id) { model.selectedFolderID = folder.id }
          }
          GroupLabel(text: model.selectedFolderID.flatMap { model.state.folders[$0]?.name } ?? "Recents")
          ForEach(model.conversations.filter { model.selectedFolderID == nil || $0.folderID == model.selectedFolderID }) { conversation in
            WorkspaceRow(icon: "bubble.left", title: conversation.title, detail: conversation.activeRunID == nil ? nil : "Running") { Task { await model.selectConversation(conversation.id) } }
          }
          ForEach(model.notes.filter { model.selectedFolderID == nil || $0.folderID == model.selectedFolderID }) { note in
            WorkspaceRow(icon: "doc.text", title: note.title, detail: model.state.isDirty(note.id) ? "On iPhone" : nil) { Task { await model.openNote(note.id) } }
          }
        }.padding(.horizontal, 18).padding(.bottom, 24)
      }.refreshable { await model.refresh() }
    }
    .alert("New folder", isPresented: $newFolderPresented) {
      TextField("Folder name", text: $folderName)
      Button("Create") { let name = folderName; folderName = ""; Task { await model.newFolder(name: name) } }
      Button("Cancel", role: .cancel) { folderName = "" }
    } message: { Text("Saved on this iPhone first, then synced to your Mac.") }
  }
}

struct ContentPane: View {
  @Bindable var model: CompanionModel
  @State private var search = ""
  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(title: "Content") { Button { Task { await model.newNote() } } label: { Image(systemName: "plus").font(.title2) }.accessibilityLabel("New note") }
      HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search notes and conversations", text: $search).textInputAutocapitalization(.never) }
        .padding(12).background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 20)
      ScrollView {
        VStack(spacing: 0) {
          GroupLabel(text: "Notes & assets")
          ForEach(model.notes.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { note in
            WorkspaceRow(icon: noteIcon(note), title: note.title, detail: model.state.uncachedNoteIDs.contains(note.id) ? "Online" : nil) { Task { await model.openNote(note.id) } }
          }
          GroupLabel(text: "Conversations")
          ForEach(model.conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { conversation in
            WorkspaceRow(icon: "bubble.left", title: conversation.title, detail: conversation.runtimeKind) { Task { await model.selectConversation(conversation.id) } }
          }
        }.padding(.horizontal, 18).padding(.bottom, 24)
      }
    }
  }
  private func noteIcon(_ note: WovenMatterCompanion.CompanionNote) -> String {
    guard let document = CompanionClient.RichDocumentEditing.document(note.content) else { return "doc.text" }
    return document.kind == .spreadsheet ? "tablecells" : document.kind == .html ? "chevron.left.forwardslash.chevron.right" : "doc.text"
  }
}

import CompanionClient
import WovenMatterCompanion
