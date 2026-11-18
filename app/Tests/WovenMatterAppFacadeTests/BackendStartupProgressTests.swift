import Foundation
import Testing
import WovenMatterLibraryStore
@testable import WovenMatterAppFacade

/// The first open after an update can upgrade the library for minutes. The
/// background service reports it while it is not ready, and a window keeps
/// waiting for as long as it does, instead of giving up after the timeout.
@MainActor @Suite
struct BackendStartupProgressTests {
    @Test func reportedWorkKeepsTheReadinessBarrierWaitingPastItsTimeout() async throws {
        let start = ContinuousClock.now
        var launches = 0
        // Reports work for three timeouts' worth of time, then becomes ready.
        try await WovenMatterBackendProcess.ensureReady(timeout: 1, check: {
            ContinuousClock.now - start < .seconds(3) ? .working : .ready
        }, ownerIsPresent: { true }, launch: { launches += 1 })
        #expect(ContinuousClock.now - start >= .seconds(3))
        #expect(launches == 0)
    }

    @Test func aSilentOwnerStillFailsAfterTheTimeout() async throws {
        let start = ContinuousClock.now
        var launches = 0
        await #expect(throws: (any Error).self) {
            try await WovenMatterBackendProcess.ensureReady(timeout: 0.25, check: { .notReady },
                                                           ownerIsPresent: { false }, launch: { launches += 1 })
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(launches == 1)
    }

    /// Work that stops being reported counts toward the timeout again.
    @Test func theTimeoutCountsFromTheLastReport() async throws {
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await WovenMatterBackendProcess.ensureReady(timeout: 1, check: {
                ContinuousClock.now - start < .milliseconds(1500) ? .working : .notReady
            }, ownerIsPresent: { true }, launch: {})
        }
        #expect(ContinuousClock.now - start >= .milliseconds(2400))
    }

    @Test func aLibraryUpgradeIsDescribedByItsStage() throws {
        let started = Date()
        func progress(_ stage: LibraryUpgradeProgress.Stage, _ fraction: Double) -> BackendStartupProgress {
            .init(libraryUpgrade: .init(stage: stage, fraction: fraction, libraryBytes: 2_134_102_016, startedAt: started))
        }
        let converting = progress(.converting, 0.4)
        #expect(converting.title == "Upgrading your library")
        #expect(converting.detail.contains("2.13 GB"))
        #expect(converting.fraction == 0.4)
        #expect(progress(.compacting, 0.9).detail.contains("last step"))
        #expect(progress(.backingUp, 1.4).fraction == 1)
    }

    /// A service from before this report answers without it, and a newer
    /// one's report survives the round trip.
    @Test func readinessCarriesTheReportWhenThereIsOne() throws {
        let older = #"{"protocolVersion":1,"instanceID":"\#(UUID().uuidString)","ready":false,"completeClientRouting":true,"capabilities":[]}"#
        #expect(try JSONDecoder().decode(BackendApplicationReadiness.self, from: Data(older.utf8)).startupProgress == nil)
        let report = BackendStartupProgress(title: "Upgrading your library", detail: "Detail", fraction: 0.5)
        let readiness = BackendApplicationReadiness(protocolVersion: 1, instanceID: UUID(), ready: false,
                                                    completeClientRouting: true, capabilities: [], startupProgress: report)
        #expect(try JSONDecoder().decode(BackendApplicationReadiness.self, from: JSONEncoder().encode(readiness)).startupProgress == report)
    }
}
