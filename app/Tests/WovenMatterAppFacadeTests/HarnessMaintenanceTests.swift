import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct HarnessMaintenanceTests {
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
