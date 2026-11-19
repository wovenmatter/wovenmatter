import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterLibraryStore
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
        let detail = "\(definition.commandName) is missing. Install the current Woven Matter-managed adapter."
        var snapshot = fixture.model.backendRuntimeSnapshot()
        snapshot.availability = [.init(runtimeKind: runtime, displayName: runtime.displayName,
            state: .adapterMissing, detail: detail, executablePath: "/fixture/\(definition.commandName)")]
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
        remote.configureFacadeFixture(fixture.remote, status: status, harnesses: [], maintenance: rows)
        await fixture.model.synchronizeRemoteAgentCatalog()
        let saved = fixture.model.remoteWorkspaceAgents
        #expect(Set(saved.map(\.runtimeKind)) == [.defaultAgent, .codex])
        #expect(saved.allSatisfy { $0.runtimeStatus == .offline })
        #expect(remote.readyChatTargets.isEmpty)
        await fixture.model.synchronizeRemoteAgentCatalog()
        #expect(fixture.model.remoteWorkspaceAgents == saved)

        // A new database/model instance has no SSH results, tokens or network calls.
        fixture.defaults.set(try JSONEncoder().encode([fixture.remote]), forKey: RemoteWorkspacesModel.storageKey)
        let reopenedStore = try await LibraryStore(supportDirectory: fixture.directory)
        let reopened = ApplicationModel(applicationDefaults: fixture.defaults, libraryStore: reopenedStore,
                                        startsAutomatically: false, localUsageService: fixture.usageService)
        await reopened.refreshWorkspace()
        #expect(reopened.remoteWorkspaces.statuses.isEmpty)
        #expect(reopened.remoteWorkspaces.runtimeMaintenance.isEmpty)
        #expect(reopened.remoteWorkspaces.readyChatTargets.isEmpty)
        // The sidebar lists the saved host and its agents with no status and no registry row.
        let other = RemoteWorkspaceConfiguration(name: "Other", workspaceID: "other", hostName: "other.invalid",
                                                 dataRoot: "/data", workspaceRoot: "/workspace")
        let links = RemoteWorkspaceSidebarModel.links(configurations: reopened.remoteWorkspaces.workspaces + [other], readyTargets: [],
            registry: [], nameOverrides: [:], localHostDeviceID: nil, localFolderOwnerID: nil)
        let link = try #require(links.first { $0.id == fixture.remote.id.uuidString.lowercased() })
        let listed = RemoteWorkspaceSidebarModel.choices(reopened.remoteWorkspaceAgents, in: link, peerAgentIDs: []).compactMap(\.agent)
        #expect(listed.sorted { $0.id.uuidString < $1.id.uuidString } == saved.sorted { $0.id.uuidString < $1.id.uuidString })
        let unrelated = try #require(links.first { $0.id == other.id.uuidString.lowercased() })
        #expect(RemoteWorkspaceSidebarModel.choices(reopened.remoteWorkspaceAgents, in: unrelated, peerAgentIDs: []).isEmpty)
        // A failed refresh (no inventory) must not remove or rewrite known agents.
        await reopened.synchronizeRemoteAgentCatalog()
        #expect(reopened.remoteWorkspaceAgents == saved)
    }

    /// A Linux host's agent is listed by its owner record like any other:
    /// this Mac's as stored; another Mac's under the host's workspace by the
    /// plain harness name; and nowhere while its owner record or the host's
    /// registry row has not arrived, when it could only be listed under its
    /// stored name for a host this Mac may not manage.
    @Test func aLinuxAgentOfUnknownOwnerIsNotListed() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let database = fixture.database, identity = try await database.libraryIdentity()
        await fixture.model.synchronizeRemoteAgentCatalog()
        let own = Set(fixture.model.remoteWorkspaceAgents.map(\.id))
        #expect(!own.isEmpty && fixture.model.remoteWorkspaceAgents.allSatisfy { $0.runtimeDeviceID == fixture.remote.id })

        // Another Mac's agent for a host it added, as synchronization delivers its row.
        let otherMac = UUID().uuidString.lowercased(), otherHost = UUID()
        let agent = try await database.ensureRemoteHarnessAgent(runtimeKind: .codex, remoteWorkspaceID: otherHost,
            remoteWorkspaceName: "Their host", ownerDeviceID: UUID())
        func arrive(_ sql: String, _ values: [String]) async throws {
            try await database.write { connection in
                try connection.executeUnlocked("UPDATE peer_sync_clock SET applying=1")
                try connection.toolsExecuteUnlocked(sql, values)
                try connection.executeUnlocked("UPDATE peer_sync_clock SET applying=0")
            }
            await fixture.model.refreshWorkspace()
        }
        func listed() -> WorkspaceAgent? { fixture.model.remoteWorkspaceAgents.first { $0.id == agent } }
        let key = agent.uuidString.lowercased()
        // Neither its owner record nor its host's registry row is here.
        try await arrive("DELETE FROM agent_owners WHERE id=?", [key])
        #expect(listed() == nil && Set(fixture.model.remoteWorkspaceAgents.map(\.id)) == own)
        #expect(!fixture.model.localCLIAgents.contains { $0.id == agent })
        // Its owner record alone places it nowhere yet.
        try await arrive("INSERT INTO agent_owners VALUES(?,?)", [key, otherMac])
        #expect(listed() == nil)
        // With the host's registry row it is listed under that workspace, by the plain name.
        let workspace = ExecutionWorkspace(id: otherHost.uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: otherMac,
            kind: .linux, name: "Their host", executionDeviceID: UUID().uuidString.lowercased())
        _ = try await database.registerExecutionWorkspace(.init(workspace: workspace), deviceID: identity.hostDeviceID)
        await fixture.model.refreshWorkspace()
        #expect(listed()?.displayName == AgentRuntimeKind.codex.displayName && listed()?.runtimeDeviceID == otherHost)
        #expect(fixture.model.peerAgentWorkspaces[agent]?.id == workspace.id)
        #expect(Set(fixture.model.remoteWorkspaceAgents.map(\.id)) == own.union([agent]))
        // The pure rule: only an agent this Mac owns, or one placed on a workspace, is presented.
        let stored = try await database.workspaceAgents()
        #expect(ApplicationModel.presentedAgents(stored, own: [], peerWorkspaces: [:]).isEmpty)
        #expect(Set(ApplicationModel.presentedAgents(stored, own: own, peerWorkspaces: [:]).map(\.id)) == own)
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

    /// Settings → Updates: starting one harness's update leaves every other one startable,
    /// both run at once, and a button covering only parts already updating waits.
    @Test func updatesStartedFromSettingsRunSideBySide() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let operations = HeldHarnessUpdates()
        fixture.model.runtimeMaintenanceFixture = { try await operations.run($0) }
        for kind in [AgentRuntimeKind.codex, .claudeCode] {
            fixture.model.setRuntimeInventoryForTesting(try JSONDecoder().decode(RuntimeInventory.self, from: Data("""
                {"kind":"\(kind.rawValue)","components":[{"name":"CLI","installed":"1.0.0","latest":"2.0.0","required":true,"present":true,"verified":true}]}
                """.utf8)))
        }
        let updates = FleetUpdatesModel()
        updates.attach(fixture.model)
        let codex = FleetHarness.Location.thisMac, ids = updates.harnesses(on: codex).map(\.id)
        let codexID = try #require(ids.first { $0.hasSuffix("/" + AgentRuntimeKind.codex.rawValue) })
        let claudeID = try #require(ids.first { $0.hasSuffix("/" + AgentRuntimeKind.claudeCode.rawValue) })
        #expect(updates.canStart(.scope(.harnesses)))

        updates.start(.harness(id: codexID))
        try await eventually { await operations.started == [.codex] }
        #expect(!updates.canStart(.harness(id: codexID)))
        #expect(updates.canStart(.harness(id: claudeID)))
        #expect(updates.canStart(.scope(.harnesses)) && !updates.isUpdating(.scope(.harnesses)))

        updates.start(.harness(id: claudeID))
        try await eventually { await operations.started == [.codex, .claudeCode] }
        #expect(updates.runs.count == 2)
        #expect(!updates.canStart(.scope(.harnesses)) && updates.isUpdating(.scope(.harnesses)))

        try await operations.finish(.claudeCode)
        try await eventually { updates.runs.count == 1 }
        try await operations.finish(.codex)
        try await eventually { !updates.running }
        #expect(updates.failures.isEmpty)
        #expect(await operations.calls == [.codex: 1, .claudeCode: 1])
    }

    /// A vendor's update command counts only when the CLI moved to a newer version; its native
    /// channel may trail the registry's newest, so it doesn't have to reach it.
    @Test func aVendorUpdateMustMoveTheCLI() throws {
        func inventory(cli: String, adapter: String = "2.0.0") -> RuntimeInventory {
            try! JSONDecoder().decode(RuntimeInventory.self, from: Data("""
                {"kind":"codex","components":[
                 {"name":"codex-acp","installed":"\(adapter)","latest":"2.0.0","required":true,"present":true,"verified":true},
                 {"name":"codex CLI","installed":"\(cli)","latest":"1.9.0","required":true,"present":true,"verified":true}]}
                """.utf8))
        }
        let before = inventory(cli: "1.0.0")
        #expect(throws: RuntimeMaintenanceError.self) {
            try ApplicationModel.verifyUpdate(before: before, after: inventory(cli: "1.0.0"), cliName: "codex CLI")
        }
        try ApplicationModel.verifyUpdate(before: before, after: inventory(cli: "1.8.2"), cliName: "codex CLI")
        try ApplicationModel.verifyUpdate(before: before, after: inventory(cli: "1.9.0"), cliName: "codex CLI")
        // The adapter is Woven Matter's own and must reach its target.
        #expect(throws: RuntimeMaintenanceError.self) {
            try ApplicationModel.verifyUpdate(before: inventory(cli: "1.9.0", adapter: "1.0.0"),
                                              after: inventory(cli: "1.9.0", adapter: "1.5.0"), cliName: "codex CLI")
        }
        let unchanged = RuntimeMaintenanceError.unchanged(name: "codex CLI", version: "1.0.0")
        #expect(unchanged.errorDescription == "codex CLI is still 1.0.0: its update command finished without updating it.")
    }

    /// A harness on disk but below the version Woven Matter needs is listed in Settings →
    /// Updates with an update, not hidden as if it weren't installed.
    @Test func aHarnessBelowTheNeededVersionShowsAsAnUpdate() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        fixture.model.setRuntimeInventoryForTesting(try JSONDecoder().decode(RuntimeInventory.self, from: Data("""
            {"kind":"codex","components":[{"name":"codex-acp","installed":"2.6.0","latest":"2.6.0","required":true,"present":true,"verified":false}]}
            """.utf8)))
        let updates = FleetUpdatesModel()
        updates.attach(fixture.model)
        let codex = try #require(updates.harnesses(on: .thisMac).first { $0.kind == .runtime(.codex) })
        #expect(codex.updateAvailable)
        #expect(updates.canStart(.harness(id: codex.id)))
    }

    /// One Update button covering several harnesses starts them all at once, each with
    /// its own progress line, and a slow one doesn't hold up the others.
    @Test func oneButtonUpdatesEveryHarnessAtOnce() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let operations = HeldHarnessUpdates()
        fixture.model.runtimeMaintenanceFixture = { try await operations.run($0) }
        for kind in [AgentRuntimeKind.codex, .claudeCode] {
            fixture.model.setRuntimeInventoryForTesting(try JSONDecoder().decode(RuntimeInventory.self, from: Data("""
                {"kind":"\(kind.rawValue)","components":[{"name":"CLI","installed":"1.0.0","latest":"2.0.0","required":true,"present":true,"verified":true}]}
                """.utf8)))
        }
        let updates = FleetUpdatesModel()
        updates.attach(fixture.model)

        updates.start(.scope(.harnesses))
        // Both start before either finishes.
        try await eventually { await operations.started == [.codex, .claudeCode] }
        #expect(updates.runs.count == 1)
        try await eventually { updates.progress.count == 2 }

        // The second finishes while the first is still running.
        try await operations.finish(.claudeCode)
        try await eventually { updates.progress.count == 1 }
        #expect(updates.running)
        try await operations.finish(.codex)
        try await eventually { !updates.running }
        #expect(updates.failures.isEmpty)
        #expect(await operations.calls == [.codex: 1, .claudeCode: 1])
    }

    /// The Mac server hands every path another Mac's Settings → Updates calls, the
    /// operation it follows included, to the signed member-maintenance handler.
    @Test func theMacServerRoutesEveryPathAnotherMacsUpdatesCall() {
        for path in ["/runtime-maintenance", "/runtime-maintenance/check", "/runtime-maintenance/codex/update",
                     "/default-agent/sdks", "/operations/" + UUID().uuidString.lowercased()] {
            #expect(LibraryHostController.servesMemberMaintenance(path), "\(path)")
        }
        #expect(!LibraryHostController.servesMemberMaintenance("/bots/ws"))
        #expect(!LibraryHostController.servesMemberMaintenance("/library"))
    }

    /// Another Mac's Settings → Updates: the update answers at once with an operation,
    /// which it follows here until the harness finishes.
    @Test func anotherMacFollowsAHarnessUpdateHereAsAnOperation() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let operations = HeldHarnessUpdates()
        fixture.model.runtimeMaintenanceFixture = { try await operations.run($0) }
        func call(_ method: String, _ path: String) async -> LibraryHTTPResponse {
            await fixture.model.memberMaintenance(.init(method: method, target: path, headers: [:], body: Data("{}".utf8)), path: path)
        }
        let started = await call("POST", "/runtime-maintenance/codex/update")
        #expect(started.status == 202)
        let operation = try JSONDecoder().decode(RemoteHarnessOperation.self, from: started.body)
        #expect(operation.status == "running" && operation.harnessID == .codex)
        try await eventually { await operations.started == [.codex] }
        let path = "/operations/" + operation.id.uuidString.lowercased()
        #expect(try JSONDecoder().decode(RemoteHarnessOperation.self, from: await call("GET", path).body).status == "running")
        try await operations.finish(.codex)
        try await eventually {
            (try? JSONDecoder().decode(RemoteHarnessOperation.self, from: await call("GET", path).body))?.status == "succeeded"
        }
        #expect(await call("GET", "/operations/" + UUID().uuidString).status == 404)
        // Pi Durable only updates (its SDKs); there is no harness to check.
        #expect(await call("POST", "/runtime-maintenance/default_agent/check").status == 404)
        #expect(await call("POST", "/runtime-maintenance/unknown/update").status == 404)
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        if try await pollUntil(attempts: 500, interval: .milliseconds(10), { await condition() }) { return }
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
                {"kind":"\(kind.rawValue)","components":[]}
                """.utf8))
            waiter?.resume(returning: inventory)
        }
    }
}
