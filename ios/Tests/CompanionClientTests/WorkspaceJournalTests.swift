import XCTest
import WovenMatterCompanion
@testable import CompanionClient

private actor OfflineWorkspace: ExecutionWorkspaceTransport {
  var receipts: [String: CompanionCommandReceipt] = [:]
  var executed: [CompanionCommand] = []
  var loseReply: Bool
  init(loseReply: Bool = true) { self.loseReply = loseReply }
  func identity() -> CompanionExecutionWorkspace { .init(id: "linux", libraryID: "library", ownerDeviceID: "mac", kind: .linux, name: "Server", revision: 1) }
  func providers() -> [CompanionProvider] { [] }
  func pending() -> [CompanionPendingInteraction] { [] }
  func command(_ command: CompanionCommand) throws -> CompanionCommandReceipt {
    if let receipt = receipts[command.commandID] { return receipt }
    executed.append(command)
    let result = CompanionCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .completed, conversationID: command.conversationID)
    receipts[command.commandID] = result
    if loseReply { loseReply = false; throw URLError(.networkConnectionLost) }
    return result
  }
  func receipt(_ id: String) -> CompanionCommandReceipt? { receipts[id] }
  func events(after: Int64) -> CompanionJournalPage { .init(libraryID: "library", cursor: after) }
  func conversations() -> [CompanionConversation] { [] }
  func transcript(_ id: String) -> CompanionTranscript { .init(conversationID: id) }
}

final class WorkspaceJournalTests: XCTestCase {
  private func path() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json") }
  private func entry(_ sequence: Int64, workspace: String = "phone", id: String = "chat") -> CompanionJournalEntry {
    .init(eventID: "event-\(workspace)-\(sequence)", workspaceID: workspace, originSequence: sequence,
      conversationID: id, kind: .conversation, conversation: .init(id: id, title: "Version \(sequence)"))
  }
  func testAuthenticatedPeerRegistryKeepsForeignExecutionNamespaceAcrossRestart() async throws {
    let file = path(), journal = try WorkspaceJournal(file: file)
    try await journal.bind(libraryID: "air-library")
    let remote = CompanionExecutionWorkspace(id: "linux", libraryID: "mini-library", ownerDeviceID: "mini", kind: .linux, name: "Server")
    do { try await journal.upsertWorkspace(remote); XCTFail("Untrusted registration cannot change the library namespace") }
    catch WorkspaceJournal.Failure.wrongLibrary { }
    try await journal.mergeRegistry([remote])
    let page = CompanionJournalPage(libraryID: "mini-library", cursor: 1, entries: [entry(1, workspace: "linux")])
    try await journal.receiveWorkspace(page, workspaceID: "linux")
    let reopened = try WorkspaceJournal(file: file)
    let state = await reopened.snapshot()
    XCTAssertEqual(state.libraryID, "air-library")
    XCTAssertEqual(state.workspaces["linux"]?.libraryID, "mini-library")
    XCTAssertEqual(state.conversationWorkspaceIDs["chat"], "linux")
    XCTAssertEqual(state.directCursors["linux"], 1)
    XCTAssertTrue(state.pendingRegistrations.isEmpty)
    do {
      try await reopened.receiveWorkspace(.init(libraryID: "air-library", cursor: 1), workspaceID: "linux")
      XCTFail("Direct replay must match the actual execution namespace")
    } catch WorkspaceJournal.Failure.wrongLibrary { }
  }
  func testDirectControlCommandsPersistOwnerBeforeDispatchAndRejectMismatches() async throws {
    let store = try MobileStore(file: path()), transport = OfflineWorkspace(loseReply: false)
    let client = WorkspaceClient(store: store, workspaceID: "linux", transport: transport)
    let command = CompanionCommand(deviceID: "phone", kind: .respond, conversationID: "chat", runID: "run",
      interactionID: "approval", response: .init(optionID: "allow"))
    _ = try await client.submit(command)
    let executed = await transport.executed
    XCTAssertEqual(executed.count, 1)
    XCTAssertEqual(executed.first?.workspaceID, "linux")
    XCTAssertEqual(executed.first?.conversationID, "chat")
    let stored = await store.journal.commandRecords(workspaceID: "linux")
    XCTAssertEqual(stored.first?.command, executed.first)
    var wrongOwner = command
    wrongOwner.commandID = UUID().uuidString.lowercased()
    wrongOwner.workspaceID = "another-workspace"
    do { _ = try await client.submit(wrongOwner); XCTFail("Explicit ownership must not be overwritten") }
    catch MobileStore.Failure.wrongWorkspace {}
    let callsAfterMismatch = await transport.executed
    let recordsAfterMismatch = await store.journal.commandRecords(workspaceID: "linux")
    XCTAssertEqual(callsAfterMismatch.count, 1)
    XCTAssertEqual(recordsAfterMismatch.count, 1)
  }
  func testAgentAuthoredProvenanceSurvivesOwnerJournalChunkingAndRestart() async throws {
    let file = path(), journal = try WorkspaceJournal(file: file)
    let message = CompanionMessage(id: "agent-input", conversationID: "target", role: "user",
      content: String(repeating: "Agent assignment. ", count: 2_000), agentSourceID: "source", isAgentAuthored: true,
      senderSessionTitle: "Research", senderHarness: "codex", senderKind: "message")
    _ = try await journal.append(workspaceID: "linux-owner", conversation: .init(id: "target", title: "Target"),
      transcript: .init(conversationID: "target", messages: [message]))
    let reopened = try WorkspaceJournal(file: file)
    let state = await reopened.snapshot()
    let messages = try XCTUnwrap(state.transcripts["target"]).messages
    XCTAssertGreaterThan(messages.count, 1)
    XCTAssertEqual(messages.map(\.content).joined(), message.content)
    XCTAssertTrue(messages.allSatisfy { $0.role == "user" && $0.isAgentAuthored == true && $0.agentSourceID == "source" && $0.senderSessionTitle == "Research" && $0.senderHarness == "codex" })
    XCTAssertEqual(state.conversationWorkspaceIDs["target"], "linux-owner")
  }

