import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("Agent tools access, coordination and timers")
struct WorkspaceAgentToolTests {
  private func fixture() throws -> (WorkspaceDatabase, URL, String, String) {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = try WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    let a = try db.createLocalACPSession(runtimeKind: .codex, title: "Coordinator", ownerDeviceID: UUID())
    let b = try db.createLocalACPSession(runtimeKind: .pi, title: "Destination", ownerDeviceID: UUID())
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

  @Test func creationCommitGrantsManagedReadOnceAndRetryDoesNotReacquireReleasedSession() throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try db.setSessionTools(.init(enabled: [.sessions]), sessionID: a)
    let request = UUID().uuidString.lowercased()
    let reserved = try db.reserveToolSessionCreation(sourceID: a, requestID: request, arguments: ["sessions", "create"], purpose: "Build", managed: true)
    let target = try #require(reserved.objectValue?["target_id"]?.stringValue)
    _ = try db.createLocalACPSession(runtimeKind: .pi, title: "Created", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    #expect(throws: WorkspaceToolError.accessRequired(target)) { try db.requireTranscriptAccess(sourceID: a, targetID: target) }
    #expect(throws: (any Error).self) { try db.completeToolSessionCreation(requestID: request, sourceID: b) }
    try db.completeToolSessionCreation(requestID: request, sourceID: a)
    try db.requireTranscriptAccess(sourceID: a, targetID: target)
    try db.setCoordinationNotifications(sourceID: a, targetID: target, enabled: false)
    #expect(try !db.sessionRelationship(target).notificationsEnabled)
    #expect(throws: (any Error).self) { try db.setCoordinationNotifications(sourceID: b, targetID: target, enabled: true) }
    try db.endCoordination(targetID: target, sourceID: a)
    try db.completeToolSessionCreation(requestID: request, sourceID: a)
    #expect(try db.sessionRelationship(target).coordinatorID == nil)
    #expect(try db.sessionRelationship(target).createdBy == a)
    #expect(throws: WorkspaceToolError.accessRequired(target)) { try db.requireTranscriptAccess(sourceID: a, targetID: target) }
  }

  @Test func pausingTimerAfterQueuePreventsItsDeferredDelivery() throws {
    let (db, dir, a, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let timer = WorkspaceSessionTimer(sessionID: a, instruction: "Follow up", nextFireAt: .distantPast)
    try db.saveSessionTimer(timer, callerID: a)
    let due = try #require(db.dueSessionTimers().first)
    let id = try #require(due.pendingDeliveryID)
    _ = try db.reserveToolDelivery(sourceID: a, targetID: a, text: due.instruction, requestID: id, kind: .timer)
    try db.pauseSessionTimer(id: timer.id, paused: true)
    #expect(try db.claimToolDelivery(id: id) == nil)
    #expect(try db.toolDelivery(id: id)?.status == "cancelled")
  }

  @Test func defaultsAreSnapshotsAndCalendarModeIsGlobal() throws {
    let (db, dir, a, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var defaults = try db.toolSettings()
    #expect(defaults.maximumManagedSessions == 4 && defaults.maximumRunningSessions == 16)
    #expect(defaults.calendarAccess == .full)
    defaults.enabledByDefault.remove(.history)
    defaults.calendarAccess = .readOnly
    try db.saveToolSettings(defaults)
    let c = try db.createLocalACPSession(runtimeKind: .claudeCode, title: "New", ownerDeviceID: UUID())
    #expect(try db.sessionTools(a).enabled.contains(.history))
    #expect(try !db.sessionTools(c).enabled.contains(.history))
    #expect(throws: (any Error).self) { try db.requireTool(.calendar, sessionID: a, writesCalendar: true) }
    try db.requireTool(.calendar, sessionID: a)
    defaults.maximumRunningSessions = 49
    #expect(throws: (any Error).self) { try db.saveToolSettings(defaults) }
    #expect(try db.toolSettings().maximumRunningSessions == 16)
    let reopened = try WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    #expect(try reopened.sessionTools(c) == db.sessionTools(c))
  }

  @Test func calendarReadOnlyAndNotesRevocationProtectActualWrites() throws {
    let (db, dir, a, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let starts = Date(timeIntervalSince1970: 1_000)
    let id = try db.saveAgentCalendar(callerID: a, creating: true, title: "Review", details: "Feature review",
      startsAt: starts, endsAt: starts.addingTimeInterval(3_600), allDay: false)
    #expect(try db.listAgentCalendar(callerID: a).objectValue?["rows"]?.arrayValue?.count == 1)
    _ = try db.saveAgentCalendar(callerID: a, id: id, creating: false, title: "Updated", details: nil,
      startsAt: starts, endsAt: nil, allDay: true)
    var settings = try db.toolSettings(); settings.calendarAccess = .readOnly
    try db.saveToolSettings(settings)
    #expect(throws: (any Error).self) { try db.removeAgentCalendar(callerID: a, id: id) }
    #expect(throws: (any Error).self) {
      try db.saveAgentCalendar(callerID: a, id: id, creating: false, title: "Forbidden", details: nil,
        startsAt: starts, endsAt: nil, allDay: true)
    }
    #expect(try db.listAgentCalendar(callerID: a).objectValue?["rows"]?.arrayValue?.first?.objectValue?["title"]?.stringValue == "Updated")
    let note = try db.createNote(folderID: nil, callerConversationID: a)
    let revision = try #require(db.readNoteForEditing(id: note, callerConversationID: a).revision)
    try db.setSessionTools(.init(enabled: [.history]), sessionID: a)
    #expect(throws: WorkspaceToolError.disabled(.notes)) { try db.readNoteForEditing(id: note, callerConversationID: a) }
    #expect(throws: WorkspaceToolError.disabled(.notes)) {
      try db.applyNoteEdits(.init(command: .apply, noteID: note, expectedRevision: revision, operations: [.setTitle("Forbidden")]), callerConversationID: a)
    }
    #expect(try db.readNoteForEditing(id: note).title == "Untitled Note")
  }

  @Test func referencesGrantOnlyTheSelectedSessionAndCanBeRevoked() throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try db.setSessionTools(.init(enabled: [.sessions, .notes]), sessionID: a)
    let c = try db.createLocalACPSession(runtimeKind: .pi, title: "Unattached", ownerDeviceID: UUID())
    #expect(throws: WorkspaceToolError.accessRequired(b)) { try db.requireTranscriptAccess(sourceID: a, targetID: b) }
    try db.attachConversationReference(sourceID: a, targetID: b)
    try db.requireTranscriptAccess(sourceID: a, targetID: b)
    _ = try db.queryAgentHistory(.init(command: "conversation", id: b), callerID: a)
    #expect(throws: WorkspaceToolError.accessRequired(c)) { try db.queryAgentHistory(.init(command: "conversation", id: c), callerID: a) }
    #expect(throws: WorkspaceToolError.disabled(.history)) { try db.queryAgentHistory(.init(command: "search", search: "secret"), callerID: a) }
    try db.removeConversationReference(sourceID: a, targetID: b)
    #expect(throws: WorkspaceToolError.accessRequired(b)) { try db.requireTranscriptAccess(sourceID: a, targetID: b) }
  }

  @Test func eventIDsAndRunIDsCannotBypassTranscriptGrants() throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let run = try db.beginLocalACPRun(conversationID: b, content: "Private content")
    try db.recordHistory(.init(id: "event", conversationID: b, runID: run.runID, harness: "pi", kind: "wire.in", payload: "Private event"))
    try db.setSessionTools(.init(enabled: [.sessions]), sessionID: a)
    for query in [WorkspaceHistoryQuery(command: "event", id: "event"), .init(command: "trace", id: run.runID),
                  .init(command: "message", id: run.userMessageID), .init(command: "runs", conversationID: b)] {
      #expect(throws: WorkspaceToolError.accessRequired(b)) { try db.queryAgentHistory(query, callerID: a) }
    }
    try db.attachConversationReference(sourceID: a, targetID: b)
    let result = try db.queryAgentHistory(.init(command: "trace", id: run.runID), callerID: a)
    let trace = result.objectValue?["rows"]?.arrayValue ?? []
    #expect(trace.contains { $0.objectValue?["id"]?.stringValue == "event" })
    // Notes history remains behind Notes even if full conversation history is on.
    try db.setSessionTools(.init(enabled: [.history]), sessionID: a)
    #expect(throws: WorkspaceToolError.disabled(.notes)) { try db.queryAgentHistory(.init(command: "versions", id: "note"), callerID: a) }
  }

