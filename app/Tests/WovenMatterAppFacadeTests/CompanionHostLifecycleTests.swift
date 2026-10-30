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
    var storage = PairedMacDeviceStorage.memory()
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
        // Fixtures never reach the user's Keychain: paired grants, pending
        // claims, legacy and direct execution credentials stay in memory.
        CompanionHostController(model: model, defaults: defaults, supportDirectory: directory, retryInterval: .milliseconds(25),
            peerStorage: storage, makeExposure: { [unowned self] in makeExposure() })
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
    func libraryStatus(bearer: String) async throws -> Int {
        var request = URLRequest(url: try loopbackURL(path: "v1/snapshot"))
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue(String(CompanionProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
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
        var storage = fixture.storage
        storage.loadCredentials = { [self] in credentials[name] ?? [] }
        storage.saveCredentials = { [self] in credentials[name] = $0 }
        fixture.host.peerSync = PairedMacSyncController(host: fixture.host, network: network, storage: storage)
        await fixture.host.start()
        let route = try await fixture.host.peerRoute()
        hosts[route.endpoint.absoluteString] = fixture
        return fixture
    }
    func request(_ endpoint: URL, path: String, token: String?, libraryID: String?, body: Data?) async throws -> Data {
        guard !offline.contains(endpoint.absoluteString), let fixture = hosts[endpoint.absoluteString] else { throw URLError(.notConnectedToInternet) }
        if path == "v1/discovery" {
            let identity = try #require(fixture.host.peerIdentity)
            return try JSONEncoder().encode(CompanionDiscoveryAdvertisement(role: .central, identity: identity, capabilities: [PairedMacSyncController.capability]))
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
        let response = try await authentication.pair(.init(token: offer.payload.token, deviceID: own.deviceID, deviceName: own.name, metadata: .init(kind: .mac),
            purpose: CompanionPairingPurpose.peerMac), workspaceID: route.libraryID)
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
        // The new phone is listed for display and delegation, but its bearer
        // authenticates only at the Mac it paired with.
        #expect(try await air.host.peerAuthentication().rosterName(for: phoneID) == "New iPhone")
        await #expect(throws: CompanionAPIError.self) { try await air.host.peerAuthentication().authenticate(bearer: phone.credential) }
        #expect(!air.model.isLibraryClient && !third.model.isLibraryClient)
        #expect(air.host.peerSync.errors.isEmpty && third.host.peerSync.errors.isEmpty)
    }

    @Test func unpairingAMacEndsItsDerivedExecutionAndItsMintedBearersNeverWorkElsewhere() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("revoke-air"), mini = try await mesh.add("revoke-mini"), third = try await mesh.add("revoke-third")
        try await mesh.pair(air, with: mini); try await mesh.pair(third, with: mini)
        for _ in 0..<2 { for fixture in [air, third, mini] { await fixture.host.peerSync.synchronize(force: true) } }
        let airID = try await air.host.peerRoute().deviceID, miniID = try await mini.host.peerRoute().deviceID
        let workspace = try #require(air.host.executionWorkspaces.first { $0.ownerDeviceID == airID && $0.kind == .mac })
        // The Mini obtains the Air's execution access for its own phone directly
        // from the Air; the Air records the Mini as that grant's provenance.
        let miniAuth = try await mini.host.peerAuthentication()
        let phone = try await miniAuth.pair(.init(token: try await miniAuth.createOffer(endpoint: mini.host.peerRoute().endpoint).payload.token,
            deviceID: UUID().uuidString.lowercased(), deviceName: "Phone", metadata: .init(kind: .iPhone)), workspaceID: mini.host.peerRoute().libraryID)
        let execution = try await mini.host.provisionExecutionWorkspace(id: workspace.id, device: miniAuth.authenticate(bearer: phone.credential))
        #expect(try await air.executionStatus(execution) == 200)
        // A phone the Air paired itself is unrelated to the Mini.
        let airAuth = try await air.host.peerAuthentication()
        let ownPhone = try await airAuth.pair(.init(token: try await airAuth.createOffer(endpoint: air.host.peerRoute().endpoint).payload.token,
            deviceID: UUID().uuidString.lowercased(), deviceName: "Air phone", metadata: .init(kind: .iPhone)), workspaceID: air.host.peerRoute().libraryID)
        let ownExecution = try await air.host.provisionExecutionWorkspace(id: workspace.id, device: airAuth.authenticate(bearer: ownPhone.credential))
        // Bearers the Mini holds or minted (its grant at the third Mac, the
        // reciprocal the third Mac minted for it, its phone) never authenticate at the Air.
        let thirdID = try await third.host.peerRoute().deviceID
        let minted = try #require(mesh.credentials["revoke-third"]?.first { $0.route.deviceID == miniID }?.returnToken)
        let held = try #require(mesh.credentials["revoke-mini"]?.first { $0.route.deviceID == thirdID }?.token)
        for bearer in [minted, held, phone.credential] {
            await #expect(throws: CompanionAPIError.self) { try await airAuth.authenticate(bearer: bearer) }
            #expect(try await air.libraryStatus(bearer: bearer) == 401)
            await #expect(throws: (any Error).self) {
                try await mesh.request(air.host.peerRoute().endpoint, path: "v1/peers/files", token: bearer, libraryID: nil, body: JSONEncoder().encode(""))
            }
        }
        // Unpairing the Mini on the Air revokes everything derived through it.
        await air.host.revoke(miniID)
        #expect(try await air.executionStatus(execution) == 401)
        #expect(try await air.executionStatus(ownExecution) == 200)
        let wire = String(decoding: try JSONEncoder().encode(await airAuth.peerMembership()), as: UTF8.self)
        #expect(!wire.contains(phone.credential) && !wire.contains(execution.token))
        let withdrawn = try #require(try await mini.model.dashboardStore?.database.companionExecutionWorkspaces().first { $0.id == workspace.id })
        #expect(withdrawn.endpoint != nil)
    }

    @Test func incomingUnpairsApplyDespiteARejectedPageAndAreMarkedOnlyAfterSuccess() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("order-air"), mini = try await mesh.add("order-mini")
        try await mesh.pair(air, with: mini)
        await air.host.peerSync.synchronize(force: true)
        let airID = try await air.host.peerRoute().deviceID
        let workspace = try #require(air.host.executionWorkspaces.first { $0.ownerDeviceID == airID && $0.kind == .mac })
        let miniAuth = try await mini.host.peerAuthentication()
        let phoneID = UUID().uuidString.lowercased()
        let phone = try await miniAuth.pair(.init(token: try await miniAuth.createOffer(endpoint: mini.host.peerRoute().endpoint).payload.token,
            deviceID: phoneID, deviceName: "Phone", metadata: .init(kind: .iPhone)), workspaceID: mini.host.peerRoute().libraryID)
        let execution = try await mini.host.provisionExecutionWorkspace(id: workspace.id, device: miniAuth.authenticate(bearer: phone.credential))
        #expect(try await air.executionStatus(execution) == 200)
        await mini.host.revoke(phoneID)
        // The Air fails to revoke locally once, and the library page is invalid.
        var failures = 0
        air.host.beforeLocalRevocation = { id in if id == phoneID { failures += 1; throw CompanionAPIError(code: "fixture", message: "Injected") } }
        let token = try #require(mesh.credentials["order-mini"]?.first { $0.route.deviceID == airID }?.token)
        let exchange = PairedMacExchange(deviceID: try await mini.host.peerRoute().deviceID, after: 0,
            page: .init(schema: "incompatible", entries: [], cursor: 0, hasMore: false), membership: await miniAuth.peerMembership())
        await #expect(throws: (any Error).self) {
            try await mesh.request(air.host.peerRoute().endpoint, path: "v1/peers/exchange", token: token, libraryID: nil, body: JSONEncoder().encode(exchange))
        }
        // The unpair still took effect before the page was rejected...
        #expect(try await air.executionStatus(execution) == 401)
        #expect(failures == 1)
        // ...but is recorded as applied only once local revocation succeeds.
        let applied = { air.defaults.stringArray(forKey: "companion.peers.applied-revocations") ?? [] }
        #expect(!applied().contains { $0.hasPrefix(phoneID + ":") })
        air.host.beforeLocalRevocation = nil
        try await air.host.applyPeerRevocations()
        #expect(applied().contains { $0.hasPrefix(phoneID + ":") })
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
        var storage = air.storage
        storage.loadCredentials = { mesh.credentials["link-air"] ?? [] }; storage.saveCredentials = { mesh.credentials["link-air"] = $0 }
        air.host.peerSync = PairedMacSyncController(host: air.host, network: network, storage: storage)
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

