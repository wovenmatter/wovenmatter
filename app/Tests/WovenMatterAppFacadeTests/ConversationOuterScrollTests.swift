import AppKit
import SwiftUI
import Testing
import WovenMatterCore
@testable import WovenMatterAppFacade

/// Exercise the production outer transcript, including its composer clearance
/// and bottom anchor. Inner work-scroll tests cannot detect a blank outer view.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct ConversationOuterScrollTests {
    @Test func firstExchangeAndConversationSwitchKeepContentInTheViewport() async throws {
        _ = NSApplication.shared
        let suite = "outer-scroll-fixture.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ApplicationModel(applicationDefaults: defaults, startsAutomatically: false, ownsExecutionOverride: false)
        let fixture = OuterTranscriptFixture()
        let host = NSHostingView(rootView: OuterTranscriptFixtureView(model: model, fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 840),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.setFrameSize(NSSize(width: 720, height: 840))
        defer { window.contentView = nil; window.close() }
        try await settle(host)

        // Match the small first Grok exchange without using user text: the
        // prompt exists immediately, followed by supplied thoughts and answer.
        fixture.started = true
        try await settle(host)
        try assertBoundedViewport(host, maximumHeight: 1800)
        fixture.thought = "A supplied thought arrives before the answer."
        fixture.answer = String(repeating: "A visible answer sentence. ", count: 11)
        try await settle(host)
        try assertBoundedViewport(host, maximumHeight: 2000)
        try assertVisibleResponse(host, containing: "visible answer")

        fixture.thought = (0..<400).map { "Reasoning paragraph \($0) describes a supplied intermediate step.\n\n" }.joined()
        try await settle(host)
        try assertBoundedViewport(host, maximumHeight: 2200)
        try assertVisibleResponse(host, containing: "visible answer")

        // A long native response grows and then settles into a short final
        // answer. Both shrinking and changing chats must discard old offsets.
        fixture.answer = (0..<180).map { "Paragraph \($0) is supplied while the response streams.\n\n" }.joined()
        try await settle(host)
        try assertVisibleResponse(host, containing: "Paragraph")
        fixture.running = false
        fixture.thought = "The supplied reasoning is complete."
        fixture.answer = "The final answer remains visible."
        try await settle(host)
        try assertBoundedViewport(host, maximumHeight: 2000)
        try assertVisibleResponse(host, containing: "final answer")

        fixture.conversationID = "second-conversation"
        fixture.running = true
        fixture.thought = ""
        fixture.answer = "The second conversation is visible immediately."
        try await settle(host)
        try assertBoundedViewport(host, maximumHeight: 1800)
        try assertVisibleResponse(host, containing: "second conversation")
    }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<16 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func assertBoundedViewport(_ host: NSView, maximumHeight: CGFloat) throws {
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }
            .max(by: { $0.bounds.height < $1.bounds.height }))
        let document = try #require(scroll.documentView)
        #expect(document.bounds.height < maximumHeight, "A short exchange acquired a phantom scroll extent")
        let visible = document.visibleRect.intersection(document.bounds)
        #expect(visible.height > 0, "The transcript scrolled beyond its document")
        #expect(document.bounds.maxY - document.visibleRect.maxY < 100,
            "The latest reply's anchor retained an earlier conversation's offset")
    }

    private func assertVisibleResponse(_ host: NSView, containing text: String) throws {
        let responses = descendants(host).compactMap { $0 as? ConversationResponseNativeTextView }
            .filter { $0.string.contains(text) }
        try #require(!responses.isEmpty, "The production transcript omitted supplied text")
        #expect(responses.contains { !$0.visibleRect.intersection($0.bounds).isEmpty },
            "All supplied response text lies outside the visible viewport")
    }
}

@MainActor private final class OuterTranscriptFixture: ObservableObject {
    @Published var conversationID = "first-conversation"
    @Published var started = false
    @Published var running = true
    @Published var thought = ""
    @Published var answer = ""

    var conversation: WorkspaceConversationRecord {
        decode(["id": conversationID, "title": "Outer scroll fixture", "unread": false, "is_pinned": false, "is_archived": false])
    }
    var messages: [WorkspaceMessageRecord] {
        guard started else { return [] }
        return [message("user", text: String(repeating: "A harmless fixture prompt. ", count: 30)), message("assistant", text: answer)]
    }
    private func message(_ role: String, text: String) -> WorkspaceMessageRecord {
        decode(["id": conversationID + role, "conversation_id": conversationID, "role": role, "content": text,
                "status": role == "user" || !running ? "completed" : "streaming", "created_at": "2026-10-27T15:46:15.000Z"])
    }
    var runs: [WorkspaceRunRecord] {
        guard started else { return [] }
        return [decode(["id": conversationID + "run", "conversation_id": conversationID,
                        "user_message_id": conversationID + "user", "assistant_message_id": conversationID + "assistant",
                        "status": running ? "running" : "completed", "started_at": "2026-10-27T15:46:15.000Z"])]
    }
    var activities: [WorkspaceRunActivityRecord] {
        guard !thought.isEmpty else { return [] }
        return [.init(id: "thought", runID: conversationID + "run", conversationID: conversationID,
                      activity: .init(id: "thought", kind: .thought, status: running ? "running" : "completed", content: thought),
                      createdAt: "2026-10-27T15:46:18.000Z", sequence: 0)]
    }
    var presentations: [String: DashboardMessagePresentation] {
        Dictionary(uniqueKeysWithValues: messages.map { message in
            let work = message.role == "assistant" ? activities : []
            return (message.id, DashboardMessagePresentation(source: message.content, displayedBody: message.content,
                status: message.status, isStreaming: running && message.role == "assistant", createdAt: message.createdAt,
                document: nil, activities: work, commentaryIDs: [],
                workTimeline: ConversationWorkTimeline(records: work, commentaryIDs: []), textDeliveredAt: Date()))
        })
    }
    private func decode<T: Decodable>(_ object: [String: Any]) -> T {
        try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

@MainActor private struct OuterTranscriptFixtureView: View {
    let model: ApplicationModel
    @ObservedObject var fixture: OuterTranscriptFixture
    var body: some View {
        DashboardCloudConversation(model: model, agent: nil, conversation: fixture.conversation,
            messages: fixture.messages, messageAttachments: [], messageReferences: [], messagePresentations: fixture.presentations,
            activeRuns: fixture.runs, runActivities: fixture.activities, runPresentations: [:], attachedNoteTitle: nil,
            draft: .constant(""), attachments: [], sendInProgress: fixture.running && fixture.started,
            startsComposerCollapsed: false, usesCompactPanelSpacing: false, showsClosePanel: false, showsAddPanel: false,
            focusRequestGeneration: nil, onActivatePanel: {}, onClosePanel: {}, onAddPanel: {}, onSend: {},
            onAttachmentAction: { _ in }, onRemoveAttachment: { _ in }, onDropFiles: { _ in false },
            onCommandNavigation: { _ in false }, onUnavailableComposerAction: { _ in })
    }
}
