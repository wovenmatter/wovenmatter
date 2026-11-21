import SwiftUI
import UIKit
import WovenProtocol

/// The open artifact filling the tab: its header (Settings, the title, which
/// opens renaming and the other artifacts, and the kind's controls), its
/// editor, and the note's count in the bottom gutter.
struct ArtifactScreen: View {
  @Bindable var model: MobileModel
  let record: WorkspaceNoteRecord
  @Environment(\.wovenTheme) private var theme
  @State private var session: ArtifactTextSession
  @State private var page = PageEditorState()
  @State private var sheetHistory = SheetUndoHistory()
  @State private var appHistory = ArtifactCodeHistory()
  @State private var documentCache = NoteDocumentCache()
  @State private var chooserPresented = false
  @State private var versionsPresented = false
  @State private var databasePresented = false
  @State private var sheetFormatPresented = false
  @State private var linkEditorPresented = false
  @State private var link = ""
  @State private var showsCharacterCount = false
  @State private var keyboardVisible = false

  init(model: MobileModel, record: WorkspaceNoteRecord) {
    self.model = model
    self.record = record
    _session = State(initialValue: ArtifactTextSession(id: record.id, documents: model.app.documents))
  }

  private var documents: DocumentsStore { model.app.documents }
  private var kind: NoteArtifactKind { record.kind }
  private var content: String { documents.content(of: record) }
  private var title: String { documents.title(of: record) }

  /// The document for the Sheet and App editors, as the Mac's pane binds it.
  private var document: Binding<NoteDocument> {
    Binding(
      get: { documentCache.value(noteID: record.id, source: content) },
      set: { updated in
        guard documentCache.isEditable(noteID: record.id, source: content),
              let encoded = try? documentCache.encode(updated, noteID: record.id) else { return }
        documents.updateNote(id: record.id, content: encoded)
      })
  }

  /// The Sheet's document, recording each local edit for undo.
  private var sheetDocument: Binding<NoteDocument> {
    Binding(get: { document.wrappedValue }, set: { updated in
      let before = document.wrappedValue
      document.wrappedValue = updated
      sheetHistory.recordLocal(from: before, to: document.wrappedValue)
    })
  }

  private var structuredEditable: Bool { documentCache.isEditable(noteID: record.id, source: content) }
  private var editable: Bool { kind == .note || kind == .canvas ? session.editable : structuredEditable }
  private var appCode: String? { kind == .html ? document.wrappedValue.html : nil }