/// The retired node's original approved Mac, reached only through this fixture.
private final class LegacyCentralTransport: CompanionTransport, @unchecked Sendable {
    let database: WorkspaceDatabase
    var operations: [String] = []
    var results: [String] = []
    init(_ database: WorkspaceDatabase) { self.database = database }
    func mutate(_ mutation: CompanionMutation) async throws -> CompanionMutationResult {
        operations.append(mutation.operationID)
        let result = try await database.applyCompanionMutation(mutation)
        results.append("\(mutation.kind):\(result.status):\(result.message ?? "")")
        return result
    }
    func workspaceIdentity() async throws -> String { throw MobileConnectionError.offline }
    func snapshot() async throws -> CompanionSnapshot { throw MobileConnectionError.offline }
    func changes(after: Int64) async throws -> CompanionChangePage { throw MobileConnectionError.offline }
    func note(_ id: String) async throws -> CompanionNote { throw MobileConnectionError.offline }
    func providers() async throws -> [CompanionProvider] { throw MobileConnectionError.offline }
    func pending() async throws -> [CompanionPendingInteraction] { throw MobileConnectionError.offline }
    func transcript(_ id: String) async throws -> CompanionTranscript { throw MobileConnectionError.offline }
    func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt { throw MobileConnectionError.offline }
    func receipt(_ id: String) async throws -> CompanionCommandReceipt? { throw MobileConnectionError.offline }
}