  @Test func metadataDoesNotGrantCoordinationButUserApprovalDoes() throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try db.setSessionTools(.init(enabled: [.sessions]), sessionID: a)
    let metadata = try db.queryAgentHistory(.init(command: "conversations"), callerID: a)
    #expect(metadata.objectValue?["rows"]?.arrayValue?.count == 2)
    #expect(throws: WorkspaceToolError.accessRequired(b)) { try db.beginCoordination(sourceID: a, targetID: b, purpose: "Monitor") }
    try db.beginCoordination(sourceID: a, targetID: b, purpose: "Monitor", userApprovedAccess: true)
    try db.requireTranscriptAccess(sourceID: a, targetID: b)
    try db.endCoordination(targetID: b, sourceID: a)
    #expect(throws: WorkspaceToolError.accessRequired(b)) { try db.requireTranscriptAccess(sourceID: a, targetID: b) }
  }

  @Test func originSurvivesManagementAndRetriesDoNotReenableTools() throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try db.setSessionTools(.init(enabled: [.sessions]), sessionID: a)
    try db.recordSessionOrigin(sourceID: a, targetID: b, purpose: "Write report")
    #expect(try db.sessionTools(b).enabled == [.sessions])
    try db.requireTranscriptAccess(sourceID: a, targetID: b)
    try db.endCoordination(targetID: b)
    try db.setSessionTools(.init(enabled: []), sessionID: b)
    try db.recordSessionOrigin(sourceID: a, targetID: b, purpose: "Retry")
    let relationship = try db.sessionRelationship(b)
    #expect(relationship.createdBy == a && relationship.coordinatorID == nil)
    #expect(try db.sessionTools(b).enabled.isEmpty)
    #expect(throws: WorkspaceToolError.accessRequired(b)) { try db.requireTranscriptAccess(sourceID: a, targetID: b) }
  }

  @Test func onlyOneCoordinatorWinsCompetingRequests() async throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = try db.createLocalACPSession(runtimeKind: .pi, title: "Other", ownerDeviceID: UUID())
    let winners = await withTaskGroup(of: String?.self) { group in
      for source in [a, c] { group.addTask {
        do { try db.beginCoordination(sourceID: source, targetID: b, purpose: "Manage"); return source }
        catch { return nil }
      } }
      var values: [String] = []
      for await value in group { if let value { values.append(value) } }
      return values
    }
    #expect(winners.count == 1)
    let winner = try #require(winners.first)
    let loser = winner == a ? c : a
    #expect(try db.sessionRelationship(b).coordinatorID == winner)
    #expect(throws: WorkspaceToolError.coordinationConflict(winner)) { try db.beginCoordination(sourceID: loser, targetID: b, purpose: "Compete") }
    #expect(throws: WorkspaceToolError.coordinationConflict(winner)) { try db.endCoordination(targetID: b, sourceID: loser) }
  }

  @Test func fanoutAndRevocationAreEnforcedTransactionally() throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var settings = try db.toolSettings()
    settings.maximumManagedSessions = 1
    try db.saveToolSettings(settings)
    try db.beginCoordination(sourceID: a, targetID: b, purpose: "Manage")
    try db.beginCoordination(sourceID: a, targetID: b, purpose: "Update intent")
    let c = try db.createLocalACPSession(runtimeKind: .pi, title: "Other", ownerDeviceID: UUID())
    #expect(throws: WorkspaceToolError.managedLimit(1)) { try db.beginCoordination(sourceID: a, targetID: c, purpose: "Over limit") }
    #expect(try db.sessionRelationship(c).coordinatorID == nil)
    #expect(throws: (any Error).self) { try db.beginCoordination(sourceID: b, targetID: a, purpose: "Cycle") }
    try db.setSessionTools(.init(enabled: []), sessionID: a)
    #expect(try db.sessionRelationship(b).coordinatorID == nil)
    #expect(throws: WorkspaceToolError.disabled(.sessions)) { try db.beginCoordination(sourceID: a, targetID: c, purpose: "Disabled") }
  }

  @Test func timerOccurrencesSurviveReopenAndPauseRevokesPendingDelivery() throws {
    let (db, dir, a, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 1_000)
    let timer = WorkspaceSessionTimer(sessionID: a, instruction: "Check progress", nextFireAt: now, intervalSeconds: 60)
    try db.saveSessionTimer(timer, callerID: a)
    #expect(try db.dueSessionTimers(now: now.addingTimeInterval(-1)).isEmpty)
    let claimed = try #require(db.dueSessionTimers(now: now).first)
    let delivery = try #require(claimed.pendingDeliveryID)
    let reopened = try WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    #expect(try reopened.dueSessionTimers(now: now).first?.pendingDeliveryID == delivery)
    #expect(throws: WorkspaceToolError.timerPauseConfirmation) { try db.setSessionTools(.init(enabled: [.sessions]), sessionID: a) }
    #expect(try db.isTimerOccurrenceActive(id: timer.id, deliveryID: delivery))
    try db.setSessionTools(.init(enabled: [.sessions]), sessionID: a, confirmedPausingTimers: true)
    #expect(try !db.isTimerOccurrenceActive(id: timer.id, deliveryID: delivery))
    #expect(try db.sessionTimers(sessionID: a).first?.isPaused == true)
    #expect(throws: WorkspaceToolError.disabled(.timers)) { try db.pauseSessionTimer(id: timer.id, paused: false) }
    try db.setSessionTools(.init(), sessionID: a)
    #expect(try db.dueSessionTimers(now: now).isEmpty)
  }

  @Test func timersCoalesceMissedFiringsAndOneShotCompletesOnce() throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(timeIntervalSince1970: 1_000)
    for interval in [nil, 60] as [TimeInterval?] {
      let timer = WorkspaceSessionTimer(sessionID: a, instruction: "Check", nextFireAt: now, intervalSeconds: interval)
      try db.saveSessionTimer(timer, callerID: a)
      let fire = try #require(db.dueSessionTimers(now: now.addingTimeInterval(3_600)).first(where: { $0.id == timer.id }))
      let delivery = try #require(fire.pendingDeliveryID)
      try db.finishTimerOccurrence(id: timer.id, deliveryID: delivery, now: now.addingTimeInterval(3_600))
      let final = try #require(db.sessionTimers(sessionID: a).first(where: { $0.id == timer.id }))
      #expect(final.isPaused == (interval == nil))
      if interval != nil { #expect(final.nextFireAt == now.addingTimeInterval(3_660)) }
      try db.finishTimerOccurrence(id: timer.id, deliveryID: delivery, now: now.addingTimeInterval(7_200))
      #expect(try db.sessionTimers(sessionID: a).first(where: { $0.id == timer.id }) == final)
      #expect(throws: (any Error).self) { try db.removeSessionTimer(id: timer.id, callerID: b) }
    }
  }

  @Test func folderSearchBroadensOnlyWhenNoLocalMatchExists() throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = try db.createFolder(name: "Project")
    _ = try db.moveConversation(id: a, toFolderID: folder)
    try db.recordHistory(.init(id: "local", conversationID: a, harness: "codex", kind: "wire.in", payload: "needle"))
    try db.recordHistory(.init(id: "outside", conversationID: b, harness: "pi", kind: "wire.in", payload: "needle external-only"))
    let local = try db.queryAgentHistory(.init(command: "search", search: "needle"), callerID: a)
    #expect(local.objectValue?["scope"]?.stringValue == "folder")
    #expect(local.objectValue?["rows"]?.arrayValue?.map { $0.objectValue?["id"]?.stringValue } == ["local"])
    let fallback = try db.queryAgentHistory(.init(command: "search", search: "external-only"), callerID: a)
    #expect(fallback.objectValue?["scope"]?.stringValue == "workspace")
    let global = try db.queryAgentHistory(.init(command: "search", search: "needle"), callerID: a, allWorkspace: true)
    #expect(global.objectValue?["rows"]?.arrayValue?.count == 2)
  }

  @Test func deliveriesClaimOnceAndRecoverWithoutDuplicateDispatch() async throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID().uuidString.lowercased()
    let first = try db.reserveToolDelivery(sourceID: a, targetID: b, text: "Do the work", requestID: id)
    #expect(first.sourceTitle == "Coordinator" && first.targetTitle == "Destination")
    #expect(first.sourceHarness == "codex" && first.targetHarness == "pi")
    _ = try db.reserveToolDelivery(sourceID: a, targetID: b, text: "Do the work", requestID: id)
    let claims = try await withThrowingTaskGroup(of: Bool.self) { group in
      for _ in 0..<5 { group.addTask { try db.claimToolDelivery(id: id) != nil } }
      var count = 0
      for try await claimed in group where claimed { count += 1 }
      return count
    }
    #expect(claims == 1)
    let reopened = try WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    try reopened.recoverToolDeliveries()
    #expect(try reopened.sessionDeliveries(sessionID: a).first?.status == "uncertain")
    #expect(try reopened.claimToolDelivery(id: id) == nil)
    #expect(throws: (any Error).self) { try db.reserveToolDelivery(sourceID: b, targetID: a, text: "Do the work", requestID: id) }
  }

  @Test func revocationAfterClaimPreventsDispatchAndDisabledQueuedWorkIsCancelled() throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID().uuidString.lowercased()
    _ = try db.reserveToolDelivery(sourceID: a, targetID: b, text: "Review", requestID: id)
    _ = try db.claimToolDelivery(id: id)
    try db.validateClaimedToolDelivery(id: id)
    let queued = UUID().uuidString.lowercased()
    _ = try db.reserveToolDelivery(sourceID: a, targetID: b, text: "More", requestID: queued)
    try db.setSessionTools(.init(enabled: []), sessionID: a)
    #expect(throws: (any Error).self) { try db.validateClaimedToolDelivery(id: id) }
    #expect(try db.claimToolDelivery(id: queued) == nil)
    #expect(try db.toolDelivery(id: queued)?.status == "cancelled")
  }

  @Test func failedOrInterruptedCreationReleasesItsSlotAndRetryRetainsIdentity() throws {
    let (db, dir, source, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var settings = try db.toolSettings(); settings.maximumManagedSessions = 1
    try db.saveToolSettings(settings)
    let firstID = UUID().uuidString, secondID = UUID().uuidString
    let args = ["sessions", "create", "--title", "Fixture"]
    let first = try db.reserveToolSessionCreation(sourceID: source, requestID: firstID, arguments: args, purpose: "Work", managed: true)
    try db.failToolSessionCreation(requestID: firstID)
    _ = try db.reserveToolSessionCreation(sourceID: source, requestID: secondID, arguments: args, purpose: "Work", managed: true)
    #expect(throws: WorkspaceToolError.managedLimit(1)) {
      _ = try db.reserveToolSessionCreation(sourceID: source, requestID: firstID, arguments: args, purpose: "Work", managed: true)
    }
    let reopened = try WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    try reopened.recoverToolSessionCreations()
    let retry = try reopened.reserveToolSessionCreation(sourceID: source, requestID: firstID, arguments: args, purpose: "Work", managed: true)
    #expect(retry.objectValue?["status"]?.stringValue == "planned")
    let target = try #require(retry.objectValue?["target_id"]?.stringValue)
    #expect(first.objectValue?["target_id"]?.stringValue == target)
    _ = try reopened.createLocalACPSession(runtimeKind: .pi, title: "Fixture", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    try reopened.completeToolSessionCreation(requestID: firstID, sourceID: source)
    try reopened.failToolSessionCreation(requestID: firstID)
    try reopened.recoverToolSessionCreations()
    try reopened.endCoordination(targetID: target)
    let completed = try reopened.reserveToolSessionCreation(sourceID: source, requestID: firstID, arguments: args, purpose: "Work", managed: true)
    #expect(completed.objectValue?["status"]?.stringValue == "ready")
    #expect(try reopened.sessionRelationship(target).coordinatorID == nil)
  }

  @Test func creationReservationsSurviveReopenAndCountTowardFanout() throws {
    let (db, dir, a, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var settings = try db.toolSettings(); settings.maximumManagedSessions = 1
    try db.saveToolSettings(settings)
    try db.setSessionTools(.init(enabled: [.sessions, .notes]), sessionID: a)
    let requestID = UUID().uuidString.lowercased()
    let args = ["sessions", "create", "--title", "Research"]
    let reservation = try db.reserveToolSessionCreation(sourceID: a, requestID: requestID, arguments: args, purpose: "Research", managed: true)
    let target = try #require(reservation.objectValue?["target_id"]?.stringValue)
    #expect(throws: WorkspaceToolError.managedLimit(1)) {
      try db.reserveToolSessionCreation(sourceID: a, requestID: UUID().uuidString, arguments: args, purpose: "Extra", managed: true)
    }
    let reopened = try WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    let retry = try reopened.reserveToolSessionCreation(sourceID: a, requestID: requestID, arguments: args, purpose: "Research", managed: true)
    #expect(retry.objectValue?["target_id"]?.stringValue == target)
    let created = try reopened.createLocalACPSession(runtimeKind: .pi, title: "Research", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    #expect(created == target)
    #expect(try reopened.sessionRelationship(target).createdBy == a)
    #expect(try reopened.sessionTools(target).enabled == [.sessions, .notes])
    try reopened.beginCoordination(sourceID: a, targetID: target, purpose: "Research", userApprovedAccess: true)
    try reopened.completeToolSessionCreation(requestID: requestID, sourceID: a)
    try reopened.endCoordination(targetID: target, sourceID: a)
    #expect(try reopened.sessionRelationship(target).createdBy == a)
    _ = try reopened.reserveToolSessionCreation(sourceID: a, requestID: UUID().uuidString, arguments: args, purpose: "Next", managed: true)
  }
}


extension WorkspaceAgentToolTests {
  @Test func concurrentNoteRetryCommitsOnceAndReopenPreservesLaterEdits() async throws {
    let (db, dir, caller, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let note = try db.createNote(folderID: nil)
    let requestID = UUID().uuidString
    let request = NoteEditingRequest(command: .apply, noteID: note,
      operations: [.appendText("Exactly once", .paragraph)])
    let before = try db.noteAssetVersions(id: note).count
    let responses = try await withThrowingTaskGroup(of: NoteEditingResponse.self) { group in
      for _ in 0..<12 {
        group.addTask { try db.applyNoteEdits(request, callerConversationID: caller, requestID: requestID) }
      }
      var values: [NoteEditingResponse] = []
      for try await value in group { values.append(value) }
      return values
    }
    #expect(responses.filter { $0.replayed != true }.count == 1)
    #expect(Set(responses.compactMap(\.revision)).count == 1)
    #expect(try db.noteAssetVersions(id: note).count == before + 1)
    let userEdit = try db.applyNoteEdits(.init(command: .apply, noteID: note, operations: [.setTitle("Later user edit")]))
    let reopened = try WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    let replay = try reopened.applyNoteEdits(request, callerConversationID: caller, requestID: requestID)
    #expect(replay.replayed == true && replay.document == nil && replay.title == nil)
    #expect(replay.revision == responses.first?.revision)
    #expect(try reopened.readNoteForEditing(id: note) == userEdit)
    #expect(throws: (any Error).self) {
      try reopened.applyNoteEdits(.init(command: .apply, noteID: note, operations: [.setTitle("Changed payload")]),
        callerConversationID: caller, requestID: requestID)
    }
    try reopened.setSessionTools(.init(enabled: []), sessionID: caller)
    #expect(throws: WorkspaceToolError.disabled(.notes)) {
      try reopened.applyNoteEdits(request, callerConversationID: caller, requestID: requestID)
    }
  }

  @Test func noteCreationRetryAndRestoreAcknowledgementsDoNotResurrectOldContents() throws {
    let (db, dir, caller, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let creationID = UUID().uuidString
    let note = try db.createNote(folderID: nil, title: "Original", callerConversationID: caller, requestID: creationID)
    #expect(try db.createNote(folderID: nil, title: "Original", callerConversationID: caller, requestID: creationID) == note)
    #expect(try db.listAgentNotes(callerID: caller).objectValue?["rows"]?.arrayValue?.count == 1)
    let version = try #require(db.noteAssetVersions(id: note).first)
    let edited = try db.applyNoteEdits(.init(command: .apply, noteID: note, operations: [.setTitle("Second")]))
    let expected = try #require(edited.revision)
    let restoreID = UUID().uuidString
    let restored = try db.restoreNoteAssetVersion(noteID: note, versionID: version.id, expectedRevision: expected,
      callerConversationID: caller, requestID: restoreID)
    #expect(restored.title == "Original")
    let latest = try db.applyNoteEdits(.init(command: .apply, noteID: note, operations: [.setTitle("Third")]))
    // A receipt remains usable after its old version has been pruned.
    try db.transaction { try db.toolsExecuteUnlocked("DELETE FROM note_asset_versions WHERE id=?", [version.id]) }
    let replay = try db.restoreNoteAssetVersion(noteID: note, versionID: version.id, expectedRevision: expected,
      callerConversationID: caller, requestID: restoreID)
    #expect(replay.replayed == true && replay.document == nil && replay.revision == restored.revision)
    #expect(try db.readNoteForEditing(id: note) == latest)
    let receipts = try db.withLock { try db.historyRowsUnlocked("SELECT result_json FROM workspace_tool_mutations", values: []) }
    #expect(receipts.allSatisfy { $0.objectValue?["result_json"]?.stringValue?.contains("document") == false })
    #expect(throws: (any Error).self) {
      try db.createNote(folderID: nil, title: "Different", callerConversationID: caller, requestID: creationID)
    }
  }

  @Test func failedNoteMutationRollsBackReceiptAndCheckpoints() throws {
    let (db, dir, caller, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let note = try db.createNote(folderID: nil)
    let requestID = UUID().uuidString
    let request = NoteEditingRequest(command: .apply, noteID: note,
      operations: [.appendText("Must roll back", .paragraph), .deleteBlock(id: "missing-block")])
    let original = try db.readNoteForEditing(id: note)
    let versions = try db.noteAssetVersions(id: note)
    #expect(throws: (any Error).self) { try db.applyNoteEdits(request, callerConversationID: caller, requestID: requestID) }
    #expect(try db.readNoteForEditing(id: note) == original)
    #expect(try db.noteAssetVersions(id: note).map(\.id) == versions.map(\.id))
    // A failed transaction did not burn the request ID.
    let success = try db.applyNoteEdits(.init(command: .apply, noteID: note, operations: [.setTitle("Recovered")]),
      callerConversationID: caller, requestID: requestID)
    #expect(success.title == "Recovered" && success.replayed != true)
  }

  @Test func timerRetryPreservesPauseRemovalAndLaterSchedule() throws {
    let (db, dir, caller, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let timer = WorkspaceSessionTimer(sessionID: caller, instruction: "Original", nextFireAt: .distantPast)
    let requestID = UUID().uuidString
    try db.saveSessionTimer(timer, callerID: caller, requestID: requestID, creating: true)
    try db.pauseSessionTimer(id: timer.id, paused: true)
    let reopened = try WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    try reopened.saveSessionTimer(timer, callerID: caller, requestID: requestID, creating: true)
    #expect(try reopened.sessionTimers().first?.isPaused == true)
    var changed = timer; changed.instruction = "Later user instruction"
    try reopened.saveSessionTimer(changed, callerID: caller)
    let pauseID = UUID().uuidString
    try reopened.pauseSessionTimer(id: timer.id, paused: true, callerID: caller, requestID: pauseID)
    try reopened.pauseSessionTimer(id: timer.id, paused: false)
    try reopened.pauseSessionTimer(id: timer.id, paused: true, callerID: caller, requestID: pauseID)
    #expect(try reopened.sessionTimers().first == changed)
    let removeID = UUID().uuidString
    try reopened.removeSessionTimer(id: timer.id, callerID: caller, requestID: removeID)
    try reopened.removeSessionTimer(id: timer.id, callerID: caller, requestID: removeID)
    try reopened.saveSessionTimer(timer, callerID: caller, requestID: requestID, creating: true)
    #expect(try reopened.sessionTimers().isEmpty)
    #expect(throws: (any Error).self) {
      try reopened.saveSessionTimer(changed, callerID: caller, requestID: requestID, creating: true)
    }
    try reopened.setSessionTools(.init(enabled: []), sessionID: caller)
    #expect(throws: WorkspaceToolError.disabled(.timers)) {
      try reopened.removeSessionTimer(id: timer.id, callerID: caller, requestID: removeID)
    }
  }

  @Test func timerUpdateRetrySurvivesRemovalAndRechecksCoordination() throws {
    let (db, dir, caller, target) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try db.beginCoordination(sourceID: caller, targetID: target, purpose: "Manage")
    let timer = WorkspaceSessionTimer(sessionID: target, instruction: "Original", nextFireAt: .distantPast)
    try db.saveSessionTimer(timer, callerID: caller)
    // CLI updates by ID without requiring the target session argument again.
    var update = timer; update.sessionID = caller; update.instruction = "Updated"
    let requestID = UUID().uuidString
    let saved = try db.saveSessionTimer(update, callerID: caller, requestID: requestID, creating: false)
    #expect(saved.sessionID == target)
    try db.removeSessionTimer(id: timer.id)
    #expect(try db.saveSessionTimer(update, callerID: caller, requestID: requestID, creating: false) == saved)
    #expect(try db.sessionTimers().isEmpty)
    try db.endCoordination(targetID: target, sourceID: caller)
    #expect(throws: (any Error).self) {
      try db.saveSessionTimer(update, callerID: caller, requestID: requestID, creating: false)
    }
  }

  @Test func timerIdentityCannotBeReusedAfterItsSessionWasDeleted() throws {
    let (db, dir, caller, target) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let timer = WorkspaceSessionTimer(sessionID: target, instruction: "Original", nextFireAt: .distantPast)
    try db.saveSessionTimer(timer, callerID: target)
    try db.transaction {
      try db.toolsExecuteUnlocked("UPDATE dashboard_conversations SET deleted_at=? WHERE id=?", ["2026-09-19T00:00:00Z", target])
    }
    var moved = timer; moved.sessionID = caller
    #expect(throws: (any Error).self) { try db.saveSessionTimer(moved, callerID: caller) }
    #expect(throws: (any Error).self) {
      try db.saveSessionTimer(moved, callerID: caller, requestID: UUID().uuidString, creating: true)
    }
    #expect(try db.sessionTimers().isEmpty)
  }

  @Test func calendarRetryPreservesLaterEditsAndRemovalAndHonorsReadOnly() throws {
    let (db, dir, caller, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID().uuidString, creationID = UUID().uuidString, updateID = UUID().uuidString
    let start = Date(timeIntervalSince1970: 1_000)
    func save(_ database: WorkspaceDatabase, title: String, creating: Bool, request: String?) throws -> String {
      try database.saveAgentCalendar(callerID: caller, id: id, creating: creating, title: title, details: nil,
        startsAt: start, endsAt: nil, allDay: false, requestID: request)
    }
    _ = try save(db, title: "Original", creating: true, request: creationID)
    _ = try save(db, title: "Updated", creating: false, request: updateID)
    _ = try save(db, title: "User change", creating: false, request: nil)
    let reopened = try WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    #expect(try save(reopened, title: "Original", creating: true, request: creationID) == id)
    #expect(try save(reopened, title: "Updated", creating: false, request: updateID) == id)
    #expect(try reopened.listAgentCalendar(callerID: caller).objectValue?["rows"]?.arrayValue?.first?.objectValue?["title"]?.stringValue == "User change")
    #expect(throws: (any Error).self) { try save(reopened, title: "Different", creating: false, request: updateID) }
    let removeID = UUID().uuidString
    try reopened.removeAgentCalendar(callerID: caller, id: id, requestID: removeID)
    try reopened.removeAgentCalendar(callerID: caller, id: id, requestID: removeID)
    _ = try save(reopened, title: "Original", creating: true, request: creationID)
    #expect(try reopened.listAgentCalendar(callerID: caller).objectValue?["rows"]?.arrayValue?.isEmpty == true)
    var settings = try reopened.toolSettings(); settings.calendarAccess = .readOnly
    try reopened.saveToolSettings(settings)
    #expect(throws: (any Error).self) { try save(reopened, title: "Original", creating: true, request: creationID) }
    #expect(throws: (any Error).self) { try reopened.removeAgentCalendar(callerID: caller, id: id, requestID: removeID) }
  }
}

