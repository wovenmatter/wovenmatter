import Foundation
import Observation
import SwiftUI
import WovenMatterCore
import WovenMatterDashboardStore

// Only appearance constants are substituted; the parser and state under test
// are the actual app sources. This fixture does not load any app services.
enum DashboardPalette {
    static let foreground = Color.black
    static let primary = Color.green
}

private final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@main
struct DashboardConversationStateTests {
    static func decode<T: Decodable>(_ value: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }

    static func message(_ id: String, _ text: String, time: String = "2") throws -> WorkspaceMessageRecord {
        try decode(["id": id, "conversation_id": "chat", "role": "assistant",
                    "content": text, "created_at": time, "status": "streaming"])
    }

    static func rendered(_ text: String, commentary: Set<String> = [], final: Bool = true) -> DashboardMessagePresentation {
        DashboardMessagePresentation(source: text, displayedBody: text, status: "streaming",
            createdAt: "2", document: ConversationMarkdownDocument(text),
            commentaryIDs: commentary, hasFinalReply: final)
    }

    static func page(_ messages: [WorkspaceMessageRecord], runs: [WorkspaceRunRecord] = [], older: Bool = false) -> WorkspaceConversationHistoryPage {
        WorkspaceConversationHistoryPage(conversationID: "chat", messages: messages, runs: runs, hasOlderMessages: older)
    }

    @MainActor static func main() throws {
        let reply = try message("reply", "Hello")
        let run: WorkspaceRunRecord = try decode(["id": "run", "conversation_id": "chat",
            "assistant_message_id": "reply", "status": "running"])
        let window = DashboardConversationWindow(page: page([reply], runs: [run]))
        func presentation(_ text: DashboardMessagePresentation = rendered("Hello")) -> DashboardConversationPresentation {
            DashboardConversationPresentation(window: window, messagesByID: ["reply": text], runsByID: [:])
        }
        let initial = presentation()
        precondition(initial.rows.count == 1)
        precondition(initial.rows == presentation().rows, "identical rows must skip redundant view work")
        precondition(initial.rows != presentation(rendered("Hello", commentary: ["segment"])).rows,
                     "commentary changes must invalidate a row")
        precondition(initial.rows != presentation(rendered("Hello", final: false)).rows,
                     "final-reply changes must invalidate a row")
        precondition(initial.rows != presentation(rendered("Replacement")).rows,
                     "projected body changes must invalidate a row")
        let timed = DashboardConversationPresentation(window: window, messagesByID: initial.messagesByID,
            runsByID: [run.id: DashboardRunPresentation(source: run, startedAt: Date(timeIntervalSince1970: 1), completedDuration: "2s")])
        precondition(initial.rows != timed.rows, "run timing changes must invalidate a row")
        let attachment: WorkspaceMessageAttachmentRecord = try decode([
            "id": "attachment", "conversation_id": "chat", "message_id": "reply",
            "file_name": "test.txt", "created_at": "2", "kind": "file",
            "mime_type": "text/plain", "size_bytes": 5
        ])
        let attachmentPage = WorkspaceConversationHistoryPage(conversationID: "chat", messages: [reply], runs: [run], attachments: [attachment], hasOlderMessages: false)
        let attached = DashboardConversationPresentation(window: DashboardConversationWindow(page: attachmentPage), messagesByID: initial.messagesByID, runsByID: [:])
        precondition(initial.rows != attached.rows, "attachment changes must invalidate a row")

        let activity = WorkspaceRunActivityRecord(id: "work", runID: "run", conversationID: "chat",
            activity: AgentRunActivity(id: "work", kind: .progress, content: "Working"), createdAt: "2")
        let activePage = WorkspaceConversationHistoryPage(conversationID: "chat", messages: [reply], runs: [run], activities: [activity], hasOlderMessages: false)
        let active = DashboardConversationPresentation(window: DashboardConversationWindow(page: activePage), messagesByID: initial.messagesByID, runsByID: [:])
        precondition(initial.rows != active.rows, "work activity changes must invalidate a row")
        let reference: WorkspaceMessageReferenceRecord = try decode([
            "id": "reference", "conversation_id": "chat", "message_id": "reply", "resource_type": "note",
            "resource_id": "note", "title_snapshot": "Note", "content_snapshot": "Context", "revision_snapshot": "1", "created_at": "2"
        ])
        let referencedPage = WorkspaceConversationHistoryPage(conversationID: "chat", messages: [reply], runs: [run], references: [reference], hasOlderMessages: false)
        let referenced = DashboardConversationPresentation(window: DashboardConversationWindow(page: referencedPage), messagesByID: initial.messagesByID, runsByID: [:])
        precondition(initial.rows != referenced.rows, "reference changes must invalidate a row")

        let primary = DashboardConversationState(conversationID: "chat")
        let sibling = DashboardConversationState(conversationID: "sibling")
        let primaryChanges = Changes(), siblingChanges = Changes()
        withObservationTracking { _ = primary.rows } onChange: { primaryChanges.record() }
        withObservationTracking { _ = sibling.rows } onChange: { siblingChanges.record() }
        primary.apply(initial)
        precondition(primaryChanges.value == 1 && siblingChanges.value == 0,
                     "streaming one pane must not invalidate a sibling state")
        let metadataChanges = Changes()
        withObservationTracking { _ = primary.hasOlderMessages; _ = primary.error } onChange: { metadataChanges.record() }
        primary.apply(presentation(rendered("Next chunk")))
        primary.setError(nil)
        precondition(metadataChanges.value == 0, "unchanged metadata must not invalidate observers")
        let staleRefresh = primary.beginRefresh()
        let currentRefresh = primary.beginRefresh()
        precondition(!primary.isCurrentRefresh(staleRefresh) && primary.isCurrentRefresh(currentRefresh),
                     "paging supersession must reject an in-flight old refresh")

        let earlier = try message("earlier", "History", time: "1")
        let current = DashboardConversationWindow(page: page([reply], runs: [run], older: true))
        let expanded = current.prepending(page([earlier]))
        let changedReply = try message("reply", "Hello again")
        let refreshed = expanded.refreshing(with: page([changedReply], runs: [run], older: true))
        precondition(refreshed.messages.map(\.id) == ["earlier", "reply"])
        precondition(refreshed.messages.last?.content == "Hello again")
        precondition(!refreshed.hasOlderMessages && refreshed.loadedOlderMessages,
                     "refresh must retain the loaded prefix and its exhausted cursor")
        let merged = expanded.mergingNewer(DashboardConversationWindow(page: page([changedReply], runs: [run])))
        precondition(merged.messages == refreshed.messages, "a concurrent newer window must win when history arrives")

        let blank = try message("reply", "")
        let queued: WorkspaceRunRecord = try decode(["id": "run", "conversation_id": "chat",
            "assistant_message_id": "reply", "status": "queued"])
        let hidden = DashboardConversationPresentation(window: DashboardConversationWindow(page: page([blank], runs: [queued])), messagesByID: [:], runsByID: [:])
        precondition(hidden.rows.isEmpty, "queued empty placeholders stay hidden")
        let code = ConversationMarkdownDocument.InlineText("A `code` span")
        precondition(code.plainText == "A code span")
        precondition(code.rendered.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && $0.font != nil },
                     "precomputed inline code styling must survive rendering")
        print("Conversation state, row equality, paging, observation, and markdown checks passed.")
    }
}
