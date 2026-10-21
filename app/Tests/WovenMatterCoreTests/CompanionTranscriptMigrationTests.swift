import Foundation
import SQLite3
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct CompanionTranscriptMigrationTests {

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
