import SwiftUI
import WovenProtocol

struct MobilePageInsertion: Identifiable { let id = UUID(); let position: PagePosition }
struct MobilePageCellTarget: Identifiable, Equatable {
  let tableID: String
  let row: Int
  let column: Int
  var id: String { "\(tableID):\(row):\(column)" }
}

/// What a Page shows besides its document: collapsed sections and the sheet
/// open over it. Adding a component goes through the Page's own undo and save.
@MainActor @Observable final class PageEditorState {
  var collapsed: Set<String> = []
  var insertion: MobilePageInsertion?
  var cell: MobilePageCellTarget?
  /// A section just added, whose title takes the keyboard.
  var sectionToFocus: String?

  func add(_ kind: PageComponentKind, assetID: String? = nil, at position: PagePosition, in session: ArtifactTextSession) {
    let id = UUID().uuidString.lowercased()
    guard session.pageChange("Add component", {
      try $0.applyPageEdit(.init(action: .add, id: id, kind: kind, assetID: assetID, position: position))
    }) == nil else { return }
    session.selectedBlockID = id
    reveal(id, in: session.document?.materializedPage())
    switch kind {
    case .text, .task: session.controller.focus(.init(blockID: id, location: 0), typingRun: nil)
    case .section: sectionToFocus = id
    default: break
    }
  }

  /// Expands every section that encloses a component the user just reached.
  func reveal(_ id: String, in page: NoteDocument?) {
    guard let page else { return }
    var parent = page.pageParentID(for: id)
    while let current = parent { collapsed.remove(current); parent = page.pageParentID(for: current) }
  }
}

/// The Page's plus menu: Task, Section, Table, Existing artifact, then a new
/// Note, Sheet or App. A Page never holds another Page; typing adds text.
struct PageAddActions: View {
  @Bindable var model: MobileModel
  let session: ArtifactTextSession
  let state: PageEditorState
  let folderID: String?
  let position: PagePosition

  var body: some View {
    Button("Task", systemImage: "checkmark.circle") { state.add(.task, at: position, in: session) }
    Button("Section", systemImage: "list.bullet.indent") { state.add(.section, at: position, in: session) }
    Button("Table", systemImage: "tablecells") { state.add(.table, at: position, in: session) }
    Divider()
    Button("Existing artifact", systemImage: "link") { state.insertion = .init(position: position) }
    ForEach(NoteArtifactKind.allCases.filter { $0 != .canvas }, id: \.self) { kind in
      Button("New \(kind.displayName)") {
        Task {
          guard let assetID = await model.app.workspace.createNote(folderID: folderID, kind: kind) else { return }
          state.add(.asset, assetID: assetID, at: position, in: session)
        }
      }
    }
  }
}

/// A Page as one flowing document: text in the Notes editor, sections with quiet
/// indentation and disclosure, tasks, tables, images and embedded originals.
/// Every change goes through shared Page edits and the Page's own undo and save.
struct MobilePageEditor: View {
  @Environment(\.wovenTheme) private var theme
  @Bindable var model: MobileModel
  let record: WorkspaceNoteRecord
  let session: ArtifactTextSession
  let state: PageEditorState
  let document: NoteDocument
  @FocusState private var focusedSection: String?
  private var editable: Bool { session.editable }

