import Foundation
import Testing
import WovenMatterClient
import CompanionClient
import WorkspaceFixtures
import WovenMatterCore
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CompanionHostLifecycleTests {


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
        #expect(response.pairing.deviceID == request.deviceID)
        #expect(fixture.host.pairingPayload == nil)
        #expect(fixture.host.pendingPairingRequests.isEmpty)
        #expect(fixture.host.pairedDevices.contains { $0.id == request.deviceID })
        for path in ["development.connect", "v1/development/connect"] {
            var networkRequest = URLRequest(url: try fixture.loopbackURL(path: path))
            networkRequest.httpMethod = "POST"
            networkRequest.setValue("Bearer " + response.pairing.credential, forHTTPHeaderField: "Authorization")
            networkRequest.setValue(response.pairing.workspaceID, forHTTPHeaderField: "X-Woven-Workspace")
            networkRequest.setValue(String(CompanionProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
            networkRequest.httpBody = try JSONEncoder().encode(DevelopmentClientRequest(
                deviceID: UUID().uuidString.lowercased(), name: "Dev · network"))
            let (_, reply) = try await URLSession.shared.data(for: networkRequest)
            #expect(try #require((reply as? HTTPURLResponse)?.statusCode) >= 400)
        }
        #expect(fixture.host.pairedDevices.count == 1)
        let oversized = try JSONSerialization.data(withJSONObject: ["deviceID": UUID().uuidString.lowercased(),
            "name": "Dev · oversized", "padding": String(repeating: "x", count: 4_096)])
        await #expect(throws: BackendRPCError.self) {
            try await BackendRPCClient(socketURL: socket).call(method: "development.connect", payload: oversized)
        }
        await #expect(throws: BackendRPCError.self) {
            try await BackendRPCClient(socketURL: socket).call(method: "application.command")
        }
    }


    @Test func developmentDisconnectWithdrawsWorkspaceAndRestartReusesIdentity() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        await fixture.host.start()
        let database = try #require(fixture.model.dashboardStore?.database)
        let identity = try await database.companionLibraryIdentity()
        let request = DevelopmentClientRequest(deviceID: UUID().uuidString.lowercased(), name: "Dev · fixture")
        let connection = try await fixture.host.connectLocalDevelopment(request)
        let workspace = try await database.registerCompanionExecutionWorkspace(.init(workspace: .init(
            id: request.deviceID, libraryID: identity.libraryID, ownerDeviceID: request.deviceID, kind: .mac,
            name: "Mac (Dev) · fixture", endpoint: URL(string: "https://fixture.test.ts.net/wovenmatter"),
            executionDeviceID: request.deviceID, developmentInstance: "fixture")), deviceID: identity.hostDeviceID)
        let absent = try await database.companionConnectionWorkspaces(activeDeviceIDs: [])
        #expect(absent.first { $0.id == workspace.id }?.isVisibleInConnections == false)
        let reconnected = try await database.companionConnectionWorkspaces(activeDeviceIDs: [request.deviceID])
        #expect(reconnected.first { $0.id == workspace.id }?.endpoint == workspace.endpoint)
        #expect(try await database.companionExecutionWorkspaces().first { $0.id == workspace.id }?.revision == workspace.revision)
        try await fixture.host.disconnectLocalDevelopment(.init(deviceID: request.deviceID, credential: connection.pairing.credential))
        #expect(!fixture.host.pairedDevices.contains { $0.id == request.deviceID })
        let retained = try #require(try await database.companionExecutionWorkspaces().first { $0.id == workspace.id })
        #expect(!retained.deleted && retained.endpoint == nil && !retained.isVisibleInConnections)
        _ = try await fixture.host.connectLocalDevelopment(request)
        #expect(fixture.host.pairedDevices.contains { $0.id == request.deviceID })
        var restarted = retained; restarted.endpoint = workspace.endpoint
        _ = try await database.registerCompanionExecutionWorkspace(.init(workspace: restarted, expectedRevision: retained.revision), deviceID: identity.hostDeviceID)
        await fixture.host.refreshStatus()
        #expect(fixture.host.executionWorkspaces.first { $0.id == workspace.id }?.isVisibleInConnections == true)
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

    @Test func pairingGrantsExecutionWithoutWorkspacePermissionsAndUnpairRevokesIt() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        await fixture.host.start()
        let credential = try await fixture.pairAndProvision(name: "Fixture Mac")
        let device = try #require(fixture.host.pairedDevices.first { $0.id == credential.deviceID })
        let fresh = try await fixture.host.provisionExecutionWorkspace(id: credential.workspace.id, device: device)
        #expect(try await fixture.executionStatus(fresh) == 200)
        await fixture.host.revoke(device.id)
        #expect(try await fixture.executionStatus(fresh) == 401)
        await #expect(throws: CompanionAPIError.self) {
            try await fixture.host.provisionExecutionWorkspace(id: credential.workspace.id, device: device)
        }
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
    var dnsName = "fixture.test.ts.net"
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
    func loopbackURL(path: String) throws -> URL {
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
            return try JSONSerialization.data(withJSONObject: ["BackendState": "Running", "Self": ["DNSName": dnsName + "."]])
        }
        let tcp = Dictionary(uniqueKeysWithValues: existingPorts.map { (String($0), ["HTTPS": true]) })
        var foreground: [String: Any] = [:]
        for (index, child) in children.enumerated() where child.isRunning {
            foreground[String(index)] = ["TCP": [String(child.port): ["HTTPS": true]],
                "Web": ["\(dnsName):\(child.port)": ["Handlers": ["/wovenmatter": ["Proxy": child.target]]]]]
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


@MainActor private final class PeerTestMesh {
    var hosts: [String: HostFixture] = [:]
    var credentials: [String: [PairedMacCredential]] = [:]
    var offline: Set<String> = []
    var loseReplyOnce: Set<String> = []
    func add(_ name: String) async throws -> HostFixture {
        let fixture = try await HostFixture()
        fixture.dnsName = name + ".fixture.ts.net"
        let network = PairedMacNetwork(request: { [self] endpoint, path, token, libraryID, body in
            try await request(endpoint, path: path, token: token, libraryID: libraryID, body: body)
        })
        fixture.host.peerSync = PairedMacSyncController(host: fixture.host, network: network, restoresPairing: false,
            loadCredentials: { [self] in credentials[name] ?? [] },
            saveCredentials: { [self] in credentials[name] = $0 })
        await fixture.host.start()
        let route = try await fixture.host.peerRoute()
        hosts[route.endpoint.absoluteString] = fixture
        return fixture
    }
    func request(_ endpoint: URL, path: String, token: String?, libraryID: String?, body: Data?) async throws -> Data {
        guard !offline.contains(endpoint.absoluteString), let fixture = hosts[endpoint.absoluteString] else { throw URLError(.notConnectedToInternet) }
        if path == "v1/discovery" {
            let identity = try #require(fixture.host.peerIdentity)
            return try JSONEncoder().encode(CompanionDiscoveryAdvertisement(role: .central, identity: identity, capabilities: ["library.peers.v1"]))
        }
        if ["v1/pair/preview", "v1/pair", "v1/pair/confirm"].contains(path) {
            var request = URLRequest(url: try fixture.loopbackURL(path: path))
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(String(CompanionProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            if let libraryID { request.setValue(libraryID, forHTTPHeaderField: "X-Woven-Workspace") }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw try JSONDecoder().decode(CompanionAPIError.self, from: data) }
            if loseReplyOnce.remove(path) != nil { throw URLError(.networkConnectionLost) }
            return data
        }
        var headers = ["x-woven-protocol": String(CompanionProtocol.version)]
        if let token { headers["authorization"] = "Bearer " + token }
        if let libraryID { headers["x-woven-workspace"] = libraryID }
        let response = try #require(await fixture.host.peerSync.handle(.init(method: body == nil ? "GET" : "POST", target: "/" + path, headers: headers, body: body ?? Data())))
        guard response.status == 200 else { throw try JSONDecoder().decode(CompanionAPIError.self, from: response.body) }
        if loseReplyOnce.remove(path) != nil { throw URLError(.networkConnectionLost) }
        return response.body
    }
    func pair(_ first: HostFixture, with second: HostFixture) async throws {
        let route = try await second.host.peerRoute()
        let own = try await first.host.peerRoute()
        let authentication = try await second.host.peerAuthentication()
        let offer = try await authentication.createOffer(endpoint: route.endpoint)
        let response = try await authentication.pair(.init(token: offer.payload.token, deviceID: own.deviceID, deviceName: own.name, metadata: .init(kind: .mac)), workspaceID: route.libraryID)
        try await first.host.peerSync.acceptPairing(endpoint: route.endpoint, response: response)
    }
    func remove() { for fixture in hosts.values { fixture.remove() }; hosts = [:] }
}

extension CompanionHostLifecycleTests {
    @Test func pairedMacMeshSharesOfflineWritingNewWorkspacesAndAppleConnectionsWithoutTheJoiningMac() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("air"), mini = try await mesh.add("mini"), third = try await mesh.add("third")
        try await mesh.pair(air, with: mini); try await mesh.pair(third, with: mini)
        for _ in 0..<2 {
            await air.host.peerSync.synchronize(force: true)
            await third.host.peerSync.synchronize(force: true)
            await mini.host.peerSync.synchronize(force: true)
        }
        let airDB = try #require(air.model.dashboardStore?.database), thirdDB = try #require(third.model.dashboardStore?.database)
        let joiningRoute = try await mini.host.peerRoute()
        mesh.offline.insert(joiningRoute.endpoint.absoluteString)
        let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        let airID = try await air.host.peerRoute().deviceID, thirdID = try await third.host.peerRoute().deviceID
        _ = try await airDB.applyCompanionMutation(.init(deviceID: airID, kind: .createNote, resourceID: first, title: "Air offline", content: try NoteDocument(blocks: [.richText(.init(text: "Air writing"))]).encoded()))
        _ = try await thirdDB.applyCompanionMutation(.init(deviceID: thirdID, kind: .createNote, resourceID: second, title: "Third offline", content: try NoteDocument(blocks: [.richText(.init(text: "Third writing"))]).encoded()))
        let remote = RemoteWorkspaceConfiguration(name: "Added from third Mac", workspaceID: "new-remote", hostName: "linux.fixture.ts.net", kind: .host)
        try await thirdDB.savePairedRemoteWorkspaces([remote])
        let phoneID = UUID().uuidString.lowercased()
        let authentication = try await third.host.peerAuthentication()
        let offer = try await authentication.createOffer(endpoint: third.host.peerRoute().endpoint)
        let phone = try await authentication.pair(.init(token: offer.payload.token, deviceID: phoneID, deviceName: "New iPhone", metadata: .init(kind: .iPhone)), workspaceID: thirdDB.companionWorkspaceID())
        await air.host.peerSync.synchronize(force: true)
        await third.host.peerSync.synchronize(force: true)
        #expect(try await airDB.companionNote(id: second)?.title == "Third offline")
        #expect(try await thirdDB.companionNote(id: first)?.title == "Air offline")
        #expect(try await airDB.pairedRemoteWorkspaces().contains { $0.id == remote.id.uuidString.lowercased() })
        #expect(try await air.host.peerAuthentication().authenticate(bearer: phone.credential).id == phoneID)
        #expect(!air.model.isLibraryClient && !third.model.isLibraryClient)
        #expect(air.host.peerSync.errors.isEmpty && third.host.peerSync.errors.isEmpty)
    }

    @Test func peerRevocationRejectsExistingExecutionBearersAndNeverReplicatesProviderSecrets() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("revoke-air"), mini = try await mesh.add("revoke-mini")
        try await mesh.pair(air, with: mini)
        await air.host.peerSync.synchronize(force: true)
        let phoneID = UUID().uuidString.lowercased()
        let authentication = try await mini.host.peerAuthentication()
        let own = try await mini.host.peerRoute()
        let offer = try await authentication.createOffer(endpoint: own.endpoint)
        let phone = try await authentication.pair(.init(token: offer.payload.token, deviceID: phoneID, deviceName: "Phone", metadata: .init(kind: .iPhone)), workspaceID: own.libraryID)
        await air.host.peerSync.synchronize(force: true)
        let airAuth = try await air.host.peerAuthentication()
        let principal = try await airAuth.authenticate(bearer: phone.credential)
        let workspace = try #require(air.host.executionWorkspaces.first { $0.ownerDeviceID == air.host.peerIdentity?.deviceID && $0.kind == .mac })
        let execution = try await air.host.provisionExecutionWorkspace(id: workspace.id, device: principal)
        #expect(try await air.executionStatus(execution) == 200)
        await mini.host.revoke(phoneID)
        await air.host.peerSync.synchronize(force: true)
        await #expect(throws: CompanionAPIError.self) { try await airAuth.authenticate(bearer: phone.credential) }
        #expect(try await air.executionStatus(execution) == 401)
        let wire = String(decoding: try JSONEncoder().encode(await airAuth.peerDevices()), as: UTF8.self)
        #expect(!wire.contains(phone.credential))
        #expect(!wire.contains(execution.token))
        let airRoute = try await air.host.peerRoute()
        await mini.host.revoke(airRoute.deviceID)
        let miniDB = try #require(mini.model.dashboardStore?.database)
        let withdrawn = try #require(try await miniDB.companionExecutionWorkspaces().first { $0.id == workspace.id })
        #expect(withdrawn.endpoint == nil && withdrawn.retainedHistory == true)
        await #expect(throws: CompanionAPIError.self) { try await mini.host.provisionCentralExecutionWorkspace(id: workspace.id) }
    }
}


