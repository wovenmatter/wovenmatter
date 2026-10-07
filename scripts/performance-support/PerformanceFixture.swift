
// Appended only to a disposable profiling copy of ApplicationModel.swift.
// Same-file extension permits the fixture to exercise production view/model
// paths without widening access or shipping a diagnostic startup mode.
#if DEBUG
extension ApplicationModel {
    func runPerformanceFixtureStream() async {
        guard let store = dashboardStore else { return }
        do {
            let device = try await store.dashboardDeviceID()
            let conversation = try await store.database.createLocalACPSession(runtimeKind: .codex,
                title: "00 Streaming fixture", ownerDeviceID: device)
            let run = try await store.database.beginLocalACPRun(conversationID: conversation,
                content: "Stream a synthetic report while I use the workspace.")
            localRunningConversationIDs.insert(conversation)
            await refreshWorkspace()
            for index in 0..<300 {
                try await Task.sleep(for: .milliseconds(50))
                try await Task.detached {
                    try await store.database.appendLocalACPAssistantChunk(runID: run.runID,
                        chunk: index.isMultiple(of: 10)
                            ? "\n\n### Update \(index / 10)\n\n"
                            : "Synthetic **streaming** content \(index). ")
                    let group = index / 10
                    if index.isMultiple(of: 10) {
                        try await store.database.recordAssistantStreamBoundary(runID: run.runID)
                        try await store.database.upsertDeviceOwnedRunActivity(runID: run.runID,
                            activity: AgentRunActivity(id: "stream-tool-\(group)", kind: .tool,
                                phase: "start", title: "Check \(group)", status: "running", toolName: "read_file"))
                        try await store.database.upsertDeviceOwnedRunActivity(runID: run.runID,
                            activity: PerformanceFixtureActivities.checklist(step: group))
                    }
                    // Grow one thought per work group, retaining earlier groups
                    // unchanged while the current item receives deltas.
                    try await store.database.upsertDeviceOwnedRunActivity(runID: run.runID,
                        activity: AgentRunActivity(id: "stream-thought-\(group)", kind: .thought,
                            title: "Reasoning \(group)", content: String(repeating: "Inspect café 🧵 \(index). ", count: 64),
                            contentIsDelta: true))
                    if index % 10 == 9 {
                        let output = PerformanceFixtureActivities.output(item: group)
                        try await store.database.upsertDeviceOwnedRunActivity(runID: run.runID,
                            activity: AgentRunActivity(id: "stream-tool-\(group)", kind: .tool,
                                phase: "result", status: "completed", content: output,
                                rawOutputJSON: String(decoding: try JSONEncoder().encode(["output": output]), as: UTF8.self)))
                    }
                    if index.isMultiple(of: 30) {
                        try await store.database.upsertDeviceOwnedRunActivity(runID: run.runID,
                            activity: try PerformanceFixtureActivities.subagents(step: group))
                    }
                }.value
                enqueueConversationChange(.init(conversationID: conversation, runID: run.runID, phase: .content))
            }
            try await store.database.recordAssistantStreamBoundary(runID: run.runID)
            try await store.database.upsertDeviceOwnedRunActivity(runID: run.runID,
                activity: PerformanceFixtureActivities.checklist(step: 30))
            try await store.database.upsertDeviceOwnedRunActivity(runID: run.runID,
                activity: try PerformanceFixtureActivities.subagents(step: 30))
            try await store.database.appendLocalACPAssistantChunk(runID: run.runID,
                chunk: "\n\nCompleted the offline report. All 30 checks finished.\n")
            try await store.database.recordAssistantStreamBoundary(runID: run.runID, finalSegment: true)
            try await store.database.completeLocalACPRun(runID: run.runID)
            localRunningConversationIDs.remove(conversation)
            // Content refresh exercises the production coalescing/refresh path.
            // Terminal database state is real. The .terminal notification also
            // starts provider metadata/usage work, so retain offline .content
            // invalidation and an explicit workspace refresh for presentation.
            enqueueConversationChange(.init(conversationID: conversation, runID: run.runID, phase: .content))
            await refreshWorkspace()
            NSLog("PERFORMANCE STREAM COMPLETE conversation=%@", conversation)
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func startPerformanceFixture(heavy: Bool) async {
        do {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "wovenmatter-performance-fixture-" + UUID().uuidString)
            let store = try await DashboardStore(supportDirectory: root)
            dashboardStore = store
            lastOpenClawCronRefresh = .distantFuture
            lastHermesCronRefresh = .distantFuture
            enabledLocalACPRuntimeKinds = []
            shownLocalACPRuntimeKinds = [.codex]
            titleGenerationSettings.isEnabled = false
            let journal = DashboardNoteDraftJournal(fileURL: root.appending(path: "drafts.ndjson"))
            noteWriteBehind = DashboardNoteWriteBehind(journal: journal, update: { [database = store.database] entry in
                try await database.persistNoteDraft(id: entry.noteID, title: entry.title, content: entry.content,
                    folderID: entry.folderID, createdAt: entry.createdAt)
            }, completion: { [weak self] entry, result in
                Task { @MainActor [weak self] in await self?.completeNoteWrite(entry, result: result) }
            })
            try await store.prepareLocalWorkspace()
            let deviceID = try await store.dashboardDeviceID()
            try await Task.detached {
                let database = store.database
                let origin = Date(timeIntervalSince1970: 1_780_000_000)
                let short = "A short **formatted** answer with a `code` span.\n\n- First item\n- Second item"
                let long = (0..<60).map { "## Section \($0)\n\nA paragraph with **emphasis**, `code`, and several lines of readable text.\n\n```swift\nlet value = \($0)\n```" }.joined(separator: "\n\n")
                for index in 0..<(heavy ? 1000 : 12) {
                    let title: String
                    switch index {
                    case 0: title = "01 Short conversation"
                    case 1: title = "02 Long conversation"
                    case 2: title = "03 Activity conversation"
                    case 3: title = "04 Failed conversation"
                    case 4: title = "05 Cancelled conversation"
                    default: title = String(format: "Chat %04d", index)
                    }
                    let conversation = try await database.createLocalACPSession(runtimeKind: .codex, title: title,
                        ownerDeviceID: deviceID, createdAt: origin.addingTimeInterval(Double(-index * 1000)))
                    for turn in 0..<(index == 1 ? 120 : 2) {
                        let date = origin.addingTimeInterval(Double(-index * 1000 + turn * 3))
                        let run = try await database.beginLocalACPRun(conversationID: conversation,
                            content: "Please summarize item \(turn).", createdAt: date)
                        if index == 2 {
                            for activity in 0..<(heavy ? 200 : 8) {
                                if activity.isMultiple(of: 4) {
                                    try await database.appendLocalACPAssistantChunk(runID: run.runID,
                                        chunk: "\nChecking group \(activity / 4): café 🧵.\n", updatedAt: date.addingTimeInterval(1))
                                    try await database.recordAssistantStreamBoundary(runID: run.runID, updatedAt: date.addingTimeInterval(1))
                                }
                                let output = PerformanceFixtureActivities.output(item: activity)
                                try await database.upsertDeviceOwnedRunActivity(runID: run.runID,
                                    activity: AgentRunActivity(id: "tool-\(activity)", kind: .tool,
                                        phase: "result", title: "Read source \(activity)", status: "completed",
                                        toolName: "read_file", content: output,
                                        rawOutputJSON: String(decoding: try JSONEncoder().encode(["output": output]), as: UTF8.self)),
                                    updatedAt: date.addingTimeInterval(1))
                            }
                            try await database.upsertDeviceOwnedRunActivity(runID: run.runID,
                                activity: PerformanceFixtureActivities.checklist(step: 30), updatedAt: date.addingTimeInterval(1))
                            try await database.upsertDeviceOwnedRunActivity(runID: run.runID,
                                activity: try PerformanceFixtureActivities.subagents(step: 30), updatedAt: date.addingTimeInterval(1))
                        }
                        try await database.appendLocalACPAssistantChunk(runID: run.runID,
                            chunk: index == 1 && turn == 119 ? long : short, updatedAt: date.addingTimeInterval(1))
                        try await database.recordAssistantStreamBoundary(runID: run.runID,
                            finalSegment: true, updatedAt: date.addingTimeInterval(1))
                        // Separate terminal examples use the same persistence
                        // APIs without admitting a provider request.
                        if index == 3 {
                            try await database.completeLocalACPRun(runID: run.runID,
                                error: "Synthetic tool failure", completedAt: date.addingTimeInterval(2))
                        } else if index == 4 {
                            try await database.cancelLocalACPRun(runID: run.runID, completedAt: date.addingTimeInterval(2))
                        } else {
                            try await database.completeLocalACPRun(runID: run.runID, completedAt: date.addingTimeInterval(2))
                        }
                    }
                }
                let documents: [(String, NoteDocument)] = [
                    ("01 Short note", NoteDocument(blocks: [.richText(NoteRichTextBlock(text: "A short note for everyday editing."))])),
                    ("02 Long note", NoteDocument(blocks: (0..<(heavy ? 300 : 30)).map {
                        .richText(NoteRichTextBlock(text: "Paragraph \($0). A synthetic note with enough text to exercise scrolling, selection, and editing."))
                    })),
                    ("03 Spreadsheet", NoteDocument(kind: .spreadsheet, blocks: [.table(NoteTableBlock(rows: heavy ? 100 : 20, columns: 8, headerRow: true))])),
                    ("04 HTML artifact", NoteDocument(kind: .html, html: "<html><body><h1>Fixture report</h1><p>Offline HTML preview.</p></body></html>")),
                ]
                for index in 0..<(heavy ? 120 : 8) {
                    let entry = documents[index % documents.count]
                    _ = try await database.createNote(folderID: nil,
                        title: index < 4 ? entry.0 : "Note \(index)", content: try entry.1.encoded(),
                        createdAt: origin.addingTimeInterval(Double(-index)))
                }
            }.value
            apply(try await store.snapshot())
            state = .ready
            PerformanceFixtureResponsiveness.start()
            let metadata: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "workload": heavy ? "heavy" : "light", "databaseRoot": root.path,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "readyAt": Date().timeIntervalSince1970,
            ]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: PerformanceFixtureEnvironment.evidenceDirectory
                    .appending(path: "fixture-\(ProcessInfo.processInfo.processIdentifier).json"))
            NSLog("PERFORMANCE FIXTURE READY workload=%@ root=%@", heavy ? "heavy" : "light", root.path)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private enum PerformanceFixtureActivities {
    nonisolated static func output(item: Int) -> String {
        String(repeating: "Synthetic output \(item): readable text with café 🧵 and a long tool result.\n", count: 1_024)
    }

    nonisolated static func checklist(step: Int) -> AgentRunActivity {
        AgentRunActivity(id: "fixture-checklist", kind: .plan, title: "Offline checks",
            status: step >= 30 ? "completed" : "running",
            planEntries: ["Inspect", "Compare", "Verify"].enumerated().map { index, content in
                AgentRunPlanEntry(content: content,
                    status: step >= (index + 1) * 10 ? "completed" : step >= index * 10 ? "in_progress" : "pending")
            })
    }

    nonisolated static func subagents(step: Int) throws -> AgentRunActivity {
        let history: [[String: String]] = [
            ["id": "child-plan", "kind": "plan", "title": "Child checklist", "content": "Inspect child files only", "status": step >= 30 ? "completed" : "running"],
            ["id": "child-tool", "kind": "tool", "title": "Read child source", "content": output(item: step), "status": "completed"],
        ]
        let json = try JSONSerialization.data(withJSONObject: ["subagents": [
            ["id": "fixture-reviewer", "name": "Reviewer", "task": "Review the synthetic report",
             "state": step >= 30 ? "completed" : "running", "history": history],
            ["id": "fixture-researcher", "name": "Researcher", "task": "Inspect fixture evidence",
             "state": "completed", "result": "Offline evidence checked", "history": history],
        ]])
        guard let activity = AgentRunActivity.builtInSubagentSnapshot(rawPayloadJSON: String(decoding: json, as: UTF8.self)) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return activity
    }
}

/// Measures main-run-loop scheduling delay, independently of automation/tool
/// latency. This is diagnostic overhead shared by both sides of a comparison.
@MainActor
private enum PerformanceFixtureResponsiveness {
    static var timer: Timer?
    static var previous = ProcessInfo.processInfo.systemUptime
    static let queue = DispatchQueue(label: "performance-fixture.trace")

    static func start() {
        let path = PerformanceFixtureEnvironment.evidenceDirectory
            .appending(path: "trace-\(ProcessInfo.processInfo.processIdentifier).csv").path
        FileManager.default.createFile(atPath: path, contents: Data("uptime,delay_ms\n".utf8))
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        _ = try? handle.seekToEnd()
        previous = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.016, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                let delay = max(0, now - previous - 0.016) * 1000
                previous = now
                let line = "\(now),\(delay)\n"
                queue.async { try? handle.write(contentsOf: Data(line.utf8)) }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        NSLog("PERFORMANCE TRACE %@", path)
    }
}
#endif
