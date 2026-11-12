import CryptoKit
import Foundation

/// Where one block of a Page sits. `blocks` stays flat and in reading order, so note
/// tools, table tools and search keep working; a node only adds the tree. A block with
/// no node is an ordinary root block. `pageNodes != nil` marks a migrated Page.
public struct PageNode: Codable, Equatable, Sendable {
  /// `nil` is the Page root. Otherwise an enclosing section, open at this block.
  public var parentID: String?
  public var isSection: Bool

  public init(parentID: String? = nil, isSection: Bool = false) {
    self.parentID = parentID; self.isSection = isSection
  }
}

/// A contiguous run the Page editor shows as one surface. Text, lists, tables and
/// tasks stay in a flow, while sections and linked originals split them.
public enum PageSegment: Equatable, Identifiable, Sendable {
  /// `afterID` is the previous sibling outside this flow, so the flow's ID survives
  /// deleting its first paragraph. An empty `blockIDs` marks a place to start typing.
  case flow(id: String, parentID: String?, afterID: String?, depth: Int, blockIDs: [String])
  case section(id: String, parentID: String?, depth: Int)
  case asset(id: String, assetID: String, parentID: String?, depth: Int)

  public var id: String {
    switch self {
    case .flow(let id, _, _, _, _), .section(let id, _, _), .asset(let id, _, _, _): id
    }
  }
  public var depth: Int {
    switch self {
    case .flow(_, _, _, let depth, _), .section(_, _, let depth), .asset(_, _, _, let depth): depth
    }
  }
  public var parentID: String? {
    switch self {
    case .flow(_, let parentID, _, _, _), .section(_, let parentID, _), .asset(_, _, let parentID, _): parentID
    }
  }
}

public enum PageComponentKind: String, Codable, CaseIterable, Sendable { case text, task, section, table, asset }

/// A place among a parent's children. With neither `afterID` nor `atStart` the
/// component goes at the end of the parent, which is what adding usually means.
public struct PagePosition: Codable, Equatable, Sendable {
  public var parentID: String?
  /// A direct child of `parentID`. The component lands after that child's whole subtree.
  public var afterID: String?
  public var atStart: Bool

  public init(parentID: String? = nil, afterID: String? = nil, atStart: Bool = false) {
    self.parentID = parentID; self.afterID = afterID; self.atStart = atStart
  }

  private enum CodingKeys: String, CodingKey { case parentID, afterID, atStart }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    parentID = try values.decodeIfPresent(String.self, forKey: .parentID)
    afterID = try values.decodeIfPresent(String.self, forKey: .afterID)
    atStart = try values.decodeIfPresent(Bool.self, forKey: .atStart) ?? false
  }
}

/// A connection drawn on an older spatial Board. A flowing Page has no place to draw
/// it, so it stays readable as text and is never silently dropped.
public struct PageLegacyConnection: Equatable, Identifiable, Sendable {
  public var id: String
  public var fromID: String
  public var toID: String
  public var fromText: String
  public var toText: String
  public var label: String
}

public extension NoteDocument {
  static let maximumPageDepth = 8
  static let legacyConnectionExcerpt = 120

  /// Rejects anything but a contiguous tree: each parent must be an enclosing open
  /// section, which also rules out cycles and split subtrees.
  func validatePageStructure() throws {
    guard let pageNodes else { return }
    guard kind == .canvas else { throw NoteDocumentSafetyError.unsupportedFormat }
    var open: [String] = []
    var seen = 0
    for block in blocks {
      let node = pageNodes[block.id]
      if node != nil { seen += 1 }
      if let parentID = node?.parentID {
        guard let index = open.lastIndex(of: parentID) else { throw NoteDocumentSafetyError.unsupportedFormat }
        open.removeSubrange((index + 1)...)
      } else {
        open.removeAll(keepingCapacity: true)
      }
      if node?.isSection == true {
        guard case .richText = block, canvas?[block.id]?.assetID == nil,
              open.count < Self.maximumPageDepth else { throw NoteDocumentSafetyError.unsupportedFormat }
        open.append(block.id)
      }
    }
    // A node for a missing block would silently re-parent a later block with that ID.
    guard seen == pageNodes.count else { throw NoteDocumentSafetyError.unsupportedFormat }
  }

