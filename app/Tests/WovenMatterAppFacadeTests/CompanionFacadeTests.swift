import Foundation
import SQLite3
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CompanionFacadeTests {
    @Test(arguments: AgentRuntimeKind.allCases, [false, true])
    func routesBindCanonicalNoteAndCreateInFolder(runtime: AgentRuntimeKind, remote: Bool) async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let folder = try fixture.database.createFolder(name: "Ideas")
        let conversationID = UUID().uuidString.lowercased()
        let provider = remote ? "remote:\(fixture.remote.id.uuidString.lowercased()):\(runtime.rawValue)" : "local:\(runtime.rawValue)"
        let create = CompanionCommand(deviceID: fixture.device, kind: .createSession,
            conversationID: conversationID, providerID: provider, folderID: folder)
        let created = try await fixture.model.companionCommands.execute(create, deviceID: fixture.device)
        #expect(created.status == .completed)
        #expect(created.conversationID == conversationID)
        #expect(try fixture.database.workspaceOverview().conversations.first?.folderID == folder)
        #expect(try await fixture.model.companionCommands.execute(create, deviceID: fixture.device) == created)
        let raw = try NoteDocument(blocks: [.richText(.init(text: "Canonical note text"))]).encoded()
        let noteID = try fixture.database.createNote(folderID: folder, title: "Selected note", content: raw)
        let revision = try #require(try fixture.database.companionNote(id: noteID)?.revision)
        let send = CompanionCommand(deviceID: fixture.device, kind: .send, conversationID: conversationID,
            text: "Use the selected note", noteID: noteID, noteRevision: revision)
        let sent = try await fixture.model.companionCommands.execute(send, deviceID: fixture.device)
        #expect(sent.status == .completed, "\(sent.message ?? "No receipt error")")
        let delivery = try #require(await fixture.recorder.deliveries.first)
        #expect(delivery.route == .localACP)
        #expect(delivery.input.references.first?.contentSnapshot == raw)
        #expect(delivery.input.references.first?.revisionSnapshot == String(revision))
        #expect(delivery.context?.noteID == noteID)
        #expect((delivery.context?.remoteEditNonce != nil) == remote)
        #expect(delivery.context?.revision == String(revision))
        #expect(sent.runID == fixture.model.canonicalActiveRunID(conversationID: conversationID))
        let stop = CompanionCommand(deviceID: fixture.device, kind: .stop,
            conversationID: conversationID, runID: sent.runID)
        #expect(try await fixture.model.companionCommands.execute(stop, deviceID: fixture.device).status == .completed)
        #expect(fixture.model.canonicalActiveRunID(conversationID: conversationID) == nil)
    }

    @Test(arguments: [false, true])
    func openNoteDoesNotPreventDesktopSteering(gateway: Bool) async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let id = try fixture.createConversation(gateway: gateway)
        let raw = try NoteDocument(blocks: [.richText(.init(text: "Keep the existing grant"))]).encoded()
        let noteID = try fixture.database.createNote(folderID: nil, title: "Open note", content: raw)
        let note = try #require(try fixture.database.workspaceOverview().notes.first)
        let originalContext = AgentNoteContext(noteID: noteID, title: note.title, folderID: nil,
            revision: note.revision ?? "1", remoteEditNonce: "existing-grant", artifactKind: .note)
        let run = try fixture.database.beginLocalACPRun(conversationID: id, input: .init(text: "Initial"), noteContext: originalContext)
        await fixture.model.configureCompanionFixture(directory: fixture.directory)
        let conversation = try #require(try fixture.database.workspaceOverview().conversations.first(where: { $0.id == id }))
        #expect(await fixture.model.sendAgentMessage(conversation: conversation, input: .init(text: "Desktop follow-up"), note: note))
        let desktop = try #require(await fixture.recorder.deliveries.first)
        #expect(desktop.route == (gateway ? .gateway : .localACP))
        #expect(desktop.delivery == "Desktop follow-up")
        #expect(desktop.context == nil)
        #expect(await fixture.recorder.deliveries.count == 1)
        let revision = try #require(try fixture.database.companionNote(id: noteID)?.revision)
        let mobile = CompanionCommand(deviceID: fixture.device, kind: .steer, conversationID: id,
            runID: run.runID, text: "Phone follow-up", noteID: noteID, noteRevision: revision)
        #expect(try await fixture.model.companionCommands.execute(mobile, deviceID: fixture.device).status == .completed)
        let phone = try #require(await fixture.recorder.deliveries.last)
        #expect(phone.context == nil && phone.delivery == "Phone follow-up")
        #expect(phone.input.references.first?.contentSnapshot == raw)
        #expect(try fixture.database.conversationContent(id: id).runs.count == 1)
        let wrong = CompanionCommand(deviceID: fixture.device, kind: .stop, conversationID: id, runID: UUID().uuidString)
        #expect(try await fixture.model.companionCommands.execute(wrong, deviceID: fixture.device).status == .rejected)
        #expect(fixture.model.canonicalActiveRunID(conversationID: id) == run.runID)
    }

    @Test(arguments: ["local", "remote", "gateway"])
    func folderDeletedDuringCreateAwaitLeavesNoSessionAndRetryIsStable(route: String) async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let folder = try fixture.database.createFolder(name: "Will be deleted")
        let id = UUID().uuidString.lowercased()
        let providerID = route == "gateway" ? "gateway:\(fixture.gatewayID.uuidString.lowercased())"
            : route == "remote" ? "remote:\(fixture.remote.id.uuidString.lowercased()):codex" : "local:codex"
        let command = CompanionCommand(deviceID: fixture.device, kind: .createSession,
            conversationID: id, providerID: providerID, folderID: folder)
        await fixture.recorder.holdCreation()
        let pending = Task { try await fixture.model.companionCommands.execute(command, deviceID: fixture.device) }
        await fixture.recorder.waitForCreation()
        _ = try fixture.database.deleteFolder(id: folder)
        await fixture.recorder.releaseCreation()
        let receipt = try await pending.value
        #expect(receipt.status == .rejected)
        #expect(try fixture.database.workspaceOverview().conversations.isEmpty)
        #expect(try await fixture.model.companionCommands.execute(command, deviceID: fixture.device) == receipt)
        #expect(try fixture.database.workspaceOverview().conversations.isEmpty)
    }

    @Test func controlsNeverReadHistoricalMessageBodiesAndTranscriptRemainsPaged() async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let id = try fixture.createConversation(gateway: false)
        let run = try fixture.database.beginLocalACPRun(conversationID: id, content: "Current")
        // Thousands of historical bodies make any accidental full-content lookup visible
        // in the actual SQL trace; the assertion does not rely on machine timing.
        try fixture.database.lock.withLock {
            try fixture.database.executeUnlocked("""
                WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 2400)
                INSERT INTO dashboard_messages(id,conversation_id,role,content,created_at,updated_at,desktop_owned)
                SELECT 'historical-' || x, '\(id)', 'user', hex(zeroblob(2048)), '2020-01-01', '2020-01-01', 1 FROM n
                """)
        }
        await fixture.model.configureCompanionFixture(directory: fixture.directory)
        let trace = SQLTrace()
        sqlite3_trace_v2(fixture.database.connection, UInt32(SQLITE_TRACE_STMT), traceFacadeSQL,
                         Unmanaged.passUnretained(trace).toOpaque())
        defer { sqlite3_trace_v2(fixture.database.connection, 0, nil, nil) }
        #expect(fixture.model.canonicalActiveRunID(conversationID: id) == run.runID)
        #expect(try await fixture.model.companionCommands.sessionCapabilities(conversationID: id).canStop)
        #expect(!trace.statements.contains(where: { $0.contains("FROM dashboard_messages") }))
        let page = try await fixture.model.companionCommands.transcript(conversationID: id)
        #expect(page.messages.count == 80 && page.olderCursor != nil)
        #expect(page.activeRunID == run.runID)
        let bodyQueries = trace.statements.filter { $0.contains("FROM dashboard_messages") && $0.contains("message.content") }
        #expect(bodyQueries.count == 1)
        #expect(bodyQueries.allSatisfy { $0.contains("LIMIT 81") })
        try await fixture.model.companionCommands.stop(conversationID: id, runID: run.runID)
        #expect(fixture.model.canonicalActiveRunID(conversationID: id) == nil)
    }
}

