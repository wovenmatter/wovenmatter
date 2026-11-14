import WorkspaceFixtures
import AppKit
import Darwin
import Foundation
import Observation
import Testing
import WovenMatterCore
import WovenMatterClient
import WovenMatterLibraryStore
@testable import WovenMatterAppFacade

// Process pipes must not occupy the cooperative workers serving MCP requests.
private func runBlockingToolFixture<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

@MainActor
struct WorkspaceAgentToolsServiceTests {

    // Opt-in acceptance with the actual packaged MCP clients and native
    // adapters. No provider or account is used; the owning app services and
    // WebKit preview are real. The normal build validation runs this after
    // producing the app bundle.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WOVENMATTER_HTML_TEST_BUNDLE"] != nil),
          .serialized, .timeLimit(.minutes(2)), arguments: AgentRuntimeKind.allCases)
    func packagedHTMLToolsWorkAcrossHarnesses(runtime: AgentRuntimeKind) async throws {
        _ = NSApplication.shared
        let bundle = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WOVENMATTER_HTML_TEST_BUNDLE"]))
        let resources = bundle.appending(path: "Contents/Resources")
        let persistence = try PersistenceFixture(); defer { persistence.remove() }
        let database = try await persistence.openDatabase()
        let caller = try await database.createFixtureLocalACPSession(runtimeKind: runtime, title: "HTML acceptance", ownerDeviceID: UUID(),
            openCodeAssociation: runtime == .opencode ? ("acceptance", "ses_acceptance") : nil)
        var native = OpenCodeSessionSnapshot()
        let runID: String?
        if runtime == .opencode {
            native.active = true
            native.messages = [["id": "msg_acceptance", "type": "assistant", "time": ["created": .number(1)], "content": .array([])]]
            try await database.saveOpenCodeSnapshot(native, conversationID: caller)
            runID = nil
        } else { runID = try await database.beginLocalACPRun(conversationID: caller, input: .init(text: "Provider-free HTML acceptance")).runID }
        let service = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() }, noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() }, usageHandler: { _ in throw CancellationError() }, onMutation: {})
        defer { service.stop() }
        service.automationHandler = { identity, command, _ in
            #expect(identity == caller)
            let input = try JSONDecoder().decode(JSONValue.self, from: Data(command.required("json").utf8))
            #expect(input.objectValue?["action"]?.stringValue == "preview")
            return .init(result: try await ConversationHTMLPreview().capture(input))
        }
        let connection = try await service.mcpContext(sessionID: caller, captureID: "")
        let driver = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "default-agent/test/fixtures/html-harness.mjs")
        let report = try await runBlockingToolFixture {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = resources.appending(path: "default-agent/bin/node")
            process.arguments = [driver.path, resources.path, runtime.rawValue, connection.endpointURL]
            var environment = ProcessInfo.processInfo.environment
            environment["WOVEN_HTML_TEST_TOKEN"] = connection.bearerToken
            process.environment = environment
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "HTMLHarnessAcceptance", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: String(decoding: diagnostics, as: UTF8.self)])
            }
            return bytes
        }
        let value = try #require(JSONSerialization.jsonObject(with: report) as? [String: Any])
        let published = try #require(value["published"] as? [String])
        #expect(value["previews"] as? Int == 2)
        #expect(!FileManager.default.fileExists(atPath: try #require(value["deletedSourceImage"] as? String)))
        if let runID { try await database.completeLocalACPRun(runID: runID) }
        else { native.active = false; try await database.saveOpenCodeSnapshot(native, conversationID: caller) }
        let reopened = try await persistence.openDatabase(readOnlyProjection: true)
        let history = try await reopened.conversationHistoryPage(id: caller, limit: 20, compactActivities: true)
        let pages = history.activities.filter { $0.activity.htmlRender != nil }
        #expect(Set(pages.compactMap { $0.activity.htmlRender?.id }) == Set(published))
        #expect(ConversationWorkTimeline(records: history.activities, commentaryIDs: []).entries.count == published.count)
        for row in pages {
            #expect(row.activity.rawOutputJSON == nil)
            let detail = try #require(try await reopened.conversationActivityDetails(conversationID: caller, runID: row.runID, activityID: row.activity.id))
            let page = try JSONDecoder().decode(ConversationHTMLPage.self, from: Data(try #require(detail.rawOutputJSON).utf8))
            #expect(page.html.contains("data:image/svg+xml;base64,"))
            #expect(!page.html.contains(try #require(value["deletedSourceImage"] as? String)))
        }
    }

    @Test(arguments: AgentRuntimeKind.allCases.filter { $0 != .opencode })
    func htmlPublicationUsesBoundConversationAndPersistsOutsideFoldedWork(runtime: AgentRuntimeKind) async throws {
        let persistence = try PersistenceFixture(); defer { persistence.remove() }
        let database = try await persistence.openDatabase()
        let caller = try await database.createFixtureLocalACPSession(runtimeKind: runtime, title: "HTML", ownerDeviceID: UUID())
        let run = try await database.beginLocalACPRun(conversationID: caller, input: .init(text: "Visual reply"))
        let service = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() }, noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() }, usageHandler: { _ in throw CancellationError() }, onMutation: {})
        defer { service.stop() }
        let connection = try await service.mcpContext(sessionID: caller, captureID: "")
        let html = "<button onclick='this.textContent=42'>Calculate</button>" + (runtime == .codex
            ? "<img src='data:image/png;base64," + String(repeating: "A", count: 5 * 1024 * 1024) + "'>" : "")
        let payload: JSONValue = .object(["action": .string("render"), "html": .string(html), "title": .string("Calculator"), "height": .number(160)])
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let data = try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
          "params": .object(["name": .string("woven_html_render"), "arguments": .object(["html": .string(html), "title": .string("Calculator"), "height": .number(160)])])]))
        var request = URLRequest(url: try #require(URL(string: connection.endpointURL)))
        request.httpMethod = "POST"; request.httpBody = data
        request.setValue("Bearer " + connection.bearerToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (response, _) = try await URLSession.shared.data(for: request)
        let envelope = try JSONDecoder().decode(JSONValue.self, from: response)
        let structured = try #require(envelope.objectValue?["result"]?.objectValue?["structuredContent"])
        let result = try JSONDecoder().decode(WovenMatterToolResponse.self, from: JSONEncoder().encode(structured))
        #expect(result.success)
        #expect(result.result?.objectValue?["htmlRender"]?.objectValue?["title"]?.stringValue == "Calculator")
        let history = try await database.conversationHistoryPage(id: caller, limit: 20, compactActivities: true)
        let timeline = ConversationWorkTimeline(records: history.activities, commentaryIDs: [])
        #expect(timeline.entries.count == 1)
        #expect(history.activities.contains { $0.runID == run.runID && $0.activity.htmlRender?.title == "Calculator" })
        if runtime == .codex {
            #expect(data.count > 4 * 1024 * 1024)
            let activity = try #require(history.activities.first { $0.activity.htmlRender != nil })
            let detail = try #require(try await database.conversationActivityDetails(conversationID: caller, runID: run.runID, activityID: activity.activity.id))
            #expect(try JSONDecoder().decode(ConversationHTMLPage.self, from: Data(try #require(detail.rawOutputJSON).utf8)).html == html)
        }
        let forged = await service.handle(.init(arguments: ["html", "call", "--json", json, "--session", "someone-else"]), callerID: caller)
        #expect(!forged.success)
    }

    @Test func receiptObservationRetainsPagedWindowsAndSharedPanelOwnership() async throws {
        let fixture = try await ToolSnapshotFixture()
        defer { fixture.stop() }
        let model = fixture.model
        var ids: [String] = []
        for index in 0..<205 {
            let delivery = try await fixture.database.reserveToolDelivery(sourceID: fixture.caller,
                targetID: fixture.target, text: "Instruction \(index)", requestID: UUID().uuidString)
            ids.append(delivery.id)
        }
        let firstPanel = UUID(), secondPanel = UUID()
        await model.observeSession(fixture.caller, token: firstPanel)
        #expect(model.receipts[fixture.caller]?.map(\.id) == Array(ids.suffix(200).reversed()))
        #expect(model.hasOlderReceipts.contains(fixture.caller))
        let unchanged = observeToolSnapshotChanges {
            _ = model.receipts
            _ = model.hasOlderReceipts
        }
        try await model.reload()
        await model.observeSession(fixture.caller, token: secondPanel)
        await model.observeSession(nil, token: firstPanel)
        #expect(unchanged.count == 0)

        let olderChanged = observeToolSnapshotChanges { _ = model.hasOlderReceipts }
        await model.loadOlderReceipts(sessionID: fixture.caller)
        #expect(olderChanged.count == 1)
        #expect(model.receipts[fixture.caller]?.map(\.id) == Array(ids.reversed()))
        #expect(!model.hasOlderReceipts.contains(fixture.caller))
        let exhausted = observeToolSnapshotChanges {
            _ = model.receipts
            _ = model.hasOlderReceipts
        }
        await model.loadOlderReceipts(sessionID: fixture.caller)
        try await model.reload()
        #expect(exhausted.count == 0)

        let newest = try await fixture.database.reserveToolDelivery(sourceID: fixture.caller,
            targetID: fixture.target, text: "Latest", requestID: UUID().uuidString)
        try await fixture.database.setToolDeliveryStatus(id: ids[0], status: "cancelled")
        try await model.reload()
        #expect(model.receipts[fixture.caller]?.map(\.id) == [newest.id] + ids.reversed())
        #expect(model.receipts[fixture.caller]?.last?.status == "cancelled")
        let removed = observeToolSnapshotChanges { _ = model.receipts }
        await model.observeSession(nil, token: secondPanel)
        #expect(removed.count == 1)
        #expect(model.receipts.isEmpty)
        #expect(model.hasOlderReceipts.isEmpty)
    }

}