  var body: some View {
    VStack(spacing: 0) {
      TabRootHeader(title: title.isEmpty ? kind.untitledName : title, subtitle: kind.displayName,
                    onTitleTap: { chooserPresented = true }, titleHint: "Renames it and shows other artifacts") {
        ArtifactHeaderControls(model: model, record: record, session: session, page: page,
                               undo: undoState, editable: editable, hasDatabaseLinks: !databaseLinks.isEmpty,
                               versions: { versionsPresented = true }, database: { databasePresented = true },
                               formatSheet: { sheetFormatPresented = true }, editLink: editLink)
      }
      // Undo, redo, formatting and dictation continue editing the focused paragraph.
      .keepsKeyboard()
      editor
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      VStack(spacing: 0) { footer }
        .background { MobileBottomFade(fades: kind == .note || kind == .canvas) }
    }
    .onAppear { documents.open(record) }
    .onChange(of: record) { _, updated in documents.open(updated) }
    .onChange(of: content, initial: true) { _, _ in session.observeStore() }
    // Each change to an App's code, usually by an agent, is one undo step.
    .onChange(of: appCode) { old, new in
      if let old, let new { appHistory.observe(old: old, new: new) }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    .onDisappear { session.controller.reset() }
    .sheet(isPresented: $chooserPresented) {
      ArtifactChooser(model: model, record: record).sheetTheme(theme)
    }
    .sheet(isPresented: $versionsPresented) {
      ArtifactVersionHistory(model: model, artifactID: record.id).sheetTheme(theme)
    }
    .sheet(isPresented: $databasePresented) {
      ArtifactDatabaseLinks(links: databaseLinks, snapshot: model.app.databases.snapshot).sheetTheme(theme)
    }
    .sheet(isPresented: $sheetFormatPresented) {
      NavigationStack {
        SpreadsheetFormattingBar(document: sheetDocument)
          .padding(20)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .mobilePageSurface()
          .navigationTitle("Format sheet")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheetFormatPresented = false } } }
      }
      .presentationDetents([.height(180)])
      .sheetTheme(theme)
    }
    .alert("Link", isPresented: $linkEditorPresented) {
      TextField("https://…", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
      Button("Apply") { session.format(.link(link.trimmingCharacters(in: .whitespacesAndNewlines))) }
      Button("Cancel", role: .cancel) {}
    } message: { Text("Apply a link to the selected text.") }
  }

  @ViewBuilder private var editor: some View {
    switch kind {
    case .note:
      NoteArtifactBody(session: session)
    case .canvas:
      if let document = session.document {
        MobilePageEditor(model: model, record: record, session: session, state: page, document: document)
      } else {
        ArtifactSourceView(content: content)
      }
    case .spreadsheet:
      if structuredEditable {
        SpreadsheetEditor(document: sheetDocument)
          .accessibilityLabel("Sheet")
      } else {
        ArtifactSourceView(content: content)
      }
    case .html:
      if !structuredEditable {
        ArtifactSourceView(content: content)
      } else if document.wrappedValue.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        AppBuildPrompt(openChat: { model.select(.chat) })
      } else {
        // The device's core serves no database reads, so a Live App shows without its data here.
        PersistentArtifactView(document: document, linkedDataJSON: nil,
          savedState: documents.appState(noteID: record.id),
          currentState: { documents.appState(noteID: record.id) },
          saveState: { documents.enqueueArtifactInput(noteID: record.id, edit: $0, after: $1) },
          reportUnsaved: { documents.setArtifactInputsUnsaved(generation: $0, $1) })
        .accessibilityLabel("App")
      }
    }
  }

  /// Below the editor: an edit that could not be made, then the format bar
  /// while typing, else the note's count in its 24-point gutter.
  @ViewBuilder private var footer: some View {
    if let error = session.error {
      Button { session.error = nil } label: {
        Text(error).font(.caption).foregroundStyle(WovenPalette.danger).multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 20)
      .accessibilityHint("Dismisses this message")
      .accessibilityIdentifier("artifact-edit-error")
    }
    if kind == .note || kind == .canvas {
      if keyboardVisible && editable {
        NoteKeyboardBar(session: session, editLink: editLink)
      } else if let document = session.document {
        let statistics = NoteTextStatistics(document: kind == .canvas ? document.materializedPage() : document)
        Button { showsCharacterCount.toggle() } label: {
          Text(showsCharacterCount
               ? "\(statistics.characters.formatted()) \(statistics.characters == 1 ? "character" : "characters")"
               : "\(statistics.words.formatted()) \(statistics.words == 1 ? "word" : "words")")
            .font(.system(size: 11)).monospacedDigit()
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(WovenIconButtonStyle())
        .foregroundStyle(WovenPalette.mutedForeground)
        .accessibilityLabel(showsCharacterCount ? "Note character count" : "Note word count")
        .accessibilityValue(showsCharacterCount ? "\(statistics.characters)" : "\(statistics.words)")
        .accessibilityHint(showsCharacterCount ? "Show word count" : "Show character count")
        .accessibilityIdentifier("note-text-count")
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 12)
      }
    }
  }

  private var undoState: ArtifactUndo {
    switch kind {
    case .note, .canvas:
      ArtifactUndo(canUndo: session.controller.canUndo, canRedo: session.controller.canRedo,
                   undo: { session.controller.undo() }, redo: { session.controller.redo() })
    case .spreadsheet:
      ArtifactUndo(canUndo: sheetHistory.canUndo, canRedo: sheetHistory.canRedo,
                   undo: { if let value = sheetHistory.undo(current: document.wrappedValue) { document.wrappedValue = value } },
                   redo: { if let value = sheetHistory.redo(current: document.wrappedValue) { document.wrappedValue = value } })
    case .html:
      ArtifactUndo(canUndo: appHistory.canUndo, canRedo: appHistory.canRedo,
                   undo: { restoreAppCode(appHistory.undo(current: document.wrappedValue.html)) },
                   redo: { restoreAppCode(appHistory.redo(current: document.wrappedValue.html)) })
    }
  }

  /// Restores earlier App code. Saved inputs are kept: the store merges them
  /// separately from the code.
  private func restoreAppCode(_ html: String?) {
    guard let html else { return }
    var value = document.wrappedValue
    value.html = html
    document.wrappedValue = value
  }

  /// Every database link the document holds: its own, its tables' and inline values'.
  private var databaseLinks: [DatabaseArtifactLink] {
    guard let current = session.document ?? (structuredEditable ? document.wrappedValue : nil) else { return [] }
    return [current.databaseLink].compactMap { $0 } + current.blocks.flatMap { block -> [DatabaseArtifactLink] in
      switch block {
      case .table(let table): [table.databaseLink].compactMap { $0 }
      case .richText(let text): text.runs.compactMap(\.databaseLink)
      }
    }
  }

  private func editLink() {
    link = ""
    linkEditorPresented = true
  }
}