extension CompanionHostLifecycleTests {
    @Test func unavailablePairedCredentialsNeverStopPhoneAndLibraryService() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        fixture.storage.loadCredentials = { throw NSError(domain: NSOSStatusErrorDomain, code: -25308) }
        await fixture.host.start()
        #expect(fixture.host.endpoint != nil)
        #expect(fixture.host.peerSync.errors["credentials"] != nil)
    }

    @Test func formerNodeWritingIsReconciledAtItsOriginalMacWithOriginalOperations() async throws {
        let fixture = try await HostFixture(isNode: true); defer { fixture.remove() }
        let centralDirectory = FileManager.default.temporaryDirectory.appending(path: "legacy-central-\(UUID())")
        defer { try? FileManager.default.removeItem(at: centralDirectory) }
        try FileManager.default.createDirectory(at: centralDirectory, withIntermediateDirectories: true)
        let central = try await WorkspaceDatabase(url: centralDirectory.appending(path: "workspace.sqlite"))
        let centralHost = try await central.companionLibraryIdentity().hostDeviceID
        let content = { (text: String) in try NoteDocument(blocks: [.richText(.init(text: text))]).encoded() }
        let edited = UUID().uuidString.lowercased(), deleted = UUID().uuidString.lowercased(), folder = UUID().uuidString.lowercased()
        _ = try await central.applyCompanionMutation(.init(deviceID: centralHost, kind: .createNote, resourceID: edited, title: "Plan", content: content("Plan v1")))
        _ = try await central.applyCompanionMutation(.init(deviceID: centralHost, kind: .createNote, resourceID: deleted, title: "Draft", content: content("Draft v1")))
        let created = try await central.applyCompanionMutation(.init(deviceID: centralHost, kind: .createFolder, resourceID: folder, title: "Projects",
            folderExecution: .init(workspaceID: "local", rootPath: centralDirectory.path)))
        #expect(created.status == .accepted)
        // The node cached the central library, then wrote offline.
        let replica = try MobileStore(file: fixture.directory.appending(path: "LibraryClient/library.json"))
        try await replica.bindWorkspace(central.companionWorkspaceID())
        try await replica.apply(central.companionSnapshot())
        let plan = try #require(await replica.snapshot().notes[edited]), draft = try #require(await replica.snapshot().notes[deleted])
        try await replica.editNote(id: edited, title: "Plan", content: content("Plan edited offline"), folderID: nil, base: plan)
        try await replica.deleteWorkspaceNote(id: deleted, base: draft)
        try await replica.renameFolder(id: folder, name: "Renamed offline")
        let outbox = await replica.snapshot().outbox.map(\.mutation.operationID)
        #expect(outbox.count == 3)
        // Meanwhile the central Mac changed the draft, so deleting it must not apply silently.
        let current = try #require(try await central.companionNote(id: deleted))
        _ = try await central.applyCompanionMutation(.init(deviceID: centralHost, kind: .updateNote, resourceID: deleted, expectedRevision: current.revision, title: "Draft", content: content("Draft v2")))
        let node = try #require(fixture.model.dashboardStore?.database)
        try await LegacyMacLibraryUpgrade.prepare(database: node, defaults: fixture.defaults)
        let state = await replica.snapshot()
        fixture.storage = .memory(legacy: .init(endpoint: URL(string: "https://central.fixture.ts.net/wovenmatter")!,
            workspaceID: try await central.companionWorkspaceID(), deviceID: state.deviceID, token: String(repeating: "t", count: 43)))
        fixture.host.peerSync = PairedMacSyncController(host: fixture.host,
            network: PairedMacNetwork(request: { _, _, _, _, _ in throw URLError(.notConnectedToInternet) }), storage: fixture.storage)
        let transport = LegacyCentralTransport(central)
        await #expect(throws: (any Error).self) {
            try await LegacyMacLibraryUpgrade.reconnect(host: fixture.host, defaults: fixture.defaults, makeTransport: { _ in transport })
        }
        // The original approved Mac received the exact original operations.
        #expect(transport.operations == outbox, "\(transport.results)")
        #expect(try await central.companionNote(id: edited)?.content.contains("Plan edited offline") == true)
        #expect(try await central.companionSnapshot().folders.first { $0.id == folder }?.name == "Renamed offline")
        #expect(try await central.companionNote(id: deleted)?.content.contains("Draft v2") == true)
        // Nothing was replayed against this Mac's library, and the unapplied
        // deletion is visible rather than silently abandoned.
        #expect(try await node.companionNote(id: edited) == nil)
        let notes = try await node.companionSnapshot().notes
        #expect(notes.filter { $0.title == "Draft (Deletion not applied before pairing upgrade)" }.count == 1)
        #expect(!fixture.defaults.bool(forKey: LegacyMacLibraryUpgrade.connectedKey))
        // A retry after the lost pairing reply is exact: no duplicate intent.
        await #expect(throws: (any Error).self) {
            try await LegacyMacLibraryUpgrade.reconnect(host: fixture.host, defaults: fixture.defaults, makeTransport: { _ in transport })
        }
        #expect(try await node.companionSnapshot().notes.count == notes.count)
        #expect(try await central.companionNote(id: edited)?.content.contains("Plan edited offline") == true)
    }

    @Test func aFallbackGrantNeverReplacesAPendingPairingWithThatMac() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("pending-air"), mini = try await mesh.add("pending-mini"), third = try await mesh.add("pending-third")
        try await mesh.pair(air, with: mini); try await mesh.pair(third, with: mini)
        for _ in 0..<2 {
            await air.host.peerSync.synchronize(force: true)
            await third.host.peerSync.synchronize(force: true)
            await mini.host.peerSync.synchronize(force: true)
        }
        let airID = try await air.host.peerRoute().deviceID, thirdRoute = try await third.host.peerRoute()
        var credentials = mesh.credentials["pending-air"] ?? []
        credentials.removeAll { $0.route.deviceID == thirdRoute.deviceID }
        credentials.append(.init(route: thirdRoute, deviceID: airID, token: String(repeating: "p", count: 43),
            returnToken: String(repeating: "r", count: 43), needsJoin: true, confirmationPending: nil))
        mesh.credentials["pending-air"] = credentials
        await air.host.peerSync.synchronize(force: true)
        let pending = (mesh.credentials["pending-air"] ?? []).filter { $0.route.deviceID == thirdRoute.deviceID }
        #expect(pending.count == 1)
        #expect(pending.first?.needsJoin == true && pending.first?.returnToken == String(repeating: "r", count: 43))
    }
}