extension WorkspaceAgentToolsServiceTests {

    @Test func canvasToolsEditCardsAndPreserveLayout() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcp-hardening-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let caller = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Writer", ownerDeviceID: UUID())
        let model = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { caller, request, id in
                switch request.command {
                case .read: return try await database.readNoteForEditing(id: request.noteID, callerConversationID: caller)
                case .apply: return try await database.applyNoteEdits(request, callerConversationID: caller, requestID: id)
                }
            },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() }, onMutation: {})
        defer { model.stop() }

        let card = NoteRichTextBlock(text: "Original")
        let placement = CanvasCardPlacement(x: 420, y: 240, assetID: "retained-reference")
        let document = NoteDocument(kind: .canvas, blocks: [.richText(card)], canvas: [card.id: placement])
        let note = try await database.createNote(folderID: nil, title: "Board", content: document.encoded(), kind: .canvas, callerConversationID: caller, requestID: UUID().uuidString)
        let read = await model.handle(.init(arguments: ["notes", "read", note]), callerID: caller)
        #expect(read.success)
        #expect(read.result?.objectValue?["kind"]?.stringValue == "canvas")
        let originalRevision = try #require(read.result?.objectValue?["revision"]?.stringValue)
        let appended = await model.handle(.init(arguments: ["notes", "append", "--note-id", note, "--text", "Agent idea", "--revision", originalRevision]), callerID: caller)
        #expect(appended.success)
        let created = await model.handle(.init(arguments: ["notes", "table", "create", "--note-id", note, "--rows", "2", "--columns", "2"]), callerID: caller)
        #expect(created.success)
        let current = try await database.readNoteForEditing(id: note)
        let table = try #require(current.document?.blocks.last)
        let edited = await model.handle(.init(arguments: ["notes", "table", "set-cell", "--note-id", note, "--table-id", table.id, "--row", "0", "--column", "0", "--text", "Comparison", "--revision", try #require(current.revision)]), callerID: caller)
        #expect(edited.success)
        let stale = await model.handle(.init(arguments: ["notes", "delete-block", "--note-id", note, "--id", card.id, "--revision", originalRevision]), callerID: caller)
        #expect(!stale.success)
        let saved = try await database.readNoteForEditing(id: note)
        #expect(saved.document?.kind == .canvas)
        #expect(saved.document?.blocks.count == 3)
        #expect(saved.document?.plainText.contains("Agent idea") == true)
        #expect(saved.document?.plainText.contains("Comparison") == true)
        #expect(saved.document?.canvas?[card.id] == placement)
        // A generic insert migrated it without moving anything or losing its layout record.
        #expect(saved.document?.pageNodes != nil)
        // Exercise the actual command parser, permissions, service and transactional store.
        let asset = try await database.createNote(folderID: nil, title: "Independent artifact", kind: .html,
            callerConversationID: caller, requestID: UUID().uuidString)
        let sectionID = UUID().uuidString.lowercased()
        let grouped = await model.handle(.init(arguments: ["pages", "add-component", "--note-id", note, "--kind", "section", "--title", "Options"], requestID: sectionID), callerID: caller)
        #expect(grouped.success)
        #expect(grouped.result?.objectValue?["component"]?.objectValue?["kind"]?.stringValue == "section")
        let referenceID = UUID().uuidString.lowercased()
        let added = await model.handle(.init(arguments: ["pages", "add-component", "--note-id", note, "--parent-id", sectionID, "--asset-id", asset, "--title", "Artifact"], requestID: referenceID), callerID: caller)
        #expect(added.success)
        #expect(added.result?.objectValue?["componentID"]?.stringValue == referenceID)
        #expect(added.result?.objectValue?["component"]?.objectValue?["parentID"]?.stringValue == sectionID)
        let tableRevision = try #require(try await database.readNoteForEditing(id: note).document?.boardItemRevision(for: table.id))
        let arguments = ["pages", "move-component", "--note-id", note, "--id", table.id, "--parent-id", sectionID, "--component-revision", tableRevision]
        let requestID = UUID().uuidString
        let batch = await model.handle(.init(arguments: arguments, requestID: requestID), callerID: caller)
        #expect(batch.success)
        let replay = await model.handle(.init(arguments: arguments, requestID: requestID), callerID: caller)
        #expect(replay.success)
        #expect(replay.result?.objectValue?["replayed"]?.boolValue == true)
        let arranged = try await database.readNoteForEditing(id: note)
        #expect(arranged.document?.pageParentID(for: table.id) == sectionID)
        #expect(arranged.document?.boardItemRevision(for: table.id) == tableRevision)
        #expect(arranged.document?.canvas?[referenceID]?.assetID == asset)
        #expect(arranged.document?.blocks.count == 5)
        // Spatial layout is not a public tool any more.
        let layout = await model.handle(.init(arguments: ["pages", "edit-layout", "--note-id", note, "--revision", try #require(arranged.revision), "--json", "[]"]), callerID: caller)
        #expect(!layout.success)
        #expect(layout.code == "invalid_request")
        // A non-empty section needs a choice, and a stale subtree cannot be removed.
        let sectionRevision = try #require(arranged.document?.boardItemRevision(for: sectionID))
        let undecided = await model.handle(.init(arguments: ["pages", "remove-component", "--note-id", note, "--id", sectionID, "--component-revision", sectionRevision]), callerID: caller)
        #expect(!undecided.success)
        #expect(undecided.code == "invalid_request")
        let staleSubtree = await model.handle(.init(arguments: ["pages", "remove-component", "--note-id", note, "--id", sectionID, "--removal", "removeSubtree", "--subtree-revision", "stale"]), callerID: caller)
        #expect(!staleSubtree.success)
        #expect(staleSubtree.code == "revision_conflict")
        #expect(staleSubtree.result?.objectValue?["currentSubtreeRevision"]?.stringValue == arranged.document?.pageSubtreeRevision(for: sectionID))
        #expect(try await database.readNoteForEditing(id: note).document == arranged.document)
        let referenceRevision = try #require(arranged.document?.boardItemRevision(for: referenceID))
        let removed = await model.handle(.init(arguments: ["pages", "remove-component", "--note-id", note, "--id", referenceID, "--component-revision", referenceRevision]), callerID: caller)
        #expect(removed.success)
        #expect(try await database.readNoteForEditing(id: asset).success)
        try await database.setSessionTools(.init(enabled: [.history]), sessionID: caller)
        let denied = await model.handle(.init(arguments: arguments), callerID: caller)
        #expect(!denied.success)

    }

    private func pageFixture(_ root: URL) async throws -> (WorkspaceDatabase, WorkspaceAgentToolsModel, String, String) {
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let first = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "First worker", ownerDeviceID: UUID())
        let second = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Second worker", ownerDeviceID: UUID())
        let model = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { caller, request, id in
                switch request.command {
                case .read: return try await database.readNoteForEditing(id: request.noteID, callerConversationID: caller)
                case .apply: return try await database.applyNoteEdits(request, callerConversationID: caller, requestID: id)
                }
            },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() }, onMutation: {})
        return (database, model, first, second)
    }

    @Test func agentsCoordinateOnOnePageWithoutOverwritingEachOther() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pages-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (database, model, first, second) = try await pageFixture(root)
        defer { model.stop() }

        let createID = UUID().uuidString
        let createArguments = ["pages", "create", "--title", "Launch", "--purpose", "Ship the release"]
        let created = await model.handle(.init(arguments: createArguments, requestID: createID), callerID: first)
        #expect(created.success)
        #expect(created.result?.objectValue?["kind"]?.stringValue == "page")
        let page = try #require(created.result?.objectValue?["id"]?.stringValue)
        #expect(await model.handle(.init(arguments: createArguments, requestID: createID), callerID: first).result?.objectValue?["id"]?.stringValue == page)
        let mismatched = await model.handle(.init(arguments: ["pages", "create", "--title", "Other"], requestID: createID), callerID: first)
        #expect(!mismatched.success)

        // Adding needs no revision, and a retry cannot duplicate the component.
        let addID = UUID().uuidString.lowercased()
        let addArguments = ["pages", "add-component", "--note-id", page, "--text", "Draft them", "--status", "todo"]
        let added = await model.handle(.init(arguments: addArguments, requestID: addID), callerID: first)
        #expect(added.success)
        #expect(added.result?.objectValue?["componentID"]?.stringValue == addID)
        let replayed = await model.handle(.init(arguments: addArguments, requestID: addID), callerID: first)
        #expect(replayed.result?.objectValue?["replayed"]?.boolValue == true)
        #expect(replayed.result?.objectValue?["componentID"]?.stringValue == addID)
        let reused = await model.handle(.init(arguments: ["pages", "add-component", "--note-id", page, "--text", "Different"], requestID: addID), callerID: first)
        #expect(!reused.success)
        let otherID = UUID().uuidString.lowercased()
        #expect(await model.handle(.init(arguments: ["pages", "add-component", "--note-id", page, "--text", "Other work"], requestID: otherID), callerID: second).success)
        #expect(try await database.readNoteForEditing(id: page).document?.blocks.count == 2)

        // Both read, then both write. Different components do not conflict.
        let snapshot = try #require(try await database.readNoteForEditing(id: page).document)
        let revision = snapshot.boardItemRevision(for: addID), otherRevision = snapshot.boardItemRevision(for: otherID)
        let claim = await model.handle(.init(arguments: ["pages", "update-component", "--note-id", page, "--id", addID, "--component-revision", revision, "--status", "doing", "--assignee", "First", "--last-change", "Claimed"]), callerID: first)
        #expect(claim.success)
        #expect(claim.result?.objectValue?["componentRevision"]?.stringValue != revision)
        let independent = await model.handle(.init(arguments: ["pages", "update-component", "--note-id", page, "--id", otherID, "--component-revision", otherRevision, "--review", "needed"]), callerID: second)
        #expect(independent.success)

        // The same component conflicts, changes nothing, and reports what is current.
        let before = try await database.readNoteForEditing(id: page)
        let stale = await model.handle(.init(arguments: ["pages", "update-component", "--note-id", page, "--id", addID, "--component-revision", revision, "--assignee", "Second"]), callerID: second)
        #expect(!stale.success)
        #expect(stale.code == "revision_conflict")
        let current = try #require(before.document?.boardItemRevision(for: addID))
        #expect(stale.result?.objectValue?["currentComponentRevision"]?.stringValue == current)
        #expect(stale.result?.objectValue?["component"]?.objectValue?["task"]?.objectValue?["assignee"]?.stringValue == "First")
        #expect(stale.error?.contains(current) == true)
        #expect(try await database.readNoteForEditing(id: page).revision == before.revision)

        // Attribution is the caller the host authorized, and only touched components change.
        let saved = try #require(try await database.readNoteForEditing(id: page).document)
        #expect(saved.boardItems?[addID]?.createdBy?.sessionID == first)
        #expect(saved.boardItems?[addID]?.updatedBy?.kind == .session)
        #expect(saved.boardItems?[addID]?.updatedBy?.sessionID == first)
        #expect(saved.boardItems?[addID]?.updatedBy?.label == "First worker")
        #expect(saved.boardItems?[otherID]?.updatedBy?.sessionID == second)
        #expect(saved.boardItems?[addID]?.task == BoardTask(status: .doing, assignee: "First"))

        // Filtered discovery and reads.
        let listed = await model.handle(.init(arguments: ["pages", "list", "--search", "Launch"]), callerID: second)
        let row = try #require(listed.result?.objectValue?["rows"]?.arrayValue?.first?.objectValue)
        #expect(row["id"]?.stringValue == page && row["purpose"]?.stringValue == "Ship the release")
        #expect(row["openTasks"]?.intValue == 1 && row["needsReview"]?.intValue == 1 && row["components"]?.intValue == 2)
        let plainNote = try await database.createNote(folderID: nil, title: "Launch notes", callerConversationID: first, requestID: UUID().uuidString)
        #expect(await model.handle(.init(arguments: ["pages", "list", "--search", "Launch"]), callerID: second).result?.objectValue?["rows"]?.arrayValue?.count == 1)
        let needs = await model.handle(.init(arguments: ["pages", "read", "--note-id", page, "--needs-review"]), callerID: second)
        #expect(needs.result?.objectValue?["components"]?.arrayValue?.compactMap { $0.objectValue?["componentID"]?.stringValue } == [otherID])
        #expect(needs.result?.objectValue?["kind"]?.stringValue == "page")
        #expect(needs.result?.objectValue?["notice"]?.stringValue != nil)
        #expect(await !model.handle(.init(arguments: ["pages", "read", "--note-id", plainNote]), callerID: second).success)

        // The document revision guards the title and purpose, with current data on conflict.
        let staleTitle = await model.handle(.init(arguments: ["pages", "update", "--note-id", page, "--revision", "1", "--purpose", "Stale"]), callerID: first)
        #expect(staleTitle.code == "revision_conflict")
        #expect(staleTitle.result?.objectValue?["currentRevision"]?.stringValue == before.revision)
        let updated = await model.handle(.init(arguments: ["pages", "update", "--note-id", page, "--revision", try #require(before.revision), "--title", "Launch v2", "--purpose", "Ship it"]), callerID: first)
        #expect(updated.success)
        let renamed = try await database.readNoteForEditing(id: page)
        #expect(renamed.title == "Launch v2" && renamed.document?.boardPurpose == "Ship it")
        #expect(renamed.document?.boardItemRevision(for: addID) == saved.boardItemRevision(for: addID))

        // A session link is repeatable and stays separate from the task.
        let session = second
        for _ in 0..<2 {
            #expect(await model.handle(.init(arguments: ["pages", "link-session", "--note-id", page, "--id", addID, "--session", session]), callerID: first).success)
        }
        let linked = try #require(try await database.readNoteForEditing(id: page).document?.boardItems?[addID])
        #expect(linked.sessions == [session] && linked.task?.status == .doing)
        #expect(await !model.handle(.init(arguments: ["pages", "link-session", "--note-id", page, "--id", addID, "--session", "not-a-uuid"]), callerID: first).success)
        for _ in 0..<2 {
            #expect(await model.handle(.init(arguments: ["pages", "unlink-session", "--note-id", page, "--id", addID, "--session", session]), callerID: first).success)
        }
        #expect(try await database.readNoteForEditing(id: page).document?.boardItems?[addID]?.sessions == [])

        // Outside callers and the user's app are attributed by the host, too.
        try await database.updateExternalMCP(enabled: true)
        try await database.updateExternalMCP(group: .notes, groupEnabled: true)
        let outsideID = UUID().uuidString.lowercased()
        #expect(await model.handle(.init(arguments: ["pages", "add-component", "--note-id", page, "--text", "From outside"], requestID: outsideID), callerID: WovenMCPCaller.outside).success)
        let outsideItem = try await database.readNoteForEditing(id: page).document?.boardItems?[outsideID]
        #expect(outsideItem?.createdBy == BoardActor(kind: .outside))
        let userEdit = try await database.applyNoteEdits(.init(command: .apply, noteID: page, operations: [.page(.init(action: .add, id: "from-user", patch: .init(text: "Mine")))]))
        #expect(userEdit.document?.boardItems?["from-user"]?.createdBy == BoardActor(kind: .user))

        // Turning Notes off removes every Page tool, including replays.
        try await database.setSessionTools(.init(enabled: [.history]), sessionID: second)
        let denied = await model.handle(.init(arguments: ["pages", "read", "--note-id", page]), callerID: second)
        #expect(!denied.success)
        #expect(denied.code == "tool_disabled")
        let deniedWrite = await model.handle(.init(arguments: addArguments, requestID: addID), callerID: second)
        #expect(!deniedWrite.success)
    }

    @Test func pageToolsRefuseOtherAssetsAndStayReplayable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pages-kind-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (database, model, caller, _) = try await pageFixture(root)
        defer { model.stop() }
        let note = try await database.createNote(folderID: nil, title: "Ordinary", callerConversationID: caller, requestID: UUID().uuidString)
        let revision = try #require(try await database.readNoteForEditing(id: note).revision)
        for arguments in [["pages", "update", "--note-id", note, "--revision", revision, "--title", "Renamed"],
                          ["pages", "update", "--note-id", note, "--revision", revision, "--purpose", "Nope"],
                          ["pages", "add-component", "--note-id", note, "--text", "Nope"]] {
            let response = await model.handle(.init(arguments: arguments), callerID: caller)
            #expect(!response.success, "\(arguments)")
            #expect(response.code == "invalid_request", "\(arguments)")
            #expect(response.error?.contains("not a Page") == true, "\(arguments)")
        }
        let unchanged = try await database.readNoteForEditing(id: note)
        #expect(unchanged.title == "Ordinary" && unchanged.revision == revision)

        // A title-only update replays after success, even once the Page is gone.
        let created = await model.handle(.init(arguments: ["pages", "create", "--title", "Plan"]), callerID: caller)
        let page = try #require(created.result?.objectValue?["id"]?.stringValue)
        let pageRevision = try #require(try await database.readNoteForEditing(id: page).revision)
        // A generic batch cannot carry Page or retired spatial edits, so it cannot pick
        // component IDs or skip the rules each Page tool enforces.
        let pageOperation = String(decoding: try JSONEncoder().encode([NoteEditOperation.page(.init(action: .add, id: "chosen", kind: .task, patch: .init(text: "Bypass")))]), as: UTF8.self)
        for operations in [pageOperation, #"[{"type":"board","edit":{"action":"addItem","id":"chosen"}}]"#,
                           #"[{"type":"canvas","edit":{"action":"connect","connection":{"id":"c","from":"a","to":"b","label":"","color":"neutral"}}}]"#] {
            let response = await model.handle(.init(arguments: ["notes", "apply", "--note-id", page, "--revision", pageRevision, "--json", operations]), callerID: caller)
            #expect(!response.success, "\(operations)")
            #expect(response.code == "invalid_request", "\(operations)")
        }
        #expect(try await database.readNoteForEditing(id: page).revision == pageRevision)
        let arguments = ["pages", "update", "--note-id", page, "--revision", pageRevision, "--title", "Plan v2"]
        let requestID = UUID().uuidString
        #expect(await model.handle(.init(arguments: arguments, requestID: requestID), callerID: caller).success)
        #expect(try await database.readNoteForEditing(id: page).title == "Plan v2")
        try await database.mutateNote(id: page, mutation: .moveToTrash, expectedRevision: database.noteActionRevision(id: page))
        let replay = await model.handle(.init(arguments: arguments, requestID: requestID), callerID: caller)
        #expect(replay.success)
        #expect(replay.result?.objectValue?["replayed"]?.boolValue == true)
        let mismatch = await model.handle(.init(arguments: ["pages", "update", "--note-id", page, "--revision", pageRevision, "--title", "Other"], requestID: requestID), callerID: caller)
        #expect(!mismatch.success)

        // An invalid block on a real Page says what is wrong instead of "not a Page".
        let valid = await model.handle(.init(arguments: ["pages", "create", "--title", "Tables"]), callerID: caller)
        let tables = try #require(valid.result?.objectValue?["id"]?.stringValue)
        let wide = NoteBlock.table(.init(rows: 1, columns: RemoteNoteEditEnvelope.maximumTableColumns + 1))
        let json = String(decoding: try JSONEncoder().encode(wide), as: UTF8.self)
        let refused = await model.handle(.init(arguments: ["pages", "add-component", "--note-id", tables, "--json", json]), callerID: caller)
        #expect(!refused.success)
        #expect(refused.error?.contains("not a Page") == false)
    }

    @Test func removedComponentsConflictActionablyAndRepeatedLinksKeepRevisions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pages-removed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (database, model, first, second) = try await pageFixture(root)
        defer { model.stop() }
        let created = await model.handle(.init(arguments: ["pages", "create", "--title", "Plan"]), callerID: first)
        let page = try #require(created.result?.objectValue?["id"]?.stringValue)
        let itemID = UUID().uuidString.lowercased()
        #expect(await model.handle(.init(arguments: ["pages", "add-component", "--note-id", page, "--text", "Task", "--status", "todo"], requestID: itemID), callerID: first).success)
        let held = try #require(try await database.readNoteForEditing(id: page).document?.boardItemRevision(for: itemID))

        // Linking twice changes the document once, and never strands another writer's revision.
        #expect(await model.handle(.init(arguments: ["pages", "link-session", "--note-id", page, "--id", itemID, "--session", second]), callerID: first).success)
        let linked = try await database.readNoteForEditing(id: page)
        let again = await model.handle(.init(arguments: ["pages", "link-session", "--note-id", page, "--id", itemID, "--session", second]), callerID: first)
        #expect(again.success)
        #expect(again.result?.objectValue?["revision"]?.stringValue == linked.revision)
        #expect(try await database.readNoteForEditing(id: page).revision == linked.revision)

        let current = try #require(linked.document?.boardItemRevision(for: itemID))
        #expect(current != held)
        #expect(await model.handle(.init(arguments: ["pages", "remove-component", "--note-id", page, "--id", itemID, "--component-revision", current]), callerID: first).success)
        let removed = try await database.readNoteForEditing(id: page)
        for arguments in [["pages", "update-component", "--note-id", page, "--id", itemID, "--component-revision", current, "--status", "done"],
                          ["pages", "remove-component", "--note-id", page, "--id", itemID, "--component-revision", current]] {
            let stale = await model.handle(.init(arguments: arguments), callerID: second)
            #expect(!stale.success)
            #expect(stale.code == "revision_conflict")
            #expect(stale.result?.objectValue?["componentRemoved"]?.boolValue == true)
            #expect(stale.result?.objectValue?["componentID"]?.stringValue == itemID)
            #expect(stale.result?.objectValue?["currentRevision"]?.stringValue == removed.revision)
            #expect(stale.error?.contains("no longer exists") == true)
        }
        // Without a held revision an unknown component is simply not found.
        let unknown = await model.handle(.init(arguments: ["pages", "link-session", "--note-id", page, "--id", itemID, "--session", second]), callerID: first)
        #expect(unknown.code == "not_found")
    }

    @Test func pageLinksPreserveOriginalsAndReportMissingOnes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pages-assets-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (database, model, caller, _) = try await pageFixture(root)
        defer { model.stop() }
        let created = await model.handle(.init(arguments: ["pages", "create", "--title", "Refs"]), callerID: caller)
        let page = try #require(created.result?.objectValue?["id"]?.stringValue)
        let asset = try await database.createNote(folderID: nil, title: "Original", kind: .html, callerConversationID: caller, requestID: UUID().uuidString)

        let missing = await model.handle(.init(arguments: ["pages", "add-component", "--note-id", page, "--asset-id", UUID().uuidString.lowercased()]), callerID: caller)
        #expect(!missing.success)
        #expect(missing.code == "not_found")
        let selfLink = await model.handle(.init(arguments: ["pages", "add-component", "--note-id", page, "--asset-id", page]), callerID: caller)
        #expect(!selfLink.success)
        let copied = await model.handle(.init(arguments: ["pages", "add-component", "--note-id", page, "--asset-id", asset, "--text", "Copy"]), callerID: caller)
        #expect(!copied.success)
        #expect(copied.code == "invalid_request")
        #expect(try await database.readNoteForEditing(id: page).document?.blocks.isEmpty == true)

        let itemID = UUID().uuidString.lowercased()
        let linked = await model.handle(.init(arguments: ["pages", "add-component", "--note-id", page, "--asset-id", asset, "--title", "Spec", "--role", "instructions"], requestID: itemID), callerID: caller)
        #expect(linked.success)
        #expect(linked.result?.objectValue?["component"]?.objectValue?["asset"]?.objectValue?["title"]?.stringValue == "Original")
        #expect(linked.result?.objectValue?["component"]?.objectValue?["asset"]?.objectValue?["kind"]?.stringValue == "html")

        // A move and a task update keep the original; deleting it keeps the link.
        let document = try #require(try await database.readNoteForEditing(id: page).document)
        let sectionID = UUID().uuidString.lowercased()
        #expect(await model.handle(.init(arguments: ["pages", "add-component", "--note-id", page, "--kind", "section", "--title", "Sources"], requestID: sectionID), callerID: caller).success)
        #expect(await model.handle(.init(arguments: ["pages", "move-component", "--note-id", page, "--id", itemID, "--parent-id", sectionID]), callerID: caller).success)
        let afterMove = try #require(try await database.readNoteForEditing(id: page).document)
        #expect(afterMove.canvas?[itemID]?.assetID == asset)
        #expect(afterMove.canvas?[itemID]?.title == "Spec")
        #expect(afterMove.pageParentID(for: itemID) == sectionID)
        #expect(afterMove.boardItems?[itemID] == document.boardItems?[itemID])
        #expect(afterMove.boardItemRevision(for: itemID) == document.boardItemRevision(for: itemID))

        try await database.mutateNote(id: asset, mutation: .moveToTrash, expectedRevision: database.noteActionRevision(id: asset))
        let read = await model.handle(.init(arguments: ["pages", "read", "--note-id", page]), callerID: caller)
        let component = try #require(read.result?.objectValue?["components"]?.arrayValue?.last?.objectValue)
        #expect(component["assetID"]?.stringValue == asset)
        #expect(component["asset"]?.objectValue?["available"]?.boolValue == false)
        let task = await model.handle(.init(arguments: ["pages", "update-component", "--note-id", page, "--id", itemID, "--component-revision", afterMove.boardItemRevision(for: itemID), "--status", "todo"]), callerID: caller)
        #expect(task.success)
        #expect(try await database.readNoteForEditing(id: page).document?.canvas?[itemID]?.assetID == asset)

        // The retained link stays, but a new component cannot reuse its missing original.
        let reused = await model.handle(.init(arguments: ["pages", "add-component", "--note-id", page, "--asset-id", asset]), callerID: caller)
        #expect(!reused.success)
        #expect(reused.code == "not_found")
        #expect(try await database.readNoteForEditing(id: page).document?.blocks.count == 2)
    }

    @Test func artifactStateToolsWriteOnlyStateAndReportConflicts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "artifact-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (database, model, caller, _) = try await pageFixture(root)
        defer { model.stop() }
        let artifact = try await database.createNote(folderID: nil, title: "Form", kind: .html, callerConversationID: caller, requestID: UUID().uuidString)
        let start = try await database.readNoteForEditing(id: artifact)
        let setHTML = await model.handle(.init(arguments: ["notes", "set-html", "--note-id", artifact, "--html", "<input id=\"name\">", "--revision", try #require(start.revision)]), callerID: caller)
        #expect(setHTML.success)
        let edits = #"[{"action":"set","key":"app:plan","value":{"step":2,"ratio":0.5,"none":null}}]"#
        let saved = await model.handle(.init(arguments: ["notes", "artifact-state-edit", "--note-id", artifact, "--json", edits], requestID: UUID().uuidString), callerID: caller)
        #expect(saved.success)
        #expect(saved.result?.objectValue?["state"]?.objectValue?["versions"]?.objectValue?["app:plan"]?.intValue == 1)

        let read = await model.handle(.init(arguments: ["notes", "artifact-state", "--note-id", artifact]), callerID: caller)
        let value = try #require(read.result?.objectValue?["state"]?.objectValue?["values"]?.objectValue?["app:plan"]?.objectValue)
        #expect(value["step"] == .number(2) && value["ratio"] == .number(0.5) && value["none"] == .null)

        // A stale write reports what is current and changes nothing, including the revision.
        let before = try await database.readNoteForEditing(id: artifact)
        let stale = #"[{"action":"set","key":"app:plan","value":"newer"}]"#
        let conflict = await model.handle(.init(arguments: ["notes", "artifact-state-edit", "--note-id", artifact, "--json", stale], requestID: UUID().uuidString), callerID: caller)
        #expect(!conflict.success)
        #expect(conflict.code == "revision_conflict")
        #expect(conflict.result?.objectValue?["currentVersion"]?.intValue == 1)
        #expect(conflict.result?.objectValue?["currentValue"]?.objectValue?["step"] == .number(2))
        let after = try await database.readNoteForEditing(id: artifact)
        #expect(after.revision == before.revision)
        #expect(after.document?.html == "<input id=\"name\">")

        // Not an artifact, not this tool. Off with Notes, like every other note tool.
        let note = try await database.createNote(folderID: nil, title: "Plain", callerConversationID: caller, requestID: UUID().uuidString)
        let wrong = await model.handle(.init(arguments: ["notes", "artifact-state-edit", "--note-id", note, "--json", edits], requestID: UUID().uuidString), callerID: caller)
        #expect(!wrong.success && wrong.code == "invalid_request")
        try await database.setSessionTools(.init(enabled: [.history]), sessionID: caller)
        let denied = await model.handle(.init(arguments: ["notes", "artifact-state", "--note-id", artifact]), callerID: caller)
        #expect(!denied.success && denied.code == "tool_disabled")
    }


    @Test func mutationHistoryIsMetadataOnlyAndNoteReadsAreChunked() async throws {
        let persistence = try PersistenceFixture(); defer { persistence.remove() }
        let database = try await persistence.openDatabase()
        let caller = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Writer", ownerDeviceID: UUID())
        let historian = try await database.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Historian", ownerDeviceID: UUID())
        try await database.setSessionTools(.init(enabled: [.history]), sessionID: historian)
        let model = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { caller, request, id in
                switch request.command {
                case .read: return try await database.readNoteForEditing(id: request.noteID, callerConversationID: caller)
                case .apply: return try await database.applyNoteEdits(request, callerConversationID: caller, requestID: id)
                }
            },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() }, onMutation: {})
        defer { model.stop() }
        try await database.coordinateFixtureSession(sourceID: caller, targetID: historian, purpose: "Audit")
        let status = await model.handle(.init(arguments: ["sessions", "status", historian]), callerID: caller)
        #expect(status.result?.objectValue?["relationship"]?.objectValue?["coordinationEpoch"]?.stringValue != nil)
        let note = try await database.createNote(folderID: nil, title: "Private", callerConversationID: caller,
            requestID: UUID().uuidString)
        let missingRevision = await model.handle(.init(arguments: ["notes", "set-title", "--note-id", note,
            "--title", "Unsafe overwrite"]), callerID: caller)
        #expect(!missingRevision.success && missingRevision.code == "revision_required")
        let secret = "private-body-" + UUID().uuidString.lowercased() + String(repeating: "x", count: 100)
        let requestID = UUID().uuidString
        let arguments = ["notes", "append", "--note-id", note, "--text", secret]
        let first = await model.handle(.init(arguments: arguments, requestID: requestID), callerID: caller)
        let replay = await model.handle(.init(arguments: arguments, requestID: requestID.lowercased()), callerID: caller)
        #expect(first.success && replay.success)
        #expect(first.result?.objectValue?["document"] == nil)
        #expect(replay.result?.objectValue?["replayed"]?.boolValue == true)
        #expect(try await database.readNoteForEditing(id: note).document?.plainText
            .components(separatedBy: secret).count == 2)

        let mismatchedID = UUID().uuidString.lowercased()
        let mismatch = await model.handle(.init(arguments: arguments + ["--request-id", mismatchedID],
            requestID: UUID().uuidString), callerID: caller)
        #expect(!mismatch.success && mismatch.code == "invalid_request")
        #expect(mismatch.error?.contains("match the request envelope") == true)
        #expect(try await database.readNoteForEditing(id: note).document?.plainText
            .components(separatedBy: secret).count == 2)

        let read = await model.handle(.init(arguments: ["notes", "read", note,
            "--characters", "10"]), callerID: caller)
        #expect(read.result?.objectValue?["content"]?.stringValue?.count == 10)
        #expect(read.result?.objectValue?["hasMore"]?.boolValue == true)
        let audit = await model.handle(.init(arguments: ["history", "events", "--conversation", caller,
            "--kind", "mcp.mutation"]), callerID: historian)
        let payloads = audit.result?.objectValue?["rows"]?.arrayValue?.compactMap {
            $0.objectValue?["payload"]?.stringValue
        } ?? []
        #expect(!payloads.isEmpty && payloads.allSatisfy { !$0.contains(secret) })
        let oldBodies = await model.handle(.init(arguments: ["history", "events", "--conversation", caller,
            "--kind", "mcp.response"]), callerID: historian)
        #expect(oldBodies.result?.objectValue?["rows"]?.arrayValue?.isEmpty == true)

        let missing = await model.handle(.init(arguments: ["history", "message", UUID().uuidString]),
            callerID: historian)
        #expect(!missing.success && missing.code == "not_found")
    }

}

