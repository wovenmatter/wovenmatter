import Foundation
import SQLite3
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct CompanionTranscriptMigrationTests {
  @Test func nativeToolProjectionMigratesWithoutLosingOriginalHistory() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let c = fixture.conversationID
    let old = CompanionTranscript(conversationID: c, messages: [
      .init(id: c + "-1-0", conversationID: c, role: "user", content: "Tool: this is actual user text"),
      .init(id: c + "-2-0", conversationID: c, role: "assistant", content: "Tool: list_files"),
      .init(id: c + "-3-0", conversationID: c, role: "tool", content: "[]")
    ])
    let original = fixture.entry(old, sequence: 2)
    try await fixture.ingest([original])
    let projection = fixture.projection()
    // Large transcript pagination may put run metadata on an earlier page.
    try await fixture.ingest([fixture.entry(.init(conversationID: c, runs: projection.runs), sequence: 3)])
    var rows = projection; rows.runs = nil
    try await fixture.ingest([fixture.entry(rows, sequence: 4)])
    let latest = try #require(try await fixture.database.companionFederatedTranscript(conversationID: c))
    #expect(latest.messages.map(\.content) == ["Tool: this is actual user text"])
    #expect(latest.messages.first?.id == c + "-1-0")
    #expect(latest.messages.first?.runID == projection.runs?.first?.id)
    #expect(latest.activities == projection.activities)
    #expect(latest.runs == projection.runs)
    let run = try #require(projection.runs?.first)
    let timestamps = try await fixture.database.write { db in
      try db.companionIDsUnlocked("SELECT started_at || '/' || completed_at FROM dashboard_runs WHERE id=?", bindings: [run.id])
    }
    #expect(timestamps == [(run.startedAt ?? "") + "/" + (run.completedAt ?? "")])
    let activity = try #require(latest.activities.first)
    let decoded = try JSONDecoder().decode(AgentRunActivity.self, from: Data(try #require(activity.projectionJSON).utf8))
    #expect(decoded.kind == .tool && decoded.toolName == "list_files" && decoded.content == "[]")
    // The render migration does not delete the prior raw transcript or journal.
    let retained = try await fixture.database.write { db in
      try db.federationScalarUnlocked("SELECT COUNT(*) FROM dashboard_messages WHERE conversation_id=?", bindings: [c])
    }
    #expect(retained == 3)
    let journal = try await fixture.database.companionJournal(after: 0)
    #expect(journal.entries.first { $0.eventID == original.eventID } == original)
    // A delayed older batch is acknowledged without reapplying its display rows.
    try await fixture.ingest([original])
    #expect(try await fixture.database.companionFederatedTranscript(conversationID: c)?.messages == latest.messages)
    // Even a later legacy tool-only observation cannot undo the migration.
    try await fixture.ingest([fixture.entry(.init(conversationID: c, messages: Array(old.messages.dropFirst())), sequence: 5)])
    #expect(try await fixture.database.companionFederatedTranscript(conversationID: c)?.messages == latest.messages)
  }

  @Test func nativeMigrationCannotHideUserTextOrReassignAnEstablishedRun() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let c = fixture.conversationID
    let projection = fixture.projection()
    try await fixture.ingest([fixture.entry(projection, sequence: 2)])
    let invalid = CompanionTranscript(conversationID: c, removedMessageIDs: [c + "-1-0"])
    await #expect(throws: (any Error).self) { try await fixture.ingest([fixture.entry(invalid, sequence: 3)]) }
    var reassigned = projection
    let different = UUID().uuidString.lowercased()
    reassigned.messages[0].runID = different
    reassigned.runs = [.init(id: different, status: "completed")]
    await #expect(throws: (any Error).self) { try await fixture.ingest([fixture.entry(reassigned, sequence: 3)]) }
    let retained = try #require(try await fixture.database.companionFederatedTranscript(conversationID: c))
    #expect(retained.messages == projection.messages)
    #expect(try await fixture.database.companionExecutionOriginCursor(workspaceID: fixture.workspaceID) == 2)
  }

  private struct Fixture {
    let root: URL
    let database: WorkspaceDatabase
    let workspaceID: String
    let conversationID: String
    let deviceID: String
    let libraryID: String
    init() async throws {
      root = FileManager.default.temporaryDirectory.appending(path: "transcript-migration-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
      libraryID = try await database.companionLibraryIdentity().libraryID
      deviceID = UUID().uuidString.lowercased()
      workspaceID = UUID().uuidString.lowercased()
      conversationID = UUID().uuidString.lowercased()
      _ = try await database.registerCompanionExecutionWorkspace(.init(workspace: .init(
        id: workspaceID, libraryID: libraryID, ownerDeviceID: deviceID, kind: .ios, name: "Fixture iPhone")), deviceID: deviceID)
      _ = try await database.ingestCompanionJournal(.init(libraryID: libraryID, entries: [
        .init(workspaceID: workspaceID, originSequence: 1, conversationID: conversationID, kind: .conversation,
          conversation: .init(id: conversationID, title: "Hey", runtimeKind: "piDurable"))
      ]), deviceID: deviceID)
    }
    func entry(_ value: CompanionTranscript, sequence: Int64) -> CompanionJournalEntry {
      .init(workspaceID: workspaceID, originSequence: sequence, conversationID: conversationID, kind: .transcript, transcript: value)
    }
    func ingest(_ entries: [CompanionJournalEntry]) async throws {
      _ = try await database.ingestCompanionJournal(.init(libraryID: libraryID, entries: entries), deviceID: deviceID)
    }
    func projection() -> CompanionTranscript {
      CompanionDeviceTranscript.project(snapshot: ["entries": [
        ["id": 1, "model": [["role": "user", "content": "Tool: this is actual user text", "timestamp": 1_000]]],
        ["id": 2, "model": [["role": "assistant", "content": [["type": "toolCall", "id": "files", "name": "list_files", "arguments": [:]]], "timestamp": 2_000]]],
        ["id": 3, "model": [["role": "toolResult", "toolCallId": "files", "content": [["type": "text", "text": "[]"]], "timestamp": 3_000]]]
      ]], conversationID: conversationID)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
