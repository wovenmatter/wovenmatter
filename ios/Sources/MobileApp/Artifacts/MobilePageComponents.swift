import SwiftUI
import UIKit
import WovenProtocol

/// A task's status circle. Whoever has the task sets it, so it is not a control.
struct MobilePageTaskStatus: View {
  let status: BoardTaskStatus

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 20, weight: .regular))
      .foregroundStyle(status == .done ? WovenPalette.primary : status == .blocked ? WovenPalette.warning : WovenPalette.mutedForeground)
      .frame(width: 32, height: 40)
      .accessibilityLabel("Task, \(status.displayName)")
  }

  private var symbol: String {
    switch status {
    case .todo: "circle"
    case .doing: "circle.lefthalf.filled"
    case .blocked: "exclamationmark.circle"
    case .done: "checkmark.circle.fill"
    }
  }
}

/// Who has a task and what they wrote, review and change summary, shown under a component.
struct MobilePageItemSummary: View {
  let item: BoardItem

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 10) {
        if item.role == .instructions { Label("Reference instructions", systemImage: "book.closed") }
        if item.review == .needed { Label("Needs review", systemImage: "tray") }
      }.foregroundStyle(WovenPalette.mutedForeground)
      if let details = item.task?.details, !details.isEmpty { Text(details).textSelection(.enabled) }
      ForEach(item.task?.assignees ?? []) { assignee in
        Label(assignee.mobileSummary, glyph: .userRound).foregroundStyle(WovenPalette.mutedForeground)
        if let message = assignee.message, !message.isEmpty, assignee.state == .failed {
          Text(message).foregroundStyle(WovenPalette.danger)
        }
      }
      if let outcome = item.task?.outcome, !outcome.isEmpty { Text(outcome).textSelection(.enabled) }
      if let change = item.lastChange, !change.isEmpty {
        Text(change).foregroundStyle(WovenPalette.mutedForeground).textSelection(.enabled)
      }
    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A Page table. Tapping a cell edits it; the original shape rules apply on save.
struct MobilePageTable: View {
  @Environment(\.wovenTheme) private var theme
  let table: NoteTableBlock
  let editable: Bool
  var maximumRows = Int.max
  var edit: (Int, Int) -> Void = { _, _ in }

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(Array(table.rows.prefix(maximumRows).enumerated()), id: \.element.id) { rowIndex, row in
          GridRow {
            ForEach(Array(row.cells.enumerated()), id: \.element.id) { column, cell in
              let text = Text(AttributedString(RichBlockTextView.attributed(.init(runs: cell.runs))))
                .frame(minWidth: 100, minHeight: 34, alignment: .leading).padding(8)
                .background(cell.backgroundHex.flatMap(UIColor.init(hex:)).map { Color(wovenColor: WovenColors.noteBackground($0)) }
                  ?? (rowIndex < table.headerRowCount ? theme.palette.themeWhisper : .clear))
                .overlay(Rectangle().stroke(WovenPalette.mutedForeground.opacity(0.25), lineWidth: 0.5))
              if editable {
                Button { edit(rowIndex, column) } label: { text.contentShape(Rectangle()) }.buttonStyle(.plain)
                  .accessibilityLabel(cell.plainText.isEmpty ? "Empty cell" : cell.plainText)
                  .accessibilityHint("Edit this cell")
                  .accessibilityIdentifier("page-cell-\(table.id)-\(rowIndex)-\(column)")
              } else { text }
            }
          }
        }
      }
    }.scrollIndicators(.never)
  }
}