extension CompanionHostLifecycleTests {
    @Test func formerNodeUpgradeKeepsUnsentWritingAndOpensTheFullApp() async throws {
        let fixture = try await HostFixture(isNode: true); defer { fixture.remove() }
        let database = try #require(fixture.model.dashboardStore?.database)
        let replicaURL = fixture.directory.appending(path: "LibraryClient/library.json")
        let replica = try MobileStore(file: replicaURL)
        try await replica.bindWorkspace(UUID().uuidString.lowercased())
        let content = try NoteDocument(blocks: [.richText(.init(text: "Saved offline before upgrading"))]).encoded()
        _ = try await replica.createNote(folderID: nil, title: "Unsent note", content: content)
        try await replica.saveChatDraft(key: "new-chat", draft: .init(text: "Unsent message"))
        let original = await replica.snapshot()
        try await LegacyMacLibraryUpgrade.prepare(database: database, defaults: fixture.defaults)
        let recovered = try await database.companionSnapshot().notes
        #expect(recovered.contains { $0.content == content })
        #expect(recovered.contains { $0.title.hasPrefix("Unsent message") })
        #expect(try await database.companionLibraryIdentity().hostDeviceID == original.deviceID)
        #expect(await replica.snapshot().outbox == original.outbox)
        #expect(!fixture.model.isLibraryClient)
        #expect(LocalExecutionRole.resolve(arguments: [], libraryClientEnabled: true) == .frontend)
        try await LegacyMacLibraryUpgrade.prepare(database: database, defaults: fixture.defaults)
        #expect(try await database.companionSnapshot().notes.count == recovered.count)
    }

