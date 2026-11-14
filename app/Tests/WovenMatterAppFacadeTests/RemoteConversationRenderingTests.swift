import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterLibraryStore
@testable import WovenMatterAppFacade

/// A session another machine runs renders through the same window and
/// presentations as the session's own history page would on its Mac.
@Suite struct RemoteConversationRenderingTests {
    private let conversationID = UUID().uuidString.lowercased()

    private func record(_ id: String, run: String, _ activity: AgentRunActivity, at time: String) -> WorkspaceRunActivityRecord {
        .init(id: run + ":activity:" + id, runID: run, conversationID: conversationID, activity: activity, createdAt: time)
    }

    /// One finished run with commentary, a thought, a tool with a diff, a
    /// plan and Pi Durable subagents, and a second run still streaming.
    private func localPage() throws -> WorkspaceConversationHistoryPage {
        let messages = try JSONDecoder().decode([WorkspaceMessageRecord].self, from: Data("""
        [{"id":"u1","conversation_id":"\(conversationID)","run_id":"r1","role":"user","content":"Fix the build","status":"completed","created_at":"2026-11-12T10:00:00Z"},
         {"id":"a1","conversation_id":"\(conversationID)","run_id":"r1","role":"assistant","content":"Looking first. Fixed it.","status":"completed","created_at":"2026-11-12T10:00:01Z"},
         {"id":"u2","conversation_id":"\(conversationID)","run_id":"r2","role":"user","content":"Now test it","status":"completed","created_at":"2026-11-12T10:01:00Z"},
         {"id":"a2","conversation_id":"\(conversationID)","run_id":"r2","role":"assistant","content":"Running the tests so f","status":"streaming","created_at":"2026-11-12T10:01:01Z"}]
        """.utf8))
        let runs = try JSONDecoder().decode([WorkspaceRunRecord].self, from: Data("""
        [{"id":"r1","conversation_id":"\(conversationID)","user_message_id":"u1","assistant_message_id":"a1","status":"completed","started_at":"2026-11-12T10:00:00Z","completed_at":"2026-11-12T10:00:42Z","created_at":"2026-11-12T10:00:00Z"},
         {"id":"r2","conversation_id":"\(conversationID)","user_message_id":"u2","assistant_message_id":"a2","status":"running","started_at":"2026-11-12T10:01:00Z","created_at":"2026-11-12T10:01:00Z"}]
        """.utf8))
        let subagents = try JSONDecoder().decode([AgentRunSubagent].self, from: Data(#"[{"id":"child","name":"Reviewer","state":"running"}]"#.utf8))
        let activities = [
            record("c1", run: "r1", .init(id: "c1", kind: .assistant, content: "Looking first. ", assistantMessageID: "a1", position: 1), at: "2026-11-12T10:00:02Z"),
            record("t1", run: "r1", .init(id: "t1", kind: .thought, title: "Thinking", status: "completed", content: "The import is wrong.", position: 2), at: "2026-11-12T10:00:03Z"),
            record("edit", run: "r1", AgentRunActivity(id: "edit", kind: .tool, phase: "end", title: "Edit Package.swift", status: "completed",
                toolName: "edit", content: "Edited", position: 3, locations: [.init(path: "Package.swift", line: 4)],
                changes: [.init(path: "Package.swift", oldText: "a\nb", newText: "a\nB\nc")], rawInputJSON: #"{"path":"Package.swift"}"#)
                .presentationSummary(version: 2), at: "2026-11-12T10:00:04Z"),
            record("plan", run: "r1", .init(id: "plan", kind: .plan, phase: "update", title: "Plan", status: "completed", position: 4,
                planEntries: [.init(content: "Fix", status: "completed")], planKind: "checklist", planOperation: "replace"), at: "2026-11-12T10:00:05Z"),
            record("agents", run: "r1", AgentRunActivity(id: "agents", kind: .activity, phase: "update", title: "Subagents",
                detail: "1 active · 1 total", status: "running", position: 5, subagents: subagents).presentationSummary(), at: "2026-11-12T10:00:06Z"),
            record("run-tests", run: "r2", .init(id: "run-tests", kind: .tool, phase: "update", title: "swift test", status: "in_progress",
                toolName: "execute", position: 6), at: "2026-11-12T10:01:02Z")
        ]
        return .init(conversationID: conversationID, messages: messages, runs: runs, activities: activities, hasOlderMessages: true)
    }

    private func rendered(_ page: WorkspaceConversationHistoryPage) throws -> ConversationPresentation {
        try #require(ApplicationModel.remotePresentation(page, previous: nil))
    }

    @Test func aRemoteTranscriptRendersTheSameViewModelAsTheLocalHistory() throws {
        let local = try localPage()
        // What the session's Mac serves on its stream and transcript route,
        // as the JSON that crosses the wire.
        let served = RemoteConversationRecords.transcript(conversationID: conversationID, messages: local.messages, runs: local.runs,
            activities: local.activities, attachments: [], activeRunID: "r2", olderCursor: "older")
        let wire = try JSONDecoder().decode(LibraryTranscript.self, from: JSONEncoder().encode(served))
        let remote = WorkspaceConversationHistoryPage(remote: wire)

        let expected = try rendered(local), actual = try rendered(remote)
        let fields: (WorkspaceMessageRecord) -> [String?] = { [$0.id, $0.runID, $0.role, $0.content, $0.status, $0.createdAt] }
        #expect(actual.window.messages.map(fields) == expected.window.messages.map(fields))
        let runFields: (WorkspaceRunRecord) -> [String?] = {
            [$0.id, $0.status, $0.userMessageID, $0.assistantMessageID, $0.startedAt, $0.completedAt]
        }
        #expect(actual.window.runs.map(runFields) == expected.window.runs.map(runFields))
        #expect(actual.window.activities == expected.window.activities)
        #expect(actual.window.hasOlderMessages == expected.window.hasOlderMessages)
        for message in expected.window.messages {
            let left = try #require(expected.messagesByID[message.id]), right = try #require(actual.messagesByID[message.id])
            #expect(right.displayedBody == left.displayedBody)
            #expect(right.isStreaming == left.isStreaming)
            #expect(right.activities == left.activities)
            #expect(right.commentaryIDs == left.commentaryIDs)
            #expect(right.workTimeline == left.workTimeline)
        }
        #expect(actual.runsByID["r1"]?.completedDuration == expected.runsByID["r1"]?.completedDuration)
        #expect(actual.runsByID["r1"]?.completedDuration != nil)
        // The work interleaves with the reply as it did on its Mac: the commentary leaves the reply body.
        #expect(actual.messagesByID["a1"]?.displayedBody == "Fixed it.")
        #expect(actual.messagesByID["a1"]?.commentaryIDs == ["c1"])
        #expect(actual.messagesByID["a2"]?.isStreaming == true)
    }

    @Test func aLinuxTranscriptJoinsItsPartsAndPlacesItsWork() throws {
        let id = conversationID, run = UUID().uuidString.lowercased(), input = UUID().uuidString.lowercased()
        func projection(_ value: AgentRunActivity) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        let long = String(repeating: "x", count: 16_384)
        let transcript = LibraryTranscript(conversationID: id, messages: [
            .init(id: input, conversationID: id, runID: run, role: "user", content: "Write it", createdAt: "2026-11-12T10:00:00Z"),
            .init(id: run, conversationID: id, runID: run, role: "assistant", content: "Reading. " + long, status: "running", createdAt: "2026-11-12T10:00:00.1Z"),
            .init(id: run + "-part-1", conversationID: id, runID: run, role: "assistant", content: "tail", status: "running", createdAt: "2026-11-12T10:00:00.1Z")
        ], activities: [
            // A reasoning row's projection has no position: its sequence places it.
            .init(id: run + ":thinking", runID: run, title: "Thinking", status: "running",
                projectionJSON: try projection(.init(id: run + ":thinking", kind: .thought, title: "Thinking", content: "Hmm")), sequence: 1),
            .init(id: run + ":assistant:0", runID: run, title: "Commentary", status: "completed",
                projectionJSON: try projection(.init(id: run + ":assistant:0", kind: .assistant, content: "Reading. ", assistantMessageID: run, position: 2)), sequence: 2),
            .init(id: run + ":read", runID: run, title: "Read", status: "running",
                projectionJSON: try projection(.init(id: run + ":read", kind: .tool, title: "Read", status: "in_progress", toolName: "read", position: 3)),
                detailsRecordID: "activity-x", sequence: 3)
        ], activeRunID: run, runs: [.init(id: run, status: "running", startedAt: "2026-11-12T10:00:00Z", userMessageID: input, assistantMessageID: run)])
        let records = RemoteConversationRecords(transcript)
        #expect(records.messages.map(\.id) == [input, run])
        #expect(records.messages.last?.content == "Reading. " + long + "tail")
        #expect(records.messages.last?.status == "streaming")
        #expect(records.runs.map(\.userMessageID) == [input] && records.runs.map(\.assistantMessageID) == [run])
        #expect(records.runs.first?.status == "running")
        #expect(records.activities.map(\.activity.position) == [1, 2, 3])
        #expect(records.activities.first?.activity.status == "running", "A projection without a status takes its row's")
        #expect(records.activities.last?.activity.detailsAvailable == true, "A details record means a disclosure has more")
        let presentation = try rendered(.init(remote: transcript))
        #expect(presentation.messagesByID[run]?.commentaryIDs == [run + ":assistant:0"])
        #expect(presentation.messagesByID[run]?.workTimeline.entries.isEmpty == false)
    }

    @Test func aSettledRowOverridesAStaleProjectionStatus() throws {
        let run = UUID().uuidString.lowercased()
        let stale = String(decoding: try JSONEncoder().encode(AgentRunActivity(id: "t", kind: .tool, status: "in_progress")), as: UTF8.self)
        let records = RemoteConversationRecords(.init(conversationID: conversationID, activities: [
            .init(id: "t", runID: run, title: "Tool", status: "interrupted", projectionJSON: stale)
        ], runs: [.init(id: run, status: "interrupted")]))
        #expect(records.activities.first?.activity.status == "interrupted")
        #expect(records.runs.first?.status == "interrupted")
    }
}