extension CompanionHostLifecycleTests {
    @Test func aFormerNodesInterruptedRunAndActiveGoalAreSafeOnTheUpgradeLaunch() async throws {
        let fixture = try await HostFixture(isNode: true); defer { fixture.remove() }
        let database = try #require(fixture.model.dashboardStore?.database)
        let replica = try MobileStore(file: fixture.directory.appending(path: "LibraryClient/library.json"))
        try await replica.bindWorkspace(UUID().uuidString.lowercased())
        let deviceID = await replica.snapshot().deviceID
        let executionDirectory = fixture.directory.appending(path: "LibraryClient/Execution/" + deviceID)
        try FileManager.default.createDirectory(at: executionDirectory, withIntermediateDirectories: true)
        let node = try await WorkspaceDatabase(url: executionDirectory.appending(path: "workspace.sqlite"))
        let session = try await node.createLocalACPSession(runtimeKind: .codex, title: "Node goal", ownerDeviceID: UUID(),
            executionRoot: .init(folderID: nil, location: .init(workspaceID: "local", rootPath: executionDirectory.path, managed: false), defaultPath: executionDirectory.path))
        let goal = try #require(try await node.mutateGoal(sessionID: session, mutation: .set(objective: "Keep going", tokenBudget: nil, turnBudget: nil)))
        let run = try await node.beginLocalACPRun(conversationID: session, content: "Interrupted by the upgrade")
        try await LegacyMacLibraryUpgrade.prepare(database: database, defaults: fixture.defaults)
        // Without a second restart: the imported run is recovered and the goal
        // cannot continue automatically; the chat stays this Mac's own work.
        let status = try await database.read { try $0.historyRowsUnlocked("SELECT status FROM dashboard_runs WHERE id=?", values: [run.runID]).first?.objectValue?["status"]?.stringValue }
        #expect(status != nil && status != "running")
        #expect(try await database.sessionGoals().first { $0.id == goal.id }?.status == .paused)
        #expect(try await database.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await database.locallyOwnsConversation(session))
        // The retained original execution database was not modified.
        #expect(try await node.read { try $0.historyRowsUnlocked("SELECT status FROM dashboard_runs WHERE id=?", values: [run.runID]).first?.objectValue?["status"]?.stringValue } == "running")
    }
}

