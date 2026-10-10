import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("Agent tools access, coordination and timers")
struct WorkspaceAgentToolTests {
  @Test func inputCapturesAreImmutableSessionScopedAndPermissionChecked() async throws {
    let (db, dir, caller, other) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = try await db.captureInputContext(conversationID: caller, noteID: "note-a")
    let later = try await db.captureInputContext(conversationID: caller, noteID: "note-b")
    let empty = try await db.captureInputContext(conversationID: caller, noteID: nil)
    #expect(try await db.inputContext(id: first, callerID: caller) == "note-a")
    #expect(try await db.inputContext(id: later, callerID: caller) == "note-b")
    #expect(try await db.inputContext(id: empty, callerID: caller) == nil)
    for id in [first, nil, "missing"] {
      await #expect(throws: (any Error).self) { try await db.inputContext(id: id, callerID: other) }
    }
    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    #expect(try await reopened.inputContext(id: first, callerID: caller) == "note-a")
    try await db.setSessionTools(.init(enabled: []), sessionID: caller)
    await #expect(throws: WorkspaceToolError.disabled(.notes)) { try await db.inputContext(id: first, callerID: caller) }
    let disabled = try await db.captureInputContext(conversationID: caller, noteID: "not-captured")
    try await db.setSessionTools(.init(enabled: [.notes]), sessionID: caller)
    #expect(try await db.inputContext(id: disabled, callerID: caller) == nil)
  }

