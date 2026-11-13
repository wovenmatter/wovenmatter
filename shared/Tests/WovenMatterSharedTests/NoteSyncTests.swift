import Foundation
import Testing
@testable import WovenMatterShared

/// One library replica as the store sees it: a Lamport counter, a causal vector, and the
/// stored row with the record that wrote it.
private struct Replica {
  let id: String
  var vector: [String: Int64] = [:]
  var tick: Int64 = 0
  var stored: (content: String, title: String, folderID: String?)?
  var record: NoteSyncDot?

  init(_ id: String) { self.id = id }

  var document: NoteDocument { NoteDocument.decode(stored!.content) }

  mutating func write(_ document: NoteDocument, title: String? = nil, folderID: String?? = nil) throws -> NoteSync.Version {
    tick += 1
    vector[id] = tick
    let title = title ?? stored?.title ?? "Plan", folder = folderID ?? stored?.folderID
    let content = NoteSync.stamp(content: try document.encoded(), title: title, folderID: folder, previous: stored, previousRecord: record)
    stored = (content, title, folder)
    record = .init(r: id, n: tick)
    return .init(content: content, title: title, folderID: folder, origin: id, clock: tick, vector: vector)
  }

  mutating func edit(_ change: (inout NoteDocument) throws -> Void) throws -> NoteSync.Version {
    var page = document
    try change(&page)
    return try write(page)
  }

  mutating func see(_ version: NoteSync.Version) {
    vector.merge(version.vector) { max($0, $1) }
    tick = max(tick, version.clock)
  }

  /// A version that supersedes everything stored here.
  mutating func receive(_ version: NoteSync.Version) {
    see(version)
    stored = (version.content, version.title, version.folderID)
    record = .init(r: version.origin, n: version.clock)
  }

  /// Concurrent versions, materialized as their merge; the winner stays the stored record.
  @discardableResult
  mutating func settle(_ versions: [NoteSync.Version]) throws -> NoteSync.Merged {
    let merged = try #require(NoteSync.merge(versions))
    for version in versions { see(version) }
    stored = (merged.content, merged.title, merged.folderID)
    record = .init(r: versions[0].origin, n: versions[0].clock)
    return merged
  }
}

private func page(_ texts: [(String, String)], purpose: String? = nil) -> NoteDocument {
  NoteDocument(kind: .canvas, blocks: texts.map { .richText(.init(id: $0.0, text: $0.1)) }, boardPurpose: purpose, pageNodes: [:])
}

private func update(_ id: String, _ text: String) -> (inout NoteDocument) throws -> Void {
  { page in try page.applyPageEdit(.init(action: .update, id: id, expectedRevision: page.boardItemRevision(for: id), patch: .init(text: text))) }
}

private func texts(_ content: String) -> [String] { NoteDocument.decode(content).blocks.map(\.plainText) }

@Suite("Replica Page and Artifact merge")
struct NoteSyncTests {
  /// Two replicas start from the same Page.
  private func pair(_ start: NoteDocument) throws -> (Replica, Replica) {
    var mac = Replica("A"), linux = Replica("B")
    let first = try mac.write(start)
    linux.receive(first)
    return (mac, linux)
  }

  @Test func clocksStayOutOfEverythingButTheStore() throws {
    var mac = Replica("A")
    let version = try mac.write(page([("a", "one")]))
    #expect(version.content.hasSuffix("}") && version.content.contains(#""~sync":"#))
    let body = NoteSync.strip(version.content)
    #expect(!body.contains("~sync"))
    #expect(NoteSync.split(version.content).clock?["c:a"] == NoteSyncDot(r: nil, n: 0))
    #expect(try NoteDocument.editableDocument(from: version.content) == NoteDocument.decode(body))
    // Notes and Sheets carry no clocks; a client cannot supply any.
    let note = try NoteDocument(kind: .note, blocks: [.richText(.init(id: "n", text: "hi"))]).encoded()
    #expect(NoteSync.stamp(content: note, title: "N", folderID: nil, previous: nil, previousRecord: nil) == note)
    #expect(NoteSync.stamp(content: version.content, title: "Plan", folderID: nil, previous: nil, previousRecord: nil).contains("~sync"))
    #expect(NoteSync.strip(NoteSync.stamp(content: version.content, title: "Plan", folderID: nil, previous: nil, previousRecord: nil)) == body)
  }

  @Test func changesToDifferentComponentsCombineInEitherOrder() throws {
    var (mac, linux) = try pair(page([("a", "one"), ("b", "two"), ("c", "three")]))
    let fromMac = try mac.edit(update("a", "one from the Mac"))
    let fromLinux = try linux.edit(update("c", "three from Linux"))
    for order in [[fromMac, fromLinux], [fromLinux, fromMac]] {
      let merged = try #require(NoteSync.merge(order))
      #expect(texts(merged.content) == ["one from the Mac", "two", "three from Linux"])
      #expect(!NoteDocument.decode(merged.content).blocks.contains { $0.id.hasPrefix("conflict-") })
    }
  }

