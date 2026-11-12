import Foundation
import Testing
import WorkspaceFixtures
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterAppFacade

/// A Linux host this Mac manages is adopted (signed member entry, this Mac as
/// its anchor) and its workspace exposed and enrolled as soon as it is added,
/// without waiting for an earlier enrollment, and retried until it succeeds.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct LinuxHostSetupTests {
    private final class Steps {
        var adopted: [String] = [], enrolled: [String] = [], adoptFailures = 0
    }

    private func install(_ f: FacadeFixture, _ steps: Steps) {
        let host = f.model.libraryHost
        host.linuxHostSetupRetry = .milliseconds(5)
        host.linuxHostSetupSteps = .init(
            adopt: { configuration in
                steps.adopted.append(configuration.id.uuidString.lowercased())
                if steps.adoptFailures > 0 {
                    steps.adoptFailures -= 1
                    throw LibraryAPIError(code: "unavailable", message: "The host's library is starting.")
                }
            },
            enroll: { steps.enrolled.append($0) })
    }

    @Test func aRegisteredHostIsSetUpWithoutAnEnrollmentAndRetriedUntilItSucceeds() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let steps = Steps(); steps.adoptFailures = 2
        install(f, steps)
        let id = f.remote.id.uuidString.lowercased()
        try await f.model.libraryHost.refreshExecutionRegistry()
        // The row names no execution device yet; setup does not wait for one.
        #expect(try await f.database.libraryExecutionWorkspaces().first { $0.id == id }?.executionDeviceID == nil)
        #expect(try await pollUntil(attempts: 500, interval: .milliseconds(5)) { steps.adopted.count == 3 && steps.enrolled.count == 3 })
        #expect(steps.adopted == [id, id, id])
        // Enrollment is tried on every attempt the row is not enrolled; a failed
        // adoption does not hold it back.
        #expect(steps.enrolled == [id, id, id])

        // Set up: later registry refreshes leave it alone for this launch.
        try await f.model.libraryHost.refreshExecutionRegistry()
        try await Task.sleep(for: .milliseconds(50))
        #expect(steps.adopted.count == 3)

        // Adding the host again (it gained its workspace) sets it up at once.
        f.model.libraryHost.setUpLinuxHost(f.remote, restart: true)
        #expect(try await pollUntil(attempts: 500, interval: .milliseconds(5)) { steps.adopted.count == 4 })
    }

    @Test func aBotsOnlyHostIsAdoptedButHasNoWorkspaceToEnroll() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let steps = Steps()
        install(f, steps)
        let bots = RemoteWorkspaceConfiguration(name: "bots.invalid", workspaceID: RemoteHostInstallMode.botsOnlyWorkspaceID,
            hostName: "bots.invalid", kind: .host)
        f.model.remoteWorkspaces.configureFacadeFixture(bots, status: try #require(f.model.remoteWorkspaces.statuses[f.remote.id]),
            harnesses: [], maintenance: [])
        f.model.libraryHost.setUpLinuxHost(bots, restart: true)
        #expect(try await pollUntil(attempts: 500, interval: .milliseconds(5)) { steps.adopted.count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(steps.adopted == [bots.id.uuidString.lowercased()])
        #expect(steps.enrolled.isEmpty)
    }
}
