import Foundation
import SQLite3
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CompanionFacadeTests {
    // OpenCode uses its native coordinator, covered by OpenCodeCoordinatorTests.
    // Every remaining runtime still traverses the real facade and launch routing.
    @Test(arguments: AgentRuntimeKind.allCases.filter { $0 != .opencode }, [false, true])
    func routesBindCanonicalNoteAndCreateInFolder(runtime: AgentRuntimeKind, remote: Bool) async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let folder = try await fixture.database.createFolder(name: "Ideas")
        let conversationID = UUID().uuidString.lowercased()
        let provider = remote ? "remote:\(fixture.remote.id.uuidString.lowercased()):\(runtime.rawValue)" : "local:\(runtime.rawValue)"
        let create = CompanionCommand(deviceID: fixture.device, kind: .createSession,
            conversationID: conversationID, providerID: provider, folderID: folder)
        let created = try await fixture.model.companionCommands.execute(create, deviceID: fixture.device)
        #expect(created.status == .completed, "\(created.message ?? "No create error")")
        #expect(created.conversationID == conversationID)
        #expect(try await fixture.database.workspaceOverview().conversations.first?.folderID == folder)
        #expect(try await fixture.model.companionCommands.execute(create, deviceID: fixture.device) == created)
        let raw = try NoteDocument(blocks: [.richText(.init(text: "Canonical note text"))]).encoded()
        let noteID = try await fixture.database.createNote(folderID: folder, title: "Selected note", content: raw)
        let revision = try #require(try await fixture.database.companionNote(id: noteID)?.revision)
        let send = CompanionCommand(deviceID: fixture.device, kind: .send, conversationID: conversationID,
            text: "Use the selected note", noteID: noteID, noteRevision: revision)
        let sent = try await fixture.model.companionCommands.execute(send, deviceID: fixture.device)
        #expect(sent.status == .completed, "\(sent.message ?? "No receipt error")")
        let delivery = try #require(await fixture.recorder.deliveries.first)
        #expect(delivery.route == .localACP)
        #expect(delivery.input.references.first?.contentSnapshot == raw)
        #expect(delivery.input.references.first?.revisionSnapshot == String(revision))
        #expect(delivery.context?.noteID == noteID)
        #expect(delivery.context?.remoteEditNonce == nil)
        #expect(delivery.context?.revision == String(revision))
        #expect(delivery.delivery == "Use the selected note")
        let cli = try #require(delivery.input.cliContext)
        #expect(cli.executablePath == (remote ? "/fixture/remote/wovenmatter" : fixture.directory.appending(path: "wovenmatter-fixture").path))
        #expect((cli.socketPath == nil) == remote)
        #expect(try await fixture.database.inputContext(id: cli.captureID, callerID: conversationID) == noteID)
        #expect(await fixture.model.canonicalActiveRunID(conversationID: conversationID) == sent.runID)
        let stop = CompanionCommand(deviceID: fixture.device, kind: .stop,
            conversationID: conversationID, runID: sent.runID)
        #expect(try await fixture.model.companionCommands.execute(stop, deviceID: fixture.device).status == .completed)
        #expect(await fixture.model.canonicalActiveRunID(conversationID: conversationID) == nil)
    }

    @Test func mobileStopFencesPreparationAndAdvancesBackendRevisionOnlyForItsRun() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let id = try await fixture.createConversation(gateway: false)
        let run = try await fixture.database.beginLocalACPRun(conversationID: id, input: .init(text: "Active"))
        let backend = BackendApplicationService(model: fixture.model)
        fixture.model.backendApplicationService = backend
        defer { fixture.model.backendApplicationService = nil }
        let pending = fixture.model.beginAgentDispatch(conversationID: id)
        defer { fixture.model.finishAgentDispatch(conversationID: id, fence: pending) }
        await #expect(throws: (any Error).self) {
            try await fixture.model.cancelCanonicalRun(conversationID: id, runID: UUID().uuidString)
        }
        #expect(!pending.isCancelled)
        #expect(backend.dispatchStopRevisions[id] == nil)
        try await fixture.model.cancelCanonicalRun(conversationID: id, runID: run.runID)
        #expect(pending.isCancelled)
        #expect(backend.dispatchStopRevisions[id] == 1)
        try await fixture.model.waitForAgentStop(conversationID: id)
        #expect(try await fixture.database.activeRunID(conversationID: id) == nil)
    }

    @Test(arguments: [false, true])
    func openNoteDoesNotPreventDesktopSteering(gateway: Bool) async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let id = try await fixture.createConversation(gateway: gateway)
        let raw = try NoteDocument(blocks: [.richText(.init(text: "Keep the existing grant"))]).encoded()
        let noteID = try await fixture.database.createNote(folderID: nil, title: "Open note", content: raw)
        let note = try #require(try await fixture.database.workspaceOverview().notes.first)
        let originalContext = AgentNoteContext(noteID: noteID, title: note.title, folderID: nil,
            revision: note.revision ?? "1", artifactKind: .note)
        let run = try await fixture.database.beginLocalACPRun(conversationID: id, input: .init(text: "Initial"), noteContext: originalContext)
        try await fixture.model.configureCompanionFixture(directory: fixture.directory)
        let conversation = try #require(try await fixture.database.workspaceOverview().conversations.first(where: { $0.id == id }))
        #expect(await fixture.model.sendAgentMessage(conversation: conversation, input: .init(text: "Desktop follow-up"), note: note))
        let desktop = try #require(await fixture.recorder.deliveries.first)
        #expect(desktop.route == (gateway ? .gateway : .localACP))
        #expect(desktop.delivery == "Desktop follow-up")
        let desktopCLI = try #require(desktop.input.cliContext)
        #expect(try await fixture.database.inputContext(id: desktopCLI.captureID, callerID: id) == noteID)
        #expect(desktop.context == nil)
        #expect(await fixture.recorder.deliveries.count == 1)
        let revision = try #require(try await fixture.database.companionNote(id: noteID)?.revision)
        let mobile = CompanionCommand(deviceID: fixture.device, kind: .steer, conversationID: id,
            runID: run.runID, text: "Phone follow-up", noteID: noteID, noteRevision: revision)
        #expect(try await fixture.model.companionCommands.execute(mobile, deviceID: fixture.device).status == .completed)
        let phone = try #require(await fixture.recorder.deliveries.last)
        #expect(phone.context == nil && phone.delivery == "Phone follow-up")
        let phoneCLI = try #require(phone.input.cliContext)
        #expect(phoneCLI.captureID != desktopCLI.captureID)
        #expect(try await fixture.database.inputContext(id: phoneCLI.captureID, callerID: id) == nil)
        #expect(phone.input.references.first?.contentSnapshot == raw)
        #expect(try await fixture.database.conversationContent(id: id).runs.count == 1)
        let wrong = CompanionCommand(deviceID: fixture.device, kind: .stop, conversationID: id, runID: UUID().uuidString)
        #expect(try await fixture.model.companionCommands.execute(wrong, deviceID: fixture.device).status == .rejected)
        #expect(await fixture.model.canonicalActiveRunID(conversationID: id) == run.runID)
    }

    @Test(arguments: ["local", "remote", "gateway"])
    func folderDeletedDuringCreateAwaitLeavesNoSessionAndRetryIsStable(route: String) async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let folder = try await fixture.database.createFolder(name: "Will be deleted")
        let id = UUID().uuidString.lowercased()
        let providerID = route == "gateway" ? "gateway:\(fixture.gatewayID.uuidString.lowercased())"
            : route == "remote" ? "remote:\(fixture.remote.id.uuidString.lowercased()):codex" : "local:codex"
        let command = CompanionCommand(deviceID: fixture.device, kind: .createSession,
            conversationID: id, providerID: providerID, folderID: folder)
        await fixture.recorder.holdCreation()
        let pending = Task { try await fixture.model.companionCommands.execute(command, deviceID: fixture.device) }
        do { try await fixture.recorder.waitForCreation() }
        catch {
            await fixture.recorder.releaseCreation()
            _ = try? await pending.value
            throw error
        }
        _ = try await fixture.database.deleteFolder(id: folder)
        await fixture.recorder.releaseCreation()
        let receipt = try await pending.value
        #expect(receipt.status == .rejected)
        #expect(try await fixture.database.workspaceOverview().conversations.isEmpty)
        #expect(try await fixture.model.companionCommands.execute(command, deviceID: fixture.device) == receipt)
        #expect(try await fixture.database.workspaceOverview().conversations.isEmpty)
    }

    @Test(arguments: [false, true])
    func unavailableNativeOpenCodeNeverFallsBackToACP(remote: Bool) async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let providerID = remote ? "remote:\(fixture.remote.id.uuidString.lowercased()):opencode" : "local:opencode"
        let provider = try #require(fixture.model.companionCommands.providers().first { $0.id == providerID })
        #expect(!provider.available && !provider.canStart)
        let command = CompanionCommand(deviceID: fixture.device, kind: .createSession,
            conversationID: UUID().uuidString.lowercased(), providerID: providerID)
        #expect(try await fixture.model.companionCommands.execute(command, deviceID: fixture.device).status == .rejected)
        #expect(try await fixture.database.workspaceOverview().conversations.isEmpty)
        #expect(await fixture.recorder.deliveries.isEmpty)
        let id = remote
            ? try await fixture.database.createRemoteACPSession(runtimeKind: .opencode, remoteWorkspaceID: fixture.remote.id,
                remoteWorkspaceName: fixture.remote.name, title: "Disconnected native", ownerDeviceID: UUID())
            : try await fixture.database.createLocalACPSession(runtimeKind: .opencode, title: "Disconnected native", ownerDeviceID: UUID())
        let capability = try await fixture.model.companionCommands.sessionCapabilities(conversationID: id)
        #expect(capability.activeInputMode == "unsupported" && !capability.canSteer && !capability.canStop)
    }

    @Test(arguments: ["local", "remote", "gateway"])
    func newPhoneSessionsConfirmCapturedDefaultsAndEnforceTheirTools(route: String) async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let runtime: AgentRuntimeKind = route == "gateway" ? .openclaw : .codex
        let scope = route == "remote" ? "remote:" + fixture.remote.id.uuidString.lowercased()
            : "local:" + fixture.directory.standardizedFileURL.path
        let desired = SessionSelections(model: "requested-model", thinking: "high", permission: "fixture-permission", tools: ["history"])
        fixture.model.sessionSelectionPreferences.saveDefaults(desired, harness: runtime.rawValue, workspace: scope)
        await fixture.recorder.confirmModelAs("provider-confirmed-model")
        let id = UUID().uuidString.lowercased()
        let create = CompanionCommand(deviceID: fixture.device, kind: .createSession, conversationID: id,
            providerID: fixture.providerID(route))
        let receipt = try await fixture.model.companionCommands.execute(create, deviceID: fixture.device)
        #expect(receipt.status == .completed, "\(receipt.message ?? "No create error")")
        let applied = try #require(fixture.model.sessionSelectionPreferences.conversation(id: id))
        #expect(applied.workspace == scope)
        #expect(applied.desiredSelections == SessionSelections(model: "provider-confirmed-model",
            thinking: desired.thinking, permission: desired.permission, tools: desired.tools))
        #expect(!applied.requiresApplication && applied.selections.model == "provider-confirmed-model")
        #expect(applied.selections.thinking == desired.thinking && applied.selections.permission == desired.permission)
        #expect(try await fixture.database.sessionTools(id).enabled == [.history])
        let configurations = await fixture.recorder.configurations
        #expect(configurations.count == 1)
        #expect(configurations.first?.selections == SessionSelections(model: desired.model,
            thinking: desired.thinking, permission: desired.permission))
        if route == "gateway" {
            let native = try #require(await fixture.recorder.gatewayCreations.first)
            #expect(native.agentID == fixture.gatewayID && native.directory == fixture.directory && native.recover)
        }
        fixture.model.sessionSelectionPreferences.saveDefaults(.init(model: "later-default", tools: ["notes"]),
            harness: runtime.rawValue, workspace: scope)
        #expect(try await fixture.model.companionCommands.execute(create, deviceID: fixture.device) == receipt)
        #expect(await fixture.recorder.configurations.count == 1)
        let raw = try NoteDocument(blocks: [.richText(.init(text: "Reference without edit access"))]).encoded()
        let noteID = try await fixture.database.createNote(folderID: nil, title: "Read-only reference", content: raw)
        let revision = try #require(try await fixture.database.companionNote(id: noteID)?.revision)
        let send = CompanionCommand(deviceID: fixture.device, kind: .send, conversationID: id,
            text: "Inspect this reference", noteID: noteID, noteRevision: revision)
        let sent = try await fixture.model.companionCommands.execute(send, deviceID: fixture.device)
        #expect(sent.status == .completed, "\(sent.message ?? "No send error")")
        let delivery = try #require(await fixture.recorder.deliveries.first)
        #expect(delivery.route == (route == "gateway" ? .gateway : .localACP))
        #expect(delivery.context == nil && delivery.input.references.first?.contentSnapshot == raw)
        #expect(delivery.input.cliContext != nil)
        #expect(try await fixture.database.sessionTools(id).enabled == [.history])
        let tools = try #require(fixture.model.agentTools)
        let deniedNote = await tools.handle(.init(arguments: ["notes", "read", noteID]), callerID: id)
        #expect(!deniedNote.success)
        try await fixture.database.recordHistory(.init(id: "phone-visible-history", conversationID: id,
            harness: runtime.rawValue, kind: "fixture.result", payload: "Retained phone session result"))
        let history = await tools.handle(.init(arguments: ["history", "events", "--conversation", id, "--kind", "fixture.result"]), callerID: id)
        #expect(history.success)
        #expect(history.result?.objectValue?["rows"]?.arrayValue?.first?.objectValue?["id"]?.stringValue == "phone-visible-history")
    }

    @Test func unconfirmedDefaultsBlockSendingAndRetryTheirOriginalSnapshot() async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let desired = SessionSelections(model: "captured-model", permission: "agent-full-access", tools: ["notes"])
        fixture.model.sessionSelectionPreferences.saveDefaults(desired, harness: "codex")
        await fixture.recorder.rejectConfiguration(true)
        let id = UUID().uuidString.lowercased()
        let create = CompanionCommand(deviceID: fixture.device, kind: .createSession,
            conversationID: id, providerID: "local:codex")
        #expect(try await fixture.model.companionCommands.execute(create, deviceID: fixture.device).status == .completed)
        #expect(fixture.model.sessionSelectionPreferences.conversation(id: id)?.requiresApplication == true)
        let blocked = CompanionCommand(deviceID: fixture.device, kind: .send, conversationID: id, text: "Wait for configuration")
        #expect(try await fixture.model.companionCommands.execute(blocked, deviceID: fixture.device).status == .rejected)
        #expect(await fixture.recorder.deliveries.isEmpty)
        fixture.model.sessionSelectionPreferences.saveDefaults(.init(model: "new-default", tools: ["history"]), harness: "codex")
        await fixture.recorder.rejectConfiguration(false)
        let retry = CompanionCommand(deviceID: fixture.device, kind: .send, conversationID: id, text: "Use captured configuration")
        #expect(try await fixture.model.companionCommands.execute(retry, deviceID: fixture.device).status == .completed)
        #expect(fixture.model.sessionSelectionPreferences.conversation(id: id)?.desiredSelections == desired)
        #expect(fixture.model.sessionSelectionPreferences.conversation(id: id)?.requiresApplication == false)
        #expect(try await fixture.database.sessionTools(id).enabled == [.notes])
        #expect(await fixture.recorder.configurations.last?.selections.model == "captured-model")
        #expect(await fixture.recorder.deliveries.count == 1)
    }

    @Test func controlsNeverReadHistoricalMessageBodiesAndTranscriptRemainsPaged() async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let id = try await fixture.createConversation(gateway: false)
        let run = try await fixture.database.beginLocalACPRun(conversationID: id, content: "Current")
        // Thousands of historical bodies make any accidental full-content lookup visible
        // in the actual SQL trace; the assertion does not rely on machine timing.
        try await fixture.database.write { db in
            try db.executeUnlocked("""
                WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 2400)
                INSERT INTO dashboard_messages(id,conversation_id,role,content,created_at,updated_at,desktop_owned)
                SELECT 'historical-' || x, '\(id)', 'user', hex(zeroblob(2048)), '2020-01-01', '2020-01-01', 1 FROM n
                """)
        }
        try await fixture.model.configureCompanionFixture(directory: fixture.directory)
        let trace = SQLTrace()
        try await fixture.database.inspectConnections { db in
            let statement = try db.prepareUnlocked("SELECT 1")
            defer { sqlite3_finalize(statement) }
            sqlite3_trace_v2(sqlite3_db_handle(statement), UInt32(SQLITE_TRACE_STMT), traceFacadeSQL,
                             Unmanaged.passUnretained(trace).toOpaque())
        }
        defer {
            let database = fixture.database
            Task { [trace] in try? await database.inspectConnections { db in
                _ = trace // Keep the observer alive until all hooks are removed.
                let statement = try db.prepareUnlocked("SELECT 1")
                defer { sqlite3_finalize(statement) }
                sqlite3_trace_v2(sqlite3_db_handle(statement), 0, nil, nil)
            } }
        }
        #expect(await fixture.model.canonicalActiveRunID(conversationID: id) == run.runID)
        #expect(try await fixture.model.companionCommands.sessionCapabilities(conversationID: id).canStop)
        #expect(!trace.statements.contains(where: { $0.contains("FROM dashboard_messages") }))
        let page = try await fixture.model.companionCommands.transcript(conversationID: id)
        #expect(page.messages.count == 80 && page.olderCursor != nil)
        #expect(page.activeRunID == run.runID)
        let bodyQueries = trace.statements.filter { $0.contains("FROM dashboard_messages") && $0.contains("message.content") }
        #expect(bodyQueries.count == 1)
        #expect(bodyQueries.allSatisfy { $0.contains("LIMIT 81") })
        try await fixture.model.companionCommands.stop(conversationID: id, runID: run.runID)
        #expect(await fixture.model.canonicalActiveRunID(conversationID: id) == nil)
    }
}