@MainActor private final class FacadeFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let store: DashboardStore
    var database: WorkspaceDatabase { store.database }
    let model: ApplicationModel
    let recorder = FacadeRecorder()
    let device = UUID().uuidString.lowercased()
    let gatewayID = UUID()
    let remote = RemoteWorkspaceConfiguration(name: "Fixture remote", workspaceID: "fixture", hostName: "fixture.invalid")
    init() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "companion-facade-\(UUID())")
        suite = "companion.facade.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        let recorder = recorder
        store = try DashboardStore(supportDirectory: directory, runControls: .init(
            accept: { route, id, input, delivery, context in try await recorder.accept(route, id, input, delivery, context) },
            steer: { route, id, input, delivery, runID in try await recorder.steer(route, id, input, delivery, runID) },
            cancel: { route, id, runID in try await recorder.cancel(route, id, runID) },
            beforeSessionCreation: { await recorder.beforeCreation() }))
        await recorder.configure(database: store.database)
        model = ApplicationModel(applicationDefaults: defaults, dashboardStore: store, startsAutomatically: false)
        try database.saveOpenClawGatewayLink(.init(agentID: gatewayID, location: .localAgentWorkspace,
            endpoint: .init(url: URL(string: "ws://127.0.0.1:1")!, authorization: .localService), status: OpenClawGatewayConnectionStatus.ready.rawValue))
        let status: RemoteWorkspaceStatus = try decode(#"{"id":"fixture","name":"Fixture","state":"running","running":true,"startedAt":"","image":"fixture","memoryBytes":0,"swapBytes":0,"hostPort":7337,"persistentVolume":"fixture","capabilities":{"memory":false,"swap":false},"storageKind":"fixture","hostStorageLow":false,"legacyStorage":false}"#)
        let harnesses: [RemoteHarnessStatus] = try AgentRuntimeKind.allCases.map { runtime in
            try decode("""
                {"id":"\(runtime.rawValue)","displayName":"\(runtime.displayName)","transport":"acp","capabilities":[],"state":"ready","authenticationStatus":"ready","setupMethods":[],"detectedProviders":[]}
                """)
        }
        model.remoteWorkspaces.configureCompanionFixture(remote, status: status, harnesses: harnesses)
        await model.configureCompanionFixture(directory: directory)
    }
    func createConversation(gateway: Bool) throws -> String {
        if gateway {
            return try database.createLocalACPSession(runtimeKind: .openclaw, title: "Gateway",
                ownerDeviceID: UUID(), gatewayAgentID: gatewayID)
        }
        return try database.createRemoteACPSession(runtimeKind: .codex, remoteWorkspaceID: remote.id,
            remoteWorkspaceName: remote.name, title: "Remote", ownerDeviceID: UUID())
    }
    func remove() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    private func decode<T: Decodable>(_ value: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(value.utf8)) }
}

