import Foundation
import SQLite3
import Testing
import WovenMatterClient
import WovenMatterCore

@testable import WovenMatterDashboardStore

@Suite("Workspace history and bounded versions")
struct WorkspaceHistoryTests {
  @Test func legacyCompletedStreamsRemainSearchableAfterMigration() async throws {
    let (db, url) = try await database()
    defer { try? FileManager.default.removeItem(at: url) }
    let session = try await db.createLocalACPSession(runtimeKind: .codex, title: "Legacy", ownerDeviceID: UUID())
    let run = try await db.beginLocalACPRun(conversationID: session, content: "Prompt")
    try await db.appendLocalACPAssistantChunk(runID: run.runID, chunk: "legacy violet harbor")
    try await db.completeLocalACPRun(runID: run.runID)
    try await db.write { connection in
      try connection.transaction {
      // Old triggers stored deltas; their terminal event normally had no content.
        try connection.toolsExecuteUnlocked("UPDATE workspace_history_events SET payload=json_set(payload,'$.content','','$.contentMode','append') WHERE run_id=? AND kind='message.update'", [run.runID])
        try connection.toolsExecuteUnlocked("INSERT INTO workspace_history_events(id,conversation_id,run_id,harness,kind,payload) VALUES(?,?,?,?,?,?)",
          [UUID().uuidString, session, run.runID, "codex", "message.update",
           try connection.toolsJSON(["id": run.assistantMessageID, "status": "streaming", "content": "legacy violet harbor", "contentMode": "append"])])
        try connection.toolsExecuteUnlocked("DELETE FROM workspace_history_schema WHERE version=2")
      }
    }
    let reopened = try await WorkspaceDatabase(url: url.appending(path: "workspace.sqlite"))
    let matches = rows(try await reopened.queryHistory(.init(command: "search", search: "legacy violet harbor", conversationID: session)))
    #expect(matches.contains { $0.objectValue?["kind"]?.stringValue == "message.snapshot" })
    #expect(rows(try await reopened.queryHistory(.init(command: "events", runID: run.runID, kind: "message.update")))
      .allSatisfy { $0.objectValue?["payload"]?.stringValue?.contains("streaming") == false })
  }

  @Test func legacyEndpointScrubbingCrossesIdentityPageBoundary() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let endpoint = "/private/tmp/wmtools-" + String(repeating: "a", count: 32)
      + "/" + String(repeating: "b", count: 32) + ".sock"
    do {
      let database = try await WorkspaceDatabase(url: url.appending(path: "workspace.sqlite"))
      try await database.write { connection in
        try connection.transaction {
          try connection.executeUnlocked("DELETE FROM workspace_history_schema WHERE version=2")
          for index in 0..<501 {
            try connection.toolsExecuteUnlocked("INSERT INTO workspace_history_events(id,harness,kind,payload) VALUES(?,?,?,?)",
              ["legacy-page-\(index)", "pi", "wire.in", "retained-marker-\(index) " + endpoint])
          }
        }
      }
    }
    let reopened = try await WorkspaceDatabase(url: url.appending(path: "workspace.sqlite"))
    let counts = try await reopened.read { connection in
      try connection.historyRowsUnlocked("SELECT count(*) AS total,sum(instr(payload,?)>0) AS leaked,sum(instr(payload,'[Woven Matter session tool endpoint]')>0) AS scrubbed FROM workspace_history_events WHERE id LIKE 'legacy-page-%'", values: [endpoint])
    }
    #expect(counts.first?.objectValue?["total"]?.intValue == 501)
    #expect(counts.first?.objectValue?["leaked"]?.intValue == 0)
    #expect(counts.first?.objectValue?["scrubbed"]?.intValue == 501)
    #expect(!rows(try await reopened.queryHistory(.init(command: "search", search: "retained-marker-500"))).isEmpty)
  }

  @Test func uppercaseSessionEndpointsAreRedacted() {
    let owner = String(repeating: "A", count: 32)
    let endpoint = String(repeating: "B", count: 32)
    let local = "/private/tmp/wmtools-\(owner)/\(endpoint).sock"
    let remote = "/home/.wmt/\(owner)/\(endpoint)/rpc.sock"
    let redacted = WorkspaceHistoryPrivacy.redactingToolEndpoints("local=\(local) remote=\(remote)")
    #expect(!redacted.contains(local) && !redacted.contains(remote))
    #expect(redacted.components(separatedBy: "[Woven Matter session tool endpoint]").count == 3)
  }

  @Test func terminalStreamSnapshotsAreSearchableWithoutPerChunkHistory() async throws {
    let (db, url) = try await database()
    defer { try? FileManager.default.removeItem(at: url) }
    let session = try await db.createLocalACPSession(runtimeKind: .codex, title: "Stream", ownerDeviceID: UUID())
    let run = try await db.beginLocalACPRun(conversationID: session, content: "Prompt")
    for chunk in ["violet ", "harbor", " final"] {
      try await db.appendLocalACPAssistantChunk(runID: run.runID, chunk: chunk)
    }
    try await db.completeLocalACPRun(runID: run.runID)
    let updates = rows(try await db.queryHistory(.init(command: "events", runID: run.runID,
      kind: "message.update", limit: 20)))
    #expect(updates.count == 1)
    let matches = rows(try await db.queryHistory(.init(command: "search", search: "violet harbor",
      conversationID: session)))
    #expect(matches.contains { $0.objectValue?["kind"]?.stringValue == "message.update" })
  }

  @Test func legacyCLIContentIsScrubbedBeforeSearchRebuild() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let secret = "legacy-secret-" + UUID().uuidString.lowercased()
    let endpoint = "/private/tmp/wmtools-" + String(repeating: "A", count: 32)
      + "/" + String(repeating: "B", count: 32) + ".sock"
    let endpointEventID = UUID().uuidString.lowercased()
    do {
      let db = try await WorkspaceDatabase(url: url.appending(path: "workspace.sqlite"))
      try await db.write { connection in
        try connection.transaction {
          try connection.toolsExecuteUnlocked("DELETE FROM workspace_history_schema WHERE version=2")
          try connection.toolsExecuteUnlocked("INSERT INTO workspace_history_events(id,harness,kind,payload) VALUES(?,?,?,?)",
            [UUID().uuidString.lowercased(), "wovenmatter", "cli.response", secret + " " + endpoint])
          try connection.toolsExecuteUnlocked("INSERT INTO workspace_history_events(id,harness,kind,payload) VALUES(?,?,?,?)",
            [UUID().uuidString.lowercased(), "woven-history", "cli.query", secret])
          try connection.toolsExecuteUnlocked("INSERT INTO workspace_history_events(id,harness,kind,payload) VALUES(?,?,?,?)",
            [endpointEventID, "pi", "wire.in", endpoint])
        }
      }
    }
    let reopened = try await WorkspaceDatabase(url: url.appending(path: "workspace.sqlite"))
    let events = rows(try await reopened.queryHistory(.init(command: "events", harness: "wovenmatter",
      kind: "cli.response")))
    #expect(events.last?.objectValue?["payload"]?.stringValue == #"{"legacyRedacted":true}"#)
    let queries = rows(try await reopened.queryHistory(.init(command: "events", harness: "woven-history",
      kind: "cli.query")))
    #expect(queries.first?.objectValue?["payload"]?.stringValue == #"{"legacyRedacted":true}"#)
    #expect(rows(try await reopened.queryHistory(.init(command: "search", search: secret))).isEmpty)
    let endpointEvent = rows(try await reopened.queryHistory(.init(command: "event", id: endpointEventID))).first
    #expect(endpointEvent?.objectValue?["payload"]?.stringValue == "[Woven Matter session tool endpoint]")
  }

  @Test func nativeHTTPHistoryIsAdoptedOnlyByTheMatchingWorkspaceImport() throws {
    let (db, url) = try database()
    defer { try? FileManager.default.removeItem(at: url) }
    let body = #"{"data":[{"id":"message-a","text":"full original response"}]}"#
    let observation = try JSONEncoder().encode(WorkspaceHTTPObservation(method: "GET", path: "/api/session/ses_shared/message",
      query: [:], status: 200, body: body))
    let local = db.openCodeHistoryRecorder(connectionID: "local")
    let remote = db.openCodeHistoryRecorder(connectionID: "remote")
    try local("in", observation)
    try remote("in", observation)
    let imported = try db.createLocalACPSession(runtimeKind: .opencode, title: "Imported", ownerDeviceID: UUID(),
      openCodeAssociation: ("local", "ses_shared"))
    let other = try db.createLocalACPSession(runtimeKind: .opencode, title: "Other workspace", ownerDeviceID: UUID(),
      openCodeAssociation: ("remote", "ses_shared"))
    let reopened = try WorkspaceDatabase(url: url.appending(path: "workspace.sqlite"))
    for id in [imported, other] {
      let result = rows(try reopened.queryHistory(.init(command: "events", conversationID: id, kind: "wire.in")))
      #expect(result.count == 1)
      #expect(result.first?.objectValue?["payload"]?.stringValue == String(decoding: observation, as: UTF8.self))
    }
    try local("in", observation)
    #expect(rows(try reopened.queryHistory(.init(command: "events", conversationID: imported, kind: "wire.in"))).count == 2)
    #expect(rows(try reopened.queryHistory(.init(command: "events", conversationID: other, kind: "wire.in"))).count == 1)
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
  @Test func nestedHTTPHistoryRedactsSessionEndpoints() throws {
    let (db, url) = try database()
    defer { try? FileManager.default.removeItem(at: url) }
    let owner = String(repeating: "a", count: 32), endpoint = String(repeating: "b", count: 32)
    for path in ["/private/tmp/wmtools-\(owner)/\(endpoint).sock", "/home/.wmt/\(owner)/\(endpoint)/wovenmatter"] {
      // HTTP observations wrap the original JSON response as a JSON string.
      let body = String(decoding: try JSONEncoder().encode(["text": "Use " + path, "other": "preserved"]), as: UTF8.self)
      let frame = WorkspaceHTTPObservation(method: "GET", path: "/api/session/ses_a/message", query: [:], status: 200, body: body)
      try db.openCodeHistoryRecorder(connectionID: "local")("in", JSONEncoder().encode(frame))
    }
    let payloads = rows(try db.queryHistory(.init(command: "events", harness: "opencode")))
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

  @Test func historyDateBoundsCompareInstantsInsteadOfDateSpellings() throws {
    let (db, url) = try database()
    defer { try? FileManager.default.removeItem(at: url) }
    let caller = try db.createLocalACPSession(runtimeKind: .pi, title: "Dates", ownerDeviceID: UUID())
    try db.recordHistory(.init(id: "dated", conversationID: caller, harness: "pi", kind: "wire.in", payload: "dated event"))
    try db.transaction {
      try db.toolsExecuteUnlocked("UPDATE workspace_history_events SET recorded_at=? WHERE id=?", ["2026-09-21T12:00:00.000Z", "dated"])
    }
    for boundary in ["2026-09-21T12:00:00Z", "2026-09-21T08:00:00-04:00", "2026-09-21T14:00:00.000+02:00"] {
      var query = WorkspaceHistoryQuery(command: "events", conversationID: caller, kind: "wire.in")
      query.since = boundary
      query.until = boundary
      #expect(rows(try db.queryAgentHistory(query, callerID: caller)).count == 1)
    }
    var query = WorkspaceHistoryQuery(command: "events", conversationID: caller, kind: "wire.in")
    query.since = "2026-09-21T09:00:00-04:00"
    #expect(rows(try db.queryHistory(query)).isEmpty)
    query.since = "not-a-date"
    #expect(throws: (any Error).self) { try db.queryHistory(query) }
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
    var revision = try #require(restored.revision)
    for n in 0..<65 {
      let response = try db.applyNoteEdits(
        .init(command: .apply, noteID: note, expectedRevision: revision,
          operations: [.setTitle("Version \(n)")]))
      revision = try #require(response.revision)
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
        let revision = try #require(db.readNoteForEditing(id: note).revision)
        _ = try db.applyNoteEdits(
          .init(command: .apply, noteID: note, expectedRevision: revision,
            operations: [.setHTML("<h1>Changed</h1>")]))
      } else {
        let revision = try #require(db.readNoteForEditing(id: note).revision)
        _ = try db.applyNoteEdits(
          .init(command: .apply, noteID: note, expectedRevision: revision,
            operations: [.setTitle("Agent title")]))
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
    let body = String(repeating: "x", count: 900 * 1024)
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
      try db.reserveToolDelivery(sourceID: a, targetID: b, text: "Findings", requestID: id).status == "queued"
    )
    _ = try db.claimToolDelivery(id: id)
    let run = try db.beginLocalACPRun(
      conversationID: b, input: AgentMessageInput(text: "Findings", historyDeliveryID: id))
    let message = try #require(
      db.conversationContent(id: b).messages.first(where: { $0.id == run.userMessageID }))
    #expect(message.senderSessionID == a)
    #expect(message.senderSessionTitle == "Research")
    #expect(message.content == "Findings")
    try db.setToolDeliveryStatus(id: id, status: "accepted")
    #expect(
      try db.reserveToolDelivery(sourceID: a, targetID: b, text: "Findings", requestID: id).status == "accepted")
    #expect(throws: (any Error).self) {
      try db.reserveToolDelivery(sourceID: b, targetID: a, text: "Findings", requestID: id)
    }
    #expect(throws: (any Error).self) {
      try db.reserveToolDelivery(
        sourceID: a, targetID: a, text: "Loop", requestID: UUID().uuidString)
    }
    #expect(throws: (any Error).self) {
      try db.reserveToolDelivery(
        sourceID: a, targetID: "missing", text: "Test", requestID: UUID().uuidString)
    }
    let findings = rows(try db.queryHistory(.init(command: "search", search: "Findings")))
    #expect(findings.count == 1) // the input, excluding this search's own audit event
    #expect(findings.first?.objectValue?["kind"]?.stringValue == "message.insert")
  }
}
