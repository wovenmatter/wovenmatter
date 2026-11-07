import SwiftUI
import QuickLook
import CompanionClient
import WovenMatterCompanion
import WovenMatterCore

struct LibraryClientPaneHeader<Actions: View>: View {
  let title: String
  @ViewBuilder var actions: () -> Actions
  var body: some View {
    HStack { Text(title).font(.system(size: 21, weight: .semibold)).lineLimit(1); Spacer(); actions() }
      .buttonStyle(DashboardQuietButtonStyle()).padding(22)
  }
}

struct LibraryClientLibraryPane: View {
  @Environment(\.openDocumentPreview) private var openPreview
  @Bindable var model: CentralLibraryClientModel
  @State private var items: [CompanionLibraryItem] = []
  @State private var search = ""
  @State private var kind = ""
  @State private var hasMore = false
  @State private var loading = false
  @State private var loadGeneration = 0
  @State private var failure: String?
  var body: some View {
    VStack(spacing: 0) {
      LibraryClientPaneHeader(title: "Library") { if loading { ProgressView() } }
      HStack {
        DashboardSearchField(text: $search, prompt: "Search files, links and photos").onSubmit { Task { await load() } }
        Button("Search") { Task { await load() } }.buttonStyle(DashboardQuietButtonStyle()).disabled(!model.online || loading)
      }.padding(.horizontal)
      DashboardSegmentedSelector(options: ["", "file", "link", "photo"], selection: $kind) {
        ["": "All", "file": "Files", "link": "Links", "photo": "Photos"][$0] ?? $0
      }.accessibilityLabel("Library item kind").padding()
      List {
        if !model.online { Text("Connect to your central database to browse the Library.").foregroundStyle(DashboardPalette.mutedForeground) }
        if let failure { Text(failure).foregroundStyle(DashboardPalette.mutedForeground) }
        if !model.artifacts.isEmpty {
          Group {
            ForEach(model.artifacts.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { artifact in
              Button(artifact.title) { Task {
                do { openPreview?(try await model.artifactURL(artifact), "artifact:" + artifact.id) }
                catch { failure = error.localizedDescription }
              } }
            }
          }
        }
        ForEach(items) { item in
          VStack(alignment: .leading, spacing: 6) {
            if let url = item.webURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
              Link(destination: url) { Label(item.title, systemImage: "link") }.tint(DashboardPalette.success)
            } else {
              Button { Task { await open(item) } } label: { Label(item.title, systemImage: item.kind == "photo" ? "photo" : "doc") }
                .disabled(!model.online || !item.available)
            }
            Text([item.agent, item.workspace].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
            if let error = item.error { Text(error).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
            HStack {
              Button("Open conversation") { Task { await model.selectConversation(item.conversationID) } }
              if !item.available { Button("Retry file") { Task { if await model.perform(.retryLibrary(id: item.id)) { await load() } } }.disabled(!model.online) }
            }.font(.caption).buttonStyle(.borderless)
          }.padding(.vertical, 4)
        }
        if items.isEmpty && model.online && !loading && failure == nil { Text("No Library items match this search.").foregroundStyle(DashboardPalette.mutedForeground) }
        if hasMore { Button("Load more") { Task { await load(more: true) } }.disabled(loading) }
      }.listStyle(.plain).scrollContentBackground(.hidden).refreshable { await load() }
    }.task(id: model.online) { await load() }.onChange(of: kind) { Task { await load() } }
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
    do { openPreview?(try await model.exportFile(.libraryFile(id: item.id)), "library:" + item.id) }
    catch { model.errorMessage = error.localizedDescription }
  }
}

struct LibraryClientTrashPane: View {
  @Bindable var model: CentralLibraryClientModel
  @State private var items: [CompanionTrashedItem] = []
  @State private var failure: String?
  var body: some View {
    VStack {
      LibraryClientPaneHeader(title: "Trash") { EmptyView() }
      List {
        if !model.online { Text("Connect to your central database to restore notes and conversations.") }
        if let failure { Text(failure) }
        ForEach(items) { item in
          HStack {
            HStack { DashboardLucideIcon(glyph: item.kind == "note" ? .fileText : .messageSquare, size: 16); Text(item.title) }
            Spacer()
            Button("Restore") { Task { await restore(item) } }.disabled(!model.online)
          }
        }
        if model.online && items.isEmpty && failure == nil { Text("Trash is empty.").foregroundStyle(DashboardPalette.mutedForeground) }
      }.listStyle(.plain).scrollContentBackground(.hidden).refreshable { await load() }
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

struct LibraryClientItemManagementSheet: View {
  @Bindable var model: CentralLibraryClientModel
  let id: String
  let isNote: Bool
  @State var title: String
  @State var folderID: String
  @State private var busy = false
  @State private var confirmTrash = false
  @State private var preview: URL?
  @Environment(\.dismiss) private var dismiss
  private var canManage: Bool { isNote ? model.online : model.canControl(workspaceID: model.executionOwner(for: id)) }
  var body: some View {
    NavigationStack {
      Form {
        if let error = model.errorMessage { Text(error).foregroundStyle(DashboardPalette.danger).accessibilityIdentifier("workspace-action-error") }
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
        if !canManage { Text("Reconnect to the workspace that owns this item to manage it.").foregroundStyle(DashboardPalette.mutedForeground) }
      }.disabled(busy || !canManage)
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
        let note = try await model.canonicalNote(id)
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
        let note = try await model.canonicalNote(id)
        request = .exportNote(id: id, format: original ? "document" : "standard", revision: String(note.revision))
      } else { request = .exportConversation(id: id, format: original ? "fullRun" : "messages") }
      preview = try await model.exportFile(request)
    } catch { model.errorMessage = error.localizedDescription }
  }
}

struct LibraryClientSessionSettingsSheet: View {
  @Bindable var model: CentralLibraryClientModel
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
        if let error = model.errorMessage { Text(error).foregroundStyle(DashboardPalette.danger).accessibilityIdentifier("workspace-action-error") }
        if busy { ProgressView("Saving…") }
        if let settings {
          Section("Agent settings") {
            selection("Model", value: $selectedModel, options: settings.models)
            selection("Thinking", value: $thinking, options: settings.thinkingLevels)
            selection("Permission", value: $permission, options: settings.permissions)
            Button("Apply settings") { Task { await apply() } }.disabled(!settings.canConfigure)
            if !settings.canConfigure { Text("Wait for the active run to finish before changing settings.").font(.caption) }
            if settings.models.isEmpty { Text("Options appear after this agent has connected on the central database.").font(.caption) }
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
      }.disabled(busy || !model.canControl)
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

struct LibraryClientNotePane: View {
  @Bindable var model: CentralLibraryClientModel
  let note: CompanionNote
  @State private var editor = DashboardNoteEditorController()
  @State private var cache = DashboardNoteDocumentCache()
  @State private var details = false
  private var source: CompanionNote { model.draftNotes[note.id] ?? model.state.notes[note.id] ?? note }
  private var document: Binding<NoteDocument> {
    Binding(get: { cache.value(noteID: note.id, source: source.content) }, set: { document in
      do { model.editNote(source, content: try cache.encode(document, noteID: note.id)) }
      catch { model.errorMessage = error.localizedDescription }
    })
  }
  private var hasLinkedData: Bool {
    document.wrappedValue.databaseLink != nil || document.wrappedValue.blocks.contains {
      if case .table(let table) = $0 { return table.databaseLink != nil }; return false
    }
  }
  @ViewBuilder private var linkedPreview: some View {
    let value = document.wrappedValue
    if value.kind == .html {
      LibraryClientLinkedPreview(model: model, note: source, tableID: nil, html: value.html)
    } else if value.kind == .spreadsheet, value.databaseLink != nil {
      LibraryClientLinkedPreview(model: model, note: source, tableID: nil, html: nil)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          ForEach(value.blocks, id: \.id) { block in
            if case .table(let table) = block, table.databaseLink != nil || value.databaseLink != nil {
              LibraryClientLinkedPreview(model: model, note: source, tableID: table.id, html: nil)
            } else { Text(block.plainText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
          }
        }.padding(22)
      }
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("Untitled note", text: Binding(get: { source.title }, set: { model.editNote(source, title: $0) }))
          .textFieldStyle(.plain).font(.system(size: 21, weight: .semibold))
        Spacer()
        Text(model.state.isDirty(note.id) ? "Saved on this Mac" : "Synchronized").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
        Button { details = true } label: { Image(systemName: "ellipsis") }.buttonStyle(DashboardIconButtonStyle()).help("Note details")
      }.padding(22)
      if model.state.uncachedNoteIDs.contains(note.id) {
        ContentUnavailableView("Not downloaded", systemImage: "arrow.down.circle", description: Text("Reconnect to the central database to download this note."))
      } else if !cache.isEditable(noteID: note.id, source: source.content) {
        Text("This document uses a newer format. Update Woven Matter to edit it.").padding()
      } else if hasLinkedData, document.wrappedValue.kind != .canvas {
        linkedPreview
      } else {
        switch document.wrappedValue.kind {
        case .note:
          HStack(spacing: 12) {
            Button("Bold") { editor.toggleBold() }; Button("Italic") { editor.toggleItalic() }; Button("Underline") { editor.toggleUnderline() }
            Button("Insert table") { editor.insertTable() }; Spacer()
          }.buttonStyle(DashboardQuietButtonStyle()).padding(.horizontal, 22)
          DashboardNoteEditor(document: document, controller: editor).padding(.horizontal, 22)
        case .spreadsheet: DashboardSpreadsheetEditor(document: document)
        case .canvas: LibraryClientPagePreview(model: model, note: source, document: document.wrappedValue)
        case .html:
          VSplitView {
            TextEditor(text: Binding(get: { document.wrappedValue.html }, set: { var value = document.wrappedValue; value.html = $0; document.wrappedValue = value }))
              .font(.system(size: 12, design: .monospaced)).frame(minHeight: 150)
            DashboardHTMLArtifactView(html: document.wrappedValue.html, linkedDataJSON: nil,
              persistentState: document.wrappedValue.artifactState ?? [:]).frame(minHeight: 150)
          }.padding(.horizontal, 22)
        }
      }
    }
    .sheet(isPresented: $details) {
      LibraryClientItemManagementSheet(model: model, id: note.id, isNote: true, title: source.title, folderID: source.folderID ?? "").frame(minWidth: 440, minHeight: 430)
    }
  }
}

private struct LibraryClientLinkedPreview: View {
  @Environment(\.dashboardTheme) private var theme
  @Bindable var model: CentralLibraryClientModel
  let note: CompanionNote
  let tableID: String?
  let html: String?
  /// Inside a Page's scrolling document, which needs a bounded table to give it a height.
  var embedded = false
  @State private var data: CompanionLinkedData?
  @State private var error: String?
  @State private var loading = false
  private var requestKey: String { "\(note.id):\(note.revision):\(tableID ?? "document"):\(model.online)" }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        DashboardLucideIcon(glyph: .database, size: 14)
        Text("Live linked data · read only").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
        Spacer()
        if loading { ProgressView().controlSize(.small) }
        else { Button("Refresh") { Task { await load() } }.disabled(!model.online) }
      }
      if let error { Text(error).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
      if let html {
        DashboardHTMLArtifactView(html: html, linkedDataJSON: data?.json,
          persistentState: NoteDocument.decode(note.content).artifactState ?? [:]).frame(minHeight: 250)
      } else if let data {
        ScrollView([.horizontal, .vertical]) {
          LazyVStack(alignment: .leading, spacing: 0) {
            row(data.columns, header: true)
            ForEach(Array(data.rows.enumerated()), id: \.offset) { _, cells in row(cells, header: false) }
          }
        }.frame(minHeight: embedded ? 180 : nil, maxHeight: embedded ? 420 : nil)
          .accessibilityLabel("Live linked table, read only")
      }
    }.padding(embedded ? 8 : 22).task(id: requestKey) { await load() }
  }
  private func row(_ cells: [String], header: Bool) -> some View {
    HStack(spacing: 0) {
      ForEach(Array(cells.enumerated()), id: \.offset) { _, text in
        Text(text).font(.system(size: 13, weight: header ? .semibold : .regular)).textSelection(.enabled)
          .frame(width: 150, alignment: .leading).padding(8)
          .background(header ? theme.palette.themeWhisper : .clear)
          .overlay(Rectangle().stroke(theme.palette.border, lineWidth: 0.5))
      }
    }
  }
  private func load() async {
    let key = requestKey
    // The result replaces the old data in one step, so a refresh reaches an Artifact
    // as one data change rather than as null followed by the new rows.
    error = nil; loading = true
    defer { if requestKey == key { loading = false } }
    guard model.online else { data = nil; error = "Connect to your central database to preview this linked data."; return }
    do {
      let result = try await model.linkedData(note: note, tableID: tableID)
      guard !Task.isCancelled, requestKey == key else { return }
      data = result
    } catch is CancellationError {} catch {
      if requestKey == key { data = nil; self.error = error.localizedDescription }
    }
  }
}

/// A client reads a Page here and changes it on the library host, whose component
/// revisions protect concurrent work. Nothing in this view can write to the document.
private struct LibraryClientPagePreview: View {
  @Bindable var model: CentralLibraryClientModel
  let note: CompanionNote
  let document: NoteDocument
  var body: some View {
    let page = document.materializedPage()
    let blocks = Dictionary(page.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        Text("Page · read only").font(.caption).foregroundStyle(DashboardPalette.mutedForeground).padding(.leading, 24)
        if let purpose = page.boardPurpose, !purpose.isEmpty {
          Text(purpose).font(.system(size: 14)).foregroundStyle(DashboardPalette.mutedForeground)
            .textSelection(.enabled).padding(.leading, 24).padding(.bottom, 10)
        }
        ForEach(page.pageSegments) { segment in
          segmentView(segment, page: page, blocks: blocks).padding(.leading, CGFloat(segment.depth) * 20)
        }
        if page.blocks.isEmpty {
          Text("This Page has no content yet.").foregroundStyle(DashboardPalette.mutedForeground).padding(.leading, 24)
        }
        let connections = page.pageLegacyConnections
        if !connections.isEmpty {
          DisclosureGroup("Retained connections") {
            ForEach(connections) { connection in
              Text(verbatim: "\(connection.fromText.prefix(60)) → \(connection.toText.prefix(60))"
                + (connection.label.isEmpty ? "" : ": \(connection.label)"))
                .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }.padding(.top, 20).padding(.leading, 24)
        }
      }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 60)
    }.scrollIndicators(.never)
  }
  @ViewBuilder private func segmentView(_ segment: PageSegment, page: NoteDocument, blocks: [String: NoteBlock]) -> some View {
    switch segment {
    case let .flow(_, _, _, _, ids):
      ForEach(LibraryClientPagePiece.pieces(of: ids, page: page, blocks: blocks)) { piece in
        switch piece {
        case .text(let flow, _): LibraryClientPageText(document: flow)
        case .linkedTable(let id): LibraryClientLinkedPreview(model: model, note: note, tableID: id, html: nil, embedded: true)
        case .details(let item, _): LibraryClientPageDetails(item: item, showsPlainStatus: false).padding(.leading, 24).padding(.bottom, 6)
        }
      }
    case let .section(id, _, _):
      VStack(alignment: .leading, spacing: 4) {
        let title = blocks[id]?.plainText ?? ""
        Text(title.isEmpty ? "Untitled section" : title).font(.system(size: 19, weight: .semibold))
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityAddTraits(.isHeader)
        if let item = page.boardItems?[id], item.hasPreviewDetails {
          LibraryClientPageDetails(item: item, showsPlainStatus: false)
        }
      }.padding(.leading, 24).padding(.top, 14).padding(.bottom, 3)
    case let .asset(id, assetID, _, _):
      LibraryClientPageOriginal(model: model, assetID: assetID, label: page.canvas?[id]?.title, item: page.boardItems?[id])
        .padding(.vertical, 6)
    }
  }
}

/// One flow splits where the native editor cannot show something by itself: a linked
/// table is evaluated by the library host, and task details have no inspector here.
private enum LibraryClientPagePiece: Identifiable {
  case text(NoteDocument, firstBlockID: String)
  case linkedTable(String)
  case details(BoardItem, blockID: String)

  var id: String {
    switch self {
    case .text(_, let id): "text:" + id
    case .linkedTable(let id): "table:" + id
    case .details(_, let id): "details:" + id
    }
  }

  static func pieces(of ids: [String], page: NoteDocument, blocks: [String: NoteBlock]) -> [Self] {
    var pieces: [Self] = []
    var run: [String] = []
    func flush() {
      guard let first = run.first else { return }
      pieces.append(.text(flowDocument(run, page: page), firstBlockID: first))
      run = []
    }
    for id in ids {
      if case .table(let table)? = blocks[id], table.databaseLink != nil || page.databaseLink != nil {
        flush()
        pieces.append(.linkedTable(id))
      } else { run.append(id) }
      if let item = page.boardItems?[id], item.hasPreviewDetails {
        flush()
        pieces.append(.details(item, blockID: id))
      }
    }
    flush()
    return pieces
  }

  /// The same projection the Page editor gives the Notes renderer, so text and task
  /// checkboxes look the same on both. It is only displayed, never saved.
  private static func flowDocument(_ ids: [String], page: NoteDocument) -> NoteDocument {
    var flow = page.pageFlowDocument(blockIDs: ids)
    flow.kind = .canvas
    let shown = Set(ids)
    let items = (page.boardItems ?? [:]).filter { shown.contains($0.key) }.mapValues { source in
      var item = source
      item.createdBy = nil; item.createdAt = nil; item.updatedBy = nil; item.updatedAt = nil
      return item
    }.filter { $0.value != BoardItem() }
    flow.boardItems = items.isEmpty ? nil : items
    return flow
  }
}

private struct LibraryClientPageText: View {
  let document: NoteDocument
  @State private var controller = DashboardNoteEditorController()
  var body: some View {
    DashboardNoteEditor(document: .constant(document), controller: controller, sizesToContent: true)
      .frame(minHeight: 40).disabled(true).accessibilityLabel("Page text, read only")
  }
}

private extension BoardItem {
  /// A checkbox already shows to do and done, so only other states need words.
  var hasPreviewDetails: Bool {
    if review == .needed || role == .instructions || lastChange?.isEmpty == false { return true }
    guard let task else { return false }
    return ![.todo, .done].contains(task.status) || !task.assignee.isEmpty || !task.outcome.isEmpty
  }
}

private struct LibraryClientPageDetails: View {
  let item: BoardItem
  /// An original has no checkbox, so it also names to do and done.
  let showsPlainStatus: Bool
  private var statusLabel: String? {
    switch item.task?.status {
    case .todo: showsPlainStatus ? "To do" : nil
    case .done: showsPlainStatus ? "Done" : nil
    case .doing: "In progress"
    case .blocked: "Blocked"
    case .canceled: "Canceled"
    case nil: nil
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        if let statusLabel { Text(statusLabel) }
        if let assignee = item.task?.assignee, !assignee.isEmpty { Text(assignee) }
        if item.role == .instructions { Label("Reference instructions", systemImage: "book.closed") }
        if item.review == .needed { Label("Needs review", systemImage: "tray") }
      }.foregroundStyle(DashboardPalette.mutedForeground)
      if let outcome = item.task?.outcome, !outcome.isEmpty { Text(outcome).textSelection(.enabled) }
      if let change = item.lastChange, !change.isEmpty {
        Text(change).foregroundStyle(DashboardPalette.mutedForeground).textSelection(.enabled)
      }
    }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A reference by stable ID. Opening uses the normal note tab, whose pane chooses
/// between the synchronized local record and the client preview of linked data.
private struct LibraryClientPageOriginal: View {
  @Environment(\.workspaceApplicationModel) private var appModel
  @Bindable var model: CentralLibraryClientModel
  let assetID: String
  let label: String?
  let item: BoardItem?
  private var clientNote: CompanionNote? {
    model.state.deletedNotes.contains(assetID) ? nil : model.state.notes[assetID]
  }
  private var localNote: WorkspaceNoteRecord? { appModel?.workspaceOverview?.notes.first { $0.id == assetID } }
  private var canOpen: Bool {
    guard appModel != nil else { return false }
    return localNote != nil || clientNote.map(DevelopmentLibraryProjection.usesCentralPreview) == true
  }
  private var title: String {
    [clientNote?.title, localNote?.title, label].compactMap { $0 }.first { !$0.isEmpty } ?? "Original asset"
  }
  private var kindName: String? {
    if let clientNote, let kind = clientNote.kind { return kind.displayName }
    return (localNote?.content ?? clientNote?.content).map { NoteDocument.decode($0).kind.displayName }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
        Label("Original", systemImage: "link").font(.system(size: 10)).foregroundStyle(DashboardPalette.mutedForeground)
        if let kindName { Text(kindName).font(.system(size: 10)).foregroundStyle(DashboardPalette.mutedForeground) }
        Spacer()
        Button { appModel?.workspaceAssets.openNote(assetID) } label: { Image(systemName: "arrow.up.right.square") }
          .buttonStyle(DashboardIconButtonStyle()).help("Open original")
          .accessibilityLabel("Open original asset").disabled(!canOpen)
      }
      if !canOpen {
        Text(clientNote == nil ? "The original asset is unavailable. Its reference is retained."
          : "The original has not synchronized to this Mac yet. Its reference is retained.")
          .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
      }
      if let item, item.task != nil || item.hasPreviewDetails { LibraryClientPageDetails(item: item, showsPlainStatus: true) }
    }
    .padding(12)
    .background(DashboardPalette.muted.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
  }
}
