import Foundation
import Testing
import WovenMatterCompanion
@testable import CompanionClient

@Suite("Mobile MCP durable boundaries")
struct MobileToolBoundaryTests {
  @Test func savedCancellationGrantsFollowRenamesWithoutEnablingComputerInput() {
    let available = WovenMCPCatalog.tools.map(\.name)
    let permitted = MobileToolSupport.permittedMCPTools(selection: ["woven_computer_cancel", "woven_browser_cancel"], available: available)
    #expect(permitted == ["woven_browser_use_cancel", "woven_computer_use_cancel"])
    #expect(!permitted.contains("woven_computer_use"))
  }
  @Test func computerUseIsOptInButScopedCancellationSurvivesDisable() throws {
    let context = MobileToolContext(sessionID: "caller", workspaceID: "phone")
    #expect(context.enabled.contains(.browser) && !context.enabled.contains(.computer))
    #expect(throws: (any Error).self) {
      try context.authorize(WovenMatterToolCommand(["computer", "call", "--json", "{\"action\":\"screenshot\"}"]))
    }
    try context.authorize(WovenMatterToolCommand(["computer", "cancel", "--id", "all"]))
  }
  private func fixture() throws -> (MobileStore, URL, MobileToolContext) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wm-tool-boundary-" + UUID().uuidString)
    return (try MobileStore(file: root.appendingPathComponent("library.json")), root,
      .init(sessionID: "parent", workspaceID: "phone-workspace"))
  }
  private func call(_ store: MobileStore, _ arguments: [String], context: MobileToolContext,
    id: String = UUID().uuidString.lowercased()) async -> WovenMatterToolResponse {
    await store.executeLocalTool(.init(arguments: arguments, requestID: id), context: context)
  }

  @Test func concurrentExecutorRetriesAcquireExactlyOneStart() async throws {
    let (store, root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased()
    _ = try await store.createExecutorJob(id: id, sessionID: "parent", code: "await tools.write_file({path:'one',content:'value'})")
    let starts = try await withThrowingTaskGroup(of: Bool.self) { group in
      for _ in 0..<12 { group.addTask { try await store.claimExecutorJobStart(id: id, sessionID: "parent") } }
      var count = 0
      for try await claimed in group where claimed { count += 1 }
      return count
    }
    #expect(starts == 1)
    let reopened = try MobileStore(file: root.appendingPathComponent("library.json"))
    #expect(try await reopened.claimExecutorJobStart(id: id, sessionID: "parent") == false)
    try await reopened.interruptExecutorJobs()
    #expect(try await reopened.executorJob(id: id, sessionID: "parent").state == "interrupted")
    #expect(try await reopened.claimExecutorJobStart(id: id, sessionID: "parent") == false)
  }

  @Test(arguments: ["pause", "remove", "update"])
  func obsoleteTimerClaimCannotEnterAgentInbox(action: String) async throws {
    let (store, root, scope) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased(), now = try MobileToolSupport.date("2026-10-10T12:01:00Z")
    #expect(await call(store, ["timers", "create", "--text", "Old work", "--at", "2026-10-10T12:00:00Z"], context: scope, id: id).success)
    let claim = try #require(try await store.claimDueToolTimers(now: now).first?.pendingFireID)
    var arguments = ["timers", action, id]
    if action == "update" { arguments += ["--text", "New work", "--at", "2026-10-11T12:00:00Z"] }
    #expect(await call(store, arguments, context: scope).success)
    let reopened = try MobileStore(file: root.appendingPathComponent("library.json"))
    #expect(try await reopened.enqueueClaimedToolTimer(id: id, fireID: claim, now: now) == nil)
    #expect(await reopened.toolSubmissions().isEmpty)
  }

  @Test func timerDeliveryAndMissedOccurrenceAdvanceCommitTogether() async throws {
    let (store, root, scope) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased(), now = try MobileToolSupport.date("2026-10-10T12:05:01Z")
    #expect(await call(store, ["timers", "create", "--text", "Check once", "--at", "2026-10-10T12:00:00Z", "--every", "60"], context: scope, id: id).success)
    let claim = try #require(try await store.claimDueToolTimers(now: now).first?.pendingFireID)
    #expect(try await store.enqueueClaimedToolTimer(id: id, fireID: claim, now: now)?.id == claim)
    let reopened = try MobileStore(file: root.appendingPathComponent("library.json"))
    #expect(await reopened.toolSubmissions().map(\.id) == [claim])
    #expect(try await reopened.claimDueToolTimers(now: now).isEmpty)
    #expect(try await reopened.enqueueClaimedToolTimer(id: id, fireID: claim, now: now) == nil)
    #expect(await reopened.toolSubmissions().count == 1)
    let next = try #require(try await reopened.claimDueToolTimers(now: now.addingTimeInterval(60)).first?.pendingFireID)
    #expect(next != claim)
  }

  @Test(arguments: [false, true])
  func managedRunCompletionAndNotificationSurviveTogether(toolSubmitted: Bool) async throws {
    let (store, root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let runID = UUID().uuidString.lowercased()
    _ = try await store.coordinateLocalSessions(callerID: "parent", targetID: "child", localExecutionIDs: ["parent", "child"],
      purpose: "Delegated work", notifications: true, requestID: UUID().uuidString.lowercased())
    if toolSubmitted { _ = try await store.enqueueToolSubmission(id: runID, sessionID: "child", text: "Do work") }
    try await store.completeLocalToolRun(sessionID: "child", requestID: runID, status: "completed")
    let reopened = try MobileStore(file: root.appendingPathComponent("library.json"))
    if toolSubmitted { #expect(await reopened.toolSubmission(requestID: runID)?.state == "completed") }
    let first = await reopened.toolSubmissions().filter { $0.sessionID == "parent" }
    #expect(first.count == 1)
    #expect(first.first?.state == "queued")
    #expect(first.first?.text.contains("completed") == true)
    try await reopened.completeLocalToolRun(sessionID: "child", requestID: runID, status: "completed")
    #expect(await reopened.toolSubmissions().filter { $0.sessionID == "parent" } == first)
  }

  @Test(arguments: ["link", "apply", "cached-linked"])
  func linkedDatabaseMutationsNeverBecomeUnsyncableLocalWrites(operation: String) async throws {
    let (store, root, scope) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let link = DatabaseArtifactLink(sourceID: "mac", databaseID: "source", relativePath: "data.sqlite")
    let document = NoteDocument(kind: .html, html: "<p>Saved</p>", databaseLink: operation == "cached-linked" ? link : nil)
    let note = CompanionNote(id: "saved-note", title: "Report", content: try document.encoded(), revision: 5, kind: .html)
    try await store.apply(.init(workspaceID: "central", cursor: 1, notes: [note]))
    var args: [String]
    if operation == "link" {
      args = ["notes", "link", "--note-id", note.id, "--source-id", "mac", "--database-id", "source", "--path", "data.sqlite"]
    } else if operation == "apply" {
      let operations = String(decoding: try JSONEncoder().encode([NoteEditOperation.setArtifactDatabaseLink(link)]), as: UTF8.self)
      args = ["notes", "apply", "--note-id", note.id, "--json", operations]
    } else { args = ["notes", "set-html", "--note-id", note.id, "--html", "<p>Unsyncable replacement</p>"] }
    args += ["--revision", try MobileToolSupport.fingerprint(note)]
    let response = await call(store, args, context: scope)
    #expect(!response.success)
    let reopened = try MobileStore(file: root.appendingPathComponent("library.json"))
    #expect(await reopened.snapshot().notes[note.id] == note)
    #expect(await reopened.snapshot().outbox.isEmpty)
    #expect(await reopened.snapshot().toolReceipts?.isEmpty != false)
  }

  @Test(arguments: ["copy", "update", "detach"])
  func inheritedScheduledTaskRequiresSessionPermission(action: String) async throws {
    let (store, root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let deviceID = await store.snapshot().deviceID
    let scope = MobileToolContext(sessionID: "parent", workspaceID: deviceID, enabled: [.calendar])
    let task = CompanionScheduledTask(prompt: "Execute work", workspaceID: deviceID, enabledTools: ["execute_command"])
    let original = try await store.calendar.save(expectedRevision: nil,
      draft: .init(title: "Daily work", startsAt: MobileToolSupport.date("2026-10-10T12:00:00Z"), recurrenceUnit: "day", task: task), ownerDeviceID: deviceID)
    var args = ["calendar", action, original.id]
    switch action {
    case "copy": args += ["--starts-at", "2026-10-15T12:00:00Z"]
    case "update": args += ["--revision", "0", "--title", "Changed"]
    default: args += ["--revision", "0", "--occurrence", "1"]
    }
    let request = WovenMatterToolRequest(arguments: args)
    await #expect(throws: WorkspaceToolError.self) {
      _ = try await store.executeCalendarTool(WovenMatterToolCommand(args), request: request, context: scope)
    }
    #expect(await store.calendar.records() == [original])
  }

  @Test func copyingScheduledTaskNarrowsInheritedNativeTools() async throws {
    let (store, root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let deviceID = await store.snapshot().deviceID
    let scope = MobileToolContext(sessionID: "parent", workspaceID: deviceID, enabled: [.calendar, .sessions], nativeToolIDs: ["woven_calendar_create", "woven_sessions_create"])
    let original = try await store.calendar.save(expectedRevision: nil,
      draft: .init(title: "Work", startsAt: MobileToolSupport.date("2026-10-10T12:00:00Z"), task: .init(prompt: "Work", workspaceID: deviceID, enabledTools: ["execute_command", "wovenmatter_calendar"])), ownerDeviceID: deviceID)
    let args = ["calendar", "copy", original.id, "--starts-at", "2026-10-15T12:00:00Z"]
    let request = WovenMatterToolRequest(arguments: args)
    _ = try await store.executeCalendarTool(WovenMatterToolCommand(args), request: request, context: scope)
    let copy = try #require(await store.calendar.record(id: request.requestID))
    #expect(copy.event.draft.task?.enabledTools == ["woven_calendar_create"])
    var revoked = scope; revoked.enabled.remove(.sessions)
    await #expect(throws: WorkspaceToolError.self) {
      _ = try await store.executeCalendarTool(WovenMatterToolCommand(args), request: request, context: revoked)
    }
  }

}