  func testNativeHistoryIsChunkedWithoutTruncationAndRetriedIdempotently() async throws {
    let file = path(); let journal = try WorkspaceJournal(file: file)
    let bytes = Data(repeating: 71, count: 150_000)
    let parts = try await journal.appendNativeRecord(workspaceID: "phone", conversationID: "chat", recordID: "native-1", format: "pi-json", data: bytes)
    XCTAssertEqual(parts.count, 3)
    XCTAssertEqual(parts.flatMap { $0.nativeRecord!.data }, Array(bytes))
    let restarted = try WorkspaceJournal(file: file)
    let retry = try await restarted.appendNativeRecord(workspaceID: "phone", conversationID: "chat", recordID: "native-1", format: "pi-json", data: bytes)
    XCTAssertEqual(parts, retry)
    let state = await restarted.snapshot(); XCTAssertEqual(state.pendingEntries.count, 3)
  }
  func testExplicitRestoreRecoversTrashedTranscriptWithoutReexecutingHistory() async throws {
    let store = try MobileStore(file: path())
    let conversation = CompanionConversation(id: "chat", title: "Recover")
    let transcript = CompanionTranscript(conversationID: "chat", messages: [.init(id: "message", conversationID: "chat", role: "assistant", content: "Keep complete")])
    _ = try await store.journal.append(workspaceID: "phone", conversation: conversation, transcript: transcript)
    try await store.journal.deleteConversation(workspaceID: "phone", conversationID: "chat")
    try await store.restoreExecutionProjection()
    var state = await store.snapshot(); XCTAssertNil(state.conversations["chat"])
    try await store.journal.restoreConversation(workspaceID: "phone", conversation: conversation)
    try await store.restoreExecutionProjection()
    state = await store.snapshot()
    XCTAssertEqual(state.conversations["chat"], conversation); XCTAssertEqual(state.transcripts["chat"], transcript)
    XCTAssertTrue(state.commands.isEmpty)
  }
  func testConversationNativeRecordAndCommandIdentitiesRemainBoundToOwnerAndPayload() async throws {
    let journal = try WorkspaceJournal(file: path())
    try await journal.record(entry(1, workspace: "owner", id: "first"))
    do { try await journal.record(entry(1, workspace: "other", id: "first")); XCTFail() }
    catch WorkspaceJournal.Failure.reusedIdentity {}
    let owner = await journal.snapshot().conversationWorkspaceIDs["first"]
    XCTAssertEqual(owner, "owner")
    _ = try await journal.appendNativeRecord(workspaceID: "owner", conversationID: "first", runID: "run", recordID: "native-entry", format: "fixture", data: Data("identical bytes".utf8))
    do {
      _ = try await journal.appendNativeRecord(workspaceID: "owner", conversationID: "second", runID: "run", recordID: "native-entry", format: "fixture", data: Data("identical bytes".utf8))
      XCTFail("Distinct native records cannot share identity even when their bodies match")
    } catch WorkspaceJournal.Failure.reusedIdentity { }
    let command = CompanionCommand(deviceID: "device", kind: .send, conversationID: "first", text: "Original")
    _ = try await journal.rememberCommand(command, workspaceID: "owner")
    var changed = command; changed.text = "Changed"
    do { _ = try await journal.rememberCommand(changed, workspaceID: "owner"); XCTFail("A command identity must keep its original payload") }
    catch WorkspaceJournal.Failure.reusedIdentity { }
    let state = await journal.snapshot()
    XCTAssertEqual(state.entries.count, 2)
    XCTAssertEqual(state.entries.values.filter { $0.kind == .conversation }.count, 1)
    XCTAssertEqual(state.entries.values.filter { $0.kind == .nativeRecord }.count, 1)
    XCTAssertEqual(state.commands.values.first?.command, command)
  }

