import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CompanionHostLifecycleTests {
    @Test func backendRPCControlsTheSameHostAndReplaysPairingReceipt() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        try await fixture.model.configureCompanionFixture(directory: fixture.directory)
        fixture.model.companionHost = fixture.host
        let backend = BackendApplicationService(model: fixture.model)
        func request(_ action: CompanionHostAction) throws -> BackendRPCRequest {
            .init(method: "application.command", payload: try JSONEncoder().encode(BackendApplicationCommand.companion(action)))
        }
        let start = await backend.handle(try request(.start))
        #expect(start.error == nil)
        let started = try JSONDecoder().decode(BackendApplicationResult.self, from: try #require(start.result))
        #expect(started.companion?.endpoint == fixture.host.endpoint)
        #expect(started.companion?.isEnabled == true)
        let codeRequest = try request(.createCode)
        let code = await backend.handle(codeRequest)
        #expect(code.error == nil)
        let offered = try JSONDecoder().decode(BackendApplicationResult.self, from: try #require(code.result))
        #expect(offered.companion?.pairingPayload != nil)
        #expect(await backend.handle(codeRequest).result == code.result)
        #expect(fixture.exposureCount == 1)
        let stop = await backend.handle(try request(.stop))
        #expect(stop.error == nil)
        let stopped = try JSONDecoder().decode(BackendApplicationResult.self, from: try #require(stop.result))
        #expect(stopped.companion?.endpoint == nil)
        #expect(stopped.companion?.isEnabled == false)
        #expect(fixture.host.endpoint == nil)
    }

    @Test func realHostWaitsForOwnedCleanupBeforeCreatingReplacementExposure() async throws {
        let fixture = try await HostFixture()
        defer { fixture.remove() }
        await fixture.host.start()
        let address = try #require(fixture.host.endpoint)
        #expect(fixture.children.count == 1)
        fixture.host.stopSharing()
        #expect(fixture.children[0].isRunning)
        await fixture.host.start()
        #expect(fixture.host.endpoint == address)
        #expect(fixture.host.errorMessage == nil)
        #expect(fixture.exposureCount == 2 && fixture.children.count == 2)
        #expect(!fixture.replacementCreatedWhileStopping)
        #expect(!fixture.children[0].isRunning && fixture.children[1].isRunning)
        #expect(fixture.existingPorts == [443])
    }

    @Test func staleHostStartupCannotStopReplacementExposure() async throws {
        let fixture = try await HostFixture()
        defer { fixture.remove() }
        fixture.holdFirstStatus = true
        let old = Task { await fixture.host.start() }
        try await waitUntil { fixture.firstStatusArrived }
        fixture.host.stopSharing()
        await fixture.host.start()
        let replacement = try #require(fixture.host.endpoint)
        #expect(fixture.children.count == 1 && fixture.children[0].isRunning)
        fixture.releaseFirstStatus()
        await old.value
        #expect(fixture.host.endpoint == replacement)
        #expect(fixture.host.errorMessage == nil)
        #expect(fixture.children[0].isRunning)
        #expect(fixture.children[0].terminationCount == 0)
    }

    @Test func cancelledStartupDuringOldExposureCleanupCannotReplaceNewGeneration() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        await fixture.host.start()
        fixture.children[0].holdCleanup = true
        fixture.host.stopSharing()
        let abandoned = Task { await fixture.host.start() }
        try await waitUntil { fixture.host.isStarting }
        // The first owned Serve child is still winding down. Both starts must
        // honor its cleanup, while only the latest generation may publish state.
        #expect(fixture.children[0].isRunning)
        fixture.host.stopSharing()
        let replacement = Task { await fixture.host.start() }
        try await waitUntil { fixture.host.isStarting }
        fixture.children[0].holdCleanup = false
        await replacement.value
        await abandoned.value
        #expect(fixture.host.endpoint != nil)
        #expect(fixture.host.errorMessage == nil)
        #expect(fixture.exposureCount == 2)
        #expect(fixture.children.count == 2 && fixture.children[1].isRunning)
        #expect(fixture.children[1].terminationCount == 0)
        #expect(!fixture.replacementCreatedWhileStopping)
    }

    @Test func executionRevocationUsesLiveAuthenticationAndSurvivesStoppedSharingRestart() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        await fixture.host.start()
        let first = try await fixture.pairAndProvision(name: "First iPhone")
        let second = try await fixture.pairAndProvision(name: "Second iPad")
        let database = try #require(fixture.model.dashboardStore?.database)
        let identity = try await database.companionLibraryIdentity()
        var tombstone = try await database.registerCompanionExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: first.deviceID,
            kind: .ios, name: "Deleted device workspace", journalDeviceIDs: [first.deviceID])), deviceID: identity.hostDeviceID)
        let tombstoneRevision = tombstone.revision
        tombstone.deleted = true
        tombstone = try await database.registerCompanionExecutionWorkspace(
            .init(workspace: tombstone, expectedRevision: tombstoneRevision), deviceID: identity.hostDeviceID)
        let live = try await database.registerCompanionExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: second.deviceID,
            kind: .ios, name: "Live device workspace", journalDeviceIDs: [first.deviceID])), deviceID: identity.hostDeviceID)
        #expect(try await fixture.executionStatus(first) == 200)
        #expect(try await fixture.executionStatus(second) == 200)

        // A separately loaded revocation actor would only update disk and leave
        // the live API's cached authentication accepting this first bearer.
        await fixture.host.revoke(first.deviceID)
        #expect(fixture.host.errorMessage == nil)
        #expect(try await fixture.executionStatus(first) == 401)
        #expect(try await fixture.executionStatus(second) == 200)
        let afterRevocation = try await database.companionExecutionWorkspaces()
        #expect(afterRevocation.first { $0.id == live.id }?.journalDeviceIDs.isEmpty == true)
        #expect(afterRevocation.first { $0.id == tombstone.id } == tombstone)

        fixture.host.stopSharing()
        await fixture.host.revoke(second.deviceID)
        #expect(fixture.host.errorMessage == nil)
        let disk = try CompanionExecutionAuthentication(fileURL: fixture.directory.appending(path: "execution-devices.json"))
        for token in [first.token, second.token] {
            do { _ = try await disk.authenticate(bearer: token); Issue.record("Revoked execution bearer remained on disk") }
            catch let error as CompanionAPIError { #expect(error.code == "unauthorized") }
        }
        // Restarting the listener must reuse the current actor state, and a new
        // enrollment must not resurrect revoked grants from an older cache.
        await fixture.host.start()
        let third = try await fixture.pairAndProvision(name: "Replacement iPhone")
        #expect(try await fixture.executionStatus(first) == 401)
        #expect(try await fixture.executionStatus(second) == 401)
        #expect(try await fixture.executionStatus(third) == 200)
        #expect(fixture.host.pairedDevices.map(\.id) == [third.deviceID])

        fixture.host.stopSharing()
        try await waitUntil { !fixture.children.contains { $0.isRunning } }
        fixture.host = fixture.makeHost()
        await fixture.host.start()
        #expect(try await fixture.executionStatus(first) == 401)
        #expect(try await fixture.executionStatus(second) == 401)
        #expect(try await fixture.executionStatus(third) == 200)
        #expect(fixture.host.pairedDevices.map(\.id) == [third.deviceID])

        // A cold controller must load persisted library authentication even if
        // the user revokes a device before sharing has been restored or started.
        fixture.host.stopSharing()
        try await waitUntil { !fixture.children.contains { $0.isRunning } }
        fixture.host = fixture.makeHost()
        fixture.defaults.set([first.deviceID: [String]()], forKey: "companion.execution.pending-revocations")
        await fixture.host.revoke(third.deviceID)
        #expect(fixture.host.errorMessage == nil)
        let libraryDisk = try CompanionAuthentication(fileURL: fixture.directory.appending(path: "companion-devices.json"))
        #expect(await libraryDisk.devices().isEmpty)
        await fixture.host.start()
        #expect(try await fixture.executionStatus(third) == 401)
        #expect(fixture.host.pairedDevices.isEmpty)
    }

    @Test func stalePairingPrincipalCannotRotateReenrolledDevicesExecutionGrant() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        await fixture.host.start()
        let oldCredential = try await fixture.pairAndProvision(name: "Original iPhone pairing")
        let oldPrincipal = try #require(fixture.host.pairedDevices.first { $0.id == oldCredential.deviceID })
        await fixture.host.revoke(oldPrincipal.id)
        let replacement = try await fixture.pairAndProvision(name: "Reenrolled iPhone", deviceID: oldPrincipal.id)
        #expect(try await fixture.executionStatus(oldCredential) == 401)
        #expect(try await fixture.executionStatus(replacement) == 200)
        do {
            _ = try await fixture.host.provisionExecutionWorkspace(id: replacement.workspace.id, device: oldPrincipal)
            Issue.record("A revoked pairing principal was accepted after device reenrollment")
        } catch let error as CompanionAPIError {
            #expect(["unavailable", "unauthorized"].contains(error.code))
        }
        #expect(try await fixture.executionStatus(replacement) == 200)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HostFixtureError.timeout
    }
}

