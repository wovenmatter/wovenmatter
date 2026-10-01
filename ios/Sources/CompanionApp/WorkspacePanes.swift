import SwiftUI
import QuickLook
import CompanionClient
import WovenMatterCompanion

struct LibraryPane: View {
  @Bindable var model: CompanionModel
  @State private var items: [CompanionLibraryItem] = []
  @State private var search = ""
  @State private var kind = ""
  @State private var hasMore = false
  @State private var loading = false
  @State private var loadGeneration = 0
  @State private var failure: String?
  @State private var preview: URL?
  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(title: "Library") { if loading { ProgressView() } }
      HStack {
        TextField("Search files, links and photos", text: $search).textFieldStyle(.roundedBorder).onSubmit { Task { await load() } }
        Button("Search") { Task { await load() } }.disabled(!model.online || loading)
      }.padding(.horizontal)
      Picker("Kind", selection: $kind) {
        Text("All").tag(""); Text("Files").tag("file"); Text("Links").tag("link"); Text("Photos").tag("photo")
      }.pickerStyle(.segmented).padding()
      List {
        if !model.online { Text("Connect to your Mac to browse the Library.").foregroundStyle(.secondary) }
        if let failure { Text(failure).foregroundStyle(.secondary) }
        ForEach(items) { item in
          VStack(alignment: .leading, spacing: 6) {
            if let url = item.webURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
              Link(destination: url) { Label(item.title, systemImage: "link") }
            } else {
              Button { Task { await open(item) } } label: { Label(item.title, systemImage: item.kind == "photo" ? "photo" : "doc") }
                .disabled(!model.online || !item.available)
            }
            Text([item.agent, item.workspace].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            if let error = item.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
              Button("Open conversation") { Task { await model.selectConversation(item.conversationID) } }
              if !item.available { Button("Retry file") { Task { if await model.perform(.retryLibrary(id: item.id)) { await load() } } }.disabled(!model.online) }
            }.font(.caption).buttonStyle(.borderless)
          }.padding(.vertical, 4)
        }
        if items.isEmpty && model.online && !loading && failure == nil { Text("No Library items match this search.").foregroundStyle(.secondary) }
        if hasMore { Button("Load more") { Task { await load(more: true) } }.disabled(loading) }
      }.listStyle(.plain).refreshable { await load() }
    }.task(id: model.online) { await load() }.onChange(of: kind) { Task { await load() } }
      .quickLookPreview($preview)
  }
  private func load(more: Bool = false) async {
    guard model.online, !more || !loading else { return }
    loadGeneration += 1; let generation = loadGeneration
    loading = true; failure = nil
    defer { if generation == loadGeneration { loading = false } }
    do {
      guard case .library(let values, let next) = try await model.workspace(.library(search: search, kind: kind.isEmpty ? nil : kind, offset: more ? items.count : 0)) else { throw MobileConnectionError.invalidResponse }
      guard generation == loadGeneration, !Task.isCancelled else { return }
      items = more ? items + values : values; hasMore = next
    } catch { if generation == loadGeneration, !Task.isCancelled { failure = error.localizedDescription } }
  }
  private func open(_ item: CompanionLibraryItem) async {
    do { preview = try await model.exportFile(.libraryFile(id: item.id)) }
    catch { model.errorMessage = error.localizedDescription }
  }
}

struct TrashPane: View {
  @Bindable var model: CompanionModel
  @State private var items: [CompanionTrashedItem] = []
  @State private var failure: String?
  var body: some View {
    VStack {
      PaneHeader(title: "Trash") { EmptyView() }
      List {
        if !model.online { Text("Connect to your Mac to restore notes and conversations.") }
        if let failure { Text(failure) }
        ForEach(items) { item in
          HStack {
            Label(item.title, systemImage: item.kind == "note" ? "doc.text" : "bubble.left")
            Spacer()
            Button("Restore") { Task { await restore(item) } }.disabled(!model.online)
          }
        }
        if model.online && items.isEmpty && failure == nil { Text("Trash is empty.").foregroundStyle(.secondary) }
      }.listStyle(.plain).refreshable { await load() }
    }.task(id: model.online) { await load() }
  }
  private func load() async {
    guard model.online else { return }; failure = nil
    do { if case .trash(let items) = try await model.workspace(.trash) { self.items = items } }
    catch { failure = error.localizedDescription }
  }
  private func restore(_ item: CompanionTrashedItem) async {
    let action: CompanionWorkspaceAction
    if item.kind == "note", let revision = item.revision { action = .note(id: item.id, action: "restore", revision: revision, title: nil, folderID: nil) }
    else { action = .conversation(id: item.id, action: "restore", title: nil, folderID: nil) }
    if await model.perform(action) { await load() }
  }
}

