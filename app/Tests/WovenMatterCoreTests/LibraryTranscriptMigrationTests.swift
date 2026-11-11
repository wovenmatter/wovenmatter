import WorkspaceFixtures
import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct LibraryTranscriptMigrationTests {

  @Test func nativeMigrationCannotHideUserTextOrReassignAnEstablishedRun() async throws {
    let fixture = try await Fixture()
    defer { fixture.remove() }
    let c = fixture.conversationID
    let projection = fixture.projection()
    try await fixture.ingest([fixture.entry(projection, sequence: 2)])
    let invalid = LibraryTranscript(conversationID: c, removedMessageIDs: [c + "-1-0"])
    await #expect(throws: (any Error).self) { try await fixture.ingest([fixture.entry(invalid, sequence: 3)]) }
    var reassigned = projection
    let different = UUID().uuidString.lowercased()
    reassigned.messages[0].runID = different
    reassigned.runs = [.init(id: different, status: "completed")]
    await #expect(throws: (any Error).self) { try await fixture.ingest([fixture.entry(reassigned, sequence: 3)]) }
    let retained = try #require(try await fixture.database.libraryFederatedTranscript(conversationID: c))
    #expect(retained.messages == projection.messages)
    #expect(try await fixture.database.libraryExecutionOriginCursor(workspaceID: fixture.workspaceID) == 2)
  }

  private struct Fixture {
    let persistence: PersistenceFixture
    let database: WorkspaceDatabase
    let workspaceID: String
    let conversationID: String
    let deviceID: String
    let libraryID: String
    init() async throws {
      persistence = try PersistenceFixture()
      database = try await persistence.openDatabase()
      libraryID = try await database.libraryIdentity().libraryID
      deviceID = UUID().uuidString.lowercased()
      workspaceID = UUID().uuidString.lowercased()
      conversationID = UUID().uuidString.lowercased()
      _ = try await database.registerExecutionWorkspace(.init(workspace: .init(
        id: workspaceID, libraryID: libraryID, ownerDeviceID: deviceID, kind: .ios, name: "Fixture iPhone",
        executionDeviceID: deviceID)), deviceID: deviceID)
      _ = try await database.ingestLibraryJournal(.init(libraryID: libraryID, entries: [
        .init(workspaceID: workspaceID, originSequence: 1, conversationID: conversationID, kind: .conversation,
          conversation: .init(id: conversationID, title: "Hey", runtimeKind: "piDurable"))
      ]), deviceID: deviceID)
    }
    func entry(_ value: LibraryTranscript, sequence: Int64) -> LibraryJournalEntry {
      .init(workspaceID: workspaceID, originSequence: sequence, conversationID: conversationID, kind: .transcript, transcript: value)
    }
    func ingest(_ entries: [LibraryJournalEntry]) async throws {
      _ = try await database.ingestLibraryJournal(.init(libraryID: libraryID, entries: entries), deviceID: deviceID)
    }
    func projection() -> LibraryTranscript {
      DeviceTranscript.project(snapshot: ["entries": [
        ["id": 1, "model": [["role": "user", "content": "Tool: this is actual user text", "timestamp": 1_000]]],
        ["id": 2, "model": [["role": "assistant", "content": [["type": "toolCall", "id": "files", "name": "list_files", "arguments": [:]]], "timestamp": 2_000]]],
        ["id": 3, "model": [["role": "toolResult", "toolCallId": "files", "content": [["type": "text", "text": "[]"]], "timestamp": 3_000]]]
      ]], conversationID: conversationID)
    }
    func remove() { persistence.remove() }
  }
}
