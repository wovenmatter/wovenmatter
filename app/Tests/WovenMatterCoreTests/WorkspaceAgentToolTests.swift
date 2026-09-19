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
    try reopened.finishToolSessionCreation(requestID: requestID, status: "ready")
    try reopened.endCoordination(targetID: target, sourceID: a)
    #expect(try reopened.sessionRelationship(target).createdBy == a)
    _ = try reopened.reserveToolSessionCreation(sourceID: a, requestID: UUID().uuidString, arguments: args, purpose: "Next", managed: true)
  }
}
