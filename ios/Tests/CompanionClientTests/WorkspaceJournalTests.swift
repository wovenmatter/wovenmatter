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
  func testRestartAndCentralLostAcknowledgementPreserveExactOriginRecord() async throws {
    let file = path(); let journal = try WorkspaceJournal(file: file)
    try await journal.bind(libraryID: "library")
    let value = entry(1); try await journal.record(value)
    let restarted = try WorkspaceJournal(file: file)
    let pending = await restarted.snapshot().pendingEntries
    XCTAssertEqual(pending, [value])
    try await restarted.record(value)
    try await restarted.acknowledge(.init(libraryID: "library", acceptedEventIDs: [value.eventID], cursor: 19), submitted: [value])
    let state = await restarted.snapshot()
    XCTAssertEqual(state.centralCursor, 0, "An upload acknowledgement cannot skip other workspaces' history")
    XCTAssertEqual(state.entries.count, 1)
    XCTAssertTrue(state.pendingEntries.isEmpty)
  }
  func testReplayGapAndReusedEventLeaveCursorAndHistoryUnchanged() async throws {
    let journal = try WorkspaceJournal(file: path()); try await journal.bind(libraryID: "library")
    do { try await journal.receiveCentral(.init(libraryID: "library", cursor: 2, entries: [entry(1)])); XCTFail() }
    catch WorkspaceJournal.Failure.replayGap {}
    try await journal.receiveCentral(.init(libraryID: "library", cursor: 1, entries: [entry(1)]))
    var changed = entry(1); changed.conversation?.title = "Changed immutable event"
    do { try await journal.receiveCentral(.init(libraryID: "library", cursor: 2, entries: [changed])); XCTFail() }
    catch WorkspaceJournal.Failure.reusedIdentity {}
    let state = await journal.snapshot()
    XCTAssertEqual(state.centralCursor, 1)
    XCTAssertEqual(state.conversations["chat"]?.title, "Version 1")
    do { try await journal.record(entry(3)); XCTFail() } catch WorkspaceJournal.Failure.replayGap {}
  }
  func testDirectHistoryDeduplicatesCentralReplayAndRetainsDeletion() async throws {
    let journal = try WorkspaceJournal(file: path()); try await journal.bind(libraryID: "library")
    let first = entry(1)
    try await journal.receiveWorkspace(.init(libraryID: "library", cursor: 1, entries: [first]), workspaceID: "phone")
    try await journal.receiveCentral(.init(libraryID: "library", cursor: 1, entries: [first]))
    let deletion = CompanionJournalEntry(workspaceID: "phone", originSequence: 2, conversationID: "chat", kind: .deletedConversation)
    try await journal.record(deletion)
    try await journal.record(entry(3))
    let state = await journal.snapshot()
    XCTAssertNil(state.conversations["chat"])
    XCTAssertTrue(state.deletedConversationIDs.contains("chat"))
    XCTAssertEqual(state.entries.count, 3)
  }
  func testJournalProjectionRecoversAfterCrashAndAppliesTombstones() async throws {
    let file = path(); let store = try MobileStore(file: file)
    try await store.journal.bind(libraryID: "library")
    try await store.journal.record(entry(1)) // Simulate crash before projection.
    let restarted = try MobileStore(file: file)
    try await restarted.restoreExecutionProjection()
    var state = await restarted.snapshot(); XCTAssertEqual(state.conversations["chat"]?.title, "Version 1")
    try await restarted.apply(CompanionSnapshot(workspaceID: "library", cursor: 1))
    state = await restarted.snapshot(); XCTAssertNotNil(state.conversations["chat"])
    try await restarted.journal.record(.init(workspaceID: "phone", originSequence: 2, conversationID: "chat", kind: .deletedConversation))
    try await restarted.restoreExecutionProjection()
    state = await restarted.snapshot(); XCTAssertNil(state.conversations["chat"])
  }
  func testOwnerHistoryCannotBeReassignedToAnotherWorkspace() async throws {
    let journal = try WorkspaceJournal(file: path())
    try await journal.record(entry(1))
    do { try await journal.record(entry(1, workspace: "other")); XCTFail() } catch WorkspaceJournal.Failure.reusedIdentity {}
    let state = await journal.snapshot(); XCTAssertEqual(state.conversationWorkspaceIDs["chat"], "phone")
  }
  func testDirectCommandWorksWithoutCentralAndRecoversLostReceipt() async throws {
    let file = path(); let store = try MobileStore(file: file); let transport = OfflineWorkspace()
    let client = WorkspaceClient(store: store, workspaceID: "linux", transport: transport)
    var command = CompanionCommand(commandID: "stable", deviceID: "phone", kind: .send, conversationID: "chat", text: "First prompt")
    do { _ = try await client.submit(command); XCTFail() } catch is URLError {}
    let restarted = try MobileStore(file: file)
    let resumed = WorkspaceClient(store: restarted, workspaceID: "linux", transport: transport)
    command.text = "Accidentally modified retry"
    let receipt = try await resumed.submit(command)
    XCTAssertEqual(receipt.status, .completed)
    let executed = await transport.executed
    XCTAssertEqual(executed.count, 1); XCTAssertEqual(executed.first?.text, "First prompt")
    let stored = await restarted.journal.commandRecords(workspaceID: "linux")
    XCTAssertEqual(stored.first?.command.text, "First prompt")
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
  func testLegacyUnscopedCommandRetryPreservesItsPersistedPayload() async throws {
    let file = path(), transport = OfflineWorkspace(loseReply: false)
    let store = try MobileStore(file: file)
    let saved = CompanionCommand(commandID: "legacy", deviceID: "phone", kind: .respond, conversationID: "chat",
      runID: "run", interactionID: "approval", response: .init(optionID: "allow"))
    _ = try await store.journal.rememberCommand(saved, workspaceID: "linux")
    let restarted = try MobileStore(file: file)
    let client = WorkspaceClient(store: restarted, workspaceID: "linux", transport: transport)
    var retry = saved
    retry.workspaceID = "linux"
    retry.response = .init(optionID: "deny")
    _ = try await client.submit(retry)
    let executed = await transport.executed
    XCTAssertEqual(executed, [saved])
    let records = await restarted.journal.commandRecords(workspaceID: "linux")
    XCTAssertEqual(records.first?.command, saved)
  }
  func testDirectLaunchPersistsInitialPromptBeforeCreateAndResumesWithoutCentral() async throws {
    let file = path(); let store = try MobileStore(file: file); let transport = OfflineWorkspace()
    let launch = MobileLaunchRecord(create: .init(deviceID: "phone", kind: .createSession, conversationID: "chat"), initialSend: .init(deviceID: "phone", kind: .send, conversationID: "chat", text: "Saved before create"))
    let client = WorkspaceClient(store: store, workspaceID: "linux", transport: transport)
    do { _ = try await client.startConversation(launch); XCTFail() } catch is URLError {}
    let restarted = try MobileStore(file: file)
    let state = await restarted.snapshot()
    XCTAssertEqual(state.launches.first?.initialSend.text, "Saved before create")
    XCTAssertEqual(state.launches.first?.create.workspaceID, "linux")
    let resumed = WorkspaceClient(store: restarted, workspaceID: "linux", transport: transport)
    let completed = try await resumed.startConversation(launch)
    XCTAssertTrue(completed.accepted)
    let executed = await transport.executed
    XCTAssertEqual(executed.map(\.kind), [.createSession, .send])
    _ = try await resumed.startConversation(launch)
    let repeatCount = await transport.executed.count; XCTAssertEqual(repeatCount, 2)
  }
  func testTranscriptDeltasPreserveHistoryAndDropTransientStreamingRows() async throws {
    let journal = try WorkspaceJournal(file: path())
    let first = CompanionMessage(id: "user", conversationID: "chat", role: "user", content: "Hello")
    let streaming = CompanionMessage(id: "transient", conversationID: "chat", role: "assistant", content: "Part", status: "streaming")
    let final = CompanionMessage(id: "native", conversationID: "chat", role: "assistant", content: "Complete", status: "completed")
    _ = try await journal.append(workspaceID: "phone", transcript: .init(conversationID: "chat", messages: [first, streaming], activeRunID: "run"))
    _ = try await journal.append(workspaceID: "phone", transcript: .init(conversationID: "chat", messages: [first, final]))
    _ = try await journal.append(workspaceID: "phone", transcript: .init(conversationID: "chat", messages: [first, final]))
    let state = await journal.snapshot()
    XCTAssertEqual(state.transcripts["chat"]?.messages, [first, final])
    XCTAssertNil(state.transcripts["chat"]?.activeRunID)
    XCTAssertEqual(state.entries.count, 2)
    XCTAssertEqual(state.entries.values.first { $0.originSequence == 2 }?.transcript?.messages, [final])
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
  func testCentralDeletionSurvivesJournalProjectionAndSnapshotReset() async throws {
    let store = try MobileStore(file: path()); let conversation = CompanionConversation(id: "chat", title: "Shared")
    _ = try await store.journal.append(workspaceID: "phone", conversation: conversation)
    try await store.apply(CompanionSnapshot(workspaceID: "library", cursor: 1, conversations: [conversation]))
    try await store.apply(CompanionChangePage(workspaceID: "library", cursor: 2, changes: [.init(cursor: 2, resourceKind: .conversation, resourceID: "chat", operation: .delete, revision: 2)]))
    try await store.restoreExecutionProjection()
    var state = await store.snapshot(); XCTAssertNil(state.conversations["chat"])
    try await store.apply(CompanionSnapshot(workspaceID: "library", cursor: 10))
    try await store.restoreExecutionProjection()
    state = await store.snapshot(); XCTAssertNil(state.conversations["chat"])
  }
  func testNativeRecordAndCommandIDsCannotBeReusedForDifferentTargets() async throws {
    let journal = try WorkspaceJournal(file: path())
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
    XCTAssertEqual(state.entries.count, 1)
    XCTAssertEqual(state.commands.values.first?.command, command)
  }
  func testNativeToolCASRejectsSameRevisionEditorChangesAndCancellation() async throws {
    let store = try MobileStore(file: path())
    let initial = CompanionNote(id: "note", title: "Shared", content: "Initial", revision: 5)
    try await store.apply(CompanionSnapshot(workspaceID: "library", cursor: 1, notes: [initial]))
    try await store.editNote(id: initial.id, title: initial.title, content: "Editor", folderID: nil, base: initial)
    do {
      try await store.editNoteIfUnchanged(id: initial.id, title: initial.title, content: "Tool", folderID: nil, expected: initial)
      XCTFail("A stale tool read must not overwrite an unacknowledged editor write")
    } catch MobileStore.Failure.conflictingNote { }
    let current = await store.snapshot().notes[initial.id]!
    XCTAssertEqual(current.content, "Editor"); XCTAssertEqual(current.revision, initial.revision)
    let cancelled = Task {
      while !Task.isCancelled { await Task.yield() }
      try await store.editNoteIfUnchanged(id: initial.id, title: initial.title, content: "Cancelled", folderID: nil, expected: current)
    }
    cancelled.cancel()
    do { try await cancelled.value; XCTFail("Cancelled tools must not write") } catch is CancellationError { }
    let after = await store.snapshot(); XCTAssertEqual(after.notes[initial.id]?.content, "Editor")
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
  func testFolderIdentityRetryAndQueuedRenameDoNotDuplicateCreation() async throws {
    let store = try MobileStore(file: path())
    let first = try await store.createFolder(name: "First", id: "stable-folder")
    let retried = try await store.createFolder(name: "First", id: "stable-folder")
    XCTAssertEqual(first, retried)
    try await store.renameFolder(id: first.id, name: "Renamed before sync")
    let sent = try await store.nextMutation()!
    XCTAssertEqual(sent.kind, .createFolder); XCTAssertEqual(sent.title, "Renamed before sync")
    do { try await store.renameFolder(id: first.id, name: "Unsafe in-flight change"); XCTFail() } catch MobileStore.Failure.conflictingNote {}
    let state = await store.snapshot(); XCTAssertEqual(state.outbox.count, 1)
  }
  func testPreFederationLibraryDecodesWithoutChangingNotesOrDeviceID() async throws {
    let file = path(); var legacy = MobileStoreState(); legacy.deviceID = "existing-phone"
    legacy.notes["note"] = .init(id: "note", title: "Saved", content: "keep")
    let json = try JSONEncoder().encode(legacy)
    var object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
    object.removeValue(forKey: "executionConversationIDs")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object).write(to: file)
    let store = try MobileStore(file: file); let state = await store.snapshot()
    XCTAssertEqual(state.deviceID, "existing-phone"); XCTAssertEqual(state.notes["note"]?.content, "keep")
  }
}
