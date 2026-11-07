import CryptoKit
import Foundation

public struct PageMerge: Equatable, Sendable {
  public var document: NoteDocument
  /// Components both sides changed differently. The remote version stays under each ID.
  public var conflictedIDs: [String]
  /// New components holding the local version of each conflict, so neither version is lost.
  public var conflictCopyIDs: [String]

  public init(document: NoteDocument, conflictedIDs: [String] = [], conflictCopyIDs: [String] = []) {
    self.document = document; self.conflictedIDs = conflictedIDs; self.conflictCopyIDs = conflictCopyIDs
  }
}

public extension NoteDocument {
  /// Three-way merge of one Page, for autosave landing after another writer. Disjoint
  /// components combine. When both sides change one component, the remote keeps its ID and
  /// the local version becomes a visible neighbor. Deleting what the other side edited keeps
  /// the edit. Throws only when the merged Page could not be stored, so a caller can fall
  /// back to draft recovery with nothing changed.
  static func mergePage(base: NoteDocument, local: NoteDocument, remote: NoteDocument) throws -> PageMerge {
    guard base.kind == .canvas, local.kind == .canvas, remote.kind == .canvas else { throw NoteEditError.artifactKindMismatch }
    let remaps = pageConflictComponentRemaps(submitted: base, stored: remote)
      .filter { mapping in !local.blocks.contains(where: { $0.id == mapping.value }) }
    var merger = PageMerger(base: base.remappingPageComponents(remaps), local: local.remappingPageComponents(remaps), remote: remote.materializedPage())
    return try merger.merge()
  }

  /// A chained autosave may still use the submitted identity after its previous
  /// save kept that version as a conflict copy. Continue on that exact copy;
  /// matching text alone is ambiguous and could select an unrelated component.
  static func pageConflictComponentRemaps(submitted: NoteDocument, stored: NoteDocument) -> [String: String] {
    let previous = PageMerger.Snapshot(submitted.materializedPage())
    let current = PageMerger.Snapshot(stored.materializedPage())
    var result: [String: String] = [:]
    for block in previous.document.blocks where !previous.isSection(block.id) {
      guard let content = previous.content(block.id), current.has(block.id),
            current.content(block.id) != content else { continue }
      let copyID = "conflict-" + PageMerger.hash(block.id, content)
      if current.has(copyID), !previous.has(copyID) { result[block.id] = copyID }
    }
    return result
  }