  /// The Page's tree, in reading order. Projects an older Board without writing.
  var pageSegments: [PageSegment] {
    let document = materializedPage()
    let children = document.pageChildMap()
    var segments: [PageSegment] = []
    func emit(parentID: String?, depth: Int) {
      var flow: [String] = []
      var afterID: String?
      var endsWithFlow = false
      func flush() {
        guard !flow.isEmpty else { return }
        segments.append(.flow(id: Self.pageFlowID(parentID: parentID, afterID: afterID), parentID: parentID,
          afterID: afterID, depth: depth, blockIDs: flow))
        flow = []
      }
      for id in children[parentID] ?? [] {
        if document.pageNodes?[id]?.isSection == true {
          flush()
          segments.append(.section(id: id, parentID: parentID, depth: depth))
          emit(parentID: id, depth: depth + 1)
          afterID = id; endsWithFlow = false
        } else if let assetID = document.canvas?[id]?.assetID {
          flush()
          segments.append(.asset(id: id, assetID: assetID, parentID: parentID, depth: depth))
          afterID = id; endsWithFlow = false
        } else {
          flow.append(id); endsWithFlow = true
        }
      }
      flush()
      if !endsWithFlow {
        segments.append(.flow(id: Self.pageFlowID(parentID: parentID, afterID: afterID), parentID: parentID,
          afterID: afterID, depth: depth, blockIDs: []))
      }
    }
    emit(parentID: nil, depth: 0)
    return segments
  }

  private static func pageFlowID(parentID: String?, afterID: String?) -> String {
    "flow:\(parentID ?? "root"):\(afterID ?? "start")"
  }

  /// Converts an older spatial Board deterministically: the same document always gives
  /// the same order and IDs on every host. Purely additive to the stored layout, so
  /// `canvas`, `canvasSections` and `canvasConnections` stay available as references.
  func materializedPage() -> NoteDocument {
    guard kind == .canvas, pageNodes == nil else { return self }
    var copy = self
    let sections = canvasSections ?? []
    let sectionIDs = Set(sections.map(\.id))
    var taken = Set(blocks.map(\.id))
    func uniqueID(_ candidate: String) -> String {
      var value = candidate, suffix = 2
      while !taken.insert(value).inserted { value = "\(candidate)~\(suffix)"; suffix += 1 }
      return value
    }
    // Tolerates a duplicate ID, so a malformed document still reaches validation. A card
    // with no stored placement sat in the Board's automatic five-column grid.
    let positions = Dictionary(blocks.enumerated().map { index, block in
      (block.id, canvas?[block.id] ?? CanvasCardPlacement(x: 24 + Double(index % 5) * 392, y: 24 + Double(index / 5) * 332))
    }, uniquingKeysWith: { first, _ in first })
    let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func order(_ lhs: (y: Double, x: Double, id: String), _ rhs: (y: Double, x: Double, id: String)) -> Bool {
      (lhs.y, lhs.x, lhs.id) < (rhs.y, rhs.x, rhs.id)
    }
    func placed(_ id: String) -> (y: Double, x: Double, id: String) {
      let placement = positions[id]; return (placement?.y ?? 0, placement?.x ?? 0, id)
    }
    var members: [String: [String]] = [:]
    var rootItems: [(y: Double, x: Double, id: String)] = sections.map { ($0.y, $0.x, $0.id) }
    for block in blocks {
      if let sectionID = canvas?[block.id]?.sectionID, sectionIDs.contains(sectionID) {
        members[sectionID, default: []].append(block.id)
      } else {
        rootItems.append(placed(block.id))
      }
    }
    rootItems.sort(by: order)
    var result: [NoteBlock] = []
    var nodes: [String: PageNode] = [:]
    func appendCard(_ id: String, parentID: String?) {
      guard var block = byID[id] else { return }
      if let parentID { nodes[id] = PageNode(parentID: parentID) }
      // A title has no place in a flowing document, so it joins the text. A linked
      // original keeps its label, because its content lives elsewhere.
      if copy.canvas?[id]?.assetID == nil, let title = copy.canvas?[id]?.title {
        copy.canvas?[id]?.title = nil
        if !title.isEmpty {
          if case .richText(var text) = block, text.plainText.isEmpty {
            text.runs = [NoteTextRun(text: title)]
            block = .richText(text)
          } else {
            let titleID = uniqueID("page-title:\(id)")
            if let parentID { nodes[titleID] = PageNode(parentID: parentID) }
            result.append(.richText(NoteRichTextBlock(id: titleID, style: .heading3, text: title)))
          }
        }
      }
      result.append(block)
    }
    for item in rootItems {
      if sectionIDs.contains(item.id), let section = sections.first(where: { $0.id == item.id }) {
        let sectionBlockID = uniqueID("page-section:\(section.id)")
        nodes[sectionBlockID] = PageNode(isSection: true)
        result.append(.richText(NoteRichTextBlock(id: sectionBlockID, style: .heading2, text: section.title)))
        for item in (members[section.id] ?? []).map(placed).sorted(by: order) {
          appendCard(item.id, parentID: sectionBlockID)
        }
      } else {
        appendCard(item.id, parentID: nil)
      }
    }
    copy.blocks = result
    copy.pageNodes = nodes
    return copy
  }

