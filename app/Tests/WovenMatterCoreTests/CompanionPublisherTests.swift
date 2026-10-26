import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Execution owner publication", .serialized)
@MainActor
struct CompanionPublisherTests {

  @Test func retainedPreflightSettlesMultipleStaleRunsButNeverTransfersAnActualActiveRun() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let conversationID = try await f.database.createFixtureRemoteACPSession(runtimeKind: .codex, remoteWorkspaceID: UUID(uuidString: f.workspace.id)!, remoteWorkspaceName: "Linux", title: "Offline history", ownerDeviceID: UUID(uuidString: f.identity.hostDeviceID)!)
    let firstRun = try await f.database.beginLocalACPRun(conversationID: conversationID, content: "First")
    try await f.database.updateLocalACPSessionID(conversationID: conversationID, runID: firstRun.runID, sessionID: "native")
    let secondRun = UUID().uuidString.lowercased()
    try await f.database.write { try $0.companionExecuteUnlocked("INSERT INTO dashboard_runs(id,conversation_id,status,openclaw_session_key) VALUES (?,?,'running','native')", values: [secondRun, conversationID]) }
    func entry(_ run: String, _ sequence: Int64) -> CompanionJournalEntry {
      .init(workspaceID: f.workspace.id, originSequence: sequence, conversationID: conversationID, runID: run, kind: .conversation,
        conversation: .init(id: conversationID, title: "Offline history", runtimeKind: "codex"),
        retainedExecution: .init(source: "task-gateway", nativeSessionID: "native", runtimeKind: "codex", runID: run, status: "completed"))
    }
    let entries = [entry(firstRun.runID, 1), entry(secondRun, 2)]
    let first = CompanionJournalBatch(libraryID: f.identity.libraryID, entries: [entries[0]])
    let all = CompanionJournalBatch(libraryID: f.identity.libraryID, entries: entries)
    let path = "/v1/federation/publisher/retained/settle"
    #expect(try await CompanionWorkspacePublisherAPI.handle(f.request(path, first), path: path, database: f.database).status == 200)
    #expect(try await f.database.companionExecutionOwner(conversationID: conversationID) == nil)
    await #expect(throws: (any Error).self) { _ = try await f.database.ingestCompanionJournal(first, deviceID: f.workspace.executionDeviceID!) }
    #expect(try await CompanionWorkspacePublisherAPI.handle(f.request(path, all), path: path, database: f.database).status == 200)
    #expect(try await CompanionWorkspacePublisherAPI.handle(f.request(path, all), path: path, database: f.database).status == 200)
    var changed = first; changed.entries[0].retainedExecution?.status = "failed"
    await #expect(throws: (any Error).self) { _ = try await f.database.settleCompanionRetainedRuns(changed, deviceID: f.workspace.executionDeviceID!) }
    let active = UUID().uuidString.lowercased()
    try await f.database.write { try $0.companionExecuteUnlocked("INSERT INTO dashboard_runs(id,conversation_id,status,openclaw_session_key) VALUES (?,?,'running','native')", values: [active, conversationID]) }
    await #expect(throws: (any Error).self) { _ = try await f.database.ingestCompanionJournal(all, deviceID: f.workspace.executionDeviceID!) }
    #expect(try await f.database.read { try $0.companionIDsUnlocked("SELECT status FROM dashboard_runs WHERE id=?", bindings: [active]).first } == "running")
    #expect(try await f.database.companionExecutionOwner(conversationID: conversationID) == nil)
    try await f.database.write { try $0.companionExecuteUnlocked("UPDATE dashboard_runs SET status='completed' WHERE id=?", values: [active]) }
    _ = try await f.database.ingestCompanionJournal(all, deviceID: f.workspace.executionDeviceID!)
    #expect(try await f.database.companionExecutionOwner(conversationID: conversationID) == f.workspace.id)
    #expect(try await f.database.companionJournal(after: 0).entries.map(\.eventID) == entries.map(\.eventID))
  }

  private struct Fixture {
    let directory: URL, database: WorkspaceDatabase, identity: CompanionLibraryIdentity, workspace: CompanionExecutionWorkspace, grant: CompanionWorkspacePublisherGrant
    init() async throws {
      directory = FileManager.default.temporaryDirectory.appending(path: "wm-publisher-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
      identity = try await database.companionLibraryIdentity()
      workspace = try await database.registerCompanionExecutionWorkspace(.init(workspace: .init(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
        ownerDeviceID: identity.hostDeviceID, kind: .linux, name: "Linux", executionDeviceID: UUID().uuidString.lowercased(), journalDeviceIDs: [identity.hostDeviceID, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"])), deviceID: identity.hostDeviceID)
      grant = try await database.issueCompanionWorkspacePublisher(workspaceID: workspace.id, endpoint: URL(string: "https://central.tail.ts.net/wovenmatter")!, deviceID: identity.hostDeviceID)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func request<T: Encodable>(_ path: String, _ value: T, libraryID: String? = nil) throws -> CompanionHTTPRequest {
      .init(method: "POST", target: path, headers: ["authorization": "Bearer " + grant.token, "x-woven-workspace": libraryID ?? identity.libraryID], body: try JSONEncoder().encode(value))
    }
    func batch() -> CompanionJournalBatch {
      let id = UUID().uuidString.lowercased()
      return .init(libraryID: identity.libraryID, entries: [.init(workspaceID: workspace.id, originSequence: 1, conversationID: id, kind: .conversation, conversation: .init(id: id, title: "Owner history"))])
    }
  }

}