    @Test func peerHistoryIsLocalButNativeControlStaysWithItsMac() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("history-air"), mini = try await mesh.add("history-mini")
        let source = try #require(air.model.dashboardStore?.database), other = try #require(mini.model.dashboardStore?.database)
        let id = try await source.createFixtureLocalACPSession(runtimeKind: .codex, title: "Owner's conversation", ownerDeviceID: UUID())
        let run = try await source.beginLocalACPRun(conversationID: id, content: "Saved native input")
        try await source.completeLocalACPRun(runID: run.runID, error: nil)
        let originalCount = try await source.read { try $0.historyRowsUnlocked("SELECT id FROM workspace_history_events WHERE conversation_id=?", values: [id]).count }
        try await mesh.pair(air, with: mini)
        await air.host.peerSync.synchronize(force: true)
        #expect(air.host.peerSync.errors.isEmpty)
        #expect(try await other.companionExecutionOwner(conversationID: id) != nil)
        #expect(try await source.companionExecutionOwner(conversationID: id) == nil)
        #expect(try await other.companionFederatedTranscript(conversationID: id)?.messages.contains { $0.content == "Saved native input" } == true)
        #expect(try await other.read { try $0.historyRowsUnlocked("SELECT conversation_id FROM desktop_local_acp_sessions WHERE conversation_id=?", values: [id]).isEmpty })
        #expect(try await other.read { try $0.historyRowsUnlocked("SELECT id FROM workspace_history_events WHERE conversation_id=?", values: [id]).count } == originalCount)
        let sourceAgent = try #require(try await source.dashboardAgents().first)
        #expect(mini.model.peerAgentWorkspaces[sourceAgent.id] != nil)
        #expect(!mini.model.localCLIAgents.contains { $0.id == sourceAgent.id })
        #expect(mini.model.remoteWorkspaceAgents.contains { $0.id == sourceAgent.id })
        let workspace = try #require(try await other.companionConversationExecutionWorkspace(conversationID: id))
        let own = try await mini.host.peerRoute()
        let credential = try await mini.host.provisionCentralExecutionWorkspace(id: workspace.id)
        #expect(credential.deviceID == own.deviceID && credential.workspace.libraryID == workspace.libraryID)
        await mini.host.peerSync.synchronize(force: true)
        #expect(try await source.companionExecutionOwner(conversationID: id) == nil)
    }
}


