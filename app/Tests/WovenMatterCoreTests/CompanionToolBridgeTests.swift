import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Companion central CLI authority and receipts", .serialized)
@MainActor
struct CompanionToolBridgeTests {
  @Test func automationUploadBoundsAndCancellationRetainDeviceOwnership() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let data = Data(repeating: 0x41, count: 2 * 1_024 * 1_024).base64EncodedString()
    let payload = "{\"action\":\"upload\",\"data\":\"" + data + "\"}"
    let upload = fixture.request(["browser", "call", "--json", payload])
    try await fixture.database.authorizeCompanionTool(upload, deviceID: fixture.deviceID)
    let oversized = fixture.request(["browser", "call", "--json", String(repeating: "x", count: 3 * 1_024 * 1_024 + 1)])
    await #expect(throws: (any Error).self) {
      try await fixture.database.authorizeCompanionTool(oversized, deviceID: fixture.deviceID)
    }
    try await fixture.database.setSessionTools(.init(enabled: []), sessionID: fixture.conversationID)
    var cancel = fixture.request(["computer", "cancel", "--id", "all"]); cancel.enabledGroups = []
    try await fixture.database.authorizeCompanionTool(cancel, deviceID: fixture.deviceID)
    await #expect(throws: (any Error).self) {
      try await fixture.database.authorizeCompanionTool(cancel, deviceID: UUID().uuidString.lowercased())
    }
  }

  @Test func desktopResponsesAreNotStoredInTransportReceiptsOrReexecuted() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let request = fixture.request(["browser", "call", "--json", "{\"action\":\"tabs\"}"])
    let dispatcher = CompanionToolDispatcher(database: fixture.database)
    var executions = 0
    let result = try await dispatcher.execute(request, deviceID: fixture.deviceID) { _, _ in
      executions += 1; return .init(result: .string("synthetic page capture"))
    }
    #expect(result.result == .string("synthetic page capture"))
    let restarted = CompanionToolDispatcher(database: try await WorkspaceDatabase(url: fixture.url))
    let retry = try await restarted.execute(request, deviceID: fixture.deviceID) { _, _ in
      executions += 1; return .init()
    }
    #expect(executions == 1 && retry.code == "automation_outcome_recorded" && retry.result == nil)
  }

  @Test func ongoingAutomationRechecksDeviceExecutionAccess() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let identity = try await fixture.database.companionLibraryIdentity()
    let host = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: .init(
      id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
      kind: .mac, name: "Central Mac", executionDeviceID: identity.hostDeviceID)), deviceID: identity.hostDeviceID)
    try await fixture.database.requireCompanionAutomationAccess(callerID: fixture.conversationID)
    try await fixture.database.setCompanionWorkspaceAccess(deviceID: fixture.deviceID, workspaceID: host.id,
      enabled: false, authorizedBy: identity.hostDeviceID)
    await #expect(throws: (any Error).self) {
      try await fixture.database.requireCompanionAutomationAccess(callerID: fixture.conversationID)
    }
  }

  @Test func onlyActualExecutionDeviceCanUseItsImportedConversation() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let request = fixture.request(["notes", "list"])
    try await fixture.database.authorizeCompanionTool(request, deviceID: fixture.deviceID)
    await #expect(throws: (any Error).self) {
      try await fixture.database.authorizeCompanionTool(request, deviceID: UUID().uuidString.lowercased())
    }
    let local = try await fixture.database.createLocalACPSession(runtimeKind: .codex, title: "Mac", ownerDeviceID: UUID())
    var spoof = request; spoof.conversationID = local
    await #expect(throws: (any Error).self) {
      try await fixture.database.authorizeCompanionTool(spoof, deviceID: fixture.deviceID)
    }
    let foreign = try await fixture.importSession(kind: .linux, executionDeviceID: UUID().uuidString.lowercased())
    spoof.conversationID = foreign
    await #expect(throws: (any Error).self) {
      try await fixture.database.authorizeCompanionTool(spoof, deviceID: fixture.deviceID)
    }
  }

  @Test func clientSelectionCannotGrantDisabledCentralTools() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    var request = fixture.request(["notes", "list"])
    request.enabledGroups = []
    await #expect(throws: (any Error).self) {
      try await fixture.database.authorizeCompanionTool(request, deviceID: fixture.deviceID)
    }
    request.enabledGroups = [.notes]
    try await fixture.database.setSessionTools(.init(enabled: []), sessionID: fixture.conversationID)
    await #expect(throws: (any Error).self) {
      try await fixture.database.authorizeCompanionTool(request, deviceID: fixture.deviceID)
    }
    #expect(try await fixture.database.sessionTools(fixture.conversationID).enabled.isEmpty)
  }

  @Test func lostReplyAndRestartReturnOriginalResultWithoutRepeatingMutation() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let request = fixture.request(["notes", "create", "--title", "Phone note"])
    let dispatcher = CompanionToolDispatcher(database: fixture.database)
    var executions = 0
    let response = try await dispatcher.execute(request, deviceID: fixture.deviceID) { request, caller in
      executions += 1
      let id = try! await fixture.database.createNote(folderID: nil, title: "Phone note", kind: .note,
        callerConversationID: caller, requestID: request.requestID)
      return .init(result: .object(["id": .string(id)]), requestID: request.requestID)
    }
    #expect(response.success && executions == 1)
    let restartedDatabase = try await WorkspaceDatabase(url: fixture.url)
    let restarted = CompanionToolDispatcher(database: restartedDatabase)
    var retry = request
    retry.request.arguments += ["--request-id", request.request.requestID.uppercased()]
    let replay = try await restarted.execute(retry, deviceID: fixture.deviceID) { _, _ in
      executions += 1
      return .init(success: false)
    }
    #expect(replay.result == response.result && executions == 1)
    #expect(try await restartedDatabase.companionSnapshot().notes.count == 1)
    retry.request.arguments = ["notes", "create", "--title", "Different"]
    await #expect(throws: (any Error).self) {
      _ = try await restarted.execute(retry, deviceID: fixture.deviceID) { _, _ in
        executions += 1; return .init()
      }
    }
    #expect(executions == 1)
  }

  @Test func acceptedWorkWithoutRecordedOutcomeIsNotReexecuted() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let request = fixture.request(["notes", "create", "--title", "Unknown outcome"])
    #expect(try await fixture.database.reserveCompanionTool(request, deviceID: fixture.deviceID).isNew)
    let restarted = CompanionToolDispatcher(database: try await WorkspaceDatabase(url: fixture.url))
    var executed = false
    let response = try await restarted.execute(request, deviceID: fixture.deviceID) { _, _ in
      executed = true; return .init()
    }
    #expect(!executed && response.code == "outcome_unknown")
  }

  @Test func concurrentRetryAndCallerCancellationKeepOneAcceptedExecution() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let dispatcher = CompanionToolDispatcher(database: fixture.database)
    let request = fixture.request(["notes", "create", "--title", "Retained work"])
    var executions = 0
    var continuation: CheckedContinuation<Void, Never>?
    let initial = Task {
      try await dispatcher.execute(request, deviceID: fixture.deviceID) { _, caller in
        executions += 1
        #expect(caller == fixture.conversationID)
        await withCheckedContinuation { continuation = $0 }
        #expect(!Task.isCancelled)
        return .init(result: .string("completed"), requestID: request.request.requestID)
      }
    }
    let deadline = Date().addingTimeInterval(5)
    while continuation == nil, Date() < deadline { await Task.yield() }
    let release = try #require(continuation)
    initial.cancel()
    let retry = Task {
      try await dispatcher.execute(request, deviceID: fixture.deviceID) { _, _ in
        executions += 1; return .init(success: false)
      }
    }
    // Both calls join the same retained work regardless of which waiter resumes first.
    release.resume()
    #expect(try await initial.value.result == .string("completed"))
    #expect(try await retry.value.result == .string("completed"))
    #expect(executions == 1)
  }

  @Test func deletedConversationAndChangedEnvelopeDoNotAcquireAuthority() async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    var request = fixture.request(["notes", "list"])
    request.request.arguments += ["--request-id", UUID().uuidString.lowercased()]
    await #expect(throws: (any Error).self) {
      try await fixture.database.authorizeCompanionTool(request, deviceID: fixture.deviceID)
    }
    request = fixture.request(["notes", "list"])
    try await fixture.database.write { db in
      try db.companionExecuteUnlocked("UPDATE dashboard_conversations SET deleted_at='deleted' WHERE id=?", values: [fixture.conversationID])
    }
    await #expect(throws: (any Error).self) {
      try await fixture.database.authorizeCompanionTool(request, deviceID: fixture.deviceID)
    }
  }

  @Test(arguments: [NoteArtifactKind.spreadsheet, .html])
  func richArtifactsKeepKindAcrossCreateEditAndReplay(kind: NoteArtifactKind) async throws {
    let fixture = try await Fixture(); defer { fixture.remove() }
    let id = UUID().uuidString.lowercased()
    var document = NoteDocument(kind: kind, html: kind == .html ? "<h1>Original</h1>" : "")
    let create = CompanionMutation(deviceID: fixture.deviceID, kind: .createNote, resourceID: id,
      title: "Rich artifact", content: try document.encoded())
    let receipt = try await fixture.database.applyCompanionMutation(create)
    #expect(receipt.status == .accepted && receipt.note?.kind == kind)
    if kind == .html { document.html = "<h1>Edited</h1>" }
    else { document.blocks = [.table(.init(rows: 3, columns: 4, headerRow: true))] }
    let update = CompanionMutation(deviceID: fixture.deviceID, kind: .updateNote, resourceID: id,
      expectedRevision: receipt.note?.revision, title: "Edited artifact", content: try document.encoded())
    #expect(try await fixture.database.applyCompanionMutation(update).status == .accepted)
    #expect(try await fixture.database.applyCompanionMutation(create) == receipt)
    let stored = try #require(try await fixture.database.companionNote(id: id))
    #expect(stored.kind == kind)
    #expect(try NoteDocument.editableDocument(from: stored.content) == document)
  }

  private struct Fixture {
    let root: URL
    let url: URL
    let database: WorkspaceDatabase
    let deviceID: String
    let conversationID: String

    init() async throws {
      root = FileManager.default.temporaryDirectory.appending(path: "companion-tools-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      url = root.appending(path: "workspace.sqlite")
      database = try await WorkspaceDatabase(url: url)
      deviceID = UUID().uuidString.lowercased()
      conversationID = UUID().uuidString.lowercased()
      try await Self.importSession(database: database, deviceID: deviceID, conversationID: conversationID,
        kind: .ios, executionDeviceID: deviceID)
    }
    func request(_ arguments: [String]) -> CompanionToolRequest {
      .init(conversationID: conversationID, request: .init(arguments: arguments), enabledGroups: WorkspaceToolGroup.allCases)
    }
    func importSession(kind: CompanionExecutionWorkspace.Kind, executionDeviceID: String?) async throws -> String {
      let id = UUID().uuidString.lowercased()
      try await Self.importSession(database: database, deviceID: deviceID, conversationID: id,
        kind: kind, executionDeviceID: executionDeviceID)
      return id
    }
    static func importSession(database: WorkspaceDatabase, deviceID: String, conversationID: String,
                              kind: CompanionExecutionWorkspace.Kind, executionDeviceID: String?) async throws {
      let identity = try await database.companionLibraryIdentity()
      // Linux registration belongs to the central host; its execution owner
      // publishes history using a scoped grant, never through the observing phone.
      let registrar = kind == .linux ? identity.hostDeviceID : deviceID
      let workspace = try await database.registerCompanionExecutionWorkspace(.init(workspace: .init(
        id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: registrar,
        kind: kind, name: "Device", executionDeviceID: executionDeviceID)), deviceID: registrar)
      let batch = CompanionJournalBatch(libraryID: identity.libraryID, entries: [
        .init(workspaceID: workspace.id, originSequence: 1, conversationID: conversationID, kind: .conversation,
          conversation: .init(id: conversationID, title: "Device agent", runtimeKind: "piDurable"))
      ])
      if kind == .linux {
        let grant = try await database.issueCompanionWorkspacePublisher(workspaceID: workspace.id,
          endpoint: URL(string: "https://central.tail.ts.net/wovenmatter")!, deviceID: identity.hostDeviceID)
        let path = "/v1/federation/publisher/journal"
        let request = CompanionHTTPRequest(method: "POST", target: path,
          headers: ["authorization": "Bearer " + grant.token, "x-woven-workspace": identity.libraryID],
          body: try JSONEncoder().encode(batch))
        #expect(try await CompanionWorkspacePublisherAPI.handle(request, path: path, database: database).status == 200)
      } else {
        _ = try await database.ingestCompanionJournal(batch, deviceID: executionDeviceID ?? deviceID)
      }
      #expect(try await database.companionExecutionOwner(conversationID: conversationID) == workspace.id)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