extension CompanionHostLifecycleTests {
    @Test func anotherMacsChatTrashAndMoveGoToItsOwnerAndNeverApplyLocally() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("route-air"), mini = try await mesh.add("route-mini")
        try await mesh.pair(air, with: mini)
        await air.host.peerSync.synchronize(force: true)
        let airDB = try #require(air.model.dashboardStore?.database), miniDB = try #require(mini.model.dashboardStore?.database)
        let id = try await airDB.createFixtureLocalACPSession(runtimeKind: .codex, title: "Air's chat", ownerDeviceID: UUID())
        await air.host.peerSync.synchronize(force: true)
        let airID = try await air.host.peerRoute().deviceID
        #expect(try await mini.model.pairedOwnerWorkspace(conversationID: id)?.ownerDeviceID == airID)
        // The owner is unreachable: no transport, so routing fails closed.
        mini.model.federatedExecutionClient = try CentralExecutionClient(database: miniDB,
            commandJournalURL: mini.directory.appending(path: "route-commands.json"),
            provision: { _ in throw URLError(.notConnectedToInternet) },
            loadCredential: { _ in nil }, saveCredential: { _ in })
        await #expect(throws: (any Error).self) { try await mini.model.mutateConversation(id: id, mutation: .moveToTrash) }
        #expect(await mini.model.moveConversation(id: id, toFolderID: nil) == false)
        let deleted = { (database: WorkspaceDatabase) in
            try await database.read { try $0.historyRowsUnlocked("SELECT deleted_at FROM dashboard_conversations WHERE id=?", values: [id]).first?.objectValue?["deleted_at"]?.stringValue }
        }
        #expect(try await deleted(miniDB) == nil)
        // Rename stays a shared edit the observer may make.
        try await mini.model.mutateConversation(id: id, mutation: .rename("Renamed on the Mini"))
        await mini.host.peerSync.synchronize(force: true)
        #expect(try await deleted(airDB) == nil)
        #expect(try await airDB.read { try $0.historyRowsUnlocked("SELECT title FROM dashboard_conversations WHERE id=?", values: [id]).first?.objectValue?["title"]?.stringValue } == "Renamed on the Mini")
    }
}

