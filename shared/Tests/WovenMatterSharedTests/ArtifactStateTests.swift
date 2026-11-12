import Foundation
import Testing
@testable import WovenMatterShared

@Suite("Artifact state")
struct ArtifactStateTests {
  private let time = "2026-11-06T00:00:00Z"
  private func artifact() -> NoteDocument { NoteDocument(kind: .html, html: "<input id=\"name\">") }
  private func set(_ key: String, _ value: GatewayJSONValue, expected: Int? = nil) -> ArtifactStateEdit {
    ArtifactStateEdit(action: .set, key: key, value: value, expectedVersion: expected)
  }

  @Test func nullsDoublesAndTombstonesSurviveEveryRoundTrip() throws {
    var document = artifact()
    try document.applyArtifactStateEdits([
      set("app:null", .null),
      set("app:fraction", .number(0.1)),
      set("app:big", .number(1e300)),
      set("app:nested", .object(["list": .array([.null, .bool(true), .number(-2.5), .string("é\n\"quote\"")])])),
      set("app:gone", .string("soon")),
    ], at: time)
    try document.applyArtifactStateEdits([.init(action: .remove, key: "app:gone", expectedVersion: 1)], at: time)

    let encoded = try document.encoded()
    // Older builds read this as an unknown field, so editable decoding must keep exact fidelity.
    let reopened = try NoteDocument.editableDocument(from: encoded)
    #expect(reopened == document.normalized())
    #expect(reopened.artifactState?["app:null"]?.value == .null)
    #expect(reopened.artifactState?["app:null"]?.isTombstone == false)
    #expect(reopened.artifactState?["app:fraction"]?.value == .number(0.1))
    #expect(reopened.artifactState?["app:big"]?.value == .number(1e300))
    #expect(reopened.artifactState?["app:gone"]?.value == nil)
    #expect(reopened.artifactState?["app:gone"]?.isTombstone == true)
    #expect(reopened.artifactState?["app:gone"]?.version == 2)
    // A second pass is byte-stable, so no-op comparisons cannot be fooled by formatting.
    #expect(try reopened.encoded() == encoded)
    let raw = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
    let state = try #require(raw["artifactState"] as? [String: [String: Any]])
    #expect(state["app:gone"]?["value"] == nil)
    #expect(state["app:null"]?["value"] is NSNull)
  }

  @Test func wireEditsTellNullFromMissing() throws {
    func edit(_ json: String) throws -> ArtifactStateEdit { try JSONDecoder().decode(ArtifactStateEdit.self, from: Data(json.utf8)) }
    #expect(try edit(#"{"action":"set","key":"app:x","value":null}"#).value == .null)
    #expect(try edit(#"{"action":"remove","key":"app:x"}"#).value == nil)
    // A bridge may send an explicit null for a key it has never seen.
    #expect(try edit(#"{"action":"set","key":"app:x","value":1,"expectedVersion":null}"#).expectedVersion == nil)
    #expect(try edit(#"{"action":"set","key":"app:x","value":1,"expectedVersion":3}"#).expectedVersion == 3)
    for original in [set("app:x", .null, expected: 2), ArtifactStateEdit(action: .remove, key: "app:x")] {
      let operation = NoteEditOperation.artifactState([original])
      #expect(try JSONDecoder().decode(NoteEditOperation.self, from: JSONEncoder().encode(operation)) == operation)
    }
  }

