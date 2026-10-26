import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

@Suite("Conversation HTML renders")
struct ConversationHTMLRenderTests {
  @Test func openCodeServerReconciliationKeepsPublishedPages() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
    let caller = try await database.createLocalACPSession(runtimeKind: .opencode, title: "HTML", ownerDeviceID: UUID())
    try await database.attachOpenCodeSession(.init(conversationID: caller, connectionID: "fixture", sessionID: "ses_fixture"))
    var snapshot = OpenCodeSessionSnapshot()
    snapshot.active = true
    snapshot.messages = [["id": "msg_result", "type": "assistant", "time": ["created": .number(1)], "content": .array([])]]
    try await database.saveOpenCodeSnapshot(snapshot, conversationID: caller)
    let page = try ConversationHTMLPage(html: "<p>Keep this page</p>", title: "Page", height: 120)
    let reference = try await database.publishConversationHTML(page, callerID: caller, requestID: UUID().uuidString)
    snapshot.active = false
    try await database.saveOpenCodeSnapshot(snapshot, conversationID: caller)
    let history = try await database.conversationHistoryPage(id: caller, limit: 20, compactActivities: true)
    #expect(history.activities.contains { $0.activity.htmlRender == reference })
  }

  @Test func validationAndSandbox() throws {
    _ = try ConversationHTMLPage(html: "<button onclick='this.textContent=42'>Calculate</button>", title: "Calculator", height: 200)
    #expect(throws: (any Error).self) { try ConversationHTMLPage(html: " ", title: "Page", height: 200) }
    #expect(throws: (any Error).self) { try ConversationHTMLPage(html: "<p>Hi</p>", title: "Page", height: 2001) }
    #expect(throws: (any Error).self) { try ConversationHTMLPage(html: "<style>div{height:100dvh}</style>", title: "Page", height: 200) }
    #expect(throws: (any Error).self) { try ConversationHTMLPage(html: "<div style='min-height:20vh'>Hi</div>", title: "Page", height: 200) }
    #expect(throws: (any Error).self) { try ConversationHTMLPage(html: String(repeating: "a", count: ConversationHTMLResources.maximumPageBytes + 1), title: "Page", height: 200) }
    let hostile = "</script><iframe src='file:///private/secret'></iframe>"
    let wrapper = ConversationHTMLDocument.render(html: hostile)
    #expect(!wrapper.contains(hostile))
    #expect(wrapper.contains("sandbox=\"allow-scripts allow-forms\""))
    #expect(!wrapper.contains("allow-same-origin"))
    #expect(wrapper.contains("connect-src http: https:"))
    #expect(wrapper.contains("e.source!==frame.contentWindow"))
    #expect(wrapper.contains("object-src 'none'"))
  }

  @Test func persistenceReplayAndFoldedHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "workspace.sqlite")
    let database = try await WorkspaceDatabase(url: url)
    let caller = try await database.createLocalACPSession(runtimeKind: .codex, title: "Visuals", ownerDeviceID: UUID())
    let other = try await database.createLocalACPSession(runtimeKind: .codex, title: "Other", ownerDeviceID: UUID())
    let run = try await database.beginLocalACPRun(conversationID: caller, content: "Make a chart")
    let id = UUID().uuidString.lowercased()
    let page = try ConversationHTMLPage(html: "<h2>Chart</h2><script>console.log('ready')</script>", title: "Chart", height: 250)
    let reference = try await database.publishConversationHTML(page, callerID: caller, requestID: id)
    #expect(try await database.publishConversationHTML(page, callerID: caller, requestID: id) == reference)
    #expect(try await database.publishConversationHTML(page, callerID: caller, requestID: id.uppercased()) == reference)
    await #expect(throws: (any Error).self) { try await database.publishConversationHTML(page, callerID: other, requestID: id) }
    let changed = try ConversationHTMLPage(html: "<p>Changed</p>", title: "Chart", height: 250)
    await #expect(throws: (any Error).self) { try await database.publishConversationHTML(changed, callerID: caller, requestID: id) }
    try await database.completeLocalACPRun(runID: run.runID)
    #expect(try await database.publishConversationHTML(page, callerID: caller, requestID: id) == reference)
    await #expect(throws: (any Error).self) { try await database.publishConversationHTML(page, callerID: caller, requestID: UUID().uuidString) }

    let reopened = try await WorkspaceDatabase(url: url, readOnlyProjection: true)
    let history = try await reopened.conversationHistoryPage(id: caller, limit: 20, compactActivities: true)
    let activity = try #require(history.activities.first { $0.activity.htmlRender != nil })
    #expect(activity.activity.htmlRender == reference)
    #expect(activity.activity.rawOutputJSON == nil)
    #expect(activity.activity.detailsAvailable == true)
    let timeline = ConversationWorkTimeline(records: history.activities, commentaryIDs: [])
    #expect(timeline.foldedEntries.count == 1)
    let duplicate = WorkspaceRunActivityRecord(id: "replicated", runID: run.runID, conversationID: caller,
      activity: .init(id: "native-copy", kind: .activity, htmlRender: reference), createdAt: "9999")
    #expect(ConversationWorkTimeline(records: history.activities + [duplicate], commentaryIDs: []).foldedEntries.count == 1)
    let detail = try #require(try await reopened.conversationActivityDetails(conversationID: caller, runID: run.runID, activityID: activity.activity.id))
    #expect(try JSONDecoder().decode(ConversationHTMLPage.self, from: Data(try #require(detail.rawOutputJSON).utf8)) == page)
    #expect(try await database.sessionTools(caller).enabled.contains(.html))
  }
}
