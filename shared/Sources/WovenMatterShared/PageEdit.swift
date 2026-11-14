import Foundation

/// One focused Page mutation. Component edits carry the revision that was read, so
/// independent components do not contend on the document revision. Moving never changes
/// a component's revision, and removing one never deletes a linked original.
public struct PageEdit: Codable, Equatable, Sendable {
  /// `requirePage` changes nothing: it fails a batch of generic operations on any other asset.
  public enum Action: String, Codable, Sendable { case requirePage, setPurpose, add, update, move, remove, linkSession, unlinkSession }
  public enum Removal: String, Codable, Sendable { case promoteChildren, removeSubtree }

  public var action: Action
  public var id: String?
  /// Required to update or remove. Optional for `move`.
  public var expectedRevision: String?
  /// Required for `removeSubtree`. Optional when moving a section.
  public var expectedSubtreeRevision: String?
  /// `add` only. Defaults to `.asset` with an `assetID`, `.table` with a table block, else `.text`.
  public var kind: PageComponentKind?
  /// Rich or table content for `add` and `update`. Its ID must match `id` on update.
  public var block: NoteBlock?
  /// `title` labels sections and linked originals; `text` is the content of a text or task.
  public var patch: BoardItemPatch?
  /// `add` only. An existing component's link is never retargeted.
  public var assetID: String?
  /// `add` (nil means the end of the Page) and `move` (required).
  public var position: PagePosition?
  /// A non-empty section requires an explicit choice.
  public var removal: Removal?
  /// `setPurpose` only; an empty value clears the purpose.
  public var purpose: String?
  public var sessionID: String?

  public init(action: Action, id: String? = nil, expectedRevision: String? = nil, expectedSubtreeRevision: String? = nil,
              kind: PageComponentKind? = nil, block: NoteBlock? = nil, patch: BoardItemPatch? = nil, assetID: String? = nil,
              position: PagePosition? = nil, removal: Removal? = nil, purpose: String? = nil, sessionID: String? = nil) {
    self.action = action; self.id = id; self.expectedRevision = expectedRevision
    self.expectedSubtreeRevision = expectedSubtreeRevision; self.kind = kind; self.block = block; self.patch = patch
    self.assetID = assetID; self.position = position; self.removal = removal; self.purpose = purpose; self.sessionID = sessionID
  }
}

public extension NoteDocument {
  mutating func applyPageEdit(_ edit: PageEdit) throws {
    guard kind == .canvas else { throw NoteEditError.artifactKindMismatch }
    guard edit.action != .requirePage else { return }
    var document = materializedPage()
    if document.pageNodes == nil { document.pageNodes = [:] }
    switch edit.action {
    case .requirePage:
      break
    case .setPurpose:
      guard let purpose = edit.purpose, purpose.utf8.count <= Self.maximumBoardPurposeBytes else { throw NoteDocumentSafetyError.tooLarge }
      document.boardPurpose = purpose.isEmpty ? nil : purpose
    case .add:
      try document.addPageComponent(edit)
    case .update:
      try document.updatePageComponent(edit)
    case .move:
      try document.movePageComponent(edit)
    case .remove:
      try document.removePageComponent(edit)
    case .linkSession:
      let id = try document.requirePageComponent(edit, revisionRequired: false)
      guard let sessionID = edit.sessionID, !sessionID.isEmpty, sessionID.utf8.count <= 1024 else { throw NoteDocumentSafetyError.unsupportedFormat }
      var item = document.boardItems?[id] ?? BoardItem()
      if !item.sessions.contains(sessionID) {
        guard item.sessions.count < BoardItem.maximumSessions else { throw NoteEditError.boardSessionLimit(id) }
        item.sessions.append(sessionID)
        if document.boardItems == nil { document.boardItems = [:] }
        document.boardItems?[id] = item
      }
    case .unlinkSession:
      let id = try document.requirePageComponent(edit, revisionRequired: false)
      guard let sessionID = edit.sessionID else { throw NoteDocumentSafetyError.unsupportedFormat }
      document.boardItems?[id]?.sessions.removeAll { $0 == sessionID }
    }
    try document.validateEditableShape()
    self = document
  }
}

