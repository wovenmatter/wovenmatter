import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct PiBotRuntimeSupervisorTests {
    private let support: URL
    private static let installation = "47f63ead-5bcd-453c-89e1-02678d75b82f"

    init() throws {
        support = FileManager.default.temporaryDirectory.appending(path: "pi-bot-supervisor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    private func make(health: PiBotHealth? = PiBotHealth(ok: true, version: "0.1.0", protocol: 1, installationId: Self.installation, capabilities: ["host.embed"])) -> PiBotRuntimeSupervisor {
        PiBotRuntimeSupervisor(supportDirectory: support, instance: "test",
                               bundleLoader: { throw PiBotHostError.bundleMissing }, healthProbe: { _ in health })
    }

    private func settled(_ supervisor: PiBotRuntimeSupervisor, _ phases: Set<PiBotRuntimeSnapshot.Phase>) async throws {
        for _ in 0..<200 {
            if phases.contains(supervisor.snapshot.phase), !supervisor.snapshot.busy { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Still \(supervisor.snapshot.phase)")
    }

    private func attached(port: Int) -> PiBotDeploymentTarget {
        PiBotDeploymentTarget(kind: .thisMac, ownership: .attached, remotePort: port)
    }

    @Test func aNewInstanceStartsUnconfiguredAndNeverInstallsOnItsOwn() async throws {
        let supervisor = make()
        supervisor.start()
        #expect(supervisor.snapshot.phase == .notConfigured)
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "PiBot").path))
    }

    @Test func anAttachedServerUsesThePortTheUserChose() async throws {
        let supervisor = make()
        _ = try await supervisor.perform(.attach(attached(port: 4317)))
        try await settled(supervisor, [.ready])
        #expect(supervisor.snapshot.baseURL?.port == 4317)
        #expect(supervisor.snapshot.health?.installationId == Self.installation)
        await supervisor.shutdown()
    }

    @Test func aSavedDeploymentResumesWithItsPortAfterRelaunch() async throws {
        let first = make()
        _ = try await first.perform(.attach(attached(port: 4317)))
        try await settled(first, [.ready])
        await first.shutdown()
        let second = make()
        #expect(second.snapshot.target?.remotePort == 4317)
        second.start()
        try await settled(second, [.ready])
        #expect(second.snapshot.baseURL?.port == 4317)
        await second.shutdown()
    }

    @Test func disconnectRevokesTheInstallationsWovenAccess() async throws {
        let supervisor = make()
        var revoked: [String] = []
        supervisor.revokeMCPGrants = { revoked.append($0) }
        _ = try await supervisor.perform(.attach(attached(port: 4317)))
        try await settled(supervisor, [.ready])
        _ = try await supervisor.perform(.forget(abandon: false))
        try await settled(supervisor, [.notConfigured])
        #expect(revoked == [Self.installation])
        #expect(supervisor.snapshot.baseURL == nil)
        #expect(supervisor.snapshot.target == nil)
        let next = make()
        #expect(next.snapshot.phase == .notConfigured)
    }

    @Test func aServerThatNeverAnswersKeepsRetryingInsteadOfClaimingReady() async throws {
        let supervisor = make(health: nil)
        _ = try await supervisor.perform(.attach(attached(port: 4317)))
        try await Task.sleep(for: .milliseconds(150))
        #expect(supervisor.snapshot.phase != .ready)
        #expect(supervisor.snapshot.baseURL == nil)
        await supervisor.shutdown()
    }

    @Test func aManagedInstallWithoutResourcesFailsVisibly() async throws {
        let supervisor = make()
        _ = try await supervisor.perform(.deploy(.thisMac))
        try await settled(supervisor, [.failed])
        #expect(supervisor.snapshot.error?.contains("does not include Pi Bot") == true)
        #expect(supervisor.snapshot.target?.ownership == .managed)
    }

    @Test func aSecondActionWaitsForTheFirst() async throws {
        let supervisor = make()
        _ = try await supervisor.perform(.attach(attached(port: 4317)))
        await #expect(throws: (any Error).self) { _ = try await supervisor.perform(.restart) }
        try await settled(supervisor, [.ready])
        await supervisor.shutdown()
    }

    @Test func removingIsRefusedForAServerWovenDidNotInstall() async throws {
        let supervisor = make()
        _ = try await supervisor.perform(.attach(attached(port: 4317)))
        try await settled(supervisor, [.ready])
        _ = try await supervisor.perform(.remove(deleteData: true))
        try await settled(supervisor, [.ready])
        #expect(supervisor.snapshot.error?.contains("did not install") == true)
        await supervisor.shutdown()
    }
}

struct BotWebRouteTests {
    @Test @MainActor func routesRoundTripBetweenTargetsAndHashes() {
        #expect(BotWebSession.hash(for: DashboardBotTarget(botID: "a")) == "#/a")
        #expect(BotWebSession.hash(for: DashboardBotTarget(botID: "a", conversationID: 7)) == "#/a/7")
        #expect(BotWebSession.hash(for: DashboardBotTarget(botID: "a", conversationID: 7, showsThreadBesideMain: true)) == "#/a/7?view=split")
        #expect(BotWebSession.target(from: ["botId": "a", "conversationId": 7, "threadView": "split"])
            == DashboardBotTarget(botID: "a", conversationID: 7, showsThreadBesideMain: true))
        #expect(BotWebSession.target(from: ["botId": "a"]) == DashboardBotTarget(botID: "a"))
        #expect(BotWebSession.target(from: ["settings": true, "botId": "a"]) == nil)
        #expect(BotWebSession.target(from: [:]) == nil)
    }
}