@MainActor
private func callMCPTool(_ service: WorkspaceAgentToolsModel, connection: WovenMCPConnection,
                         name: String, arguments: [String: JSONValue],
                         requestID: String = UUID().uuidString) async throws -> WovenMatterToolResponse {
    var arguments = arguments
    arguments["requestID"] = .string(requestID)
    let message: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .string(UUID().uuidString),
        "method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": .object(arguments)])])
    let response = try #require(await service.handleMCP(.init(method: "POST", target: "/mcp",
        headers: ["authorization": "Bearer " + connection.bearerToken], body: try JSONEncoder().encode(message))))
    #expect(response.status == 200)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: response.body)
    if let error = decoded.objectValue?["error"]?.objectValue {
        return .init(success: false, error: error["message"]?.stringValue, code: "invalid_request", requestID: requestID)
    }
    let envelope = try #require(decoded.objectValue?["result"]?.objectValue?["structuredContent"])
    return try JSONDecoder().decode(WovenMatterToolResponse.self, from: JSONEncoder().encode(envelope))
}

extension WorkspaceAgentToolsServiceTests {

}

@MainActor
private func observeToolSnapshotChanges(_ read: () -> Void) -> ToolSnapshotChanges {
    let changes = ToolSnapshotChanges()
    withObservationTracking(read, onChange: { changes.record() })
    return changes
}