private extension NoteDocument {
  mutating func addPageComponent(_ edit: PageEdit) throws {
    guard let id = edit.id, !id.isEmpty, id.utf8.count <= 1024 else { throw NoteDocumentSafetyError.unsupportedFormat }
    guard !blocks.contains(where: { $0.id == id }) else { throw NoteEditError.boardItemExists(id) }
    let requested: PageComponentKind
    if let kind = edit.kind { requested = kind }
    else if edit.assetID != nil { requested = .asset }
    else if case .table? = edit.block { requested = .table }
    else { requested = .text }
    if requested != .asset, edit.assetID != nil { throw NoteEditError.boardConflictingPatch("Only an asset component links an original.") }
    let position = edit.position ?? PagePosition()
    let index = try pageInsertionIndex(position)
    let block: NoteBlock
    switch requested {
    case .asset:
      guard let assetID = edit.assetID, !assetID.isEmpty else { throw NoteDocumentSafetyError.unsupportedFormat }
      guard edit.patch?.text == nil, edit.block == nil else { throw NoteEditError.boardLinkedAssetText(id) }
      block = .richText(NoteRichTextBlock(id: id))
      var placement = CanvasCardPlacement(x: 0, y: 0, assetID: assetID)
      placement.title = edit.patch?.title.flatMap { $0.isEmpty ? nil : $0 }
      if canvas == nil { canvas = [:] }
      canvas?[id] = placement
    case .section:
      guard pageDepthOfChildren(parentID: position.parentID) < Self.maximumPageDepth else { throw NoteEditError.pageDepthExceeded(id) }
      block = try pageSectionBlock(id: id, edit: edit)
    case .table:
      guard edit.patch?.text == nil, edit.patch?.title == nil else { throw NoteEditError.boardItemNotText(id) }
      if let supplied = edit.block {
        guard case .table(var table) = supplied else { throw NoteDocumentSafetyError.unsupportedFormat }
        table.id = id
        block = .table(table)
      } else {
        var table = NoteTableBlock(rows: 3, columns: 3, headerRow: true)
        table.id = id
        block = .table(table)
      }
    case .text, .task:
      block = try pageTextBlock(id: id, edit: edit)
    }
    blocks.insert(block, at: index)
    if requested == .section {
      pageNodes?[id] = PageNode(parentID: position.parentID, isSection: true)
    } else if let parentID = position.parentID {
      pageNodes?[id] = PageNode(parentID: parentID)
    }
    var item = BoardItem()
    try applyPageMetadata(edit.patch, to: &item, id: id, isSection: requested == .section)
    if requested == .task, item.task == nil { item.task = BoardTask() }
    if boardItems == nil { boardItems = [:] }
    boardItems?[id] = item
  }

  mutating func updatePageComponent(_ edit: PageEdit) throws {
    let id = try requirePageComponent(edit, revisionRequired: true)
    guard edit.patch != nil || edit.block != nil else { throw NoteDocumentSafetyError.unsupportedFormat }
    guard let index = blocks.firstIndex(where: { $0.id == id }) else { throw NoteEditError.blockNotFound(id) }
    let isSection = pageNodes?[id]?.isSection == true, isAsset = canvas?[id]?.assetID != nil
    let patch = edit.patch
    if let supplied = edit.block {
      guard !isAsset else { throw NoteEditError.boardLinkedAssetText(id) }
      guard supplied.id == id else { throw NoteEditError.boardCardIDChanged(id) }
      if isSection, case .table = supplied { throw NoteDocumentSafetyError.unsupportedFormat }
      blocks[index] = supplied
    }
    if isAsset {
      guard patch?.text == nil else { throw NoteEditError.boardLinkedAssetText(id) }
      if let title = patch?.title { canvas?[id]?.title = title.isEmpty ? nil : title }
    } else if isSection {
      if patch?.text != nil, patch?.title != nil { throw NoteEditError.boardConflictingPatch("A section has one title. Supply title or text.") }
      if let text = patch?.title ?? patch?.text { try setPageText(text, at: index, id: id) }
    } else {
      if patch?.text != nil, patch?.title != nil { throw NoteEditError.boardConflictingPatch("Titles label sections and originals. Supply the text of this component.") }
      if let text = patch?.text ?? patch?.title { try setPageText(text, at: index, id: id) }
    }
    var item = boardItems?[id] ?? BoardItem()
    try applyPageMetadata(patch, to: &item, id: id, isSection: isSection)
    if boardItems == nil { boardItems = [:] }
    boardItems?[id] = item
  }

  mutating func movePageComponent(_ edit: PageEdit) throws {
    let id = try requirePageComponent(edit, revisionRequired: false)
    guard let position = edit.position else { throw NoteDocumentSafetyError.unsupportedFormat }
    if let expected = edit.expectedSubtreeRevision {
      let current = pageSubtreeRevision(for: id)
      guard expected == current else { throw NoteEditError.pageSubtreeConflict(id: id, currentRevision: current) }
    }
    guard let range = pageSubtreeRange(of: id) else { throw NoteEditError.blockNotFound(id) }
    let moving = Array(blocks[range])
    let movingIDs = Set(moving.map(\.id))
    if let parentID = position.parentID, movingIDs.contains(parentID) { throw NoteEditError.pageMoveIntoOwnSubtree(id) }
    if let afterID = position.afterID, movingIDs.contains(afterID) { throw NoteEditError.pagePositionInvalid(afterID) }
    // Deepest section in the subtree, counted from the moved component itself.
    let base = pageDepth(for: id)
    let nestedSections = moving.filter { pageNodes?[$0.id]?.isSection == true }
    if let deepest = nestedSections.map({ pageDepth(for: $0.id) - base }).max(),
       pageDepthOfChildren(parentID: position.parentID) + deepest >= Self.maximumPageDepth {
      throw NoteEditError.pageDepthExceeded(id)
    }
    // Compute against the blocks without the slice, so `afterID` cannot shift under it.
    var document = self
    document.blocks.removeSubrange(range)
    let index = try document.pageInsertionIndex(position)
    document.blocks.insert(contentsOf: moving, at: index)
    var node = document.pageNodes?[id] ?? PageNode()
    node.parentID = position.parentID
    document.pageNodes?[id] = node == PageNode() ? nil : node
    self = document
  }