  var body: some View {
    // The layout and the generation come from one read of the session, so a
    // paragraph never pairs a stale block with a newer generation.
    let layout = MobilePageLayout(page: session.document ?? document, placeholders: session.placeholders)
    let generation = session.generation
    let page = layout.page
    VStack(spacing: 0) {
      let review = page.blocks.filter { page.boardItems?[$0.id]?.review == .needed }
      if !review.isEmpty {
        HStack {
          Spacer()
          Menu {
            ForEach(review, id: \.id) { block in
              Button(block.plainText.isEmpty ? "Review component" : String(block.plainText.prefix(80))) {
                session.selectedBlockID = block.id; state.reveal(block.id, in: page)
              }
            }
          } label: { Label("\(review.count) to review", systemImage: "tray").font(.caption).frame(minHeight: 44) }
            .foregroundStyle(WovenPalette.mutedForeground).accessibilityIdentifier("page-review")
        }.padding(.horizontal, 20)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          if !editable { Text("Page · read only · linked data").font(.caption).foregroundStyle(WovenPalette.mutedForeground) }
          ForEach(layout.rows.filter { visible($0, in: page) }) { row in
            rowView(row, layout: layout, generation: generation).padding(.leading, CGFloat(row.depth) * 16)
          }
          // The rest of the Page is part of its last line: tapping puts the cursor there.
          Color.clear.frame(maxWidth: .infinity, minHeight: 160).contentShape(Rectangle())
            .onTapGesture { session.focusEnd() }
        }.padding(.horizontal, 20).padding(.top, 4)
      }
      .scrollDismissesKeyboard(.interactively)
    }
    .onChange(of: state.sectionToFocus) { _, id in
      guard let id else { return }
      DispatchQueue.main.async { focusedSection = id; state.sectionToFocus = nil }
    }
    .sheet(item: Binding(get: { state.insertion }, set: { state.insertion = $0 })) { insertion in
      MobilePageAssetPicker(model: model, pageID: record.id) { assetID in
        state.add(.asset, assetID: assetID, at: insertion.position, in: session)
      }
      .sheetTheme(theme)
    }
    .sheet(item: Binding(get: { state.cell }, set: { state.cell = $0 })) { target in
      if case .table(let table)? = layout.blocks[target.tableID] {
        MobilePageCellEditor(table: table, target: target) { action, transform in
          session.pageChange(action) { page in
            guard let index = page.blocks.firstIndex(where: { $0.id == target.tableID }), case .table(let current) = page.blocks[index] else {
              throw RichDocumentEditing.Failure.missingBlock
            }
            try page.applyPageEdit(.init(action: .update, id: target.tableID, expectedRevision: page.boardItemRevision(for: target.tableID),
              block: .table(try transform(current))))
          }
        }
        .sheetTheme(theme)
      }
    }
  }

  @ViewBuilder private func rowView(_ row: MobilePageRow, layout: MobilePageLayout, generation: Int) -> some View {
    let page = layout.page
    switch row.kind {
    case .text(let placeholder):
      let block: NoteRichTextBlock = if case .richText(let text)? = layout.blocks[row.id] { text } else { .init(id: row.id) }
      let item = placeholder ? nil : page.boardItems?[row.id]
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .top, spacing: 4) {
          if let task = item?.task { MobilePageTaskStatus(status: task.status) }
          ArtifactTextBlock(session: session, block: block, number: layout.listNumbers[row.id], generation: generation,
                            identity: "page:\(record.id):\(block.id)")
            .accessibilityIdentifier("page-text-\(block.id)")
          if let task = item?.task, task.status != .todo {
            Text(task.status.displayName).font(.caption).foregroundStyle(WovenPalette.mutedForeground)
              .padding(.top, 8).fixedSize()
          }
          if editable { if placeholder { Color.clear.frame(width: 32, height: 1) } else { componentMenu(row.id, in: page) } }
        }
        if let item, item.hasMobileSummary {
          MobilePageItemSummary(item: item).padding(.leading, item.task == nil ? 0 : 36)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(placeholder ? "page-place-\(row.id)" : "page-component-\(row.id)")
    case .table:
      if case .table(let table)? = layout.blocks[row.id] {
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .top, spacing: 4) {
            MobilePageTable(table: table, editable: editable) { r, c in
              session.selectedBlockID = row.id; state.cell = .init(tableID: row.id, row: r, column: c)
            }
            if editable { componentMenu(row.id, in: page) }
          }
          if let item = page.boardItems?[row.id], item.hasMobileSummary { MobilePageItemSummary(item: item) }
        }.padding(.vertical, 4)
          .accessibilityElement(children: .contain).accessibilityIdentifier("page-component-\(row.id)")
      }
    case .section:
      let isCollapsed = state.collapsed.contains(row.id)
      HStack(alignment: .center, spacing: 4) {
        Button {
          if isCollapsed { state.collapsed.remove(row.id) } else { state.collapsed.insert(row.id) }
        } label: {
          LucideIcon(glyph: .chevronDown, size: 14).rotationEffect(.degrees(isCollapsed ? -90 : 0)).frame(width: 28, height: 44)
        }.buttonStyle(.plain).foregroundStyle(WovenPalette.mutedForeground)
          .accessibilityLabel(isCollapsed ? "Expand section" : "Collapse section").accessibilityIdentifier("page-section-toggle-\(row.id)")
        TextField("Section", text: Binding(get: { layout.blocks[row.id]?.plainText ?? "" }, set: { text in
          _ = session.pageChange("Section title") { page in
            try page.applyPageEdit(.init(action: .update, id: row.id, expectedRevision: page.boardItemRevision(for: row.id), patch: .init(title: text)))
          }
        }), axis: .vertical)
          .font(.title3.weight(.semibold)).lineLimit(1...3).disabled(!editable)
          .focused($focusedSection, equals: row.id)
          .accessibilityIdentifier("page-section-title-\(row.id)")
        if editable {
          Menu {
            PageAddActions(model: model, session: session, state: state, folderID: record.folderID, position: .init(parentID: row.id))
          } label: {
            LucideIcon(glyph: .plus, size: 16).frame(width: 32, height: 44)
          }.foregroundStyle(WovenPalette.mutedForeground)
            .accessibilityLabel("Add inside section").accessibilityIdentifier("page-add-inside-\(row.id)")
          componentMenu(row.id, in: page)
        }
      }.padding(.top, 10)
        .simultaneousGesture(TapGesture().onEnded { session.selectedBlockID = row.id })
        .accessibilityElement(children: .contain).accessibilityIdentifier("page-component-\(row.id)")
    case .image:
      HStack(alignment: .top, spacing: 4) {
        MobilePageImage(image: page.canvas?[row.id]?.image)
        if editable { componentMenu(row.id, in: page) }
      }.padding(.vertical, 6)
        .simultaneousGesture(TapGesture().onEnded { session.selectedBlockID = row.id })
        .accessibilityElement(children: .contain).accessibilityIdentifier("page-component-\(row.id)")
    case .asset(let assetID):
      MobilePageEmbed(model: model, page: page, componentID: row.id, assetID: assetID) {
        if editable { componentMenu(row.id, in: page) }
      }
      .padding(.vertical, 6)
      .simultaneousGesture(TapGesture().onEnded { session.selectedBlockID = row.id })
      .accessibilityElement(children: .contain).accessibilityIdentifier("page-component-\(row.id)")
    }
  }

  private func componentMenu(_ id: String, in page: NoteDocument) -> some View {
    MobilePageComponentMenu(page: page, componentID: id, commit: session.pageChange, onMoved: { state.reveal(id, in: page) })
  }

  private func visible(_ row: MobilePageRow, in page: NoteDocument) -> Bool {
    var parent = row.parentID
    while let id = parent {
      if state.collapsed.contains(id) { return false }
      parent = page.pageParentID(for: id)
    }
    return true
  }
}
