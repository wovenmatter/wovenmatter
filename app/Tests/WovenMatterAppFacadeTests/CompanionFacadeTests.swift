import WorkspaceFixtures
import AppKit
import Foundation
import SQLite3
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CompanionFacadeTests {

    @Test func goalSlashCommandAtCapacityDoesNotPersistOrDispatch() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let id = try await fixture.createConversation()
        let conversation = try #require(try await fixture.database.workspaceOverview().conversations.first { $0.id == id })
        var settings = try await fixture.database.toolSettings()
        settings.maximumRunningSessions = 1
        try await fixture.database.saveToolSettings(settings)
        try await fixture.model.agentTools?.reload()
        let busyID = try await fixture.createConversation()
        let busy = try #require(try await fixture.database.workspaceOverview().conversations.first { $0.id == busyID })
        #expect(try await fixture.model.dispatchAgentMessage(conversation: busy, input: .init(text: "Occupy the slot")))
        #expect(try await fixture.model.dispatchAgentMessage(conversation: conversation,
            input: .init(text: "/goal Fix the fixture")) == false)
        #expect(try await fixture.database.sessionGoals().isEmpty)
        #expect(await fixture.recorder.deliveries.count == 1)
    }


    // OpenCode uses its native coordinator, covered by OpenCodeCoordinatorTests.
    // Every remaining runtime still traverses the real facade and launch routing.

    @Test func mobileStopFencesPreparationAndAdvancesBackendRevisionOnlyForItsRun() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let id = try await fixture.createConversation()
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

    @Test(arguments: ["local", "remote"])
    func folderDeletedDuringCreateAwaitLeavesNoSessionAndRetryIsStable(route: String) async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let folder = try await fixture.database.createFolder(name: "Will be deleted", location: .init(
            workspaceID: try await fixture.model.executionWorkspaceIdentity(workspaceID: route == "remote" ? fixture.remote.id : nil),
            rootPath: fixture.directory.path, managed: false))
        let id = UUID().uuidString.lowercased()
        let providerID = route == "remote" ? "remote:\(fixture.remote.id.uuidString.lowercased()):codex" : "local:codex"
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

}

@MainActor final class FacadeFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let store: DashboardStore
    var database: WorkspaceDatabase { store.database }
    let model: ApplicationModel
    let recorder = FacadeRecorder()
    let usageProbe = FacadeUsageProbe()
    let usageService: LocalUsageService
    let device = UUID().uuidString.lowercased()
    let remote = RemoteWorkspaceConfiguration(name: "Fixture remote", workspaceID: "fixture", hostName: "fixture.invalid")
    init(legacyHiddenHarnesses: Bool = false) async throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appending(path: "companion-facade-\(UUID())")
        suite = "companion.facade.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        if legacyHiddenHarnesses {
            defaults.set([], forKey: "wovenmatter.local-acp.enabled-runtimes")
            defaults.set([], forKey: "wovenmatter.local-acp.shown-runtimes")
            defaults.set(["codex", "claude_code"], forKey: "wovenmatter.local-acp.hidden-runtimes")
        }
        let recorder = recorder
        store = try await DashboardStore(supportDirectory: directory, runControls: .init(
            accept: { route, id, input, delivery, context in try await recorder.accept(route, id, input, delivery, context) },
            steer: { route, id, input, delivery, runID in try await recorder.steer(route, id, input, delivery, runID) },
            cancel: { route, id, runID in try await recorder.cancel(route, id, runID) },
            sessionConfiguration: { id in try await recorder.sessionConfiguration(id) },
            configureSession: { id, selections, workspace in
                try await recorder.configureSession(id, selections: selections, directory: workspace?.rootURL.path)
            },
            beforeSessionCreation: { await recorder.beforeCreation() }))
        await recorder.configure(database: store.database)
        let probe = usageProbe
        usageService = LocalUsageService(homeDirectory: directory.appending(path: "ProviderFixtureHome"),
            fileManager: .default, credentialStore: FacadeNoCredentials(probe: probe),
            usageDatabaseURL: directory.appending(path: "usage.sqlite"), sharedConnectionRevision: { 0 },
            limitCollector: { request in probe.collectLimits(request); return [] },
            openRouterActivityFetcher: { _ in probe.record("fetch"); throw FixtureError.configurationRejected })
        model = ApplicationModel(applicationDefaults: defaults, dashboardStore: store, startsAutomatically: false,
            localUsageService: usageService)
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
        route == "remote" ? "remote:\(remote.id.uuidString.lowercased()):codex" : "local:codex"
    }
    func createConversation() async throws -> String {
        return try await database.createRemoteACPSession(runtimeKind: .codex, remoteWorkspaceID: remote.id,
            remoteWorkspaceName: remote.name, title: "Remote", ownerDeviceID: UUID(),
            executionRoot: .init(folderID: nil, location: .init(workspaceID: "remote:" + remote.id.uuidString.lowercased(),
                rootPath: directory.path, managed: false), defaultPath: "/workspace"))
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
    var deliveries: [Delivery] = []
    var configurations: [Configuration] = []
    private var confirmedModel: String?
    private var configurationRejected = false
    private var database: WorkspaceDatabase!
    nonisolated let creationGate = FacadeGate()
    nonisolated let configurationGate = FacadeGate()
    nonisolated let acceptGate = FacadeGate()
    func configure(database: WorkspaceDatabase) { self.database = database }
    func accept(_ route: DashboardRunControlAdapters.Route, _ id: String, _ input: AgentMessageInput,
                _ delivery: String?, _ context: AgentNoteContext?) async throws -> LocalACPRunIdentifiers {
        await acceptGate.pass()
        deliveries.append(.init(route: route, input: input, delivery: delivery, context: context))
        let visible = AgentMessageInput(text: delivery ?? input.text, attachments: input.attachments,
            historyDeliveryID: input.historyDeliveryID, visibleWorkspace: input.visibleWorkspace, mcpContext: input.mcpContext)
        return try await database.beginLocalACPRun(conversationID: id, input: visible, noteContext: context)
    }
    func steer(_ route: DashboardRunControlAdapters.Route, _ id: String, _ input: AgentMessageInput,
               _ delivery: String?, _ expectedRunID: String?) async throws -> LocalACPSteeringIdentifiers {
        guard let runID = try await database.activeRunID(conversationID: id), expectedRunID == nil || expectedRunID == runID else {
            throw LocalACPSessionDatabaseError.runNotFound
        }
        deliveries.append(.init(route: route, input: input, delivery: delivery, context: nil))
        let visible = AgentMessageInput(text: delivery ?? input.text, attachments: input.attachments,
            historyDeliveryID: input.historyDeliveryID, visibleWorkspace: input.visibleWorkspace, mcpContext: input.mcpContext)
        return try await database.beginLocalACPSteeringTurn(runID: runID, input: visible)
    }
    func cancel(_ route: DashboardRunControlAdapters.Route, _ id: String, _ expectedRunID: String?) async throws {
        guard let runID = try await database.activeRunID(conversationID: id) else {
            if expectedRunID == nil { return }
            throw LocalACPSessionDatabaseError.runNotFound
        }
        guard expectedRunID == nil || expectedRunID == runID else { throw LocalACPSessionDatabaseError.runNotFound }
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
        await configurationGate.pass()
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
    func holdCreation() { creationGate.hold() }
    func beforeCreation() async { await creationGate.pass() }
    func waitForCreation() async throws { await creationGate.waitForArrival() }
    func releaseCreation() { creationGate.open() }
    func holdConfiguration() { configurationGate.hold() }
    func waitForConfiguration() async { await configurationGate.waitForArrival() }
    func releaseConfiguration() { configurationGate.open() }

}

final class SQLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var statements: [String] { lock.withLock { values } }
    func append(_ sql: String) { lock.withLock { values.append(sql) } }
}

