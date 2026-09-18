import Foundation
import SQLite3
import Testing
import WovenMatterClient
import WovenMatterCore

@testable import WovenMatterDashboardStore

@Suite("Workspace history and bounded versions")
struct WorkspaceHistoryTests {
  @Test func sessionEndpointCapabilitiesAreRedactedWithoutChangingOtherProtocolContent() throws {
    let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32)
    let socket = "/private/tmp/wmtools-\(a)/\(b).sock"
    let cli = "/home/.wmt/\(a)/\(b)/wovenmatter"
    for path in [socket, cli, socket.replacingOccurrences(of: "/", with: "\\/")] {
      let raw = "{\"prompt\":\"Use \(path)\",\"future_field\":true}"
      let redacted = WorkspaceHistoryPrivacy.redactingToolEndpoints(raw)
      #expect(!redacted.contains(a))
      #expect(redacted.contains("future_field"))
      #expect(try JSONSerialization.jsonObject(with: Data(redacted.utf8)) is [String: Any])
    }
    let ordinary = #"{"path":"/Users/example/a.swift","text":"preserved"}"#
    #expect(WorkspaceHistoryPrivacy.redactingToolEndpoints(ordinary) == ordinary)
  }
  private func database() throws -> (WorkspaceDatabase, URL) {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return (try WorkspaceDatabase(url: url.appending(path: "workspace.sqlite")), url)
  }
  private func rows(_ value: GatewayJSONValue) -> [GatewayJSONValue] {
    value.objectValue?["rows"]?.arrayValue ?? []
  }

  @Test func nativePayloadsSurviveReopenAndSearchWithStablePagination() throws {
    let (db, url) = try database()
    defer { try? FileManager.default.removeItem(at: url) }
    let conversation = try db.createLocalACPSession(
      runtimeKind: .pi, title: "Pi", ownerDeviceID: UUID())
    let run = try db.beginLocalACPRun(conversationID: conversation, content: "research")
    let raw =
      #"{"type":"tool_execution_end","result":{"text":"unique needle","futureField":[1,2]}}"#
    let event = WorkspaceHistoryEvent(
      id: "native-1", conversationID: conversation, harness: "pi", kind: "wire.in", payload: raw)
    try db.recordHistory(event)
    try db.recordHistory(event)
    try db.recordHistory(
      WorkspaceHistoryEvent(
        id: "native-2", conversationID: conversation, harness: "pi", kind: "wire.in", payload: raw))
    let query = WorkspaceHistoryQuery(
      command: "search", search: "unique needle", harness: "pi", limit: 1)
    let first = try db.queryHistory(query)
    #expect(rows(first).count == 1)
    #expect(rows(first).first?.objectValue?["payload"]?.stringValue == raw)
    #expect(rows(first).first?.objectValue?["run_id"]?.stringValue == run.runID)
    #expect(first.objectValue?["hasMore"]?.boolValue == true)
    let reopened = try WorkspaceDatabase(url: url.appending(path: "workspace.sqlite"))
    var next = query
    next.after = Int64(first.objectValue?["nextCursor"]?.intValue ?? 0)
    #expect(
      rows(try reopened.queryHistory(next)).first?.objectValue?["id"]?.stringValue == "native-2")
    #expect(throws: (any Error).self) {
      try db.recordHistory(
        WorkspaceHistoryEvent(id: "native-1", harness: "pi", kind: "wire.in", payload: "different"))
    }
    #expect(throws: (any Error).self) { try db.queryHistory(.init(command: "DELETE FROM notes")) }
  }

  @Test func queriesRecordReferencesWithoutRecursivelyEmbeddingHistory() throws {
    let (db, url) = try database()
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try db.queryHistory(.init(command: "events"))
    let audit = rows(try db.queryHistory(.init(command: "events", harness: "woven-history")))
    #expect(audit.count == 3)
    #expect(audit[1].objectValue?["kind"]?.stringValue == "cli.query.result")
    #expect((audit[1].objectValue?["payload"]?.stringValue?.count ?? 999) < 200)
  }

  @Test func versionsAreBoundedAndRestoreChecksRevision() throws {
    let (db, url) = try database()
    defer { try? FileManager.default.removeItem(at: url) }
    let note = try db.createNote(folderID: nil, title: "Document", content: "Original")
    let original = try #require(db.noteAssetVersions(id: note).first)
    _ = try db.applyNoteEdits(
      .init(command: .apply, noteID: note, operations: [.appendText(" agent", .paragraph)]))
    #expect(try db.noteAssetVersions(id: note).count == 2)
    #expect(throws: (any Error).self) {
      try db.restoreNoteAssetVersion(
        noteID: note, versionID: original.id, expectedRevision: "stale")
    }
    let current = try db.readNoteForEditing(id: note)
    let restored = try db.restoreNoteAssetVersion(
      noteID: note, versionID: original.id, expectedRevision: try #require(current.revision))
    #expect(restored.document?.plainText == NoteDocument.decode(original.content).plainText)
    for n in 0..<65 {
      _ = try db.applyNoteEdits(
        .init(command: .apply, noteID: note, operations: [.setTitle("Version \(n)")]))
    }
    #expect(try db.noteAssetVersions(id: note).count == 50)
    #expect(try db.readNoteForEditing(id: note).title == "Version 64")
  }

  @Test func rapidAutosavesCoalesceButAgentEditsAreImmediateForEveryAssetKind() throws {
    let (db, url) = try database()
    defer { try? FileManager.default.removeItem(at: url) }
    for kind in [NoteArtifactKind.note, .spreadsheet, .html] {
      let note = try db.createNote(folderID: nil, title: "Asset", kind: kind)
      let current = try db.readNoteForEditing(id: note)
      for n in 0..<10 {
        _ = try db.persistNoteDraft(
          id: note, title: "Draft \(n)", content: try #require(current.document).encoded())
      }
      #expect(try db.noteAssetVersions(id: note).count == 1)
      try db.checkpointNote(id: note)
      #expect(try db.noteAssetVersions(id: note).count == 2)
      if kind == .html {
        _ = try db.applyNoteEdits(
          .init(command: .apply, noteID: note, operations: [.setHTML("<h1>Changed</h1>")]))
      } else {
        _ = try db.applyNoteEdits(
          .init(command: .apply, noteID: note, operations: [.setTitle("Agent title")]))
      }
      #expect(try db.noteAssetVersions(id: note).count == 3)
    }
  }

  @Test func largePayloadsAreRetrievedInBoundedChunksWithoutLosingEvidence() throws {
    let (db, url) = try database()
    defer { try? FileManager.default.removeItem(at: url) }
    let payload = String(repeating: "π", count: 100000)
    try db.recordHistory(.init(id: "large", harness: "pi", kind: "wire.in", payload: payload))
    let listing = rows(try db.queryHistory(.init(command: "events", harness: "pi")))
    #expect(listing.first?.objectValue?["payload"] == .null)
    #expect(listing.first?.objectValue?["payload_characters"]?.intValue == 100000)
    var query = WorkspaceHistoryQuery(command: "event", id: "large")
    let first = rows(try db.queryHistory(query)).first?.objectValue?["payload"]?.stringValue ?? ""
    query.offset = 65536
    let second = rows(try db.queryHistory(query)).first?.objectValue?["payload"]?.stringValue ?? ""
    #expect(first + second == payload)
  }

  @Test func byteRetentionAndRevisionTokensHoldUnderRapidLargeEdits() throws {
    let (db, url) = try database()
    defer { try? FileManager.default.removeItem(at: url) }
    let note = try db.createNote(folderID: nil, title: "Large HTML", kind: .html)
    var previous = try #require(db.readNoteForEditing(id: note).revision)
    let body = String(repeating: "x", count: 1024 * 1024)
    for n in 0..<23 {
      let response = try db.applyNoteEdits(
        .init(
          command: .apply, noteID: note, expectedRevision: previous,
          operations: [.setHTML("<p>\(n) \(body)</p>")]))
      let revision = try #require(response.revision)
      #expect(revision > previous)
      previous = revision
    }
    let versions = try db.noteAssetVersions(id: note)
    #expect(versions.count < 23)
    #expect(
      versions.reduce(0) { $0 + $1.content.utf8.count + $1.title.utf8.count } <= 20 * 1024 * 1024)
    #expect(try db.readNoteForEditing(id: note).document?.html.contains("<p>23") == false)
    #expect(try db.readNoteForEditing(id: note).document?.html.contains("<p>22") == true)
  }

  @Test func messagingReservesIdempotentlyAndRejectsImpersonationCollisionAndSelfSend() throws {
    let (db, url) = try database()
    defer { try? FileManager.default.removeItem(at: url) }
    let a = try db.createLocalACPSession(
      runtimeKind: .codex, title: "Research", ownerDeviceID: UUID())
    let b = try db.createLocalACPSession(
      runtimeKind: .hermes, title: "Writer", ownerDeviceID: UUID())
    let id = UUID().uuidString
    #expect(
      try db.reserveSessionMessage(sourceID: a, targetID: b, text: "Findings", requestID: id) == nil
    )
    let run = try db.beginLocalACPRun(
      conversationID: b, input: AgentMessageInput(text: "Findings", historyDeliveryID: id))
    let message = try #require(
      db.conversationContent(id: b).messages.first(where: { $0.id == run.userMessageID }))
    #expect(message.senderSessionID == a)
    #expect(message.senderSessionTitle == "Research")
    #expect(message.content == "Findings")
    try db.finishSessionMessage(requestID: id, accepted: true)
    #expect(
      try db.reserveSessionMessage(sourceID: a, targetID: b, text: "Findings", requestID: id)?
        .objectValue?["status"]?.stringValue == "accepted")
    #expect(throws: (any Error).self) {
      try db.reserveSessionMessage(sourceID: b, targetID: a, text: "Findings", requestID: id)
    }
    #expect(throws: (any Error).self) {
      try db.reserveSessionMessage(
        sourceID: a, targetID: a, text: "Loop", requestID: UUID().uuidString)
    }
    #expect(throws: (any Error).self) {
      try db.reserveSessionMessage(
        sourceID: a, targetID: "missing", text: "Test", requestID: UUID().uuidString)
    }
    #expect(rows(try db.queryHistory(.init(command: "search", search: "Findings"))).count >= 2)
  }
}