private final class ToolSnapshotChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

@MainActor
private struct ToolSnapshotFixture {
    let persistence: PersistenceFixture
    let database: WorkspaceDatabase
    let caller: String
    let target: String
    let model: WorkspaceAgentToolsModel

    init() async throws {
        persistence = try PersistenceFixture()
        database = try await persistence.openDatabase()
        caller = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Caller", ownerDeviceID: UUID())
        target = try await database.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Target", ownerDeviceID: UUID())
        model = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() }, onMutation: {})
    }

    func stop() {
        model.stop()
        persistence.remove()
    }
}

extension WorkspaceAgentToolsServiceTests {
    @Test func calendarCommandsShareNativeEventsAndKeepRetriesAndPermissions() async throws {
        let persistence = try PersistenceFixture(); defer { persistence.remove() }
        let database = try await persistence.openDatabase()
        let caller = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Planner", ownerDeviceID: UUID())
        @MainActor final class ResolutionState {
            var count = 0
            var editsEvent = false
        }
        let resolution = ResolutionState()
        let service = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() },
            calendarTaskHandler: { _, command, existing in
                resolution.count += 1
                if resolution.editsEvent {
                    let event = try await database.calendarEvent(id: command.required("id", allowPositional: true), callerID: caller)
                    var draft = WorkspaceCalendarDraft(event); draft.details = "A newer user edit"
                    try await database.saveCalendarEvent(id: event.id, draft: draft, creating: false, expectedRevision: event.calendar.revision)
                }
                var task = existing ?? WorkspaceCalendarTask(prompt: "", configuration: .init(runtimeKind: .codex,
                    title: "Review", model: "fixture-model", thinking: "high", permission: "read-only", tools: .init(enabled: [.notes])))
                task.prompt = command.options["prompt"] ?? task.prompt
                if let mode = command.options["session-mode"].flatMap(WorkspaceCalendarTask.SessionMode.init(rawValue:)) { task.sessionMode = mode }
                return task
            }, onMutation: {})
        defer { service.stop() }
        let connection = try await service.mcpContext(sessionID: caller, captureID: "")
        func request(_ action: String, _ arguments: [String: JSONValue] = [:], id: String = UUID().uuidString.lowercased()) async throws -> WovenMatterToolResponse {
            try await callMCPTool(service, connection: connection, name: "woven_calendar_" + action, arguments: arguments, requestID: id)
        }
        let id = UUID().uuidString.lowercased()
        let creation: [String: JSONValue] = ["title": .string("Daily review"), "startsAt": .string("2026-09-01T13:00:00Z"),
            "timeZone": .string("America/New_York"), "repeatUnit": .string("day"), "repeatInterval": .number(2),
            "prompt": .string("Review changes"), "sessionMode": .string("new")]
        #expect(try await request("create", creation, id: id).success)
        let event = try await database.calendarEvent(id: id, callerID: caller)
        #expect(event.calendar.recurrence == .init(unit: .day, interval: 2))
        #expect(event.calendar.createdBy.agent == "codex")
        #expect(event.calendar.task?.sessionMode == .new)
        let listing = try await request("list", ["since": .string("2026-09-15T00:00:00Z")])
        #expect(listing.result?.objectValue?["rows"]?.arrayValue?.first?.objectValue?["calendar"]?.objectValue?["task"] != nil)
        let occurrences = try await request("occurrences", ["id": .string(id), "since": .string("2026-09-01T00:00:00Z"), "until": .string("2026-09-08T00:00:00Z")])
        #expect(occurrences.result?.objectValue?["rows"]?.arrayValue?.count == 4)
        #expect(try await request("update", ["id": .string(id), "revision": .number(Double(event.calendar.revision)),
            "description": .string("Edited from a session")]).success)
        let updated = try await database.calendarEvent(id: id, callerID: caller)
        #expect(updated.calendar.task?.configuration.permission == "read-only")
        #expect(updated.calendar.task?.prompt == "Review changes")
        #expect(updated.calendar.recurrence == event.calendar.recurrence)
        #expect(updated.calendar.editedBy?.sessionID == caller)
        #expect(try await !request("update", ["id": .string(id), "revision": .number(0), "title": .string("Stale edit")]).success)
        #expect(try await !request("update", ["id": .string(id), "occurrence": .number(1), "title": .string("Linked exception")]).success)
        let detached = try await request("detach", ["id": .string(id), "occurrence": .number(1),
            "revision": .number(Double(updated.calendar.revision)), "title": .string("Independent review")])
        #expect(detached.success)
        let detachedID = try #require(detached.result?.objectValue?["id"]?.stringValue)
        let independent = try await database.calendarEvent(id: detachedID, callerID: caller)
        #expect(independent.calendar.recurrence == nil)
        #expect(independent.calendar.task?.prompt == "Review changes")
        #expect(independent.calendar.task?.configuration.tools.enabled == [.notes, .goals, .html])
        #expect(try await !request("remove", ["id": .string(detachedID), "occurrence": .number(1),
            "revision": .number(Double(independent.calendar.revision))]).success)
        #expect(try await request("read", ["id": .string(detachedID)]).success)
        #expect(try await database.calendarEvent(id: id, callerID: caller).calendar.excludedOccurrences == [1])
        let copyID = UUID().uuidString.lowercased()
        let copy: [String: JSONValue] = ["id": .string(detachedID), "startsAt": .string("2026-09-20T13:00:00Z")]
        #expect(try await request("copy", copy, id: copyID).success)
        let copied = try await database.calendarEvent(id: copyID, callerID: caller)
        #expect(try await request("remove", ["id": .string(copyID), "revision": .number(Double(copied.calendar.revision))]).success)
        // Replay succeeds even after the copy was deleted, without re-resolving defaults.
        let beforeReplay = resolution.count
        #expect(try await request("copy", copy, id: copyID).result?.objectValue?["id"]?.stringValue == copyID)
        #expect(resolution.count == beforeReplay)
        #expect(try await !request("copy", copy.merging(["title": .string("Different input")]) { _, new in new }, id: copyID).success)
        resolution.editsEvent = true
        let beforeRace = try await database.calendarEvent(id: id, callerID: caller)
        #expect(try await !request("update", ["id": .string(id), "revision": .number(Double(beforeRace.calendar.revision)),
            "description": .string("Stale agent edit")]).success)
        #expect(try await database.calendarEvent(id: id, callerID: caller).details == "A newer user edit")
        resolution.editsEvent = false
        var settings = try await database.toolSettings(); settings.calendarAccess = .readOnly
        try await database.saveToolSettings(settings)
        #expect(try await request("read", ["id": .string(id)]).success)
        #expect(try await !request("create", creation, id: id).success)
        #expect(try await !request("remove", ["id": .string(id)]).success)
        settings.calendarAccess = .full; try await database.saveToolSettings(settings)
        try await database.setSessionTools(.init(enabled: [.calendar]), sessionID: caller)
        #expect(try await !request("create", creation, id: UUID().uuidString.lowercased()).success)
        #expect(try await request("create", ["title": .string("Ordinary event"), "startsAt": .string("2026-09-22T13:00:00Z")]).success)
        try await database.setSessionTools(.init(enabled: []), sessionID: caller)
        #expect(try await !request("list").success)
    }

}

