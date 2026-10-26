import Foundation
import Testing
import WovenMatterCompanion
@testable import CompanionClient

@Suite("Offline Woven MCP service operations")
struct MobileToolTests {
  private func fixture() throws -> (MobileStore, URL, MobileToolContext) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wm-tool-tests-" + UUID().uuidString)
    return (try MobileStore(file: root.appendingPathComponent("library.json")), root, .init(sessionID: "phone-session", workspaceID: "phone-workspace"))
  }
  private func call(_ store: MobileStore, _ args: [String], context: MobileToolContext, id: String = UUID().uuidString.lowercased()) async -> WovenMatterToolResponse {
    await store.executeLocalTool(.init(arguments: args, requestID: id), context: context)
  }
  @Test func mutationReceiptPreservesEditsAndRechecksRevisionAndPermission() async throws {
    let (store, root, scope) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased()
    let created = await call(store, ["notes", "create", "--title", "Original"], context: scope, id: id)
    #expect(created.success)
    let read = await call(store, ["notes", "read", id], context: scope)
    let revision = try #require(read.result?.objectValue?["revision"]?.stringValue)
    let edited = await call(store, ["notes", "set-title", "--note-id", id, "--title", "Later", "--revision", revision], context: scope)
    #expect(edited.success)
    let stale = await call(store, ["notes", "set-title", "--note-id", id, "--title", "Lost edit", "--revision", revision], context: scope)
    #expect(stale.code == "revision_conflict")
    #expect(await store.snapshot().notes[id]?.title == "Later")
    let reopened = try MobileStore(file: root.appendingPathComponent("library.json"))
    let replay = await call(reopened, ["notes", "create", "--title", "Original"], context: scope, id: id)
    #expect(replay.success)
    #expect(await reopened.snapshot().notes.count == 1)
    #expect(await reopened.snapshot().notes[id]?.title == "Later")
    let mismatched = await call(reopened, ["notes", "create", "--title", "Other"], context: scope, id: id)
    #expect(!mismatched.success)
    var disabled = scope; disabled.enabled.remove(.notes)
    let denied = await call(reopened, ["notes", "create", "--title", "Original"], context: disabled, id: id)
    #expect(!denied.success && denied.code == "tool_disabled")
    #expect(await reopened.snapshot().notes.count == 1)
  }

  @Test func cancelledCallerCannotCommitAfterActorHop() async throws {
    let (store, root, scope) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let request = WovenMatterToolRequest(arguments: ["notes", "create", "--title", "Cancelled"])
    let response = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await store.executeLocalTool(request, context: scope)
    }.value
    #expect(!response.success)
    #expect(await store.snapshot().notes.isEmpty)
    #expect(await store.snapshot().outbox.isEmpty)
    let queued = await Task { () -> Bool in
      withUnsafeCurrentTask { $0?.cancel() }
      do { _ = try await store.enqueueToolSubmission(id: UUID().uuidString, sessionID: scope.sessionID, text: "Cancelled"); return true }
      catch is CancellationError { return false }
      catch { return true }
    }.value
    #expect(!queued)
    #expect(await store.toolSubmissions().isEmpty)
  }
  @Test func richTableOperationsUseSharedDesktopDocumentEngine() async throws {
    let (store, root, scope) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased()
    #expect(await call(store, ["notes", "create", "--title", "Sheet", "--kind", "spreadsheet"], context: scope, id: id).success)
    let note = try #require(await store.snapshot().notes[id]); let doc = try NoteDocument.editableDocument(from: note.content)
    let tableID = try #require(doc.blocks.first?.id)
    let result = await call(store, ["notes", "table", "set-cell", "--note-id", id, "--table-id", tableID, "--row", "0", "--column", "0", "--text", "Value", "--revision", try MobileToolSupport.fingerprint(note)], context: scope)
    #expect(result.success)
    let changed = try #require(await store.snapshot().notes[id])
    #expect(NoteDocument.decode(changed.content).plainText.contains("Value"))
    #expect(changed.kind == .spreadsheet)
    #expect(await store.snapshot().outbox.count == 1)
    let versions = await call(store, ["notes", "versions", id], context: scope)
    #expect(versions.result?.objectValue?["rows"]?.arrayValue?.count == 1)
  }
  @Test func nativeHistoryReadsBeyondUICacheAndRetainsBoundedWindows() async throws {
    let (store, root, scope) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let date = try MobileToolSupport.date("2026-10-10T12:00:00Z")
    let raw: [String: Any] = ["id": 42, "conversationId": 7, "kind": "pi.assistant", "model": [["role": "assistant", "timestamp": date.timeIntervalSince1970 * 1_000, "content": String(repeating: "history detail ", count: 10_000)]]]
    let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
    let events = try await store.journal.appendNativeRecord(workspaceID: scope.workspaceID, conversationID: scope.sessionID, recordID: "native-record", format: "pi-durable.entry.v1", data: data)
    #expect(events.count > 1)
    #expect(await store.snapshot().transcripts.isEmpty)
    let search = await call(store, ["history", "search", "history detail", "--kind", "pi.assistant", "--native-conversation-id", "7", "--since", "2026-10-10T11:00:00Z", "--until", "2026-10-10T13:00:00Z"], context: scope)
    #expect(search.success)
    #expect(search.result?.objectValue?["rows"]?.arrayValue?.count == 1)
    let id = try #require(events.first?.eventID)
    let read = await call(store, ["history", "event", id, "--offset", "100000", "--characters", "100"], context: scope)
    #expect(read.success)
    #expect(read.result?.objectValue?["content"]?.stringValue?.count == 100)
    #expect(read.result?.objectValue?["nativeRecord"] == nil)
    #expect(read.result?.objectValue?["transcript"] == nil)
  }
  @Test func libraryKindsAndWorkspaceSelectionsDoNotMixSavedItems() async throws {
    let (store, root, scope) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let photo = try await store.artifacts.save(data: Data("photo".utf8), workspaceID: "phone", title: "Photo", mediaType: "image/png")
    let document = try await store.artifacts.save(data: Data("file".utf8), workspaceID: "mac", title: "Document", mediaType: "text/plain")
    let link = try await store.artifacts.save(data: Data("https://example.com".utf8), workspaceID: "phone", title: "Link", mediaType: "text/uri-list; charset=utf-8")
    for (kind, id) in [("photo", photo.id), ("file", document.id), ("link", link.id)] {
      let result = await call(store, ["library", "list", "--kind", kind, "--workspace", "phone,mac"], context: scope)
      #expect(result.success)
      #expect(result.result?.objectValue?["rows"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue } == [id])
    }
    #expect(!(await call(store, ["library", "list", "--kind", "invalid"], context: scope)).success)
  }
  @Test func timersPersistClaimIdentityCoalesceAndDoNotResurrectOnRetry() async throws {
    let (store, root, scope) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased(), start = try MobileToolSupport.date("2026-10-10T12:00:00Z")
    let args = ["timers", "create", "--text", "Check work", "--at", "2026-10-10T12:00:00Z", "--every", "60"]
    let denied = await call(store, ["timers", "create", "--text", "Bad", "--at", "2026-10-10T12:00:00Z", "--session", "another"], context: scope)
    #expect(denied.code == "access_required")
    #expect(await call(store, args, context: scope, id: id).success)
    let due = try await store.claimDueToolTimers(now: start.addingTimeInterval(301))
    let claim = try #require(due.first?.pendingFireID)
    let reopened = try MobileStore(file: root.appendingPathComponent("library.json"))
    #expect(try await reopened.claimDueToolTimers(now: start.addingTimeInterval(302)).first?.pendingFireID == claim)
    try await reopened.acknowledgeToolTimer(id: id, fireID: claim, now: start.addingTimeInterval(302))
    #expect(try await reopened.claimDueToolTimers(now: start.addingTimeInterval(303)).isEmpty)
    #expect(await call(reopened, ["timers", "remove", id], context: scope).success)
    #expect(await call(reopened, args, context: scope, id: id).success)
    #expect(await reopened.snapshot().toolTimers?[id]?.removed == true)
  }

  @Test func localSessionCoordinationRejectsRemoteAndCycles() async throws {
    let (store, root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let ids: Set<String> = ["a", "b"]
    _ = try await store.coordinateLocalSessions(callerID: "a", targetID: "b", localExecutionIDs: ids, purpose: "Work", notifications: true, requestID: "one")
    await #expect(throws: WorkspaceToolError.self) { _ = try await store.coordinateLocalSessions(callerID: "b", targetID: "a", localExecutionIDs: ids, purpose: "Cycle", notifications: true, requestID: "two") }
    await #expect(throws: WorkspaceToolError.self) { _ = try await store.coordinateLocalSessions(callerID: "a", targetID: "remote", localExecutionIDs: ids, purpose: "Not local", notifications: true, requestID: "three") }
  }
  @Test func executorJobIsDurableAndBoundToSessionAndCode() async throws {
    let (store, root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased()
    _ = try await store.createExecutorJob(id: id, sessionID: "a", code: "text(2+2)")
    try await store.updateExecutorJob(id: id, state: "running")
    let reopened = try MobileStore(file: root.appendingPathComponent("library.json"))
    try await reopened.interruptExecutorJobs()
    #expect(try await reopened.executorJob(id: id, sessionID: "a").state == "interrupted")
    await #expect(throws: WorkspaceToolError.self) { _ = try await reopened.createExecutorJob(id: id, sessionID: "a", code: "other") }
    await #expect(throws: WorkspaceToolError.self) { _ = try await reopened.executorJob(id: id, sessionID: "b") }
  }
  @Test func sessionInboxBindsReplayContentAndPreservesTerminalStateAcrossRestart() async throws {
    let (store, root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased()
    _ = try await store.enqueueToolSubmission(id: id, sessionID: "a", text: "One")
    let reopened = try MobileStore(file: root.appendingPathComponent("library.json"))
    #expect(try await reopened.enqueueToolSubmission(id: id, sessionID: "a", text: "One").state == "queued")
    await #expect(throws: WorkspaceToolError.self) { _ = try await reopened.enqueueToolSubmission(id: id, sessionID: "a", text: "Two") }
    try await reopened.updateToolSubmission(id: id, state: "cancelled")
    try await reopened.updateToolSubmission(id: id, state: "interrupted", error: "Late cancellation")
    #expect(await reopened.toolSubmission(requestID: id)?.state == "cancelled")
  }

  @Test func commandReservationBindsAllSessionCreationArguments() async throws {
    let (store, root, scope) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased()
    let first = WovenMatterToolRequest(arguments: ["sessions", "create", "--title", "One", "--text", "Task", "--purpose", "Testing"], requestID: id)
    try await store.reserveToolInvocation(first, context: scope)
    var changed = first; changed.arguments[3] = "Two"
    await #expect(throws: WorkspaceToolError.self) { try await store.reserveToolInvocation(changed, context: scope) }
  }
  @Test func detachedCalendarRetryReturnsOriginalAfterExcludedOccurrence() async throws {
    let (store, root, scope) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let create = WovenMatterToolRequest(arguments: ["calendar", "create", "--title", "Series", "--starts-at", "2026-10-14T12:00:00Z", "--repeat-unit", "day"])
    #expect(try await store.executeCalendarTool(WovenMatterToolCommand(create.arguments), request: create, context: scope).success)
    #expect(await store.calendar.records().count == 1)
    var disabled = scope; disabled.enabled.remove(.calendar)
    await #expect(throws: WorkspaceToolError.self) {
      _ = try await store.executeCalendarTool(WovenMatterToolCommand(create.arguments), request: create, context: disabled)
    }
    let detach = WovenMatterToolRequest(arguments: ["calendar", "detach", create.requestID, "--revision", "0", "--occurrence", "1"])
    let first = try await store.executeCalendarTool(WovenMatterToolCommand(detach.arguments), request: detach, context: scope)
    let replay = try await store.executeCalendarTool(WovenMatterToolCommand(detach.arguments), request: detach, context: scope)
    #expect(first == replay)
    #expect(await store.calendar.records().count == 2)
  }

}