extension CompanionHostLifecycleTests {
    @Test func pairingLinkAndLostJoinReplyResumeTheSameGrantAfterControllerRestart() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("link-air"), mini = try await mesh.add("link-mini")
        await mini.host.createPairingCode()
        let payload = try #require(mini.host.pairingPayload)
        mesh.loseReplyOnce = ["v1/pair/confirm"]
        await #expect(throws: URLError.self) { try await air.host.peerSync.pairUsingLink(payload.encodedURL.absoluteString) }
        let pending = try #require(mesh.credentials["link-air"]?.first)
        #expect(pending.confirmationPending == true && pending.needsJoin == true)
        let auth = try await mini.host.peerAuthentication()
        #expect(try await auth.authenticate(bearer: pending.token).id == pending.deviceID)
        mesh.loseReplyOnce = ["v1/peers/join"]
        let network = PairedMacNetwork(request: { endpoint, path, token, libraryID, body in
            try await mesh.request(endpoint, path: path, token: token, libraryID: libraryID, body: body)
        })
        air.host.peerSync = PairedMacSyncController(host: air.host, network: network, restoresPairing: false,
            loadCredentials: { mesh.credentials["link-air"] ?? [] }, saveCredentials: { mesh.credentials["link-air"] = $0 })
        try await air.host.peerSync.restore()
        #expect(mesh.credentials["link-air"]?.first?.needsJoin == true)
        try await air.host.peerSync.restore()
        let completed = try #require(mesh.credentials["link-air"]?.first)
        #expect(completed.token == pending.token && completed.returnToken == pending.returnToken)
        #expect(completed.needsJoin == nil && completed.confirmationPending == nil)
        #expect(await auth.devices().filter { $0.id == pending.deviceID }.count == 1)
        await air.host.peerSync.synchronize(force: true)
        #expect(air.host.peerSync.errors.isEmpty)
    }
}


extension CompanionHostLifecycleTests {
    @Test func fileManifestContinuesBeyondOneBoundedSyncTurn() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("files-air"), mini = try await mesh.add("files-mini")
        let source = try LibraryFileStore(supportDirectory: air.directory)
        let target = try LibraryFileStore(supportDirectory: mini.directory)
        var contents: [(String, Data)] = []
        for index in 0..<810 {
            let data = Data("file-\(index)".utf8)
            contents.append((try source.retain(data), data))
        }
        contents.sort { $0.0 < $1.0 }
        for item in contents.prefix(800) { _ = try target.retain(item.1) }
        try await mesh.pair(mini, with: air)
        await mini.host.peerSync.synchronize(force: true)
        let database = try #require(mini.model.dashboardStore?.database)
        let peer = try await air.host.peerRoute()
        #expect(try await database.pairedLibraryFileCursor(peer.deviceID) != "")
        await mini.host.peerSync.synchronize(force: true)
        #expect(mini.host.peerSync.errors.isEmpty)
        #expect(try await database.pairedLibraryFileCursor(peer.deviceID) == "")
        for item in contents.suffix(10) {
            #expect(try Data(contentsOf: mini.directory.appending(path: "library-files/" + item.0)) == item.1)
        }
    }
}
