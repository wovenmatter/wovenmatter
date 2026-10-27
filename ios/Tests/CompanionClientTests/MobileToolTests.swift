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

}
