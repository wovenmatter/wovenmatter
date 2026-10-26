import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct HarnessMaintenanceTests {
    @Test func installedHarnessesIgnoreLegacyHidingAndDisabling() async throws {
        let fixture = try await FacadeFixture(legacyHiddenHarnesses: true); defer { fixture.remove() }
        let kinds = Set(fixture.model.installedOrderedLocalCLIAgents.map(\.runtimeKind))
        #expect(kinds.contains(.codex))
        #expect(kinds.contains(.claudeCode))
        #expect(!kinds.contains(.opencode)) // The fixture has no local OpenCode installation.
        let snapshot = fixture.model.backendRuntimeSnapshot()
        #expect(snapshot.installedKinds.contains(.codex))
        #expect(snapshot.installedKinds.contains(.claudeCode))
        #expect(fixture.defaults.bool(forKey: "wovenmatter.credential-access.disclosure-acknowledged") == false)
    }

    @Test func remoteAvailabilityIgnoresRetiredFlagsButRequiresInstallation() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let model = fixture.model.remoteWorkspaces
        let workspace = fixture.remote
        let status = try #require(model.statuses[workspace.id])
        let harnesses = model.currentHarnesses(for: workspace)
        let rows = try #require(model.runtimeMaintenance[workspace.id])
        for installed in [true, false] {
            let changed = try rows.map { row in
                var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
                object["enabled"] = false; object["visible"] = false
                object["installed"] = installed
                return try JSONDecoder().decode(RemoteRuntimeMaintenance.self, from: JSONSerialization.data(withJSONObject: object))
            }
            model.configureCompanionFixture(workspace, status: status, harnesses: harnesses, maintenance: changed)
            #expect(model.isRuntimeInstalled(.codex, in: workspace) == installed)
            #expect(model.readyChatTargets.contains { $0.harness.id == .codex } == installed)
        }
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
