import AppKit
import SwiftUI
import Vision
import Testing
import WovenMatterCore
@testable import WovenMatterAppFacade

/// Provider-free rendered acceptance scenes. Set WOVENMATTER_STREAMING_SCREENSHOTS
/// to export the actual shared SwiftUI views for visual review.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct StreamingPresentationTests {
    @Test func workActivityUsesStaticIconsInsteadOfBusySpinners() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App/Views")
        for file in ["ConversationWorkTranscript.swift", "ConversationSubagentRow.swift"] {
            let source = try String(contentsOf: views.appending(path: file), encoding: .utf8)
            #expect(!source.contains("ProgressView"), "Work and detail loading must use static icons and text")
        }
    }

    @Test func renderedReasoningOmitsProtocolDumpAndRetainsToolDetails() async throws {
        _ = NSApplication.shared
        let unique = UUID().uuidString
        let state = ConversationTranscriptState()
        state.setExpanded(ConversationTranscriptState.disclosureKey(runID: unique, itemID: "group:tool"), true)
        for id in ["tool"] {
            state.setExpanded(ConversationTranscriptState.disclosureKey(runID: unique, itemID: "activity:" + id), true)
        }
        let activities = [
            AgentRunActivity(id: "thought", kind: .thought, title: "Inspecting result", status: "completed",
                content: "SUPPLIED REASONING VISIBLE", rawInputJSON: #"{"marker":"THOUGHTINPUTDUMP"}"#,
                rawOutputJSON: #"{"marker":"THOUGHTOUTPUTDUMP"}"#,
                rawPayloadJSON: #"{"marker":"THOUGHTEVENTDUMP"}"#),
            AgentRunActivity(id: "empty-thought", kind: .thought, status: "completed",
                rawPayloadJSON: #"{"marker":"EMPTYTHOUGHTDUMP"}"#),
            AgentRunActivity(id: "tool", kind: .tool, title: "Inspect tool details", status: "completed", toolName: "read",
                rawInputJSON: #"{"marker":"TOOLINPUTVISIBLE"}"#,
                rawOutputJSON: #"{"marker":"TOOLOUTPUTVISIBLE"}"#),
        ]
        let records: [WorkspaceRunActivityRecord] = activities.enumerated().map { index, activity in
            .init(id: activity.id, runID: unique, conversationID: unique,
                activity: activity, createdAt: "", sequence: Int64(index))
        }
        let root = ConversationWorkTranscript(run: .init(id: unique, conversationID: unique, status: "running"),
            presentation: .init(startedAt: nil, completedDuration: nil), records: records)
            .environment(\.conversationTranscriptState, state)
            .environment(\.dashboardTheme, .green)
            .environment(\.colorScheme, .light)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.setFrameSize(NSSize(width: 760, height: 700))
        defer { window.contentView = nil; window.close() }
        let rendered = try await settle(host) { responseText(in: host).contains("SUPPLIED REASONING VISIBLE") }
        try #require(rendered)
        try await layoutPasses(host)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let pixels = try #require(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: pixels).perform([request])
        let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        #expect(visible.contains("SUPPLIED REASONING VISIBLE"), "The captured view must include the supplied reasoning")
        #expect(visible.contains("TOOLINPUTVISIBLE") && visible.contains("TOOLOUTPUTVISIBLE"),
            "Tool input/output details must remain visible: \(visible)")
        for marker in ["THOUGHTINPUTDUMP", "THOUGHTOUTPUTDUMP", "THOUGHTEVENTDUMP", "EMPTYTHOUGHTDUMP"] {
            #expect(!visible.contains(marker), "Protocol data leaked into the reasoning disclosure")
        }
        if let directory = ProcessInfo.processInfo.environment["WOVENMATTER_STREAMING_SCREENSHOTS"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appending(path: "reasoning-without-protocol-dump.png"))
        }
    }

    @Test func eventReplayKeepsThoughtsAndAccumulatesLiveToolsBeforeFoldingOnlyPastGroups() async throws {
        _ = NSApplication.shared
        let fixture = EventReplayFixture()
        let state = ConversationTranscriptState()
        let host = NSHostingView(rootView: EventReplayFixtureView(fixture: fixture, state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 1200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.setFrameSize(NSSize(width: 760, height: 1200))
        defer { window.contentView = nil; window.close() }

        fixture.appendThought("first-thought", text: "**FIRST SUPPLIED THOUGHT**")
        let firstThought = try await settle(host) { responseText(in: host).contains("FIRST SUPPLIED THOUGHT") }
        try #require(firstThought, "Supplied thought text must appear without opening a disclosure")
        let markers = ["ALPHA TOOL EVIDENCE", "BETA TOOL EVIDENCE", "GAMMA TOOL EVIDENCE"]
        for (index, marker) in markers.enumerated() {
            fixture.appendTool("tool-\(index)", marker: marker)
            try await layoutPasses(host)
            let visible = try recognizedText(in: host)
            for expected in markers.prefix(index + 1) {
                #expect(visible.contains(expected), "A new tool replaced an earlier live row: \(visible)")
            }
            #expect(responseText(in: host).contains("FIRST SUPPLIED THOUGHT"))
            #expect(scrollViews(in: host).count == 1,
                "The live tool list must grow in the outer transcript, alongside the thought's bounded viewport")
        }

        try exportReplayStage(host, name: "01-live-tools")
        fixture.appendThought("second-thought", text: "**SECOND SUPPLIED THOUGHT**")
        let secondThought = try await settle(host) { responseText(in: host).contains("SECOND SUPPLIED THOUGHT") }
        try #require(secondThought)
        var visible = try recognizedText(in: host)
        #expect(markers.allSatisfy { !visible.contains($0) }, "The prior tool list did not fold at the thought boundary")
        #expect(responseText(in: host).contains("FIRST SUPPLIED THOUGHT"))

        try exportReplayStage(host, name: "02-thought-boundary")
        let priorGroup = ConversationTranscriptState.disclosureKey(runID: "replay-run", itemID: "group:tool-0")
        state.setExpanded(priorGroup, true)
        try await layoutPasses(host)
        visible = try recognizedText(in: host)
        #expect(markers.allSatisfy { visible.contains($0) }, "Reopening the prior tool group lost rows: \(visible)")
        state.setExpanded(priorGroup, false)

        fixture.appendTool("later-a", marker: "DELTA TOOL EVIDENCE")
        fixture.appendTool("later-b", marker: "EPSILON TOOL EVIDENCE")
        try await layoutPasses(host)
        visible = try recognizedText(in: host)
        #expect(visible.contains("DELTA TOOL EVIDENCE") && visible.contains("EPSILON TOOL EVIDENCE"))
        fixture.appendCommentary("COMMENTARY AFTER THE TOOLS")
        let commentary = try await settle(host) { responseText(in: host).contains("COMMENTARY AFTER THE TOOLS") }
        try #require(commentary)
        visible = try recognizedText(in: host)
        #expect(!visible.contains("DELTA TOOL EVIDENCE") && !visible.contains("EPSILON TOOL EVIDENCE"),
            "The prior tool list did not fold at the commentary boundary")

        try exportReplayStage(host, name: "03-commentary-boundary")
        let agentTools = ["ZETA TOOL EVIDENCE", "KAPPA TOOL EVIDENCE"]
        fixture.appendTool("agent-a", marker: agentTools[0])
        fixture.appendTool("agent-b", marker: agentTools[1])
        try await layoutPasses(host)
        visible = try recognizedText(in: host)
        #expect(agentTools.allSatisfy { visible.contains($0) })
        try fixture.appendSubagents()
        try await layoutPasses(host)
        visible = try recognizedText(in: host)
        #expect(agentTools.allSatisfy { !visible.contains($0) }, "The native subagent event did not fold the preceding tools")
        for name in ["ORION REVIEWER", "LYRA RESEARCHER"] {
            #expect(visible.contains(name), "The native subagent name is missing: \(visible)")
        }
        #expect(visible.contains("Working") && visible.contains("Done"), "Subagent statuses must remain visible: \(visible)")
        for thought in ["FIRST SUPPLIED THOUGHT", "SECOND SUPPLIED THOUGHT"] {
            #expect(responseText(in: host).contains(thought), "The subagent event hid a preceding thought")
        }
        try exportReplayStage(host, name: "04-subagent-boundary")

        let finalTools = ["THETA TOOL EVIDENCE", "IOTA TOOL EVIDENCE"]
        fixture.appendTool("final-a", marker: finalTools[0])
        fixture.appendTool("final-b", marker: finalTools[1])
        try await layoutPasses(host)
        visible = try recognizedText(in: host)
        #expect(finalTools.allSatisfy { visible.contains($0) })
        fixture.response = "**STREAMED FOLLOWING RESPONSE**\n\n"
        let responseAppeared = try await settle(host) { responseText(in: host).contains("STREAMED FOLLOWING RESPONSE") }
        try #require(responseAppeared, "The actual following assistant body must render while the run is still running")
        #expect(fixture.status == "running")
        visible = try recognizedText(in: host)
        #expect(finalTools.allSatisfy { !visible.contains($0) }, "The first visible assistant body did not fold tail tools before completion")
        for thought in ["FIRST SUPPLIED THOUGHT", "SECOND SUPPLIED THOUGHT"] {
            #expect(responseText(in: host).contains(thought), "The streamed response hid a preceding thought")
        }
        try exportReplayStage(host, name: "05-streaming-response")

        fixture.status = "completed"
        try await layoutPasses(host)
        let settled = responseText(in: host)
        for text in ["FIRST SUPPLIED THOUGHT", "SECOND SUPPLIED THOUGHT", "COMMENTARY AFTER THE TOOLS", "STREAMED FOLLOWING RESPONSE"] {
            #expect(settled.contains(text), "Completion folded a non-tool event: \(text)")
        }
        #expect(settled.allSatisfy { !$0.contains("**") }, "Supplied thought Markdown was rendered literally")
        visible = try recognizedText(in: host)
        #expect(visible.contains("ORION REVIEWER") && visible.contains("LYRA RESEARCHER"), "Completion hid the native subagents")
        try exportReplayStage(host, name: "06-completed")
        let groups = [
            ("tool-0", markers),
            ("later-a", ["DELTA TOOL EVIDENCE", "EPSILON TOOL EVIDENCE"]),
            ("agent-a", agentTools),
            ("final-a", finalTools),
        ]
        for (index, group) in groups.enumerated() {
            let key = ConversationTranscriptState.disclosureKey(runID: "replay-run", itemID: "group:" + group.0)
            state.setExpanded(key, true)
            try await layoutPasses(host)
            visible = try recognizedText(in: host)
            #expect(group.1.allSatisfy { visible.contains($0) }, "Completion made a prior tool list inaccessible: \(group.0): \(visible)")
            try exportReplayStage(host, name: "07-reopened-\(index)")
            state.setExpanded(key, false)
        }
    }

    @Test func followingResponseReplacesGenericWaitingWithoutHidingToolHistory() async throws {
        _ = NSApplication.shared
        let fixture = EventReplayFixture()
        let state = ConversationTranscriptState()
        let host = NSHostingView(rootView: EventReplayFixtureView(fixture: fixture, state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.setFrameSize(NSSize(width: 760, height: 700))
        defer { window.contentView = nil; window.close() }
        fixture.appendTool("waiting-a", marker: "WAITING FIRST TOOL")
        fixture.appendTool("waiting-b", marker: "WAITING SECOND TOOL")
        try await layoutPasses(host)
        var visible = try recognizedText(in: host)
        #expect(visible.contains("Thinking"), "Completed tail tools must retain a quiet waiting indication before the next event")
        #expect(visible.contains("WAITING FIRST TOOL") && visible.contains("WAITING SECOND TOOL"))
        fixture.response = "THE RESPONSE IS NOW STREAMING\n\n"
        let appeared = try await settle(host) { responseText(in: host).contains("THE RESPONSE IS NOW STREAMING") }
        try #require(appeared)
        #expect(fixture.status == "running")
        visible = try recognizedText(in: host)
        #expect(!visible.contains("Thinking"), "A generic waiting indicator remained above the actual streamed response")
        #expect(!visible.contains("WAITING FIRST TOOL") && !visible.contains("WAITING SECOND TOOL"))
        state.setExpanded(ConversationTranscriptState.disclosureKey(runID: "replay-run", itemID: "group:waiting-a"), true)
        try await layoutPasses(host)
        visible = try recognizedText(in: host)
        #expect(visible.contains("WAITING FIRST TOOL") && visible.contains("WAITING SECOND TOOL"))
        #expect(!visible.contains("Thinking"))
    }

    @Test func boundedReasoningPagesPreserveFenceContextAtBothEdges() throws {
        _ = NSApplication.shared
        for marker in ["```", "~~~~"] {
            let source = marker + "swift\n" + String(repeating: "let earlierValue = 1\n", count: 1_500)
                + "let fencedTail = 2\n" + marker + "\n\nOutside the fenced code."
            let latest = ConversationReasoningPage(text: source, endOffset: source.count, maximumCharacters: 20_000)
            try #require(latest.startOffset > 0)
            let view = ConversationResponseNativeTextView()
            view.apply(content: latest.markdown, document: nil, isStreaming: false)
            for (text, fixedPitch) in [("let fencedTail = 2", true), ("Outside the fenced code.", false)] {
                let range = (view.string as NSString).range(of: text)
                try #require(range.location != NSNotFound, "Bounded reasoning lost \(text)")
                let font = try #require(view.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
                #expect(font.isFixedPitch == fixedPitch, "Fence context styled \(text) incorrectly")
            }
            let earlier = ConversationReasoningPage(text: source, endOffset: latest.startOffset, maximumCharacters: 20_000)
            view.apply(content: earlier.markdown, document: nil, isStreaming: false)
            let code = (view.string as NSString).range(of: "let earlierValue = 1")
            try #require(code.location != NSNotFound)
            let font = try #require(view.textStorage?.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont)
            #expect(font.isFixedPitch, "A page ending inside a fence lost its code styling")
            #expect(!view.string.contains(marker), "Synthetic Markdown fence leaked into visible text")
        }
    }

    @Test func settledReasoningAutomaticallyLoadsDelayedChunksWithoutRetry() async throws {
        _ = NSApplication.shared
        let unique = UUID().uuidString
        let runID = "delayed-run-" + unique
        let activityID = "delayed-thought-" + unique
        let suffix = "Delivered complete reasoning " + unique
        let pendingMessage = "Fixture chunks have not arrived " + unique
        let preview = "A short supplied reasoning preview."
        let full = AgentRunActivity(id: activityID, kind: .thought, status: "completed",
            content: preview + "\n\n" + suffix, detailsAvailable: true, detailVersion: 42)
        let records: [WorkspaceRunActivityRecord] = [
            .init(id: activityID, runID: runID, conversationID: unique,
                activity: .init(id: activityID, kind: .thought, status: "completed",
                    content: preview, detailsAvailable: true, detailVersion: 42), createdAt: "", sequence: 0),
            .init(id: "second-" + unique, runID: runID, conversationID: unique,
                activity: .init(id: "second-" + unique, kind: .thought, status: "completed", content: "A second supplied thought."),
                createdAt: "", sequence: 1),
        ]
        let state = ConversationTranscriptState()
        var requests = 0
        let root = ConversationWorkTranscript(
            run: .init(id: runID, conversationID: unique, status: "completed"),
            presentation: .init(startedAt: nil, completedDuration: "1s"), records: records)
            .environment(\.conversationTranscriptState, state)
            .environment(\.conversationActivityDetails, { requestedRun, requestedActivity in
                #expect(requestedRun == runID && requestedActivity == activityID)
                requests += 1
                if requests == 1 {
                    throw CompanionAPIError(code: "incomplete_activity_details", message: pendingMessage)
                }
                return full
            })
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.setFrameSize(NSSize(width: 600, height: 520))
        defer { window.contentView = nil; window.close() }

        let pending = try await settle(host) { requests == 1 }
        try #require(pending, "The rendered settled disclosure did not request its missing detail")
        if let directory = ProcessInfo.processInfo.environment["WOVENMATTER_STREAMING_SCREENSHOTS"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appending(path: "settled-reasoning-pending-details.png"))
        }
        let complete = try await settle(host) { responseText(in: host).contains(where: { $0.contains(suffix) }) }
        try #require(complete, "Settled disclosure did not automatically replace its preview with the complete trace at the same version")
        #expect(requests == 2)
        try await Task.sleep(for: .milliseconds(650))
        #expect(requests == 2, "Settled complete details continued polling")
        #expect(responseText(in: host).contains(where: { $0.contains(suffix) }),
            "Settled reasoning must remain visible without a disclosure")
    }

    @Test func liveReasoningUsesLoadedDetailsWhenPreviewEndsInsideGrapheme() async throws {
        _ = NSApplication.shared
        for (previewTail, completeTail) in [("👩‍", "👩‍💻"), ("e", "e\u{301}"), ("क", "कि")] {
            let unique = UUID().uuidString
            let runID = "grapheme-run-" + unique
            let activityID = "grapheme-thought-" + unique
            let prefix = "A supplied complete paragraph.\n\n"
            let preview = prefix + previewTail
            let suffix = "Full reasoning suffix " + unique
            let fullText = prefix + completeTail + "\n\n" + suffix + "\n\n"
            try #require(fullText.utf16.starts(with: preview.utf16))
            try #require(!fullText.hasPrefix(preview), "Fixture must end inside an extended grapheme")
            let compact = AgentRunActivity(id: activityID, kind: .thought, status: "running",
                content: preview, detailsAvailable: true)
            let full = AgentRunActivity(id: activityID, kind: .thought, status: "running",
                content: fullText, detailsAvailable: true)
            let state = ConversationTranscriptState()
            var requests = 0
            let root = ConversationWorkTranscript(
                run: .init(id: runID, conversationID: unique, status: "running"),
                presentation: .init(startedAt: nil, completedDuration: nil), records: [
                    .init(id: activityID, runID: runID, conversationID: unique,
                        activity: compact, createdAt: "", sequence: 0),
                ])
                .environment(\.conversationTranscriptState, state)
                .environment(\.conversationActivityDetails, { _, _ in requests += 1; return full })
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.setFrameSize(NSSize(width: 600, height: 520))
            defer { window.contentView = nil; window.close() }
            let delivered = try await settle(host) {
                responseText(in: host).contains(where: { $0.contains(suffix) && $0.contains(completeTail) })
            }
            #expect(requests > 0, "The live disclosure did not load its complete record")
            #expect(delivered, "A preview ending inside a grapheme hid the complete live reasoning suffix")
        }
    }

    @Test func longNativeReasoningDeliversLatestPageWithoutMovingReader() async throws {
        _ = NSApplication.shared
        let fixture = ReasoningScrollFixture()
        fixture.text = (0..<500).map { "Original paragraph \($0) preserves a detailed supplied reasoning trace.\n\n" }.joined()
        try #require(fixture.text.count > 20_000)
        let state = ConversationTranscriptState()
        let host = NSHostingView(rootView: ReasoningScrollFixtureView(fixture: fixture, state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.setFrameSize(NSSize(width: 600, height: 520))
        defer { window.contentView = nil; window.close() }
        let found = try await settle(host) { scrollViews(in: host).count == 1 }
        try #require(found)
        let scroll = try #require(scrollViews(in: host).first)
        let overflowing = try await settle(host) { metrics(scroll).maximumOffset > 200 }
        try #require(overflowing)
        move(scroll, toOffset: metrics(scroll).maximumOffset)
        let bottom = try await settle(host) { metrics(scroll).distanceFromBottom <= 4 }
        try #require(bottom)
        let suffix = "Latest live reasoning suffix " + UUID().uuidString
        fixture.text += suffix + "\n\n"
        let delivered = try await settle(host) {
            responseText(in: host).contains(where: { $0.contains(suffix) }) && metrics(scroll).distanceFromBottom <= 4
        }
        #expect(delivered, "Reasoning beyond 20k stopped delivering/following the live suffix: \(metrics(scroll))")
        #expect(responseText(in: host).allSatisfy { $0.count <= 20_000 }, "Long reasoning rendered an unbounded native text surface")

        move(scroll, toOffset: 120)
        let reading = try await settle(host) { abs(metrics(scroll).offset - 120) <= 4 }
        try #require(reading)
        let before = responseText(in: host)
        fixture.text += "A newer paragraph must not replace the reader's current page.\n\n"
        try await layoutPasses(host)
        #expect(abs(metrics(scroll).offset - 120) <= 4, "Long live reasoning moved a reader above the live edge")
        #expect(responseText(in: host) == before, "A growing tail replaced the page being read")

        // Crossing the first page limit while reading must retain the entire
        // previously rendered page, not an old offset from the last edge visit.
        fixture.text = (0..<280).map { "Threshold paragraph \($0) preserves the reader's existing reasoning.\n\n" }.joined()
        try #require(fixture.text.count < 20_000)
        let reset = try await settle(host) { responseText(in: host).contains(where: { $0.contains("Threshold paragraph 279") }) }
        try #require(reset)
        move(scroll, toOffset: 120)
        let thresholdReading = try await settle(host) { abs(metrics(scroll).offset - 120) <= 4 }
        try #require(thresholdReading)
        let thresholdPage = responseText(in: host)
        fixture.text += String(repeating: "New reasoning after the first page threshold.\n\n", count: 100)
        try #require(fixture.text.count > 20_000)
        try await layoutPasses(host)
        #expect(responseText(in: host) == thresholdPage, "Crossing 20k replaced the page being read")
        #expect(abs(metrics(scroll).offset - 120) <= 4, "Crossing 20k moved the reader")
    }

    @Test func nativeReasoningScrollFollowsParagraphsWithoutMovingReadersOrCorrections() async throws {
        _ = NSApplication.shared
        let fixture = ReasoningScrollFixture()
        let state = ConversationTranscriptState()
        let host = NSHostingView(rootView: ReasoningScrollFixtureView(fixture: fixture, state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.setFrameSize(NSSize(width: 600, height: 520))
        defer { window.contentView = nil; window.close() }

        let found = try await settle(host) { scrollViews(in: host).count == 1 }
        try #require(found, "Production reasoning trace did not expose exactly one native NSScrollView")
        let scroll = try #require(scrollViews(in: host).first)
        let overflowing = try await settle(host) { metrics(scroll).maximumOffset > 200 }
        try #require(overflowing, "Reasoning fixture must overflow the real bounded work list")
        move(scroll, toOffset: metrics(scroll).maximumOffset)
        let reachedBottom = try await settle(host) { metrics(scroll).distanceFromBottom <= 4 }
        try #require(reachedBottom, "Could not position the owned reasoning trace at its live edge")
        let beforeAppend = metrics(scroll)
        fixture.appendParagraph()
        let followed = try await settle(host) {
            metrics(scroll).height > beforeAppend.height + 8 && metrics(scroll).distanceFromBottom <= 4
        }
        #expect(followed, "A streamed reasoning paragraph did not follow: before=\(beforeAppend), after=\(metrics(scroll))")

        move(scroll, toOffset: 120)
        let reading = try await settle(host) { abs(metrics(scroll).offset - 120) <= 4 }
        try #require(reading, "Could not position the owned reasoning trace above its live edge")
        let beforeReadingAppend = metrics(scroll)
        fixture.appendParagraph()
        let appendedWhileReading = try await settle(host) { metrics(scroll).height > beforeReadingAppend.height + 8 }
        try #require(appendedWhileReading, "The observable fixture did not render a new reasoning paragraph")
        try await layoutPasses(host)
        #expect(abs(metrics(scroll).offset - beforeReadingAppend.offset) <= 4,
            "Streaming reasoning moved a reader above the live edge: before=\(beforeReadingAppend), after=\(metrics(scroll))")

        // A longer replacement must not be mistaken for an append even when
        // the reader was previously at the bottom of the original trace.
        move(scroll, toOffset: metrics(scroll).maximumOffset)
        let bottomBeforeCorrection = try await settle(host) { metrics(scroll).distanceFromBottom <= 4 }
        try #require(bottomBeforeCorrection)
        let beforeCorrection = metrics(scroll)
        fixture.replaceTrace()
        let corrected = try await settle(host) { metrics(scroll).height > beforeCorrection.height + 8 }
        try #require(corrected, "Correction fixture must increase rendered height to exercise follow suppression")
        try await layoutPasses(host)
        #expect(abs(metrics(scroll).offset - beforeCorrection.offset) <= 4,
            "A reasoning replacement was followed as an append: before=\(beforeCorrection), after=\(metrics(scroll))")
    }

    @Test func liveReasoningRemountPreservesBottomIntentAndReadingPosition() async throws {
        _ = NSApplication.shared
        for wasAtBottom in [true, false] {
            let fixture = ReasoningScrollFixture()
            let state = ConversationTranscriptState()
            let host = NSHostingView(rootView: ReasoningScrollFixtureView(fixture: fixture, state: state))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.setFrameSize(NSSize(width: 600, height: 520))
            defer { window.contentView = nil; window.close() }
            let found = try await settle(host) { scrollViews(in: host).count == 1 }
            try #require(found)
            var scroll = try #require(scrollViews(in: host).first)
            let overflowing = try await settle(host) { metrics(scroll).maximumOffset > 200 }
            try #require(overflowing)
            let target = wasAtBottom ? metrics(scroll).maximumOffset : 120
            move(scroll, toOffset: target)
            let positioned = try await settle(host) { abs(metrics(scroll).offset - target) <= 4 }
            try #require(positioned)
            let prior = metrics(scroll)
            fixture.isMounted = false
            let disappeared = try await settle(host) { scrollViews(in: host).isEmpty }
            try #require(disappeared)
            let key = ConversationTranscriptState.disclosureKey(runID: "reasoning-run", itemID: "thinking:thought")
            let saved = state.workScrollSnapshot(key)
            #expect(saved.isAtBottom == wasAtBottom)
            #expect(abs(saved.offset - prior.offset) <= 4)
            for _ in 0..<8 { fixture.appendParagraph() }
            fixture.isMounted = true
            let reappeared = try await settle(host) { scrollViews(in: host).count == 1 }
            try #require(reappeared)
            scroll = try #require(scrollViews(in: host).first)
            let restored = try await settle(host) {
                metrics(scroll).height > prior.height + 8 && (wasAtBottom
                    ? metrics(scroll).distanceFromBottom <= 4
                    : abs(metrics(scroll).offset - prior.offset) <= 4)
            }
            #expect(restored, "Remount lost the reader's bottom intent: bottom=\(wasAtBottom), before=\(prior), after=\(metrics(scroll))")
            let beforeAppend = metrics(scroll)
            fixture.appendParagraph()
            let appended = try await settle(host) {
                metrics(scroll).height > beforeAppend.height + 8 && (wasAtBottom
                    ? metrics(scroll).distanceFromBottom <= 4
                    : abs(metrics(scroll).offset - prior.offset) <= 4)
            }
            #expect(appended, "The remounted trace followed the wrong reading intent: bottom=\(wasAtBottom), actual=\(metrics(scroll))")
        }
    }

    @Test func historicalWorkScrollPreservesReadingPositionAcrossUpdatesAndReopening() async throws {
        _ = NSApplication.shared
        let fixture = WorkScrollFixture()
        let state = ConversationTranscriptState()
        let key = ConversationTranscriptState.disclosureKey(runID: "scroll-run", itemID: "group:tool-0")
        state.setExpanded(key, true)
        let host = NSHostingView(rootView: WorkScrollFixtureView(fixture: fixture, state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.setFrameSize(NSSize(width: 600, height: 520))
        defer { window.contentView = nil; window.close() }

        let found = try await settle(host) { scrollViews(in: host).count == 1 }
        try #require(found, "Production work list did not expose exactly one native NSScrollView")
        var scroll = try #require(scrollViews(in: host).first)
        let overflowing = try await settle(host) { metrics(scroll).maximumOffset > 200 }
        try #require(overflowing, "Fixture must overflow the real bounded work list")

        move(scroll, toOffset: metrics(scroll).maximumOffset)
        let reachedBottom = try await settle(host) { metrics(scroll).distanceFromBottom <= 4 }
        try #require(reachedBottom, "Could not position the owned work list at its live edge")
        let beforeAppend = metrics(scroll)
        fixture.appendTool()
        let appended = try await settle(host) { metrics(scroll).height > beforeAppend.height + 8 }
        try #require(appended)
        #expect(abs(metrics(scroll).offset - beforeAppend.offset) <= 4,
            "A historical tool correction moved the reader: before=\(beforeAppend), after=\(metrics(scroll))")

        move(scroll, toOffset: 120)
        let reading = try await settle(host) {
            abs(metrics(scroll).offset - 120) <= 4 && metrics(scroll).distanceFromBottom > 100
        }
        try #require(reading, "Could not position the owned work list above its live edge")
        let beforeReadingAppend = metrics(scroll)
        fixture.appendTool()
        let appendedWhileReading = try await settle(host) { metrics(scroll).height > beforeReadingAppend.height + 8 }
        try #require(appendedWhileReading, "The observable fixture did not append a rendered tool row")
        try await layoutPasses(host)
        #expect(abs(metrics(scroll).offset - beforeReadingAppend.offset) <= 4,
            "Appending a tool moved the reader: before=\(beforeReadingAppend), after=\(metrics(scroll))")

        let beforeStatus = metrics(scroll)
        fixture.changeStatus(of: 5, to: "failed")
        try await layoutPasses(host)
        #expect(abs(metrics(scroll).offset - beforeStatus.offset) <= 4,
            "A tool status update moved the reader: before=\(beforeStatus), after=\(metrics(scroll))")

        let savedOffset = metrics(scroll).offset
        state.setExpanded(key, false)
        let collapsed = try await settle(host) { scrollViews(in: host).isEmpty }
        try #require(collapsed, "Closing the work disclosure left its scroll view mounted")
        state.setExpanded(key, true)
        let reopened = try await settle(host) { scrollViews(in: host).count == 1 }
        try #require(reopened, "Reopening the work disclosure did not recreate its native scroll view")
        scroll = try #require(scrollViews(in: host).first)
        let restored = try await settle(host) { abs(metrics(scroll).offset - savedOffset) <= 4 }
        #expect(restored, "Disclosure reopening lost the reading offset: expected=\(savedOffset), actual=\(metrics(scroll))")
    }

    @Test func sharedTranscriptRendersLiveExpandedSettledAndInterruptedWork() async throws {
        _ = NSApplication.shared
        let output = ProcessInfo.processInfo.environment["WOVENMATTER_STREAMING_SCREENSHOTS"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for theme in DashboardTheme.allCases {
            for width: CGFloat in [380, 760] {
                for scene in Scene.allCases {
                    let state = ConversationTranscriptState()
                    state.setExpanded(ConversationTranscriptState.disclosureKey(runID: "run", itemID: "group:read"),
                        scene == .expanded)
                    let records = scene.records
                    let root = VStack(alignment: .leading, spacing: 18) {
                        ConversationUserBubble(content: "Compare the streaming events and verify the result.") { EmptyView() }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        ConversationWorkTranscript(
                            run: .init(id: "run", conversationID: "fixture", status: scene.status),
                            presentation: .init(startedAt: Date().addingTimeInterval(-12), completedDuration: "12s"),
                            records: records, hasFollowingResponse: !scene.response.isEmpty)
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
                    var fitting = host.fittingSize
                    #expect(fitting.width.isFinite && fitting.height.isFinite && fitting.height > 100)
                    // Native text measurement and lazy work-list geometry can
                    // settle on consecutive layout passes after disclosure.
                    for _ in 0..<3 {
                        window.setContentSize(NSSize(width: width, height: min(900, max(200, fitting.height))))
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(25))
                        fitting = host.fittingSize
                    }
                    let nativeText = responseText(in: host).joined(separator: "\n")
                    if scene.records.contains(where: { $0.activity.kind == .thought }) {
                        #expect(nativeText.contains("Checking event order"))
                        #expect(!nativeText.contains("**Checking event order**"))
                        #expect(nativeText.contains("Keep the final answer after the work."))
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

    private func exportReplayStage(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["WOVENMATTER_STREAMING_REPLAY_SCREENSHOTS"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appending(path: name + ".png"))
    }

    private func recognizedText(in host: NSView) throws -> String {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func responseText(in view: NSView) -> [String] {
        if let text = view as? ConversationResponseNativeTextView { return [text.string] }
        return view.subviews.flatMap { responseText(in: $0) }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }

    private struct ScrollMetrics: CustomStringConvertible {
        let height: CGFloat
        let maximumOffset: CGFloat
        let offset: CGFloat
        var distanceFromBottom: CGFloat { maximumOffset - offset }
        var description: String { "height=\(height), offset=\(offset), maximum=\(maximumOffset)" }
    }

    private func metrics(_ scroll: NSScrollView) -> ScrollMetrics {
        let document = scroll.documentView!
        let visible = scroll.documentVisibleRect
        let offset = document.isFlipped ? visible.minY - document.bounds.minY : document.bounds.maxY - visible.maxY
        return ScrollMetrics(height: document.bounds.height,
            maximumOffset: max(0, document.bounds.height - visible.height), offset: max(0, offset))
    }

    /// Only the test's own native clip view is moved; no global events or input.
    private func move(_ scroll: NSScrollView, toOffset offset: CGFloat) {
        let document = scroll.documentView!
        let bounded = min(max(0, offset), metrics(scroll).maximumOffset)
        let y = document.isFlipped ? document.bounds.minY + bounded
            : document.bounds.maxY - scroll.contentView.bounds.height - bounded
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func settle(_ host: NSView, until condition: () -> Bool) async throws -> Bool {
        // Require several consecutive observations so a pre-update layout
        // cannot satisfy a condition before SwiftUI processes geometry changes.
        var consecutive = 0
        for _ in 0..<80 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
            host.layoutSubtreeIfNeeded()
            consecutive = condition() ? consecutive + 1 : 0
            if consecutive == 4 { return true }
        }
        return false
    }

    private func layoutPasses(_ host: NSView) async throws {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        host.layoutSubtreeIfNeeded()
    }

    @MainActor private final class EventReplayFixture: ObservableObject {
        @Published var records: [WorkspaceRunActivityRecord] = []
        @Published var status = "running"
        @Published var commentaryIDs: Set<String> = []
        @Published var response = ""

        func appendThought(_ id: String, text: String) {
            append(.init(id: id, kind: .thought, status: "completed", content: text))
        }
        func appendTool(_ id: String, marker: String) {
            append(.init(id: id, kind: .tool, title: "Read fixture file", status: "completed",
                toolName: "read", content: marker))
        }
        func appendCommentary(_ text: String) {
            let id = "commentary"
            commentaryIDs.insert(id)
            append(.init(id: id, kind: .assistant, status: "completed", content: text))
        }
        func appendSubagents() throws {
            let snapshot = Data(#"[{"id":"orion","name":"ORION REVIEWER","state":"running"},{"id":"lyra","name":"LYRA RESEARCHER","state":"completed"}]"#.utf8)
            let children = try JSONDecoder().decode([AgentRunSubagent].self, from: snapshot)
            append(.init(id: "native-agents", kind: .activity, status: "running", subagents: children))
        }
        private func append(_ activity: AgentRunActivity) {
            records.append(.init(id: activity.id, runID: "replay-run", conversationID: "replay-chat",
                activity: activity, createdAt: "2026-10-27T00:00:00Z", sequence: Int64(records.count)))
        }
    }

    @MainActor private struct EventReplayFixtureView: View {
        @ObservedObject var fixture: EventReplayFixture
        let state: ConversationTranscriptState
        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                ConversationWorkTranscript(
                    run: .init(id: "replay-run", conversationID: "replay-chat", status: fixture.status),
                    presentation: .init(startedAt: nil, completedDuration: "1s"), records: fixture.records,
                    commentaryIDs: fixture.commentaryIDs, hasFollowingResponse: !fixture.response.isEmpty)
                if !fixture.response.isEmpty {
                    ConversationResponse(content: fixture.response, isStreaming: fixture.status == "running")
                }
            }
                .environment(\.conversationTranscriptState, state)
                .environment(\.dashboardTheme, .green)
                .environment(\.colorScheme, .light)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.white)
        }
    }

    @MainActor private final class WorkScrollFixture: ObservableObject {
        @Published var records: [WorkspaceRunActivityRecord] = (0..<28).map { record($0) }

        func appendTool() { records.append(Self.record(records.count)) }

        func changeStatus(of index: Int, to status: String) {
            records[index] = Self.record(index, status: status)
        }

        private static func record(_ index: Int, status: String = "completed") -> WorkspaceRunActivityRecord {
            .init(id: "tool-\(index)", runID: "scroll-run", conversationID: "scroll-fixture",
                activity: .init(id: "tool-\(index)", kind: .tool,
                    title: "Read fixture file \(index)", status: status, toolName: "read"),
                createdAt: "2026-10-27T00:00:00Z", sequence: Int64(index))
        }
    }

    @MainActor private struct WorkScrollFixtureView: View {
        @ObservedObject var fixture: WorkScrollFixture
        let state: ConversationTranscriptState

        var body: some View {
            ConversationWorkTranscript(
                run: .init(id: "scroll-run", conversationID: "scroll-fixture", status: "completed"),
                presentation: .init(startedAt: nil, completedDuration: nil), records: fixture.records)
                .environment(\.conversationTranscriptState, state)
                .environment(\.dashboardTheme, DashboardTheme.dark)
                .environment(\.colorScheme, .dark)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @MainActor private final class ReasoningScrollFixture: ObservableObject {
        @Published var isMounted = true
        @Published var text = (0..<28).map { "Original paragraph \($0) describes the supplied reasoning clearly.\n\n" }.joined()
        private var nextParagraph = 28

        func appendParagraph() {
            text += "Original paragraph \(nextParagraph) continues the supplied reasoning clearly.\n\n"
            nextParagraph += 1
        }

        func replaceTrace() {
            text = "A corrected opening introduces the revised reasoning.\n\n"
                + text.replacingOccurrences(of: "Original", with: "Revised")
                + "A corrected conclusion closes the replacement trace.\n\n"
        }

        var records: [WorkspaceRunActivityRecord] {
            [.init(id: "thought", runID: "reasoning-run", conversationID: "reasoning-fixture",
                activity: .init(id: "thought", kind: .thought, status: "running",
                    content: text),
                createdAt: "2026-10-27T00:00:00Z", sequence: 0)]
        }
    }

    @MainActor private struct ReasoningScrollFixtureView: View {
        @ObservedObject var fixture: ReasoningScrollFixture
        let state: ConversationTranscriptState

        var body: some View {
            Group {
                if fixture.isMounted {
                    ConversationWorkTranscript(
                        run: .init(id: "reasoning-run", conversationID: "reasoning-fixture", status: "running"),
                        presentation: .init(startedAt: nil, completedDuration: nil), records: fixture.records)
                        .environment(\.conversationTranscriptState, state)
                        .environment(\.dashboardTheme, DashboardTheme.dark)
                        .environment(\.colorScheme, .dark)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private enum Scene: String, CaseIterable {
        case thinking, tool, expanded, trace, detailTrace, settled, interrupted
        case piSearch, piBrowser, piCommand, piThoughtAfterFailure, piSettledThoughtAfterFailure

        var status: String {
            switch self { case .settled, .piSettledThoughtAfterFailure: "completed"; case .interrupted: "cancelled"; default: "running" }
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
            let activities: [AgentRunActivity]
            switch self {
            case .piSearch, .piBrowser, .piCommand, .piThoughtAfterFailure, .piSettledThoughtAfterFailure:
                // Recorded live Pi shapes, with synthetic input values. The
                // transport category is not the actual tool identity.
                let failed = AgentRunActivity(id: "search", kind: .tool, title: "web_search",
                    status: "failed", toolName: "other", rawInputJSON: #"{"query":"native event ordering"}"#)
                switch self {
                case .piSearch:
                    activities = [AgentRunActivity(id: "search", kind: .tool, title: "web_search",
                        status: "running", toolName: "other", rawInputJSON: #"{"query":"native event ordering"}"#)]
                case .piBrowser:
                    activities = [failed, AgentRunActivity(id: "browser", kind: .tool, title: "woven_browser_use",
                        status: "running", toolName: "other", rawInputJSON: #"{"action":"open","url":"https://example.com"}"#)]
                case .piCommand:
                    activities = [failed, AgentRunActivity(id: "command", kind: .tool, title: "bash",
                        status: "running", toolName: "execute", rawInputJSON: #"{"command":"curl https://example.com"}"#)]
                default: activities = [failed, reasoning]
                }
            default:
                activities = self == .thinking ? [] : (self == .trace || self == .detailTrace ? [reasoning] : [reasoning, tool])
            }
            return activities.enumerated().map { index, activity in
                .init(id: activity.id, runID: "run", conversationID: "fixture", activity: activity,
                    createdAt: "2026-10-26T12:00:0\(index)Z", sequence: Int64(index))
            }
        }
    }
}
