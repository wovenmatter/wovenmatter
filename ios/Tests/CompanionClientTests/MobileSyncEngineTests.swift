import XCTest
@testable import CompanionClient
import WovenMatterCompanion

private actor FakeMac: CompanionTransport, FederationTransport, CompanionCalendarTransport, CompanionDictationTransport {
  var dictations: [DictationRecord] = []
  var loseDictationReceipt = false
  func loseNextDictationReceipt() { loseDictationReceipt = true }
  func publishDictation(_ record: DictationRecord) throws -> DictationRecord {
    if !dictations.contains(where: { $0.id == record.id }) { dictations.append(record) }
    if loseDictationReceipt { loseDictationReceipt = false; throw MobileConnectionError.offline }
    return record
  }
  func dictationChanges(after: Int64) -> DictationHistoryPage {
    .init(workspaceID: workspace, cursor: Int64(dictations.count), records: Array(dictations.dropFirst(Int(after))), hasMore: false)
  }
  var workspace = "mac-a"
  var refusedFolderIDs = Set<String>()
  var failArtifacts = false
  var journalUploads: [CompanionJournalEntry] = []
  var registeredWorkspaces: [CompanionExecutionWorkspace] = []
  var calendarRecords: [CompanionCalendarRecord] = []
  var transcriptReads: [String] = []
  var transcriptPages: [String: CompanionTranscript] = [:]
  var conversationIndex: [CompanionConversation] = []
  func refuseFolder(_ id: String) { refusedFolderIDs.insert(id) }
  func failArtifactTransfers() { failArtifacts = true }
  func seedNotes(_ values: [CompanionNote]) { for note in values { notes[note.id] = note } }
  func seedConversations(_ values: [CompanionConversation], pages: [String: CompanionTranscript]) { conversationIndex = values; transcriptPages = pages }
  func libraryIdentity() -> CompanionLibraryIdentity { .init(libraryID: workspace, hostDeviceID: "central") }
  func executionWorkspaces() -> [CompanionExecutionWorkspace] { registeredWorkspaces }
  func registerWorkspace(_ registration: CompanionWorkspaceRegistration) -> CompanionExecutionWorkspace {
    var value = registration.workspace; value.revision += 1
    registeredWorkspaces.removeAll { $0.id == value.id }; registeredWorkspaces.append(value); return value
  }
  func journal(after: Int64) -> CompanionJournalPage { .init(libraryID: workspace, cursor: after) }
  func importJournal(_ batch: CompanionJournalBatch) -> CompanionJournalBatchResult {
    journalUploads += batch.entries
    return .init(libraryID: workspace, acceptedEventIDs: batch.entries.map(\.eventID), cursor: Int64(journalUploads.count))
  }
  func artifactManifests() -> [CompanionArtifactManifest] { [] }
  func registerArtifact(_ registration: CompanionArtifactRegistration) throws -> CompanionArtifactTransfer { throw MobileConnectionError.http(503, "Artifact storage unavailable") }
  func artifactStatus(_ id: String) throws -> CompanionArtifactTransfer { throw MobileConnectionError.offline }
  func uploadArtifactChunk(_ chunk: CompanionArtifactChunk) throws -> CompanionArtifactTransfer { throw MobileConnectionError.offline }
  func commitArtifact(_ commit: CompanionArtifactCommit) throws -> CompanionArtifactManifest { throw MobileConnectionError.offline }
  func downloadArtifactChunk(_ id: String, revision: Int64, offset: Int64) throws -> CompanionArtifactChunk { throw MobileConnectionError.offline }
  func calendarSnapshot() -> CompanionCalendarSnapshot { .init(workspaceID: workspace, records: calendarRecords) }
  func calendarPublishRuns(_ runs: [CompanionCalendarRun]) -> [String] { runs.map(\.id) }
  func calendarMutate(_ mutation: CompanionCalendarMutation) -> CompanionCalendarReceipt {
    var record = mutation.record; record.event.revision += 1
    calendarRecords.removeAll { $0.id == record.id }; calendarRecords.append(record)
    return .init(mutationID: mutation.id, status: .accepted, record: record)
  }

  var notes: [String: CompanionNote] = [:]
  var folders: [String: CompanionFolder] = [:]
  var mutations: [CompanionMutation] = []
  var results: [String: CompanionMutationResult] = [:]
  var commands: [CompanionCommand] = []
  var commandRequests: [CompanionCommand] = []
  var gatedReceiptID: String?
  var receiptGate: CheckedContinuation<Void, Never>?
  var receiptWaiting = false
  var hiddenReceipts: Set<String> = []
  var linked: CompanionLinkedData?
  func gateReceipt(_ id: String, hide: String) { gatedReceiptID = id; hiddenReceipts.insert(hide) }
  func releaseReceipt() { receiptGate?.resume(); receiptGate = nil }
  func setLinked(_ value: CompanionLinkedData) { linked = value }
  func linkedData(_ id: String, tableID: String?) async throws -> CompanionLinkedData {
    guard let linked else { throw MobileConnectionError.http(503, "Remote database data is unavailable on this Mac.") }
    return linked
  }
  var receipts: [String: CompanionCommandReceipt] = [:]
  var loseMutationAcknowledgement = false
  var loseCommandAcknowledgement = false
  var cursor: Int64 = 0
  func configure(workspace: String? = nil, loseMutation: Bool = false, loseCommand: Bool = false) {
    if let workspace { self.workspace = workspace }
    loseMutationAcknowledgement = loseMutation; loseCommandAcknowledgement = loseCommand
  }
  func workspaceIdentity() async throws -> String { workspace }
  func snapshot() async throws -> CompanionSnapshot {
    let metadata = notes.values.map { value in var note = value; note.content = ""; note.contentIncluded = false; return note }
    return .init(workspaceID: workspace, cursor: cursor, folders: Array(folders.values), notes: metadata, conversations: conversationIndex)
  }
  func changes(after: Int64) async throws -> CompanionChangePage { .init(workspaceID: workspace, cursor: cursor) }
  func note(_ id: String) async throws -> CompanionNote { guard let note = notes[id] else { throw MobileConnectionError.http(404, "Deleted") }; return note }
  func mutate(_ mutation: CompanionMutation) async throws -> CompanionMutationResult {
    mutations.append(mutation)
    if refusedFolderIDs.contains(mutation.resourceID) { return .init(operationID: mutation.operationID, status: .conflict, message: "Folder changed") }
    if let result = results[mutation.operationID] { return result }
    let result: CompanionMutationResult
    if mutation.kind == .createFolder {
      let folder = CompanionFolder(id: mutation.resourceID, name: mutation.title!, revision: 1)
      folders[folder.id] = folder; result = .init(operationID: mutation.operationID, status: .accepted, folder: folder)
    } else {
      if let folder = mutation.folderID, folders[folder] == nil { return .init(operationID: mutation.operationID, status: .invalid, message: "Folder dependency missing") }
      let note = CompanionNote(id: mutation.resourceID, folderID: mutation.folderID, title: mutation.title!, content: mutation.content!, revision: (notes[mutation.resourceID]?.revision ?? 0) + 1)
      notes[note.id] = note
      var metadata = note; metadata.content = ""; metadata.contentIncluded = false
      result = .init(operationID: mutation.operationID, status: .accepted, note: metadata)
    }
    cursor += 1; results[mutation.operationID] = result
    if loseMutationAcknowledgement { loseMutationAcknowledgement = false; throw URLError(.networkConnectionLost) }
    return result
  }
  func providers() async throws -> [CompanionProvider] {
    ["codex", "claude", "grok", "hermes", "cursor", "opencode", "pi", "openclaw"].map { .init(id: "local:" + $0, runtimeKind: $0, displayName: $0, available: true, canSteer: $0 == "codex") }
  }
  func pending() async throws -> [CompanionPendingInteraction] { [] }
  func transcript(_ id: String) async throws -> CompanionTranscript {
    transcriptReads.append(id); return transcriptPages[id] ?? .init(conversationID: id, activeRunID: "mac-run")
  }
  func transcript(_ id: String, before: String) async throws -> CompanionTranscript {
    transcriptReads.append(id + ":" + before)
    return transcriptPages[id + ":" + before] ?? .init(conversationID: id)
  }
  func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt {
    commandRequests.append(command)
    if let receipt = receipts[command.commandID] { return receipt }
    commands.append(command)
    let receipt = CompanionCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .completed, conversationID: command.conversationID, runID: "mac-run")
    receipts[command.commandID] = receipt
    if loseCommandAcknowledgement { loseCommandAcknowledgement = false; throw URLError(.networkConnectionLost) }
    return receipt
  }
  func receipt(_ id: String) async throws -> CompanionCommandReceipt? {
    let captured = hiddenReceipts.contains(id) ? nil : receipts[id]
    if gatedReceiptID == id { gatedReceiptID = nil; receiptWaiting = true; await withCheckedContinuation { receiptGate = $0 } }
    return captured
  }
}