extension NoteTableBlock {
  func settingText(_ text: String, row: Int, column: Int) -> NoteTableBlock {
    var copy = self
    guard copy.rows.indices.contains(row), copy.rows[row].cells.indices.contains(column) else { return copy }
    var cell = copy.rows[row].cells[column]
    guard cell.plainText != text else { return copy }
    var run = cell.runs.first ?? NoteTextRun(text: "")
    run.text = text
    cell.runs = text.isEmpty ? [] : [run]
    copy.rows[row].cells[column] = cell
    return copy
  }
  func insertingRow(after row: Int) -> NoteTableBlock {
    var copy = self
    copy.rows.insert(NoteTableRow(cellCount: columns.count), at: min(row + 1, copy.rows.count))
    return copy
  }
  func insertingColumn(after column: Int) -> NoteTableBlock {
    var copy = self
    let index = min(column + 1, copy.columns.count)
    copy.columns.insert(NoteTableColumn(), at: index)
    for row in copy.rows.indices { copy.rows[row].cells.insert(NoteTableCell(), at: min(index, copy.rows[row].cells.count)) }
    return copy
  }
  func removingRow(_ row: Int) -> NoteTableBlock {
    var copy = self
    guard copy.rows.indices.contains(row) else { return copy }
    copy.rows.remove(at: row)
    if row < copy.headerRowCount { copy.headerRowCount -= 1 }
    return copy
  }
  func removingColumn(_ column: Int) -> NoteTableBlock {
    var copy = self
    guard copy.columns.indices.contains(column) else { return copy }
    copy.columns.remove(at: column)
    for row in copy.rows.indices where copy.rows[row].cells.indices.contains(column) { copy.rows[row].cells.remove(at: column) }
    return copy
  }
}

/// Edits one cell, and adds or removes its row and column.
struct MobilePageCellEditor: View {
  @Environment(\.dismiss) private var dismiss
  let table: NoteTableBlock
  let target: MobilePageCellTarget
  /// Applies a change to the table as it is now; returns the shared refusal.
  let apply: (String, @escaping (NoteTableBlock) throws -> NoteTableBlock) -> String?
  @State private var text: String
  @State private var problem: String?

  init(table: NoteTableBlock, target: MobilePageCellTarget,
       apply: @escaping (String, @escaping (NoteTableBlock) throws -> NoteTableBlock) -> String?) {
    self.table = table; self.target = target; self.apply = apply
    let cells = table.rows.indices.contains(target.row) ? table.rows[target.row].cells : []
    _text = State(initialValue: cells.indices.contains(target.column) ? cells[target.column].plainText : "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Cell text", text: $text, axis: .vertical).lineLimit(1...8).accessibilityIdentifier("page-cell-text")
        }
        if let problem { Text(problem).font(.caption).foregroundStyle(WovenPalette.danger).accessibilityIdentifier("page-cell-error") }
        Section("Row \(target.row + 1)") {
          Button("Add row below") { run("Add row") { $0.insertingRow(after: target.row) } }
          Button("Remove row", role: .destructive) { run("Remove row") { $0.removingRow(target.row) } }
            .disabled(table.rows.count <= 1)
        }
        Section("Column \(target.column + 1)") {
          Button("Add column after") { run("Add column") { $0.insertingColumn(after: target.column) } }
          Button("Remove column", role: .destructive) { run("Remove column") { $0.removingColumn(target.column) } }
            .disabled(table.columns.count <= 1)
        }
      }
      .scrollIndicators(.never)
      .navigationTitle("Edit cell").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { run("Edit table") { $0.settingText(text, row: target.row, column: target.column) } }
            .accessibilityIdentifier("page-cell-save")
        }
      }
    }.presentationDetents([.medium, .large])
  }

  private func run(_ action: String, _ transform: @escaping (NoteTableBlock) -> NoteTableBlock) {
    // A text edit saved with a shape change keeps what was typed.
    let typed = text, row = target.row, column = target.column
    problem = apply(action) { current in
      action == "Edit table" ? transform(current) : transform(current.settingText(typed, row: row, column: column))
    }
    if problem == nil { dismiss() }
  }
}

/// Component actions, matching the Mac's menu and copy.
struct MobilePageComponentMenu: View {
  let page: NoteDocument
  let componentID: String
  let commit: (String, (inout NoteDocument) throws -> Void) -> String?
  let onMoved: () -> Void