extension WorkspaceAgentToolTests {
  @Test(arguments: [false, true])
  func creationConfigurationSurvivesReopenAndKeepsOriginalInheritance(remote: Bool) throws {
    let (db, dir, source, other) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = try db.createFolder(name: "Original folder")
    let laterFolder = try db.createFolder(name: "Later folder")
    try db.setSessionTools(.init(enabled: [.sessions, .notes]), sessionID: source)
    let requestID = UUID().uuidString
    let args = ["sessions", "create", "--title", "Planned title"]
    let reservation = try db.reserveToolSessionCreation(sourceID: source, requestID: requestID,
      arguments: args, purpose: "Implement", managed: true)
    let target = try #require(reservation.objectValue?["target_id"]?.stringValue)
    let proposed = WorkspaceSessionCreationConfiguration(runtimeKind: .pi, workspaceID: remote ? UUID() : nil,
      folderID: folder, title: "Planned title", model: "original-model", thinking: "high",
      nativeWorkingDirectory: "/workspace/original")
    let saved = try db.saveToolSessionCreationConfiguration(requestID: requestID, sourceID: source, configuration: proposed)
    #expect(saved.tools.enabled == [.sessions, .notes])
    #expect(throws: (any Error).self) {
      try db.saveToolSessionCreationConfiguration(requestID: requestID, sourceID: other, configuration: proposed)
    }
    try db.failToolSessionCreation(requestID: requestID)
    try db.setSessionTools(.init(enabled: [.sessions, .calendar]), sessionID: source)
    let reopened = try WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    let retry = try reopened.reserveToolSessionCreation(sourceID: source, requestID: requestID,
      arguments: args, purpose: "Implement", managed: true)
    let json = try #require(retry.objectValue?["configuration_json"]?.stringValue)
    #expect(try JSONDecoder().decode(WorkspaceSessionCreationConfiguration.self, from: Data(json.utf8)) == saved)
    let changed = WorkspaceSessionCreationConfiguration(runtimeKind: .codex, folderID: laterFolder,
      title: "Different", model: "new-model", thinking: "low", nativeWorkingDirectory: "/workspace/later")
    #expect(try reopened.saveToolSessionCreationConfiguration(requestID: requestID, sourceID: source, configuration: changed) == saved)
    if let workspace = saved.workspaceID {
      _ = try reopened.createRemoteACPSession(runtimeKind: saved.runtimeKind, remoteWorkspaceID: workspace,
        remoteWorkspaceName: "Fixture remote", title: "Provider default", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    } else {
      _ = try reopened.createLocalACPSession(runtimeKind: saved.runtimeKind, title: "Provider default",
        ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    }
    let inserted = try #require(reopened.workspaceOverview().conversations.first { $0.id == target })
    #expect(inserted.title == saved.title && inserted.folderID == folder && inserted.remoteWorkspaceID == saved.workspaceID)
    #expect(try reopened.sessionTools(target) == saved.tools)
    #expect(try reopened.sessionRelationship(target).createdBy == source)
    let localTitle = try reopened.withLock {
      try reopened.historyRowsUnlocked("SELECT title FROM desktop_local_acp_sessions WHERE conversation_id=?", values: [target])
        .first?.objectValue?["title"]?.stringValue
    }
    #expect(localTitle == saved.title)
    _ = try reopened.updateConversationTitleIfCurrent(id: target, expectedTitle: saved.title, title: "User renamed")
    _ = try reopened.moveConversation(id: target, toFolderID: laterFolder)
    try reopened.setSessionTools(.init(enabled: [.history]), sessionID: target)
    try reopened.recoverToolSessionCreations()
    _ = try reopened.reserveToolSessionCreation(sourceID: source, requestID: requestID, arguments: args, purpose: "Implement", managed: true)
    try reopened.completeToolSessionCreation(requestID: requestID, sourceID: source)
    let final = try #require(reopened.workspaceOverview().conversations.first { $0.id == target })
    #expect(final.title == "User renamed" && final.folderID == laterFolder)
    #expect(try reopened.sessionTools(target).enabled == [.history])
  }

  @Test func revocationDuringCreationRollsBackSessionAndInitialConfiguration() throws {
    let (db, dir, source, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let requestID = UUID().uuidString
    let reservation = try db.reserveToolSessionCreation(sourceID: source, requestID: requestID,
      arguments: ["sessions", "create"], purpose: "Work", managed: true)
    let target = try #require(reservation.objectValue?["target_id"]?.stringValue)
    _ = try db.saveToolSessionCreationConfiguration(requestID: requestID, sourceID: source,
      configuration: .init(runtimeKind: .pi, title: "Planned"))
    try db.setSessionTools(.init(enabled: []), sessionID: source)
    #expect(throws: WorkspaceToolError.disabled(.sessions)) {
      try db.createLocalACPSession(runtimeKind: .pi, title: "Default", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    }
    #expect(try !db.workspaceOverview().conversations.contains { $0.id == target })
    #expect(try db.sessionRelationship(target).createdBy == nil)
    try db.setSessionTools(.init(enabled: [.sessions]), sessionID: source)
    _ = try db.createLocalACPSession(runtimeKind: .pi, title: "Default", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    #expect(try db.workspaceOverview().conversations.first { $0.id == target }?.title == "Planned")
  }
}

extension WorkspaceAgentToolTests {
  @Test func nativeSubmissionRechecksAuthorityBeforePersistingInput() throws {
    let (db, dir, caller, target) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let requestID = UUID().uuidString
    _ = try db.reserveToolDelivery(sourceID: caller, targetID: target, text: "Work", requestID: requestID)
    _ = try #require(try db.claimToolDelivery(id: requestID))
    try db.validateClaimedToolDelivery(id: requestID)
    try db.setSessionTools(.init(enabled: []), sessionID: caller)
    #expect(throws: (any Error).self) {
      try db.saveOpenCodeSubmission(conversationID: target, id: "msg_revoked", payload: ["text": "Work"],
        status: "sending", visibleText: "Work", deliveryID: requestID)
    }
    #expect(try db.openCodeUncertainSubmissions(conversationID: target).isEmpty)
    #expect(try db.toolDelivery(id: requestID)?.messageID == nil)
  }
}

extension WorkspaceAgentToolTests {
  @Test(arguments: [1.0, 1.25, 90.0, 3_600.125])
  func timerEditorPreservesExactCadenceUnlessExplicitlyChanged(interval: Double) throws {
    let (db, dir, caller, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let original = WorkspaceSessionTimer(sessionID: caller, instruction: "Original", nextFireAt: .distantFuture,
      intervalSeconds: interval)
    try db.saveSessionTimer(original, callerID: caller)
    let saved = try #require(db.sessionTimers(sessionID: caller).first)
    var draft = WorkspaceSessionTimerDraft(saved)
    draft.instruction = "Changed instruction"
    try db.saveSessionTimer(draft.timer(), callerID: caller)
    #expect(try db.sessionTimers(sessionID: caller).first?.intervalSeconds == interval)
    draft.nextFireAt = Date(timeIntervalSince1970: 2_000)
    try db.saveSessionTimer(draft.timer(), callerID: caller)
    #expect(try db.sessionTimers(sessionID: caller).first?.intervalSeconds == interval)
    draft.intervalSeconds = 75.125
    try db.saveSessionTimer(draft.timer(), callerID: caller)
    #expect(try db.sessionTimers(sessionID: caller).first?.intervalSeconds == 75.125)
    draft.repeats = false
    #expect(try draft.timer().intervalSeconds == nil)
    draft.repeats = true
    draft.intervalSeconds = 0.5
    #expect(throws: (any Error).self) { try draft.timer() }
  }
}

extension WorkspaceAgentToolTests {
  @Test func confirmedCreationSelectionIsNotReappliedAfterCoordinationFailure() throws {
    let (db, dir, source, competing) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let requestID = UUID().uuidString
    let arguments = ["sessions", "create", "--model", "original"]
    let reservation = try db.reserveToolSessionCreation(sourceID: source, requestID: requestID,
      arguments: arguments, purpose: "Work", managed: true)
    let target = try #require(reservation.objectValue?["target_id"]?.stringValue)
    _ = try db.saveToolSessionCreationConfiguration(requestID: requestID, sourceID: source,
      configuration: .init(runtimeKind: .pi, title: "Created", model: "original"))
    _ = try db.createLocalACPSession(runtimeKind: .pi, title: "Created", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: target))
    try db.markToolSessionCreationConfigured(requestID: requestID, sourceID: source)
    try db.beginCoordination(sourceID: competing, targetID: target, purpose: "User reassigned")
    #expect(throws: WorkspaceToolError.coordinationConflict(competing)) {
      try db.completeToolSessionCreation(requestID: requestID, sourceID: source)
    }
    try db.failToolSessionCreation(requestID: requestID)
    try db.transaction {
      try db.toolsExecuteUnlocked("UPDATE desktop_local_acp_sessions SET model=? WHERE conversation_id=?", ["later-user-selection", target])
    }
    let reopened = try WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    let retry = try reopened.reserveToolSessionCreation(sourceID: source, requestID: requestID, arguments: arguments, purpose: "Work", managed: true)
    #expect(retry.objectValue?["configuration_applied"]?.intValue == 1)
    #expect(try reopened.localACPSession(conversationID: target).model == "later-user-selection")
  }
}
