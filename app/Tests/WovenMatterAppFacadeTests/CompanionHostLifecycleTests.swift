import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CompanionHostLifecycleTests {
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


    @Test func restoredCancellationRetainsItsProofUntilTheMacAcknowledges() async throws {
        let identity = CompanionPairingDeviceIdentity(deviceID: UUID().uuidString.lowercased(), deviceName: "Fixture Mac", metadata: .init(kind: .mac))
        let request = CompanionPairingApprovalRequest(requestID: UUID().uuidString.lowercased(), requestSecret: String(repeating: "s", count: 43), identity: identity)
        let cancelled = CompanionStoredPairingClaim(endpoint: URL(string: "https://fixture.test.ts.net:8443/wovenmatter")!,
            request: request, expiresAt: Date().addingTimeInterval(600), cancelled: true)
        var stored: Data? = try JSONEncoder().encode(cancelled)
        var attempts = 0, paired = false
        let controller = CompanionMacPairingController(identity: { identity }, onPaired: { _, _ in paired = true },
            loadClaim: { _ in try stored.map { try JSONDecoder().decode(CompanionStoredPairingClaim.self, from: $0) } },
            saveClaim: { claim, _ in stored = try claim.map { try JSONEncoder().encode($0) } },
            cancelClaim: { endpoint, poll in
                #expect(endpoint == cancelled.endpoint && poll.requestID == cancelled.poll.requestID && poll.requestSecret == cancelled.poll.requestSecret)
                attempts += 1
                if attempts == 1 { throw URLError(.notConnectedToInternet) }
            })
        await controller.restorePendingRequest()
        try await waitUntil { attempts == 1 }
        #expect(stored != nil && controller.isRequestPending && !paired)
        try await waitUntil { attempts == 2 && !controller.isRequestPending }
        #expect(stored == nil && !paired)
    }

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

    @Test func foregroundHostServesDevelopmentEnrollmentAndRepeatedStartupKeepsTheEndpoint() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        try await fixture.model.configureCompanionFixture(directory: fixture.directory)
        fixture.model.companionHost = fixture.host
        await fixture.host.start()
        let socket = LocalExecutionRole.backendSocketURL(workspaceDirectory: fixture.directory)
        defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
        try fixture.model.startDevelopmentConnectionService(socketURL: socket)
        let server = try #require(fixture.model.backendRPCServer)
        defer { server.stop() }
        try fixture.model.startDevelopmentConnectionService(socketURL: socket)
        #expect(fixture.model.backendRPCServer === server)
        let request = DevelopmentClientRequest(deviceID: UUID().uuidString.lowercased(), name: "Dev · fixture")
        let data = try await BackendRPCClient(socketURL: socket).call(method: "development.connect",
            payload: JSONEncoder().encode(request))
        let response = try JSONDecoder().decode(DevelopmentClientConnection.self, from: data)
        #expect(response.endpoint == fixture.host.endpoint)
        #expect(!response.pairing.credential.isEmpty)
        await #expect(throws: BackendRPCError.self) {
            try await BackendRPCClient(socketURL: socket).call(method: "application.command")
        }
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

    @Test func clickPairingHTTPRequiresLocalApprovalAndReturnsAccurateMetadata() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        await fixture.host.startForCentralDatabase()
        try await waitUntil { fixture.host.endpoint != nil }
        let target = try #require(fixture.children.last?.target)
        let base = try #require(URL(string: target))
        func post(_ path: String, _ body: Data) async throws -> (Data, Int) {
            var request = URLRequest(url: base.appending(path: path))
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, try #require((response as? HTTPURLResponse)?.statusCode))
        }
        let (advertised, _) = try await URLSession.shared.data(from: base.appending(path: "v1/discovery"))
        let advertisement = try JSONDecoder().decode(CompanionDiscoveryAdvertisement.self, from: advertised)
        #expect(advertisement.role == .central && advertisement.identity.metadata.kind == .mac)
        #expect(!String(decoding: advertised, as: UTF8.self).contains("credential"))
        let request = CompanionPairingApprovalRequest(requestID: UUID().uuidString.lowercased(), requestSecret: UUID().uuidString + UUID().uuidString,
            identity: .init(deviceID: UUID().uuidString.lowercased(), deviceName: "Peer Mac", metadata: .init(kind: .mac, osVersion: "fixtureOS", appVersion: "fixtureApp")))
        let (pendingData, pendingStatus) = try await post("v1/pairing/request", JSONEncoder().encode(request))
        let pending = try JSONDecoder().decode(CompanionPairingApprovalResult.self, from: pendingData)
        #expect(pendingStatus == 200 && pending.state == .pending && pending.pairing == nil)
        await fixture.host.refreshStatus()
        #expect(fixture.host.pendingPairingRequests.first?.identity == request.identity)
        #expect(fixture.host.pairedDevices.isEmpty)
        let (_, forbidden) = try await post("v1/pairing/approve", Data("{}".utf8))
        #expect(forbidden != 200)
        await fixture.host.approvePairing(id: request.requestID)
        let (approvedData, status) = try await post("v1/pairing/result", JSONEncoder().encode(CompanionPairingPoll(requestID: request.requestID, requestSecret: request.requestSecret)))
        let approved = try JSONDecoder().decode(CompanionPairingApprovalResult.self, from: approvedData)
        #expect(status == 200 && approved.pairing?.deviceID == request.identity.deviceID)
        #expect(fixture.host.pairedDevices.first?.metadata == request.identity.metadata)
        #expect(fixture.host.pairedDevices.first?.lastSeenAt == nil)
        let principal = try #require(fixture.host.pairedDevices.first)
        let workspace = try #require(fixture.host.executionWorkspaces.first { $0.kind == .mac })
        let direct = try await fixture.host.provisionExecutionWorkspace(id: workspace.id, device: principal)
        #expect(try await fixture.executionStatus(direct) == 200)
        let (_, cancelled) = try await post("v1/pairing/cancel", JSONEncoder().encode(CompanionPairingPoll(requestID: request.requestID, requestSecret: request.requestSecret)))
        #expect(cancelled == 200)
        #expect(try await fixture.executionStatus(direct) == 401)
        #expect(fixture.host.pairedDevices.isEmpty)
    }

    @Test func disablingExecutionDuringEnrollmentLeavesLibraryPairingAndDeniesOldAndNewGrants() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        await fixture.host.start()
        let old = try await fixture.pairAndProvision(name: "Fixture Mac")
        let device = try #require(fixture.host.pairedDevices.first { $0.id == old.deviceID })
        let provisioning = Task { try? await fixture.host.provisionExecutionWorkspace(id: old.workspace.id, device: device) }
        await fixture.host.setExecutionAccess(deviceID: old.deviceID, workspaceID: old.workspace.id, enabled: false)
        let concurrent = await provisioning.value
        #expect(try await fixture.executionStatus(old) != 200)
        if let concurrent { #expect(try await fixture.executionStatus(concurrent) != 200) }
        #expect(fixture.host.pairedDevices.contains { $0.id == old.deviceID })
        #expect(fixture.host.workspaceAccessPolicies.contains { $0.deviceID == old.deviceID && $0.workspaceID == old.workspace.id && !$0.enabled })
        await #expect(throws: CompanionAPIError.self) {
            try await fixture.host.provisionExecutionWorkspace(id: old.workspace.id, device: device)
        }
        await fixture.host.setExecutionAccess(deviceID: old.deviceID, workspaceID: old.workspace.id, enabled: true)
        let fresh = try await fixture.host.provisionExecutionWorkspace(id: old.workspace.id, device: device)
        #expect(try await fixture.executionStatus(fresh) == 200)
        #expect(try await fixture.executionStatus(old) != 200)
    }

    private func waitUntil(attempts: Int = 300, _ condition: () -> Bool) async throws {
        // CI can run every package's suites in one process. Bound observations,
        // so unrelated MainActor work cannot consume this fixture's entire wait
        // before its startup task gets another chance to run.
        for _ in 0..<attempts {
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
    var existingPorts: Set<Int> = [443]
    var exposureCount = 0
    var children: [HostServingChild] = []
    var replacementCreatedWhileStopping = false
    var tailscaleRunning = true
    var holdFirstStatus = false
    var firstStatusArrived = false
    private var firstStatusWaiter: CheckedContinuation<Void, Never>?

    init(isNode: Bool = false) async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "companion-host-\(UUID())")
        suite = "companion.host.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(isNode, forKey: LocalExecutionRole.libraryClientPreferenceKey)
        let store = try await DashboardStore(supportDirectory: directory)
        model = ApplicationModel(applicationDefaults: defaults, dashboardStore: store, startsAutomatically: false)
    }
    func makeHost() -> CompanionHostController {
        CompanionHostController(model: model, defaults: defaults, supportDirectory: directory, retryInterval: .milliseconds(25),
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
            guard tailscaleRunning else { return Data(#"{"BackendState":"Stopped"}"#.utf8) }
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