func traceFacadeSQL(_ mask: UInt32, _ context: UnsafeMutableRawPointer?,
                            _ statement: UnsafeMutableRawPointer?, _ extra: UnsafeMutableRawPointer?) -> Int32 {
    guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
    Unmanaged<SQLTrace>.fromOpaque(context).takeUnretainedValue().append(String(cString: sql))
    return 0
}

// A gate signals arrival without polling. Synchronous open permits unconditional
// defer cleanup even when an assertion or the operation under test throws.
final class FacadeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var arrived = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    func hold() { lock.withLock { held = true; arrived = false } }
    func pass() async {
        await withCheckedContinuation { continuation in
            let result: (Bool, [CheckedContinuation<Void, Never>]) = lock.withLock {
                guard held else { return (false, []) }
                arrived = true
                waiting.append(continuation)
                let observers = arrivals; arrivals = []
                return (true, observers)
            }
            result.1.forEach { $0.resume() }
            if !result.0 { continuation.resume() }
        }
    }
    func waitForArrival() async {
        let deadline = Task { [self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            Issue.record("Fixture gate was not reached within its bounded deadline")
            open()
        }
        defer { deadline.cancel() }
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock {
                if arrived { return true }
                arrivals.append(continuation); return false
            }
            if immediate { continuation.resume() }
        }
    }
    func open() {
        let pending = lock.withLock {
            held = false
            let pending = waiting + arrivals; waiting = []; arrivals = []
            return pending
        }
        pending.forEach { $0.resume() }
    }
}

final class FacadeUsageProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var accesses: [String] = []
    private var expectedPassiveProviders: Set<ProviderKind>?
    private var requests: [UsageLimitsRequest] = []
    var limitRequests: [UsageLimitsRequest] { lock.withLock { requests } }
    func expectPassiveLimits(providers: Set<ProviderKind>) {
        lock.withLock { expectedPassiveProviders = providers }
    }
    func collectLimits(_ request: UsageLimitsRequest) {
        let expected = lock.withLock {
            requests.append(request)
            let expected = expectedPassiveProviders
            expectedPassiveProviders = nil
            return expected
        }
        guard let expected, request.enabledProviders == expected,
              !request.allowCredentialAccess, !request.keychainInteraction.allowsInteraction,
              request.interactiveProvider == nil, request.openRouterAPIKey == nil else {
            record("unexpected limits policy")
            return
        }
    }
    var calls: [String] { lock.withLock { accesses } }
    func record(_ access: String) {
        lock.withLock { accesses.append(access) }
        Issue.record("Facade unexpectedly requested usage \(access)")
    }
}
private struct FacadeNoCredentials: UsageCredentialStoring {
    let probe: FacadeUsageProbe
    func hasOpenRouterAPIKey() throws -> Bool { probe.record("credential existence"); return false }
    func authorizeOpenRouterAPIKey() throws -> String? { probe.record("credential authorization"); return nil }
    func loadOpenRouterAPIKey() throws -> String? { probe.record("credential load"); return nil }
    func saveOpenRouterAPIKey(_ key: String) throws { probe.record("credential save") }
    func deleteOpenRouterAPIKey() throws { probe.record("credential delete") }
}