final class MobileSyncEngineTests: XCTestCase {

  func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json") }
  func content(_ text: String) throws -> String { try NoteDocument(blocks: [.richText(.init(id: "stable-block", text: text))]).encoded() }

  func testFolderAndArtifactFailuresDoNotBlockIndependentLanes() async throws {
    let store = try MobileStore(file: file()), mac = FakeMac()
    let device = await store.snapshot().deviceID
    let folder = try await store.createFolder(name: "Local folder")
    _ = try await store.createNote(folderID: folder.id, title: "Dependent", content: content("saved"))
    let note = try await store.createNote(folderID: nil, title: "Independent", content: content("sync me"))
    await mac.refuseFolder(folder.id)
    _ = try await store.calendar.save(expectedRevision: nil, draft: .init(title: "Offline event", startsAt: Date(), timeZoneID: "UTC"))
    try await store.journal.upsertWorkspace(.init(id: device, libraryID: "mac-a", ownerDeviceID: device, kind: .ios, name: "Phone"))
    try await store.journal.append(workspaceID: device, conversation: .init(id: "local-chat", title: "Local history"))
    try await store.journal.upsertWorkspace(.init(id: "remote", libraryID: "mac-a", ownerDeviceID: "other", kind: .mac, name: "Other Mac"))
    try await store.journal.append(workspaceID: "remote", conversation: .init(id: "remote-chat", title: "Cached old relay"))
    _ = try await store.artifacts.save(data: Data("saved locally".utf8), workspaceID: device, title: "Artifact", mediaType: "text/plain")
    let engine = MobileSyncEngine(store: store, transport: mac)
    do { try await engine.synchronize(); XCTFail("Expected independent lane failures") } catch { }
    let local = await store.snapshot(), syncedNotes = await mac.notes, uploads = await mac.journalUploads
    XCTAssertEqual(syncedNotes[note.id]?.title, "Independent")
    XCTAssertEqual(local.outbox.count, 2); XCTAssertEqual(local.folders[folder.id]?.name, "Local folder")
    XCTAssertEqual(uploads.map(\.conversationID), ["local-chat"])
    XCTAssertNotNil(local.conversations["remote-chat"], "Removing relay flags must retain cached history")
    let calendarCount = await store.calendar.pendingCount(); XCTAssertEqual(calendarCount, 0)
    let status = await engine.synchronizationStatus()
    XCTAssertEqual(status.centralReachable, true)
    XCTAssertEqual(status.lanes[.library]?.phase, .blocked)
    XCTAssertEqual(status.lanes[.library]?.pendingCount, 2)
    XCTAssertEqual(status.lanes[.journal]?.phase, .current)
    XCTAssertEqual(status.lanes[.calendar]?.phase, .current)
    XCTAssertEqual(status.lanes[.artifacts]?.pendingCount, 1)
    let attempted = await mac.mutations.filter { $0.resourceID == folder.id }.count
    XCTAssertEqual(attempted, 1, "Do not spin on one permanent folder failure")
    try await engine.synchronizeRequiredLanes([.journal])
    await mac.configure(workspace: "different-library")
    do { try await engine.synchronizeRequiredLanes([.journal]); XCTFail("An older successful journal pass cannot bypass a changed central identity") }
    catch MobileStore.Failure.wrongWorkspace { }
  }

