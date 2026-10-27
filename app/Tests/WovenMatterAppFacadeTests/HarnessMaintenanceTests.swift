import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct HarnessMaintenanceTests {
    @Test(arguments: [LocalACPRuntimeAvailability.State.executableUnavailable, .authenticationRequired])
    func successfulReplacementInvalidatesExecutableFailureWithoutErasingAccountFailure(state: LocalACPRuntimeAvailability.State) async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        var snapshot = fixture.model.backendRuntimeSnapshot()
        let prior = LocalACPRuntimeAvailability(runtimeKind: .codex, displayName: "Codex", state: state,
            detail: "Prior explicit check", executablePath: "/fixture/codex-acp")
        snapshot.availability = [prior]
        fixture.model.applyBackendRuntimeSnapshot(snapshot)
        let operations = HeldHarnessUpdates()
        fixture.model.runtimeMaintenanceFixture = { try await operations.run($0) }
        fixture.model.updateRuntime(.codex)
        try await eventually { await operations.started == [.codex] }
        try await operations.finish(.codex)
        try await eventually { !fixture.model.runtimeMaintenanceBusy(.codex) }
        let latest = fixture.model.backendRuntimeSnapshot().availability.first { $0.runtimeKind == .codex }
        #expect(latest == (state == .authenticationRequired ? prior : nil))
        #expect(fixture.defaults.bool(forKey: "wovenmatter.credential-access.disclosure-acknowledged") == false)
    }

    @Test(arguments: [AgentRuntimeKind.codex, .claudeCode])
    func unavailableSessionShowsItsSpecificAdapterFailure(runtime: AgentRuntimeKind) async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let definition = try #require(LocalACPRuntimeCatalog.definition(for: runtime))
        let detail = "\(definition.commandName) is outdated. Install the current Woven Matter-managed adapter."
        var snapshot = fixture.model.backendRuntimeSnapshot()
        snapshot.availability = [.init(runtimeKind: runtime, displayName: runtime.displayName,
            state: .adapterOutdated, detail: detail, executablePath: "/fixture/\(definition.commandName)")]
        snapshot.readyKinds.remove(runtime)
        snapshot.launchableKinds.remove(runtime)
        snapshot.workspace = .init(state: .ready, detail: "Fixture", rootPath: fixture.directory.path,
            databasesPath: fixture.directory.appending(path: "datasets").path)
        fixture.model.applyBackendRuntimeSnapshot(snapshot)
        let id = await fixture.model.createLocalACPSession(runtimeKind: runtime, nativeWorkingDirectory: fixture.directory)
        #expect(id == nil)
        #expect(fixture.model.localRunError == detail)
        #expect(try await fixture.database.workspaceOverview().conversations.isEmpty)
        #expect(await fixture.recorder.deliveries.isEmpty)
        // A different or ready harness must not inherit this failure text.
        let other: AgentRuntimeKind = runtime == .codex ? .claudeCode : .codex
        #expect(fixture.model.localACPLaunchUnavailableError(for: other).localizedDescription == ApplicationModelError.localACPRuntimeUnavailable.localizedDescription)
        snapshot.availability = [.init(runtimeKind: runtime, displayName: runtime.displayName,
            state: .ready, detail: "Installed", executablePath: "/fixture/\(definition.commandName)")]
        fixture.model.applyBackendRuntimeSnapshot(snapshot)
        #expect(fixture.model.localACPLaunchUnavailableError(for: runtime).localizedDescription == ApplicationModelError.localACPRuntimeUnavailable.localizedDescription)
    }

    @Test func installedHarnessesPopulateTheRuntimeSnapshot() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let kinds = Set(fixture.model.installedOrderedLocalCLIAgents.map(\.runtimeKind))
        #expect(kinds.contains(.codex))
        #expect(kinds.contains(.claudeCode))
        #expect(!kinds.contains(.opencode)) // The fixture has no local OpenCode installation.
        let snapshot = fixture.model.backendRuntimeSnapshot()
        #expect(snapshot.installedKinds.contains(.codex))
        #expect(snapshot.installedKinds.contains(.claudeCode))
        #expect(fixture.defaults.bool(forKey: "wovenmatter.credential-access.disclosure-acknowledged") == false)
    }

    @Test func remoteCatalogSurvivesRestartWithoutReadinessAndDoesNotRewriteKnownAgents() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let remote = fixture.model.remoteWorkspaces
        let status = try #require(remote.statuses[fixture.remote.id])
        let rows = try #require(remote.runtimeMaintenance[fixture.remote.id])
            .filter { $0.id == .codex || $0.id == .defaultAgent }
        // Installation is enough for navigation; no sign-in/readiness is available.
        remote.configureCompanionFixture(fixture.remote, status: status, harnesses: [], maintenance: rows)
        await fixture.model.synchronizeRemoteAgentCatalog()
        let saved = fixture.model.remoteWorkspaceAgents
        #expect(Set(saved.map(\.runtimeKind)) == [.defaultAgent, .codex])
        #expect(saved.allSatisfy { $0.runtimeStatus == .offline })
        #expect(remote.readyChatTargets.isEmpty)
        await fixture.model.synchronizeRemoteAgentCatalog()
        #expect(fixture.model.remoteWorkspaceAgents == saved)

        // A new database/model instance has no SSH results, tokens or network calls.
        fixture.defaults.set(try JSONEncoder().encode([fixture.remote]), forKey: "wovenmatter.remote-workspaces.v1")
        let reopenedStore = try await DashboardStore(supportDirectory: fixture.directory)
        let reopened = ApplicationModel(applicationDefaults: fixture.defaults, dashboardStore: reopenedStore,
                                        startsAutomatically: false, localUsageService: fixture.usageService)
        await reopened.refreshWorkspace()
        #expect(reopened.remoteWorkspaces.statuses.isEmpty)
        #expect(reopened.remoteWorkspaces.runtimeMaintenance.isEmpty)
        #expect(reopened.remoteWorkspaces.readyChatTargets.isEmpty)
        #expect(DashboardRemoteWorkspaceSidebarModel.agents(reopened.remoteWorkspaceAgents, in: fixture.remote.id) == saved)
        #expect(DashboardRemoteWorkspaceSidebarModel.agents(reopened.remoteWorkspaceAgents, in: UUID()).isEmpty)
        // A failed refresh (no inventory) must not remove or rewrite known agents.
        await reopened.synchronizeRemoteAgentCatalog()
        #expect(reopened.remoteWorkspaceAgents == saved)
    }

    @Test func updatesOverlapAndKeepProgressAndFailuresIndependent() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let operations = HeldHarnessUpdates()
        fixture.model.runtimeMaintenanceFixture = { try await operations.run($0) }
        fixture.model.updateRuntime(.codex)
        fixture.model.updateRuntime(.claudeCode)
        fixture.model.updateRuntime(.codex) // Same-harness double clicks are ignored.
        #expect(fixture.model.updatingRuntimeKinds == [.codex, .claudeCode])
        try await eventually { await operations.started == [.codex, .claudeCode] }
        try await operations.finish(.codex)
        try await eventually { !fixture.model.runtimeMaintenanceBusy(.codex) }
        #expect(fixture.model.runtimeMaintenanceBusy(.claudeCode))
        #expect(fixture.model.runtimeInventories[.codex]?.kind == .codex)
        try await operations.finish(.claudeCode, fail: true)
        try await eventually { fixture.model.updatingRuntimeKinds.isEmpty }
        #expect(fixture.model.failedRuntimeUpdateKinds == [.claudeCode])
        #expect(fixture.model.runtimeFailureDetails[.codex] == nil)
        #expect(fixture.model.runtimeFailureDetails[.claudeCode] != nil)
        #expect(await operations.calls == [.codex: 1, .claudeCode: 1])
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Maintenance did not reach the expected state")
        throw RuntimeMaintenanceError.timeout
    }
}

private actor HeldHarnessUpdates {
    var calls: [AgentRuntimeKind: Int] = [:]
    var started: Set<AgentRuntimeKind> { Set(waiters.keys) }
    private var waiters: [AgentRuntimeKind: CheckedContinuation<RuntimeInventory, any Error>] = [:]
    func run(_ kind: AgentRuntimeKind) async throws -> RuntimeInventory {
        calls[kind, default: 0] += 1
        return try await withCheckedThrowingContinuation { waiters[kind] = $0 }
    }
    func finish(_ kind: AgentRuntimeKind, fail: Bool = false) throws {
        let waiter = waiters.removeValue(forKey: kind)
        if fail { waiter?.resume(throwing: RuntimeMaintenanceError.verification) }
        else {
            let inventory = try JSONDecoder().decode(RuntimeInventory.self, from: Data("""
                {"kind":"\(kind.rawValue)","components":[],"detectedUpdateAvailable":false}
                """.utf8))
            waiter?.resume(returning: inventory)
        }
    }
}