/// Undo and redo for whichever editor the artifact uses.
struct ArtifactUndo {
  var canUndo: Bool
  var canRedo: Bool
  var undo: () -> Void
  var redo: () -> Void
}

/// The header's trailing controls, in the style guide's order for each kind.
/// A phone shows Undo, Redo and the kind's most used control; the rest fold
/// into one ellipsis menu in the same order, with the artifact's own actions.
private struct ArtifactHeaderControls: View {
  @Bindable var model: MobileModel
  let record: WorkspaceNoteRecord
  let session: ArtifactTextSession
  let page: PageEditorState
  let undo: ArtifactUndo
  let editable: Bool
  let hasDatabaseLinks: Bool
  let versions: () -> Void
  let database: () -> Void
  let formatSheet: () -> Void
  let editLink: () -> Void
  private var dictation: DictationSession { MobileDictation.shared.session }

  var body: some View {
    HStack(spacing: 0) {
      if editable {
        Button(action: undo.undo) { Image(systemName: "arrow.uturn.backward").font(.system(size: 17)).frame(width: 44, height: 44) }
          .disabled(!undo.canUndo)
          .accessibilityLabel(record.kind == .html ? "Undo the last code change" : "Undo")
          .accessibilityIdentifier("artifact-undo")
        Button(action: undo.redo) { Image(systemName: "arrow.uturn.forward").font(.system(size: 17)).frame(width: 44, height: 44) }
          .disabled(!undo.canRedo)
          .accessibilityLabel(record.kind == .html ? "Redo the code change" : "Redo")
          .accessibilityIdentifier("artifact-redo")
      }
      primary
      Menu {
        folded
        Divider()
        artifactActions
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44)
      }
      .accessibilityLabel("More")
      .accessibilityIdentifier("artifact-more")
    }
  }

  /// The one control kept beside Undo and Redo.
  @ViewBuilder private var primary: some View {
    switch record.kind {
    case .note:
      if editable { MobileDictationMicrophone(editor: session.dictation) }
    case .canvas:
      if editable {
        Menu {
          PageAddActions(model: model, session: session, state: page, folderID: record.folderID, position: insertionPosition)
        } label: {
          LucideIcon(glyph: .plus, size: 20).frame(width: 44, height: 44)
        }
        .accessibilityLabel("Add component")
        .accessibilityIdentifier("page-add-component")
      }
    case .spreadsheet:
      if editable {
        Button(action: formatSheet) { Image(systemName: "textformat").font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44) }
          .accessibilityLabel("Format sheet")
          .accessibilityIdentifier("sheet-format")
      }
    case .html:
      Button(action: versions) { Image(systemName: "clock.arrow.circlepath").font(.system(size: 17)).frame(width: 44, height: 44) }
        .accessibilityLabel("Version history")
        .accessibilityIdentifier("artifact-versions")
    }
  }

  /// The kind's other controls, in their order.
  @ViewBuilder private var folded: some View {
    if record.kind != .html {
      Button("Version history", systemImage: "clock.arrow.circlepath", action: versions)
    }
    Button(action: database) { Label("Database", glyph: .database) }
      .disabled(!hasDatabaseLinks)
    if editable {
      switch record.kind {
      case .note:
        Menu {
          NoteFormatMenuItems(session: session, editLink: editLink)
        } label: { Label("Format note", systemImage: "textformat") }
      case .canvas:
        Menu {
          NoteFormatMenuItems(session: session, editLink: editLink)
        } label: { Label("Format page", systemImage: "textformat") }
        Button(dictationTitle, systemImage: dictation.isRecording ? "stop.circle" : "mic") {
          if session.controller.activeBlockID == nil { session.focusEnd() }
          MobileDictation.shared.toggle(session.dictation)
        }
        .disabled(dictation.phase == .finishing)
      case .spreadsheet, .html:
        EmptyView()
      }
    }
  }

  @ViewBuilder private var artifactActions: some View {
    let workspace = model.app.workspace
    Button(record.isPinned ? "Unpin" : "Pin", systemImage: record.isPinned ? "pin.slash" : "pin") {
      mutate(.setPinned(!record.isPinned))
    }
    let folders = workspace.workspaceOverview?.folders ?? []
    if !folders.isEmpty {
      Menu {
        Button("No folder") { mutate(.moveToFolder(nil)) }.disabled(record.folderID == nil)
        ForEach(folders) { folder in
          Button(folderName(folder)) { mutate(.moveToFolder(folder.id)) }.disabled(record.folderID == folder.id)
        }
      } label: { Label("Move to folder", glyph: .folder) }
    }
    Button(role: .destructive) {
      mutate(.moveToTrash)
      model.closeArtifact()
    } label: { Label("Move to Trash", glyph: .trash) }
  }

  private var insertionPosition: PagePosition {
    guard let document = session.document else { return .init() }
    return MobilePageEditing.insertionPosition(after: session.selectedBlockID,
                                               in: MobilePageLayout(page: document, placeholders: session.placeholders))
  }

  private var dictationTitle: String {
    dictation.retainedTranscript != nil ? "Insert dictation" : dictation.isRecording ? "Stop dictation" : "Start dictation"
  }

  private func folderName(_ folder: WorkspaceFolderRecord) -> String {
    guard let machine = model.app.machines.machine(id: folder.machineID) else { return folder.name }
    return "\(folder.name) · \(machine.name)"
  }

  private func mutate(_ mutation: WorkspaceNoteMutation) {
    let id = record.id
    let workspace = model.app.workspace
    Task { try? await workspace.mutateNote(id: id, mutation: mutation) }
  }
}

/// The database links an artifact holds. Linking one is done on a Mac.
private struct ArtifactDatabaseLinks: View {
  let links: [DatabaseArtifactLink]
  let snapshot: DatabasesSnapshot
  @Environment(\.dismiss) private var dismiss
  @Environment(\.wovenTheme) private var theme

  var body: some View {
    NavigationStack {
      List {
        ForEach(Array(links.enumerated()), id: \.offset) { _, link in
          VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.database(sourceID: link.sourceID, databaseID: link.databaseID)?.name ?? "Database")
              .font(.body.weight(.medium))
            Text(link.sqliteQuery ?? link.relativePath).font(.system(.caption, design: .monospaced))
              .foregroundStyle(WovenPalette.mutedForeground).textSelection(.enabled)
          }
          .frame(minHeight: 44, alignment: .leading)
          .listRowBackground(theme.palette.themeWhisper)
        }
      }
      .mobilePageSurface()
      .navigationTitle("Database")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    .presentationDetents([.medium])
  }
}