private actor FacadeRecorder {
    struct Delivery: Sendable {
        let route: DashboardRunControlAdapters.Route
        let input: AgentMessageInput
        let delivery: String?
        let context: AgentNoteContext?
    }
    var deliveries: [Delivery] = []
    private var database: WorkspaceDatabase!
    private var creationHeld = false
    private var creationArrived = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func configure(database: WorkspaceDatabase) { self.database = database }
    func accept(_ route: DashboardRunControlAdapters.Route, _ id: String, _ input: AgentMessageInput,
                _ delivery: String?, _ context: AgentNoteContext?) throws -> LocalACPRunIdentifiers {
        deliveries.append(.init(route: route, input: input, delivery: delivery, context: context))
        return try database.beginLocalACPRun(conversationID: id, input: input, noteContext: context)
    }
    func steer(_ route: DashboardRunControlAdapters.Route, _ id: String, _ input: AgentMessageInput,
               _ delivery: String?, _ expectedRunID: String?) throws -> LocalACPSteeringIdentifiers {
        guard let runID = try database.activeRunID(conversationID: id), expectedRunID == nil || expectedRunID == runID else {
            throw LocalACPSessionDatabaseError.runNotFound
        }
        deliveries.append(.init(route: route, input: input, delivery: delivery, context: nil))
        return try database.beginLocalACPSteeringTurn(runID: runID, input: input)
    }
    func cancel(_ route: DashboardRunControlAdapters.Route, _ id: String, _ expectedRunID: String?) throws {
        guard let runID = try database.activeRunID(conversationID: id), expectedRunID == nil || expectedRunID == runID else {
            throw LocalACPSessionDatabaseError.runNotFound
        }
        try database.cancelLocalACPRun(runID: runID)
    }
    func holdCreation() { creationHeld = true }
    func beforeCreation() async {
        guard creationHeld else { return }
        creationArrived = true; arrival?.resume(); arrival = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitForCreation() async {
        if creationArrived { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func releaseCreation() { creationHeld = false; release?.resume(); release = nil }
}

private final class SQLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var statements: [String] { lock.withLock { values } }
    func append(_ sql: String) { lock.withLock { values.append(sql) } }
}

private func traceFacadeSQL(_ mask: UInt32, _ context: UnsafeMutableRawPointer?,
                            _ statement: UnsafeMutableRawPointer?, _ extra: UnsafeMutableRawPointer?) -> Int32 {
    guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
    Unmanaged<SQLTrace>.fromOpaque(context).takeUnretainedValue().append(String(cString: sql))
    return 0
}