  func testWorkspaceNoteImportPreservesIdentityAndDoesNotResurrectDeletedNote() async throws {
    let store = try MobileStore(file: path())
    let note = CompanionNote(id: "agent-note", title: "Result", content: "saved output", revision: 3)
    try await store.apply(CompanionSnapshot(workspaceID: "library", cursor: 1, notes: [note]))
    try await store.apply(CompanionChangePage(workspaceID: "library", cursor: 2, changes: [.init(cursor: 2, resourceKind: .note, resourceID: note.id, operation: .delete, revision: 4)]))
    var changed = note; changed.content = "agent output after deletion"
    try await store.importWorkspaceNote(changed, base: note)
    let state = await store.snapshot()
    XCTAssertEqual(state.conflicts[note.id]?.local.content, changed.content)
    XCTAssertTrue(state.outbox.isEmpty)
    let created = CompanionNote(id: "created-by-agent", title: "New", content: "new output", revision: 0)
    try await store.importWorkspaceNote(created)
    let saved = await store.snapshot(); XCTAssertEqual(saved.outbox.first?.mutation.resourceID, created.id)
  }
  func testWorkspaceDeletionRetainsBackupUntilAcknowledgementAndRestoresConflict() async throws {
    let file = path(); let store = try MobileStore(file: file)
    let note = CompanionNote(id: "note", title: "Keep", content: "original", revision: 4)
    try await store.apply(CompanionSnapshot(workspaceID: "library", cursor: 1, notes: [note]))
    try await store.deleteWorkspaceNote(id: note.id, base: note)
    let sent = try await store.nextMutation()!
    let restarted = try MobileStore(file: file)
    let retry = try await restarted.nextMutation(); XCTAssertEqual(retry, sent)
    var remote = note; remote.revision = 5; remote.content = "Someone changed this"
    try await restarted.acknowledge(.init(operationID: sent.operationID, status: .conflict, note: remote))
    let state = await restarted.snapshot()
    XCTAssertEqual(state.conflicts[note.id]?.local.content, "original")
    XCTAssertEqual(state.conflicts[note.id]?.remote?.content, remote.content)
    XCTAssertTrue(state.outbox.isEmpty)
    XCTAssertNil(state.pendingNoteDeletions?[note.id])
  }
}
