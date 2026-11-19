import Foundation
import Testing
@testable import WovenMatterShared

@Suite("Flowing Pages")
struct PageModelTests {
  private func text(_ id: String, _ value: String = "", style: NoteParagraphStyle = .paragraph) -> NoteBlock {
    .richText(.init(id: id, style: style, text: value))
  }
  private func page(_ blocks: [NoteBlock], nodes: [String: PageNode] = [:], items: [String: BoardItem]? = nil,
                    canvas: [String: CanvasCardPlacement]? = nil) -> NoteDocument {
    NoteDocument(kind: .canvas, blocks: blocks, canvas: canvas, boardItems: items, pageNodes: nodes)
  }
  /// section s holds a, then nested section t holding b. Then root text c and link l.
  private func sample() -> NoteDocument {
    page([text("s", "Section", style: .heading2), text("a", "Alpha"), text("t", "Nested", style: .heading3), text("b", "Beta"), text("c", "Root"), text("l")],
      nodes: ["s": .init(isSection: true), "a": .init(parentID: "s"), "t": .init(parentID: "s", isSection: true), "b": .init(parentID: "t")],
      items: ["b": .init(task: .init(status: .doing))], canvas: ["l": .init(assetID: "original")])
  }
  private func order(_ document: NoteDocument) -> [String] { document.blocks.map(\.id) }

  @Test func continuedTypingAfterAConflictEditsItsExactRetainedCopy() throws {
    let base = page([text("a", "Base")])
    let submitted = page([text("a", "Mine")])
    let remote = page([text("a", "Theirs")])
    let first = try NoteDocument.mergePage(base: base, local: submitted, remote: remote)
    let copy = try #require(first.conflictCopyIDs.first)
    let continued = page([text("a", "Mine, continued")])
    let next = try NoteDocument.mergePage(base: submitted, local: continued, remote: first.document)
    #expect(next.conflictCopyIDs.isEmpty)
    #expect(next.document.blocks.count == 2)
    #expect(next.document.blocks.first { $0.id == "a" }?.plainText == "Theirs")
    #expect(next.document.blocks.first { $0.id == copy }?.plainText == "Mine, continued")
    #expect(next.document.boardItems?[copy]?.review == .needed)
    var current = next.document
    var previous = continued
    for value in ["Third save", "Fourth save", "Fifth save"] {
      let local = page([text("a", value)])
      let merged = try NoteDocument.mergePage(base: previous, local: local, remote: current)
      #expect(merged.conflictCopyIDs.isEmpty)
      #expect(merged.document.blocks.count == 2)
      #expect(merged.document.blocks.first { $0.id == copy }?.plainText == value)
      #expect(NoteDocument.pageConflictComponentRemaps(submitted: local, stored: merged.document)["a"] == copy)
      previous = local
      current = merged.document
    }
  }

  /// A task, then a section holding a linked original and text, then a heading and a table.
  private func plan() -> NoteDocument {
    var linked = CanvasCardPlacement(assetID: "asset-1"); linked.title = "Spec"
    return NoteDocument(kind: .canvas, blocks: [
      text("b", "Write the plan"),
      text("section", "Research", style: .heading2),
      text("c"),
      text("a", "In a section"),
      text("numbers", "Numbers", style: .heading3),
      .table(.init(id: "d", columns: [.init(id: "col")], rows: [.init(id: "row", cells: [.init(id: "cell")])])),
    ], canvas: ["c": linked], boardPurpose: "Plan", boardItems: ["b": .init(task: .init(status: .todo))],
      pageNodes: ["section": .init(isSection: true), "c": .init(parentID: "section"), "a": .init(parentID: "section")])
  }

  // MARK: Tree validation

  @Test func malformedTreesAreRejected() throws {
    func rejected(_ document: NoteDocument, sourceLocation: SourceLocation = #_sourceLocation) {
      #expect(throws: NoteDocumentSafetyError.unsupportedFormat, sourceLocation: sourceLocation) { try document.validateEditableShape() }
    }
    rejected(page([text("a")], nodes: ["ghost": .init()]))
    rejected(page([text("a")], nodes: ["a": .init(parentID: "missing")]))
    rejected(page([text("p"), text("a")], nodes: ["a": .init(parentID: "p")]))  // parent is no section
    rejected(page([text("s"), text("a"), text("r"), text("b")],  // broken contiguity
      nodes: ["s": .init(isSection: true), "a": .init(parentID: "s"), "b": .init(parentID: "s")]))
    rejected(page([text("x"), text("y")],  // cycle
      nodes: ["x": .init(parentID: "y", isSection: true), "y": .init(parentID: "x", isSection: true)]))
    rejected(page([text("a"), text("s")], nodes: ["a": .init(parentID: "s"), "s": .init(isSection: true)]))  // child first
    rejected(page([.table(.init(id: "s", columns: [.init(id: "c")], rows: [.init(id: "r", cells: [.init(id: "x")])]))], nodes: ["s": .init(isSection: true)]))
    rejected(page([text("s")], nodes: ["s": .init(isSection: true)], canvas: ["s": .init(assetID: "a")]))
    rejected(NoteDocument(blocks: [text("a")], pageNodes: [:]))

    var chain: [NoteBlock] = [], nodes: [String: PageNode] = [:]
    for depth in 0...NoteDocument.maximumPageDepth {
      chain.append(text("s\(depth)"))
      nodes["s\(depth)"] = .init(parentID: depth == 0 ? nil : "s\(depth - 1)", isSection: true)
    }
    rejected(page(chain, nodes: nodes))
    try page(Array(chain.dropLast()), nodes: nodes.filter { $0.key != "s\(NoteDocument.maximumPageDepth)" }).validateEditableShape()
  }

