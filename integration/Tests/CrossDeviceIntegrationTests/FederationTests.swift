import CryptoKit
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Central library federation", .serialized)
struct FederationTests {
  let owner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  let observer = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  func uuid() -> String { UUID().uuidString.lowercased() }
  func digest(_ data: Data) -> String { SHA256.hash(data: data).hexString }
  func fixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("federation-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  func register(_ db: WorkspaceDatabase, grants: [String] = []) async throws -> ExecutionWorkspace {
    let library = try await db.libraryIdentity()
    return try await db.registerExecutionWorkspace(.init(workspace: .init(id: uuid(), libraryID: library.libraryID,
      ownerDeviceID: owner, kind: .ios, name: "Phone", executionDeviceID: owner, journalDeviceIDs: grants)), deviceID: owner)
  }
  func creation(_ workspace: ExecutionWorkspace, id: String? = nil, sequence: Int64 = 1) -> ExecutionJournalEntry {
    let id = id ?? uuid()
    return .init(workspaceID: workspace.id, originSequence: sequence, conversationID: id, kind: .conversation,
      conversation: .init(id: id, title: "Mobile execution", runtimeKind: "default_agent"))
  }

  @Test("additive migration keeps library identity and existing notes across restart")
  func migration() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite")
    let db = try await WorkspaceDatabase(url: url)
    let note = try await db.createNote(folderID: nil, title: "Kept", content: "Offline writing")
    let before = try await db.libraryNote(id: note)
    let identity = try await db.libraryIdentity()
    #expect(identity.libraryID == (try await db.libraryID()))
    let restarted = try await WorkspaceDatabase(url: url)
    #expect(try await restarted.libraryIdentity() == identity)
    #expect(try await restarted.libraryNote(id: note) == before)
  }

  @Test("registration CAS preserves owner, explicit grants and tombstones")
  func registry() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try await register(db)
    #expect(workspace.revision == 1)
    #expect(try await db.registerExecutionWorkspace(.init(workspace: workspace), deviceID: owner) == workspace)
    var changed = workspace; changed.name = "Renamed"
    await #expect(throws: LibraryAPIError.self) { try await db.registerExecutionWorkspace(.init(workspace: changed), deviceID: owner) }
    await #expect(throws: LibraryAPIError.self) { try await db.registerExecutionWorkspace(.init(workspace: changed, expectedRevision: 1), deviceID: observer) }
    changed.journalDeviceIDs = [observer]
    let updated = try await db.registerExecutionWorkspace(.init(workspace: changed, expectedRevision: 1), deviceID: owner)
    #expect(updated.revision == 2)
    var deleted = updated; deleted.deleted = true
    let tombstone = try await db.registerExecutionWorkspace(.init(workspace: deleted, expectedRevision: 2), deviceID: owner)
    #expect(tombstone.revision == 3)
    await #expect(throws: LibraryAPIError.self) { try await db.registerExecutionWorkspace(.init(workspace: updated, expectedRevision: 3), deviceID: owner) }
  }

  @Test("journal replay is atomic, deduplicated, contiguous and owner fenced")
  func replay() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite"); let db = try await WorkspaceDatabase(url: url)
    let workspace = try await register(db, grants: [observer]); let event = creation(workspace)
    let batch = ExecutionJournalBatch(libraryID: workspace.libraryID, entries: [event])
    await #expect(throws: LibraryAPIError.self) { try await db.ingestExecutionJournal(batch, deviceID: observer) }
    let result = try await db.ingestExecutionJournal(batch, deviceID: owner)
    #expect(result.cursor == 1 && result.acceptedEventIDs == [event.eventID])
    let restarted = try await WorkspaceDatabase(url: url)
    #expect(try await restarted.ingestExecutionJournal(batch, deviceID: owner) == result)
    #expect(try await restarted.librarySnapshot().conversations.map(\.id) == [event.conversationID])
    var forged = event; forged.conversation?.title = "Conflicting replay"
    await #expect(throws: LibraryAPIError.self) { try await restarted.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [forged]), deviceID: owner) }
    let next = creation(workspace, sequence: 2); let gap = creation(workspace, sequence: 4)
    await #expect(throws: LibraryAPIError.self) { try await db.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [next, gap]), deviceID: owner) }
    #expect(try await db.executionJournal(after: 0).entries == [event])
    #expect(try await db.librarySnapshot().conversations.map(\.id) == [event.conversationID])
    let other = try await register(db)
    let takeover = creation(other, id: event.conversationID)
    await #expect(throws: LibraryAPIError.self) { try await db.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [takeover]), deviceID: owner) }
    let ungranted = creation(other)
    await #expect(throws: LibraryAPIError.self) { try await db.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [ungranted]), deviceID: observer) }
    await #expect(throws: LibraryAPIError.self) { try await db.executionJournal(after: 2) }
  }

  @Test("transcript deltas merge while central archival cannot reserve or execute commands")
  func transcriptAndReceipts() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try await register(db); let first = creation(workspace)
    let run = uuid(); let message = LibraryMessage(id: uuid(), conversationID: first.conversationID, runID: run, role: "assistant", content: "First")
    let delta = ExecutionJournalEntry(workspaceID: workspace.id, originSequence: 2, conversationID: first.conversationID, runID: run, kind: .transcript,
      transcript: .init(conversationID: first.conversationID, messages: [message], activeRunID: run))
    let secondMessage = LibraryMessage(id: uuid(), conversationID: first.conversationID, runID: run, role: "assistant", content: "Second")
    let done = ExecutionJournalEntry(workspaceID: workspace.id, originSequence: 3, conversationID: first.conversationID, runID: run, kind: .transcript,
      transcript: .init(conversationID: first.conversationID, messages: [secondMessage]))
    let receipt = LibraryCommandReceipt(commandID: uuid(), deviceID: owner, status: .completed, conversationID: first.conversationID, runID: run, workspaceID: workspace.id)
    let receiptEvent = ExecutionJournalEntry(workspaceID: workspace.id, originSequence: 4, conversationID: first.conversationID, runID: run, kind: .receipt, receipt: receipt)
    _ = try await db.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [first, delta, done, receiptEvent]), deviceID: owner)
    let transcript = try #require(try await db.libraryFederatedTranscript(conversationID: first.conversationID))
    #expect(transcript.messages == [message, secondMessage] && transcript.activeRunID == nil)
    #expect(try await db.libraryCommandReceipt(deviceID: owner, commandID: receipt.commandID) == nil)
    let snapshot = try await db.librarySnapshot()
    #expect(snapshot.conversations.first?.workspaceID == workspace.id)
    let delete = ExecutionJournalEntry(workspaceID: workspace.id, originSequence: 5, conversationID: first.conversationID, kind: .deletedConversation)
    _ = try await db.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [delete]), deviceID: owner)
    #expect(try await db.librarySnapshot().conversations.isEmpty)
    var resurrect = first; resurrect.eventID = uuid(); resurrect.originSequence = 6
    _ = try await db.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [resurrect]), deviceID: owner)
    var delayed = done; delayed.eventID = uuid(); delayed.originSequence = 7
    _ = try await db.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [delayed]), deviceID: owner)
    #expect(try await db.librarySnapshot().conversations.isEmpty)
    #expect(try await db.libraryExecutionOriginCursor(workspaceID: workspace.id) == 7)
  }

  @Test("complete native records preserve oversized tool output across multiple parts")
  func nativeHistory() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try await register(db); let first = creation(workspace)
    let bytes = Data(repeating: 42, count: 800_000); let hash = digest(bytes); let record = uuid()
    let one = NativeRecordPart(recordID: record, format: "pi.message.v1", partIndex: 0, partCount: 2, byteCount: Int64(bytes.count), sha256: hash, data: bytes.prefix(400_000))
    let two = NativeRecordPart(recordID: record, format: "pi.message.v1", partIndex: 1, partCount: 2, byteCount: Int64(bytes.count), sha256: hash, data: bytes.suffix(400_000))
    let e1 = ExecutionJournalEntry(workspaceID: workspace.id, originSequence: 2, conversationID: first.conversationID, kind: .nativeRecord, nativeRecord: one)
    let e2 = ExecutionJournalEntry(workspaceID: workspace.id, originSequence: 3, conversationID: first.conversationID, kind: .nativeRecord, nativeRecord: two)
    _ = try await db.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [first, e1]), deviceID: owner)
    #expect(try await db.libraryNativeHistoryPart(workspaceID: workspace.id, recordID: record, partIndex: 0) == nil)
    _ = try await db.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [e2]), deviceID: owner)
    #expect(try await db.libraryNativeHistoryPart(workspaceID: workspace.id, recordID: record, partIndex: 0) == one)
    #expect(try await db.libraryNativeHistoryPart(workspaceID: workspace.id, recordID: record, partIndex: 1) == two)
  }

  @Test("derived reasoning revisions remain retrievable without multiplying native search hits")
  func reasoningDetailSearchIsolation() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try await register(db), first = creation(workspace)
    var entries = [first]
    let marker = "reasoningsearchisolation"
    let formats = ["woven-native-update-v1", "wovenmatter.activity.v1"] + Array(repeating: "wovenmatter.activity.v2", count: 12)
    var parts: [NativeRecordPart] = []
    for (index, format) in formats.enumerated() {
      let bytes = Data("{\"text\":\"\(marker)\",\"revision\":\(index)}".utf8)
      let part = NativeRecordPart(recordID: "record-\(index)", format: format, partIndex: 0, partCount: 1,
        byteCount: Int64(bytes.count), sha256: digest(bytes), data: bytes)
      parts.append(part)
      entries.append(.init(workspaceID: workspace.id, originSequence: Int64(index + 2), conversationID: first.conversationID,
        kind: .nativeRecord, nativeRecord: part))
    }
    _ = try await db.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: entries), deviceID: owner)
    let found = try await db.queryHistory(.init(command: "search", search: marker, conversationID: first.conversationID,
      kind: "native.federated.record"))
    let rows = found.objectValue?["rows"]?.arrayValue ?? []
    #expect(rows.count == 2)
    #expect(Set(rows.compactMap { $0.objectValue?["native_record_id"]?.stringValue }) == ["record-0", "record-1"])
    for part in parts {
      #expect(try await db.libraryNativeHistoryPart(workspaceID: workspace.id, recordID: part.recordID, partIndex: 0) == part)
    }
  }

  @Test("only the trusted host can transfer an idle configured remote session and its existing run identities")
  func adoption() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let identity = try await db.libraryIdentity(); let remoteID = UUID()
    let descriptor = ExecutionWorkspace(id: remoteID.uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .linux, name: "Remote", executionDeviceID: uuid())
    _ = try await db.registerExecutionWorkspace(.init(workspace: descriptor), deviceID: identity.hostDeviceID)
    let conversationID = try await db.createRemoteACPSession(runtimeKind: .codex, remoteWorkspaceID: remoteID,
      remoteWorkspaceName: "Remote", title: "Existing conversation", ownerDeviceID: UUID(),
      executionRoot: .init(folderID: nil, location: .init(workspaceID: "remote:" + descriptor.id, rootPath: "/workspace/projects/existing", managed: false), defaultPath: "/workspace"))
    try await db.updateLocalACPSessionID(conversationID: conversationID, sessionID: "native-existing")
    let run = try await db.beginLocalACPRun(conversationID: conversationID, input: .init(text: "Preserve this history"))
    await #expect(throws: LibraryAPIError.self) {
      try await db.prepareExecutionAdoption(conversationID: conversationID, workspaceID: descriptor.id, deviceID: identity.hostDeviceID)
    }
    #expect(try await db.libraryExecutionOwner(conversationID: conversationID) == nil)
    try await db.completeLocalACPRun(runID: run.runID)
    await #expect(throws: LibraryAPIError.self) {
      try await db.prepareExecutionAdoption(conversationID: conversationID, workspaceID: descriptor.id, deviceID: owner)
    }
    let transfer = try await db.prepareExecutionAdoption(conversationID: conversationID, workspaceID: descriptor.id, deviceID: identity.hostDeviceID)
    #expect(transfer.nativeSessionID == "native-existing" && transfer.knownRunIDs == [run.runID])
    #expect(transfer.nativeWorkingDirectory == "/workspace/projects/existing")
    #expect(try await db.libraryExecutionOwner(conversationID: conversationID) == descriptor.id)
    await #expect(throws: LibraryAPIError.self) {
      try await db.beginLocalACPRun(conversationID: conversationID, input: .init(text: "Legacy execution must stay fenced"))
    }
    #expect(try await db.libraryFederatedTranscript(conversationID: conversationID)?.messages.contains(where: { $0.content == "Preserve this history" }) == true)
    #expect(try await db.localACPSession(conversationID: conversationID).nativeSessionID == "native-existing")
    let repeated = try await db.prepareExecutionAdoption(conversationID: conversationID, workspaceID: descriptor.id, deviceID: identity.hostDeviceID)
    #expect(repeated.knownRunIDs == transfer.knownRunIDs)
    let event = ExecutionJournalEntry(workspaceID: descriptor.id, originSequence: 1, conversationID: conversationID,
      runID: run.runID, kind: .conversation, conversation: transfer.conversation)
    await #expect(throws: LibraryAPIError.self) {
      try await db.ingestExecutionJournal(.init(libraryID: identity.libraryID, entries: [event]), deviceID: identity.hostDeviceID)
    }
    _ = try await db.ingestExecutionJournal(.init(libraryID: identity.libraryID, entries: [event]), deviceID: try #require(descriptor.executionDeviceID))
    #expect(try await db.libraryExecutionOriginCursor(workspaceID: descriptor.id) == 1)
    try await db.write { connection in
      try connection.transaction {
        try connection.toolsExecuteUnlocked("UPDATE runs SET status='running' WHERE id=?", [run.runID])
      }
    }
    let reopened = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let resumed = try await reopened.prepareExecutionAdoption(conversationID: conversationID, workspaceID: descriptor.id, deviceID: identity.hostDeviceID)
    #expect(resumed == transfer)
  }

  @Test("adopted legacy transcript pages advance for a single oversized message")
  func oversizedLegacyTranscript() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try await register(db); let first = creation(workspace)
    _ = try await db.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [first]), deviceID: owner)
    let legacy = LibraryTranscript(conversationID: first.conversationID, messages: [
      .init(id: uuid(), conversationID: first.conversationID, role: "assistant", content: String(repeating: "x", count: 5 * 1_024 * 1_024))
    ])
    let content = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
    try await db.write { connection in
      try connection.transaction {
        try connection.toolsExecuteUnlocked("UPDATE execution_conversations SET transcript=? WHERE id=?", [content, first.conversationID])
      }
    }
    let page = try #require(try await db.libraryFederatedTranscript(conversationID: first.conversationID))
    #expect(page.messages == legacy.messages && page.olderCursor == nil)
  }

  @Test("central metadata and deletion remain authoritative until explicit restore")
  func centralMetadata() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let workspace = try await register(db); let first = creation(workspace)
    _ = try await db.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [first]), deviceID: owner)
    try await db.write { connection in
      try connection.transaction {
        try connection.toolsExecuteUnlocked("UPDATE conversations SET title='Central title',deleted_at='deleted' WHERE id=?", [first.conversationID])
      }
    }
    var replay = first; replay.eventID = uuid(); replay.originSequence = 2; replay.conversation?.title = "Stale title"
    _ = try await db.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [replay]), deviceID: owner)
    #expect(try await db.librarySnapshot().conversations.isEmpty)
    let changes = try await db.libraryChanges(after: 0)
    #expect(changes.changes.last(where: { $0.resourceKind == .conversation })?.operation == .delete)
    var restore = first; restore.eventID = uuid(); restore.originSequence = 3; restore.kind = .restoredConversation
    _ = try await db.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [restore]), deviceID: owner)
    #expect(try await db.librarySnapshot().conversations.count == 1)
    #expect(try await db.librarySnapshot().conversations.first?.title == "Central title")
  }

  @Test("structured artifacts sync conditionally without changing their kind")
  func structuredEdits() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let id = uuid()
    let original = try NoteDocument(kind: .html, html: "<p>Original</p>").encoded()
    let created = try await db.applyLibraryMutation(.init(deviceID: owner, kind: .createNote, resourceID: id, title: "HTML", content: original))
    #expect(created.status == .accepted)
    let replacement = try NoteDocument(kind: .html, html: "<p>Edited</p>").encoded()
    let changed = try await db.applyLibraryMutation(.init(deviceID: owner, kind: .updateNote, resourceID: id, expectedRevision: 1, title: "HTML", content: replacement))
    #expect(changed.status == .accepted)
    let converted = try NoteDocument(blocks: [.richText(NoteRichTextBlock(text: "Accidental flattening"))]).encoded()
    #expect(try await db.applyLibraryMutation(.init(deviceID: owner, kind: .updateNote, resourceID: id, expectedRevision: 2, title: "HTML", content: converted)).status == .invalid)
    #expect(try await db.libraryNote(id: id)?.content == replacement)
  }

  @Test("artifact transfer resumes exactly, verifies hash and preserves committed revision on conflict")
  func artifact() async throws {
    let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite"); let db = try await WorkspaceDatabase(url: url)
    let workspace = try await register(db); let bytes = Data("Saved artifact output".utf8)
    let manifest = LibraryArtifactManifest(id: uuid(), workspaceID: workspace.id, title: "Output.txt", mediaType: "text/plain", byteCount: Int64(bytes.count), sha256: digest(bytes))
    let registration = LibraryArtifactRegistration(manifest: manifest)
    let started = try await db.registerLibraryArtifact(registration, deviceID: owner)
    #expect(started.nextOffset == 0 && !started.complete)
    let chunk = LibraryArtifactChunk(id: manifest.id, revision: 1, offset: 0, data: bytes.prefix(5))
    _ = try await db.appendLibraryArtifactChunk(chunk, deviceID: owner)
    let restarted = try await WorkspaceDatabase(url: url)
    #expect(try await restarted.registerLibraryArtifact(registration, deviceID: owner).nextOffset == 5)
    #expect(try await restarted.appendLibraryArtifactChunk(chunk, deviceID: owner).nextOffset == 5)
    var bad = chunk; bad.data = Data("wrong".utf8)
    await #expect(throws: LibraryAPIError.self) { try await restarted.appendLibraryArtifactChunk(bad, deviceID: owner) }
    await #expect(throws: LibraryAPIError.self) { try await restarted.commitLibraryArtifact(.init(id: manifest.id, revision: 1), deviceID: owner) }
    _ = try await restarted.appendLibraryArtifactChunk(.init(id: manifest.id, revision: 1, offset: 5, data: bytes.dropFirst(5)), deviceID: owner)
    let committed = try await restarted.commitLibraryArtifact(.init(id: manifest.id, revision: 1), deviceID: owner)
    #expect(committed.revision == 1)
    #expect(try await restarted.registerLibraryArtifact(registration, deviceID: owner).complete)
    #expect(try await restarted.libraryArtifactChunk(id: manifest.id, offset: 5).data == bytes.dropFirst(5))
    var replacement = committed; replacement.sha256 = digest(Data("another".utf8)); replacement.byteCount = 7
    await #expect(throws: LibraryAPIError.self) { try await restarted.registerLibraryArtifact(.init(manifest: replacement), deviceID: owner) }
    _ = try await restarted.registerLibraryArtifact(.init(manifest: replacement, expectedRevision: 1), deviceID: owner)
    #expect(try await restarted.librarySavedArtifacts() == [committed])
    #expect(try await restarted.libraryArtifactChunk(id: manifest.id, revision: 1, offset: 0).data == bytes.prefix(5))
  }
}