  func testAllNotesCacheAndPinnedOlderPagesSurviveRestart() async throws {
    let location = file(), store = try MobileStore(file: location), mac = FakeMac()
    let notes = try (0..<25).map { index -> CompanionNote in
      CompanionNote(id: "note-\(index)", title: "Note \(index)", content: try content("body \(index)"))
    }
    await mac.seedNotes(notes)
    let recent = ISO8601DateFormatter().string(from: Date())
    await mac.seedConversations([.init(id: "recent", title: "Recent", updatedAt: recent), .init(id: "older", title: "Older", updatedAt: "2000-01-01T00:00:00Z")], pages: [
      "older": .init(conversationID: "older", messages: [.init(id: "new", conversationID: "older", role: "user", content: "latest")], olderCursor: "page2"),
      "older:page2": .init(conversationID: "older", messages: [.init(id: "old", conversationID: "older", role: "user", content: "oldest")])])
    let engine = MobileSyncEngine(store: store, transport: mac)
    try await engine.synchronize()
    let initial = await store.snapshot(), reads = await mac.transcriptReads
    XCTAssertEqual(initial.notes.count, 25); XCTAssertTrue(initial.uncachedNoteIDs.isEmpty)
    XCTAssertTrue(reads.contains("recent")); XCTAssertFalse(reads.contains("older"))
    try await engine.keepTranscriptOffline("older")
    let restarted = try MobileStore(file: location), state = await restarted.snapshot()
    XCTAssertEqual(state.transcripts["older"]?.messages.map(\.id), ["old", "new"])
    XCTAssertNil(state.transcripts["older"]?.olderCursor)
    XCTAssertEqual(state.pinnedTranscriptIDs, ["older"])
  }

}