private enum HostFixtureError: Error { case timeout }

@MainActor private final class HostFixture {
    let directory: URL
    let suite: String
    let defaults: UserDefaults
    let model: ApplicationModel
    lazy var host = makeHost()
    let existingPorts: Set<Int> = [443]
    var exposureCount = 0
    var children: [HostServingChild] = []
    var replacementCreatedWhileStopping = false
    var holdFirstStatus = false
    var firstStatusArrived = false
    private var firstStatusWaiter: CheckedContinuation<Void, Never>?

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "companion-host-\(UUID())")
        suite = "companion.host.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        let store = try await DashboardStore(supportDirectory: directory)
        model = ApplicationModel(applicationDefaults: defaults, dashboardStore: store, startsAutomatically: false)
    }
    func makeHost() -> CompanionHostController {
        CompanionHostController(model: model, defaults: defaults, supportDirectory: directory,
            makeExposure: { [unowned self] in makeExposure() })
    }
    func pairAndProvision(name: String, deviceID: String = UUID().uuidString.lowercased()) async throws -> CompanionExecutionCredential {
        await host.createPairingCode()
        let offer = try #require(host.pairingPayload)
        var request = URLRequest(url: try loopbackURL(path: "v1/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CompanionPairRequest(token: offer.token,
            deviceID: deviceID, deviceName: name))
        let (bytes, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let paired = try JSONDecoder().decode(CompanionPairResponse.self, from: bytes)
        let device = try #require(host.pairedDevices.first { $0.id == paired.deviceID })
        let database = try #require(model.dashboardStore?.database)
        let identity = try await database.companionLibraryIdentity()
        let workspaces = try await database.companionExecutionWorkspaces()
        let workspace = try #require(workspaces.first { $0.kind == .mac && $0.ownerDeviceID == identity.hostDeviceID })
        return try await host.provisionExecutionWorkspace(id: workspace.id, device: device)
    }
    func executionStatus(_ credential: CompanionExecutionCredential) async throws -> Int {
        var request = URLRequest(url: try loopbackURL(path: "v1/execution"))
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        request.setValue(String(CompanionProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
        request.setValue(credential.workspace.libraryID, forHTTPHeaderField: "X-Woven-Library")
        request.setValue(credential.workspace.id, forHTTPHeaderField: "X-Woven-Workspace")
        request.setValue(credential.deviceID, forHTTPHeaderField: "X-Woven-Device")
        let (_, response) = try await URLSession.shared.data(for: request)
        return try #require((response as? HTTPURLResponse)?.statusCode)
    }
    private func loopbackURL(path: String) throws -> URL {
        let child = try #require(children.last { $0.isRunning })
        return try #require(URL(string: child.target)).appendingPathComponent(path)
    }
    func makeExposure() -> CompanionTailscaleServe {
        replacementCreatedWhileStopping = replacementCreatedWhileStopping || children.contains { $0.stoppedAt != nil && $0.isRunning }
        exposureCount += 1
        let attempt = exposureCount
        return CompanionTailscaleServe(executable: URL(fileURLWithPath: "/fixture/tailscale"),
            probe: { [self] _, arguments in try await probe(arguments, attempt: attempt) },
            launch: { [self] _, arguments in
                let child = HostServingChild(port: Int(arguments[1].dropFirst("--https=".count))!, target: arguments[3])
                children.append(child)
                return child
            })
    }
    func probe(_ arguments: [String], attempt: Int) async throws -> Data {
        if arguments == ["status", "--json"] {
            if attempt == 1 && holdFirstStatus {
                firstStatusArrived = true
                await withCheckedContinuation { firstStatusWaiter = $0 }
            }
            return Data(#"{"BackendState":"Running","Self":{"DNSName":"fixture.test.ts.net."}}"#.utf8)
        }
        let tcp = Dictionary(uniqueKeysWithValues: existingPorts.map { (String($0), ["HTTPS": true]) })
        var foreground: [String: Any] = [:]
        for (index, child) in children.enumerated() where child.isRunning {
            foreground[String(index)] = ["TCP": [String(child.port): ["HTTPS": true]],
                "Web": ["fixture.test.ts.net:\(child.port)": ["Handlers": ["/wovenmatter": ["Proxy": child.target]]]]]
        }
        return try JSONSerialization.data(withJSONObject: ["TCP": tcp, "Foreground": foreground])
    }
    func releaseFirstStatus() { firstStatusWaiter?.resume(); firstStatusWaiter = nil }
    func remove() {
        releaseFirstStatus()
        host.stopSharing()
        children.forEach { $0.forceStopped = true }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor private final class HostServingChild: CompanionServingProcess {
    let port: Int
    let target: String
    var stoppedAt: TimeInterval?
    var forceStopped = false
    var holdCleanup = false
    var terminationCount = 0
    init(port: Int, target: String) { self.port = port; self.target = target }
    var isRunning: Bool {
        !forceStopped && stoppedAt.map { holdCleanup || ProcessInfo.processInfo.systemUptime - $0 < 0.4 } ?? !forceStopped
    }
    func terminate() { terminationCount += 1; stoppedAt = ProcessInfo.processInfo.systemUptime }
}
