
// Appended only to a disposable profiling copy of ApplicationModel.swift.
// Same-file extension permits the fixture to exercise production view/model
// paths without widening access or shipping a diagnostic startup mode.
#if DEBUG
extension ApplicationModel {
    func runPerformanceFixtureStream() async {
        guard let store = dashboardStore else { return }
        do {
            let device = try await store.dashboardDeviceID()
            let conversation = try store.database.createLocalACPSession(runtimeKind: .codex,
                title: "00 Streaming fixture", ownerDeviceID: device)
            let run = try store.database.beginLocalACPRun(conversationID: conversation,
                content: "Stream a synthetic report while I use the workspace.")
            localRunningConversationIDs.insert(conversation)
            await refreshWorkspace()
            for index in 0..<300 {
                try await Task.sleep(for: .milliseconds(50))
                try await Task.detached {
                    try store.database.appendLocalACPAssistantChunk(runID: run.runID,
                        chunk: index.isMultiple(of: 10)
                            ? "\n\n### Update \(index / 10)\n\n"
                            : "Synthetic **streaming** content \(index). ")
                    if index.isMultiple(of: 10) {
                        try store.database.recordAssistantStreamBoundary(runID: run.runID)
                        try store.database.upsertDeviceOwnedRunActivity(runID: run.runID,
                            activity: AgentRunActivity(id: "stream-tool-\(index)", kind: .tool,
                                phase: "result", title: "Check \(index)", status: "completed",
                                toolName: "read_file", content: "Synthetic result"))
                    }
                }.value
                enqueueConversationChange(.init(conversationID: conversation, runID: run.runID, phase: .content))
            }
            try store.database.completeLocalACPRun(runID: run.runID)
            localRunningConversationIDs.remove(conversation)
            // Content refresh exercises the production coalescing/refresh path.
            // Deliberately omit terminal follow-up: it restores real provider
            // metadata and reads usage, which is outside this offline fixture.
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
            let store = try DashboardStore(supportDirectory: root)
            dashboardStore = store
            lastOpenClawCronRefresh = .distantFuture
            lastHermesCronRefresh = .distantFuture
            enabledLocalACPRuntimeKinds = []
            shownLocalACPRuntimeKinds = [.codex]
            titleGenerationSettings.isEnabled = false
            let journal = DashboardNoteDraftJournal(fileURL: root.appending(path: "drafts.ndjson"))
            noteWriteBehind = makeNoteWriteBehind(journal: journal, database: store.database)
            try await store.prepareLocalWorkspace()
            let deviceID = try await store.dashboardDeviceID()
            try await Task.detached {
                let database = store.database
                let origin = Date(timeIntervalSince1970: 1_780_000_000)
                let short = "A short **formatted** answer with a `code` span.\n\n- First item\n- Second item"
                let long = (0..<60).map { "## Section \($0)\n\nA paragraph with **emphasis**, `code`, and several lines of readable text.\n\n```swift\nlet value = \($0)\n```" }.joined(separator: "\n\n")
                for index in 0..<(heavy ? 1000 : 12) {
                    let title = index == 0 ? "01 Short conversation" : index == 1 ? "02 Long conversation" : index == 2 ? "03 Activity conversation" : String(format: "Chat %04d", index)
                    let conversation = try database.createLocalACPSession(runtimeKind: .codex, title: title,
                        ownerDeviceID: deviceID, createdAt: origin.addingTimeInterval(Double(-index * 1000)))
                    for turn in 0..<(index == 1 ? 120 : 2) {
                        let date = origin.addingTimeInterval(Double(-index * 1000 + turn * 3))
                        let run = try database.beginLocalACPRun(conversationID: conversation,
                            content: "Please summarize item \(turn).", createdAt: date)
                        try database.appendLocalACPAssistantChunk(runID: run.runID,
                            chunk: index == 1 && turn == 119 ? long : short, updatedAt: date.addingTimeInterval(1))
                        if index == 2 {
                            for activity in 0..<(heavy ? 200 : 8) {
                                try database.upsertDeviceOwnedRunActivity(runID: run.runID,
                                    activity: AgentRunActivity(id: "tool-\(activity)", kind: .tool,
                                        phase: "result", title: "Read source \(activity)", status: "completed",
                                        toolName: "read_file", content: "Synthetic output \(activity)",
                                        rawOutputJSON: "{\"result\":\"fixture\"}"),
                                    updatedAt: date.addingTimeInterval(1))
                            }
                        }
                        try database.completeLocalACPRun(runID: run.runID, completedAt: date.addingTimeInterval(2))
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
                    _ = try database.createNote(folderID: nil,
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
