import WorkspaceFixtures
import CompanionClient
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct DevelopmentLaunchTests {

    @Test func liveHostUsesTheSameExclusiveLeaseAsProduction() throws {
        for mode in [DevelopmentLaunch.Mode.client, .snapshot, .live] {
            let frontend = LocalExecutionRole.resolve(arguments: ["app"], developmentMode: mode)
            let backend = LocalExecutionRole.resolve(arguments: ["app", "--backend"], developmentMode: mode)
            #expect(frontend == .frontend && !frontend.ownsExecution)
            #expect(backend == .backend && backend.ownsExecution)
            #expect(frontend.leaseFileName != backend.leaseFileName)
            let isolated = URL(fileURLWithPath: "/tmp/isolated-client-test")
            #expect(WorkspaceProcessLease.defaultFileURL(isolatedDirectory: isolated, role: frontend)
                != WorkspaceProcessLease.defaultFileURL(isolatedDirectory: isolated, role: backend))
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let role = LocalExecutionRole.resolve(arguments: ["app", "--backend"], developmentMode: .live)
        let file = directory.appending(path: DevelopmentLaunch.Mode.live.workspaceFolder(instance: "fixture"))
            .appending(path: role.leaseFileName)
        let productionFile = directory.appending(path: "Woven Matter/workspace-owner.lock")
        #expect(file == productionFile)
        var lease: WorkspaceProcessLease? = try WorkspaceProcessLease(fileURL: file)
        func otherHostStatus() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", """
            import fcntl, sys
            with open(sys.argv[1], 'r+') as file:
                try: fcntl.lockf(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError: sys.exit(73)
            """, productionFile.path]
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }
        let occupiedStatus = try withExtendedLifetime(lease) { try otherHostStatus() }
        #expect(occupiedStatus == 73)
        lease = nil
        #expect(try otherHostStatus() == 0)
    }

    @Test func duplicateLaunchCanOnlyActivateItsOwnInstance() {
        let production = WorkspaceProcessLeaseOwner(processIdentifier: 1, bundleIdentifier: "wovenmatter.desktop", bundlePath: "/production")
        let own = WorkspaceProcessLeaseOwner(processIdentifier: 2, bundleIdentifier: "wovenmatter.desktop.dev.a.client", bundlePath: "/own")
        var activated: [Int32] = []
        func candidate(_ owner: WorkspaceProcessLeaseOwner) -> WorkspaceProcessLeaseActivationCandidate {
            .init(owner: owner, isTerminated: { false }, activate: { activated.append(owner.processIdentifier); return true })
        }
        let ownHandoff = WorkspaceProcessLease.verifyIncumbentHandoff(own, currentProcessIdentifier: 3,
            currentBundleIdentifier: own.bundleIdentifier, candidateForProcessIdentifier: { _ in candidate(own) },
            candidatesForBundleIdentifier: { _ in [candidate(production)] })
        #expect(ownHandoff == .activated(own))
        activated = []
        let foreignHandoff = WorkspaceProcessLease.verifyIncumbentHandoff(production, currentProcessIdentifier: 3,
            currentBundleIdentifier: own.bundleIdentifier, candidateForProcessIdentifier: { _ in candidate(production) },
            candidatesForBundleIdentifier: { _ in [candidate(production)] })
        #expect(foreignHandoff == .unavailable)
        #expect(activated.isEmpty)
    }

}