  @Test func aFutureNodeFieldIsReadOnly() throws {
    var object = try #require(JSONSerialization.jsonObject(with: Data(sample().encoded().utf8)) as? [String: Any])
    var nodes = try #require(object["pageNodes"] as? [String: [String: Any]])
    nodes["a"]?["futureField"] = true
    object["pageNodes"] = nodes
    let raw = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: raw) }
    #expect(try NoteDocument.editableDocument(from: sample().encoded()) == sample().normalized())
  }

  // MARK: Segments

  @Test func segmentsSplitFlowsAtSectionsAndOriginals() throws {
    let segments = sample().pageSegments
    #expect(segments == [
      .section(id: "s", parentID: nil, depth: 0),
      .flow(id: PageSegment.flowID(parentID: "s", afterID: nil), parentID: "s", afterID: nil, depth: 1, blockIDs: ["a"]),
      .section(id: "t", parentID: "s", depth: 1),
      .task(id: "b", parentID: "t", depth: 2),
      .flow(id: PageSegment.flowID(parentID: "t", afterID: "b"), parentID: "t", afterID: "b", depth: 2, blockIDs: []),
      .flow(id: PageSegment.flowID(parentID: "s", afterID: "t"), parentID: "s", afterID: "t", depth: 1, blockIDs: []),
      .flow(id: PageSegment.flowID(parentID: nil, afterID: "s"), parentID: nil, afterID: "s", depth: 0, blockIDs: ["c"]),
      .asset(id: "l", assetID: "original", parentID: nil, depth: 0),
      .flow(id: PageSegment.flowID(parentID: nil, afterID: "l"), parentID: nil, afterID: "l", depth: 0, blockIDs: []),
    ])
    #expect(page([]).pageSegments == [.flow(id: PageSegment.flowID(parentID: nil, afterID: nil), parentID: nil, afterID: nil, depth: 0, blockIDs: [])])
    let empty = page([text("s")], nodes: ["s": .init(isSection: true)]).pageSegments
    #expect(empty.contains(.flow(id: PageSegment.flowID(parentID: "s", afterID: nil), parentID: "s", afterID: nil, depth: 1, blockIDs: [])))
  }

  @Test func flowIDsNeverCollide() throws {
    #expect(PageSegment.flowID(parentID: nil, afterID: nil) == "flow/-/-")
    #expect(PageSegment.flowID(parentID: "s", afterID: "a:b") == "flow/1:s/3:a:b")
    let places: [(String?, String?)] = [(nil, nil), ("root", nil), (nil, "start"), ("root", "start"),
      ("a:b", "c"), ("a", "b:c"), ("a/1:b", nil), ("a", "1:b"), ("-", nil), (nil, "-")]
    #expect(Set(places.map { PageSegment.flowID(parentID: $0.0, afterID: $0.1) }).count == places.count)
    // A section literally called "root" holds its own flow, apart from the Page root's.
    let named = page([text("intro", "Intro"), text("root", "Root section", style: .heading2), text("inside", "In it")],
      nodes: ["root": .init(isSection: true), "inside": .init(parentID: "root")])
    let ids = named.pageSegments.map(\.id)
    #expect(ids.count == 4 && Set(ids).count == ids.count)
  }

  @Test func aFlowKeepsItsIdentityWhenItsFirstParagraphGoes() throws {
    var document = page([text("one", "1"), text("two", "2")])
    let before = document.pageSegments.first?.id
    try document.spliceFlow(["one", "two"], with: [text("two", "2")], parentID: nil)
    #expect(document.pageSegments.first?.id == before)
    try document.spliceFlow(["two"], with: [], parentID: nil)
    #expect(document.pageSegments == [.flow(id: before!, parentID: nil, afterID: nil, depth: 0, blockIDs: [])])
  }

  @Test func tablesStayInTheFlowAndTasksAndImagesStandApart() throws {
    let table = NoteBlock.table(.init(id: "grid", columns: [.init(id: "c")], rows: [.init(id: "r", cells: [.init(id: "x")])]))
    var picture = CanvasCardPlacement(); picture.image = PageImage(mediaType: "image/png", bytes: Data([1, 2, 3]))
    let document = page([text("t", "Task"), table, text("p", "After"), text("i")], items: ["t": .init(task: .init())], canvas: ["i": picture])
    #expect(document.pageSegments == [
      .task(id: "t", parentID: nil, depth: 0),
      .flow(id: PageSegment.flowID(parentID: nil, afterID: "t"), parentID: nil, afterID: "t", depth: 0, blockIDs: ["grid", "p"]),
      .image(id: "i", parentID: nil, depth: 0),
      .flow(id: PageSegment.flowID(parentID: nil, afterID: "i"), parentID: nil, afterID: "i", depth: 0, blockIDs: []),
    ])
    #expect(document.pageComponentKind(for: "i") == .image)
    #expect(throws: NoteEditError.self) { var copy = document; try copy.spliceFlow(["i"], with: [], parentID: nil) }
    #expect(document.pageComponentKind(for: "t") == .task)
    #expect(document.pageComponentKind(for: "grid") == .table)
    #expect(document.pageComponentKind(for: "p") == .text)
    let flow = document.pageFlowDocument(blockIDs: ["t", "grid"])
    #expect(flow.kind == .note && order(flow) == ["t", "grid"])
    try flow.validateEditableShape()
    #expect(page([]).pageFlowDocument(blockIDs: []).blocks.count == 1)
  }

  // MARK: Splicing

  @Test func spliceAssignsParentsAndPrunesMetadata() throws {
    var document = sample()
    document.boardItems?["a"] = .init(review: .needed)
    let before = document
    // Paragraphs split: a stays, and a new one inherits the section.
    try document.spliceFlow(["a"], with: [text("a", "Changed"), text("new", "Typed")], parentID: "s")
    #expect(order(document) == ["s", "a", "new", "t", "b", "c", "l"])
    #expect(document.pageParentID(for: "new") == "s")
    #expect(document.boardItems?["a"]?.review == .needed)
    // Removed text takes its metadata with it, and nothing else.
    try document.spliceFlow(["a", "new"], with: [text("new", "Typed")], parentID: "s")
    #expect(document.boardItems?["a"] == nil)
    #expect(document.boardItems?["b"] == before.boardItems?["b"])
    #expect(document.canvas?["l"]?.assetID == "original")
    try document.validateEditableShape()
  }

  @Test func spliceRefusesAnythingThatWouldBreakTheTree() throws {
    let document = sample()
    func refuses(_ old: [String], _ new: [NoteBlock], parent: String?, after: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
      #expect(throws: (any Error).self, sourceLocation: sourceLocation) {
        var copy = document
        try copy.spliceFlow(old, with: new, parentID: parent, afterID: after)
      }
    }
    refuses(["a"], [text("a")], parent: "t")          // Not its parent.
    refuses(["a"], [text("a")], parent: "nope")       // No such section.
    refuses(["a"], [text("c")], parent: "s")          // Collides with text outside the flow.
    refuses(["a"], [text("x"), text("x")], parent: "s")
    refuses(["a", "b"], [], parent: "s")              // Not contiguous children.
    refuses(["s"], [text("s")], parent: nil)          // A section is not flow text.
    refuses(["l"], [text("l")], parent: nil)          // Nor is an original.
    refuses(["missing"], [], parent: nil)
    refuses([], [text("x", "typed")], parent: "s", after: "b")  // Not a direct child.
  }

  @Test func typingIntoAnEmptyPlaceStartsANewFlow() throws {
    var document = sample()
    let before = document
    // An untouched empty paragraph is not a change.
    try document.spliceFlow([], with: [text("seed")], parentID: "t")
    try document.spliceFlow([], with: [], parentID: nil)
    #expect(document == before)
    try document.spliceFlow([], with: [text("tail", "Typed after")], parentID: nil, afterID: "l")
    #expect(order(document).last == "tail")
    try document.spliceFlow([], with: [text("first", "Typed first")], parentID: "s")
    #expect(order(document) == ["s", "first", "a", "t", "b", "c", "l", "tail"])
    #expect(document.pageParentID(for: "first") == "s")
  }

  // MARK: Component edits

  @Test func componentsNestAtExactPositions() throws {
    var document = page([])
    _ = try document.apply([.page(.init(action: .add, id: "s", kind: .section, patch: .init(title: "Section")))])
    #expect(document.pageComponentKind(for: "s") == .section)
    #expect(document.blocks[0].plainText == "Section")
    func add(_ id: String, _ position: PagePosition, kind: PageComponentKind? = nil, patch: BoardItemPatch? = nil) throws {
      _ = try document.apply([.page(.init(action: .add, id: id, kind: kind, patch: patch ?? .init(text: id), position: position))])
    }
    try add("last", .init(parentID: "s"))
    try add("first", .init(parentID: "s", atStart: true))
    try add("middle", .init(parentID: "s", afterID: "first"))
    #expect(document.pageChildren(of: "s") == ["first", "middle", "last"])
    try add("root", .init())
    try add("top", .init(atStart: true))
    #expect(document.pageChildren(of: nil) == ["top", "s", "root"])
    // afterID lands after the whole subtree.
    try add("afterSection", .init(afterID: "s"))
    #expect(document.pageChildren(of: nil) == ["top", "s", "afterSection", "root"])
    try add("task", .init(parentID: "s"), kind: .task)
    #expect(document.boardItems?["task"]?.task == BoardTask())
    _ = try document.apply([.page(.init(action: .add, id: "grid", position: .init(parentID: "s")))])
    _ = try document.apply([.page(.init(action: .add, id: "t2", kind: .table, position: .init(parentID: "s")))])
    #expect(document.pageComponentKind(for: "t2") == .table)
    _ = try document.apply([.page(.init(action: .add, id: "link", assetID: "original", position: .init(parentID: "s")))])
    #expect(document.pageComponentKind(for: "link") == .asset)
    #expect(document.pageSegments.contains(.asset(id: "link", assetID: "original", parentID: "s", depth: 1)))
    try document.validateEditableShape()

    for bad in [PagePosition(parentID: "missing"), PagePosition(parentID: "first"), PagePosition(parentID: "s", afterID: "root"), PagePosition(afterID: "nope")] {
      #expect(throws: NoteEditError.self) {
        var copy = document
        _ = try copy.apply([.page(.init(action: .add, id: "x", patch: .init(text: "x"), position: bad))])
      }
    }
    #expect(throws: NoteEditError.boardItemExists("first")) {
      var copy = document
      _ = try copy.apply([.page(.init(action: .add, id: "first"))])
    }
    #expect(throws: NoteEditError.boardLinkedAssetText("copy")) {
      var copy = document
      _ = try copy.apply([.page(.init(action: .add, id: "copy", patch: .init(text: "Copied"), assetID: "a"))])
    }
    #expect(throws: NoteEditError.self) {
      var copy = document
      _ = try copy.apply([.page(.init(action: .add, id: "sectionTask", kind: .section, patch: .init(status: .todo)))])
    }
  }

  @Test func updatesRespectEachKind() throws {
    var document = sample()
    func update(_ id: String, patch: BoardItemPatch? = nil, block: NoteBlock? = nil) throws {
      _ = try document.apply([.page(.init(action: .update, id: id, expectedRevision: document.boardItemRevision(for: id), block: block, patch: patch))])
    }
    try update("s", patch: .init(title: "Renamed"))
    #expect(document.blocks[0].plainText == "Renamed")
    if case .richText(let block) = document.blocks[0] { #expect(block.style == .heading2) }
    try update("a", patch: .init(text: "New"))
    #expect(document.blocks[1].plainText == "New")
    try update("l", patch: .init(title: "Label"))
    #expect(document.canvas?["l"]?.title == "Label")
    #expect(throws: NoteEditError.boardLinkedAssetText("l")) { try update("l", patch: .init(text: "Copied")) }
    #expect(throws: NoteEditError.boardLinkedAssetText("l")) { try update("l", block: text("l", "Copied")) }
    #expect(throws: NoteEditError.boardCardIDChanged("a")) { try update("a", block: text("other", "Renamed")) }
    #expect(throws: NoteEditError.self) { try update("s", patch: .init(status: .todo)) }
    try update("b", patch: .init(status: .done, outcome: "Shipped"))
    #expect(document.boardItems?["b"]?.task == .init(status: .done, outcome: "Shipped"))
    #expect(document.boardItemRevision(for: "b") != sample().boardItemRevision(for: "b"))
    #expect(document.boardItemRevision(for: "c") == sample().boardItemRevision(for: "c"))
    #expect(throws: WorkspaceToolError.self) { _ = try document.apply([.page(.init(action: .update, id: "a", patch: .init(text: "Unchecked")))]) }
    #expect(throws: NoteEditError.boardItemConflict(id: "gone", currentRevision: "")) {
      _ = try document.apply([.page(.init(action: .update, id: "gone", expectedRevision: "r", patch: .init(text: "x")))])
    }
  }

  @Test func movingKeepsContentAndRevisions() throws {
    var document = sample()
    let tokens = Dictionary(uniqueKeysWithValues: order(document).map { ($0, document.boardItemRevision(for: $0)) })
    let subtree = document.pageSubtreeRevision(for: "t")
    let items = document.boardItems
    _ = try document.apply([.page(.init(action: .move, id: "t", position: .init()))])
    #expect(order(document) == ["s", "a", "c", "l", "t", "b"])
    #expect(document.pageParentID(for: "t") == nil && document.pageParentID(for: "b") == "t")
    #expect(document.pageSubtreeRevision(for: "t") == subtree)
    #expect(document.boardItems == items)
    for (id, token) in tokens { #expect(document.boardItemRevision(for: id) == token, "\(id)") }
    // A move inside a parent, and one that cannot shift under its own anchor.
    _ = try document.apply([.page(.init(action: .move, id: "c", position: .init(afterID: "t")))])
    #expect(order(document) == ["s", "a", "l", "t", "b", "c"])
    _ = try document.apply([.page(.init(action: .move, id: "c", position: .init(atStart: true)))])
    #expect(order(document).first == "c")
    _ = try document.apply([.page(.init(action: .move, id: "c", position: .init(parentID: "t")))])
    #expect(document.pageParentID(for: "c") == "t" && document.pageChildren(of: "t") == ["b", "c"])
    try document.validateEditableShape()
  }

  @Test func movesThatBreakTheTreeAreRefused() throws {
    let document = sample()
    #expect(throws: NoteEditError.pageMoveIntoOwnSubtree("s")) {
      var copy = document
      _ = try copy.apply([.page(.init(action: .move, id: "s", position: .init(parentID: "t")))])
    }
    #expect(throws: NoteEditError.pageMoveIntoOwnSubtree("s")) {
      var copy = document
      _ = try copy.apply([.page(.init(action: .move, id: "s", position: .init(parentID: "s")))])
    }
    #expect(throws: NoteEditError.pagePositionInvalid("s")) {
      var copy = document
      _ = try copy.apply([.page(.init(action: .move, id: "s", position: .init(afterID: "s")))])
    }
    #expect(throws: NoteEditError.boardItemConflict(id: "a", currentRevision: document.boardItemRevision(for: "a"))) {
      var copy = document
      _ = try copy.apply([.page(.init(action: .move, id: "a", expectedRevision: "stale", position: .init()))])
    }
    #expect(throws: NoteEditError.pageSubtreeConflict(id: "t", currentRevision: document.pageSubtreeRevision(for: "t"))) {
      var copy = document
      _ = try copy.apply([.page(.init(action: .move, id: "t", expectedSubtreeRevision: "stale", position: .init()))])
    }
    var chain: [NoteBlock] = [text("s0")], nodes: [String: PageNode] = ["s0": .init(isSection: true)]
    for depth in 1..<NoteDocument.maximumPageDepth {
      chain.append(text("s\(depth)"))
      nodes["s\(depth)"] = .init(parentID: "s\(depth - 1)", isSection: true)
    }
    chain += [text("x"), text("y")]
    nodes["x"] = .init(isSection: true)
    nodes["y"] = .init(parentID: "x", isSection: true)
    let deep = page(chain, nodes: nodes)
    try deep.validateEditableShape()
    #expect(throws: NoteEditError.pageDepthExceeded("x")) {
      var copy = deep
      _ = try copy.apply([.page(.init(action: .move, id: "x", position: .init(parentID: "s\(NoteDocument.maximumPageDepth - 1)")))])
    }
    #expect(throws: NoteEditError.pageDepthExceeded("n")) {
      var copy = deep
      _ = try copy.apply([.page(.init(action: .add, id: "n", kind: .section, position: .init(parentID: "s\(NoteDocument.maximumPageDepth - 1)")))])
    }
  }

  @Test func removingProtectsContentAndOriginals() throws {
    let document = sample()
    let sectionToken = document.boardItemRevision(for: "t")
    #expect(throws: NoteEditError.pageSectionNotEmpty("t")) {
      var copy = document
      _ = try copy.apply([.page(.init(action: .remove, id: "t", expectedRevision: sectionToken))])
    }
    #expect(throws: WorkspaceToolError.self) {
      var copy = document
      _ = try copy.apply([.page(.init(action: .remove, id: "t", removal: .removeSubtree))])
    }
    #expect(throws: WorkspaceToolError.self) {
      var copy = document
      _ = try copy.apply([.page(.init(action: .remove, id: "t", removal: .promoteChildren))])
    }
    let subtreeToken = document.pageSubtreeRevision(for: "t")
    var changed = document
    _ = try changed.apply([.page(.init(action: .update, id: "b", expectedRevision: document.boardItemRevision(for: "b"), patch: .init(status: .done)))])
    // A child's change fails a removal that read the subtree before it, even though the
    // section's own revision did not move.
    #expect(changed.boardItemRevision(for: "t") == sectionToken)
    #expect(throws: NoteEditError.pageSubtreeConflict(id: "t", currentRevision: changed.pageSubtreeRevision(for: "t"))) {
      var copy = changed
      _ = try copy.apply([.page(.init(action: .remove, id: "t", expectedSubtreeRevision: subtreeToken, removal: .removeSubtree))])
    }

    var promoted = document
    _ = try promoted.apply([.page(.init(action: .remove, id: "t", expectedRevision: sectionToken, removal: .promoteChildren))])
    #expect(order(promoted) == ["s", "a", "b", "c", "l"])
    #expect(promoted.pageParentID(for: "b") == "s")
    #expect(promoted.boardItems?["b"]?.task?.status == .doing)
    try promoted.validateEditableShape()

    var removed = document
    _ = try removed.apply([.page(.init(action: .remove, id: "t", expectedSubtreeRevision: subtreeToken, removal: .removeSubtree))])
    #expect(order(removed) == ["s", "a", "c", "l"])
    #expect(removed.boardItems?["b"] == nil && removed.pageNodes?["b"] == nil && removed.pageNodes?["t"] == nil)
    try removed.validateEditableShape()

    // Removing a link only removes the link: the document has no original to touch.
    var unlinked = document
    _ = try unlinked.apply([.page(.init(action: .remove, id: "l", expectedRevision: document.boardItemRevision(for: "l")))])
    #expect(unlinked.canvas?["l"] == nil)
    #expect(throws: NoteEditError.boardItemConflict(id: "l", currentRevision: "")) {
      var copy = unlinked
      _ = try copy.apply([.page(.init(action: .remove, id: "l", expectedRevision: "any"))])
    }
    // An emptied section needs no choice.
    var emptied = removed
    _ = try emptied.apply([.page(.init(action: .remove, id: "a", expectedRevision: removed.boardItemRevision(for: "a")))])
    _ = try emptied.apply([.page(.init(action: .remove, id: "s", expectedRevision: emptied.boardItemRevision(for: "s")))])
    #expect(order(emptied) == ["c", "l"])
  }

  @Test func revisionsTrackTheRightScope() throws {
    let document = sample()
    #expect(document.pageSubtreeRevision(for: "missing") == "")
    #expect(document.pageSubtreeRevision(for: "a") == document.boardItemRevision(for: "a"))
    #expect(document.pageSubtreeRevision(for: "s") != document.boardItemRevision(for: "s"))
    #expect(document.pageSubtreeIDs(of: "s") == ["s", "a", "t", "b"])
    #expect(document.pageDepth(for: "b") == 2)
    // A plain block's token does not cover its place in the Page; a section's does.
    var withoutNodes = document; withoutNodes.pageNodes = nil
    #expect(withoutNodes.boardItemRevision(for: "a") == document.boardItemRevision(for: "a"))
    #expect(withoutNodes.boardItemRevision(for: "s") != document.boardItemRevision(for: "s"))
    var reordered = document
    _ = try reordered.apply([.page(.init(action: .move, id: "a", position: .init(parentID: "s", afterID: "t")))])
    #expect(reordered.pageSubtreeRevision(for: "s") != document.pageSubtreeRevision(for: "s"))
    #expect(reordered.pageSubtreeRevision(for: "t") == document.pageSubtreeRevision(for: "t"))
  }

  @Test func onlyAPageTakesPageEdits() throws {
    #expect(throws: NoteEditError.artifactKindMismatch) {
      var note = NoteDocument()
      try note.applyPageEdit(.init(action: .add, id: "x"))
    }
    #expect(throws: RemoteNoteEditError.operationNotAllowed) {
      try RemoteNoteEditEnvelope.validate(operations: [.page(.init(action: .add, id: "x"))], noteKind: .note)
    }
    #expect(!RemoteNoteEditEnvelope.requiresRevision([.page(.init(action: .update, id: "x"))]))
    #expect(!RemoteNoteEditEnvelope.requiresRevision([.page(.init(action: .move, id: "x"))]))
    #expect(RemoteNoteEditEnvelope.requiresRevision([.page(.init(action: .setPurpose, purpose: "p"))]))
    let edit = NoteEditOperation.page(.init(action: .move, id: "x", expectedSubtreeRevision: "r", position: .init(parentID: "p", afterID: "a", atStart: false), removal: .promoteChildren))
    #expect(try JSONDecoder().decode(NoteEditOperation.self, from: JSONEncoder().encode(edit)) == edit)
    let position = try JSONDecoder().decode(PagePosition.self, from: Data(#"{"parentID":"p"}"#.utf8))
    #expect(position == PagePosition(parentID: "p"))
    var unchanged = plan()
    let copy = unchanged
    _ = try unchanged.apply([.page(.init(action: .requirePage))])
    #expect(unchanged == copy)
    #expect(NoteArtifactKind.canvas.rawValue == "canvas" && NoteArtifactKind.canvas.displayName == "Page")
  }

  @Test func agentBatchesCannotCarryPageEdits() throws {
    try NoteEditOperation.requireGenericNoteOperations([.appendText("Fine", .paragraph)])
    #expect(throws: WorkspaceToolError.self) {
      try NoteEditOperation.requireGenericNoteOperations([.appendText("Fine", .paragraph), .page(.init(action: .requirePage))])
    }
    let nonce = "nonce"
    let envelope = RemoteNoteEditEnvelope(nonce: nonce, noteID: "p", expectedRevision: "r",
      operations: [.page(.init(action: .add, id: "chosen", patch: .init(text: "Bypass")))])
    let content = RemoteNoteEditEnvelope.beginMarker(nonce: nonce) + "\n" + String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
      + "\n" + RemoteNoteEditEnvelope.endMarker(nonce: nonce)
    #expect(throws: RemoteNoteEditError.operationNotAllowed) {
      _ = try RemoteNoteEditEnvelope.extract(from: content, nonce: nonce, noteID: "p", expectedRevision: "r", noteKind: .canvas)
    }
  }

  // MARK: Generic note tools

  @Test func genericToolsKeepTheTreeValid() throws {
    var document = sample()
    func newest(_ before: NoteDocument) -> String {
      let known = Set(before.blocks.map(\.id))
      return document.blocks.first { !known.contains($0.id) }!.id
    }
    // Inside a section it joins that section, and right after a section it opens it.
    var before = document
    _ = try document.apply([.insertText(afterBlockID: "a", text: "After a", style: .paragraph)])
    #expect(document.pageParentID(for: newest(before)) == "s")
    before = document
    _ = try document.apply([.insertText(afterBlockID: "s", text: "After heading", style: .paragraph)])
    #expect(document.pageChildren(of: "s").first == newest(before))
    before = document
    _ = try document.apply([.createTable(afterBlockID: "b", rows: 1, columns: 1, headerRow: false)])
    #expect(document.pageParentID(for: newest(before)) == "t")
    before = document
    _ = try document.apply([.appendText("At the end", .paragraph)])
    #expect(document.pageParentID(for: newest(before)) == nil)
    try document.validateEditableShape()

    #expect(throws: NoteEditError.pageSectionNotEmpty("t")) {
      var copy = document
      _ = try copy.apply([.deleteBlock(id: "t")])
    }
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) {
      var copy = document
      _ = try copy.apply([.replaceBlock(id: "t", block: .table(.init(id: "t", columns: [.init(id: "c")], rows: [.init(id: "r", cells: [.init(id: "x")])])))])
    }
    _ = try document.apply([.deleteBlock(id: "b")])
    #expect(document.pageNodes?["b"] == nil && document.boardItems?["b"] == nil)
    try document.validateEditableShape()

    // A linked original is edited at its asset, never by hiding text in the embed.
    #expect(throws: NoteEditError.boardLinkedAssetText("l")) {
      var copy = document
      _ = try copy.apply([.replaceBlock(id: "l", block: text("l", "Hidden copy"))])
    }

    // A generic insert lands inside the section of the block it follows.
    var nested = plan()
    _ = try nested.apply([.insertText(afterBlockID: "a", text: "Note", style: .paragraph)])
    #expect(nested.pageParentID(for: nested.pageChildren(of: "section").last!) == "section")
    try nested.validateEditableShape()
  }

  // MARK: Merging

  private func merged(_ base: NoteDocument, local: (inout NoteDocument) throws -> Void, remote: (inout NoteDocument) throws -> Void) throws -> PageMerge {
    var l = base, r = base
    try local(&l); try remote(&r)
    let result = try NoteDocument.mergePage(base: base, local: l, remote: r)
    try result.document.validateEditableShape()
    return result
  }
  private func setText(_ id: String, _ value: String, in document: inout NoteDocument) throws {
    let revision = document.boardItemRevision(for: id)
    _ = try document.apply([.page(.init(action: .update, id: id, expectedRevision: revision, patch: .init(text: value)))])
  }
  private func plain(_ document: NoteDocument, _ id: String) -> String? { document.blocks.first { $0.id == id }?.plainText }

  @Test func disjointEditsAndStructureCombine() throws {
    let base = sample()
    let result = try merged(base, local: {
      try setText("a", "Typed locally", in: &$0)
      _ = try $0.apply([.page(.init(action: .add, id: "localNew", patch: .init(text: "New"), position: .init(parentID: "s", afterID: "a")))])
    }, remote: {
      try setText("c", "Agent wrote", in: &$0)
      _ = try $0.apply([.page(.init(action: .update, id: "b", expectedRevision: $0.boardItemRevision(for: "b"), patch: .init(status: .done, outcome: "Done")))])
      _ = try $0.apply([.page(.init(action: .add, id: "remoteNew", patch: .init(text: "Agent"), position: .init()))])
    })
    #expect(result.conflictedIDs.isEmpty && result.conflictCopyIDs.isEmpty)
    #expect(plain(result.document, "a") == "Typed locally")
    #expect(plain(result.document, "c") == "Agent wrote")
    #expect(result.document.boardItems?["b"]?.task?.status == .done)
    #expect(order(result.document) == ["s", "a", "localNew", "t", "b", "c", "l", "remoteNew"])
    #expect(result.document.pageParentID(for: "localNew") == "s")
    #expect(result.document.canvas?["l"]?.assetID == "original")
  }

  @Test func theSameComponentKeepsBothVersionsVisibly() throws {
    let result = try merged(sample(), local: { try setText("a", "Mine", in: &$0) }, remote: { try setText("a", "Theirs", in: &$0) })
    #expect(result.conflictedIDs == ["a"])
    let copy = try #require(result.conflictCopyIDs.first)
    #expect(plain(result.document, "a") == "Theirs")
    #expect(plain(result.document, copy) == "Mine")
    #expect(result.document.pageChildren(of: "s").prefix(2) == ["a", copy])
    #expect(result.document.boardItems?[copy]?.review == .needed)
    #expect(result.document.boardItems?[copy]?.lastChange?.isEmpty == false)
    // The same edit on both sides is not a conflict.
    let same = try merged(sample(), local: { try setText("a", "Same", in: &$0) }, remote: { try setText("a", "Same", in: &$0) })
    #expect(same.conflictedIDs.isEmpty && plain(same.document, "a") == "Same")
  }

  @Test func aRetryNeverDuplicatesItsCopy() throws {
    let base = sample()
    var local = base, remote = base
    try setText("a", "Mine", in: &local)
    try setText("a", "Theirs", in: &remote)
    let first = try NoteDocument.mergePage(base: base, local: local, remote: remote)
    let second = try NoteDocument.mergePage(base: base, local: local, remote: first.document)
    #expect(second.conflictCopyIDs.isEmpty)
    #expect(second.document.blocks.count == first.document.blocks.count)
    #expect(plain(second.document, "a") == "Theirs")
  }

  @Test func differentFieldsOfOneComponentMerge() throws {
    let result = try merged(sample(), local: {
      try setText("b", "Text changed here", in: &$0)
    }, remote: {
      _ = try $0.apply([.page(.init(action: .update, id: "b", expectedRevision: $0.boardItemRevision(for: "b"), patch: .init(status: .done)))])
    })
    #expect(result.conflictedIDs.isEmpty)
    #expect(plain(result.document, "b") == "Text changed here")
    #expect(result.document.boardItems?["b"]?.task?.status == .done)
    let tasks = try merged(sample(), local: {
      _ = try $0.apply([.page(.init(action: .update, id: "b", expectedRevision: $0.boardItemRevision(for: "b"), patch: .init(status: .blocked)))])
    }, remote: {
      _ = try $0.apply([.page(.init(action: .update, id: "b", expectedRevision: $0.boardItemRevision(for: "b"), patch: .init(status: .done)))])
    })
    #expect(tasks.conflictedIDs == ["b"])
    let copy = try #require(tasks.conflictCopyIDs.first)
    #expect(tasks.document.boardItems?["b"]?.task?.status == .done)
    #expect(tasks.document.boardItems?[copy]?.task?.status == .blocked)
  }

  @Test func eachTaskFieldMergesOnItsOwn() throws {
    func patch(_ value: BoardItemPatch) -> (inout NoteDocument) throws -> Void {
      { _ = try $0.apply([.page(.init(action: .update, id: "b", expectedRevision: $0.boardItemRevision(for: "b"), patch: value))]) }
    }
    // A person ticks the task done while an agent records its outcome and details.
    let result = try merged(sample(), local: patch(.init(status: .done)), remote: patch(.init(outcome: "Found the cause", details: "Check the log")))
    #expect(result.conflictedIDs.isEmpty && result.conflictCopyIDs.isEmpty)
    #expect(result.document.boardItems?["b"]?.task == BoardTask(status: .done, outcome: "Found the cause", details: "Check the log"))
    // Two new tasks on one component combine the same way.
    let fresh = try merged(sample(), local: { _ = try $0.apply([.page(.init(action: .update, id: "a", expectedRevision: $0.boardItemRevision(for: "a"), patch: .init(status: .doing)))]) },
      remote: { _ = try $0.apply([.page(.init(action: .update, id: "a", expectedRevision: $0.boardItemRevision(for: "a"), patch: .init(details: "Check the log")))]) })
    #expect(fresh.conflictedIDs.isEmpty)
    #expect(fresh.document.boardItems?["a"]?.task == BoardTask(status: .doing, details: "Check the log"))
    // The same field changed both ways, or a cleared task against an edit, still keeps both versions.
    let outcomes = try merged(sample(), local: patch(.init(outcome: "Mine")), remote: patch(.init(outcome: "Theirs")))
    #expect(outcomes.conflictedIDs == ["b"] && outcomes.conflictCopyIDs.count == 1)
    #expect(outcomes.document.boardItems?["b"]?.task?.outcome == "Theirs")
    let cleared = try merged(sample(), local: patch(.init(clearTask: true)), remote: patch(.init(outcome: "Theirs")))
    #expect(cleared.conflictedIDs == ["b"])
    #expect(cleared.document.boardItems?["b"]?.task?.outcome == "Theirs")
  }

  @Test func mergedSessionLinksStayWithinTheirLimit() throws {
    var base = sample()
    let existing = (0..<(BoardItem.maximumSessions - 2)).map { "base-\($0)" }
    base.boardItems?["b"]?.sessions = existing
    func link(_ ids: [String]) -> (inout NoteDocument) throws -> Void {
      { document in for id in ids { _ = try document.apply([.page(.init(action: .linkSession, id: "b", sessionID: id))]) } }
    }
    let result = try merged(base, local: link(["local-1", "local-2"]), remote: link(["remote-1", "remote-2"]))
    #expect(result.document.boardItems?["b"]?.sessions == existing + ["remote-1", "remote-2"])
    // Below the limit both sides' links are kept.
    let room = try merged(sample(), local: link(["local-1"]), remote: link(["remote-1"]))
    #expect(room.document.boardItems?["b"]?.sessions == ["remote-1", "local-1"])
  }

  @Test func anEditOutlivesADeleteOnTheOtherSide() throws {
    let removeA: (inout NoteDocument) throws -> Void = {
      _ = try $0.apply([.page(.init(action: .remove, id: "a", expectedRevision: $0.boardItemRevision(for: "a")))])
    }
    let localDeletes = try merged(sample(), local: removeA, remote: { try setText("a", "Agent kept writing", in: &$0) })
    #expect(plain(localDeletes.document, "a") == "Agent kept writing")
    #expect(localDeletes.conflictedIDs == ["a"])
    let remoteDeletes = try merged(sample(), local: { try setText("a", "Still typing", in: &$0) }, remote: removeA)
    #expect(plain(remoteDeletes.document, "a") == "Still typing")
    #expect(remoteDeletes.document.pageParentID(for: "a") == "s")
    #expect(remoteDeletes.conflictedIDs == ["a"])
    // A clean delete on either side simply happens.
    #expect(try !order(merged(sample(), local: removeA, remote: { _ in }).document).contains("a"))
    #expect(try !order(merged(sample(), local: { _ in }, remote: removeA).document).contains("a"))
  }

  @Test func movesCombineWithContentEdits() throws {
    let result = try merged(sample(), local: {
      _ = try $0.apply([.page(.init(action: .move, id: "c", position: .init(parentID: "s", atStart: true)))])
    }, remote: { try setText("c", "Edited elsewhere", in: &$0) })
    #expect(result.conflictedIDs.isEmpty)
    #expect(result.document.pageParentID(for: "c") == "s")
    #expect(plain(result.document, "c") == "Edited elsewhere")
    #expect(result.document.pageChildren(of: "s").first == "c")

    let inside = try merged(sample(), local: {
      _ = try $0.apply([.page(.init(action: .move, id: "a", position: .init(parentID: "s", afterID: "t")))])
    }, remote: { _ in })
    #expect(inside.document.pageChildren(of: "s") == ["t", "a"])
  }

  @Test func childrenSurviveASectionRemovedElsewhere() throws {
    let result = try merged(sample(), local: {
      let id = "t"
      _ = try $0.apply([.page(.init(action: .remove, id: id, expectedSubtreeRevision: $0.pageSubtreeRevision(for: id), removal: .removeSubtree))])
    }, remote: {
      _ = try $0.apply([.page(.init(action: .add, id: "lateChild", patch: .init(text: "Added late"), position: .init(parentID: "t")))])
    })
    #expect(plain(result.document, "lateChild") == "Added late")
    #expect(result.document.pageParentID(for: "lateChild") == "s")
    #expect(!order(result.document).contains("t") && !order(result.document).contains("b"))
  }

  @Test func opposingMovesCannotFormACycleOrLoseAnything() throws {
    let base = page([text("x", "X"), text("y", "Y"), text("child", "C")],
      nodes: ["x": .init(isSection: true), "y": .init(isSection: true), "child": .init(parentID: "y")])
    let result = try merged(base, local: {
      _ = try $0.apply([.page(.init(action: .move, id: "x", position: .init(parentID: "y")))])
    }, remote: {
      _ = try $0.apply([.page(.init(action: .move, id: "y", position: .init(parentID: "x")))])
    })
    #expect(Set(order(result.document)) == ["x", "y", "child"])
    #expect(plain(result.document, "child") == "C")
  }

  @Test func purposesMerge() throws {
    let result = try merged(plan(), local: {
      _ = try $0.apply([.page(.init(action: .setPurpose, purpose: "Local purpose"))])
    }, remote: {
      _ = try $0.apply([.page(.init(action: .setPurpose, purpose: "Remote purpose"))])
    })
    #expect(result.document.boardPurpose == "Remote purpose")
    let copy = try #require(result.conflictCopyIDs.first)
    #expect(plain(result.document, copy) == "Local purpose")
    #expect(throws: NoteEditError.artifactKindMismatch) {
      _ = try NoteDocument.mergePage(base: NoteDocument(), local: plan(), remote: plan())
    }
  }

  @Test func aTableConflictCopyHasFreshIDs() throws {
    let table = NoteTableBlock(id: "grid", columns: [.init(id: "col")], rows: [.init(id: "row", cells: [.init(id: "cell", text: "Base")])])
    let base = page([.table(table)])
    func edited(_ value: String) -> (inout NoteDocument) throws -> Void {
      { _ = try $0.apply([.setTableCell(tableID: "grid", row: 0, column: 0, runs: [.init(text: value)])]) }
    }
    let result = try merged(base, local: edited("Mine"), remote: edited("Theirs"))
    let copy = try #require(result.conflictCopyIDs.first)
    #expect(plain(result.document, "grid") == "Theirs")
    #expect(plain(result.document, copy) == "Mine")
  }

  // MARK: Assignees

  private func agent(_ id: String, state: BoardTaskAssignee.State = .assigned) -> BoardTaskAssignee {
    BoardTaskAssignee(id: id, kind: .agent, name: "Claude Code", place: "Studio", workspaceID: "w1", runtime: "claude_code", state: state)
  }

  @Test func assigningIsIdempotentAndStoppingFollowsTheAssigneesState() throws {
    var document = page([text("t", "Write the email")])
    try document.applyPageEdit(.init(action: .assign, id: "t", assignee: agent("one")))
    #expect(document.pageComponentKind(for: "t") == .task)
    // The same request again, or the same agent in the same place, adds nobody.
    try document.applyPageEdit(.init(action: .assign, id: "t", assignee: agent("one")))
    try document.applyPageEdit(.init(action: .assign, id: "t", assignee: agent("two")))
    #expect(document.boardItems?["t"]?.task?.assignees.map(\.id) == ["one"])
    let conversation = try #require(document.boardItems?["t"]?.task?.assignees.first?.conversationID)
    #expect(conversation == BoardTaskAssignee.conversationID(for: "one") && UUID(uuidString: conversation) != nil)
    var bot = BoardTaskAssignee(id: "bot", kind: .bot, name: "Research", botID: "b", machineID: "m", state: .sending)
    try document.applyPageEdit(.init(action: .assign, id: "t", assignee: bot))
    // Not sent yet: stopping unassigns. Working: stopping asks its chat to stop, and it stays listed.
    try document.applyPageEdit(.init(action: .stopAssignee, id: "t", assigneeID: "one"))
    #expect(document.boardItems?["t"]?.task?.assignees.map(\.id) == ["bot"])
    try document.applyPageEdit(.init(action: .stopAssignee, id: "t", assigneeID: "bot"))
    #expect(document.boardItems?["t"]?.task?.assignees.first?.state == .stopping)
    bot.state = .stopped; bot.conversationID = "7"
    try document.applyPageEdit(.init(action: .updateAssignee, id: "t", assignee: bot))
    #expect(document.boardItems?["t"]?.task?.assignees.first?.conversationID == "7")
    #expect(throws: NoteEditError.self) { try document.applyPageEdit(.init(action: .stopAssignee, id: "t", assigneeID: "missing")) }
    try document.validateEditableShape()
    // A section is not a task, and an image is not one either.
    var sectioned = page([text("s", "S", style: .heading2)], nodes: ["s": .init(isSection: true)])
    #expect(throws: NoteEditError.self) { try sectioned.applyPageEdit(.init(action: .assign, id: "s", assignee: agent("x"))) }
  }

  @Test func assigneesMergeOneByOneAndLaterStatesWin() throws {
    let base = page([text("t", "Task")], items: ["t": .init(task: .init(assignees: [agent("a", state: .sending)]))])
    var local = base, remote = base
    local.boardItems?["t"]?.task?.assignees.append(agent("b"))
    local.boardItems?["t"]?.task?.status = .done
    remote.boardItems?["t"]?.task?.assignees[0].state = .sent
    remote.boardItems?["t"]?.task?.outcome = "Drafted"
    let merged = try NoteDocument.mergePage(base: base, local: local, remote: remote)
    #expect(merged.conflictCopyIDs.isEmpty)
    let task = try #require(merged.document.boardItems?["t"]?.task)
    #expect(task.assignees.map(\.id) == ["a", "b"] && task.assignees[0].state == .sent)
    #expect(task.status == .done && task.outcome == "Drafted")
    // Both changed one assignee: the later state stays.
    var stopping = base, sent = base
    stopping.boardItems?["t"]?.task?.assignees[0].state = .stopping
    sent.boardItems?["t"]?.task?.assignees[0].state = .sent
    let raced = try NoteDocument.mergePage(base: base, local: stopping, remote: sent)
    #expect(raced.document.boardItems?["t"]?.task?.assignees.first?.state == .stopping)
  }

  @Test func aSlowSenderNeverOverwritesANewerStateOrForgetsAThread() throws {
    var document = page([text("t", "Write the email")])
    var bot = BoardTaskAssignee(id: "bot", kind: .bot, name: "Research", botID: "b", machineID: "m", state: .sending)
    try document.applyPageEdit(.init(action: .assign, id: "t", assignee: bot))
    // The person stops it while the sender is still working from what it read.
    try document.applyPageEdit(.init(action: .stopAssignee, id: "t", assigneeID: "bot"))
    var sent = bot
    sent.state = .sent; sent.conversationID = "7"
    #expect(throws: NoteEditError.self) {
      try document.applyPageEdit(.init(action: .updateAssignee, id: "t", assignee: sent, expectedAssigneeState: .sending))
    }
    #expect(document.boardItems?["t"]?.task?.assignees.first?.state == .stopping)
    // A write without a thread number keeps the one already recorded.
    bot.state = .stopping; bot.conversationID = "7"
    try document.applyPageEdit(.init(action: .updateAssignee, id: "t", assignee: bot))
    var stopped = bot
    stopped.state = .stopped; stopped.conversationID = nil
    try document.applyPageEdit(.init(action: .updateAssignee, id: "t", assignee: stopped, expectedAssigneeState: .stopping))
    let assignee = try #require(document.boardItems?["t"]?.task?.assignees.first)
    #expect(assignee.state == .stopped && assignee.conversationID == "7")
    // Two replicas: one knows the thread, the other a later state.
    let research = BoardTaskAssignee(id: "a", kind: .bot, name: "Research", botID: "b", machineID: "m", state: .sending)
    let base = page([text("t", "Task")], items: ["t": .init(task: .init(assignees: [research]))])
    var withThread = base, withStop = base
    withThread.boardItems?["t"]?.task?.assignees[0].state = .sent
    withThread.boardItems?["t"]?.task?.assignees[0].conversationID = "thread"
    withStop.boardItems?["t"]?.task?.assignees[0].state = .stopping
    withStop.boardItems?["t"]?.task?.assignees[0].conversationID = nil
    let merged = try NoteDocument.mergePage(base: base, local: withThread, remote: withStop)
    let mergedAssignee = try #require(merged.document.boardItems?["t"]?.task?.assignees.first)
    #expect(mergedAssignee.state == .stopping && mergedAssignee.conversationID == "thread")
  }

  @Test func whoAssignedSomeoneIsStampedOnce() throws {
    let old = page([text("t", "Task")], items: ["t": .init(task: .init())])
    var new = old
    new.boardItems?["t"]?.task?.assignees = [agent("a")]
    let session = BoardActor(kind: .session, sessionID: "s1", label: "Planner")
    new.stampBoardChanges(from: old, actor: session, at: "2026-11-17T10:00:00Z")
    #expect(new.boardItems?["t"]?.task?.assignees.first?.assignedBy == session)
    var later = new
    later.boardItems?["t"]?.task?.status = .done
    later.stampBoardChanges(from: new, actor: BoardActor(kind: .user), at: "2026-11-17T11:00:00Z")
    #expect(later.boardItems?["t"]?.task?.assignees.first?.assignedBy == session)
    #expect(later.boardItems?["t"]?.task?.assignees.first?.assignedAt == "2026-11-17T10:00:00Z")
  }

  @Test func anImageIsAddedWholeAndDescribedWithoutItsBytes() throws {
    var document = page([])
    let image = PageImage(mediaType: "image/png", bytes: Data(repeating: 7, count: 32), alt: "Sketch", width: 4, height: 2)
    try document.applyPageEdit(.init(action: .add, id: "i", kind: .image, image: image))
    #expect(document.canvas?["i"]?.image == image)
    #expect(throws: NoteEditError.self) {
      try document.applyPageEdit(.init(action: .update, id: "i", expectedRevision: document.boardItemRevision(for: "i"), patch: .init(text: "x")))
    }
    let value = try document.pageComponentValue(id: "i")
    #expect(value.objectValue?["kind"]?.stringValue == "image")
    #expect(value.objectValue?["image"]?.objectValue?["bytes"]?.doubleValue == 32)
    var tooLarge = page([])
    let large = PageImage(mediaType: "image/png", bytes: Data(repeating: 1, count: PageImage.maximumBytes + 10))
    #expect(throws: (any Error).self) { try tooLarge.applyPageEdit(.init(action: .add, id: "big", kind: .image, image: large)) }
  }
}
