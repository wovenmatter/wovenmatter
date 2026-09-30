import Foundation
import SQLite3
import Testing
import WovenMatterClient
import WovenMatterCore

@testable import WovenMatterDashboardStore

@Suite("Workspace history and bounded versions")
struct WorkspaceHistoryTests {
  @Test func nativeHTTPHistoryIsAdoptedOnlyByTheMatchingWorkspaceImport() async throws {
    let (db, url) = try await database()
    defer { try? FileManager.default.removeItem(at: url) }
    let body = #"{"data":[{"id":"message-a","text":"full original response"}]}"#
    let observation = try JSONEncoder().encode(WorkspaceHTTPObservation(method: "GET", path: "/api/session/ses_shared/message",
      query: [:], status: 200, body: body))
    let local = db.openCodeHistoryRecorder(connectionID: "local")
    let remote = db.openCodeHistoryRecorder(connectionID: "remote")
    try await local("in", observation)
    try await remote("in", observation)
    let imported = try await db.createLocalACPSession(runtimeKind: .opencode, title: "Imported", ownerDeviceID: UUID(),
      openCodeAssociation: ("local", "ses_shared"))
    let other = try await db.createLocalACPSession(runtimeKind: .opencode, title: "Other workspace", ownerDeviceID: UUID(),
      openCodeAssociation: ("remote", "ses_shared"))
    let reopened = try await WorkspaceDatabase(url: url.appending(path: "workspace.sqlite"))
    for id in [imported, other] {
      let result = rows(try await reopened.queryHistory(.init(command: "events", conversationID: id, kind: "wire.in")))
      #expect(result.count == 1)
      #expect(result.first?.objectValue?["payload"]?.stringValue == String(decoding: observation, as: UTF8.self))
    }
    try await local("in", observation)
    #expect(rows(try await reopened.queryHistory(.init(command: "events", conversationID: imported, kind: "wire.in"))).count == 2)
    #expect(rows(try await reopened.queryHistory(.init(command: "events", conversationID: other, kind: "wire.in"))).count == 1)
  }

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
    let ordinary = #"{"path":"/workspace/example/a.swift","text":"preserved"}"#
    #expect(WorkspaceHistoryPrivacy.redactingToolEndpoints(ordinary) == ordinary)
  }
  @Test func nestedHTTPHistoryRedactsSessionEndpoints() async throws {
    let (db, url) = try await database()
    defer { try? FileManager.default.removeItem(at: url) }
    let owner = String(repeating: "a", count: 32), endpoint = String(repeating: "b", count: 32)
    for path in ["/private/tmp/wmtools-\(owner)/\(endpoint).sock", "/home/.wmt/\(owner)/\(endpoint)/wovenmatter"] {
      // HTTP observations wrap the original JSON response as a JSON string.
      let body = String(decoding: try JSONEncoder().encode(["text": "Use " + path, "other": "preserved"]), as: UTF8.self)
      let frame = WorkspaceHTTPObservation(method: "GET", path: "/api/session/ses_a/message", query: [:], status: 200, body: body)
      try await db.openCodeHistoryRecorder(connectionID: "local")("in", JSONEncoder().encode(frame))
    }
    let payloads = rows(try await db.queryHistory(.init(command: "events", harness: "opencode")))
    #expect(payloads.count == 2)
    for row in payloads {
      let payload = try #require(row.objectValue?["payload"]?.stringValue)
      #expect(!payload.contains(owner))
      #expect(!payload.contains(endpoint))
      let frame = try JSONDecoder().decode([String: GatewayJSONValue].self, from: Data(payload.utf8))
      let body = try #require(frame["body"]?.stringValue)
      let decoded = try JSONDecoder().decode([String: String].self, from: Data(body.utf8))
      #expect(decoded["other"] == "preserved")
      #expect(decoded["text"] == "Use [Woven Matter session tool endpoint]")
    }
  }

  @Test func historyDateBoundsCompareInstantsInsteadOfDateSpellings() async throws {
    let (db, url) = try await database()
    defer { try? FileManager.default.removeItem(at: url) }
    let caller = try await db.createLocalACPSession(runtimeKind: .pi, title: "Dates", ownerDeviceID: UUID())
    try await db.recordHistory(.init(id: "dated", conversationID: caller, harness: "pi", kind: "wire.in", payload: "dated event"))
    try await db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("UPDATE workspace_history_events SET recorded_at=? WHERE id=?", ["2026-09-21T12:00:00.000Z", "dated"])
     } }
    for boundary in ["2026-09-21T12:00:00Z", "2026-09-21T08:00:00-04:00", "2026-09-21T14:00:00.000+02:00"] {
      var query = WorkspaceHistoryQuery(command: "events", conversationID: caller, kind: "wire.in")
      query.since = boundary
      query.until = boundary
      #expect(rows(try await db.queryAgentHistory(query, callerID: caller)).count == 1)
    }
    var query = WorkspaceHistoryQuery(command: "events", conversationID: caller, kind: "wire.in")
    query.since = "2026-09-21T09:00:00-04:00"
    #expect(rows(try await db.queryHistory(query)).isEmpty)
    query.since = "not-a-date"
    await #expect(throws: (any Error).self) { try await db.queryHistory(query) }
  }

  private func database() async throws -> (WorkspaceDatabase, URL) {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return (try await WorkspaceDatabase(url: url.appending(path: "workspace.sqlite")), url)
  }
  private func rows(_ value: GatewayJSONValue) -> [GatewayJSONValue] {
    value.objectValue?["rows"]?.arrayValue ?? []
  }

  @Test func nativePayloadsSurviveReopenAndSearchWithStablePagination() async throws {
    let (db, url) = try await database()
    defer { try? FileManager.default.removeItem(at: url) }
    let conversation = try await db.createLocalACPSession(
      runtimeKind: .pi, title: "Pi", ownerDeviceID: UUID())
    let run = try await db.beginLocalACPRun(conversationID: conversation, content: "research")
    let raw =
      #"{"type":"tool_execution_end","result":{"text":"unique needle","futureField":[1,2]}}"#
    let event = WorkspaceHistoryEvent(
      id: "native-1", conversationID: conversation, harness: "pi", kind: "wire.in", payload: raw)
    try await db.recordHistory(event)
    try await db.recordHistory(event)
    try await db.recordHistory(
      WorkspaceHistoryEvent(
        id: "native-2", conversationID: conversation, harness: "pi", kind: "wire.in", payload: raw))
    let query = WorkspaceHistoryQuery(
      command: "search", search: "unique needle", harness: "pi", limit: 1)
    let first = try await db.queryHistory(query)
    #expect(rows(first).count == 1)
    #expect(rows(first).first?.objectValue?["payload"]?.stringValue == raw)
    #expect(rows(first).first?.objectValue?["run_id"]?.stringValue == run.runID)
    #expect(first.objectValue?["hasMore"]?.boolValue == true)
    let reopened = try await WorkspaceDatabase(url: url.appending(path: "workspace.sqlite"))
    var next = query
    next.after = Int64(first.objectValue?["nextCursor"]?.intValue ?? 0)
    #expect(
      rows(try await reopened.queryHistory(next)).first?.objectValue?["id"]?.stringValue == "native-2")
    await #expect(throws: (any Error).self) {
      try await db.recordHistory(
        WorkspaceHistoryEvent(id: "native-1", harness: "pi", kind: "wire.in", payload: "different"))
    }
    await #expect(throws: (any Error).self) { try await db.queryHistory(.init(command: "DELETE FROM notes")) }
  }

  @Test func queriesRecordReferencesWithoutRecursivelyEmbeddingHistory() async throws {
    let (db, url) = try await database()
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try await db.queryHistory(.init(command: "events"))
    let audit = rows(try await db.queryHistory(.init(command: "events", harness: "woven-history")))
    #expect(audit.count == 3)
    #expect(audit[1].objectValue?["kind"]?.stringValue == "cli.query.result")
    #expect((audit[1].objectValue?["payload"]?.stringValue?.count ?? 999) < 200)
  }

  @Test func versionsAreBoundedAndRestoreChecksRevision() async throws {
    let (db, url) = try await database()
    defer { try? FileManager.default.removeItem(at: url) }
    let note = try await db.createNote(folderID: nil, title: "Document", content: "Original")
    let original = try await #require(db.noteAssetVersions(id: note).first)
    _ = try await db.applyNoteEdits(
      .init(command: .apply, noteID: note, operations: [.appendText(" agent", .paragraph)]))
    #expect(try await db.noteAssetVersions(id: note).count == 2)
    await #expect(throws: (any Error).self) {
      try await db.restoreNoteAssetVersion(
        noteID: note, versionID: original.id, expectedRevision: "stale")
    }
    let current = try await db.readNoteForEditing(id: note)
    let restored = try await db.restoreNoteAssetVersion(
      noteID: note, versionID: original.id, expectedRevision: try #require(current.revision))
    #expect(restored.document?.plainText == NoteDocument.decode(original.content).plainText)
    for n in 0..<65 {
      _ = try await db.applyNoteEdits(
        .init(command: .apply, noteID: note, operations: [.setTitle("Version \(n)")]))
    }
    #expect(try await db.noteAssetVersions(id: note).count == 50)
    #expect(try await db.readNoteForEditing(id: note).title == "Version 64")
  }

  @Test func rapidAutosavesCoalesceButAgentEditsAreImmediateForEveryAssetKind() async throws {
    let (db, url) = try await database()
    defer { try? FileManager.default.removeItem(at: url) }
    for kind in [NoteArtifactKind.note, .spreadsheet, .html] {
      let note = try await db.createNote(folderID: nil, title: "Asset", kind: kind)
      let current = try await db.readNoteForEditing(id: note)
      for n in 0..<10 {
        _ = try await db.persistNoteDraft(
          id: note, title: "Draft \(n)", content: try #require(current.document).encoded())
      }
      #expect(try await db.noteAssetVersions(id: note).count == 1)
      try await db.checkpointNote(id: note)
      #expect(try await db.noteAssetVersions(id: note).count == 2)
      if kind == .html {
        _ = try await db.applyNoteEdits(
          .init(command: .apply, noteID: note, operations: [.setHTML("<h1>Changed</h1>")]))
      } else {
        _ = try await db.applyNoteEdits(
          .init(command: .apply, noteID: note, operations: [.setTitle("Agent title")]))
      }
      #expect(try await db.noteAssetVersions(id: note).count == 3)
    }
  }

  @Test func largePayloadsAreRetrievedInBoundedChunksWithoutLosingEvidence() async throws {
    let (db, url) = try await database()
    defer { try? FileManager.default.removeItem(at: url) }
    let payload = String(repeating: "π", count: 100000)
    try await db.recordHistory(.init(id: "large", harness: "pi", kind: "wire.in", payload: payload))
    let listing = rows(try await db.queryHistory(.init(command: "events", harness: "pi")))
    #expect(listing.first?.objectValue?["payload"] == .null)
    #expect(listing.first?.objectValue?["payload_characters"]?.intValue == 100000)
    var query = WorkspaceHistoryQuery(command: "event", id: "large")
    let first = rows(try await db.queryHistory(query)).first?.objectValue?["payload"]?.stringValue ?? ""
    query.offset = 65536
    let second = rows(try await db.queryHistory(query)).first?.objectValue?["payload"]?.stringValue ?? ""
    #expect(first + second == payload)
  }

  @Test func byteRetentionAndRevisionTokensHoldUnderRapidLargeEdits() async throws {
    let (db, url) = try await database()
    defer { try? FileManager.default.removeItem(at: url) }
    let note = try await db.createNote(folderID: nil, title: "Large HTML", kind: .html)
    var previous = try await #require(db.readNoteForEditing(id: note).revision)
    let body = String(repeating: "x", count: 1024 * 1024)
    for n in 0..<23 {
      let response = try await db.applyNoteEdits(
        .init(
          command: .apply, noteID: note, expectedRevision: previous,
          operations: [.setHTML("<p>\(n) \(body)</p>")]))
      let revision = try #require(response.revision)
      #expect(revision > previous)
      previous = revision
    }
    let versions = try await db.noteAssetVersions(id: note)
    #expect(versions.count < 23)
    #expect(
      versions.reduce(0) { $0 + $1.content.utf8.count + $1.title.utf8.count } <= 20 * 1024 * 1024)
    #expect(try await db.readNoteForEditing(id: note).document?.html.contains("<p>23") == false)
    #expect(try await db.readNoteForEditing(id: note).document?.html.contains("<p>22") == true)
  }

  @Test func messagingReservesIdempotentlyAndRejectsImpersonationCollisionAndSelfSend() async throws {
    let (db, url) = try await database()
    defer { try? FileManager.default.removeItem(at: url) }
    let a = try await db.createLocalACPSession(
      runtimeKind: .codex, title: "Research", ownerDeviceID: UUID())
    let b = try await db.createLocalACPSession(
      runtimeKind: .hermes, title: "Writer", ownerDeviceID: UUID())
    let id = UUID().uuidString
    #expect(
      try await db.reserveToolDelivery(sourceID: a, targetID: b, text: "Findings", requestID: id).status == "queued"
    )
    _ = try await db.claimToolDelivery(id: id)
    let run = try await db.beginLocalACPRun(
      conversationID: b, input: AgentMessageInput(text: "Findings", historyDeliveryID: id))
    let message = try await #require(
      db.conversationContent(id: b).messages.first(where: { $0.id == run.userMessageID }))
    #expect(message.senderSessionID == a)
    #expect(message.senderSessionTitle == "Research")
    #expect(message.content == "Findings")
    try await db.setToolDeliveryStatus(id: id, status: "accepted")
    #expect(
      try await db.reserveToolDelivery(sourceID: a, targetID: b, text: "Findings", requestID: id).status == "accepted")
    await #expect(throws: (any Error).self) {
      try await db.reserveToolDelivery(sourceID: b, targetID: a, text: "Findings", requestID: id)
    }
    await #expect(throws: (any Error).self) {
      try await db.reserveToolDelivery(
        sourceID: a, targetID: a, text: "Loop", requestID: UUID().uuidString)
    }
    await #expect(throws: (any Error).self) {
      try await db.reserveToolDelivery(
        sourceID: a, targetID: "missing", text: "Test", requestID: UUID().uuidString)
    }
    let findings = rows(try await db.queryHistory(.init(command: "search", search: "Findings")))
    #expect(findings.count == 1) // the input, excluding this search's own audit event
    #expect(findings.first?.objectValue?["kind"]?.stringValue == "message.insert")
  }
}
