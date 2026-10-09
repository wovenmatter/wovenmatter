import SwiftUI

@main struct WovenMatterCompanionApp: App {
  @State private var model = CompanionModel()
  var body: some Scene {
    WindowGroup {
      ZStack {
        if model.initialized { CompanionShell(model: model) }
        else { ProgressView("Opening your library…") }
      }
        .task { await model.run() }
        .onOpenURL { url in Task { await model.pair(url: url) } }
    }
  }
}

enum MobileTheme {
  static let green = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
    ? .init(red: 0.43, green: 0.78, blue: 0.60, alpha: 1)
    : .init(red: 0, green: 0.259, blue: 0.145, alpha: 1) })
  static let action = Color(red: 0, green: 0.259, blue: 0.145)
  static let selection = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
    ? .init(red: 0.16, green: 0.24, blue: 0.19, alpha: 1)
    : .init(red: 0.89, green: 0.93, blue: 0.90, alpha: 1) })
  static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .init(red: 0.9, green: 0.95, blue: 0.92, alpha: 1) : .init(red: 0.039, green: 0.122, blue: 0.086, alpha: 1) })
  static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemBackground : .init(red: 0.969, green: 0.965, blue: 0.953, alpha: 1) })
  static let muted = Color.secondary
}

struct CompanionShell: View {
  @Bindable var model: CompanionModel
  @State private var keyboardVisible = false
  @Environment(\.horizontalSizeClass) private var sizeClass
  var body: some View {
    HStack(spacing: 0) {
      if sizeClass == .regular {
        VStack(alignment: .leading, spacing: 0) {
          Label("Woven Matter", systemImage: "square.stack.3d.up")
            .font(.title3.weight(.semibold)).padding(24)
          ScrollView {
            VStack(spacing: 4) {
              ForEach(Array(CompanionModel.Tab.allCases.prefix(5)), id: \.self) { tab in sidebarRow(tab) }
              GroupLabel(text: "Workspace")
              ForEach(Array(CompanionModel.Tab.allCases.dropFirst(5)), id: \.self) { tab in sidebarRow(tab) }
            }.padding(.horizontal, 12)
          }
          Button { model.pairingPresented = true } label: {
            Label(model.connectionLabel, systemImage: model.online ? "checkmark.circle" : "laptopcomputer")
              .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(20)
          }.buttonStyle(.plain).accessibilityLabel("Mac connection: " + model.connectionLabel)
        }.frame(width: 260).background(MobileTheme.surface)
        Divider()
      }
      VStack(spacing: 0) {
        if sizeClass != .regular && !CompanionModel.Tab.allCases.prefix(5).contains(model.tab) {
          HStack {
            Button { model.tab = .home } label: { Label("Home", systemImage: "chevron.left").frame(minHeight: 44) }
              .accessibilityIdentifier("back-home")
            Spacer()
          }.padding(.horizontal, 20)
        }
        pane.frame(maxWidth: 960, maxHeight: .infinity).frame(maxWidth: .infinity)
        if keyboardVisible {
          HStack {
            Spacer()
            Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
              .font(.subheadline.weight(.semibold)).frame(minWidth: 60, minHeight: 44)
              .accessibilityIdentifier("dismiss-keyboard")
          }.padding(.horizontal, 16).background(MobileTheme.surface)
        }
        if sizeClass != .regular && !keyboardVisible {
          HStack(spacing: 0) {
            ForEach(Array(CompanionModel.Tab.allCases.prefix(5)), id: \.self) { tab in
              Button { model.tab = tab } label: {
                VStack(spacing: 5) {
                  Image(systemName: tab.icon).font(.system(size: 21, weight: .medium))
                    .frame(width: 54, height: 30)
                    .background(isSelected(tab) ? MobileTheme.selection : .clear, in: Capsule())
                  Text(tab.rawValue).font(.caption2.weight(isSelected(tab) ? .semibold : .regular))
                }.frame(maxWidth: .infinity).padding(.vertical, 11)
                  .foregroundStyle(isSelected(tab) ? MobileTheme.ink : MobileTheme.muted)
              }.accessibilityIdentifier("tab-\(tab.rawValue.lowercased())")
                .accessibilityAddTraits(isSelected(tab) ? .isSelected : [])
            }
          }.background(MobileTheme.surface).overlay(alignment: .top) { Divider() }
        }
      }
    }
    .scrollIndicators(.never)
    .foregroundStyle(MobileTheme.ink).tint(MobileTheme.green)
    .background(Color(uiColor: .systemBackground))
    .sheet(isPresented: $model.pairingPresented) { PairingPane(model: model) }
    .alert("Woven Matter", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
      Button("OK") { model.errorMessage = nil }
    } message: { Text(model.errorMessage ?? "") }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
  }
  private func isSelected(_ tab: CompanionModel.Tab) -> Bool {
    model.tab == tab || (tab == .home && !CompanionModel.Tab.allCases.prefix(5).contains(model.tab))
  }
  private func sidebarRow(_ tab: CompanionModel.Tab) -> some View {
    WorkspaceRow(icon: tab.icon, title: tab.rawValue, selected: model.tab == tab) { model.tab = tab }
      .accessibilityIdentifier("tab-\(tab.rawValue.lowercased())")
  }
  @ViewBuilder private var pane: some View {
    switch model.tab {
    case .home: HomePane(model: model)
    case .folders: FoldersPane(model: model)
    case .settings: CompanionSettingsPane(model: model)
    case .chat: ChatPane(model: model)
    case .note:
      if let note = model.selectedNote { NotePane(model: model, note: note).id(note.id) }
      else { EmptyNotePane(model: model) }
    case .library: LibraryPane(model: model)
    case .calendar: CalendarPane(model: model)
    case .trash: TrashPane(model: model)
    }
  }

}