  private func remappingPageComponents(_ mapping: [String: String]) -> NoteDocument {
    var page = materializedPage()
    guard !mapping.isEmpty else { return page }
    page.blocks = page.blocks.map { block in mapping[block.id].map { PageMerger.copyBlock(block, id: $0) } ?? block }
    func remap<T>(_ values: [String: T]?) -> [String: T]? {
      values.map { Dictionary($0.map { (mapping[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { first, _ in first }) }
    }
    page.boardItems = remap(page.boardItems)
    page.canvas = remap(page.canvas)
    page.pageNodes = remap(page.pageNodes)?.mapValues { node in
      var node = node
      if let parent = node.parentID { node.parentID = mapping[parent] ?? parent }
      return node
    }
    return page
  }
}

private struct PageMerger {
  struct Snapshot {
    let document: NoteDocument
    let blocks: [String: NoteBlock]
    let children: [String?: [String]]
    init(_ document: NoteDocument) {
      self.document = document
      blocks = Dictionary(document.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      children = document.pageChildMap()
    }
    func has(_ id: String) -> Bool { blocks[id] != nil }
    func parent(_ id: String) -> String? { document.pageNodes?[id]?.parentID }
    func isSection(_ id: String) -> Bool { document.pageNodes?[id]?.isSection == true }
    /// Everything a reader sees of a component, and nothing a stamp writes or layout moves.
    func content(_ id: String) -> Content? {
      guard let block = blocks[id] else { return nil }
      let placement = document.canvas?[id], item = document.boardItems?[id] ?? BoardItem()
      return Content(block: block.normalized, title: placement?.title, assetID: placement?.assetID, role: item.role,
        task: item.task, review: item.review, sessions: item.sessions, lastChange: item.lastChange)
    }
  }

  struct Content: Equatable, Encodable {
    var block: NoteBlock
    var title: String?
    var assetID: String?
    var role: BoardItemRole
    var task: BoardTask?
    var review: BoardReviewState?
    var sessions: [String]
    var lastChange: String?
  }

  let base: Snapshot, local: Snapshot, remote: Snapshot
  var survivors: Set<String> = []
  var resolved: [String: Content] = [:]
  var parents: [String: String?] = [:]
  var sections: Set<String> = []
  var localItems: [String: BoardItem] = [:]
  var conflicted: [String] = []
  var copies: [String] = []
  var extraBlocks: [String: NoteBlock] = [:]
  var extraItems: [String: BoardItem] = [:]
  var extraPlacements: [String: CanvasCardPlacement] = [:]

  init(base: NoteDocument, local: NoteDocument, remote: NoteDocument) {
    self.base = Snapshot(base); self.local = Snapshot(local); self.remote = Snapshot(remote)
  }

  mutating func merge() throws -> PageMerge {
    let order = readingUnion()
    var conflicts: [(id: String, content: Content)] = []
    for id in order {
      guard survives(id) else { continue }
      survivors.insert(id)
      if local.isSection(id) || remote.isSection(id) { sections.insert(id) }
      let (content, conflict) = mergedContent(id)
      resolved[id] = content
      if let conflict { conflicts.append((id, conflict)) }
    }
    for id in order where survivors.contains(id) { parents[id] = mergedParent(id) }
    var children = orderedChildren(order: order)
    for conflict in conflicts { addConflictCopy(of: conflict.id, content: conflict.content, children: &children) }
    let purpose = mergedPurpose(&children)
    return try build(children: children, order: order, purpose: purpose)
  }

  /// Remote reading order, then anything only the local side holds.
  private func readingUnion() -> [String] {
    var seen = Set<String>(), result: [String] = []
    for document in [remote.document, local.document, base.document] {
      for block in document.blocks where seen.insert(block.id).inserted { result.append(block.id) }
    }
    return result
  }

  /// An edit outlives a delete on the other side, so no writing disappears silently.
  private mutating func survives(_ id: String) -> Bool {
    switch (local.has(id), remote.has(id)) {
    case (true, true): return true
    case (false, false): return false
    case (true, false):
      guard base.has(id) else { return true }
      guard local.content(id) != base.content(id) else { return false }
      conflicted.append(id)
      return true
    case (false, true):
      guard base.has(id) else { return true }
      guard remote.content(id) != base.content(id) else { return false }
      conflicted.append(id)
      return true
    }
  }

  /// Returns the merged content, plus the local version when it has to live beside it.
  private mutating func mergedContent(_ id: String) -> (Content, Content?) {
    guard let localContent = local.content(id) else { return (remote.content(id)!, nil) }
    guard let remoteContent = remote.content(id) else { return (localContent, nil) }
    guard let baseContent = base.content(id) else {
      if localContent == remoteContent { return (remoteContent, nil) }
      conflicted.append(id)
      return (remoteContent, localContent)
    }
    if localContent == baseContent || localContent == remoteContent { return (remoteContent, nil) }
    if remoteContent == baseContent { return (localContent, nil) }

    var collision = false
    func pick<T: Equatable>(_ path: KeyPath<Content, T>) -> T {
      let b = baseContent[keyPath: path], l = localContent[keyPath: path], r = remoteContent[keyPath: path]
      if l == b || l == r { return r }
      if r == b { return l }
      collision = true
      return r
    }
    var merged = remoteContent
    merged.block = pick(\.block)
    merged.title = pick(\.title)
    merged.role = pick(\.role)
    merged.task = pick(\.task)
    merged.review = pick(\.review)
    // A session link and a change summary are additive metadata, not anyone's writing.
    let added = localContent.sessions.filter { !baseContent.sessions.contains($0) }
    let dropped = Set(baseContent.sessions.filter { !localContent.sessions.contains($0) })
    merged.sessions = (remoteContent.sessions + added.filter { !remoteContent.sessions.contains($0) }).filter { !dropped.contains($0) }
    if localContent.lastChange != baseContent.lastChange, remoteContent.lastChange == baseContent.lastChange {
      merged.lastChange = localContent.lastChange
    }
    guard collision else { return (merged, nil) }
    conflicted.append(id)
    return (merged, localContent)
  }

  /// Moves merge independently of content. If both sides moved one component, the remote wins.
  private func mergedParent(_ id: String) -> String? {
    let wanted: String?
    switch (local.has(id), remote.has(id), base.has(id)) {
    case (false, _, _): wanted = remote.parent(id)
    case (_, false, _): wanted = local.parent(id)
    case (_, _, false): wanted = remote.parent(id)
    default:
      let b = base.parent(id), l = local.parent(id)
      wanted = l == b ? remote.parent(id) : (remote.parent(id) == b ? l : remote.parent(id))
    }
    return survivingSection(from: wanted)
  }

  /// A parent removed on one side hands its children to the nearest remaining ancestor.
  private func survivingSection(from start: String?) -> String? {
    var current = start
    var visited = Set<String>()
    while let id = current {
      if survivors.contains(id), sections.contains(id) { return id }
      guard visited.insert(id).inserted else { return nil }
      if remote.has(id) { current = remote.parent(id) }
      else if local.has(id) { current = local.parent(id) }
      else { current = base.parent(id) }
    }
    return nil
  }

  /// Remote order is the starting point, because it is already stored. Local inserts and
  /// local moves then land after their nearest local predecessor that still exists.
  private func orderedChildren(order: [String]) -> [String?: [String]] {
    var grouped: [String?: Set<String>] = [:]
    for id in order where survivors.contains(id) { grouped[parents[id] ?? nil, default: []].insert(id) }
    var result: [String?: [String]] = [:]
    for (parent, members) in grouped {
      // A component the remote deleted but an edit kept has no remote place, so its local one stands.
      let remoteChildren = remote.children[parent] ?? []
      let positioned = locallyPositioned(parent: parent).union(
        (local.children[parent] ?? []).filter { members.contains($0) && !remote.has($0) })
      var sequence = remoteChildren.filter { members.contains($0) && !positioned.contains($0) }
      var placed = Set(sequence)
      var anchor: String?
      for id in local.children[parent] ?? [] where members.contains(id) {
        if positioned.contains(id) {
          let index = anchor.flatMap { sequence.firstIndex(of: $0).map { $0 + 1 } } ?? 0
          sequence.insert(id, at: index)
          placed.insert(id)
        }
        if placed.contains(id) { anchor = id }
      }
      sequence += order.filter { members.contains($0) && !placed.contains($0) }
      result[parent] = sequence
    }
    return result
  }

  /// Local children that were inserted, moved here, or reordered relative to the base.
  private func locallyPositioned(parent: String?) -> Set<String> {
    let current = local.children[parent] ?? []
    guard !current.isEmpty else { return [] }
    let baseIndex = Dictionary((base.children[parent] ?? []).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
    var positioned = Set<String>()
    var kept: [(id: String, index: Int)] = []
    for id in current {
      if let index = baseIndex[id] { kept.append((id, index)) } else { positioned.insert(id) }
    }
    // Whatever stays in increasing base order did not move; the rest did.
    positioned.formUnion(Set(kept.map { $0.id }).subtracting(Self.longestIncreasing(kept)))
    return positioned
  }

  private static func longestIncreasing(_ values: [(id: String, index: Int)]) -> Set<String> {
    guard !values.isEmpty else { return [] }
    var tails: [Int] = []
    var previous = [Int](repeating: -1, count: values.count)
    for offset in values.indices {
      var low = 0, high = tails.count
      while low < high {
        let middle = (low + high) / 2
        if values[tails[middle]].index < values[offset].index { low = middle + 1 } else { high = middle }
      }
      if low > 0 { previous[offset] = tails[low - 1] }
      if low == tails.count { tails.append(offset) } else { tails[low] = offset }
    }
    var result = Set<String>()
    var cursor = tails.last ?? -1
    while cursor >= 0 { result.insert(values[cursor].id); cursor = previous[cursor] }
    return result
  }

  private mutating func addConflictCopy(of id: String, content: Content, children: inout [String?: [String]]) {
    let copyID = "conflict-" + Self.hash(id, content)
    // A retry of the same draft finds its copy already stored, and must not add another.
    guard !copies.contains(copyID), !remote.has(copyID) else { return }
    copies.append(copyID)
    let isSection = sections.contains(id)
    extraBlocks[copyID] = Self.copyBlock(content.block, id: copyID)
    extraItems[copyID] = BoardItem(role: content.role, task: isSection ? nil : content.task, review: .needed, sessions: content.sessions,
      lastChange: "Kept this version because the same component also changed elsewhere.")
    if let assetID = content.assetID {
      var placement = CanvasCardPlacement(x: 0, y: 0, assetID: assetID)
      placement.title = content.title
      extraPlacements[copyID] = placement
    }
    // A section's title has no sibling to sit beside inside its subtree, so its copy opens it.
    if isSection {
      children[id, default: []].insert(copyID, at: 0)
    } else {
      let parent = parents[id] ?? nil
      var siblings = children[parent] ?? []
      let index = siblings.firstIndex(of: id).map { $0 + 1 } ?? siblings.endIndex
      siblings.insert(copyID, at: index)
      children[parent] = siblings
    }
  }

  private mutating func mergedPurpose(_ children: inout [String?: [String]]) -> String? {
    let b = base.document.boardPurpose, l = local.document.boardPurpose, r = remote.document.boardPurpose
    if l == b || l == r { return r }
    if r == b { return l }
    if let l, !l.isEmpty {
      let copyID = "conflict-purpose-" + Self.hash(l)
      if !remote.has(copyID), !copies.contains(copyID) {
        copies.append(copyID)
        extraBlocks[copyID] = .richText(NoteRichTextBlock(id: copyID, text: l))
        extraItems[copyID] = BoardItem(review: .needed, lastChange: "Kept this purpose because the Page's purpose also changed elsewhere.")
        children[nil, default: []].append(copyID)
      }
    }
    return r
  }

  private func build(children: [String?: [String]], order: [String], purpose: String?) throws -> PageMerge {
    var document = remote.document
    document.boardPurpose = purpose
    var blocks: [NoteBlock] = []
    var nodes: [String: PageNode] = [:]
    var canvas = document.canvas ?? [:]
    var items: [String: BoardItem] = [:]
    var deferred: [String] = []
    var reached = Set<String>()

    func mergedItem(_ id: String, _ content: Content) -> BoardItem? {
      // Provenance follows the writer whose version is kept; the host stamps this write next.
      let source = remote.has(id) ? remote.document.boardItems?[id] : local.document.boardItems?[id]
      var value = source ?? BoardItem()
      value.role = content.role; value.task = content.task; value.review = content.review
      value.sessions = content.sessions; value.lastChange = content.lastChange
      return value == BoardItem() ? nil : value
    }

    func emit(_ id: String, parent: String?, depth: Int) {
      guard !reached.contains(id), let block = extraBlocks[id] ?? resolved[id]?.block else { return }
      let isSection = sections.contains(id)
      // Each side's nesting was legal, but both together can run too deep.
      if isSection, depth >= NoteDocument.maximumPageDepth {
        deferred.append(id)
        return
      }
      reached.insert(id)
      blocks.append(block)
      if isSection { nodes[id] = PageNode(parentID: parent, isSection: true) }
      else if let parent { nodes[id] = PageNode(parentID: parent) }
      if let extra = extraItems[id] { items[id] = extra }
      else if let content = resolved[id], let value = mergedItem(id, content) { items[id] = value }
      if let extra = extraPlacements[id] { canvas[id] = extra }
      else if let content = resolved[id] {
        var placement = canvas[id] ?? local.document.canvas?[id]
        if placement != nil || content.title != nil || content.assetID != nil {
          if placement == nil { placement = CanvasCardPlacement(x: 0, y: 0) }
          placement?.title = content.title
          placement?.assetID = content.assetID
          canvas[id] = placement
        }
      }
      if isSection {
        for child in children[id] ?? [] { emit(child, parent: id, depth: depth + 1) }
      }
    }
    for id in children[nil] ?? [] { emit(id, parent: nil, depth: 0) }
    // A parent cycle across the two sides, or an over-deep section, re-enters at the root.
    var cursor = order.startIndex
    while true {
      if let id = deferred.popLast() {
        emit(id, parent: nil, depth: 0)
      } else if cursor < order.endIndex {
        let id = order[cursor]
        cursor += 1
        if survivors.contains(id) { emit(id, parent: nil, depth: 0) }
      } else {
        break
      }
    }

    let surviving = Set(blocks.map(\.id))
    document.blocks = blocks
    document.pageNodes = nodes
    canvas = canvas.filter { surviving.contains($0.key) }
    document.canvas = canvas.isEmpty && document.canvas == nil ? nil : canvas
    document.boardItems = items.isEmpty && document.boardItems == nil ? nil : items
    document.canvasConnections = document.canvasConnections?.filter { surviving.contains($0.from) && surviving.contains($0.to) }
    try document.validateEditableShape()
    return PageMerge(document: document, conflictedIDs: conflicted, conflictCopyIDs: copies)
  }

  static func copyBlock(_ block: NoteBlock, id: String) -> NoteBlock {
    switch block {
    case .richText(var text):
      text.id = id
      return .richText(text)
    case .table(var table):
      table.id = id
      var cell = 0
      table.columns = table.columns.enumerated().map { var column = $0.element; column.id = "\(id):c\($0.offset)"; return column }
      table.rows = table.rows.enumerated().map { rowIndex, row in
        var row = row
        row.id = "\(id):r\(rowIndex)"
        row.cells = row.cells.map { value in var value = value; value.id = "\(id):x\(cell)"; cell += 1; return value }
        return row
      }
      return .table(table)
    }
  }

  static func hash(_ id: String, _ content: Content) -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = (try? encoder.encode(content)) ?? Data()
    return hash(id + "\u{0}" + String(decoding: bytes, as: UTF8.self))
  }

  private static func hash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
  }
}
