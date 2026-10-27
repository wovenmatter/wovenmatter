import CryptoKit
import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Execution owner publication", .serialized)
@MainActor
struct CompanionPublisherTests {

  @Test func retainedPreflightSettlesMultipleStaleRunsButNeverTransfersAnActualActiveRun() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let conversationID = try await f.database.createFixtureRemoteACPSession(runtimeKind: .codex, remoteWorkspaceID: UUID(uuidString: f.workspace.id)!, remoteWorkspaceName: "Linux", title: "Offline history", ownerDeviceID: UUID(uuidString: f.identity.hostDeviceID)!)
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

  @Test func reasoningDisclosureResolvesChunkedDetailsAfterRestartAndClearsCorrections() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let conversationID = UUID().uuidString.lowercased(), runID = UUID().uuidString.lowercased()
    let id = runID + ":trace", recordID = "reasoning-detail"
    let content = String(repeating: "Reasoning café 🧵\n", count: 20_000)
    let full = AgentRunActivity(id: id, kind: .thought, title: "Thinking", content: content,
      contentIsDelta: false, detailsAvailable: true, detailVersion: 1)
    let bytes = try JSONEncoder().encode(full), chunkSize = 131_072
    let count = (bytes.count + chunkSize - 1) / chunkSize
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    var sequence: Int64 = 0
    func entry(_ kind: CompanionJournalEntry.Kind, transcript: CompanionTranscript? = nil,
      native: CompanionNativeRecordPart? = nil) -> CompanionJournalEntry {
      sequence += 1
      return .init(workspaceID: f.workspace.id, originSequence: sequence, conversationID: conversationID,
        runID: runID, kind: kind, transcript: transcript, nativeRecord: native)
    }
    sequence += 1
    let creation = CompanionJournalEntry(workspaceID: f.workspace.id, originSequence: sequence,
      conversationID: conversationID, kind: .conversation,
      conversation: .init(id: conversationID, title: "Complete reasoning", runtimeKind: "default_agent"))
    var entries = [creation]
    for index in 0..<count {
      entries.append(entry(.nativeRecord, native: .init(recordID: recordID, format: "wovenmatter.activity.v1",
        partIndex: index, partCount: count, byteCount: Int64(bytes.count), sha256: digest,
        data: bytes.subdata(in: index * chunkSize..<min(bytes.count, (index + 1) * chunkSize)))))
    }
    let preview = AgentRunActivity(id: id, kind: .thought, title: "Thinking", content: String(content.prefix(280)),
      contentIsDelta: false, detailsAvailable: true, detailVersion: 1)
    var row = CompanionActivity(id: id, runID: runID, title: "Thinking", detail: String(content.prefix(2048)),
      status: "completed", projectionJSON: String(decoding: try JSONEncoder().encode(preview), as: UTF8.self), detailsRecordID: recordID)
    entries.append(entry(.transcript, transcript: .init(conversationID: conversationID,
      messages: [.init(id: runID, conversationID: conversationID, runID: runID, role: "assistant", content: "Answer")], activities: [row])))
    // Import separate pages, exactly as an observer encounters native chunks.
    for event in entries {
      _ = try await f.database.ingestCompanionJournal(.init(libraryID: f.identity.libraryID, entries: [event]), deviceID: f.workspace.executionDeviceID!)
    }
    let page = try #require(try await f.database.companionFederatedTranscript(conversationID: conversationID))
    #expect(page.activities.first?.projectionJSON == row.projectionJSON)
    #expect(page.activities.first?.detail?.count == 2048)
    #expect(try await f.database.conversationActivityDetails(conversationID: conversationID, runID: runID, activityID: id) == full)
    let restarted = try await WorkspaceDatabase(url: f.directory.appending(path: "workspace.sqlite"))
    #expect(try await restarted.conversationActivityDetails(conversationID: conversationID, runID: runID, activityID: id) == full)
    #expect(try await restarted.conversationActivityDetails(conversationID: conversationID, runID: UUID().uuidString, activityID: id) == nil)
    for (index, correction) in ["Corrected reasoning", ""].enumerated() {
      let corrected = AgentRunActivity(id: id, kind: .thought, title: "Thinking", content: correction,
        contentIsDelta: false, detailsAvailable: true, detailVersion: Int64(index + 2))
      row.detail = correction; row.detailsRecordID = nil
      row.projectionJSON = String(decoding: try JSONEncoder().encode(corrected), as: UTF8.self)
      _ = try await restarted.ingestCompanionJournal(.init(libraryID: f.identity.libraryID,
        entries: [entry(.transcript, transcript: .init(conversationID: conversationID, activities: [row]))]), deviceID: f.workspace.executionDeviceID!)
      #expect(try await restarted.conversationActivityDetails(conversationID: conversationID, runID: runID, activityID: id) == corrected)
    }
    // A correction changes only the disclosure pointer; immutable native bytes remain intact.
    #expect(try await restarted.companionNativeHistoryPart(workspaceID: f.workspace.id, recordID: recordID,
      partIndex: count - 1)?.data == bytes.subdata(in: (count - 1) * chunkSize..<bytes.count))
  }

  @Test func reasoningDisclosureWaitsForReferencedChunksWithoutCachingThePreview() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let conversationID = UUID().uuidString.lowercased(), runID = UUID().uuidString.lowercased()
    let id = runID + ":trace", recordID = "pending-reasoning-detail"
    let full = AgentRunActivity(id: id, kind: .thought, title: "Thinking",
      content: String(repeating: "Reasoning café 🧵\n", count: 20_000),
      contentIsDelta: false, detailsAvailable: true, detailVersion: 1)
    let bytes = try JSONEncoder().encode(full), chunkSize = 131_072
    #expect(bytes.count > 400 * 1_024)
    let count = (bytes.count + chunkSize - 1) / chunkSize
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let preview = AgentRunActivity(id: id, kind: .thought, title: "Thinking", content: "Bounded preview",
      contentIsDelta: false, detailsAvailable: true, detailVersion: 1)
    let row = CompanionActivity(id: id, runID: runID, title: "Thinking", detail: "Bounded preview",
      status: "completed", projectionJSON: String(decoding: try JSONEncoder().encode(preview), as: UTF8.self), detailsRecordID: recordID)
    let creation = CompanionJournalEntry(workspaceID: f.workspace.id, originSequence: 1,
      conversationID: conversationID, kind: .conversation,
      conversation: .init(id: conversationID, title: "Pending reasoning", runtimeKind: "default_agent"))
    let transcript = CompanionJournalEntry(workspaceID: f.workspace.id, originSequence: 2,
      conversationID: conversationID, runID: runID, kind: .transcript,
      transcript: .init(conversationID: conversationID, activities: [row]))
    _ = try await f.database.ingestCompanionJournal(.init(libraryID: f.identity.libraryID,
      entries: [creation, transcript]), deviceID: f.workspace.executionDeviceID!)
    func expectUnavailable() async throws {
      do {
        _ = try await f.database.conversationActivityDetails(conversationID: conversationID, runID: runID, activityID: id)
        Issue.record("An unresolved detail pointer returned its bounded preview as complete")
      } catch let error as CompanionAPIError {
        #expect(error.code == "incomplete_activity_details")
      }
    }
    try await expectUnavailable()
    for index in 0..<count {
      let part = CompanionNativeRecordPart(recordID: recordID, format: "wovenmatter.activity.v1",
        partIndex: index, partCount: count, byteCount: Int64(bytes.count), sha256: digest,
        data: bytes.subdata(in: index * chunkSize..<min(bytes.count, (index + 1) * chunkSize)))
      let event = CompanionJournalEntry(workspaceID: f.workspace.id, originSequence: Int64(index + 3),
        conversationID: conversationID, runID: runID, kind: .nativeRecord, nativeRecord: part)
      if index == count - 1 {
        var corrupted = event
        var invalidPart = part
        invalidPart.data[0] ^= 1
        corrupted.nativeRecord = invalidPart
        do {
          _ = try await f.database.ingestCompanionJournal(.init(libraryID: f.identity.libraryID,
            entries: [corrupted]), deviceID: f.workspace.executionDeviceID!)
          Issue.record("A mismatched native record digest was accepted")
        } catch let error as CompanionAPIError {
          #expect(error.code == "record_digest")
        }
        // The rejected final part rolls back; the same sequence can be retried.
        try await expectUnavailable()
      }
      _ = try await f.database.ingestCompanionJournal(.init(libraryID: f.identity.libraryID,
        entries: [event]), deviceID: f.workspace.executionDeviceID!)
      if index < count - 1 { try await expectUnavailable() }
    }
    #expect(try await f.database.conversationActivityDetails(conversationID: conversationID,
      runID: runID, activityID: id) == full)
    // Chunk completion needs no new transcript row or disclosure version.
    let saved = try #require(try await f.database.companionFederatedTranscript(conversationID: conversationID))
    #expect(saved.activities.first == row)
  }

  @Test func linkedReasoningDetailsWaitForPredecessorsAndPreserveHeadMetadata() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let conversationID = UUID().uuidString.lowercased(), runID = UUID().uuidString.lowercased()
    let id = runID + ":trace"
    var sequence: Int64 = 0
    func ingest(_ kind: CompanionJournalEntry.Kind, transcript: CompanionTranscript? = nil,
      native: CompanionNativeRecordPart? = nil, nativeRun: String? = nil) async throws {
      sequence += 1
      let event = CompanionJournalEntry(workspaceID: f.workspace.id, originSequence: sequence,
        conversationID: conversationID, runID: nativeRun ?? runID, kind: kind,
        conversation: kind == .conversation ? .init(id: conversationID, title: "Linked reasoning", runtimeKind: "default_agent") : nil,
        transcript: transcript, nativeRecord: native)
      _ = try await f.database.ingestCompanionJournal(.init(libraryID: f.identity.libraryID, entries: [event]), deviceID: f.workspace.executionDeviceID!)
    }
    func parts(_ recordID: String, _ content: String, previous: String? = nil,
      identity: String? = nil, version: Int64 = 3) throws -> [CompanionNativeRecordPart] {
      let value = AgentRunActivity(id: identity ?? id, kind: .thought, title: "Head metadata", content: content,
        contentIsDelta: previous != nil, detailsAvailable: true, detailVersion: version)
      var envelope: [String: Any] = ["activity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))]
      if let previous { envelope["previousDetailsRecordID"] = previous }
      let bytes = try JSONSerialization.data(withJSONObject: envelope), chunk = 131_072
      let count = (bytes.count + chunk - 1) / chunk
      let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      return (0..<count).map { .init(recordID: recordID, format: "wovenmatter.activity.v2", partIndex: $0,
        partCount: count, byteCount: Int64(bytes.count), sha256: digest,
        data: bytes.subdata(in: $0 * chunk..<min(bytes.count, ($0 + 1) * chunk))) }
    }
    func point(_ recordID: String) async throws {
      try await ingest(.transcript, transcript: .init(conversationID: conversationID, activities: [
        .init(id: id, runID: runID, title: "Thinking", status: "completed", projectionJSON: "{\"id\":\"\(id)\",\"detailVersion\":3}", detailsRecordID: recordID)
      ]))
    }
    func expectError(_ code: String) async throws {
      do {
        _ = try await f.database.conversationActivityDetails(conversationID: conversationID, runID: runID, activityID: id)
        Issue.record("An incomplete or invalid chain returned a disclosure")
      } catch let error as CompanionAPIError { #expect(error.code == code) }
    }
    try await ingest(.conversation)
    try await point("head")
    try await expectError("incomplete_activity_details")
    for part in try parts("head", " suffix 🧵", previous: "middle") { try await ingest(.nativeRecord, native: part) }
    try await expectError("incomplete_activity_details")
    for part in try parts("middle", " café", previous: "base", version: 2) { try await ingest(.nativeRecord, native: part) }
    let base = String(repeating: "Reasoning e\u{301} 🧵\n", count: 30_000)
    let baseParts = try parts("base", base, version: 1)
    #expect(baseParts.count > 3)
    for (index, part) in baseParts.enumerated() {
      try await ingest(.nativeRecord, native: part)
      if index < baseParts.count - 1 { try await expectError("incomplete_activity_details") }
    }
    let expected = AgentRunActivity(id: id, kind: .thought, title: "Head metadata", content: base + " café suffix 🧵",
      contentIsDelta: false, detailsAvailable: true, detailVersion: 3)
    #expect(try await f.database.conversationActivityDetails(conversationID: conversationID, runID: runID, activityID: id) == expected)
    let reopened = try await WorkspaceDatabase(url: f.directory.appending(path: "workspace.sqlite"))
    #expect(try await reopened.conversationActivityDetails(conversationID: conversationID, runID: runID, activityID: id) == expected)
    for part in try parts("terminal", "Corrected final 🧵", version: 4) { try await ingest(.nativeRecord, native: part) }
    try await point("terminal")
    let terminal = try await f.database.conversationActivityDetails(conversationID: conversationID, runID: runID, activityID: id)
    #expect(terminal?.content == "Corrected final 🧵")
    #expect(terminal?.detailVersion == 4)
    for part in try parts("foreign", "Secret") { try await ingest(.nativeRecord, native: part, nativeRun: UUID().uuidString.lowercased()) }
    for part in try parts("wrong-run", "Suffix", previous: "foreign") { try await ingest(.nativeRecord, native: part) }
    try await point("wrong-run")
    try await expectError("invalid_activity_details")
    for part in try parts("wrong-id", "Other", identity: "another-activity") { try await ingest(.nativeRecord, native: part) }
    for part in try parts("identity-head", "Suffix", previous: "wrong-id") { try await ingest(.nativeRecord, native: part) }
    try await point("identity-head")
    try await expectError("invalid_activity_details")
    for part in try parts("cycle", "Suffix", previous: "cycle") { try await ingest(.nativeRecord, native: part) }
    try await point("cycle")
    try await expectError("invalid_activity_details")
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

}