  var body: some View {
    let kind = page.pageComponentKind(for: componentID)
    let item = page.boardItems?[componentID]
    let siblings = page.pageChildren(of: page.pageParentID(for: componentID))
    let index = siblings.firstIndex(of: componentID) ?? 0
    Menu {
      if let task = item?.task {
        Button(task.status == .done ? "Reopen task" : "Complete task") {
          update(task.status == .done ? "Reopen task" : "Complete task", .init(status: task.status == .done ? .todo : .done))
        }
      }
      if kind != .section && item?.task == nil {
        Button("Turn into task") { update("Task", .init(status: .todo)) }
      }
      if kind == .table, case .table(let table)? = page.blocks.first(where: { $0.id == componentID }) {
        Divider()
        Button("Add row") { replaceTable("Add row") { $0.insertingRow(after: $0.rows.count - 1) } }
        Button("Add column") { replaceTable("Add column") { $0.insertingColumn(after: $0.columns.count - 1) } }
        Button("Remove last row") { replaceTable("Remove row") { $0.removingRow($0.rows.count - 1) } }.disabled(table.rows.count <= 1)
        Button("Remove last column") { replaceTable("Remove column") { $0.removingColumn($0.columns.count - 1) } }.disabled(table.columns.count <= 1)
      }
      Divider()
      Button("Move up") { move(MobilePageEditing.siblingMove(componentID, by: -1, in: page)) }.disabled(index == 0)
      Button("Move down") { move(MobilePageEditing.siblingMove(componentID, by: 1, in: page)) }.disabled(index >= siblings.count - 1)
      if let section = MobilePageEditing.sectionAbove(componentID, in: page) {
        Button("Move into section above") { move(.init(parentID: section)) }
      }
      if let parent = page.pageParentID(for: componentID) {
        Button("Move out of section") { move(.init(parentID: page.pageParentID(for: parent), afterID: parent)) }
      }
      Divider()
      if kind == .section {
        Button("Remove section, keep content") { remove(.promoteChildren) }
        Button("Remove section and content", role: .destructive) { remove(.removeSubtree) }
      } else {
        Button("Remove component", role: .destructive) { remove(nil) }
      }
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium)).frame(width: 32, height: 44)
        .foregroundStyle(WovenPalette.mutedForeground)
    }
    .accessibilityLabel("Component actions").accessibilityIdentifier("page-component-actions-\(componentID)")
  }

  private func update(_ action: String, _ patch: BoardItemPatch) {
    _ = commit(action) { page in
      try page.applyPageEdit(.init(action: .update, id: componentID, expectedRevision: page.boardItemRevision(for: componentID), patch: patch))
    }
  }

  private func replaceTable(_ action: String, _ transform: @escaping (NoteTableBlock) -> NoteTableBlock) {
    _ = commit(action) { page in
      guard case .table(let table)? = page.blocks.first(where: { $0.id == componentID }) else { throw RichDocumentEditing.Failure.missingBlock }
      try page.applyPageEdit(.init(action: .update, id: componentID, expectedRevision: page.boardItemRevision(for: componentID),
                                   block: .table(transform(table))))
    }
  }

  private func move(_ position: PagePosition?) {
    guard let position else { return }
    if commit("Move component", { page in
      try page.applyPageEdit(.init(action: .move, id: componentID, expectedRevision: page.boardItemRevision(for: componentID),
        expectedSubtreeRevision: page.pageSubtreeRevision(for: componentID), position: position))
    }) == nil { onMoved() }
  }

  private func remove(_ removal: PageEdit.Removal?) {
    _ = commit("Remove component") { page in
      try page.applyPageEdit(.init(action: .remove, id: componentID, expectedRevision: page.boardItemRevision(for: componentID),
        expectedSubtreeRevision: removal == .removeSubtree ? page.pageSubtreeRevision(for: componentID) : nil, removal: removal))
    }
  }
}

/// An embedded original, marked Original. It is the same library artifact
/// wherever it is embedded: an App keeps its input on the original, and
/// opening it shows the original in the tab. A missing original keeps its
/// place and reference.
struct MobilePageEmbed<Actions: View>: View {
  @Environment(\.wovenTheme) private var theme
  @Bindable var model: MobileModel
  let page: NoteDocument
  let componentID: String
  let assetID: String
  @ViewBuilder let actions: Actions

  private var asset: WorkspaceNoteRecord? { model.app.workspace.workspaceOverview?.notes.first { $0.id == assetID } }
  private var documents: DocumentsStore { model.app.documents }
  private var title: String {
    [asset.map { documents.title(of: $0) }, page.canvasPlacement(for: componentID).title].compactMap { $0 }.first { !$0.isEmpty }
      ?? "Original artifact"
  }

