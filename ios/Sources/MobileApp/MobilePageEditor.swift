import SwiftUI
import LibraryClient
import WovenMatterShared

struct MobilePageTarget: Identifiable, Equatable { let id: String }
struct MobilePageInsertion: Identifiable { let id = UUID(); let position: PagePosition }
struct MobilePageCellTarget: Identifiable, Equatable {
  let tableID: String
  let row: Int
  let column: Int
  var id: String { "\(tableID):\(row):\(column)" }
}

/// A Page as one flowing document: text in the Notes editor, sections with quiet
/// indentation and disclosure, tables, and embedded originals. Every change goes
/// through shared Page edits and the note's own undo and save path.
struct MobilePageEditor<TextRow: View>: View {
  @Environment(\.wovenTheme) private var theme
  @Bindable var model: MobileModel
  let note: LibraryNote
  let layout: MobilePageLayout
  let editable: Bool
  @Binding var selectedID: String?
  /// Applies one change through the editor's undo and save, returning the refusal if any.
  let commit: (String, (inout NoteDocument) throws -> Void) -> String?
  /// Puts the caret in a text component once it renders.
  let focusText: (String) -> Void
  @ViewBuilder let textRow: (MobilePageRow, NoteRichTextBlock, Int?) -> TextRow
  @State private var collapsed: Set<String> = []
  @State private var details: MobilePageTarget?
  @State private var insertion: MobilePageInsertion?
  @State private var cell: MobilePageCellTarget?
  @FocusState private var focusedSection: String?
  private var page: NoteDocument { layout.page }