  mutating func removePageComponent(_ edit: PageEdit) throws {
    guard let id = edit.id else { throw NoteDocumentSafetyError.unsupportedFormat }
    guard let range = pageSubtreeRange(of: id) else {
      // A caller holding a revision read this component, so it was removed since then.
      if edit.expectedRevision != nil || edit.expectedSubtreeRevision != nil {
        throw NoteEditError.boardItemConflict(id: id, currentRevision: "")
      }
      throw NoteEditError.blockNotFound(id)
    }
    if range.count > 1, edit.removal == nil { throw NoteEditError.pageSectionNotEmpty(id) }
    if edit.removal == .removeSubtree {
      guard let expected = edit.expectedSubtreeRevision else {
        throw WorkspaceToolError.revisionRequired("Removing this component and its contents requires subtreeRevision. Read the Page and pass its current value.")
      }
      let current = pageSubtreeRevision(for: id)
      guard expected == current else { throw NoteEditError.pageSubtreeConflict(id: id, currentRevision: current) }
      let removed = Set(blocks[range].map(\.id))
      blocks.removeSubrange(range)
      prunePageMetadata(removed)
      return
    }
    _ = try requirePageComponent(edit, revisionRequired: true)
    // Children take the section's own parent and stay exactly where they are.
    let parentID = pageNodes?[id]?.parentID
    for block in blocks[range].dropFirst() where pageNodes?[block.id]?.parentID == id {
      var node = pageNodes?[block.id] ?? PageNode()
      node.parentID = parentID
      pageNodes?[block.id] = node == PageNode() ? nil : node
    }
    blocks.remove(at: range.lowerBound)
    prunePageMetadata([id])
  }

  func requirePageComponent(_ edit: PageEdit, revisionRequired: Bool) throws -> String {
    guard let id = edit.id else { throw NoteDocumentSafetyError.unsupportedFormat }
    guard blocks.contains(where: { $0.id == id }) else {
      if edit.expectedRevision != nil { throw NoteEditError.boardItemConflict(id: id, currentRevision: "") }
      throw NoteEditError.blockNotFound(id)
    }
    if revisionRequired, edit.expectedRevision == nil {
      throw WorkspaceToolError.revisionRequired("This Page change requires componentRevision. Read the Page and pass the component's current revision.")
    }
    if let expected = edit.expectedRevision {
      let current = boardItemRevision(for: id)
      guard expected == current else { throw NoteEditError.boardItemConflict(id: id, currentRevision: current) }
    }
    return id
  }

  func applyPageMetadata(_ patch: BoardItemPatch?, to item: inout BoardItem, id: String, isSection: Bool) throws {
    if isSection, patch?.status != nil || patch?.assignee != nil || patch?.outcome != nil {
      throw NoteEditError.boardConflictingPatch("A section is not a task. Add a task component inside it.")
    }
    try applyBoardPatch(patch, to: &item)
  }

  func pageSectionBlock(id: String, edit: PageEdit) throws -> NoteBlock {
    if edit.patch?.text != nil, edit.patch?.title != nil { throw NoteEditError.boardConflictingPatch("A section has one title. Supply title or text.") }
    if let supplied = edit.block {
      guard case .richText(var text) = supplied else { throw NoteDocumentSafetyError.unsupportedFormat }
      text.id = id
      return .richText(text)
    }
    return .richText(NoteRichTextBlock(id: id, style: .heading2, text: edit.patch?.title ?? edit.patch?.text ?? ""))
  }

  func pageTextBlock(id: String, edit: PageEdit) throws -> NoteBlock {
    if edit.patch?.text != nil, edit.patch?.title != nil { throw NoteEditError.boardConflictingPatch("Titles label sections and originals. Supply the text of this component.") }
    if let supplied = edit.block {
      guard case .richText(var text) = supplied else { throw NoteDocumentSafetyError.unsupportedFormat }
      text.id = id
      return .richText(text)
    }
    return .richText(NoteRichTextBlock(id: id, text: edit.patch?.text ?? edit.patch?.title ?? ""))
  }

  mutating func setPageText(_ text: String, at index: Int, id: String) throws {
    guard case .richText(var block) = blocks[index] else { throw NoteEditError.boardItemNotText(id) }
    if block.plainText != text {
      block.runs = text.isEmpty ? [] : [NoteTextRun(text: text)]
      blocks[index] = .richText(block)
    }
  }

  /// A new section at this depth would hold children one level deeper.
  func pageDepthOfChildren(parentID: String?) -> Int {
    guard let parentID else { return 0 }
    return pageDepth(for: parentID) + 1
  }
}