extension CompanionHostLifecycleTests {
    @Test func aDirectReplacementRetiresDelegatedProvenanceButAFailedOneKeepsIt() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("replace-air"), mini = try await mesh.add("replace-mini")
        try await mesh.pair(air, with: mini)
        await air.host.peerSync.synchronize(force: true)
        let airID = try await air.host.peerRoute().deviceID, miniID = try await mini.host.peerRoute().deviceID
        let workspace = try #require(air.host.executionWorkspaces.first { $0.ownerDeviceID == airID && $0.kind == .mac })
        let miniAuth = try await mini.host.peerAuthentication(), airAuth = try await air.host.peerAuthentication()
        let phoneID = UUID().uuidString.lowercased()
        let phone = try await miniAuth.pair(.init(token: try await miniAuth.createOffer(endpoint: mini.host.peerRoute().endpoint).payload.token,
            deviceID: phoneID, deviceName: "Phone", metadata: .init(kind: .iPhone)), workspaceID: mini.host.peerRoute().libraryID)
        let delegated = try await mini.host.provisionExecutionWorkspace(id: workspace.id, device: miniAuth.authenticate(bearer: phone.credential))
        #expect(try await air.executionStatus(delegated) == 200)
        // The phone now pairs with the Air directly.
        let direct = try await airAuth.pair(.init(token: try await airAuth.createOffer(endpoint: air.host.peerRoute().endpoint).payload.token,
            deviceID: phoneID, deviceName: "Phone", metadata: .init(kind: .iPhone)), workspaceID: air.host.peerRoute().libraryID)
        let principal = try await airAuth.authenticate(bearer: direct.credential)
        // A failed direct replacement (for a workspace that does not exist) keeps the delegated origin.
        await #expect(throws: (any Error).self) { try await air.host.provisionExecutionWorkspace(id: UUID().uuidString.lowercased(), device: principal) }
        #expect(await airAuth.delegations(provisionedBy: miniID).map(\.workspaceID) == [workspace.id])
        // A successful direct replacement rotates the token and retires that origin.
        let replacement = try await air.host.provisionExecutionWorkspace(id: workspace.id, device: principal)
        #expect(await airAuth.delegations(provisionedBy: miniID).isEmpty)
        #expect(try await air.executionStatus(delegated) == 401)
        // Unpairing the Mini later never touches the Air's own direct grant.
        await air.host.revoke(miniID)
        #expect(try await air.executionStatus(replacement) == 200)
    }
}

/// A remote workspace that keeps one token per device, as the Linux service
/// and Mac execution management do; issuance can be suspended or failed.
@MainActor final class FakeRemoteExecutionWorkspace {
    var tokens: [String: String] = [:]
    var removals: [String] = []
    var suspendNextIssue = false, failNextIssue = false
    private(set) var suspended = false
    private var gate: CheckedContinuation<Void, Never>?

    func requests(_ workspace: CompanionExecutionWorkspace) -> CompanionHostController.RemoteExecutionRequests {
        .init(issue: { [self] _, deviceID in
            if suspendNextIssue {
                suspendNextIssue = false
                await withCheckedContinuation { gate = $0; suspended = true }
            }
            if failNextIssue { failNextIssue = false; throw URLError(.notConnectedToInternet) }
            let token = UUID().uuidString + UUID().uuidString
            tokens[deviceID] = token
            return CompanionExecutionCredential(workspace: workspace, deviceID: deviceID, token: token)
        }, revoke: { [self] _, deviceID in
            tokens.removeValue(forKey: deviceID); removals.append(deviceID)
        })
    }
    func untilSuspended() async throws {
        for _ in 0..<2_000 where !suspended { try await Task.sleep(for: .milliseconds(5)) }
        try #require(suspended)
    }
    func resume() { suspended = false; gate?.resume(); gate = nil }
}

