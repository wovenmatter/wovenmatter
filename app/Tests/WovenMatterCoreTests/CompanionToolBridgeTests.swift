import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Companion central CLI authority and receipts", .serialized)
@MainActor
struct CompanionToolBridgeTests {
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
    let relayed = try await fixture.importSession(kind: .linux, executionDeviceID: UUID().uuidString.lowercased())
    spoof.conversationID = relayed
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
      let workspace = try await database.registerCompanionExecutionWorkspace(.init(workspace: .init(
        id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: deviceID,
        kind: kind, name: "Device", executionDeviceID: executionDeviceID)), deviceID: deviceID)
      _ = try await database.ingestCompanionJournal(.init(libraryID: identity.libraryID, entries: [
        .init(workspaceID: workspace.id, originSequence: 1, conversationID: conversationID, kind: .conversation,
          conversation: .init(id: conversationID, title: "Phone agent", runtimeKind: "piDurable"))
      ]), deviceID: deviceID)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