struct ItemManagementSheet: View {
  @Bindable var model: CompanionModel
  let id: String
  let isNote: Bool
  @State var title: String
  @State var folderID: String
  @State private var busy = false
  @State private var confirmTrash = false
  @State private var preview: URL?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        if let error = model.errorMessage { Text(error).foregroundStyle(.red).accessibilityIdentifier("workspace-action-error") }
        if busy { ProgressView("Saving…") }
        Section("Title") {
          TextField("Title", text: $title)
          Button("Rename") { Task { await perform("rename") } }
        }
        Section("Folder") {
          Picker("Folder", selection: $folderID) {
            Text("No folder").tag("")
            ForEach(model.folders) { Text($0.name).tag($0.id) }
          }
          Button("Move") { Task { await perform("move") } }
        }
        Section {
          Button("Pin") { Task { await perform("pin") } }
          Button("Unpin") { Task { await perform("unpin") } }
          Button(isNote ? "Export Markdown / spreadsheet" : "Export messages") { Task { await export(original: false) } }
          Button(isNote ? "Export original document" : "Export full run") { Task { await export(original: true) } }
        }
        Section { Button("Move to Trash", role: .destructive) { confirmTrash = true } }
        if !model.online { Text("Connect to your Mac to manage this item.").foregroundStyle(.secondary) }
      }.disabled(busy || !model.online)
        .navigationTitle(isNote ? "Note details" : "Conversation details")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .confirmationDialog("Move this item to Trash?", isPresented: $confirmTrash, titleVisibility: .visible) {
          Button("Move to Trash", role: .destructive) { Task { await perform("trash") } }
        }
        .quickLookPreview($preview)
    }
  }
  private func perform(_ action: String) async {
    guard !busy else { return }; busy = true; defer { busy = false }
    do {
      let request: CompanionWorkspaceAction
      if isNote {
        let note = try await model.canonicalNoteForAction(id)
        request = .note(id: id, action: action, revision: String(note.revision), title: title, folderID: folderID.isEmpty ? nil : folderID)
      } else { request = .conversation(id: id, action: action, title: title, folderID: folderID.isEmpty ? nil : folderID) }
      if await model.perform(request) { dismiss() }
    } catch { model.errorMessage = error.localizedDescription }
  }
  private func export(original: Bool) async {
    busy = true; defer { busy = false }
    do {
      let request: CompanionWorkspaceRead
      if isNote {
        let note = try await model.canonicalNoteForAction(id)
        request = .exportNote(id: id, format: original ? "document" : "standard", revision: String(note.revision))
      } else { request = .exportConversation(id: id, format: original ? "fullRun" : "messages") }
      preview = try await model.exportFile(request)
    } catch { model.errorMessage = error.localizedDescription }
  }
}

struct SessionSettingsSheet: View {
  @Bindable var model: CompanionModel
  let id: String
  @State private var settings: CompanionSessionSettings?
  @State private var selectedModel = ""
  @State private var thinking = ""
  @State private var permission = ""
  @State private var enabled: Set<String> = []
  @State private var busy = false
  @State private var failure: String?
  @State private var confirmTimers = false
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        if let error = model.errorMessage { Text(error).foregroundStyle(.red).accessibilityIdentifier("workspace-action-error") }
        if busy { ProgressView("Saving…") }
        if let settings {
          Section("Agent settings") {
            selection("Model", value: $selectedModel, options: settings.models)
            selection("Thinking", value: $thinking, options: settings.thinkingLevels)
            selection("Permission", value: $permission, options: settings.permissions)
            Button("Apply settings") { Task { await apply() } }.disabled(!settings.canConfigure)
            if !settings.canConfigure { Text("Wait for the active run to finish before changing settings.").font(.caption) }
            if settings.models.isEmpty { Text("Options appear after this agent has connected on the Mac.").font(.caption) }
          }
          Section("Workspace tools") {
            ForEach(settings.availableTools) { tool in
              Toggle(tool.label, isOn: Binding(get: { enabled.contains(tool.id) }, set: { if $0 { enabled.insert(tool.id) } else { enabled.remove(tool.id) } }))
            }
            Button("Save tool access") {
              if settings.enabledTools.contains("timers") && !enabled.contains("timers") { confirmTimers = true }
              else { Task { await saveTools(confirmed: false) } }
            }
          }
        } else if let failure { Text(failure) } else { ProgressView("Loading settings…") }
      }.disabled(busy || !model.online)
        .navigationTitle("Session settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { await load() }
        .confirmationDialog("Removing timer access pauses this session’s timers.", isPresented: $confirmTimers, titleVisibility: .visible) {
          Button("Pause timers and save") { Task { await saveTools(confirmed: true) } }
        }
    }
  }
  @ViewBuilder private func selection(_ title: String, value: Binding<String>, options: [CompanionSelection]) -> some View {
    if !options.isEmpty {
      Picker(title, selection: value) {
        Text("Keep current").tag("")
        ForEach(options) { Text($0.label).tag($0.id) }
      }
    }
  }
  private func load() async {
    do {
      guard case .session(let value) = try await model.workspace(.session(id: id)) else { throw MobileConnectionError.invalidResponse }
      settings = value; selectedModel = value.model ?? ""; thinking = value.thinking ?? ""; permission = value.permission ?? ""; enabled = Set(value.enabledTools)
    } catch { failure = error.localizedDescription }
  }
  private func apply() async {
    busy = true; defer { busy = false }
    if await model.perform(.configureSession(id: id, model: selectedModel.isEmpty ? nil : selectedModel,
      thinking: thinking.isEmpty ? nil : thinking, permission: permission.isEmpty ? nil : permission)) { await load() }
  }
  private func saveTools(confirmed: Bool) async {
    busy = true; defer { busy = false }
    if await model.perform(.sessionTools(id: id, enabled: enabled.sorted(), confirmPausingTimers: confirmed)) { await load() }
  }
}