struct PaneHeader<Trailing: View>: View {
  let title: String
  @ViewBuilder var trailing: Trailing
  var body: some View { HStack(alignment: .center) { Text(title).font(.title.weight(.bold)).accessibilityIdentifier("pane-heading-" + title.lowercased()); Spacer(); trailing }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14) }
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
        .background(selected ? MobileTheme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
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
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.fixture ? "iphone.gen3" : model.online ? "checkmark.circle.fill" : "laptopcomputer")
              .font(.title3).foregroundStyle(MobileTheme.green)
            VStack(alignment: .leading, spacing: 6) {
              Text(model.connectionLabel).font(.subheadline.weight(.semibold))
              Text(model.fixture ? "Explore your workspace with sample notes and conversations."
                : model.online ? "Your workspace is connected. Agents run on your Mac."
                : "Your notes stay available here. Connect to your Mac to sync and use agents.")
                .font(.subheadline).foregroundStyle(.secondary)
              if !model.fixture && !model.online {
                if model.credential == nil {
                  Button("Pair your Mac") { model.pairingPresented = true }.buttonStyle(.borderedProminent).tint(MobileTheme.action)
                } else {
                  Button(model.connecting ? "Connecting…" : "Reconnect") { Task { await model.refresh() } }.disabled(model.connecting)
                }
              }
            }
          }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 16))
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { quickActions }
            VStack(spacing: 12) { quickActions }
          }.padding(.vertical, 12)
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
          ForEach(model.notes.prefix(5)) { note in WorkspaceRow(icon: "doc.text", title: note.title, detail: model.state.isDirty(note.id) ? "On device" : nil) { Task { await model.openNote(note.id) } } }
          if model.notes.isEmpty { Text("Your ideas start here. Create a note, even before pairing.").foregroundStyle(.secondary).padding(14) }
          GroupLabel(text: "Workspace")
          ForEach([CompanionModel.Tab.library, .calendar, .trash], id: \.self) { tab in
            WorkspaceRow(icon: tab.icon, title: tab.rawValue) { model.tab = tab }
              .accessibilityIdentifier("open-\(tab.rawValue.lowercased())")
          }
          if !model.state.outbox.isEmpty { Text("\(model.state.outbox.count) saved changes waiting to sync").font(.caption).foregroundStyle(.secondary).padding(14) }
        }.padding(.horizontal, 18).padding(.bottom, 20)
      }.refreshable { await model.refresh() }
    }
  }
  @ViewBuilder private var quickActions: some View {
    quickAction("New chat", icon: "square.and.pencil", detail: "Continue your work") { model.newChat() }
    quickAction("New note", icon: "doc.badge.plus", detail: "Capture an idea") { Task { await model.newNote() } }
      .accessibilityIdentifier("action-new-note")
  }
  private func quickAction(_ title: String, icon: String, detail: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        Image(systemName: icon).font(.title2).foregroundStyle(MobileTheme.green)
        Text(title).font(.headline)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }.buttonStyle(.plain)
  }

}

struct FoldersPane: View {
  @Bindable var model: CompanionModel
  @State private var newFolderPresented = false
  @State private var folderName = ""
  var body: some View {
    Group {
      if model.folderContentsPresented {
        FolderContentsPane(model: model)
      } else {
        VStack(spacing: 0) {
          PaneHeader(title: "Folders") { EmptyView() }
          ScrollView {
            VStack(spacing: 0) {
              WorkspaceRow(icon: "square.and.pencil", title: "New chat") { model.newChat() }
              WorkspaceRow(icon: "doc.text", title: "New note") { Task { await model.newNote() } }.accessibilityIdentifier("action-new-note")
              GroupLabel(text: "Folders")
              WorkspaceRow(icon: "plus", title: "New folder") { newFolderPresented = true }
              WorkspaceRow(icon: "folder", title: "All workspace") { model.openFolder(nil) }
                .accessibilityIdentifier("folder-all")
              ForEach(model.folders) { folder in
                WorkspaceRow(icon: "folder", title: folder.name,
                  detail: String(model.notes.filter { $0.folderID == folder.id }.count + model.conversations.filter { $0.folderID == folder.id }.count)) { model.openFolder(folder.id) }
                  .accessibilityIdentifier("folder-" + folder.id)
              }
            }.padding(.horizontal, 18).padding(.bottom, 24)
          }.refreshable { await model.refresh() }
        }
      }
    }
    .alert("New folder", isPresented: $newFolderPresented) {
      TextField("Folder name", text: $folderName)
      Button("Create") { let name = folderName; folderName = ""; Task { await model.newFolder(name: name) } }
      Button("Cancel", role: .cancel) { folderName = "" }
    } message: { Text("Saved on this device first, then synced to your Mac.") }
  }
}

