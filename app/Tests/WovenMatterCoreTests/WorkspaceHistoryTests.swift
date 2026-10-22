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
      runtimeKind: .claudeCode, title: "Pi", ownerDeviceID: UUID())
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

  @Test func rapidAutosavesCoalesceButAgentEditsAreImmediateForEveryAssetKind() async throws {
    let (db, url) = try await database()
    defer { try? FileManager.default.removeItem(at: url) }
    for kind in [NoteArtifactKind.note, .spreadsheet, .html] {
      let note = try await db.createNote(folderID: nil, title: "Asset", kind: kind)
      let current = try await db.readNoteForEditing(id: note)
      for n in 0..<10 {
        _ = try await db.persistNoteDraft(
          id: note, title: "Draft \(n)", content: try #require(current.document).encoded(),
          expectedRevision: try await db.readNoteForEditing(id: note).revision)
      }
      #expect(try await db.noteAssetVersions(id: note).count == 1)
      try await db.checkpointNote(id: note)
      #expect(try await db.noteAssetVersions(id: note).count == 2)
      if kind == .html {
        let revision = try await #require(db.readNoteForEditing(id: note).revision)
        _ = try await db.applyNoteEdits(
          .init(command: .apply, noteID: note, expectedRevision: revision,
            operations: [.setHTML("<h1>Changed</h1>")]))
      } else {
        let revision = try await #require(db.readNoteForEditing(id: note).revision)
        _ = try await db.applyNoteEdits(
          .init(command: .apply, noteID: note, expectedRevision: revision,
            operations: [.setTitle("Agent title")]))
      }
      #expect(try await db.noteAssetVersions(id: note).count == 3)
    }
  }

}