  /// The blocks of one flow as an ordinary note, for a text editor. Task, review and
  /// provenance metadata stay on this Page; retained block IDs keep them through `spliceFlow`.
  /// An empty list yields one fresh empty paragraph, so hold its ID until the first splice.
  func pageFlowDocument(blockIDs: [String]) -> NoteDocument {
    let document = materializedPage()
    let byID = Dictionary(document.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return NoteDocument(kind: .note, blocks: blockIDs.compactMap { byID[$0] })
  }

  /// Replaces one flow's blocks. A block that keeps its ID keeps its metadata; a block
  /// that disappears takes its metadata with it. Original assets are never in a flow.
  mutating func spliceFlow(_ old: [String], with new: [NoteBlock], parentID: String?, afterID: String? = nil) throws {
    guard kind == .canvas else { throw NoteEditError.artifactKindMismatch }
    if old.isEmpty {
      if new.isEmpty { return }
      if new.count == 1, case .richText(let only) = new[0], only.plainText.isEmpty, only.style == .paragraph { return }
    }
    var document = materializedPage()
    if let parentID, document.pageNodes?[parentID]?.isSection != true { throw NoteEditError.pageTargetMissing(parentID) }
    let oldIDs = Set(old), newIDs = new.map(\.id), newIDSet = Set(newIDs)
    guard oldIDs.count == old.count, newIDSet.count == newIDs.count, !newIDs.contains(where: \.isEmpty) else {
      throw NoteDocumentSafetyError.unsupportedFormat
    }
    guard document.blocks.allSatisfy({ oldIDs.contains($0.id) || !newIDSet.contains($0.id) }) else {
      throw NoteDocumentSafetyError.unsupportedFormat
    }
    let start: Int
    if let first = old.first {
      guard let index = document.blocks.firstIndex(where: { $0.id == first }) else { throw NoteEditError.blockNotFound(first) }
      guard index + old.count <= document.blocks.count,
            document.blocks[index..<(index + old.count)].map(\.id) == old else { throw NoteEditError.pagePositionInvalid(first) }
      for id in old {
        guard document.pageParentID(for: id) == parentID, document.pageNodes?[id]?.isSection != true,
              document.canvas?[id]?.assetID == nil else { throw NoteEditError.pagePositionInvalid(id) }
      }
      start = index
    } else {
      start = try document.pageInsertionIndex(PagePosition(parentID: parentID, afterID: afterID, atStart: afterID == nil))
    }
    document.blocks.replaceSubrange(start..<(start + old.count), with: new)
    document.prunePageMetadata(oldIDs.subtracting(newIDSet))
    for id in newIDs {
      document.pageNodes?[id] = parentID.map { PageNode(parentID: $0) }
    }
    try document.validateEditableShape()
    self = document
  }

  func pageComponentKind(for id: String) -> PageComponentKind? {
    guard let block = blocks.first(where: { $0.id == id }) else { return nil }
    return pageComponentKind(block: block)
  }

  func pageParentID(for id: String) -> String? { pageNodes?[id]?.parentID }

  /// How many sections enclose this block.
  func pageDepth(for id: String) -> Int {
    var depth = 0
    var current = pageNodes?[id]?.parentID
    while let parent = current, depth <= Self.maximumPageDepth {
      depth += 1
      current = pageNodes?[parent]?.parentID
    }
    return depth
  }

  /// Direct children in reading order. `nil` asks for the Page root.
  func pageChildren(of parentID: String?) -> [String] { pageChildMap()[parentID] ?? [] }

  /// A component and everything nested in it, in reading order.
  func pageSubtreeIDs(of id: String) -> [String] {
    guard let range = pageSubtreeRange(of: id) else { return [] }
    return blocks[range].map(\.id)
  }

  /// Token for a component and its nested content. A subtree delete must prove it read
  /// what it removes. Equal to `boardItemRevision` for anything that has no children,
  /// and independent of where the subtree itself sits.
  func pageSubtreeRevision(for id: String) -> String {
    guard let range = pageSubtreeRange(of: id) else { return "" }
    guard range.count > 1 else { return boardItemRevision(for: id) }
    var entries: [String] = []
    entries.reserveCapacity(range.count)
    for (offset, block) in blocks[range].enumerated() {
      let parent = offset == 0 ? "" : (pageNodes?[block.id]?.parentID ?? "")
      entries.append("\(block.id)\u{0}\(parent)\u{0}\(pageRevision(of: block))")
    }
    return Self.pageHash(entries.joined(separator: "\u{1}"))
  }

  /// Older connections, readable without any spatial view. Endpoints missing from the
  /// document cannot occur: validation rejects them and removal prunes them. Each end
  /// is a short excerpt that identifies it, so a read never repeats whole components.
  var pageLegacyConnections: [PageLegacyConnection] {
    let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func text(_ id: String) -> String {
      if let title = canvas?[id]?.title, !title.isEmpty { return String(title.prefix(Self.legacyConnectionExcerpt)) }
      return String((byID[id]?.plainText ?? "").prefix(Self.legacyConnectionExcerpt))
    }
    return (canvasConnections ?? []).map {
      PageLegacyConnection(id: $0.id, fromID: $0.from, toID: $0.to, fromText: text($0.from), toText: text($0.to), label: $0.label)
    }
  }
}

// MARK: - Internals shared with PageEdit and PageMerge

extension NoteDocument {
  func pageComponentKind(block: NoteBlock) -> PageComponentKind {
    if pageNodes?[block.id]?.isSection == true { return .section }
    if canvas?[block.id]?.assetID != nil { return .asset }
    if case .table = block { return .table }
    return boardItems?[block.id]?.task != nil ? .task : .text
  }