  var body: some View {
    let item = page.boardItems?[componentID]
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        if let task = item?.task { MobilePageTaskStatus(status: task.status) }
        if let asset { ArtifactKindIcon(kind: asset.kind, size: 18).frame(width: 24).foregroundStyle(WovenPalette.mutedForeground) }
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
          Label(asset.map { "Original · \($0.kind.displayName)" } ?? "Original", systemImage: "link")
            .font(.caption2).foregroundStyle(WovenPalette.mutedForeground)
        }
        Spacer(minLength: 4)
        Button { model.open(artifactID: assetID) } label: { LucideIcon(glyph: .externalLink, size: 17).frame(width: 44, height: 44) }
          .buttonStyle(.plain).disabled(asset == nil)
          .accessibilityLabel("Open original artifact").accessibilityIdentifier("page-open-original-\(componentID)")
        actions
      }
      if let asset {
        preview(asset, NoteDocument.decode(documents.content(of: asset)))
      } else {
        Text("The original artifact is unavailable. Its reference is retained.").font(.caption).foregroundStyle(WovenPalette.mutedForeground)
          .accessibilityIdentifier("page-original-unavailable-\(componentID)")
      }
      if let item, item.hasMobileSummary { MobilePageItemSummary(item: item) }
    }
    .padding(12)
    .background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
    .onAppear { if let asset { documents.open(asset) } }
  }

  @ViewBuilder private func preview(_ asset: WorkspaceNoteRecord, _ source: NoteDocument) -> some View {
    switch asset.kind {
    case .canvas:
      EmptyView()
    case .note:
      Button { model.open(artifactID: assetID) } label: {
        Text(source.plainText.isEmpty ? "Empty note" : source.plainText).font(.callout).lineLimit(8)
          .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
          .foregroundStyle(source.plainText.isEmpty ? WovenPalette.mutedForeground : WovenPalette.foreground)
      }.buttonStyle(.plain).accessibilityHint("Opens the original note")
    case .spreadsheet:
      MobilePageTable(table: source.spreadsheetTable, editable: false, maximumRows: 8)
    case .html:
      Group {
        if source.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          AppBuildPrompt(openChat: { model.select(.chat) })
        } else {
          PersistentArtifactView(document: .constant(source), linkedDataJSON: nil,
            savedState: documents.appState(noteID: assetID),
            currentState: { documents.appState(noteID: assetID) },
            saveState: { documents.enqueueArtifactInput(noteID: assetID, edit: $0, after: $1) },
            reportUnsaved: { documents.setArtifactInputsUnsaved(generation: $0, $1) })
        }
      }
      .frame(height: max(240, min(720, page.canvasPlacement(for: componentID).height)))
      .clipShape(RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
    }
  }
}

/// Existing artifact: any Note, Sheet or App in the library. A Page never holds another Page.
struct MobilePageAssetPicker: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: MobileModel
  let pageID: String
  let choose: (String) -> Void
  @State private var search = ""

  private var assets: [WorkspaceNoteRecord] {
    (model.app.workspace.workspaceOverview?.notes ?? [])
      .filter { $0.id != pageID && $0.kind != .canvas && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
      .sorted { ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id) }
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(assets) { asset in
          ArtifactRow(artifact: asset) { choose(asset.id); dismiss() }
            .listRowBackground(Color.clear)
        }
        if assets.isEmpty {
          Text("No other artifacts.").font(.callout).foregroundStyle(WovenPalette.mutedForeground)
            .listRowBackground(Color.clear)
        }
      }
      .listStyle(.plain)
      .searchable(text: $search, prompt: "Search artifacts")
      .mobilePageSurface()
      .navigationTitle("Embed an artifact").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
  }
}

extension BoardTaskAssignee {
  /// Who, where, and where they stand, as a phone's task line names them.
  var mobileSummary: String {
    let who = kind == .user ? "Me" : [name, place].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    let state: String? = switch state {
    case .assigned: kind == .user ? nil : "Not sent"
    case .sending: "Sending…"
    case .sent: "Sent"
    case .stopping: "Stopping…"
    case .stopped: "Stopped"
    case .failed: "Didn't send"
    }
    return [who, state].compactMap { $0 }.joined(separator: " · ")
  }
}

/// An image stored in the Page.
struct MobilePageImage: View {
  let image: PageImage?

  var body: some View {
    if let image, let bytes = image.bytes, let picture = UIImage(data: bytes) {
      Image(uiImage: picture).resizable().aspectRatio(contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(image.alt ?? "Image")
    } else {
      Label("This image can't be shown.", systemImage: "photo").font(.caption).foregroundStyle(WovenPalette.mutedForeground)
    }
  }
}