extension CompanionHostLifecycleTests {
    /// The Air manages a remote workspace; the Mini's phone holds a grant there
    /// delegated through the Air, and the phone has also paired with the Air.
    private func remoteReplacementFixture(_ mesh: PeerTestMesh, _ prefix: String) async throws
        -> (air: HostFixture, miniID: String, workspaceID: String, phoneID: String, direct: CompanionPairedDevice, remote: FakeRemoteExecutionWorkspace) {
        let air = try await mesh.add(prefix + "-air"), mini = try await mesh.add(prefix + "-mini")
        try await mesh.pair(air, with: mini)
        await air.host.peerSync.synchronize(force: true)
        let airID = try await air.host.peerRoute().deviceID, miniID = try await mini.host.peerRoute().deviceID
        let database = try #require(air.model.dashboardStore?.database)
        let identity = try await database.companionLibraryIdentity()
        let workspace = try await database.registerCompanionExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: airID, kind: .linux,
            name: "Linux", endpoint: URL(string: "https://linux.fixture.ts.net/wovenmatter"), capabilities: ["execution.v1"])), deviceID: identity.hostDeviceID)
        let remote = FakeRemoteExecutionWorkspace()
        air.host.remoteExecutionRequests = remote.requests(workspace)
        let phoneID = UUID().uuidString.lowercased()
        let delegated = try await air.host.provisionDelegatedExecution(id: workspace.id, deviceID: phoneID, name: "Phone", provisionedBy: miniID)
        #expect(remote.tokens[phoneID] == delegated.token)
        let airAuth = try await air.host.peerAuthentication()
        #expect(await airAuth.delegations(provisionedBy: miniID).map(\.workspaceID) == [workspace.id])
        let pairing = try await airAuth.pair(.init(token: try await airAuth.createOffer(endpoint: air.host.peerRoute().endpoint).payload.token,
            deviceID: phoneID, deviceName: "Phone", metadata: .init(kind: .iPhone)), workspaceID: air.host.peerRoute().libraryID)
        return (air, miniID, workspace.id, phoneID, try await airAuth.authenticate(bearer: pairing.credential), remote)
    }

    @Test func aRemoteDirectReplacementSurvivesUnpairingTheDelegatingMacMidFlight() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let (air, miniID, workspaceID, phoneID, direct, remote) = try await remoteReplacementFixture(mesh, "race")
        // The direct replacement drains nothing and suspends at the remote workspace.
        remote.suspendNextIssue = true
        let replacement = Task { try await air.host.provisionExecutionWorkspace(id: workspaceID, device: direct) }
        try await remote.untilSuspended()
        // The Mini is unpaired meanwhile: its delegated grant's cleanup is queued
        // and cannot run while the workspace is guarded.
        await air.host.revoke(miniID)
        #expect(air.host.snapshot.pendingDeviceRevocations[phoneID] == [workspaceID])
        #expect(remote.removals.isEmpty)
        remote.resume()
        let fresh = try await replacement.value
        #expect(remote.tokens[phoneID] == fresh.token)
        // The replacement superseded that cleanup; a later retry never removes it.
        #expect(air.host.snapshot.pendingDeviceRevocations[phoneID] == nil)
        await air.host.retryPendingRevocations()
        #expect(remote.removals.isEmpty && remote.tokens[phoneID] == fresh.token)
        #expect(try await air.host.peerAuthentication().delegations(provisionedBy: miniID).isEmpty)
        // Unpairing the Mini again has nothing left to clean up for this phone.
        await air.host.revoke(miniID)
        await air.host.retryPendingRevocations()
        #expect(remote.tokens[phoneID] == fresh.token)
    }

    @Test func aFailedOrSameOriginRemoteReplacementKeepsTheQueuedCleanup() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        // A direct replacement that fails leaves the delegated token to be removed.
        do {
            let (air, miniID, workspaceID, phoneID, direct, remote) = try await remoteReplacementFixture(mesh, "failed")
            remote.suspendNextIssue = true; remote.failNextIssue = true
            let replacement = Task { try await air.host.provisionExecutionWorkspace(id: workspaceID, device: direct) }
            try await remote.untilSuspended()
            await air.host.revoke(miniID)
            remote.resume()
            await #expect(throws: (any Error).self) { try await replacement.value }
            #expect(air.host.snapshot.pendingDeviceRevocations[phoneID] == [workspaceID])
            await air.host.retryPendingRevocations()
            #expect(remote.removals == [phoneID] && remote.tokens[phoneID] == nil)
            #expect(air.host.snapshot.pendingDeviceRevocations[phoneID] == nil)
        }
        // A replacement from the Mac being unpaired never supersedes its own cleanup.
        do {
            let (air, miniID, workspaceID, phoneID, _, remote) = try await remoteReplacementFixture(mesh, "same")
            remote.suspendNextIssue = true
            let replacement = Task { try await air.host.provisionDelegatedExecution(id: workspaceID, deviceID: phoneID, name: "Phone", provisionedBy: miniID) }
            try await remote.untilSuspended()
            await air.host.revoke(miniID)
            remote.resume()
            await #expect(throws: (any Error).self) { try await replacement.value }
            #expect(remote.tokens[phoneID] != nil)
            await air.host.retryPendingRevocations()
            #expect(remote.tokens[phoneID] == nil && remote.removals == [phoneID])
            #expect(air.host.snapshot.pendingDeviceRevocations[phoneID] == nil)
        }
    }
}