  func pageChildMap() -> [String?: [String]] {
    var children: [String?: [String]] = [:]
    for block in blocks { children[pageNodes?[block.id]?.parentID, default: []].append(block.id) }
    return children
  }

  /// A subtree is always contiguous once validated, so this is a slice of `blocks`.
  func pageSubtreeRange(of id: String) -> Range<Int>? {
    guard let start = blocks.firstIndex(where: { $0.id == id }) else { return nil }
    guard pageNodes?[id]?.isSection == true else { return start..<(start + 1) }
    var open: Set<String> = [id]
    var end = start + 1
    while end < blocks.count, let parent = pageNodes?[blocks[end].id]?.parentID, open.contains(parent) {
      if pageNodes?[blocks[end].id]?.isSection == true { open.insert(blocks[end].id) }
      end += 1
    }
    return start..<end
  }

  /// The index a component would take in the current blocks. Throws for a parent that is
  /// not a section, or an anchor that is not its direct child.
  func pageInsertionIndex(_ position: PagePosition) throws -> Int {
    if let parentID = position.parentID, pageNodes?[parentID]?.isSection != true {
      throw NoteEditError.pageTargetMissing(parentID)
    }
    if let afterID = position.afterID {
      guard blocks.contains(where: { $0.id == afterID }) else { throw NoteEditError.pageTargetMissing(afterID) }
      guard pageNodes?[afterID]?.parentID == position.parentID, let range = pageSubtreeRange(of: afterID) else {
        throw NoteEditError.pagePositionInvalid(afterID)
      }
      return range.upperBound
    }
    guard let parentID = position.parentID else { return position.atStart ? 0 : blocks.endIndex }
    guard let range = pageSubtreeRange(of: parentID) else { throw NoteEditError.pageTargetMissing(parentID) }
    return position.atStart ? range.lowerBound + 1 : range.upperBound
  }

  /// A generic insert lands where a reader would expect: inside `blockID`'s own parent,
  /// or as the first child of a section. Anything else appends at the root.
  mutating func insertPageAware(_ block: NoteBlock, after blockID: String?) {
    guard let blockID, let index = blocks.firstIndex(where: { $0.id == blockID }) else {
      blocks.append(block)
      return
    }
    blocks.insert(block, at: index + 1)
    guard pageNodes != nil else { return }
    let parent = pageNodes?[blockID]?.isSection == true ? blockID : pageNodes?[blockID]?.parentID
    pageNodes?[block.id] = parent.map { PageNode(parentID: $0) }
  }

  /// Generic tools can only reach a section through its own component tools. Refusing
  /// here stops one delete from orphaning everything nested in it.
  func requirePageRemovable(_ id: String) throws {
    guard pageNodes?[id]?.isSection == true, let range = pageSubtreeRange(of: id), range.count > 1 else { return }
    throw NoteEditError.pageSectionNotEmpty(id)
  }

  mutating func prunePageMetadata(_ ids: Set<String>) {
    guard !ids.isEmpty else { return }
    for id in ids {
      canvas?.removeValue(forKey: id)
      boardItems?.removeValue(forKey: id)
      pageNodes?.removeValue(forKey: id)
    }
    canvasConnections?.removeAll { ids.contains($0.from) || ids.contains($0.to) }
  }

  /// The same token as `boardItemRevision`, for a block already in hand.
  func pageRevision(of block: NoteBlock) -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let placement = canvas?[block.id]
    guard let bytes = try? encoder.encode(BoardItemFingerprint(block: block.normalized, title: placement?.title,
      assetID: placement?.assetID, item: boardItems?[block.id],
      isSection: pageNodes?[block.id]?.isSection == true ? true : nil)) else { return "" }
    return Self.pageHash(bytes)
  }

  static func pageHash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(32).description
  }

  static func pageHash(_ text: String) -> String { pageHash(Data(text.utf8)) }
}