  @Test func bothVersionsOfOneComponentStay() throws {
    var (mac, linux) = try pair(page([("a", "one"), ("b", "two")]))
    let fromMac = try mac.edit(update("a", "Mac wording"))
    let fromLinux = try linux.edit(update("a", "Linux wording"))
    let merged = try #require(NoteSync.merge([fromMac, fromLinux]))
    let document = NoteDocument.decode(merged.content)
    #expect(texts(merged.content) == ["Mac wording", "Linux wording", "two"])
    let copy = try #require(document.blocks.first { $0.id.hasPrefix("conflict-") })
    #expect(document.boardItems?[copy.id]?.review == .needed)
    // The copy counts as seen only where both conflicting changes were.
    let dot = try #require(NoteSync.split(merged.content).clock?["c:" + copy.id])
    #expect(dot.r == fromLinux.origin && dot.n == fromLinux.clock)
    #expect(dot.a?.contains { $0.r == fromMac.origin && $0.n == fromMac.clock } == true)
  }

  @Test func aRemovalStandsUnlessTheOtherSideChangedIt() throws {
    var (mac, linux) = try pair(page([("a", "one"), ("b", "two"), ("c", "three")]))
    let fromMac = try mac.edit { page in
      try page.applyPageEdit(.init(action: .remove, id: "a", expectedRevision: page.boardItemRevision(for: "a")))
      try page.applyPageEdit(.init(action: .remove, id: "b", expectedRevision: page.boardItemRevision(for: "b")))
    }
    let fromLinux = try linux.edit(update("b", "two, kept"))
    let merged = try #require(NoteSync.merge([fromLinux, fromMac]))
    #expect(texts(merged.content) == ["two, kept", "three"])
    let again = try #require(NoteSync.merge([fromMac, fromLinux]))
    #expect(texts(again.content) == ["two, kept", "three"])
  }

  @Test func newComponentsFromBothSidesStay() throws {
    var (mac, linux) = try pair(page([("a", "one")]))
    let fromMac = try mac.edit { try $0.applyPageEdit(.init(action: .add, id: "m", kind: .task, patch: .init(text: "Mac task"), position: .init(afterID: "a"))) }
    let fromLinux = try linux.edit { try $0.applyPageEdit(.init(action: .add, id: "l", kind: .text, patch: .init(text: "Linux note"), position: .init(atStart: true))) }
    let merged = try #require(NoteSync.merge([fromMac, fromLinux]))
    #expect(texts(merged.content) == ["Linux note", "one", "Mac task"])
  }

