import Foundation
import Testing
import WorkspaceFixtures
import WovenMatterCore
@testable import WovenMatterLibraryStore

/// A damaged row does not take a list down with it: the list shows every
/// row it can read, the damaged one is left out and reported, and reading
/// that one row itself fails.
@Suite struct UnreadableRecordsTests {
  @Test func aDamagedRowIsLeftOutOfItsListAndReported() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let database = try await fixture.openDatabase()
    let identity = try await database.libraryIdentity()
    #expect(try await database.unreadableRecords().isEmpty)

    // A workspace, a goal, an agent and a note this build reads, and one of each it cannot.
    let workspace = try await database.registerExecutionWorkspace(.init(workspace: .init(id: UUID().uuidString.lowercased(),
      libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Mac", executionDeviceID: identity.hostDeviceID)),
      deviceID: identity.hostDeviceID)
    var damaged = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any])
    let damagedWorkspace = UUID().uuidString.lowercased()
    damaged["id"] = damagedWorkspace; damaged["kind"] = "hologram"
    let chat = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "With a goal", ownerDeviceID: UUID())
    let damagedChat = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "With a damaged goal", ownerDeviceID: UUID())
    _ = try await database.mutateGoal(sessionID: chat, mutation: .set(objective: "Ship it", tokenBudget: nil, turnBudget: nil))
    let note = try await database.createNote(folderID: nil, title: "Kept"), damagedNote = try await database.createNote(folderID: nil, title: "Damaged")
    let agents = try await database.workspaceAgents().count
    let damagedAgent = UUID().uuidString.lowercased()
    let payload = String(decoding: try JSONSerialization.data(withJSONObject: damaged), as: UTF8.self)
    try await database.write {
      try $0.toolsExecuteUnlocked("INSERT INTO execution_workspaces(id,owner_device_id,revision,deleted,payload) VALUES (?,?,1,0,?)",
                                  [damagedWorkspace, identity.hostDeviceID, payload])
      try $0.toolsExecuteUnlocked("INSERT INTO session_goals(session_id,value) VALUES (?,?)", [damagedChat, #"{"objective":7}"#])
      try $0.toolsExecuteUnlocked("INSERT INTO agents(id,execution_location,runtime_kind,status) VALUES (?,'remote','hologram','ready')", [damagedAgent])
      try $0.toolsExecuteUnlocked("UPDATE notes SET is_pinned='yes' WHERE id=?", [damagedNote])
    }

    // Each list still shows what it can read.
    #expect(try await database.libraryExecutionWorkspaces().map(\.id) == [workspace.id])
    #expect(try await database.libraryConnectionWorkspaces(activeDeviceIDs: []).map(\.id) == [workspace.id])
    #expect(try await database.sessionGoals().map(\.sessionID) == [chat])
    #expect(try await database.workspaceAgents().count == agents)
    #expect(try await database.workspaceOverview().notes.map(\.id) == [note])
    // What was left out is reported, by what it is and its ID.
    #expect(try await database.unreadableRecords() == [
      .init(kind: "agent", id: damagedAgent), .init(kind: "goal", id: damagedChat),
      .init(kind: "note", id: damagedNote), .init(kind: "workspace", id: damagedWorkspace),
    ].sorted { ($0.kind, $0.id) < ($1.kind, $1.id) })
    // The damaged row itself does not read as missing, so nothing replaces it.
    await #expect(throws: DecodingError.self) { _ = try await database.read { try $0.federationWorkspaceUnlocked(damagedWorkspace) } }
    var replacement = workspace; replacement.id = damagedWorkspace
    await #expect(throws: DecodingError.self) {
      _ = try await database.registerExecutionWorkspace(.init(workspace: replacement), deviceID: identity.hostDeviceID)
    }

    // Once a row reads again it is no longer reported.
    try await database.write {
      try $0.toolsExecuteUnlocked("DELETE FROM execution_workspaces WHERE id=?", [damagedWorkspace])
      try $0.toolsExecuteUnlocked("DELETE FROM session_goals WHERE session_id=?", [damagedChat])
      try $0.toolsExecuteUnlocked("DELETE FROM agents WHERE id=?", [damagedAgent])
    }
    _ = try await database.libraryExecutionWorkspaces(); _ = try await database.sessionGoals(); _ = try await database.workspaceAgents()
    #expect(try await database.unreadableRecords() == [.init(kind: "note", id: damagedNote)])
  }

  @Test func recordsAreNamedInWords() {
    #expect(WorkspaceDatabaseConnection.recordKind(WorkspaceNoteRecord.self) == "note")
    #expect(WorkspaceDatabaseConnection.recordKind(WorkspaceConversationRecord.self) == "conversation")
    #expect(WorkspaceDatabaseConnection.recordKind(WorkspaceLibraryItem.self) == "library item")
  }
}