  @Test func replacementTablesAreValidatedBeforeApplyingABatch() async throws {
    let malformed = NoteTableBlock(id: "table", columns: [NoteTableColumn()],
      rows: [NoteTableRow(cells: [])])
    let operations: [NoteEditOperation] = [
      .replaceBlock(id: "original", block: .table(malformed)),
      .setTableCell(tableID: "table", row: 0, column: 0, runs: [.init(text: "value")])
    ]
    // Applying this malformed batch before validating its shape indexes an empty cell array.
    #expect(throws: (any Error).self) {
      try RemoteNoteEditEnvelope.validate(operations: operations, noteKind: .note)
    }
    var oversized = malformed
    oversized.columns = Array(repeating: NoteTableColumn(), count: 129)
    #expect(throws: (any Error).self) {
      try RemoteNoteEditEnvelope.validate(operations: [.replaceBlock(id: "original", block: .table(oversized))], noteKind: .note)
    }
  }

  @Test func indexedTableInsertionsRequireTheRevisionTheyWerePlannedAgainst() async throws {
    let (db, dir, caller, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let note = try await db.createNote(folderID: nil, callerConversationID: caller, requestID: UUID().uuidString)
    let table = try await db.applyNoteEdits(.init(command: .apply, noteID: note,
      operations: [.createTable(afterBlockID: nil, rows: 2, columns: 2, headerRow: false)]),
      callerConversationID: caller, requestID: UUID().uuidString)
    let tableID = try #require(table.document?.blocks.last?.id)
    for operation: NoteEditOperation in [.addTableRow(tableID: tableID, after: 0), .addTableColumn(tableID: tableID, after: 0)] {
      await #expect(throws: (any Error).self) {
        try await db.applyNoteEdits(.init(command: .apply, noteID: note, operations: [operation]),
          callerConversationID: caller, requestID: UUID().uuidString)
      }
    }
    #expect(try await db.readNoteForEditing(id: note) == table)
    let appended = try await db.applyNoteEdits(.init(command: .apply, noteID: note,
      operations: [.addTableRow(tableID: tableID, after: nil)]), callerConversationID: caller, requestID: UUID().uuidString)
    #expect(appended.success)
  }

  @Test func legacyRevisionlessReceiptsReplayWithoutPermittingNewRevisionlessWrites() async throws {
    let (db, dir, caller, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let note = try await db.createNote(folderID: nil, title: "Original")
    let initial = try await db.readNoteForEditing(id: note)
    let requestID = UUID().uuidString.lowercased()
    let legacyRequest = NoteEditingRequest(command: .apply, noteID: note,
      operations: [.setTitle("Legacy edit")])
    let applied = try await db.applyNoteEdits(.init(command: .apply, noteID: note,
      expectedRevision: initial.revision, operations: legacyRequest.operations))
    // Model the durable pre-upgrade receipt, whose input had no revision. The
    // edit above already committed; seed its acknowledgement without nesting
    // applyNoteEdits' transaction inside the receipt fixture transaction.
    _ = try await db.write { connection in
      try connection.transaction {
        try connection.performToolMutationUnlocked(callerID: caller, requestID: requestID,
          operation: "notes.apply", input: legacyRequest, receipt: connection.noteMutationReceipt) {
            applied
          }.result
      }
    }
    let later = try await db.applyNoteEdits(.init(command: .apply, noteID: note,
      expectedRevision: applied.revision, operations: [.setTitle("Later user edit")]))
    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    let replay = try await reopened.applyNoteEdits(legacyRequest, callerConversationID: caller,
      requestID: requestID)
    #expect(replay.replayed == true && replay.revision == applied.revision)
    #expect(try await reopened.readNoteForEditing(id: note) == later)
    await #expect(throws: WorkspaceToolError.revisionRequired(
      "This note operation requires --revision. Read the note again and pass its current revision.")) {
      try await reopened.applyNoteEdits(legacyRequest, callerConversationID: caller,
        requestID: UUID().uuidString)
    }
    try await reopened.setSessionTools(.init(enabled: []), sessionID: caller)
    await #expect(throws: WorkspaceToolError.disabled(.notes)) {
      try await reopened.applyNoteEdits(legacyRequest, callerConversationID: caller,
        requestID: requestID)
    }
  }

  @Test func legacyUppercaseRequestIDsKeepTheirReceiptsAfterUpgrade() async throws {
    let (db, dir, caller, target) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let note = try await db.createNote(folderID: nil)
    let requestID = UUID().uuidString
    let request = NoteEditingRequest(command: .apply, noteID: note, operations: [.appendText("one append", .paragraph)])
    _ = try await db.applyNoteEdits(request, callerConversationID: caller, requestID: requestID)
    try await db.write { connection in
      try connection.toolsExecuteUnlocked("UPDATE workspace_tool_mutations SET request_id=upper(request_id) WHERE source_id=? AND request_id=?", [caller, requestID.lowercased()])
    }
    let replay = try await db.applyNoteEdits(request, callerConversationID: caller, requestID: requestID.lowercased())
    #expect(replay.replayed == true)
    #expect(try await db.readNoteForEditing(id: note).document?.plainText.components(separatedBy: "one append").count == 2)

    try await db.beginCoordination(sourceID: caller, targetID: target, purpose: "Retry")
    let deliveryID = UUID().uuidString
    _ = try await db.reserveToolDelivery(sourceID: caller, targetID: target, text: "Delivered once", requestID: deliveryID)
    try await db.write { connection in
      try connection.toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET id=upper(id) WHERE id=?", [deliveryID.lowercased()])
    }
    #expect(try await db.toolDelivery(id: deliveryID.lowercased()) != nil)
    #expect(try await db.claimToolDelivery(id: deliveryID.lowercased()) != nil)
    try await db.setToolDeliveryStatus(id: deliveryID.lowercased(), status: "accepted")
    #expect(try await db.reserveToolDelivery(sourceID: caller, targetID: target, text: "Delivered once", requestID: deliveryID.lowercased()).status == "accepted")

    let creationID = UUID().uuidString
    let arguments = ["sessions", "create", "--title", "Once"]
    let reservation = try await db.reserveToolSessionCreation(sourceID: caller, requestID: creationID, arguments: arguments, purpose: "Retry", managed: false)
    try await db.write { connection in
      try connection.toolsExecuteUnlocked("UPDATE workspace_session_creations SET id=upper(id) WHERE id=?", [creationID.lowercased()])
    }
    let retry = try await db.reserveToolSessionCreation(sourceID: caller, requestID: creationID.lowercased(), arguments: arguments, purpose: "Retry", managed: false)
    #expect(retry.objectValue?["target_id"] == reservation.objectValue?["target_id"])
    // Old builds could persist both spellings. Preserve that evidence and reject ambiguity.
    try await db.write { connection in
      try connection.toolsExecuteUnlocked("INSERT INTO workspace_tool_mutations SELECT source_id,lower(request_id),operation,input_digest,result_json FROM workspace_tool_mutations WHERE source_id=? AND request_id=?", [caller, requestID])
    }
    await #expect(throws: (any Error).self) {
      _ = try await db.applyNoteEdits(request, callerConversationID: caller, requestID: requestID.lowercased())
    }
  }

  @Test func linkedSQLiteRejectsPragmasBeforeOpeningAnyDatabase() {
    // Use a nonexistent path: this assertion never executes a process-wide
    // allocator-changing pragma even if prefix validation regresses.
    #expect(throws: DatabaseLinkedDataError.sqliteReadOnlyQueryRequired) {
      try DatabaseLinkedData.load(from: URL(fileURLWithPath: "/nonexistent/pr85-linked-data.sqlite"),
        preference: .sqlite, sqliteQuery: "PRAGMA hard_heap_limit=1")
    }
  }

  @Test func linkedSQLitePreservesEmbeddedNULTextAndBudgetsItsSuffix() async throws {
    let (db, dir, _, _) = try await fixture()
    _ = db
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "workspace.sqlite")
    let table = try DatabaseLinkedData.load(from: url, preference: .sqlite,
      sqliteQuery: "SELECT 'before'||char(0)||'after 🪡' AS value")
    #expect(table.rows == [["before\0after 🪡"]])
    let object = try JSONSerialization.jsonObject(with: Data(table.json.utf8)) as? [[String: String]]
    #expect(object?.first?["value"] == "before\0after 🪡")
    #expect(throws: DatabaseLinkedDataError.sqliteResultTooLarge) {
      try DatabaseLinkedData.load(from: url, preference: .sqlite,
        sqliteQuery: "WITH n(x) AS (VALUES(1),(2),(3)) SELECT char(0)||replace(hex(zeroblob(100000)),'0',char(1)) AS value FROM n")
    }
  }

  @Test func sqliteResultBudgetsIncludeJSONEscaping() async throws {
    let control = String(repeating: "\u{0001}", count: 200_000)
    #expect(throws: DatabaseLinkedDataError.sqliteResultTooLarge) {
      try DatabaseLinkedData.load(queryResponse: .init(columns: ["value"],
        rows: Array(repeating: [control], count: 3)))
    }
    #expect(throws: DatabaseLinkedDataError.sqliteResultTooLarge) {
      try DatabaseLinkedData.load(queryResponse: .init(columns: [String(repeating: "\u{0001}", count: 4_000)],
        rows: Array(repeating: ["value"], count: 100)))
    }
    let (db, dir, _, _) = try await fixture()
    _ = db
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: DatabaseLinkedDataError.sqliteResultTooLarge) {
      try DatabaseLinkedData.load(from: dir.appending(path: "workspace.sqlite"), preference: .sqlite,
        sqliteQuery: "WITH n(x) AS (VALUES(1),(2),(3)) SELECT replace(hex(zeroblob(100000)),'0',char(1)) AS value FROM n")
    }
  }

  @Test func managementReceiptKeepsItsOriginalCoordinationEpoch() async throws {
    let (db, dir, caller, target) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let requestID = UUID().uuidString
    let first = try await db.requestCoordinationAccess(sourceID: caller, targetID: target, purpose: "First", requestID: requestID)
    let accepted = first.state == "pending" ? try await db.resolveCoordinationAccess(requestID: requestID, allowed: true) : first
    let epoch = try #require(accepted.coordinationEpoch)
    try await db.endCoordination(targetID: target, sourceID: caller)
    try await db.beginCoordination(sourceID: caller, targetID: target, purpose: "New", userApprovedAccess: true)
    let replay = try await db.requestCoordinationAccess(sourceID: caller, targetID: target, purpose: "First", requestID: requestID)
    #expect(replay.coordinationEpoch == epoch)
    #expect(try await replay.coordinationEpoch != db.sessionRelationship(target).coordinationEpoch)
  }

  @Test func editBatchesCannotExceedDocumentLimitsBetweenOperations() async throws {
    let document = NoteDocument(blocks: [.richText(.init(id: "left")), .richText(.init(id: "right"))])
    var left = NoteTableBlock(rows: 100, columns: 100); left.id = "left"
    var right = NoteTableBlock(rows: 100, columns: 100); right.id = "right"
    let operations: [NoteEditOperation] = [.replaceBlock(id: "left", block: .table(left)),
      .replaceBlock(id: "right", block: .table(right)), .deleteBlock(id: "right")]
    #expect(throws: RemoteNoteEditError.operationTooLarge) {
      try RemoteNoteEditEnvelope.validate(operations: operations, applyingTo: document)
    }
  }

  @Test func linkedSQLiteQueriesHaveExecutionAndResultBudgets() async throws {
    let (db, dir, _, _) = try await fixture()
    _ = db
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "workspace.sqlite")
    #expect(throws: DatabaseLinkedDataError.sqliteResultTooLarge) {
      try DatabaseLinkedData.load(from: url, preference: .sqlite,
        sqliteQuery: "SELECT hex(randomblob(300000)) AS payload")
    }
    #expect(throws: DatabaseLinkedDataError.sqliteQueryLimitExceeded) {
      try DatabaseLinkedData.load(from: url, preference: .sqlite,
        sqliteQuery: "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT sum(x) FROM n")
    }
    #expect(throws: DatabaseLinkedDataError.sqliteResultTooLarge) {
      try DatabaseLinkedData.load(queryResponse: .init(columns: ["value"],
        rows: [[String(repeating: "x", count: DatabaseLinkedData.maximumSQLiteCellBytes + 1)]]))
    }
  }

  @Test func coordinationEpochsMakeReleaseAndNotificationRetriesSafe() async throws {
    let (db, dir, source, target) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await db.beginCoordination(sourceID: source, targetID: target, purpose: "First assignment")
    let firstEpoch = try await #require(db.sessionRelationship(target).coordinationEpoch)
    let notificationID = UUID().uuidString
    let changed = try await db.setAgentCoordinationNotifications(sourceID: source, targetID: target,
      epoch: firstEpoch, enabled: false, requestID: notificationID)
    let notificationReplay = try await db.setAgentCoordinationNotifications(sourceID: source, targetID: target,
      epoch: firstEpoch, enabled: false, requestID: notificationID.lowercased())
    #expect(!changed.replayed && notificationReplay.replayed)

    let releaseID = UUID().uuidString
    let released = try await db.releaseAgentCoordination(sourceID: source, targetID: target,
      epoch: firstEpoch, requestID: releaseID)
    #expect(!released.replayed)
    try await db.beginCoordination(sourceID: source, targetID: target, purpose: "New assignment")
    let secondEpoch = try await #require(db.sessionRelationship(target).coordinationEpoch)
    #expect(secondEpoch != firstEpoch)
    let replay = try await db.releaseAgentCoordination(sourceID: source, targetID: target,
      epoch: firstEpoch, requestID: releaseID.lowercased())
    #expect(replay.replayed)
    #expect(try await db.sessionRelationship(target).coordinationEpoch == secondEpoch)
    await #expect(throws: WorkspaceToolError.revisionConflict(
      "The coordination epoch is stale. Read sessions status and retry with its current epoch.")) {
      try await db.releaseAgentCoordination(sourceID: source, targetID: target,
        epoch: firstEpoch, requestID: UUID().uuidString)
    }
    #expect(try await db.sessionRelationship(target).coordinationEpoch == secondEpoch)
  }

  @Test func noteMutationLimitsRejectOversizedAndInvalidWorkAtomically() async throws {
    let (db, dir, caller, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let note = try await db.createNote(folderID: nil, callerConversationID: caller,
      requestID: UUID().uuidString)
    let original = try await db.readNoteForEditing(id: note)
    await #expect(throws: (any Error).self) {
      try await db.applyNoteEdits(.init(command: .apply, noteID: note,
        operations: Array(repeating: .appendText("x", .paragraph), count: 129)),
        callerConversationID: caller, requestID: UUID().uuidString)
    }
    await #expect(throws: (any Error).self) {
      try await db.applyNoteEdits(.init(command: .apply, noteID: note,
        operations: [.createTable(afterBlockID: nil, rows: -1, columns: 2, headerRow: false)]),
        callerConversationID: caller, requestID: UUID().uuidString)
    }
    await #expect(throws: (any Error).self) {
      try await db.applyNoteEdits(.init(command: .apply, noteID: note,
        expectedRevision: original.revision, operations: [.setTitle(String(repeating: "t", count: 1_025))]),
        callerConversationID: caller, requestID: UUID().uuidString)
    }
    let table = try await db.applyNoteEdits(.init(command: .apply, noteID: note,
      operations: [.createTable(afterBlockID: nil, rows: 1, columns: 1, headerRow: false)]),
      callerConversationID: caller, requestID: UUID().uuidString)
    let tableID = try #require(table.document?.blocks.last?.id)
    await #expect(throws: (any Error).self) {
      try await db.applyNoteEdits(.init(command: .apply, noteID: note,
        operations: [.addTableRow(tableID: tableID, after: Int.max)]),
        callerConversationID: caller, requestID: UUID().uuidString)
    }
  }

  @Test func discoveryPaginationAndRequestIDCanonicalizationAreConsistent() async throws {
    let (db, dir, caller, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let expectedFolders = [
      try await db.createFolder(name: "Discoverable"),
      try await db.createFolder(name: "Second folder"),
      try await db.createFolder(name: "Third folder")
    ]
    let note = try await db.createNote(folderID: nil, title: "Deep search", kind: .note,
      callerConversationID: caller, requestID: UUID().uuidString)
    let requestID = UUID().uuidString
    let text = String(repeating: "prefix ", count: 100) + "distantneedle"
    _ = try await db.applyNoteEdits(.init(command: .apply, noteID: note,
      operations: [.appendText(text, .paragraph)]), callerConversationID: caller, requestID: requestID)
    _ = try await db.applyNoteEdits(.init(command: .apply, noteID: note,
      operations: [.appendText(text, .paragraph)]), callerConversationID: caller,
      requestID: requestID.lowercased())
    #expect(try await db.readNoteForEditing(id: note).document?.plainText
      .components(separatedBy: "distantneedle").count == 2)
    let notes = try await db.listAgentNotes(callerID: caller, search: "distantneedle", limit: 1)
    #expect(notes.objectValue?["rows"]?.arrayValue?.first?.objectValue?["kind"]?.stringValue == "note")
    let newer = try await db.createNote(folderID: nil, title: "Newer", callerConversationID: caller,
      requestID: UUID().uuidString)
    let newest = try await db.listAgentNotes(callerID: caller, limit: 1)
    let oldest = try await db.listAgentNotes(callerID: caller, after: 0, limit: 1, newestFirst: false)
    #expect(newest.objectValue?["rows"]?.arrayValue?.first?.objectValue?["id"]?.stringValue == newer)
    #expect(oldest.objectValue?["rows"]?.arrayValue?.first?.objectValue?["id"]?.stringValue == note)

    try await db.setSessionTools(.init(enabled: [.notes, .timers]), sessionID: caller)
    let folders = try await db.listAgentFolders(callerID: caller, requiredTool: .notes, limit: 1)
    #expect(folders.objectValue?["rows"]?.arrayValue?.count == 1)
    let firstFolder = folders.objectValue?["rows"]?.arrayValue?.first?.objectValue?["id"]?.stringValue
    let folderCursor = Int64(folders.objectValue?["nextCursor"]?.intValue ?? 0)
    let remainingFolders = try await db.listAgentFolders(callerID: caller, requiredTool: .notes,
      after: folderCursor, limit: 200)
    let folderIDs = ([firstFolder] + (remainingFolders.objectValue?["rows"]?.arrayValue?.map {
      $0.objectValue?["id"]?.stringValue
    } ?? [])).compactMap { $0 }
    #expect(folderIDs == expectedFolders)
    for index in 0..<3 {
      try await db.saveSessionTimer(.init(sessionID: caller, instruction: "Timer \(index)",
        nextFireAt: Date(timeIntervalSince1970: 4_000_000_000 + Double(index))), callerID: caller)
    }
    let timers = try await db.querySessionTimers(callerID: caller, sessionID: caller, limit: 1)
    #expect(timers.objectValue?["rows"]?.arrayValue?.count == 1)
    #expect(timers.objectValue?["hasMore"]?.boolValue == true)
  }

  @Test func builtInClaudeUsageKeepsSubscriptionAndAPIKeyBillingDistinct() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "usage.sqlite")
    let recorder = try await UsageRunRecorder(databaseURL: url)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    for provider in ["claude-subscription", "anthropic"] {
      try await recorder.record(.init(runID: provider, timestamp: date, runtimeKind: .defaultAgent,
        sessionID: "fixture", model: provider + "/sonnet", reasoningLevel: "high", agent: "Built-in",
        workspace: "local", tokens: .init(inputTokens: 3, outputTokens: 2), costUSD: nil))
    }
    let samples = try UsageStore(databaseURL: url).samples(in: DateInterval(start: date.addingTimeInterval(-1), duration: 2))
    #expect(samples.count == 2)
    #expect(samples.allSatisfy { $0.provider == .claude })
    #expect(Set(samples.map(\.billingRoute)) == ["Claude subscription", "Claude API key"])
  }
  @Test func explicitCreationDirectoryCrossesParserAndRejectsInvalidPathsBeforeSaving() async throws {
    let (db, root, source, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for directory in ["/workspace/a quoted ' project", "relative/project", "/workspace/invalid\0suffix"] {
      let command = try WovenMatterToolCommand(["sessions", "create", "--title", "Explicit directory", "--directory", directory])
      #expect(command.options["directory"] == directory)
      let requestID = UUID().uuidString
      let reserved = try await db.reserveToolSessionCreation(sourceID: source, requestID: requestID,
        arguments: command.operationArguments, purpose: "Check location", managed: false)
      let target = try #require(reserved.objectValue?["target_id"]?.stringValue)
      let configuration = WorkspaceSessionCreationConfiguration(runtimeKind: .codex, title: "Explicit directory",
        nativeWorkingDirectory: command.options["directory"])
      if directory.hasPrefix("/"), !directory.contains("\0") {
        _ = try await db.saveToolSessionCreationConfiguration(requestID: requestID, sourceID: source, configuration: configuration)
        #expect(try await db.toolSessionCreationConfiguration(targetID: target)?.nativeWorkingDirectory == directory)
      } else {
        await #expect(throws: WorkspaceToolError.self) {
          try await db.saveToolSessionCreationConfiguration(requestID: requestID, sourceID: source, configuration: configuration)
        }
        #expect(try await db.toolSessionCreationConfiguration(targetID: target) == nil)
      }
    }
  }

  @Test func usageConnectionCanIngestAfterWorkspaceSchemaMigration() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "workspace.sqlite")
    let recorder = try await UsageRunRecorder(databaseURL: url)
    let usageReader = try UsageStore(databaseURL: url)
    let database = try await WorkspaceDatabase(url: url)
    let session = try await database.createLocalACPSession(runtimeKind: .codex, title: "Recorded usage", ownerDeviceID: UUID())
    let run = try await database.beginLocalACPRun(conversationID: session, content: "Offline fixture")
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let observation = UsageRunRecorder.Observation(runID: run.runID, timestamp: date,
      runtimeKind: .codex, sessionID: session, model: "fixture", reasoningLevel: nil,
      agent: "fixture", workspace: directory.path, tokens: .init(inputTokens: 17, outputTokens: 5), costUSD: nil)
    try await recorder.record(observation)
    try await recorder.record(observation)
    let samples = try usageReader.samples(in: DateInterval(start: date.addingTimeInterval(-1), duration: 2))
    #expect(samples.count == 1)
    #expect(samples.first?.sessionID == session && samples.first?.sourceEventID == session + ":" + run.runID)
    #expect(samples.first?.tokens.inputTokens == 17 && samples.first?.tokens.outputTokens == 5)
    try await database.recoverInterruptedLocalACPRuns()
    #expect(try await database.conversationContent(id: session).runs.first?.status == "failed")
  }

  @Test func freshDashboardStoreAndUsageInitializationRetainTheWorkspaceSchema() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await DashboardStore(supportDirectory: directory)
    let session = try await store.database.createLocalACPSession(runtimeKind: .codex, title: "Fresh app", ownerDeviceID: UUID())
    #expect(try await store.database.toolSettings().enabledByDefault == Set(WorkspaceToolGroup.allCases.filter { $0 != .executor }))
    let run = try await store.database.beginLocalACPRun(conversationID: session, content: "Retained input")
    try await store.database.completeLocalACPRun(runID: run.runID)
    await store.shutdownLocalACPSessions()
    let reopened = try await DashboardStore(supportDirectory: directory)
    #expect(try await reopened.database.conversationContent(id: session).messages.first?.content == "Retained input")
    #expect(try await reopened.database.sessionTools(session).enabled == Set(WorkspaceToolGroup.allCases.filter { $0 != .executor }))
    await reopened.shutdownLocalACPSessions()
  }

  private func fixture() async throws -> (WorkspaceDatabase, URL, String, String) {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    let a = try await db.createLocalACPSession(runtimeKind: .codex, title: "Coordinator", ownerDeviceID: UUID())
    let b = try await db.createLocalACPSession(runtimeKind: .pi, title: "Destination", ownerDeviceID: UUID())
    return (db, dir, a, b)
  }

  @Test func asynchronousPreparationHoldsCapacityAndSteeringNeedsNoNewSlot() {
    var gate = WorkspaceSessionAdmission()
    #expect(gate.begin("a", running: [], limit: 1) == .start)
    #expect(gate.begin("b", running: [], limit: 1) == .atCapacity)
    #expect(gate.begin("a", running: ["a"], limit: 1) == .preparing)
    gate.finish("a")
    #expect(gate.begin("a", running: ["a"], limit: 1) == .steer)
    #expect(gate.begin("b", running: ["a"], limit: 2) == .start)
    #expect(gate.begin("c", running: ["a"], limit: 2) == .atCapacity)
    gate.finish("b") // failed preparation releases its reservation
    #expect(gate.begin("c", running: ["a"], limit: 2) == .start)
    var maximum = WorkspaceSessionAdmission()
    for n in 0..<48 { #expect(maximum.begin(String(n), running: [], limit: 48) == .start) }
    #expect(maximum.begin("49", running: [], limit: 48) == .atCapacity)
  }

  @Test func creationCommitGrantsManagedReadOnceAndRetryDoesNotReacquireReleasedSession() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await db.setSessionTools(.init(enabled: [.sessions]), sessionID: a)
    let request = UUID().uuidString.lowercased()
    let reserved = try await db.reserveToolSessionCreation(sourceID: a, requestID: request, arguments: ["sessions", "create"], purpose: "Build", managed: true)
    let target = try #require(reserved.objectValue?["target_id"]?.stringValue)
    _ = try await db.createLocalACPSession(runtimeKind: .pi, title: "Created", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    await #expect(throws: WorkspaceToolError.accessRequired(target)) { try await db.requireTranscriptAccess(sourceID: a, targetID: target) }
    await #expect(throws: (any Error).self) { try await db.completeToolSessionCreation(requestID: request, sourceID: b) }
    try await db.completeToolSessionCreation(requestID: request, sourceID: a)
    try await db.requireTranscriptAccess(sourceID: a, targetID: target)
    try await db.setCoordinationNotifications(sourceID: a, targetID: target, enabled: false)
    #expect(try await !db.sessionRelationship(target).notificationsEnabled)
    await #expect(throws: (any Error).self) { try await db.setCoordinationNotifications(sourceID: b, targetID: target, enabled: true) }
    try await db.endCoordination(targetID: target, sourceID: a)
    try await db.completeToolSessionCreation(requestID: request, sourceID: a)
    #expect(try await db.sessionRelationship(target).coordinatorID == nil)
    #expect(try await db.sessionRelationship(target).createdBy == a)
    await #expect(throws: WorkspaceToolError.accessRequired(target)) { try await db.requireTranscriptAccess(sourceID: a, targetID: target) }
  }

  @Test func pausingTimerAfterQueuePreventsItsDeferredDelivery() async throws {
    let (db, dir, a, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let timer = WorkspaceSessionTimer(sessionID: a, instruction: "Follow up", nextFireAt: .distantPast)
    try await db.saveSessionTimer(timer, callerID: a)
    let due = try await #require(db.dueSessionTimers().first)
    let id = try #require(due.pendingDeliveryID)
    _ = try await db.reserveToolDelivery(sourceID: a, targetID: a, text: due.instruction, requestID: id, kind: .timer)
    try await db.pauseSessionTimer(id: timer.id, paused: true)
    #expect(try await db.claimToolDelivery(id: id) == nil)
    #expect(try await db.toolDelivery(id: id)?.status == "cancelled")
  }

  @Test func defaultsAreSnapshotsAndCalendarModeIsGlobal() async throws {
    let (db, dir, a, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var defaults = try await db.toolSettings()
    #expect(defaults.maximumManagedSessions == 4 && defaults.maximumRunningSessions == 16)
    #expect(defaults.calendarAccess == .full)
    defaults.enabledByDefault.remove(.history)
    defaults.calendarAccess = .readOnly
    try await db.saveToolSettings(defaults)
    let c = try await db.createLocalACPSession(runtimeKind: .claudeCode, title: "New", ownerDeviceID: UUID())
    #expect(try await db.sessionTools(a).enabled.contains(.history))
    #expect(try await !db.sessionTools(c).enabled.contains(.history))
    await #expect(throws: (any Error).self) { try await db.requireTool(.calendar, sessionID: a, writesCalendar: true) }
    try await db.requireTool(.calendar, sessionID: a)
    defaults.maximumRunningSessions = 49
    await #expect(throws: (any Error).self) { try await db.saveToolSettings(defaults) }
    #expect(try await db.toolSettings().maximumRunningSessions == 16)
    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    #expect(try await reopened.sessionTools(c) == db.sessionTools(c))
  }

  @Test func calendarReadOnlyAndNotesRevocationProtectActualWrites() async throws {
    let (db, dir, a, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let starts = Date(timeIntervalSince1970: 1_000)
    let id = try await db.saveAgentCalendar(callerID: a, creating: true, title: "Review", details: "Feature review",
      startsAt: starts, endsAt: starts.addingTimeInterval(3_600), allDay: false)
    #expect(try await db.listAgentCalendar(callerID: a).objectValue?["rows"]?.arrayValue?.count == 1)
    _ = try await db.saveAgentCalendar(callerID: a, id: id, creating: false, title: "Updated", details: nil,
      startsAt: starts, endsAt: nil, allDay: true)
    var settings = try await db.toolSettings(); settings.calendarAccess = .readOnly
    try await db.saveToolSettings(settings)
    await #expect(throws: (any Error).self) { try await db.removeAgentCalendar(callerID: a, id: id) }
    await #expect(throws: (any Error).self) {
      try await db.saveAgentCalendar(callerID: a, id: id, creating: false, title: "Forbidden", details: nil,
        startsAt: starts, endsAt: nil, allDay: true)
    }
    #expect(try await db.listAgentCalendar(callerID: a).objectValue?["rows"]?.arrayValue?.first?.objectValue?["title"]?.stringValue == "Updated")
    let note = try await db.createNote(folderID: nil, callerConversationID: a)
    let revision = try await #require(db.readNoteForEditing(id: note, callerConversationID: a).revision)
    try await db.setSessionTools(.init(enabled: [.history]), sessionID: a)
    await #expect(throws: WorkspaceToolError.disabled(.notes)) { try await db.readNoteForEditing(id: note, callerConversationID: a) }
    await #expect(throws: WorkspaceToolError.disabled(.notes)) {
      try await db.applyNoteEdits(.init(command: .apply, noteID: note, expectedRevision: revision, operations: [.setTitle("Forbidden")]), callerConversationID: a)
    }
    #expect(try await db.readNoteForEditing(id: note).title == "Untitled Note")
  }

  @Test func referencesGrantOnlyTheSelectedSessionAndCanBeRevoked() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await db.setSessionTools(.init(enabled: [.sessions, .notes]), sessionID: a)
    let c = try await db.createLocalACPSession(runtimeKind: .pi, title: "Unattached", ownerDeviceID: UUID())
    await #expect(throws: WorkspaceToolError.accessRequired(b)) { try await db.requireTranscriptAccess(sourceID: a, targetID: b) }
    try await db.attachConversationReference(sourceID: a, targetID: b)
    try await db.requireTranscriptAccess(sourceID: a, targetID: b)
    _ = try await db.queryAgentHistory(.init(command: "conversation", id: b), callerID: a)
    await #expect(throws: WorkspaceToolError.accessRequired(c)) { try await db.queryAgentHistory(.init(command: "conversation", id: c), callerID: a) }
    await #expect(throws: WorkspaceToolError.disabled(.history)) { try await db.queryAgentHistory(.init(command: "search", search: "secret"), callerID: a) }
    try await db.removeConversationReference(sourceID: a, targetID: b)
    await #expect(throws: WorkspaceToolError.accessRequired(b)) { try await db.requireTranscriptAccess(sourceID: a, targetID: b) }
  }

  @Test func eventIDsAndRunIDsCannotBypassTranscriptGrants() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let run = try await db.beginLocalACPRun(conversationID: b, content: "Private content")
    try await db.recordHistory(.init(id: "event", conversationID: b, runID: run.runID, harness: "pi", kind: "wire.in", payload: "Private event"))
    try await db.setSessionTools(.init(enabled: [.sessions]), sessionID: a)
    for query in [WorkspaceHistoryQuery(command: "event", id: "event"), .init(command: "trace", id: run.runID),
                  .init(command: "message", id: run.userMessageID), .init(command: "runs", conversationID: b)] {
      await #expect(throws: WorkspaceToolError.accessRequired(b)) { try await db.queryAgentHistory(query, callerID: a) }
    }
    try await db.attachConversationReference(sourceID: a, targetID: b)
    let result = try await db.queryAgentHistory(.init(command: "trace", id: run.runID), callerID: a)
    let trace = result.objectValue?["rows"]?.arrayValue ?? []
    #expect(trace.contains { $0.objectValue?["id"]?.stringValue == "event" })
    // Notes history remains behind Notes even if full conversation history is on.
    try await db.setSessionTools(.init(enabled: [.history]), sessionID: a)
    await #expect(throws: WorkspaceToolError.disabled(.notes)) { try await db.queryAgentHistory(.init(command: "versions", id: "note"), callerID: a) }
  }

  @Test func metadataDoesNotGrantCoordinationButUserApprovalDoes() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await db.setSessionTools(.init(enabled: [.sessions]), sessionID: a)
    let metadata = try await db.queryAgentHistory(.init(command: "conversations"), callerID: a)
    #expect(metadata.objectValue?["rows"]?.arrayValue?.count == 2)
    await #expect(throws: WorkspaceToolError.accessRequired(b)) { try await db.beginCoordination(sourceID: a, targetID: b, purpose: "Monitor") }
    try await db.beginCoordination(sourceID: a, targetID: b, purpose: "Monitor", userApprovedAccess: true)
    try await db.requireTranscriptAccess(sourceID: a, targetID: b)
    try await db.endCoordination(targetID: b, sourceID: a)
    await #expect(throws: WorkspaceToolError.accessRequired(b)) { try await db.requireTranscriptAccess(sourceID: a, targetID: b) }
  }

  @Test func originSurvivesManagementAndRetriesDoNotReenableTools() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await db.setSessionTools(.init(enabled: [.sessions]), sessionID: a)
    try await db.recordSessionOrigin(sourceID: a, targetID: b, purpose: "Write report")
    #expect(try await db.sessionTools(b).enabled == [.sessions])
    try await db.requireTranscriptAccess(sourceID: a, targetID: b)
    try await db.endCoordination(targetID: b)
    try await db.setSessionTools(.init(enabled: []), sessionID: b)
    try await db.recordSessionOrigin(sourceID: a, targetID: b, purpose: "Retry")
    let relationship = try await db.sessionRelationship(b)
    #expect(relationship.createdBy == a && relationship.coordinatorID == nil)
    #expect(try await db.sessionTools(b).enabled.isEmpty)
    await #expect(throws: WorkspaceToolError.accessRequired(b)) { try await db.requireTranscriptAccess(sourceID: a, targetID: b) }
  }

  @Test func onlyOneCoordinatorWinsCompetingRequests() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = try await db.createLocalACPSession(runtimeKind: .pi, title: "Other", ownerDeviceID: UUID())
    let winners = await withTaskGroup(of: String?.self) { group in
      for source in [a, c] { group.addTask {
        do { try await db.beginCoordination(sourceID: source, targetID: b, purpose: "Manage"); return source }
        catch { return nil }
      } }
      var values: [String] = []
      for await value in group { if let value { values.append(value) } }
      return values
    }
    #expect(winners.count == 1)
    let winner = try #require(winners.first)
    let loser = winner == a ? c : a
    #expect(try await db.sessionRelationship(b).coordinatorID == winner)
    await #expect(throws: WorkspaceToolError.coordinationConflict(winner)) { try await db.beginCoordination(sourceID: loser, targetID: b, purpose: "Compete") }
    await #expect(throws: WorkspaceToolError.coordinationConflict(winner)) { try await db.endCoordination(targetID: b, sourceID: loser) }
  }

  @Test func fanoutAndRevocationAreEnforcedTransactionally() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var settings = try await db.toolSettings()
    settings.maximumManagedSessions = 1
    try await db.saveToolSettings(settings)
    try await db.beginCoordination(sourceID: a, targetID: b, purpose: "Manage")
    try await db.beginCoordination(sourceID: a, targetID: b, purpose: "Update intent")
    let c = try await db.createLocalACPSession(runtimeKind: .pi, title: "Other", ownerDeviceID: UUID())
    await #expect(throws: WorkspaceToolError.managedLimit(1)) { try await db.beginCoordination(sourceID: a, targetID: c, purpose: "Over limit") }
    #expect(try await db.sessionRelationship(c).coordinatorID == nil)
    await #expect(throws: (any Error).self) { try await db.beginCoordination(sourceID: b, targetID: a, purpose: "Cycle") }
    try await db.setSessionTools(.init(enabled: []), sessionID: a)
    #expect(try await db.sessionRelationship(b).coordinatorID == nil)
    await #expect(throws: WorkspaceToolError.disabled(.sessions)) { try await db.beginCoordination(sourceID: a, targetID: c, purpose: "Disabled") }
  }

  @Test func timerOccurrencesSurviveReopenAndPauseRevokesPendingDelivery() async throws {
    let (db, dir, a, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 1_000)
    let timer = WorkspaceSessionTimer(sessionID: a, instruction: "Check progress", nextFireAt: now, intervalSeconds: 60)
    try await db.saveSessionTimer(timer, callerID: a)
    #expect(try await db.dueSessionTimers(now: now.addingTimeInterval(-1)).isEmpty)
    let claimed = try await #require(db.dueSessionTimers(now: now).first)
    let delivery = try #require(claimed.pendingDeliveryID)
    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    #expect(try await reopened.dueSessionTimers(now: now).first?.pendingDeliveryID == delivery)
    await #expect(throws: WorkspaceToolError.timerPauseConfirmation) { try await db.setSessionTools(.init(enabled: [.sessions]), sessionID: a) }
    #expect(try await db.isTimerOccurrenceActive(id: timer.id, deliveryID: delivery))
    try await db.setSessionTools(.init(enabled: [.sessions]), sessionID: a, confirmedPausingTimers: true)
    #expect(try await !db.isTimerOccurrenceActive(id: timer.id, deliveryID: delivery))
    #expect(try await db.sessionTimers(sessionID: a).first?.isPaused == true)
    await #expect(throws: WorkspaceToolError.disabled(.timers)) { try await db.pauseSessionTimer(id: timer.id, paused: false) }
    try await db.setSessionTools(.init(), sessionID: a)
    #expect(try await db.dueSessionTimers(now: now).isEmpty)
  }

  @Test func timersCoalesceMissedFiringsAndOneShotCompletesOnce() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 1_000)
    for interval in [nil, 60] as [TimeInterval?] {
      let timer = WorkspaceSessionTimer(sessionID: a, instruction: "Check", nextFireAt: now, intervalSeconds: interval)
      try await db.saveSessionTimer(timer, callerID: a)
      let fire = try await #require(db.dueSessionTimers(now: now.addingTimeInterval(3_600)).first(where: { $0.id == timer.id }))
      let delivery = try #require(fire.pendingDeliveryID)
      _ = try await db.reserveToolDelivery(sourceID: a, targetID: a, text: timer.instruction, requestID: delivery, kind: .timer)
      _ = try await db.claimToolDelivery(id: delivery)
      try await db.setToolDeliveryStatus(id: delivery, status: "accepted")
      try await db.finishTimerOccurrence(id: timer.id, deliveryID: delivery, now: now.addingTimeInterval(3_600))
      let final = try await #require(db.sessionTimers(sessionID: a).first(where: { $0.id == timer.id }))
      #expect(final.isPaused == (interval == nil))
      if interval != nil { #expect(final.nextFireAt == now.addingTimeInterval(3_660)) }
      try await db.finishTimerOccurrence(id: timer.id, deliveryID: delivery, now: now.addingTimeInterval(7_200))
      #expect(try await db.sessionTimers(sessionID: a).first(where: { $0.id == timer.id }) == final)
      await #expect(throws: (any Error).self) { try await db.removeSessionTimer(id: timer.id, callerID: b) }
    }
  }

  @Test func folderSearchBroadensOnlyWhenNoLocalMatchExists() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = try await db.createFolder(name: "Project")
    _ = try await db.moveConversation(id: a, toFolderID: folder)
    try await db.recordHistory(.init(id: "local", conversationID: a, harness: "codex", kind: "wire.in", payload: "needle"))
    try await db.recordHistory(.init(id: "outside", conversationID: b, harness: "pi", kind: "wire.in", payload: "needle external-only"))
    let local = try await db.queryAgentHistory(.init(command: "search", search: "needle"), callerID: a)
    #expect(local.objectValue?["scope"]?.stringValue == "folder")
    #expect(local.objectValue?["rows"]?.arrayValue?.map { $0.objectValue?["id"]?.stringValue } == ["local"])
    let fallback = try await db.queryAgentHistory(.init(command: "search", search: "external-only"), callerID: a)
    #expect(fallback.objectValue?["scope"]?.stringValue == "workspace")
    let global = try await db.queryAgentHistory(.init(command: "search", search: "needle"), callerID: a, allWorkspace: true)
    #expect(global.objectValue?["rows"]?.arrayValue?.count == 2)
  }

  @Test func deliveriesClaimOnceAndRecoverWithoutDuplicateDispatch() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID().uuidString.lowercased()
    let first = try await db.reserveToolDelivery(sourceID: a, targetID: b, text: "Do the work", requestID: id)
    #expect(first.sourceTitle == "Coordinator" && first.targetTitle == "Destination")
    #expect(first.sourceHarness == "codex" && first.targetHarness == "pi")
    _ = try await db.reserveToolDelivery(sourceID: a, targetID: b, text: "Do the work", requestID: id)
    let claims = try await withThrowingTaskGroup(of: Bool.self) { group in
      for _ in 0..<5 { group.addTask { try await db.claimToolDelivery(id: id) != nil } }
      var count = 0
      for try await claimed in group where claimed { count += 1 }
      return count
    }
    #expect(claims == 1)
    try await db.markToolDeliveryTransportStarted(id: id)
    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    try await reopened.recoverToolDeliveries()
    #expect(try await reopened.sessionDeliveries(sessionID: a).first?.status == "uncertain")
    #expect(try await reopened.claimToolDelivery(id: id) == nil)
    await #expect(throws: (any Error).self) { try await db.reserveToolDelivery(sourceID: b, targetID: a, text: "Do the work", requestID: id) }
  }

  @Test func timerPreparationRetriesWithBackoffButUnknownAcceptanceKeepsTheOccurrence() async throws {
    let (db, dir, a, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 1_000)
    let timer = WorkspaceSessionTimer(sessionID: a, instruction: "Check", nextFireAt: now)
    try await db.saveSessionTimer(timer, callerID: a)
    let occurrence = try #require(try await db.dueSessionTimers(now: now).first)
    let id = try #require(occurrence.pendingDeliveryID)
    _ = try await db.reserveToolDelivery(sourceID: a, targetID: a, text: timer.instruction, requestID: id, kind: .timer)
    _ = try #require(try await db.claimToolDelivery(id: id, now: now))
    try await db.failToolDeliveryAttempt(id: id, now: now) // offline before input acceptance
    #expect(try await db.toolDelivery(id: id)?.status == "queued")
    #expect(try await db.claimToolDelivery(id: id, now: now.addingTimeInterval(29)) == nil)
    try await db.finishTimerOccurrence(id: timer.id, deliveryID: id, now: now)
    #expect(try await db.sessionTimers().first == occurrence)

    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    _ = try #require(try await reopened.claimToolDelivery(id: id, now: now.addingTimeInterval(30)))
    try await reopened.recoverToolDeliveries() // exit during safe preparation
    #expect(try await reopened.toolDelivery(id: id)?.status == "queued")
    _ = try #require(try await reopened.claimToolDelivery(id: id, now: now.addingTimeInterval(31)))
    try await reopened.markToolDeliveryTransportStarted(id: id)
    try await reopened.failToolDeliveryAttempt(id: id, now: now.addingTimeInterval(31))
    #expect(try await reopened.toolDelivery(id: id)?.status == "uncertain")
    try await reopened.recoverToolDeliveries()
    #expect(try await reopened.claimToolDelivery(id: id, now: now.addingTimeInterval(100)) == nil)
    try await reopened.finishTimerOccurrence(id: timer.id, deliveryID: id, now: now)
    #expect(try await reopened.sessionTimers().first == occurrence)
    try await reopened.setToolDeliveryStatus(id: id, status: "accepted") // confirmed by native reconciliation
    try await reopened.finishTimerOccurrence(id: timer.id, deliveryID: id, now: now)
    #expect(try await reopened.sessionTimers().first?.isPaused == true)
    #expect(try await reopened.sessionTimers().first?.pendingDeliveryID == nil)
  }

  @Test func acceptanceWinsLateFailureAndRevocationCannotEraseAnUncertainSend() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let accepted = UUID().uuidString.lowercased(), submitted = UUID().uuidString.lowercased()
    for id in [accepted, submitted] {
      _ = try await db.reserveToolDelivery(sourceID: a, targetID: b, text: "Check", requestID: id)
      _ = try await db.claimToolDelivery(id: id)
    }
    try await db.setToolDeliveryStatus(id: accepted, status: "accepted")
    try await db.markToolDeliveryTransportStarted(id: submitted)
    try await db.setSessionTools(.init(enabled: []), sessionID: a)
    try await db.failToolDeliveryAttempt(id: accepted)
    try await db.failToolDeliveryAttempt(id: submitted)
    #expect(try await db.toolDelivery(id: accepted)?.status == "accepted")
    #expect(try await db.toolDelivery(id: submitted)?.status == "uncertain")
    #expect(try await db.claimToolDelivery(id: submitted) == nil)
  }

  @Test func revocationAfterClaimPreventsDispatchAndDisabledQueuedWorkIsCancelled() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID().uuidString.lowercased()
    _ = try await db.reserveToolDelivery(sourceID: a, targetID: b, text: "Review", requestID: id)
    _ = try await db.claimToolDelivery(id: id)
    try await db.validateClaimedToolDelivery(id: id)
    let queued = UUID().uuidString.lowercased()
    _ = try await db.reserveToolDelivery(sourceID: a, targetID: b, text: "More", requestID: queued)
    try await db.setSessionTools(.init(enabled: []), sessionID: a)
    await #expect(throws: (any Error).self) { try await db.validateClaimedToolDelivery(id: id) }
    #expect(try await db.claimToolDelivery(id: queued) == nil)
    #expect(try await db.toolDelivery(id: queued)?.status == "cancelled")
  }

  @Test func failedOrInterruptedCreationReleasesItsSlotAndRetryRetainsIdentity() async throws {
    let (db, dir, source, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var settings = try await db.toolSettings(); settings.maximumManagedSessions = 1
    try await db.saveToolSettings(settings)
    try await db.setSessionTools(.init(enabled: [.sessions, .notes]), sessionID: source)
    let firstID = UUID().uuidString, secondID = UUID().uuidString
    let args = ["sessions", "create", "--title", "Fixture"]
    let first = try await db.reserveToolSessionCreation(sourceID: source, requestID: firstID, arguments: args, purpose: "Work", managed: true)
    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    let planned = try await reopened.reserveToolSessionCreation(sourceID: source, requestID: firstID, arguments: args, purpose: "Work", managed: true)
    #expect(planned.objectValue?["target_id"] == first.objectValue?["target_id"])
    try await db.failToolSessionCreation(requestID: firstID)
    _ = try await db.reserveToolSessionCreation(sourceID: source, requestID: secondID, arguments: args, purpose: "Work", managed: true)
    await #expect(throws: WorkspaceToolError.managedLimit(1)) {
      _ = try await db.reserveToolSessionCreation(sourceID: source, requestID: firstID, arguments: args, purpose: "Work", managed: true)
    }
    try await reopened.recoverToolSessionCreations()
    let retry = try await reopened.reserveToolSessionCreation(sourceID: source, requestID: firstID, arguments: args, purpose: "Work", managed: true)
    #expect(retry.objectValue?["status"]?.stringValue == "planned")
    let target = try #require(retry.objectValue?["target_id"]?.stringValue)
    #expect(first.objectValue?["target_id"]?.stringValue == target)
    let created = try await reopened.createLocalACPSession(runtimeKind: .pi, title: "Fixture", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    #expect(created == target)
    #expect(try await reopened.sessionRelationship(target).createdBy == source)
    #expect(try await reopened.sessionTools(target).enabled == [.sessions, .notes])
    try await reopened.completeToolSessionCreation(requestID: firstID, sourceID: source)
    try await reopened.failToolSessionCreation(requestID: firstID)
    try await reopened.recoverToolSessionCreations()
    try await reopened.endCoordination(targetID: target)
    let completed = try await reopened.reserveToolSessionCreation(sourceID: source, requestID: firstID, arguments: args, purpose: "Work", managed: true)
    #expect(completed.objectValue?["status"]?.stringValue == "ready")
    #expect(try await reopened.sessionRelationship(target).coordinatorID == nil)
    #expect(try await reopened.sessionRelationship(target).createdBy == source)
    _ = try await reopened.reserveToolSessionCreation(sourceID: source, requestID: UUID().uuidString, arguments: args, purpose: "Next", managed: true)
  }
}


