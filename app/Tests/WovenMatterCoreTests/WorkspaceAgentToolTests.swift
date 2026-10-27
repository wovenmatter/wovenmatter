import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("Agent tools access, coordination and timers")
struct WorkspaceAgentToolTests {


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


}

extension WorkspaceAgentToolTests {
}

extension WorkspaceAgentToolTests {

}

extension WorkspaceAgentToolTests {
}

extension WorkspaceAgentToolTests {
}

extension WorkspaceAgentToolTests {
}

extension WorkspaceAgentToolTests {

}
