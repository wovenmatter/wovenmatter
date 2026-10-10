import CryptoKit
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Central library federation", .serialized)
struct CompanionFederationTests {
  let owner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  let observer = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  func uuid() -> String { UUID().uuidString.lowercased() }
  func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  func fixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("federation-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  func register(_ db: WorkspaceDatabase, grants: [String] = []) async throws -> CompanionExecutionWorkspace {
    let library = try await db.companionLibraryIdentity()
    return try await db.registerCompanionExecutionWorkspace(.init(workspace: .init(id: uuid(), libraryID: library.libraryID,
      ownerDeviceID: owner, kind: .ios, name: "Phone", executionDeviceID: owner, journalDeviceIDs: grants)), deviceID: owner)
  }
  func creation(_ workspace: CompanionExecutionWorkspace, id: String? = nil, sequence: Int64 = 1) -> CompanionJournalEntry {
    let id = id ?? uuid()
    return .init(workspaceID: workspace.id, originSequence: sequence, conversationID: id, kind: .conversation,
      conversation: .init(id: id, title: "Mobile execution", runtimeKind: "pi"))
  }

  @Test("additive migration keeps library identity and existing notes across restart")
  func migration() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite")
    let db = try await WorkspaceDatabase(url: url)
    let note = try await db.createNote(folderID: nil, title: "Kept", content: "Offline writing")
    let before = try await db.companionNote(id: note)
    let identity = try await db.companionLibraryIdentity()
    #expect(identity.libraryID == (try await db.companionWorkspaceID()))
    let restarted = try await WorkspaceDatabase(url: url)
    #expect(try await restarted.companionLibraryIdentity() == identity)
    #expect(try await restarted.companionNote(id: note) == before)
  }

  @Test("registration CAS preserves owner, explicit grants and tombstones")
  func registry() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try await register(db)
    #expect(workspace.revision == 1)
    #expect(try await db.registerCompanionExecutionWorkspace(.init(workspace: workspace), deviceID: owner) == workspace)
    var changed = workspace; changed.name = "Renamed"
    await #expect(throws: CompanionAPIError.self) { try await db.registerCompanionExecutionWorkspace(.init(workspace: changed), deviceID: owner) }
    await #expect(throws: CompanionAPIError.self) { try await db.registerCompanionExecutionWorkspace(.init(workspace: changed, expectedRevision: 1), deviceID: observer) }
    changed.journalDeviceIDs = [observer]
    let updated = try await db.registerCompanionExecutionWorkspace(.init(workspace: changed, expectedRevision: 1), deviceID: owner)
    #expect(updated.revision == 2)
    var deleted = updated; deleted.deleted = true
    let tombstone = try await db.registerCompanionExecutionWorkspace(.init(workspace: deleted, expectedRevision: 2), deviceID: owner)
    #expect(tombstone.revision == 3)
    await #expect(throws: CompanionAPIError.self) { try await db.registerCompanionExecutionWorkspace(.init(workspace: updated, expectedRevision: 3), deviceID: owner) }
  }

  @Test("journal replay is atomic, deduplicated, contiguous and owner fenced")
  func replay() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite"); let db = try await WorkspaceDatabase(url: url)
    let workspace = try await register(db, grants: [observer]); let event = creation(workspace)
    let batch = CompanionJournalBatch(libraryID: workspace.libraryID, entries: [event])
    let result = try await db.ingestCompanionJournal(batch, deviceID: observer)
    #expect(result.cursor == 1 && result.acceptedEventIDs == [event.eventID])
    let restarted = try await WorkspaceDatabase(url: url)
    #expect(try await restarted.ingestCompanionJournal(batch, deviceID: owner) == result)
    var forged = event; forged.conversation?.title = "Conflicting replay"
    await #expect(throws: CompanionAPIError.self) { try await restarted.ingestCompanionJournal(.init(libraryID: workspace.libraryID, entries: [forged]), deviceID: owner) }
    let next = creation(workspace, sequence: 2); let gap = creation(workspace, sequence: 4)
    await #expect(throws: CompanionAPIError.self) { try await db.ingestCompanionJournal(.init(libraryID: workspace.libraryID, entries: [next, gap]), deviceID: owner) }
    #expect(try await db.companionJournal(after: 0).entries == [event])
    #expect(try await db.companionSnapshot().conversations.map(\.id) == [event.conversationID])
    let other = try await register(db)
    let takeover = creation(other, id: event.conversationID)
    await #expect(throws: CompanionAPIError.self) { try await db.ingestCompanionJournal(.init(libraryID: workspace.libraryID, entries: [takeover]), deviceID: owner) }
    let ungranted = creation(other)
    await #expect(throws: CompanionAPIError.self) { try await db.ingestCompanionJournal(.init(libraryID: workspace.libraryID, entries: [ungranted]), deviceID: observer) }
    await #expect(throws: CompanionAPIError.self) { try await db.companionJournal(after: 2) }
  }

  @Test("transcript deltas merge while central archival cannot reserve or execute commands")
  func transcriptAndReceipts() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try await register(db); let first = creation(workspace)
    let run = uuid(); let message = CompanionMessage(id: uuid(), conversationID: first.conversationID, runID: run, role: "assistant", content: "First")
    let delta = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 2, conversationID: first.conversationID, runID: run, kind: .transcript,
      transcript: .init(conversationID: first.conversationID, messages: [message], activeRunID: run))
    let secondMessage = CompanionMessage(id: uuid(), conversationID: first.conversationID, runID: run, role: "assistant", content: "Second")
    let done = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 3, conversationID: first.conversationID, runID: run, kind: .transcript,
      transcript: .init(conversationID: first.conversationID, messages: [secondMessage]))
    let receipt = CompanionCommandReceipt(commandID: uuid(), deviceID: owner, status: .completed, conversationID: first.conversationID, runID: run, workspaceID: workspace.id)
    let receiptEvent = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 4, conversationID: first.conversationID, runID: run, kind: .receipt, receipt: receipt)
    _ = try await db.ingestCompanionJournal(.init(libraryID: workspace.libraryID, entries: [first, delta, done, receiptEvent]), deviceID: owner)
    let transcript = try #require(try await db.companionFederatedTranscript(conversationID: first.conversationID))
    #expect(transcript.messages == [message, secondMessage] && transcript.activeRunID == nil)
    #expect(try await db.companionCommandReceipt(deviceID: owner, commandID: receipt.commandID) == nil)
    let snapshot = try await db.companionSnapshot()
    #expect(snapshot.conversations.first?.workspaceID == workspace.id)
    let delete = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 5, conversationID: first.conversationID, kind: .deletedConversation)
    _ = try await db.ingestCompanionJournal(.init(libraryID: workspace.libraryID, entries: [delete]), deviceID: owner)
    #expect(try await db.companionSnapshot().conversations.isEmpty)
    var resurrect = first; resurrect.eventID = uuid(); resurrect.originSequence = 6
    _ = try await db.ingestCompanionJournal(.init(libraryID: workspace.libraryID, entries: [resurrect]), deviceID: owner)
    var delayed = done; delayed.eventID = uuid(); delayed.originSequence = 7
    _ = try await db.ingestCompanionJournal(.init(libraryID: workspace.libraryID, entries: [delayed]), deviceID: owner)
    #expect(try await db.companionSnapshot().conversations.isEmpty)
    #expect(try await db.companionExecutionOriginCursor(workspaceID: workspace.id) == 7)
  }

  @Test("complete native records preserve oversized tool output across multiple parts")
  func nativeHistory() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try await register(db); let first = creation(workspace)
    let bytes = Data(repeating: 42, count: 800_000); let hash = digest(bytes); let record = uuid()
    let one = CompanionNativeRecordPart(recordID: record, format: "pi.message.v1", partIndex: 0, partCount: 2, byteCount: Int64(bytes.count), sha256: hash, data: bytes.prefix(400_000))
    let two = CompanionNativeRecordPart(recordID: record, format: "pi.message.v1", partIndex: 1, partCount: 2, byteCount: Int64(bytes.count), sha256: hash, data: bytes.suffix(400_000))
    let e1 = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 2, conversationID: first.conversationID, kind: .nativeRecord, nativeRecord: one)
    let e2 = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 3, conversationID: first.conversationID, kind: .nativeRecord, nativeRecord: two)
    _ = try await db.ingestCompanionJournal(.init(libraryID: workspace.libraryID, entries: [first, e1]), deviceID: owner)
    #expect(try await db.companionNativeHistoryPart(workspaceID: workspace.id, recordID: record, partIndex: 0) == nil)
    _ = try await db.ingestCompanionJournal(.init(libraryID: workspace.libraryID, entries: [e2]), deviceID: owner)
    #expect(try await db.companionNativeHistoryPart(workspaceID: workspace.id, recordID: record, partIndex: 0) == one)
    #expect(try await db.companionNativeHistoryPart(workspaceID: workspace.id, recordID: record, partIndex: 1) == two)
  }

  @Test("only the trusted host can transfer an idle configured remote session and its existing run identities")
  func adoption() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let identity = try await db.companionLibraryIdentity(); let remoteID = UUID()
    let descriptor = CompanionExecutionWorkspace(id: remoteID.uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .linux, name: "Remote")
    _ = try await db.registerCompanionExecutionWorkspace(.init(workspace: descriptor), deviceID: identity.hostDeviceID)
    let conversationID = try await db.createRemoteACPSession(runtimeKind: .codex, remoteWorkspaceID: remoteID,
      remoteWorkspaceName: "Remote", title: "Existing conversation", ownerDeviceID: UUID())
    try await db.updateLocalACPSessionID(conversationID: conversationID, sessionID: "native-existing")
    let run = try await db.beginLocalACPRun(conversationID: conversationID, content: "Preserve this history")
    await #expect(throws: CompanionAPIError.self) {
      try await db.prepareCompanionExecutionAdoption(conversationID: conversationID, workspaceID: descriptor.id, deviceID: identity.hostDeviceID)
    }
    #expect(try await db.companionExecutionOwner(conversationID: conversationID) == nil)
    try await db.completeLocalACPRun(runID: run.runID)
    await #expect(throws: CompanionAPIError.self) {
      try await db.prepareCompanionExecutionAdoption(conversationID: conversationID, workspaceID: descriptor.id, deviceID: owner)
    }
    let transfer = try await db.prepareCompanionExecutionAdoption(conversationID: conversationID, workspaceID: descriptor.id, deviceID: identity.hostDeviceID)
    #expect(transfer.nativeSessionID == "native-existing" && transfer.knownRunIDs == [run.runID])
    #expect(try await db.companionExecutionOwner(conversationID: conversationID) == descriptor.id)
    await #expect(throws: CompanionAPIError.self) {
      try await db.beginLocalACPRun(conversationID: conversationID, content: "Legacy execution must stay fenced")
    }
    #expect(try await db.companionFederatedTranscript(conversationID: conversationID)?.messages.contains(where: { $0.content == "Preserve this history" }) == true)
    #expect(try await db.localACPSession(conversationID: conversationID).acpSessionID == "native-existing")
    let repeated = try await db.prepareCompanionExecutionAdoption(conversationID: conversationID, workspaceID: descriptor.id, deviceID: identity.hostDeviceID)
    #expect(repeated.knownRunIDs == transfer.knownRunIDs)
    let event = CompanionJournalEntry(workspaceID: descriptor.id, originSequence: 1, conversationID: conversationID,
      runID: run.runID, kind: .conversation, conversation: transfer.conversation)
    _ = try await db.ingestCompanionJournal(.init(libraryID: identity.libraryID, entries: [event]), deviceID: identity.hostDeviceID)
    #expect(try await db.companionExecutionOriginCursor(workspaceID: descriptor.id) == 1)
    try await db.write { connection in
      try connection.transaction {
        try connection.companionExecuteUnlocked("UPDATE dashboard_runs SET status='running' WHERE id=?", values: [run.runID])
      }
    }
    let reopened = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let resumed = try await reopened.prepareCompanionExecutionAdoption(conversationID: conversationID, workspaceID: descriptor.id, deviceID: identity.hostDeviceID)
    #expect(resumed == transfer)
  }

  @Test("adopted legacy transcript pages advance for a single oversized message")
  func oversizedLegacyTranscript() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try await register(db); let first = creation(workspace)
    _ = try await db.ingestCompanionJournal(.init(libraryID: workspace.libraryID, entries: [first]), deviceID: owner)
    let legacy = CompanionTranscript(conversationID: first.conversationID, messages: [
      .init(id: uuid(), conversationID: first.conversationID, role: "assistant", content: String(repeating: "x", count: 5 * 1_024 * 1_024))
    ])
    let content = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
    try await db.write { connection in
      try connection.transaction {
        try connection.companionExecuteUnlocked("UPDATE companion_execution_conversations SET transcript=? WHERE id=?", values: [content, first.conversationID])
      }
    }
    let page = try #require(try await db.companionFederatedTranscript(conversationID: first.conversationID))
    #expect(page.messages == legacy.messages && page.olderCursor == nil)
  }

  @Test("central metadata and deletion remain authoritative until explicit restore")
  func centralMetadata() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try await register(db); let first = creation(workspace)
    _ = try await db.ingestCompanionJournal(.init(libraryID: workspace.libraryID, entries: [first]), deviceID: owner)
    try await db.write { connection in
      try connection.transaction {
        try connection.companionExecuteUnlocked("UPDATE dashboard_conversations SET title='Central title',deleted_at='deleted' WHERE id=?", values: [first.conversationID])
      }
    }
    var replay = first; replay.eventID = uuid(); replay.originSequence = 2; replay.conversation?.title = "Stale title"
    _ = try await db.ingestCompanionJournal(.init(libraryID: workspace.libraryID, entries: [replay]), deviceID: owner)
    #expect(try await db.companionSnapshot().conversations.isEmpty)
    let changes = try await db.companionChanges(after: 0)
    #expect(changes.changes.last(where: { $0.resourceKind == .conversation })?.operation == .delete)
    var restore = first; restore.eventID = uuid(); restore.originSequence = 3; restore.kind = .restoredConversation
    _ = try await db.ingestCompanionJournal(.init(libraryID: workspace.libraryID, entries: [restore]), deviceID: owner)
    #expect(try await db.companionSnapshot().conversations.count == 1)
    #expect(try await db.companionSnapshot().conversations.first?.title == "Central title")
  }

  @Test("structured artifacts sync conditionally without changing their kind")
  func structuredEdits() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let id = uuid()
    let original = try NoteDocument(kind: .html, html: "<p>Original</p>").encoded()
    let created = try await db.applyCompanionMutation(.init(deviceID: owner, kind: .createNote, resourceID: id, title: "HTML", content: original))
    #expect(created.status == .accepted)
    let replacement = try NoteDocument(kind: .html, html: "<p>Edited</p>").encoded()
    let changed = try await db.applyCompanionMutation(.init(deviceID: owner, kind: .updateNote, resourceID: id, expectedRevision: 1, title: "HTML", content: replacement))
    #expect(changed.status == .accepted)
    let converted = try NoteDocument(blocks: [.richText(NoteRichTextBlock(text: "Accidental flattening"))]).encoded()
    #expect(try await db.applyCompanionMutation(.init(deviceID: owner, kind: .updateNote, resourceID: id, expectedRevision: 2, title: "HTML", content: converted)).status == .invalid)
    #expect(try await db.companionNote(id: id)?.content == replacement)
  }

  @Test("artifact transfer resumes exactly, verifies hash and preserves committed revision on conflict")
  func artifact() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite"); let db = try await WorkspaceDatabase(url: url)
    let workspace = try await register(db); let bytes = Data("Saved artifact output".utf8)
    let manifest = CompanionArtifactManifest(id: uuid(), workspaceID: workspace.id, title: "Output.txt", mediaType: "text/plain", byteCount: Int64(bytes.count), sha256: digest(bytes))
    let registration = CompanionArtifactRegistration(manifest: manifest)
    let started = try await db.registerCompanionArtifact(registration, deviceID: owner)
    #expect(started.nextOffset == 0 && !started.complete)
    let chunk = CompanionArtifactChunk(id: manifest.id, revision: 1, offset: 0, data: bytes.prefix(5))
    _ = try await db.appendCompanionArtifactChunk(chunk, deviceID: owner)
    let restarted = try await WorkspaceDatabase(url: url)
    #expect(try await restarted.registerCompanionArtifact(registration, deviceID: owner).nextOffset == 5)
    #expect(try await restarted.appendCompanionArtifactChunk(chunk, deviceID: owner).nextOffset == 5)
    var bad = chunk; bad.data = Data("wrong".utf8)
    await #expect(throws: CompanionAPIError.self) { try await restarted.appendCompanionArtifactChunk(bad, deviceID: owner) }
    await #expect(throws: CompanionAPIError.self) { try await restarted.commitCompanionArtifact(.init(id: manifest.id, revision: 1), deviceID: owner) }
    _ = try await restarted.appendCompanionArtifactChunk(.init(id: manifest.id, revision: 1, offset: 5, data: bytes.dropFirst(5)), deviceID: owner)
    let committed = try await restarted.commitCompanionArtifact(.init(id: manifest.id, revision: 1), deviceID: owner)
    #expect(committed.revision == 1)
    #expect(try await restarted.registerCompanionArtifact(registration, deviceID: owner).complete)
    #expect(try await restarted.companionArtifactChunk(id: manifest.id, offset: 5).data == bytes.dropFirst(5))
    var replacement = committed; replacement.sha256 = digest(Data("another".utf8)); replacement.byteCount = 7
    await #expect(throws: CompanionAPIError.self) { try await restarted.registerCompanionArtifact(.init(manifest: replacement), deviceID: owner) }
    _ = try await restarted.registerCompanionArtifact(.init(manifest: replacement, expectedRevision: 1), deviceID: owner)
    #expect(try await restarted.companionSavedArtifacts() == [committed])
    #expect(try await restarted.companionArtifactChunk(id: manifest.id, revision: 1, offset: 0).data == bytes.prefix(5))
  }
}