extension WorkspaceAgentToolTests {
  @Test func concurrentNoteRetryCommitsOnceAndReopenPreservesLaterEdits() async throws {
    let (db, dir, caller, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let note = try await db.createNote(folderID: nil)
    let requestID = UUID().uuidString
    let request = NoteEditingRequest(command: .apply, noteID: note,
      operations: [.appendText("Exactly once", .paragraph)])
    let before = try await db.noteAssetVersions(id: note).count
    let responses = try await withThrowingTaskGroup(of: NoteEditingResponse.self) { group in
      for _ in 0..<12 {
        group.addTask { try await db.applyNoteEdits(request, callerConversationID: caller, requestID: requestID) }
      }
      var values: [NoteEditingResponse] = []
      for try await value in group { values.append(value) }
      return values
    }
    #expect(responses.filter { $0.replayed != true }.count == 1)
    #expect(Set(responses.compactMap(\.revision)).count == 1)
    #expect(try await db.noteAssetVersions(id: note).count == before + 1)
    let userEdit = try await db.applyNoteEdits(.init(command: .apply, noteID: note,
      expectedRevision: responses.first?.revision, operations: [.setTitle("Later user edit")]))
    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    let replay = try await reopened.applyNoteEdits(request, callerConversationID: caller, requestID: requestID)
    #expect(replay.replayed == true && replay.document == nil && replay.title == nil)
    #expect(replay.revision == responses.first?.revision)
    #expect(try await reopened.readNoteForEditing(id: note) == userEdit)
    await #expect(throws: (any Error).self) {
      try await reopened.applyNoteEdits(.init(command: .apply, noteID: note,
        expectedRevision: userEdit.revision, operations: [.setTitle("Changed payload")]),
        callerConversationID: caller, requestID: requestID)
    }
    try await reopened.setSessionTools(.init(enabled: []), sessionID: caller)
    await #expect(throws: WorkspaceToolError.disabled(.notes)) {
      try await reopened.applyNoteEdits(request, callerConversationID: caller, requestID: requestID)
    }
  }

  @Test func noteCreationRetryAndRestoreAcknowledgementsDoNotResurrectOldContents() async throws {
    let (db, dir, caller, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let creationID = UUID().uuidString
    let note = try await db.createNote(folderID: nil, title: "Original", callerConversationID: caller, requestID: creationID)
    #expect(try await db.createNote(folderID: nil, title: "Original", callerConversationID: caller, requestID: creationID) == note)
    #expect(try await db.listAgentNotes(callerID: caller).objectValue?["rows"]?.arrayValue?.count == 1)
    let version = try await #require(db.noteAssetVersions(id: note).first)
    let initialRevision = try await #require(db.readNoteForEditing(id: note).revision)
    let edited = try await db.applyNoteEdits(.init(command: .apply, noteID: note,
      expectedRevision: initialRevision, operations: [.setTitle("Second")]))
    let expected = try #require(edited.revision)
    let restoreID = UUID().uuidString
    let restored = try await db.restoreNoteAssetVersion(noteID: note, versionID: version.id, expectedRevision: expected,
      callerConversationID: caller, requestID: restoreID)
    #expect(restored.title == "Original")
    let latest = try await db.applyNoteEdits(.init(command: .apply, noteID: note,
      expectedRevision: restored.revision, operations: [.setTitle("Third")]))
    // A receipt remains usable after its old version has been pruned.
    try await db.write { connection in try connection.transaction { try connection.toolsExecuteUnlocked("DELETE FROM note_asset_versions WHERE id=?", [version.id])  } }
    let replay = try await db.restoreNoteAssetVersion(noteID: note, versionID: version.id, expectedRevision: expected,
      callerConversationID: caller, requestID: restoreID)
    #expect(replay.replayed == true && replay.document == nil && replay.revision == restored.revision)
    #expect(try await db.readNoteForEditing(id: note) == latest)
    let receipts = try await db.read { connection in try connection.historyRowsUnlocked("SELECT result_json FROM workspace_tool_mutations", values: []) }
    #expect(receipts.allSatisfy { $0.objectValue?["result_json"]?.stringValue?.contains("document") == false })
    await #expect(throws: (any Error).self) {
      try await db.createNote(folderID: nil, title: "Different", callerConversationID: caller, requestID: creationID)
    }
  }

  @Test func failedNoteMutationRollsBackReceiptAndCheckpoints() async throws {
    let (db, dir, caller, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let note = try await db.createNote(folderID: nil)
    let requestID = UUID().uuidString
    let original = try await db.readNoteForEditing(id: note)
    let request = NoteEditingRequest(command: .apply, noteID: note, expectedRevision: original.revision,
      operations: [.appendText("Must roll back", .paragraph), .deleteBlock(id: "missing-block")])
    let versions = try await db.noteAssetVersions(id: note)
    await #expect(throws: (any Error).self) { try await db.applyNoteEdits(request, callerConversationID: caller, requestID: requestID) }
    #expect(try await db.readNoteForEditing(id: note) == original)
    #expect(try await db.noteAssetVersions(id: note).map(\.id) == versions.map(\.id))
    // A failed transaction did not burn the request ID.
    let success = try await db.applyNoteEdits(.init(command: .apply, noteID: note,
      expectedRevision: original.revision, operations: [.setTitle("Recovered")]),
      callerConversationID: caller, requestID: requestID)
    #expect(success.title == "Recovered" && success.replayed != true)
  }

  @Test func timerRetryPreservesPauseRemovalAndLaterSchedule() async throws {
    let (db, dir, caller, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let timer = WorkspaceSessionTimer(sessionID: caller, instruction: "Original", nextFireAt: .distantPast)
    let requestID = UUID().uuidString
    try await db.saveSessionTimer(timer, callerID: caller, requestID: requestID, creating: true)
    try await db.pauseSessionTimer(id: timer.id, paused: true)
    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    try await reopened.saveSessionTimer(timer, callerID: caller, requestID: requestID, creating: true)
    #expect(try await reopened.sessionTimers().first?.isPaused == true)
    var changed = timer; changed.instruction = "Later user instruction"
    try await reopened.saveSessionTimer(changed, callerID: caller)
    let pauseID = UUID().uuidString
    try await reopened.pauseSessionTimer(id: timer.id, paused: true, callerID: caller, requestID: pauseID)
    try await reopened.pauseSessionTimer(id: timer.id, paused: false)
    try await reopened.pauseSessionTimer(id: timer.id, paused: true, callerID: caller, requestID: pauseID)
    #expect(try await reopened.sessionTimers().first == changed)
    let removeID = UUID().uuidString
    try await reopened.removeSessionTimer(id: timer.id, callerID: caller, requestID: removeID)
    try await reopened.removeSessionTimer(id: timer.id, callerID: caller, requestID: removeID)
    try await reopened.saveSessionTimer(timer, callerID: caller, requestID: requestID, creating: true)
    #expect(try await reopened.sessionTimers().isEmpty)
    await #expect(throws: (any Error).self) {
      try await reopened.saveSessionTimer(changed, callerID: caller, requestID: requestID, creating: true)
    }
    try await reopened.setSessionTools(.init(enabled: []), sessionID: caller)
    await #expect(throws: WorkspaceToolError.disabled(.timers)) {
      try await reopened.removeSessionTimer(id: timer.id, callerID: caller, requestID: removeID)
    }
  }

  @Test func timerUpdateRetrySurvivesRemovalAndRechecksCoordination() async throws {
    let (db, dir, caller, target) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await db.beginCoordination(sourceID: caller, targetID: target, purpose: "Manage")
    let timer = WorkspaceSessionTimer(sessionID: target, instruction: "Original", nextFireAt: .distantPast)
    try await db.saveSessionTimer(timer, callerID: caller)
    // CLI updates by ID without requiring the target session argument again.
    var update = timer; update.sessionID = caller; update.instruction = "Updated"
    let requestID = UUID().uuidString
    let saved = try await db.saveSessionTimer(update, callerID: caller, requestID: requestID, creating: false)
    #expect(saved.sessionID == target)
    try await db.removeSessionTimer(id: timer.id)
    #expect(try await db.saveSessionTimer(update, callerID: caller, requestID: requestID, creating: false) == saved)
    #expect(try await db.sessionTimers().isEmpty)
    try await db.endCoordination(targetID: target, sourceID: caller)
    await #expect(throws: (any Error).self) {
      try await db.saveSessionTimer(update, callerID: caller, requestID: requestID, creating: false)
    }
  }

  @Test func timerIdentityCannotBeReusedAfterItsSessionWasDeleted() async throws {
    let (db, dir, caller, target) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let timer = WorkspaceSessionTimer(sessionID: target, instruction: "Original", nextFireAt: .distantPast)
    try await db.saveSessionTimer(timer, callerID: target)
    try await db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("UPDATE dashboard_conversations SET deleted_at=? WHERE id=?", ["2026-09-19T00:00:00Z", target])
     } }
    var moved = timer; moved.sessionID = caller
    await #expect(throws: (any Error).self) { try await db.saveSessionTimer(moved, callerID: caller) }
    await #expect(throws: (any Error).self) {
      try await db.saveSessionTimer(moved, callerID: caller, requestID: UUID().uuidString, creating: true)
    }
    #expect(try await db.sessionTimers().isEmpty)
  }

  @Test func calendarRetryPreservesLaterEditsAndRemovalAndHonorsReadOnly() async throws {
    let (db, dir, caller, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID().uuidString, creationID = UUID().uuidString, updateID = UUID().uuidString
    let start = Date(timeIntervalSince1970: 1_000)
    func save(_ database: WorkspaceDatabase, title: String, creating: Bool, request: String?) async throws -> String {
      try await database.saveAgentCalendar(callerID: caller, id: id, creating: creating, title: title, details: nil,
        startsAt: start, endsAt: nil, allDay: false, requestID: request)
    }
    _ = try await save(db, title: "Original", creating: true, request: creationID)
    _ = try await save(db, title: "Updated", creating: false, request: updateID)
    _ = try await save(db, title: "User change", creating: false, request: nil)
    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    await #expect(try save(reopened, title: "Original", creating: true, request: creationID) == id)
    await #expect(try save(reopened, title: "Updated", creating: false, request: updateID) == id)
    #expect(try await reopened.listAgentCalendar(callerID: caller).objectValue?["rows"]?.arrayValue?.first?.objectValue?["title"]?.stringValue == "User change")
    await #expect(throws: (any Error).self) { try await save(reopened, title: "Different", creating: false, request: updateID) }
    let removeID = UUID().uuidString
    try await reopened.removeAgentCalendar(callerID: caller, id: id, requestID: removeID)
    try await reopened.removeAgentCalendar(callerID: caller, id: id, requestID: removeID)
    _ = try await save(reopened, title: "Original", creating: true, request: creationID)
    #expect(try await reopened.listAgentCalendar(callerID: caller).objectValue?["rows"]?.arrayValue?.isEmpty == true)
    var settings = try await reopened.toolSettings(); settings.calendarAccess = .readOnly
    try await reopened.saveToolSettings(settings)
    await #expect(throws: (any Error).self) { try await save(reopened, title: "Original", creating: true, request: creationID) }
    await #expect(throws: (any Error).self) { try await reopened.removeAgentCalendar(callerID: caller, id: id, requestID: removeID) }
  }
}

