import XCTest
import WovenMatterShared
@testable import LibraryClient

private actor OfflineWorkspace: ExecutionWorkspaceTransport {
  var receipts: [String: LibraryCommandReceipt] = [:]
  var executed: [LibraryCommand] = []
  func identity() -> ExecutionWorkspace { .init(id: "linux", libraryID: "library", ownerDeviceID: "mac", kind: .linux, name: "Server", revision: 1) }
  func providers() -> [HarnessCapabilities] { [] }
  func pending() -> [PendingInteraction] { [] }
  func command(_ command: LibraryCommand) throws -> LibraryCommandReceipt {
    if let receipt = receipts[command.commandID] { return receipt }
    executed.append(command)
    let result = LibraryCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .completed, conversationID: command.conversationID)
    receipts[command.commandID] = result
    return result
  }
  func receipt(_ id: String) -> LibraryCommandReceipt? { receipts[id] }
  func events(after: Int64) -> ExecutionJournalPage { .init(libraryID: "library", cursor: after) }
  func conversations() -> [LibraryConversation] { [] }
  func transcript(_ id: String) -> LibraryTranscript { .init(conversationID: id) }
}

final class WorkspaceJournalTests: XCTestCase {
  private func path() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json") }
  private func entry(_ sequence: Int64, workspace: String = "phone", id: String = "chat") -> ExecutionJournalEntry {
    .init(eventID: "event-\(workspace)-\(sequence)", workspaceID: workspace, originSequence: sequence,
      conversationID: id, kind: .conversation, conversation: .init(id: id, title: "Version \(sequence)"))
  }
  func testAuthenticatedPeerRegistryKeepsForeignExecutionNamespaceAcrossRestart() async throws {
    let file = path(), journal = try WorkspaceJournal(file: file)
    try await journal.bind(libraryID: "air-library")
    let remote = ExecutionWorkspace(id: "linux", libraryID: "mini-library", ownerDeviceID: "mini", kind: .linux, name: "Server")
    do { try await journal.upsertWorkspace(remote); XCTFail("Untrusted registration cannot change the library namespace") }
    catch WorkspaceJournal.Failure.wrongLibrary { }
    try await journal.mergeRegistry([remote])
    let page = ExecutionJournalPage(libraryID: "mini-library", cursor: 1, entries: [entry(1, workspace: "linux")])
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
  /// A record a newer workspace wrote holds a place in its sequence. A page
  /// that names the place moves the cursor past it and the records after it
  /// are accepted; a gap nothing names still stops without advancing.
  func testANamedSkipAdvancesTheSequenceAndAnUnnamedGapStillStops() async throws {
    let journal = try WorkspaceJournal(file: path())
    try await journal.bind(libraryID: "library")
    try await journal.mergeRegistry([.init(id: "linux", libraryID: "library", ownerDeviceID: "mac", kind: .linux, name: "Server")])
    // As the workspace sends it: record 2 is of a kind this build does not know.
    var rows = try [1, 2, 3].map { try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry($0, workspace: "linux"))) as? [String: Any]) }
    rows[1]["kind"] = "forkedConversation"
    let body: [String: Any] = ["libraryID": "library", "cursor": 3, "hasMore": true, "entries": rows]
    let page = try JSONDecoder().decode(ExecutionJournalPage.self, from: JSONSerialization.data(withJSONObject: body))
    XCTAssertEqual(page.entries.map(\.originSequence), [1, 3])
    XCTAssertEqual(page.skipped, [.init(workspaceID: "linux", originSequence: 2)])
    try await journal.receiveWorkspace(page, workspaceID: "linux", localDeviceID: "phone")
    var state = await journal.snapshot()
    XCTAssertEqual(state.directCursors["linux"], 3)
    XCTAssertEqual(state.originSequences["linux"], 3)
    XCTAssertEqual(state.entries.values.map(\.originSequence).sorted(), [1, 3])
    XCTAssertEqual(state.conversations["chat"]?.title, "Version 3")
    XCTAssertTrue(state.pendingEventIDs.isEmpty, "An observer never publishes what it read")

    // The sequence continues, and a page that holds only a skip still advances.
    try await journal.receiveWorkspace(.init(libraryID: "library", cursor: 4, entries: [entry(4, workspace: "linux")]), workspaceID: "linux")
    try await journal.receiveWorkspace(.init(libraryID: "library", cursor: 5, hasMore: true, skipped: [.init(workspaceID: "linux", originSequence: 5)]), workspaceID: "linux")
    state = await journal.snapshot()
    XCTAssertEqual(state.directCursors["linux"], 5)
    XCTAssertEqual(state.originSequences["linux"], 5)

    // Only a named position is passed over.
    let refused: [ExecutionJournalPage] = [
      .init(libraryID: "library", cursor: 7, entries: [entry(7, workspace: "linux")]),
      .init(libraryID: "library", cursor: 7, entries: [entry(7, workspace: "linux")], skipped: [.init(workspaceID: "linux", originSequence: 9)]),
      .init(libraryID: "library", cursor: 7, entries: [entry(7, workspace: "linux")], skipped: [.init(workspaceID: "other", originSequence: 6)]),
      .init(libraryID: "library", cursor: 6, hasMore: true),
    ]
    for page in refused {
      do { try await journal.receiveWorkspace(page, workspaceID: "linux"); XCTFail("An unexplained gap was accepted") }
      catch WorkspaceJournal.Failure.replayGap { }
    }
    let cursor = await journal.snapshot().directCursors["linux"]
    XCTAssertEqual(cursor, 5)
    try await journal.receiveWorkspace(.init(libraryID: "library", cursor: 7, entries: [entry(7, workspace: "linux")],
      skipped: [.init(workspaceID: "linux", originSequence: 6)]), workspaceID: "linux")
    let final = await journal.snapshot().directCursors["linux"]
    XCTAssertEqual(final, 7)
  }

  /// The library's journal interleaves workspaces: a skip moves only its own
  /// workspace's sequence, in order with that workspace's entries.
  func testALibraryPageWithASkipKeepsEveryWorkspacesSequence() async throws {
    let journal = try WorkspaceJournal(file: path())
    try await journal.bind(libraryID: "library")
    let page = ExecutionJournalPage(libraryID: "library", cursor: 4, entries: [
      entry(1, workspace: "linux", id: "a"), entry(1, workspace: "other", id: "b"), entry(3, workspace: "linux", id: "a"),
    ], hasMore: true, skipped: [.init(workspaceID: "linux", originSequence: 2)])
    try await journal.receiveLibrary(page)
    var state = await journal.snapshot()
    XCTAssertEqual(state.libraryCursor, 4)
    XCTAssertEqual(state.originSequences, ["linux": 3, "other": 1])
    XCTAssertEqual(state.conversations["a"]?.title, "Version 3")
    // A position this device already holds is not passed over twice.
    try await journal.receiveLibrary(.init(libraryID: "library", cursor: 5, skipped: [.init(workspaceID: "linux", originSequence: 2)]))
    state = await journal.snapshot()
    XCTAssertEqual(state.libraryCursor, 5)
    XCTAssertEqual(state.originSequences["linux"], 3)
    for page in [ExecutionJournalPage(libraryID: "library", cursor: 6, entries: [entry(5, workspace: "linux", id: "a")]),
                 .init(libraryID: "library", cursor: 6, skipped: [.init(workspaceID: "other", originSequence: 3)])] {
      do { try await journal.receiveLibrary(page); XCTFail("An unexplained gap was accepted") }
      catch WorkspaceJournal.Failure.replayGap { }
    }
    let cursor = await journal.snapshot().libraryCursor
    XCTAssertEqual(cursor, 5)
  }

  /// This device publishes its own workspace's records in sequence, and a
  /// host refuses a missing one, so nothing of its own is ever skipped.
  func testTheExecutionOwnerNeverSkipsItsOwnRecords() async throws {
    let journal = try WorkspaceJournal(file: path())
    try await journal.upsertWorkspace(.init(id: "phone", libraryID: "library", ownerDeviceID: "phone", kind: .ios, name: "iPhone"))
    do {
      try await journal.receiveWorkspace(.init(libraryID: "library", cursor: 1, skipped: [.init(workspaceID: "phone", originSequence: 1)]),
                                         workspaceID: "phone", localDeviceID: "phone")
      XCTFail("The owner skipped its own record")
    } catch WorkspaceJournal.Failure.replayGap { }
    try await journal.receiveWorkspace(.init(libraryID: "library", cursor: 1, entries: [entry(1)]), workspaceID: "phone", localDeviceID: "phone")
    let pending = await journal.pendingOwnerEntries(deviceID: "phone").map(\.originSequence)
    XCTAssertEqual(pending, [1])
  }

  func testDirectControlCommandsPersistOwnerBeforeDispatchAndRejectMismatches() async throws {
    let store = try MobileStore(file: path()), transport = OfflineWorkspace()
    let client = WorkspaceClient(store: store, workspaceID: "linux", transport: transport)
    let command = LibraryCommand(deviceID: "phone", kind: .respond, conversationID: "chat", runID: "run",
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
    let message = LibraryMessage(id: "agent-input", conversationID: "target", role: "user",
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
    let conversation = LibraryConversation(id: "chat", title: "Recover")
    let transcript = LibraryTranscript(conversationID: "chat", messages: [.init(id: "message", conversationID: "chat", role: "assistant", content: "Keep complete")])
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
    let command = LibraryCommand(deviceID: "device", kind: .send, conversationID: "first", text: "Original")
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

  func testWorkspaceDeletionRetainsBackupUntilAcknowledgementAndRestoresConflict() async throws {
    let file = path(); let store = try MobileStore(file: file)
    let note = LibraryNote(id: "note", title: "Keep", content: "original", revision: 4)
    try await store.apply(LibrarySnapshot(workspaceID: "library", cursor: 1, notes: [note]))
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