  @Test func aMoveAndAnEditOfOneComponentBothApply() throws {
    var start = page([("a", "one"), ("b", "two")])
    try start.applyPageEdit(.init(action: .add, id: "s", kind: .section, patch: .init(text: "Section"), position: .init(afterID: "b")))
    var (mac, linux) = try pair(start)
    let fromMac = try mac.edit { page in
      try page.applyPageEdit(.init(action: .move, id: "a", expectedRevision: page.boardItemRevision(for: "a"), position: .init(parentID: "s")))
    }
    let fromLinux = try linux.edit(update("a", "one, edited"))
    for order in [[fromMac, fromLinux], [fromLinux, fromMac]] {
      let document = NoteDocument.decode(try #require(NoteSync.merge(order)).content)
      #expect(document.pageNodes?["a"]?.parentID == "s")
      #expect(document.blocks.first { $0.id == "a" }?.plainText == "one, edited")
      #expect(!document.blocks.contains { $0.id.hasPrefix("conflict-") })
    }
  }

  @Test func titlesPurposesAndTaskFieldsMergeOnTheirOwn() throws {
    var start = page([("a", "one")], purpose: "Plan the launch")
    try start.applyPageEdit(.init(action: .add, id: "t", kind: .task, patch: .init(text: "Ship it"), position: .init(afterID: "a")))
    var (mac, linux) = try pair(start)
    var renamed = mac.document
    try update("t", "Ship it Friday")(&renamed)
    let fromMac = try mac.write(renamed, title: "Launch plan")
    let fromLinux = try linux.edit { page in
      page.boardPurpose = "Plan the launch and the follow-up"
      try page.applyPageEdit(.init(action: .update, id: "t", expectedRevision: page.boardItemRevision(for: "t"), patch: .init(status: .done)))
    }
    let merged = try #require(NoteSync.merge([fromLinux, fromMac]))
    let document = NoteDocument.decode(merged.content)
    #expect(merged.title == "Launch plan")
    #expect(document.boardPurpose == "Plan the launch and the follow-up")
    #expect(document.blocks.first { $0.id == "t" }?.plainText == "Ship it Friday")
    #expect(document.boardItems?["t"]?.task?.status == .done)
    #expect(!document.blocks.contains { $0.id.hasPrefix("conflict-") })
  }

  @Test func threeReplicasConvergeOnEveryChange() throws {
    var mac = Replica("A"), linux = Replica("B"), laptop = Replica("C")
    let first = try mac.write(page([("a", "one"), ("b", "two"), ("c", "three")]))
    linux.receive(first); laptop.receive(first)
    let versions = [try mac.edit(update("a", "A")), try linux.edit(update("b", "B")), try laptop.edit(update("c", "C"))]
    let merged = try #require(NoteSync.merge(versions))
    #expect(texts(merged.content) == ["A", "B", "C"])
    #expect(NoteSync.merge([versions[0], versions[1], versions[2]]) == merged)
  }

  @Test func laterWritesBuildOnTheMergeWithoutReviving() throws {
    var (mac, linux) = try pair(page([("a", "one"), ("b", "two"), ("c", "three")]))
    let fromMac = try mac.edit(update("a", "Mac wording"))
    let fromLinux = try linux.edit(update("a", "Linux wording"))
    try mac.settle([fromMac, fromLinux])
    let copyID = try #require(mac.document.blocks.first { $0.id.hasPrefix("conflict-") }?.id)
    // The Mac reviews the copy and removes it, while Linux, which has not seen the merge,
    // goes on editing another component.
    let reviewed = try mac.edit { page in
      try page.applyPageEdit(.init(action: .remove, id: copyID, expectedRevision: page.boardItemRevision(for: copyID)))
    }
    let later = try linux.edit(update("c", "three from Linux"))
    let merged = try #require(NoteSync.merge([reviewed, later]))
    #expect(texts(merged.content) == ["Mac wording", "two", "three from Linux"])
    // Linux's earlier wording was reviewed away on the Mac, and does not come back.
    let again = try #require(NoteSync.merge([later, reviewed]))
    #expect(texts(again.content) == ["Mac wording", "two", "three from Linux"])
  }

  @Test func aCopyThatNoOneReviewedSurvivesLaterWrites() throws {
    var (mac, linux) = try pair(page([("a", "one"), ("b", "two")]))
    let fromMac = try mac.edit(update("a", "Mac wording"))
    let fromLinux = try linux.edit(update("a", "Linux wording"))
    try mac.settle([fromMac, fromLinux])
    let afterMerge = try mac.edit(update("b", "two from the Mac"))
    let later = try linux.edit(update("b", "two from Linux"))
    let merged = NoteDocument.decode(try #require(NoteSync.merge([afterMerge, later])).content)
    #expect(merged.blocks.map(\.plainText).contains("Linux wording"))
    #expect(merged.blocks.map(\.plainText).contains("two from Linux"))
    #expect(merged.blocks.map(\.plainText).contains("two from the Mac"))
  }

  @Test func artifactInputsMergeKeyByKey() throws {
    let original = NoteDocument(kind: .html, html: "<input id=a><input id=b>")
    func artifact(_ state: [String: ArtifactStateEntry], html: String? = nil) -> NoteDocument {
      var document = original
      if let html { document.html = html }
      document.artifactState = state.isEmpty ? nil : state
      return document
    }
    let at = "2026-11-13T00:00:00Z"
    var mac = Replica("A"), linux = Replica("B")
    linux.receive(try mac.write(artifact(["form:a": .init(value: .string("1"), version: 1, updatedAt: at)])))
    let fromMac = try mac.write(artifact(["form:a": .init(value: .string("1"), version: 1, updatedAt: at),
                                          "form:b": .init(value: .string("Mac"), version: 1, updatedAt: at)]))
    let fromLinux = try linux.write(artifact(["form:a": .init(value: .string("Linux"), version: 2, updatedAt: at)]))
    let merged = NoteDocument.decode(try #require(NoteSync.merge([fromMac, fromLinux])).content)
    #expect(merged.artifactState?["form:a"]?.value == .string("Linux"))
    #expect(merged.artifactState?["form:b"]?.value == .string("Mac"))

    let sameKeyMac = try mac.write(artifact(["form:a": .init(value: .string("Mac again"), version: 2, updatedAt: at)]))
    let sameKeyLinux = try linux.write(artifact(["form:a": .init(value: .string("Linux again"), version: 3, updatedAt: at)]))
    let both = NoteDocument.decode(try #require(NoteSync.merge([sameKeyMac, sameKeyLinux])).content)
    #expect(both.artifactState?["form:a"]?.value == .string("Linux again"))
    #expect(both.artifactState?["form:a"]?.version == 4)

    let newCode = try mac.write(artifact([:], html: "<p>Mac</p>"))
    let otherCode = try linux.write(artifact([:], html: "<p>Linux</p>"))
    #expect(NoteSync.merge([newCode, otherCode]) == nil)
  }

  @Test func notesAndVersionsWithoutClocksKeepWholeDocuments() throws {
    let note = try NoteDocument(kind: .note, blocks: [.richText(.init(id: "n", text: "hi"))]).encoded()
    let legacy = try page([("a", "one")]).encoded()
    let stamped = NoteSync.stamp(content: legacy, title: "Plan", folderID: nil, previous: nil, previousRecord: nil)
    func version(_ content: String, _ origin: String) -> NoteSync.Version {
      .init(content: content, title: "Plan", folderID: nil, origin: origin, clock: 2, vector: [origin: 2])
    }
    #expect(NoteSync.merge([version(note, "A"), version(note, "B")]) == nil)
    #expect(NoteSync.merge([version(legacy, "A"), version(stamped, "B")]) == nil)
    #expect(NoteSync.merge([version(stamped, "A")]) == nil)
  }
}