extension WorkspaceAgentToolTests {
  @Test(arguments: [false, true], [false, true])
  func creationConfigurationSurvivesReopenAndKeepsResolvedDefaults(remote: Bool, emptyTools: Bool) async throws {
    let (db, dir, source, other) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = try await db.createFolder(name: "Original folder")
    let laterFolder = try await db.createFolder(name: "Later folder")
    try await db.setSessionTools(.init(enabled: [.sessions, .notes]), sessionID: source)
    let requestID = UUID().uuidString
    let args = ["sessions", "create", "--title", "Planned title"]
    let reservation = try await db.reserveToolSessionCreation(sourceID: source, requestID: requestID,
      arguments: args, purpose: "Implement", managed: true)
    let target = try #require(reservation.objectValue?["target_id"]?.stringValue)
    let resolvedTools = WorkspaceSessionTools(enabled: emptyTools ? [] : [.history, .calendar, .executor],
      executorProfiles: emptyTools ? [] : ["saved:profile"])
    let proposed = WorkspaceSessionCreationConfiguration(runtimeKind: .codex, workspaceID: remote ? UUID() : nil,
      folderID: folder, title: "Planned title", model: "original-model", thinking: "high", permission: "native-permission",
      selectionWorkspace: remote ? "remote:fixture" : "local:/workspace/original",
      nativeWorkingDirectory: "/workspace/original", nativeWorkspaceID: "native-workspace", tools: resolvedTools)
    let saved = try await db.saveToolSessionCreationConfiguration(requestID: requestID, sourceID: source, configuration: proposed)
    #expect(saved.tools == resolvedTools)
    await #expect(throws: (any Error).self) {
      try await db.saveToolSessionCreationConfiguration(requestID: requestID, sourceID: other, configuration: proposed)
    }
    try await db.failToolSessionCreation(requestID: requestID)
    var laterDefaults = try await db.toolSettings()
    var executor = ExecutorConfiguration(); executor.defaultProfiles = ["later:profile"]
    laterDefaults.executor = executor
    try await db.saveToolSettings(laterDefaults)
    try await db.setSessionTools(.init(enabled: [.sessions, .calendar]), sessionID: source)
    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    let retry = try await reopened.reserveToolSessionCreation(sourceID: source, requestID: requestID,
      arguments: args, purpose: "Implement", managed: true)
    let json = try #require(retry.objectValue?["configuration_json"]?.stringValue)
    #expect(try JSONDecoder().decode(WorkspaceSessionCreationConfiguration.self, from: Data(json.utf8)) == saved)
    #expect(try await reopened.toolSessionCreationConfiguration(targetID: target) == saved)
    let changed = WorkspaceSessionCreationConfiguration(runtimeKind: .codex, folderID: laterFolder,
      title: "Different", model: "new-model", thinking: "low", nativeWorkingDirectory: "/workspace/later")
    #expect(try await reopened.saveToolSessionCreationConfiguration(requestID: requestID, sourceID: source, configuration: changed) == saved)
    if let workspace = saved.workspaceID {
      _ = try await reopened.createRemoteACPSession(runtimeKind: saved.runtimeKind, remoteWorkspaceID: workspace,
        remoteWorkspaceName: "Fixture remote", title: "Provider default", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    } else {
      _ = try await reopened.createLocalACPSession(runtimeKind: saved.runtimeKind, title: "Provider default",
        ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    }
    let inserted = try await #require(reopened.workspaceOverview().conversations.first { $0.id == target })
    #expect(inserted.title == saved.title && inserted.folderID == folder && inserted.remoteWorkspaceID == saved.workspaceID)
    #expect(try await reopened.sessionTools(target) == saved.tools)
    // Session insertion seals reservation tools; a delayed generic default
    // callback must not override the frozen creation snapshot.
    try await reopened.applyInitialSessionTools(.init(enabled: [.library]), sessionID: target)
    #expect(try await reopened.sessionTools(target) == saved.tools)
    #expect(try await reopened.sessionRelationship(target).createdBy == source)
    let localTitle = try await reopened.read { connection in
      try connection.historyRowsUnlocked("SELECT title FROM desktop_local_acp_sessions WHERE conversation_id=?", values: [target])
        .first?.objectValue?["title"]?.stringValue
    }
    #expect(localTitle == saved.title)
    _ = try await reopened.updateConversationTitleIfCurrent(id: target, expectedTitle: saved.title, title: "User renamed")
    _ = try await reopened.moveConversation(id: target, toFolderID: laterFolder)
    try await reopened.setSessionTools(.init(enabled: [.history]), sessionID: target)
    try await reopened.applyInitialSessionTools(saved.tools, sessionID: target)
    try await reopened.recoverToolSessionCreations()
    _ = try await reopened.reserveToolSessionCreation(sourceID: source, requestID: requestID, arguments: args, purpose: "Implement", managed: true)
    try await reopened.completeToolSessionCreation(requestID: requestID, sourceID: source)
    let final = try await #require(reopened.workspaceOverview().conversations.first { $0.id == target })
    #expect(final.title == "User renamed" && final.folderID == laterFolder)
    #expect(try await reopened.sessionTools(target).enabled == [.history])
  }

  @Test func revocationDuringCreationRollsBackSessionAndInitialConfiguration() async throws {
    let (db, dir, source, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let requestID = UUID().uuidString
    let reservation = try await db.reserveToolSessionCreation(sourceID: source, requestID: requestID,
      arguments: ["sessions", "create"], purpose: "Work", managed: true)
    let target = try #require(reservation.objectValue?["target_id"]?.stringValue)
    _ = try await db.saveToolSessionCreationConfiguration(requestID: requestID, sourceID: source,
      configuration: .init(runtimeKind: .pi, title: "Planned"))
    try await db.setSessionTools(.init(enabled: []), sessionID: source)
    await #expect(throws: WorkspaceToolError.disabled(.sessions)) {
      try await db.createLocalACPSession(runtimeKind: .pi, title: "Default", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    }
    #expect(try await !db.workspaceOverview().conversations.contains { $0.id == target })
    #expect(try await db.sessionRelationship(target).createdBy == nil)
    try await db.setSessionTools(.init(enabled: [.sessions]), sessionID: source)
    _ = try await db.createLocalACPSession(runtimeKind: .pi, title: "Default", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    #expect(try await db.workspaceOverview().conversations.first { $0.id == target }?.title == "Planned")
  }
}

extension WorkspaceAgentToolTests {
  @Test func nativeSubmissionRechecksAuthorityBeforePersistingInput() async throws {
    let (db, dir, caller, target) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let requestID = UUID().uuidString
    _ = try await db.reserveToolDelivery(sourceID: caller, targetID: target, text: "Work", requestID: requestID)
    _ = try #require(try await db.claimToolDelivery(id: requestID))
    try await db.validateClaimedToolDelivery(id: requestID)
    try await db.setSessionTools(.init(enabled: []), sessionID: caller)
    await #expect(throws: (any Error).self) {
      try await db.saveOpenCodeSubmission(conversationID: target, id: "msg_revoked", payload: ["text": "Work"],
        status: "sending", visibleText: "Work", deliveryID: requestID)
    }
    #expect(try await db.openCodeUncertainSubmissions(conversationID: target).isEmpty)
    #expect(try await db.toolDelivery(id: requestID)?.messageID == nil)
  }
}

extension WorkspaceAgentToolTests {
  @Test(arguments: [1.0, 1.25, 90.0, 3_600.125])
  func timerEditorPreservesExactCadenceUnlessExplicitlyChanged(interval: Double) async throws {
    let (db, dir, caller, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let original = WorkspaceSessionTimer(sessionID: caller, instruction: "Original", nextFireAt: .distantFuture,
      intervalSeconds: interval)
    try await db.saveSessionTimer(original, callerID: caller)
    let saved = try await #require(db.sessionTimers(sessionID: caller).first)
    var draft = WorkspaceSessionTimerDraft(saved)
    draft.instruction = "Changed instruction"
    try await db.saveSessionTimer(draft.timer(), callerID: caller)
    #expect(try await db.sessionTimers(sessionID: caller).first?.intervalSeconds == interval)
    draft.nextFireAt = Date(timeIntervalSince1970: 2_000)
    try await db.saveSessionTimer(draft.timer(), callerID: caller)
    #expect(try await db.sessionTimers(sessionID: caller).first?.intervalSeconds == interval)
    draft.intervalSeconds = 75.125
    try await db.saveSessionTimer(draft.timer(), callerID: caller)
    #expect(try await db.sessionTimers(sessionID: caller).first?.intervalSeconds == 75.125)
    draft.repeats = false
    #expect(try draft.timer().intervalSeconds == nil)
    draft.repeats = true
    draft.intervalSeconds = 0.5
    #expect(throws: (any Error).self) { try draft.timer() }
  }
}

extension WorkspaceAgentToolTests {
  @Test func confirmedCreationSelectionIsNotReappliedAfterCoordinationFailure() async throws {
    let (db, dir, source, competing) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let requestID = UUID().uuidString
    let arguments = ["sessions", "create", "--model", "original"]
    let reservation = try await db.reserveToolSessionCreation(sourceID: source, requestID: requestID,
      arguments: arguments, purpose: "Work", managed: true)
    let target = try #require(reservation.objectValue?["target_id"]?.stringValue)
    _ = try await db.saveToolSessionCreationConfiguration(requestID: requestID, sourceID: source,
      configuration: .init(runtimeKind: .pi, title: "Created", model: "original"))
    _ = try await db.createLocalACPSession(runtimeKind: .pi, title: "Created", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    try await db.markToolSessionCreationConfigured(requestID: requestID, sourceID: source)
    try await db.beginCoordination(sourceID: competing, targetID: target, purpose: "User reassigned")
    await #expect(throws: WorkspaceToolError.coordinationConflict(competing)) {
      try await db.completeToolSessionCreation(requestID: requestID, sourceID: source)
    }
    try await db.failToolSessionCreation(requestID: requestID)
    try await db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("UPDATE desktop_local_acp_sessions SET model=? WHERE conversation_id=?", ["later-user-selection", target])
     } }
    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    let retry = try await reopened.reserveToolSessionCreation(sourceID: source, requestID: requestID, arguments: arguments, purpose: "Work", managed: true)
    #expect(retry.objectValue?["configuration_applied"]?.intValue == 1)
    #expect(try await reopened.localACPSession(conversationID: target).model == "later-user-selection")
  }
}


extension WorkspaceAgentToolTests {
  @Test(arguments: [false, true])
  func initialToolsAreAppliedOnceAndRespectUserChanges(userChangesFirst: Bool) async throws {
    let (database, directory, _, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = try await database.createLocalACPSession(runtimeKind: .codex, title: "New chat", ownerDeviceID: UUID())
    if userChangesFirst {
      try await database.setSessionTools(.init(enabled: [.notes]), sessionID: id)
    }
    try await database.applyInitialSessionTools(.init(enabled: []), sessionID: id)
    #expect(try await database.sessionTools(id).enabled == (userChangesFirst ? [.notes] : []))
    let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    try await reopened.applyInitialSessionTools(.init(enabled: [.library]), sessionID: id)
    #expect(try await reopened.sessionTools(id).enabled == (userChangesFirst ? [.notes] : []))
    try await reopened.setSessionTools(.init(enabled: [.history]), sessionID: id)
    try await reopened.applyInitialSessionTools(.init(enabled: []), sessionID: id)
    #expect(try await reopened.sessionTools(id).enabled == [.history])
  }

  @Test func migratingToolDefaultsPreservesExistingSessionsAndEnablesNewSnapshots() async throws {
    let (database, directory, source, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await database.setSessionTools(.init(enabled: [.history]), sessionID: source)
    // Recreate the prior schema shape, retaining the user's stored tool choices.
    try await database.write { connection in
      try connection.executeUnlocked("DROP TRIGGER workspace_session_tool_defaults")
      try connection.executeUnlocked("ALTER TABLE workspace_session_tools DROP COLUMN defaults_applied")
    }
    let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    try await reopened.applyInitialSessionTools(.init(enabled: []), sessionID: source)
    #expect(try await reopened.sessionTools(source).enabled == [.history])
    let new = try await reopened.createLocalACPSession(runtimeKind: .codex, title: "After migration", ownerDeviceID: UUID())
    try await reopened.applyInitialSessionTools(.init(enabled: []), sessionID: new)
    #expect(try await reopened.sessionTools(new).enabled.isEmpty)
  }

  @Test func oldCreationConfigurationDecodesWithoutNewSelectionFields() throws {
    let oldJSON = #"{"runtimeKind":"codex","title":"Existing","tools":{"enabled":[]}}"#
    let configuration = try JSONDecoder().decode(WorkspaceSessionCreationConfiguration.self, from: Data(oldJSON.utf8))
    #expect(configuration.permission == nil && configuration.selectionWorkspace == nil)
    #expect(configuration.tools.enabled.isEmpty)
  }
}
