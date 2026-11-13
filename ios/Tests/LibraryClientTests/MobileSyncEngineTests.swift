import XCTest
@testable import LibraryClient
import WovenMatterShared

private actor FakeMac: LibraryTransport, FederationTransport, LibraryCalendarTransport, LibraryDictationTransport {
  var dictations: [DictationRecord] = []
  var analyticsEvents: [ProductAnalyticsEvent.Name] = []
  func publishDictation(_ record: DictationRecord) throws -> DictationRecord {
    if !dictations.contains(where: { $0.id == record.id }) { dictations.append(record) }
    return record
  }
  func dictationChanges(after: Int64) -> DictationHistoryPage {
    .init(workspaceID: workspace, cursor: Int64(dictations.count), records: Array(dictations.dropFirst(Int(after))), hasMore: false)
  }
  var workspace = "mac-a"
  var refusedFolderIDs = Set<String>()
  var journalUploads: [ExecutionJournalEntry] = []
  var registeredWorkspaces: [ExecutionWorkspace] = []
  var calendarRecords: [LibraryCalendarRecord] = []
  var transcriptReads: [String] = []
  var transcriptPages: [String: LibraryTranscript] = [:]
  var conversationIndex: [LibraryConversation] = []
  func refuseFolder(_ id: String) { refusedFolderIDs.insert(id) }
  func seedNotes(_ values: [LibraryNote]) { for note in values { notes[note.id] = note } }
  func seedConversations(_ values: [LibraryConversation], pages: [String: LibraryTranscript]) { conversationIndex = values; transcriptPages = pages }
  func libraryIdentity() -> LibraryIdentity { .init(libraryID: workspace, hostDeviceID: "central") }
  func executionWorkspaces() -> [ExecutionWorkspace] { registeredWorkspaces }
  func registerWorkspace(_ registration: LibraryWorkspaceRegistration) -> ExecutionWorkspace {
    var value = registration.workspace; value.revision += 1
    registeredWorkspaces.removeAll { $0.id == value.id }; registeredWorkspaces.append(value); return value
  }
  func journal(after: Int64) -> ExecutionJournalPage { .init(libraryID: workspace, cursor: after) }
  func importJournal(_ batch: ExecutionJournalBatch) -> ExecutionJournalBatchResult {
    journalUploads += batch.entries
    return .init(libraryID: workspace, acceptedEventIDs: batch.entries.map(\.eventID), cursor: Int64(journalUploads.count))
  }
  func artifactManifests() -> [LibraryArtifactManifest] { [] }
  func registerArtifact(_ registration: LibraryArtifactRegistration) throws -> LibraryArtifactTransfer { throw MobileConnectionError.http(503, "Artifact storage unavailable") }
  func uploadArtifactChunk(_ chunk: LibraryArtifactChunk) throws -> LibraryArtifactTransfer { throw MobileConnectionError.offline }
  func commitArtifact(_ commit: LibraryArtifactCommit) throws -> LibraryArtifactManifest { throw MobileConnectionError.offline }
  func downloadArtifactChunk(_ id: String, revision: Int64, offset: Int64) throws -> LibraryArtifactChunk { throw MobileConnectionError.offline }
  func calendarSnapshot() -> LibraryCalendarSnapshot { .init(workspaceID: workspace, records: calendarRecords) }
  func calendarPublishRuns(_ runs: [LibraryCalendarRun]) -> [String] { runs.map(\.id) }
  func calendarMutate(_ mutation: LibraryCalendarMutation) -> LibraryCalendarReceipt {
    var record = mutation.record; record.event.revision += 1
    calendarRecords.removeAll { $0.id == record.id }; calendarRecords.append(record)
    return .init(mutationID: mutation.id, status: .accepted, record: record)
  }

  var notes: [String: LibraryNote] = [:]
  var folders: [String: LibraryFolder] = [:]
  var mutations: [LibraryMutation] = []
  var results: [String: LibraryMutationResult] = [:]
  func linkedData(_ id: String, tableID: String?) async throws -> LinkedDataPreview {
    throw MobileConnectionError.http(503, "Remote database data is unavailable on this Mac.")
  }
  var receipts: [String: LibraryCommandReceipt] = [:]
  var loseMutationAcknowledgement = false
  var loseCommandAcknowledgement = false
  var cursor: Int64 = 0
  func configure(workspace: String? = nil, loseMutation: Bool = false, loseCommand: Bool = false) {
    if let workspace { self.workspace = workspace }
    loseMutationAcknowledgement = loseMutation; loseCommandAcknowledgement = loseCommand
  }
  func workspaceIdentity() async throws -> String { workspace }
  func snapshot() async throws -> LibrarySnapshot {
    let metadata = notes.values.map { value in var note = value; note.content = ""; note.contentIncluded = false; return note }
    return .init(workspaceID: workspace, cursor: cursor, folders: Array(folders.values), notes: metadata, conversations: conversationIndex)
  }
  func changes(after: Int64) async throws -> LibraryChangePage { .init(workspaceID: workspace, cursor: cursor) }
  func note(_ id: String) async throws -> LibraryNote { guard let note = notes[id] else { throw MobileConnectionError.http(404, "Deleted") }; return note }
  func mutate(_ mutation: LibraryMutation) async throws -> LibraryMutationResult {
    mutations.append(mutation)
    if refusedFolderIDs.contains(mutation.resourceID) { return .init(operationID: mutation.operationID, status: .conflict, message: "Folder changed") }
    if let result = results[mutation.operationID] { return result }
    let result: LibraryMutationResult
    if mutation.kind == .createFolder {
      let folder = LibraryFolder(id: mutation.resourceID, name: mutation.title!, revision: 1)
      folders[folder.id] = folder; result = .init(operationID: mutation.operationID, status: .accepted, folder: folder)
    } else {
      if let folder = mutation.folderID, folders[folder] == nil { return .init(operationID: mutation.operationID, status: .invalid, message: "Folder dependency missing") }
      let note = LibraryNote(id: mutation.resourceID, folderID: mutation.folderID, title: mutation.title!, content: mutation.content!, revision: (notes[mutation.resourceID]?.revision ?? 0) + 1)
      notes[note.id] = note
      var metadata = note; metadata.content = ""; metadata.contentIncluded = false
      result = .init(operationID: mutation.operationID, status: .accepted, note: metadata)
    }
    cursor += 1; results[mutation.operationID] = result
    if loseMutationAcknowledgement { loseMutationAcknowledgement = false; throw URLError(.networkConnectionLost) }
    return result
  }
  func providers() async throws -> [HarnessCapabilities] {
    ["default_agent", "codex", "claude_code", "grok_build", "opencode"].map { .init(id: "local:" + $0, runtimeKind: $0, displayName: $0, available: true, canSteer: $0 == "codex") }
  }
  func pending() async throws -> [PendingInteraction] { [] }
  func transcript(_ id: String) async throws -> LibraryTranscript {
    transcriptReads.append(id); return transcriptPages[id] ?? .init(conversationID: id, activeRunID: "mac-run")
  }
  func transcript(_ id: String, before: String) async throws -> LibraryTranscript {
    transcriptReads.append(id + ":" + before)
    return transcriptPages[id + ":" + before] ?? .init(conversationID: id)
  }
  func command(_ command: LibraryCommand) async throws -> LibraryCommandReceipt {
    if let receipt = receipts[command.commandID] { return receipt }
    let receipt = LibraryCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .completed, conversationID: command.conversationID, runID: "mac-run")
    receipts[command.commandID] = receipt
    if loseCommandAcknowledgement { loseCommandAcknowledgement = false; throw URLError(.networkConnectionLost) }
    return receipt
  }
  func receipt(_ id: String) async throws -> LibraryCommandReceipt? { receipts[id] }
}