@MainActor final class FacadeFixture {
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
        store = try await DashboardStore(supportDirectory: directory, runControls: .init(
            accept: { route, id, input, delivery, context in try await recorder.accept(route, id, input, delivery, context) },
            steer: { route, id, input, delivery, runID in try await recorder.steer(route, id, input, delivery, runID) },
            cancel: { route, id, runID in try await recorder.cancel(route, id, runID) },
            sessionConfiguration: { id in try await recorder.sessionConfiguration(id) },
            configureSession: { id, selections, workspace in
                try await recorder.configureSession(id, selections: selections, directory: workspace?.rootURL.path)
            },
            createGatewaySession: { agentID, key, directory, recover in
                await recorder.createGatewaySession(agentID, key: key, directory: directory, recover: recover)
            },
            patchGatewaySession: { id, preferences in try await recorder.patchGatewaySession(id, preferences: preferences) },
            gatewaySessionMetadata: { id in try await recorder.gatewayMetadata(id) },
            beforeSessionCreation: { await recorder.beforeCreation() }))
        await recorder.configure(database: store.database)
        model = ApplicationModel(applicationDefaults: defaults, dashboardStore: store, startsAutomatically: false)
        try await database.saveOpenClawGatewayLink(.init(agentID: gatewayID, location: .localAgentWorkspace,
            endpoint: .init(url: URL(string: "ws://127.0.0.1:1")!, authorization: .localService), status: OpenClawGatewayConnectionStatus.ready.rawValue))
        let status: RemoteWorkspaceStatus = try decode(#"{"id":"fixture","name":"Fixture","state":"running","running":true,"startedAt":"","image":"fixture","memoryBytes":0,"swapBytes":0,"hostPort":7337,"persistentVolume":"fixture","capabilities":{"memory":false,"swap":false},"storageKind":"fixture","hostStorageLow":false,"legacyStorage":false}"#)
        let harnesses: [RemoteHarnessStatus] = try AgentRuntimeKind.allCases.map { runtime in
            try decode("""
                {"id":"\(runtime.rawValue)","displayName":"\(runtime.displayName)","transport":"\(runtime == .opencode ? "native" : "acp")","capabilities":[],"state":"\(runtime == .opencode ? "transport_unavailable" : "ready")","authenticationStatus":"ready","setupMethods":[],"detectedProviders":[]}
                """)
        }
        let maintenance: [RemoteRuntimeMaintenance] = try AgentRuntimeKind.allCases.map { runtime in
            try decode("""
                {"id":"\(runtime.rawValue)","displayName":"\(runtime.displayName)","enabled":true,"visible":true,"installed":true,"components":[],"failureCount":0,"updateAvailable":false}
                """)
        }
        model.remoteWorkspaces.configureCompanionFixture(remote, status: status, harnesses: harnesses, maintenance: maintenance)
        try await model.configureCompanionFixture(directory: directory)
    }
    func providerID(_ route: String) -> String {
        route == "gateway" ? "gateway:\(gatewayID.uuidString.lowercased())"
            : route == "remote" ? "remote:\(remote.id.uuidString.lowercased()):codex" : "local:codex"
    }
    func createConversation(gateway: Bool) async throws -> String {
        if gateway {
            return try await database.createLocalACPSession(runtimeKind: .openclaw, title: "Gateway",
                ownerDeviceID: UUID(), gatewayAgentID: gatewayID)
        }
        return try await database.createRemoteACPSession(runtimeKind: .codex, remoteWorkspaceID: remote.id,
            remoteWorkspaceName: remote.name, title: "Remote", ownerDeviceID: UUID())
    }
    func remove() {
        model.agentTools?.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    private func decode<T: Decodable>(_ value: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(value.utf8)) }
}