  var body: some View {
    VStack(spacing: 0) {
      if editable {
        HStack(spacing: 8) {
          Menu {
            addActions(MobilePageEditing.insertionPosition(after: selectedID, in: layout))
          } label: {
            Label("Add component", glyph: .plus).font(.subheadline.weight(.medium)).frame(minHeight: 44)
          }.accessibilityIdentifier("page-add-component")
          Spacer(minLength: 4)
          let review = page.blocks.filter { page.boardItems?[$0.id]?.review == .needed }
          if !review.isEmpty {
            Menu {
              ForEach(review, id: \.id) { block in
                Button(block.plainText.isEmpty ? "Review component" : String(block.plainText.prefix(80))) {
                  selectedID = block.id; reveal(block.id); details = .init(id: block.id)
                }
              }
            } label: { Label("\(review.count) to review", systemImage: "tray").font(.caption).frame(minHeight: 44) }
              .foregroundStyle(WovenPalette.mutedForeground).accessibilityIdentifier("page-review")
          }
        }.keepsKeyboard().padding(.horizontal, 20)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          if !editable { Text("Page · read only · linked data").font(.caption).foregroundStyle(WovenPalette.mutedForeground) }
          TextField("Add a description…", text: Binding(get: { page.boardPurpose ?? "" }, set: { value in
            _ = commit("Description") { try $0.applyPageEdit(.init(action: .setPurpose, purpose: value)) }
          }), axis: .vertical)
            .font(.callout).foregroundStyle(WovenPalette.mutedForeground).lineLimit(1...4)
            .disabled(!editable).accessibilityIdentifier("page-purpose").padding(.bottom, 6)
          ForEach(layout.rows.filter(visible)) { row in
            rowView(row).padding(.leading, CGFloat(row.depth) * 16)
          }
          legacyConnections
        }.padding(.horizontal, 20).padding(.bottom, 24)
      }.scrollDismissesKeyboard(.interactively).scrollIndicators(.never)
    }
    .sheet(item: $details) { target in
      MobilePageComponentDetails(model: model, note: note, page: page, componentID: target.id, commit: commit)
        .environment(\.wovenTheme, theme)
    }
    .sheet(item: $insertion) { insertion in
      MobilePageAssetPicker(model: model, pageID: note.id) { assetID in
        add(.asset, assetID: assetID, at: insertion.position)
      }.environment(\.wovenTheme, theme)
    }
    .sheet(item: $cell) { target in
      if case .table(let table)? = layout.blocks[target.tableID] {
        MobilePageCellEditor(table: table, target: target) { action, transform in
          commit(action) { page in
            guard let index = page.blocks.firstIndex(where: { $0.id == target.tableID }), case .table(let current) = page.blocks[index] else {
              throw MobilePageDispatchError.unavailable
            }
            try page.applyPageEdit(.init(action: .update, id: target.tableID, expectedRevision: page.boardItemRevision(for: target.tableID),
              block: .table(try transform(current))))
          }
        }.environment(\.wovenTheme, theme)
      }
    }
  }

  @ViewBuilder private func rowView(_ row: MobilePageRow) -> some View {
    switch row.kind {
    case .text(let placeholder):
      let block: NoteRichTextBlock = if case .richText(let text)? = layout.blocks[row.id] { text } else { .init(id: row.id) }
      let item = placeholder ? nil : page.boardItems?[row.id]
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .top, spacing: 4) {
          if let task = item?.task {
            MobilePageTaskToggle(componentID: row.id, label: block.plainText, done: task.status == .done, editable: editable) { toggleTask(row.id) }
          }
          textRow(row, block, layout.listNumbers[row.id])
          if editable { if placeholder { Color.clear.frame(width: 32, height: 1) } else { componentMenu(row.id) } }
        }
        if let item, item.hasMobileSummary {
          MobilePageItemSummary(item: item, showsPlainStatus: false).padding(.leading, item.task == nil ? 0 : 36)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(placeholder ? "page-place-\(row.id)" : "page-component-\(row.id)")
    case .table:
      if case .table(let table)? = layout.blocks[row.id] {
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .top, spacing: 4) {
            MobilePageTable(table: table, editable: editable) { r, c in selectedID = row.id; cell = .init(tableID: row.id, row: r, column: c) }
            if editable { componentMenu(row.id) }
          }
          if let item = page.boardItems?[row.id], item.hasMobileSummary { MobilePageItemSummary(item: item, showsPlainStatus: true) }
        }.padding(.vertical, 4)
          .accessibilityElement(children: .contain).accessibilityIdentifier("page-component-\(row.id)")
      }
    case .section:
      let isCollapsed = collapsed.contains(row.id)
      HStack(alignment: .center, spacing: 4) {
        Button {
          if isCollapsed { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
        } label: {
          LucideIcon(glyph: .chevronDown, size: 14).rotationEffect(.degrees(isCollapsed ? -90 : 0)).frame(width: 28, height: 44)
        }.buttonStyle(.plain).foregroundStyle(WovenPalette.mutedForeground)
          .accessibilityLabel(isCollapsed ? "Expand section" : "Collapse section").accessibilityIdentifier("page-section-toggle-\(row.id)")
        TextField("Section", text: Binding(get: { layout.blocks[row.id]?.plainText ?? "" }, set: { text in
          _ = commit("Section title") { page in
            try page.applyPageEdit(.init(action: .update, id: row.id, expectedRevision: page.boardItemRevision(for: row.id), patch: .init(title: text)))
          }
        }), axis: .vertical)
          .font(.title3.weight(.semibold)).lineLimit(1...3).disabled(!editable)
          .focused($focusedSection, equals: row.id)
          .accessibilityIdentifier("page-section-title-\(row.id)")
        if editable {
          Menu { addActions(.init(parentID: row.id)) } label: {
            LucideIcon(glyph: .plus, size: 16).frame(width: 32, height: 44)
          }.foregroundStyle(WovenPalette.mutedForeground)
            .accessibilityLabel("Add inside section").accessibilityIdentifier("page-add-inside-\(row.id)")
          componentMenu(row.id)
        }
      }.padding(.top, 10)
        .simultaneousGesture(TapGesture().onEnded { selectedID = row.id })
        .accessibilityElement(children: .contain).accessibilityIdentifier("page-component-\(row.id)")
    case .asset(let assetID):
      MobilePageEmbed(model: model, page: page, componentID: row.id, assetID: assetID, editable: editable,
        onToggleTask: { toggleTask(row.id) }) { componentMenu(row.id) }
        .padding(.vertical, 6)
        .simultaneousGesture(TapGesture().onEnded { selectedID = row.id })
        .accessibilityElement(children: .contain).accessibilityIdentifier("page-component-\(row.id)")
    }
  }

  private func componentMenu(_ id: String) -> some View {
    MobilePageComponentMenu(page: page, componentID: id, commit: commit,
      onDetails: { selectedID = id; details = .init(id: id) },
      onMoved: { reveal(id) })
  }

  @ViewBuilder private func addActions(_ position: PagePosition) -> some View {
    Button("Text", glyph: .fileText) { add(.text, at: position) }
    Button("Task", systemImage: "checkmark.circle") { add(.task, at: position) }
    Button("Section", systemImage: "list.bullet.indent") { add(.section, at: position) }
    Button("Table", systemImage: "tablecells") { add(.table, at: position) }
    Divider()
    Button("Existing asset…", systemImage: "link") { insertion = .init(position: position) }
    ForEach(NoteArtifactKind.allCases, id: \.self) { kind in
      Button("New \(kind.displayName)") {
        Task {
          guard let assetID = await model.createAsset(kind, folderID: note.folderID) else { return }
          add(.asset, assetID: assetID, at: position)
        }
      }
    }
  }

  private func add(_ kind: PageComponentKind, assetID: String? = nil, at position: PagePosition) {
    let id = UUID().uuidString.lowercased()
    guard commit("Add component", { try $0.applyPageEdit(.init(action: .add, id: id, kind: kind, assetID: assetID, position: position)) }) == nil else { return }
    selectedID = id
    reveal(id)
    switch kind {
    case .text, .task: focusText(id)
    case .section: DispatchQueue.main.async { focusedSection = id }
    default: break
    }
  }

  private func toggleTask(_ id: String) {
    guard let status = page.boardItems?[id]?.task?.status else { return }
    _ = commit(status == .done ? "Reopen task" : "Complete task") { page in
      try page.applyPageEdit(.init(action: .update, id: id, expectedRevision: page.boardItemRevision(for: id),
        patch: .init(status: status == .done ? .todo : .done)))
    }
  }

  /// Expands every section that encloses a component the user just reached.
  private func reveal(_ id: String) {
    var parent = page.pageParentID(for: id)
    while let current = parent { collapsed.remove(current); parent = page.pageParentID(for: current) }
  }

  private func visible(_ row: MobilePageRow) -> Bool {
    var parent = row.parentID
    while let id = parent {
      if collapsed.contains(id) { return false }
      parent = page.pageParentID(for: id)
    }
    return true
  }

  @ViewBuilder private var legacyConnections: some View {
    let connections = page.pageLegacyConnections
    if !connections.isEmpty {
      DisclosureGroup("Retained connections") {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(connections) { connection in
            Text("\(connection.fromText.isEmpty ? "Component" : connection.fromText) → \(connection.toText.isEmpty ? "Component" : connection.toText)\(connection.label.isEmpty ? "" : ": " + connection.label)")
              .font(.caption).foregroundStyle(WovenPalette.mutedForeground).textSelection(.enabled)
          }
        }
      }.font(.subheadline).padding(.top, 16)
    }
  }
}

/// The New Asset choices, in the Mac's order and wording.
struct MobileNewAssetItems: View {
  let create: (NoteArtifactKind) -> Void
  var body: some View {
    Button("Note", glyph: .fileText) { create(.note) }.accessibilityIdentifier("action-new-note")
    Button("Sheet", systemImage: "tablecells") { create(.spreadsheet) }.accessibilityIdentifier("action-new-sheet")
    Button("Artifact", systemImage: "chevron.left.forwardslash.chevron.right") { create(.html) }.accessibilityIdentifier("action-new-artifact")
    Button("Page", glyph: .panelsTopLeft) { create(.canvas) }.accessibilityIdentifier("action-new-page")
  }
}