extension FakeMac: ProductAnalyticsTransport {
  func analyticsPreference() -> ProductAnalyticsPreference { .init(analyticsID: "mac-analytics") }
  func setAnalyticsPreference(_ change: ProductAnalyticsPreferenceChange) -> ProductAnalyticsPreference {
    .init(analyticsID: "mac-analytics", enabled: change.enabled, revision: change.expectedRevision + 1)
  }
  func sendAnalytics(_ batch: ProductAnalyticsBatch) -> ProductAnalyticsAcknowledgement {
    analyticsEvents += batch.events.map(\.name)
    return .init(acceptedEventIDs: batch.events.map(\.id), preference: analyticsPreference())
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
    let notes = try (0..<25).map { index -> LibraryNote in
      LibraryNote(id: "note-\(index)", title: "Note \(index)", content: try content("body \(index)"))
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


  /// Everything made on a phone that was never paired reaches the library
  /// once when it pairs later: notes with their latest writing (a note deleted
  /// before pairing never appears), folders, Quick Chat history, calendar events,
  /// timer reminders and dictations. A second pass sends nothing again. Analytics start
  /// only once a Mac is paired.
  func testStandaloneWritingUploadsOnceWhenPairedLater() async throws {
    let store = try MobileStore(file: file()), mac = FakeMac()
    let device = await store.snapshot().deviceID
    let unpaired = await store.snapshot().workspaceID
    XCTAssertNil(unpaired)
    let folder = try await store.createFolder(name: "Ideas")
    let filed = try await store.createNote(folderID: folder.id, title: "Untitled note", content: content("first"))
    try await store.editNote(id: filed.id, title: "Trip", content: content("second"), folderID: folder.id, base: filed)
    let edited = await store.snapshot().notes[filed.id]!
    try await store.editNote(id: filed.id, title: "Trip plan", content: content("final writing"), folderID: folder.id, base: edited)
    let loose = try await store.createNote(folderID: nil, title: "Groceries", content: content("milk"))
    let discarded = try await store.createNote(folderID: nil, title: "Scratch", content: content("delete me"))
    try await store.deleteWorkspaceNote(id: discarded.id, base: discarded)
    // Quick Chat history is journaled before this phone's workspace is registered anywhere.
    try await store.journal.append(workspaceID: device, conversation: .init(id: "quick-chat", title: "Weekend", workspaceID: device),
      transcript: .init(conversationID: "quick-chat", messages: [.init(id: "m1", conversationID: "quick-chat", role: "user", content: "Plan Saturday")]))
    try await store.adoptExecution(conversation: .init(id: "quick-chat", title: "Weekend", workspaceID: device))
    _ = try await store.calendar.save(expectedRevision: nil, draft: .init(title: "Dentist", startsAt: Date().addingTimeInterval(86_400), timeZoneID: "UTC"))
    let timerID = UUID().uuidString.lowercased()
    let timer = await store.executeLocalTool(.init(arguments: ["timers", "create", "--text", "Stretch", "--at",
      ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600))], requestID: timerID),
      context: .init(sessionID: "quick-chat", workspaceID: device, enabled: [.timers]))
    XCTAssertTrue(timer.success)
    _ = try await store.reconcileTimerReminders(sessionIDs: ["quick-chat"], now: Date())
    let dictation = DictationRecord(text: "Buy stamps")
    try await store.dictations.save(dictation)
    try await store.analytics.record(.appOpened, platform: "ios")
    let unsent = await mac.analyticsEvents
    XCTAssertTrue(unsent.isEmpty, "A standalone phone has nowhere to send analytics")

    // Pairing: the commit binds the library and the app registers this phone's workspace.
    try await store.prepareForPairing("mac-a")
    try await store.journal.upsertWorkspace(.init(id: device, libraryID: "mac-a", ownerDeviceID: device, kind: .ios, name: "Phone",
      capabilities: ["quick-chat", "notes", "approvals", "questions"]))
    let engine = MobileSyncEngine(store: store, transport: mac)
    try await engine.synchronize()
    try await engine.synchronize()

    let notes = await mac.notes, folders = await mac.folders, mutations = await mac.mutations
    XCTAssertEqual(Set(notes.keys), [filed.id, loose.id])
    XCTAssertEqual(notes[filed.id]?.title, "Trip plan")
    XCTAssertEqual(notes[filed.id]?.content, try content("final writing"))
    XCTAssertEqual(notes[filed.id]?.folderID, folder.id)
    XCTAssertEqual(folders[folder.id]?.name, "Ideas")
    XCTAssertEqual(mutations.filter { $0.kind == .createNote }.count, 2, "Each note is created once, with its latest writing")
    XCTAssertEqual(mutations.filter { $0.kind == .createFolder }.count, 1)
    XCTAssertFalse(mutations.contains { $0.resourceID == discarded.id })
    let uploads = await mac.journalUploads
    XCTAssertEqual(Set(uploads.map(\.conversationID)), ["quick-chat"])
    XCTAssertEqual(uploads.count, Set(uploads.map(\.eventID)).count, "No history entry is sent twice")
    XCTAssertTrue(uploads.contains { $0.transcript?.messages.contains { $0.content == "Plan Saturday" } == true })
    let calendar = await mac.calendarRecords
    XCTAssertTrue(calendar.contains { $0.event.draft.title == "Dentist" })
    XCTAssertTrue(calendar.contains { $0.id == MobileStore.reminderEventID(timerID: timerID) })
    XCTAssertEqual(calendar.count, Set(calendar.map(\.id)).count)

    let dictations = await mac.dictations
    XCTAssertEqual(dictations, [dictation])

    let local = await store.snapshot()
    XCTAssertEqual(local.workspaceID, "mac-a")
    XCTAssertTrue(local.outbox.isEmpty)
    XCTAssertEqual(Set(local.notes.keys), [filed.id, loose.id], "The phone keeps its notes, with no duplicates")
    XCTAssertEqual(local.notes[filed.id]?.content, try content("final writing"))
    XCTAssertNotNil(local.folders[folder.id])
    XCTAssertEqual(local.conversations["quick-chat"]?.title, "Weekend")
    let pendingCalendar = await store.calendar.pendingCount()
    XCTAssertEqual(pendingCalendar, 0)

    // Pairing bound analytics to the Mac: they flow now, and only through it.
    for _ in 0..<50 { if await store.analytics.snapshot().preference != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
    try await store.analytics.record(.appOpened, platform: "ios")
    for _ in 0..<50 { if !(await mac.analyticsEvents.isEmpty) { break }; try await Task.sleep(for: .milliseconds(20)) }
    let sent = await mac.analyticsEvents
    XCTAssertEqual(sent, [.appOpened])
  }

}