private enum FixtureError: Error { case configurationRejected, creationTimedOut }

actor FacadeRecorder {
    struct Delivery: Sendable {
        let route: DashboardRunControlAdapters.Route
        let input: AgentMessageInput
        let delivery: String?
        let context: AgentNoteContext?
    }
    struct Configuration: Sendable {
        let conversationID: String
        let selections: SessionSelections
        let directory: String?
    }
    struct GatewayCreation: Sendable {
        let agentID: UUID
        let key: String
        let directory: URL
        let recover: Bool
    }
    var deliveries: [Delivery] = []
    var configurations: [Configuration] = []
    var gatewayCreations: [GatewayCreation] = []
    private var confirmedModel: String?
    private var configurationRejected = false
    private var database: WorkspaceDatabase!
    private var creationHeld = false
    private var creationArrived = false
    private var release: CheckedContinuation<Void, Never>?
    private var gatewayCreationHeld = false
    private var gatewayCreationArrived = false
    private var gatewayRelease: CheckedContinuation<Void, Never>?
    func configure(database: WorkspaceDatabase) { self.database = database }
    func accept(_ route: DashboardRunControlAdapters.Route, _ id: String, _ input: AgentMessageInput,
                _ delivery: String?, _ context: AgentNoteContext?) async throws -> LocalACPRunIdentifiers {
        deliveries.append(.init(route: route, input: input, delivery: delivery, context: context))
        return try await database.beginLocalACPRun(conversationID: id, input: input, noteContext: context)
    }
    func steer(_ route: DashboardRunControlAdapters.Route, _ id: String, _ input: AgentMessageInput,
               _ delivery: String?, _ expectedRunID: String?) async throws -> LocalACPSteeringIdentifiers {
        guard let runID = try await database.activeRunID(conversationID: id), expectedRunID == nil || expectedRunID == runID else {
            throw LocalACPSessionDatabaseError.runNotFound
        }
        deliveries.append(.init(route: route, input: input, delivery: delivery, context: nil))
        return try await database.beginLocalACPSteeringTurn(runID: runID, input: input)
    }
    func cancel(_ route: DashboardRunControlAdapters.Route, _ id: String, _ expectedRunID: String?) async throws {
        guard let runID = try await database.activeRunID(conversationID: id), expectedRunID == nil || expectedRunID == runID else {
            throw LocalACPSessionDatabaseError.runNotFound
        }
        try await database.cancelLocalACPRun(runID: runID)
    }
    func confirmModelAs(_ value: String?) { confirmedModel = value }
    func rejectConfiguration(_ value: Bool) { configurationRejected = value }
    func sessionConfiguration(_ id: String) async throws -> LocalACPSessionConfiguration {
        let native = try await database.localACPSession(conversationID: id)
        return .init(model: native.model, thinking: native.thinking, permission: native.permission,
            permissionOptions: ["fixture-permission"])
    }
    func configureSession(_ id: String, selections: SessionSelections, directory: String?) async throws -> LocalACPSessionConfiguration {
        configurations.append(.init(conversationID: id, selections: selections, directory: directory))
        if configurationRejected { throw FixtureError.configurationRejected }
        let prior = try await database.localACPSession(conversationID: id)
        let confirmed = LocalACPSessionConfiguration(model: confirmedModel ?? selections.model ?? prior.model,
            thinking: selections.thinking ?? prior.thinking, permission: selections.permission ?? prior.permission,
            workingDirectory: directory)
        try await database.updateLocalACPSessionConfiguration(conversationID: id,
            model: confirmed.model, thinking: confirmed.thinking, permission: confirmed.permission)
        return confirmed
    }
    func createGatewaySession(_ agentID: UUID, key: String, directory: URL, recover: Bool) async {
        gatewayCreations.append(.init(agentID: agentID, key: key, directory: directory, recover: recover))
        guard gatewayCreationHeld else { return }
        gatewayCreationArrived = true
        await withCheckedContinuation { gatewayRelease = $0 }
    }
    func holdGatewayCreation() { gatewayCreationHeld = true }
    func waitForGatewayCreation() async throws {
        for _ in 0..<200 {
            if gatewayCreationArrived { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureError.creationTimedOut
    }
    func releaseGatewayCreation() { gatewayCreationHeld = false; gatewayRelease?.resume(); gatewayRelease = nil }
    func patchGatewaySession(_ id: String, preferences: OpenClawSessionPreferences) async throws -> OpenClawSessionPreferences {
        let result = try await configureSession(id, selections: SessionSelections(model: preferences.model,
            thinking: preferences.thinkingLevel, permission: preferences.permissionMode), directory: nil)
        return .init(model: result.model, thinkingLevel: result.thinking, permissionMode: result.permission)
    }
    func gatewayMetadata(_ id: String) async throws -> LocalACPSessionMetadata {
        let session = try await database.localACPSession(conversationID: id)
        return LocalACPSessionMetadata(sessionKey: id, model: session.model, thinking: session.thinking,
            modelOptions: [session.model].compactMap { $0 }, thinkingLevels: [], slashCommands: [], permission: session.permission)
    }
    func holdCreation() { creationHeld = true }
    func beforeCreation() async {
        guard creationHeld else { return }
        creationArrived = true
        await withCheckedContinuation { release = $0 }
    }
    func waitForCreation() async throws {
        for _ in 0..<200 {
            if creationArrived { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureError.creationTimedOut
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
