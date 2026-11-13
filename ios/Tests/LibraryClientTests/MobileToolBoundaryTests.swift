import Foundation
import Testing
import WovenMatterShared
@testable import LibraryClient

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
  @Test func pageReadsWorkLocally() async throws {
    let (store, root, context) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let document = NoteDocument(kind: .canvas, blocks: [
      .richText(.init(id: "section", style: .heading2, text: "Launch plan")),
      .richText(.init(id: "task", text: "Task")), .richText(.init(id: "link", text: ""))],
      canvas: ["link": .init(x: 0, y: 0, assetID: "missing-asset")], boardPurpose: "Launch",
      boardItems: ["task": .init(task: .init(status: .doing), review: .needed)],
      pageNodes: ["section": .init(isSection: true), "task": .init(parentID: "section"), "link": .init(parentID: "section")])
    let page = try await store.createNote(folderID: nil, title: "Plan", content: document.encoded())
    let before = try #require(await store.snapshot().notes[page.id])

    let read = await call(store, ["pages", "read", "--note-id", page.id], context: context)
    #expect(read.success)
    #expect(read.result?.objectValue?["purpose"]?.stringValue == "Launch")
    let components = try #require(read.result?.objectValue?["components"]?.arrayValue).compactMap(\.objectValue)
    #expect(components.map { $0["componentID"]?.stringValue } == ["section", "task", "link"])
    #expect(components[0]["kind"]?.stringValue == "section" && components[0]["subtreeRevision"]?.stringValue == document.pageSubtreeRevision(for: "section"))
    #expect(components[1]["parentID"]?.stringValue == "section" && components[1]["depth"]?.intValue == 1)
    #expect(components[1]["componentRevision"]?.stringValue == document.boardItemRevision(for: "task"))
    #expect(components[2]["asset"]?.objectValue?["available"]?.boolValue == false)
    let filtered = await call(store, ["pages", "read", "--note-id", page.id, "--needs-review"], context: context)
    #expect(filtered.result?.objectValue?["components"]?.arrayValue?.count == 1)
    let listed = await call(store, ["pages", "list"], context: context)
    #expect(listed.result?.objectValue?["rows"]?.arrayValue?.first?.objectValue?["purpose"]?.stringValue == "Launch")
    #expect(listed.result?.objectValue?["rows"]?.arrayValue?.first?.objectValue?["needsReview"]?.intValue == 1)

    #expect(await store.snapshot().notes[page.id] == before)
    let created = await call(store, ["notes", "create", "--title", "Page", "--kind", "canvas"], context: context)
    #expect(!created.success && created.error?.contains("woven_pages_create") == true)

    var disabled = context; disabled.enabled.remove(.notes)
    let denied = await call(store, ["pages", "read", "--note-id", page.id], context: disabled)
    #expect(!denied.success && denied.code == "tool_disabled")
  }

  /// Quick Chat on a phone edits Pages with the same rules, revisions and replies as on a Mac.
  @Test func quickChatEditsPagesLocallyWithComponentRevisions() async throws {
    let (store, root, base) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var context = base; context.sessionTitle = "Planning"
    let created = await call(store, ["pages", "create", "--title", "Launch", "--purpose", "Ship it"], context: context)
    #expect(created.success && created.result?.objectValue?["kind"]?.stringValue == "page")
    let pageID = try #require(created.result?.objectValue?["id"]?.stringValue)
    #expect(await store.snapshot().notes[pageID]?.kind == .canvas)
    #expect(await store.snapshot().outbox.contains { $0.mutation.resourceID == pageID && $0.mutation.kind == .createNote })

    let sectionID = UUID().uuidString.lowercased(), taskID = UUID().uuidString.lowercased()
    #expect(await call(store, ["pages", "add-component", "--note-id", pageID, "--kind", "section", "--title", "Week one"], context: context, id: sectionID).success)
    let added = await call(store, ["pages", "add-component", "--note-id", pageID, "--kind", "task", "--text", "Write copy", "--parent-id", sectionID], context: context, id: taskID)
    #expect(added.success, "\(added.error ?? "")")
    #expect(added.result?.objectValue?["componentID"]?.stringValue == taskID)
    let revision = try #require(added.result?.objectValue?["componentRevision"]?.stringValue)
    // A retry of the same request replays the reply instead of adding a second task.
    let replay = await call(store, ["pages", "add-component", "--note-id", pageID, "--kind", "task", "--text", "Write copy", "--parent-id", sectionID], context: context, id: taskID)
    #expect(replay == added)

    let done = await call(store, ["pages", "update-component", "--note-id", pageID, "--id", taskID, "--component-revision", revision, "--status", "done", "--outcome", "Drafted"], context: context)
    #expect(done.success)
    let afterDone = try #require(await store.snapshot().notes[pageID])
    let stale = await call(store, ["pages", "update-component", "--note-id", pageID, "--id", taskID, "--component-revision", revision, "--status", "todo"], context: context)
    #expect(!stale.success && stale.code == "revision_conflict")
    #expect(stale.result?.objectValue?["currentComponentRevision"]?.stringValue == done.result?.objectValue?["componentRevision"]?.stringValue)
    #expect(await store.snapshot().notes[pageID] == afterDone, "A conflicting write changes nothing")

    let session = UUID().uuidString.lowercased()
    #expect(await call(store, ["pages", "link-session", "--note-id", pageID, "--id", taskID, "--session", session], context: context).success)
    #expect(await call(store, ["pages", "move-component", "--note-id", pageID, "--id", taskID, "--at-start"], context: context).success)
    #expect(await call(store, ["notes", "append", "--note-id", pageID, "--text", "Notes from the phone"], context: context).success)
    let read = await call(store, ["pages", "read", "--note-id", pageID], context: context)
    let pageRevision = try #require(read.result?.objectValue?["revision"]?.stringValue)
    #expect(await call(store, ["pages", "update", "--note-id", pageID, "--revision", pageRevision, "--title", "Launch v2"], context: context).success)

    let saved = try #require(await store.snapshot().notes[pageID])
    #expect(saved.title == "Launch v2")
    let document = try NoteDocument.editableDocument(from: saved.content).materializedPage()
    #expect(document.blocks.first?.id == taskID, "Moved to the start, out of its section")
    #expect(document.pageNodes?[taskID]?.parentID == nil)
    let task = try #require(document.boardItems?[taskID])
    #expect(task.task?.status == .done && task.task?.outcome == "Drafted" && task.sessions.contains(session))
    #expect(task.updatedBy == BoardActor(kind: .session, sessionID: "parent", label: "Planning"))
    #expect(document.blocks.contains { $0.plainText == "Notes from the phone" })
    // The phone queues the Page for sync as one document.
    #expect(await store.snapshot().outbox.filter { $0.mutation.resourceID == pageID }.count == 1)

    let missing = await call(store, ["pages", "add-component", "--note-id", pageID, "--asset-id", UUID().uuidString.lowercased()], context: context)
    #expect(!missing.success && missing.code == "not_found")
    let note = try await store.createNote(folderID: nil, title: "Plain", content: NoteDocument().encoded())
    let notPage = await call(store, ["pages", "add-component", "--note-id", note.id, "--text", "x"], context: context)
    #expect(!notPage.success && notPage.error?.contains("not a Page") == true)
  }

  @Test func artifactStateIsReadableAndKeyedEditsWorkLocally() async throws {
    let (store, root, context) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let html = "<input id=\"name\">"
    let artifact = try await store.createNote(folderID: nil, title: "Form", content: NoteDocument(kind: .html, html: html).encoded())
    let edit = { (json: String) in ["notes", "artifact-state-edit", "--note-id", artifact.id, "--json", json] }
    #expect(await call(store, edit(#"[{"action":"set","key":"form:name","value":"Ada"}]"#), context: context).success)
    let read = await call(store, ["notes", "artifact-state", "--note-id", artifact.id], context: context)
    #expect(read.result?.objectValue?["state"]?.objectValue?["values"]?.objectValue?["form:name"]?.stringValue == "Ada")
    #expect(read.result?.objectValue?["state"]?.objectValue?["versions"]?.objectValue?["form:name"]?.intValue == 1)
    // A stale version fails and reports a conflict; the next read still has the earlier value.
    let stale = await call(store, edit(#"[{"action":"set","key":"form:name","value":"Bea"}]"#), context: context)
    #expect(!stale.success && stale.code == "revision_conflict")
    let saved = try #require(await store.snapshot().notes[artifact.id])
    let document = try NoteDocument.editableDocument(from: saved.content)
    #expect(document.artifactStateSnapshot.values["form:name"] == .string("Ada"))
    #expect(document.html == html)
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
    let note = LibraryNote(id: "saved-note", title: "Report", content: try document.encoded(), revision: 5, kind: .html)
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
