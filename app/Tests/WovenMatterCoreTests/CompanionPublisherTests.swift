import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Execution owner publication", .serialized)
@MainActor
struct CompanionPublisherTests {

  @Test func observerAndCentralManagerCannotRelayEvenWithLegacyJournalGrants() async throws {
    let f = try await Fixture(); defer { f.remove() }; let batch = f.batch()
    for observer in [f.identity.hostDeviceID, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"] {
      await #expect(throws: (any Error).self) { _ = try await f.database.ingestCompanionJournal(batch, deviceID: observer) }
    }
    #expect(try await f.database.companionJournal(after: 0).entries.isEmpty)
    let path = "/v1/federation/publisher/journal"
    #expect(try await CompanionWorkspacePublisherAPI.handle(f.request(path, batch), path: path, database: f.database).status == 200)
    #expect(try await CompanionWorkspacePublisherAPI.handle(f.request(path, batch), path: path, database: f.database).status == 200)
    #expect(try await f.database.companionJournal(after: 0).entries.count == 1)
  }


  @Test func retainedOwnerCompletesOnlyItsExactStaleRunningLegacyRun() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let conversationID = try await f.database.createRemoteACPSession(runtimeKind: .codex, remoteWorkspaceID: UUID(uuidString: f.workspace.id)!, remoteWorkspaceName: "Linux", title: "Legacy", ownerDeviceID: UUID(uuidString: f.identity.hostDeviceID)!)
    let run = try await f.database.beginLocalACPRun(conversationID: conversationID, content: "Work")
    try await f.database.updateLocalACPSessionID(conversationID: conversationID, runID: run.runID, sessionID: "exact-native")
    #expect(try await f.database.companionRetainedAssociation(workspaceID: f.workspace.id, runID: run.runID, nativeSessionID: "wrong-native") == nil)
    #expect(try await f.database.companionRetainedAssociation(workspaceID: UUID().uuidString.lowercased(), runID: run.runID, nativeSessionID: "exact-native") == nil)
    let proof = CompanionRetainedExecution(source: "task-gateway", nativeSessionID: "exact-native", runtimeKind: "codex", runID: run.runID, status: "completed")
    var event = CompanionJournalEntry(workspaceID: f.workspace.id, originSequence: 1, conversationID: conversationID, runID: run.runID, kind: .conversation,
      conversation: .init(id: conversationID, title: "Legacy", runtimeKind: "codex"), retainedExecution: proof)
    let path = "/v1/federation/publisher/journal"
    event.retainedExecution?.nativeSessionID = "mismatched"
    await #expect(throws: (any Error).self) {
      _ = try await CompanionWorkspacePublisherAPI.handle(f.request(path, CompanionJournalBatch(libraryID: f.identity.libraryID, entries: [event])), path: path, database: f.database)
    }
    #expect(try await f.database.companionExecutionOwner(conversationID: conversationID) == nil)
    event.retainedExecution = proof
    let response = try await CompanionWorkspacePublisherAPI.handle(f.request(path, CompanionJournalBatch(libraryID: f.identity.libraryID, entries: [event])), path: path, database: f.database)
    #expect(response.status == 200)
    #expect(try await f.database.companionExecutionOwner(conversationID: conversationID) == f.workspace.id)
    #expect(try await f.database.read { try $0.companionIDsUnlocked("SELECT status FROM dashboard_runs WHERE id=?", bindings: [run.runID]).first } == "completed")
    // A second retained run in the same native session needs its own exact proof.
    let nextRun = UUID().uuidString.lowercased()
    try await f.database.write { try $0.companionExecuteUnlocked("INSERT INTO dashboard_runs(id,conversation_id,status,openclaw_session_key) VALUES (?,?,'completed','exact-native')", values: [nextRun, conversationID]) }
    event.eventID = UUID().uuidString.lowercased(); event.originSequence = 2; event.runID = nextRun
    event.retainedExecution?.runID = nextRun
    #expect(try await CompanionWorkspacePublisherAPI.handle(f.request(path, CompanionJournalBatch(libraryID: f.identity.libraryID, entries: [event])), path: path, database: f.database).status == 200)
    #expect(try await f.database.read { try $0.companionIDsUnlocked("SELECT workspace_id FROM companion_execution_runs WHERE id=?", bindings: [nextRun]).first } == f.workspace.id)
  }

  @Test func retainedPreflightSettlesMultipleStaleRunsButNeverTransfersAnActualActiveRun() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let conversationID = try await f.database.createRemoteACPSession(runtimeKind: .codex, remoteWorkspaceID: UUID(uuidString: f.workspace.id)!, remoteWorkspaceName: "Linux", title: "Offline history", ownerDeviceID: UUID(uuidString: f.identity.hostDeviceID)!)
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
  @Test func publisherIsScopedAndCannotBecomePairedDeviceCredential() async throws {
    let f = try await Fixture(); defer { f.remove() }; let path = "/v1/federation/publisher/journal"
    var batch = f.batch(); batch.entries[0].workspaceID = UUID().uuidString.lowercased()
    #expect(try await CompanionWorkspacePublisherAPI.handle(f.request(path, batch), path: path, database: f.database).status == 403)
    #expect(try await CompanionWorkspacePublisherAPI.handle(f.request(path, f.batch(), libraryID: UUID().uuidString.lowercased()), path: path, database: f.database).status == 409)
    let authentication = try CompanionAuthentication(fileURL: f.directory.appending(path: "paired.json"))
    await #expect(throws: (any Error).self) { _ = try await authentication.authenticate(bearer: f.grant.token) }
    for forbidden in ["/v1/federation/publisher/workspaces", "/v1/federation/publisher/mutations", "/v1/federation/publisher/commands"] {
      #expect(try await CompanionWorkspacePublisherAPI.handle(f.request(forbidden, [String:String]()), path: forbidden, database: f.database).status == 404)
    }
  }
  @Test func retainedOwnerCannotClaimLocalSessionOrConflictWithAnotherActiveRun() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let conversationID = try await f.database.createLocalACPSession(runtimeKind: .codex, title: "Local", ownerDeviceID: UUID())
    let run = try await f.database.beginLocalACPRun(conversationID: conversationID, content: "Local work")
    try await f.database.updateLocalACPSessionID(conversationID: conversationID, runID: run.runID, sessionID: "native")
    let event = CompanionJournalEntry(workspaceID: f.workspace.id, originSequence: 1, conversationID: conversationID, runID: run.runID, kind: .conversation,
      conversation: .init(id: conversationID, title: "Claim"), retainedExecution: .init(source: "task-gateway", nativeSessionID: "native", runtimeKind: "codex", runID: run.runID, status: "completed"))
    await #expect(throws: (any Error).self) { _ = try await f.database.ingestCompanionJournal(.init(libraryID: f.identity.libraryID, entries: [event]), deviceID: f.workspace.executionDeviceID!) }
    #expect(try await f.database.companionExecutionOwner(conversationID: conversationID) == nil)
    try await f.database.write { try $0.companionExecuteUnlocked("UPDATE desktop_local_acp_sessions SET remote_workspace_id=? WHERE conversation_id=?", values: [f.workspace.id, conversationID]) }
    let conflict = UUID().uuidString.lowercased()
    try await f.database.write { try $0.companionExecuteUnlocked("INSERT INTO dashboard_runs(id,conversation_id,status) VALUES (?,?,'running')", values: [conflict, conversationID]) }
    await #expect(throws: (any Error).self) { _ = try await f.database.ingestCompanionJournal(.init(libraryID: f.identity.libraryID, entries: [event]), deviceID: f.workspace.executionDeviceID!) }
    #expect(try await f.database.companionExecutionOwner(conversationID: conversationID) == nil)
  }

  @Test func publisherDigestPersistsAndRotationRevokesOriginalScope() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let reopened = try await WorkspaceDatabase(url: f.directory.appending(path: "workspace.sqlite"))
    #expect(try await reopened.authenticateCompanionWorkspacePublisher(bearer: f.grant.token).workspaceID == f.workspace.id)
    let next = try await reopened.issueCompanionWorkspacePublisher(workspaceID: f.workspace.id, endpoint: f.grant.endpoint, deviceID: f.identity.hostDeviceID)
    await #expect(throws: (any Error).self) { _ = try await reopened.authenticateCompanionWorkspacePublisher(bearer: f.grant.token) }
    #expect(try await reopened.authenticateCompanionWorkspacePublisher(bearer: next.token).executionDeviceID == f.workspace.executionDeviceID)
    for suffix in ["", "-wal"] {
      if let bytes = try? Data(contentsOf: f.directory.appending(path: "workspace.sqlite" + suffix)) {
        #expect(bytes.range(of: Data(next.token.utf8)) == nil && bytes.range(of: Data(f.grant.token.utf8)) == nil)
      }
    }
  }
}
