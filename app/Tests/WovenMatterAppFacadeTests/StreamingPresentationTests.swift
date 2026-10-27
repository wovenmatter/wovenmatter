import AppKit
import SwiftUI
import Testing
import WovenMatterCore
@testable import WovenMatterAppFacade

/// Provider-free rendered acceptance scenes. Set WOVENMATTER_STREAMING_SCREENSHOTS
/// to export the actual shared SwiftUI views for visual review.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct StreamingPresentationTests {
    @Test func sharedTranscriptRendersLiveExpandedSettledAndInterruptedWork() async throws {
        _ = NSApplication.shared
        let output = ProcessInfo.processInfo.environment["WOVENMATTER_STREAMING_SCREENSHOTS"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for theme in DashboardTheme.allCases {
            for width: CGFloat in [380, 760] {
                for scene in Scene.allCases {
                    let state = ConversationTranscriptState()
                    state.setRunExpanded("run", true)
                    state.setExpanded(ConversationTranscriptState.disclosureKey(runID: "run", itemID: "group:reasoning"),
                        scene == .expanded || scene == .trace || scene == .detailTrace)
                    state.setExpanded(ConversationTranscriptState.disclosureKey(runID: "run", itemID: "activity:reasoning"),
                        scene == .expanded)
                    let records = scene.records
                    let root = VStack(alignment: .leading, spacing: 18) {
                        ConversationUserBubble(content: "Compare the streaming events and verify the result.") { EmptyView() }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        ConversationWorkTranscript(
                            run: .init(id: "run", conversationID: "fixture", status: scene.status),
                            presentation: .init(startedAt: Date().addingTimeInterval(-12), completedDuration: "12s"),
                            records: records, hasFinalReply: !scene.response.isEmpty)
                        if !scene.response.isEmpty {
                            ConversationResponse(content: scene.response, isStreaming: scene.status == "running")
                        }
                    }
                    .padding(24)
                    .frame(width: width, alignment: .leading)
                    .environment(\.conversationTranscriptState, state)
                    .environment(\.dashboardTheme, theme)
                    .environment(\.colorScheme, theme.colorScheme)
                    .background(theme.palette.workspace)
                    let host = NSHostingView(rootView: root)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
                    window.contentView = host
                    host.setFrameSize(NSSize(width: width, height: 900))
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(25))
                    host.layoutSubtreeIfNeeded()
                    let fitting = host.fittingSize
                    #expect(fitting.width.isFinite && fitting.height.isFinite && fitting.height > 100)
                    window.setContentSize(NSSize(width: width, height: min(900, max(200, fitting.height))))
                    host.layoutSubtreeIfNeeded()
                    let nativeText = responseText(in: host).joined(separator: "\n")
                    if scene == .expanded || scene == .trace || scene == .detailTrace {
                        #expect(nativeText.contains("Checking event order"))
                        #expect(!nativeText.contains("**Checking event order**"))
                    }
                    if scene == .settled || scene == .interrupted {
                        #expect(nativeText.contains("The supplied reasoning and tool output remain in order."))
                    }
                    if let output {
                        let rect = NSRect(x: 0, y: 0, width: width, height: min(900, max(200, fitting.height)))
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: rect))
                        host.cacheDisplay(in: rect, to: bitmap)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: output.appending(path: "\(theme.rawValue)-\(Int(width))-\(scene.rawValue).png"))
                    }
                    window.contentView = nil
                    window.close()
                }
            }
        }
    }

    private func responseText(in view: NSView) -> [String] {
        if let text = view as? ConversationResponseNativeTextView { return [text.string] }
        return view.subviews.flatMap { responseText(in: $0) }
    }

    private enum Scene: String, CaseIterable {
        case thinking, tool, expanded, trace, detailTrace, settled, interrupted

        var status: String {
            switch self { case .settled: "completed"; case .interrupted: "cancelled"; default: "running" }
        }
        var response: String {
            switch self {
            case .settled, .interrupted:
                "The supplied reasoning and tool output remain in order.\n\n- Paragraphs stay stable.\n- Native selection spans the complete answer."
            default: ""
            }
        }
        var records: [WorkspaceRunActivityRecord] {
            let trace = "**Checking event order**\n\nI am comparing the supplied reasoning with the tool events.\n\n- Preserve each native part.\n- Keep the final answer after the work.\n\n"
            let reasoning = AgentRunActivity(id: "reasoning", kind: .thought,
                detail: self == .detailTrace ? trace : nil,
                status: self == .trace ? "running" : "completed",
                content: self == .detailTrace ? nil : trace)
            let tool = AgentRunActivity(id: "read", kind: .tool, title: "Read streaming events", status: status == "running" ? "running" : "completed",
                toolName: "read", content: "event-1: reasoning\nevent-2: tool\nevent-3: answer")
            let activities = self == .thinking ? [] : (self == .trace || self == .detailTrace ? [reasoning] : [reasoning, tool])
            return activities.enumerated().map { index, activity in
                .init(id: activity.id, runID: "run", conversationID: "fixture", activity: activity,
                    createdAt: "2026-10-26T12:00:0\(index)Z", sequence: Int64(index))
            }
        }
    }
}
