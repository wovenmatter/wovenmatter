import SwiftUI
import LibraryClient
import WovenMatterShared

/// A task's checkbox. VoiceOver reads it as a toggle named by the task's text.
struct MobilePageTaskToggle: View {
  let componentID: String
  let label: String
  let done: Bool
  let editable: Bool
  let toggle: () -> Void
  var body: some View {
    Button(action: toggle) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 20, weight: .regular))
        .foregroundStyle(done ? WovenPalette.primary : WovenPalette.mutedForeground)
        .frame(width: 32, height: 44)
    }.buttonStyle(.plain).disabled(!editable).keepsKeyboard()
      .accessibilityRepresentation {
        Toggle(label.isEmpty ? "Task" : label, isOn: Binding(get: { done }, set: { _ in toggle() })).disabled(!editable)
      }
      .accessibilityIdentifier("page-task-toggle-\(componentID)")
  }
}

/// Task state, assignee, outcome, review and change summary, shown under a component.
struct MobilePageItemSummary: View {
  let item: BoardItem
  /// A component without a checkbox also names to do and done.
  let showsPlainStatus: Bool
  private var statusLabel: String? {
    guard let status = item.task?.status else { return nil }
    return [.todo, .done].contains(status) && !showsPlainStatus ? nil : status.mobileTitle
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 10) {
        if let statusLabel { Text(statusLabel) }
        if let assignee = item.task?.assignee, !assignee.isEmpty { Label(assignee, glyph: .userRound) }
        if item.role == .instructions { Label("Reference instructions", systemImage: "book.closed") }
        if item.review == .needed { Label("Needs review", systemImage: "tray") }
      }.foregroundStyle(WovenPalette.mutedForeground)
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
                .background(rowIndex < table.headerRowCount ? theme.palette.themeWhisper : .clear)
                .overlay(Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
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
  let apply: (String, (NoteTableBlock) throws -> NoteTableBlock) -> String?
  @State private var text: String
  @State private var problem: String?
  init(table: NoteTableBlock, target: MobilePageCellTarget, apply: @escaping (String, (NoteTableBlock) throws -> NoteTableBlock) -> String?) {
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
          Button("Add row below") { run("Add row") { $0.insertingRow(after: target.row) } }.accessibilityIdentifier("page-cell-add-row")
          Button("Remove row", role: .destructive) { run("Remove row") { $0.removingRow(target.row) } }
            .disabled(table.rows.count <= 1).accessibilityIdentifier("page-cell-remove-row")
        }
        Section("Column \(target.column + 1)") {
          Button("Add column after") { run("Add column") { $0.insertingColumn(after: target.column) } }.accessibilityIdentifier("page-cell-add-column")
          Button("Remove column", role: .destructive) { run("Remove column") { $0.removingColumn(target.column) } }
            .disabled(table.columns.count <= 1).accessibilityIdentifier("page-cell-remove-column")
        }
      }.scrollIndicators(.never)
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
  let onDetails: () -> Void
  let onMoved: () -> Void
  var body: some View {
    let kind = page.pageComponentKind(for: componentID)
    let item = page.boardItems?[componentID]
    let siblings = page.pageChildren(of: page.pageParentID(for: componentID))
    let index = siblings.firstIndex(of: componentID) ?? 0
    Menu {
      Button("Component details") { onDetails() }.accessibilityIdentifier("page-details-\(componentID)")
      if let task = item?.task {
        Button(task.status == .done ? "Reopen task" : "Complete task") {
          update(task.status == .done ? "Reopen task" : "Complete task", .init(status: task.status == .done ? .todo : .done))
        }
      }
      if kind != .section {
        Button(item?.task == nil ? "Turn into task" : "Remove task state") {
          update("Task", item?.task == nil ? .init(status: .todo) : .init(clearTask: true))
        }
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
      Menu("Move into section") {
        let subtree = Set(page.pageSubtreeIDs(of: componentID))
        ForEach(page.blocks.filter { page.pageNodes?[$0.id]?.isSection == true && !subtree.contains($0.id) }, id: \.id) { block in
          Button(block.plainText.isEmpty ? "Untitled section" : block.plainText) { move(.init(parentID: block.id)) }
        }
        Button("Page root") { move(.init()) }
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
    }.accessibilityLabel("Component actions").accessibilityIdentifier("page-component-actions-\(componentID)")
  }
  private func update(_ action: String, _ patch: BoardItemPatch) {
    _ = commit(action) { page in
      try page.applyPageEdit(.init(action: .update, id: componentID, expectedRevision: page.boardItemRevision(for: componentID), patch: patch))
    }
  }
  private func replaceTable(_ action: String, _ transform: @escaping (NoteTableBlock) -> NoteTableBlock) {
    _ = commit(action) { page in
      guard case .table(let table)? = page.blocks.first(where: { $0.id == componentID }) else { throw MobilePageDispatchError.unavailable }
      try page.applyPageEdit(.init(action: .update, id: componentID, expectedRevision: page.boardItemRevision(for: componentID), block: .table(transform(table))))
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

/// An embedded original, previewed as its own pane shows it. Opening it uses
/// the normal pane; a missing original keeps its place and reference.
struct MobilePageEmbed<Actions: View>: View {
  @Environment(\.wovenTheme) private var theme
  @Bindable var model: MobileModel
  let page: NoteDocument
  let componentID: String
  let assetID: String
  let editable: Bool
  let onToggleTask: () -> Void
  @ViewBuilder let actions: Actions
  private var asset: LibraryNote? { model.state.deletedNotes.contains(assetID) ? nil : model.state.notes[assetID] }
  private var cached: Bool { !model.state.uncachedNoteIDs.contains(assetID) }
  private var title: String {
    [asset?.title, page.canvasPlacement(for: componentID).title].compactMap { $0 }.first { !$0.isEmpty } ?? "Original asset"
  }
  var body: some View {
    let item = page.boardItems?[componentID]
    let source = asset.flatMap { cached ? RichDocumentEditing.document($0.content) : nil }
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        if let task = item?.task {
          MobilePageTaskToggle(componentID: componentID, label: title, done: task.status == .done, editable: editable, toggle: onToggleTask)
        }
        if let asset { MobileNoteIcon(content: asset.content).frame(width: 24).foregroundStyle(WovenPalette.mutedForeground) }
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
          Label(source.map { "Original · \($0.kind.displayName)" } ?? "Original", systemImage: "link")
            .font(.caption2).foregroundStyle(WovenPalette.mutedForeground)
        }
        Spacer(minLength: 4)
        Button { open() } label: { LucideIcon(glyph: .externalLink, size: 17).frame(width: 36, height: 44) }
          .buttonStyle(.plain).disabled(asset == nil)
          .accessibilityLabel("Open original asset").accessibilityIdentifier("page-open-original-\(componentID)")
        actions
      }
      if let asset {
        if !cached {
          Text("Not saved on this device yet. Open it to download the original.").font(.caption).foregroundStyle(WovenPalette.mutedForeground)
        } else if let source { preview(asset, source) }
      } else {
        Text("The original asset is unavailable. Its reference is retained.").font(.caption).foregroundStyle(WovenPalette.mutedForeground)
          .accessibilityIdentifier("page-original-unavailable-\(componentID)")
      }
      if let item, item.hasMobileSummary || item.task?.status == .doing { MobilePageItemSummary(item: item, showsPlainStatus: false) }
    }
    .padding(12)
    .background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
  }
  @ViewBuilder private func preview(_ asset: LibraryNote, _ source: NoteDocument) -> some View {
    switch source.kind {
    case .canvas:
      Button { open() } label: {
        Label("Open nested Page · \(source.materializedPage().blocks.count) components", glyph: .panelsTopLeft)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      }.buttonStyle(WovenQuietButtonStyle())
    case .note:
      Button { open() } label: {
        Text(source.plainText.isEmpty ? "Empty note" : source.plainText).font(.callout).lineLimit(8)
          .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
          .foregroundStyle(source.plainText.isEmpty ? WovenPalette.mutedForeground : WovenPalette.foreground)
      }.buttonStyle(.plain).accessibilityHint("Opens the original note")
    case .spreadsheet:
      if source.databaseLink != nil { LinkedArtifactPreview(model: model, note: asset, tableID: nil, html: nil) }
      else if case .table(let table)? = source.blocks.first(where: { if case .table = $0 { true } else { false } }) {
        MobilePageTable(table: table, editable: false, maximumRows: 8)
      }
    case .html:
      Group {
        if source.databaseLink != nil { LinkedArtifactPreview(model: model, note: asset, tableID: nil, html: source.html) }
        else { SafeHTMLPreview(html: source.html, state: source.artifactStateSnapshot) }
      }.frame(height: max(240, min(720, page.canvasPlacement(for: componentID).height)))
        .clipShape(RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
    }
  }
  private func open() { Task { await model.openNote(assetID) } }
}

/// Existing asset: any library asset on this device except the Page itself.
struct MobilePageAssetPicker: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: MobileModel
  let pageID: String
  let choose: (String) -> Void
  @State private var search = ""
  private var assets: [LibraryNote] {
    model.notes.filter { $0.id != pageID && !model.state.deletedNotes.contains($0.id)
      && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 8) {
        WovenSearchField(text: $search, prompt: "Search assets").padding(.horizontal, 20)
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(assets) { asset in
              WorkspaceRow(icon: MobileNoteIcon(content: asset.content), title: asset.title.isEmpty ? "Untitled asset" : asset.title,
                detail: RichDocumentEditing.document(asset.content)?.kind.displayName) {
                choose(asset.id); dismiss()
              }.accessibilityIdentifier("page-asset-\(asset.id)")
            }
            if assets.isEmpty {
              Text("No other assets on this device.").font(.callout).foregroundStyle(WovenPalette.mutedForeground).padding(20)
            }
          }.padding(.horizontal, 12)
        }.scrollIndicators(.never)
      }.padding(.top, 8)
        .navigationTitle("Embed an original asset").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
  }
}