  @Test func eachKeyCompareAndSwapsIndependently() throws {
    var document = artifact()
    // A new key requires that nothing is there.
    let created = try document.applyArtifactStateEdits([set("form:a", .string("one"))], at: time)
    #expect(created)
    #expect(document.artifactState?["form:a"]?.version == 1)
    #expect(document.artifactState?["form:a"]?.updatedAt == time)
    let held = document
    #expect(throws: ArtifactStateError.conflict(key: "form:a", current: held.artifactState?["form:a"])) {
      var copy = held
      try copy.applyArtifactStateEdits([set("form:a", .string("other"))], at: time)
    }
    #expect(throws: ArtifactStateError.conflict(key: "form:a", current: held.artifactState?["form:a"])) {
      var copy = held
      try copy.applyArtifactStateEdits([set("form:a", .string("other"), expected: 7)], at: time)
    }
    #expect(throws: ArtifactStateError.conflict(key: "app:never", current: nil)) {
      var copy = held
      try copy.applyArtifactStateEdits([set("app:never", .string("x"), expected: 1)], at: time)
    }
    // Another key neither conflicts nor changes this one's version.
    try document.applyArtifactStateEdits([set("form:b", .bool(true))], at: "later")
    try document.applyArtifactStateEdits([set("form:a", .string("two"), expected: 1)], at: "later")
    #expect(document.artifactState?["form:a"]?.version == 2)
    #expect(document.artifactState?["form:b"]?.version == 1)
    #expect(document.artifactState?["form:a"]?.updatedAt == "later")
  }

  @Test func aRemovedKeyKeepsItsVersionAndCannotBeTakenByAStaleWriter() throws {
    var document = artifact()
    try document.applyArtifactStateEdits([set("app:x", .number(1))], at: time)
    try document.applyArtifactStateEdits([.init(action: .remove, key: "app:x", expectedVersion: 1)], at: time)
    let removed = document
    #expect(removed.artifactStateSnapshot.values["app:x"] == nil)
    #expect(removed.artifactStateSnapshot.versions["app:x"] == 2)
    // A tombstone is an entry, so "absent" no longer holds.
    #expect(throws: ArtifactStateError.conflict(key: "app:x", current: removed.artifactState?["app:x"])) {
      var copy = removed
      try copy.applyArtifactStateEdits([set("app:x", .number(9))], at: time)
    }
    try document.applyArtifactStateEdits([set("app:x", .number(9), expected: 2)], at: time)
    #expect(document.artifactState?["app:x"]?.version == 3)
    #expect(document.artifactStateSnapshot.values["app:x"] == .number(9))
  }

  @Test func repeatedOutcomesChangeNothing() throws {
    var document = artifact()
    try document.applyArtifactStateEdits([set("app:x", .string("v"))], at: time)
    let before = document
    // A retry after a lost acknowledgement must not look like a conflict or a new version.
    let retried = try document.applyArtifactStateEdits([set("app:x", .string("v"))], at: "later")
    let staleRetry = try document.applyArtifactStateEdits([set("app:x", .string("v"), expected: 40)], at: "later")
    let removedAbsent = try document.applyArtifactStateEdits([.init(action: .remove, key: "app:absent")], at: "later")
    #expect(!retried && !staleRetry && !removedAbsent)
    #expect(document == before)
    try document.applyArtifactStateEdits([.init(action: .remove, key: "app:x", expectedVersion: 1)], at: time)
    let removed = document
    let removedAgain = try document.applyArtifactStateEdits([.init(action: .remove, key: "app:x", expectedVersion: 1)], at: "later")
    #expect(!removedAgain)
    #expect(document == removed)
  }

  @Test func aBatchIsAllOrNothing() throws {
    var document = artifact()
    try document.applyArtifactStateEdits([set("app:x", .number(1))], at: time)
    let before = document
    #expect(throws: ArtifactStateError.self) {
      try document.applyArtifactStateEdits([set("app:y", .number(2)), set("app:x", .number(3))], at: time)
    }
    #expect(document == before)
  }

  @Test func limitsRejectBeforeAccepting() throws {
    for key in ["", "app:", "form:", "plain", "state:x", "app:\u{0}x", "app:new\nline", "app:" + String(repeating: "k", count: ArtifactStateLimits.maximumKeyBytes)] {
      #expect(throws: ArtifactStateError.invalidKey(key)) {
        var copy = artifact()
        try copy.applyArtifactStateEdits([set(key, .null)], at: time)
      }
    }
    #expect(throws: ArtifactStateError.valueTooLarge("app:big")) {
      var copy = artifact()
      try copy.applyArtifactStateEdits([set("app:big", .string(String(repeating: "x", count: ArtifactStateLimits.maximumValueBytes)))], at: time)
    }
    #expect(throws: ArtifactStateError.self) {
      var copy = artifact()
      try copy.applyArtifactStateEdits([set("app:nan", .number(.nan))], at: time)
    }
    #expect(throws: ArtifactStateError.self) {
      var copy = artifact()
      try copy.applyArtifactStateEdits([set("app:inf", .array([.number(.infinity)]))], at: time)
    }
    var deep = GatewayJSONValue.null
    for _ in 0...ArtifactStateLimits.maximumDepth { deep = .array([deep]) }
    #expect(throws: ArtifactStateError.self) {
      var copy = artifact()
      try copy.applyArtifactStateEdits([set("app:deep", deep)], at: time)
    }
    #expect(throws: ArtifactStateError.self) {
      var copy = artifact()
      let many = GatewayJSONValue.array(Array(repeating: .null, count: ArtifactStateLimits.maximumNodes + 1))
      try copy.applyArtifactStateEdits([set("app:many", many)], at: time)
    }
    #expect(throws: ArtifactStateError.self) {
      var copy = artifact()
      try copy.applyArtifactStateEdits([set("app:field", .object([String(repeating: "f", count: ArtifactStateLimits.maximumObjectKeyBytes + 1): .null]))], at: time)
    }
    #expect(throws: ArtifactStateError.invalidEdit("Setting Artifact state requires a value.")) {
      var copy = artifact()
      try copy.applyArtifactStateEdits([.init(action: .set, key: "app:x")], at: time)
    }
    #expect(throws: ArtifactStateError.self) {
      var copy = artifact()
      try copy.applyArtifactStateEdits([.init(action: .remove, key: "app:x", value: .null)], at: time)
    }
    #expect(throws: ArtifactStateError.self) {
      var copy = artifact()
      try copy.applyArtifactStateEdits([set("app:x", .null, expected: 0)], at: time)
    }

    var full = artifact()
    try full.applyArtifactStateEdits((0..<ArtifactStateLimits.maximumKeys).map { set("app:\($0)", .number(Double($0))) }, at: time)
    #expect(throws: ArtifactStateError.tooManyKeys) {
      var copy = full
      try copy.applyArtifactStateEdits([set("app:one-more", .null)], at: time)
    }
    // Replacing a value and freeing a key both still work at the limit.
    try full.applyArtifactStateEdits([set("app:0", .string("changed"), expected: 1)], at: time)
    try full.applyArtifactStateEdits([.init(action: .remove, key: "app:1", expectedVersion: 1)], at: time)
    try full.applyArtifactStateEdits([set("app:one-more", .null)], at: time)

    var heavy = artifact()
    let chunk = String(repeating: "x", count: 60 * 1_024)
    try heavy.applyArtifactStateEdits((0..<4).map { set("app:\($0)", .string(chunk)) }, at: time)
    #expect(throws: ArtifactStateError.stateTooLarge) {
      var copy = heavy
      try copy.applyArtifactStateEdits([set("app:last", .string(chunk))], at: time)
    }
  }

  @Test func tombstonesYieldBeforeLiveDataAndStaleWritersStillFail() throws {
    var document = artifact()
    for index in 0...ArtifactStateLimits.maximumTombstones {
      try document.applyArtifactStateEdits([set("app:\(index)", .null)], at: String(format: "T%04d", index))
      try document.applyArtifactStateEdits([.init(action: .remove, key: "app:\(index)", expectedVersion: 1)], at: String(format: "T%04d", index))
    }
    try document.validateArtifactState()
    #expect(document.artifactState?.count == ArtifactStateLimits.maximumTombstones)
    #expect(document.artifactState?["app:0"] == nil)
    // The evicted key is absent, so a writer holding its old version still conflicts.
    #expect(throws: ArtifactStateError.conflict(key: "app:0", current: nil)) {
      var copy = document
      try copy.applyArtifactStateEdits([set("app:0", .bool(true), expected: 2)], at: time)
    }
  }

  @Test func onlyAnArtifactHoldsState() throws {
    #expect(throws: ArtifactStateError.notArtifact) {
      var note = NoteDocument()
      try note.applyArtifactStateEdits([set("app:x", .null)], at: time)
    }
    let entry = ArtifactStateEntry(value: .null, version: 1, updatedAt: time)
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) {
      try NoteDocument(artifactState: ["app:x": entry]).validateEditableShape()
    }
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) {
      try NoteDocument(kind: .html, artifactState: ["app:x": .init(value: .null, version: 0, updatedAt: time)]).validateEditableShape()
    }
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) {
      try NoteDocument(kind: .html, artifactState: ["unprefixed": entry]).validateEditableShape()
    }
    #expect(throws: RemoteNoteEditError.operationNotAllowed) {
      try RemoteNoteEditEnvelope.validate(operations: [.artifactState([set("app:x", .null)])], noteKind: .note)
    }
  }

  @Test func aFutureFieldInStateIsReadOnly() throws {
    var document = artifact()
    try document.applyArtifactStateEdits([set("app:x", .number(1))], at: time)
    var object = try #require(JSONSerialization.jsonObject(with: Data(document.encoded().utf8)) as? [String: Any])
    var state = try #require(object["artifactState"] as? [String: [String: Any]])
    state["app:x"]?["futureField"] = "preserve"
    object["artifactState"] = state
    let raw = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: raw) }
  }

  @Test func theSnapshotOmitsTombstonesAndKeepsNull() throws {
    var document = artifact()
    #expect(document.artifactStateSnapshot == .empty)
    try document.applyArtifactStateEdits([set("app:null", .null), set("app:gone", .number(1))], at: time)
    try document.applyArtifactStateEdits([.init(action: .remove, key: "app:gone", expectedVersion: 1)], at: time)
    let snapshot = document.artifactStateSnapshot
    #expect(snapshot.values == ["app:null": .null])
    #expect(snapshot.versions == ["app:null": 1, "app:gone": 2])
    #expect(try JSONDecoder().decode(ArtifactStateSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
  }

  @Test func draftsCarryOnlyWhatTheyChanged() throws {
    func entry(_ value: GatewayJSONValue?, _ version: Int) -> ArtifactStateEntry { .init(value: value, version: version, updatedAt: time) }
    let base = ["form:a": entry(.number(1), 1), "form:b": entry(.number(1), 1), "form:c": entry(.number(1), 1)]
    // A stale draft that left state alone takes every newer value.
    let newer = ["form:a": entry(.number(2), 2), "form:b": entry(nil, 2), "form:c": entry(.number(1), 1), "form:new": entry(.null, 1)]
    #expect(try NoteDocument.mergeArtifactState(base: base, draft: base, current: newer, at: "later") == newer)
    // A key only the draft changed is applied, with a version past both sides.
    var edited = base; edited["form:c"] = entry(.number(9), 5)
    let merged = try NoteDocument.mergeArtifactState(base: base, draft: edited, current: newer, at: "later")
    #expect(merged?["form:c"] == entry(.number(9), 6).with(updatedAt: "later"))
    #expect(merged?["form:a"] == newer["form:a"])
    // A key both changed differently goes to recovery instead of losing either side.
    var clash = base; clash["form:a"] = entry(.number(7), 2)
    #expect(throws: ArtifactStateError.conflict(key: "form:a", current: newer["form:a"])) {
      try NoteDocument.mergeArtifactState(base: base, draft: clash, current: newer, at: "later")
    }
    var same = base; same["form:a"] = entry(.number(2), 2)
    #expect(try NoteDocument.mergeArtifactState(base: base, draft: same, current: newer, at: "later") == newer)
    #expect(try NoteDocument.mergeArtifactState(base: nil, draft: nil, current: nil, at: "later") == nil)
  }

  @Test func aDraftClearingManyKeysStaysWithinTheTombstoneLimit() throws {
    let count = ArtifactStateLimits.maximumTombstones + 10
    let base = Dictionary(uniqueKeysWithValues: (0..<count).map { ("form:\($0)", ArtifactStateEntry(value: .number(1), version: 1, updatedAt: time)) })
    let cleared = base.mapValues { ArtifactStateEntry(value: nil, version: $0.version, updatedAt: time) }
    let merged = try #require(try NoteDocument.mergeArtifactState(base: base, draft: cleared, current: base, at: "later"))
    #expect(merged.values.filter { $0.isTombstone }.count == ArtifactStateLimits.maximumTombstones)
    #expect(merged.values.allSatisfy { $0.isTombstone })
  }

  @Test func genericEditsLeaveStateAloneAndStateEditsLeaveCodeAlone() throws {
    var document = artifact()
    _ = try document.apply([.artifactState([set("app:x", .number(1))])])
    let state = document.artifactState
    _ = try document.apply([.setHTML("<p>new</p>")])
    #expect(document.artifactState == state)
    _ = try document.apply([.artifactState([set("app:x", .number(2), expected: 1)])])
    #expect(document.html == "<p>new</p>")
    #expect(!RemoteNoteEditEnvelope.requiresRevision([.artifactState([set("app:x", .null)])]))
    try RemoteNoteEditEnvelope.validate(operations: [.artifactState([set("app:y", .null)])], applyingTo: document)
  }
}

private extension ArtifactStateEntry {
  func with(updatedAt: String) -> ArtifactStateEntry { .init(value: value, version: version, updatedAt: updatedAt) }
}
