import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("Agent tools access, coordination and timers")
struct WorkspaceAgentToolTests {

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

  @Test func discoveryPaginationAndRequestIDCanonicalizationAreConsistent() async throws {
    let (db, dir, caller, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let expectedFolders = [
      try await db.createFixtureFolder(name: "Discoverable"),
      try await db.createFixtureFolder(name: "Second folder"),
      try await db.createFixtureFolder(name: "Third folder")
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

  @Test(arguments: [false, true], [false, true])
  func creationConfigurationSurvivesReopenAndKeepsResolvedDefaults(remote: Bool, emptyTools: Bool) async throws {
    let (db, dir, source, other) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let remoteWorkspaceID = remote ? UUID() : nil
    let owner = remoteWorkspaceID.map { "remote:" + $0.uuidString.lowercased() } ?? "device:test"
    let folder = try await db.createFolder(name: "Original folder", location: .init(workspaceID: owner, rootPath: "/workspace/original", managed: false))
    let laterFolder = try await db.createFolder(name: "Later folder", location: .init(workspaceID: owner, rootPath: "/workspace/later", managed: false))
    try await db.setSessionTools(.init(enabled: [.sessions, .notes]), sessionID: source)
    let requestID = UUID().uuidString
    let args = ["sessions", "create", "--title", "Planned title"]
    let reservation = try await db.reserveToolSessionCreation(sourceID: source, requestID: requestID,
      arguments: args, purpose: "Implement", managed: true)
    let target = try #require(reservation.objectValue?["target_id"]?.stringValue)
    let resolvedTools = WorkspaceSessionTools(enabled: emptyTools ? [] : [.history, .calendar, .executor],
      executorProfiles: emptyTools ? [] : ["saved:profile"])
    let proposed = WorkspaceSessionCreationConfiguration(runtimeKind: .codex, workspaceID: remoteWorkspaceID,
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
      _ = try await reopened.createFixtureRemoteACPSession(runtimeKind: saved.runtimeKind, remoteWorkspaceID: workspace,
        remoteWorkspaceName: "Fixture remote", title: "Provider default", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    } else {
      _ = try await reopened.createFixtureLocalACPSession(runtimeKind: saved.runtimeKind, title: "Provider default",
        ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    }
    try await reopened.saveSessionExecutionRoot(id: target, folderID: folder,
      location: .init(workspaceID: owner, rootPath: "/workspace/original", managed: false), defaultPath: "/workspace/default")
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
    #expect(try await reopened.sessionTools(target).enabled == [.history, .goals, .html])
  }

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

  private func fixture() async throws -> (WorkspaceDatabase, URL, String, String) {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    let a = try await db.createFixtureLocalACPSession(runtimeKind: .codex, title: "Coordinator", ownerDeviceID: UUID(), fixtureLocation: .init(workspaceID: "device:test", rootPath: dir.path, managed: false))
    let b = try await db.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Destination", ownerDeviceID: UUID(), fixtureLocation: .init(workspaceID: "device:test", rootPath: dir.path, managed: false))
    return (db, dir, a, b)
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

}

extension WorkspaceAgentToolTests {
}

extension WorkspaceAgentToolTests {

  @Test func revocationDuringCreationRollsBackSessionAndInitialConfiguration() async throws {
    let (db, dir, source, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let requestID = UUID().uuidString
    let reservation = try await db.reserveToolSessionCreation(sourceID: source, requestID: requestID,
      arguments: ["sessions", "create"], purpose: "Work", managed: true)
    let target = try #require(reservation.objectValue?["target_id"]?.stringValue)
    _ = try await db.saveToolSessionCreationConfiguration(requestID: requestID, sourceID: source,
      configuration: .init(runtimeKind: .claudeCode, title: "Planned"))
    try await db.setSessionTools(.init(enabled: []), sessionID: source)
    await #expect(throws: WorkspaceToolError.disabled(.sessions)) {
      try await db.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Default", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    }
    #expect(try await !db.workspaceOverview().conversations.contains { $0.id == target })
    #expect(try await db.sessionRelationship(target).createdBy == nil)
    try await db.setSessionTools(.init(enabled: [.sessions]), sessionID: source)
    _ = try await db.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Default", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    #expect(try await db.workspaceOverview().conversations.first { $0.id == target }?.title == "Planned")
  }
}

extension WorkspaceAgentToolTests {
}

extension WorkspaceAgentToolTests {
}

extension WorkspaceAgentToolTests {
}

extension WorkspaceAgentToolTests {

}