extension WorkspaceAgentToolsServiceTests {

    @Test(.timeLimit(.minutes(1)))
    func failedQueuedSettingsSavePreservesNewerEditAndLastSuccessfulValue() async throws {
        let fixture = try await ToolSnapshotFixture()
        defer { fixture.stop() }
        let gate = ToolSettingsSaveGate()
        let projection = try await WorkspaceAgentToolsModel(projection: fixture.database) { mutation in
            try await gate.pause()
            if case let .saveSettings(value, _) = mutation { try await fixture.database.saveToolSettings(value) }
        }
        defer { projection.stop(); gate.finishAll() }
        var first = projection.settings
        first.maximumManagedSessions = 7
        var latest = first
        latest.maximumManagedSessions = 9
        let oldSave = Task { await projection.saveSettings(first) }
        await gate.waitForStarts(1)
        let newestSave = Task { await projection.saveSettings(latest) }
        let deadline = ContinuousClock.now + .seconds(5)
        while projection.settings != latest, ContinuousClock.now < deadline { await Task.yield() }
        #expect(projection.settings == latest)
        gate.finish(1, failure: true)
        await gate.waitForStarts(2)
        #expect(projection.settings == latest)
        gate.finish(2, failure: false)
        await oldSave.value
        await newestSave.value
        #expect(projection.settings == latest)
        #expect(try await fixture.database.toolSettings() == latest)
        #expect(projection.error == nil)

        var rejected = latest
        rejected.maximumManagedSessions = 11
        let failedSave = Task { await projection.saveSettings(rejected) }
        await gate.waitForStarts(3)
        gate.finish(3, failure: true)
        await failedSave.value
        #expect(projection.settings == latest)
        #expect(projection.error == ToolSettingsSaveFailure().localizedDescription)
    }
}

private struct ToolSettingsSaveFailure: LocalizedError {
    var errorDescription: String? { "The fixture save failed." }
}

@MainActor
private final class ToolSettingsSaveGate {
    private var starts = 0
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func pause() async throws {
        starts += 1
        let id = starts
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let ready = observers.filter { $0.0 <= starts }
            observers.removeAll { $0.0 <= starts }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForStarts(_ count: Int) async {
        if starts >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func finish(_ id: Int, failure: Bool) {
        if failure { pending.removeValue(forKey: id)?.resume(throwing: ToolSettingsSaveFailure()) }
        else { pending.removeValue(forKey: id)?.resume() }
    }
    func finishAll() {
        let remaining = pending.values
        pending.removeAll()
        remaining.forEach { $0.resume(throwing: CancellationError()) }
    }
}