struct FolderContentsPane: View {
  @Bindable var model: CompanionModel
  @State private var search = ""
  private var notes: [CompanionNote] {
    model.notes.filter { (model.selectedFolderID == nil || $0.folderID == model.selectedFolderID)
      && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
  }
  private var conversations: [CompanionConversation] {
    model.conversations.filter { (model.selectedFolderID == nil || $0.folderID == model.selectedFolderID)
      && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button { model.closeFolder() } label: { Label("Folders", systemImage: "chevron.left").frame(minHeight: 44) }
          .accessibilityLabel("Back to Folders").accessibilityIdentifier("back-folders")
        Spacer()
      }.padding(.horizontal, 20)
      PaneHeader(title: model.selectedFolderID.flatMap { model.state.folders[$0]?.name } ?? "All workspace") {
        Menu {
          Button("New chat", systemImage: "square.and.pencil") { model.newChat() }
          Button("New note", systemImage: "doc.badge.plus") { Task { await model.newNote() } }
        } label: { Image(systemName: "plus").font(.title2).frame(width: 44, height: 44) }
          .accessibilityLabel("Add to folder")
      }
      HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search notes and conversations", text: $search).textInputAutocapitalization(.never) }
        .padding(12).background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 20)
      ScrollView {
        VStack(spacing: 0) {
          if notes.isEmpty && conversations.isEmpty {
            Text(search.isEmpty ? "This folder is empty. Add a note or start a chat." : "No matching notes or chats.")
              .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24).padding(.horizontal, 14)
          }
          if !notes.isEmpty {
            GroupLabel(text: "Notes & assets")
            ForEach(notes) { note in
              WorkspaceRow(icon: noteIcon(note), title: note.title, detail: model.state.uncachedNoteIDs.contains(note.id) ? "Online" : nil) { Task { await model.openNote(note.id) } }
            }
          }
          if !conversations.isEmpty {
            GroupLabel(text: "Chats")
            ForEach(conversations) { conversation in
              WorkspaceRow(icon: "bubble.left", title: conversation.title, detail: conversation.runtimeKind) { Task { await model.selectConversation(conversation.id) } }
            }
          }
        }.padding(.horizontal, 18).padding(.bottom, 24)
      }.refreshable { await model.refresh() }
    }
  }
  private func noteIcon(_ note: CompanionNote) -> String {
    guard let document = RichDocumentEditing.document(note.content) else { return "doc.text" }
    return document.kind == .spreadsheet ? "tablecells" : document.kind == .html ? "chevron.left.forwardslash.chevron.right" : "doc.text"
  }
}

struct CompanionSettingsPane: View {
  @Bindable var model: CompanionModel
  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(title: "Settings") { EmptyView() }
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          GroupLabel(text: "Mac connection")
          VStack(alignment: .leading, spacing: 8) {
            Label(model.connectionLabel, systemImage: model.online ? "checkmark.circle" : "laptopcomputer")
              .font(.headline)
            Text(model.fixture ? "You’re exploring sample content. Pairing is available in the regular app."
              : "Connect to your Mac to sync your workspace and use agents.")
              .font(.subheadline).foregroundStyle(.secondary)
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 16))
          if !model.fixture {
            WorkspaceRow(icon: "qrcode", title: model.credential == nil ? "Pair your Mac" : "Pairing") { model.pairingPresented = true }
            WorkspaceRow(icon: "arrow.clockwise", title: model.connecting ? "Connecting…" : "Sync now") { Task { await model.refresh() } }
              .disabled(model.credential == nil || model.connecting)
          }
          GroupLabel(text: "Sync")
          Text(model.state.outbox.isEmpty ? "No saved changes waiting to sync." : "\(model.state.outbox.count) saved changes waiting to sync.")
            .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 14)
          if !model.state.conflicts.isEmpty {
            WorkspaceRow(icon: "doc.on.doc", title: "Review saved conflicts", detail: String(model.state.conflicts.count)) { model.tab = .home }
          }
          Text("Notes are saved on this device and remain available offline.")
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 8)
        }.padding(.horizontal, 18).padding(.bottom, 24)
      }
    }
  }
}

import CompanionClient
import WovenMatterCompanion
