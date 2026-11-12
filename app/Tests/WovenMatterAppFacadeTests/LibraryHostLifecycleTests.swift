import CryptoKit
import Foundation
import Testing
import WovenMatterClient
import LibraryClient
import WorkspaceFixtures
import WovenMatterCore
import WovenMatterShared
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct LibraryHostLifecycleTests {

    @Test func restoredCancellationRetainsItsProofUntilTheMacAcknowledges() async throws {
        let identity = PairingDeviceIdentity(deviceID: UUID().uuidString.lowercased(), deviceName: "Fixture Mac", metadata: .init(kind: .mac))
        let request = PairingApprovalRequest(requestID: UUID().uuidString.lowercased(), requestSecret: String(repeating: "s", count: 43), identity: identity)
        let cancelled = StoredPairingClaim(endpoint: URL(string: "https://fixture.test.ts.net:8443/wovenmatter")!,
            request: request, expiresAt: Date().addingTimeInterval(600), cancelled: true)
        var stored: Data? = try JSONEncoder().encode(cancelled)
        var attempts = 0, paired = false
        let controller = MacPairingController(identity: { identity }, onPaired: { _, _ in paired = true },
            loadClaim: { _ in try stored.map { try JSONDecoder().decode(StoredPairingClaim.self, from: $0) } },
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
        try await fixture.model.configureFacadeFixture(directory: fixture.directory)
        fixture.model.libraryHost = fixture.host
        let backend = BackendApplicationService(model: fixture.model)
        func request(_ action: LibraryHostAction) throws -> BackendRPCRequest {
            .init(method: "application.command", payload: try JSONEncoder().encode(BackendApplicationCommand.libraryHost(action)))
        }
        let start = await backend.handle(try request(.start))
        #expect(start.error == nil)
        let started = try JSONDecoder().decode(BackendApplicationResult.self, from: try #require(start.result))
        #expect(started.libraryHost?.endpoint == fixture.host.endpoint)
        #expect(started.libraryHost?.isEnabled == true)
        let codeRequest = try request(.createCode)
        let code = await backend.handle(codeRequest)
        #expect(code.error == nil)
        let offered = try JSONDecoder().decode(BackendApplicationResult.self, from: try #require(code.result))
        #expect(offered.libraryHost?.pairingPayload != nil)
        #expect(await backend.handle(codeRequest).result == code.result)
        #expect(fixture.exposureCount == 1)
        let stop = await backend.handle(try request(.stop))
        #expect(stop.error == nil)
        let stopped = try JSONDecoder().decode(BackendApplicationResult.self, from: try #require(stop.result))
        #expect(stopped.libraryHost?.endpoint == nil)
        #expect(stopped.libraryHost?.isEnabled == false)
        #expect(fixture.host.endpoint == nil)
    }

    @Test func foregroundHostServesDevelopmentEnrollmentAndRepeatedStartupKeepsTheEndpoint() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        try await fixture.model.configureFacadeFixture(directory: fixture.directory)
        fixture.model.libraryHost = fixture.host
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
            networkRequest.setValue(String(LibraryProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
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


    /// A client-mode Dev build's stream ("Client mode", docs/DEVELOPMENT_BUILDS.md):
    /// its key is enrolled with `development.connect` on the same-user socket,
    /// stays out of the synced member list, opens only the loopback development
    /// listener, and is revoked (4401) when the client disconnects.
    @Test func aDevStreamKeyIsLocalOnlyOpensOnlyTheLoopbackStreamAndIsRevokedOnDisconnect() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        try await fixture.model.configureFacadeFixture(directory: fixture.directory)
        fixture.model.libraryHost = fixture.host
        await fixture.host.start()
        let socket = LocalExecutionRole.backendSocketURL(workspaceDirectory: fixture.directory)
        defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
        try fixture.model.startDevelopmentConnectionService(socketURL: socket)
        let rpc = try #require(fixture.model.backendRPCServer)
        defer { rpc.stop() }
        let database = try #require(fixture.model.dashboardStore?.database)
        let membersBefore = try await database.libraryMemberRecords()

        let deviceID = UUID().uuidString.lowercased()
        let key = Curve25519.Signing.PrivateKey()
        let connected = try JSONDecoder().decode(DevelopmentClientConnection.self, from: await BackendRPCClient(socketURL: socket).call(
            method: "development.connect", payload: JSONEncoder().encode(DevelopmentClientRequest(deviceID: deviceID, name: "Dev · fixture",
                memberKey: key.publicKey.rawRepresentation))))
        let route = try #require(connected.stream, "development.connect admits the stream key with the new credential")
        let identity = try await database.libraryIdentity()
        #expect(route.libraryID == identity.libraryID)

        // The key never enters the synced member list: no entry, removal or
        // anchor names the Dev device or carries its key.
        let members = try await database.libraryMemberRecords()
        #expect(members.entries == membersBefore.entries && members.revocations == membersBefore.revocations)
        #expect(!members.entries.contains { $0.deviceID == deviceID || $0.publicKey == key.publicKey.rawRepresentation })
        #expect(!members.anchors.contains { $0.deviceID == deviceID })

        func signed(_ signer: MemberRequestSigner, port: UInt16, audience: String = route.audience) throws -> WebSocketStreamTransport {
            let url = WebSocketStreamTransport.loopbackURL(port: port)
            return WebSocketStreamTransport.loopback(port: port,
                headers: try signer.headers(method: "GET", target: StreamEndpoint.target(of: url), audience: audience))
        }
        let devSigner = MemberRequestSigner(deviceID: deviceID, key: key)

        // A roster key's loopback upgrade is accepted: the hello names this host.
        let stream = try signed(devSigner, port: route.port)
        guard case .hello(let hello) = try await stream.receive() else { Issue.record("hello was not first"); return }
        #expect(hello.deviceID == route.audience && hello.libraryID == route.libraryID && hello.workspaceID == route.workspaceID)
        try await stream.send(.subscribe(.init(id: "w", stream: .workspace)))
        guard case .item(let first) = try await stream.receive(), case .conversations(let snapshot) = first.payload else {
            Issue.record("no conversations snapshot"); return
        }
        #expect(first.id == "w" && snapshot.snapshot)
        // A stream key only reads: it answers no call. Commands go through the library API.
        var command = LibraryCommand(deviceID: deviceID, kind: .stop, conversationID: UUID().uuidString.lowercased())
        command.libraryID = route.libraryID; command.workspaceID = route.workspaceID
        try await stream.send(.request(try .init(id: "c", method: .executionCommand, params: StreamCommandParams(command: command))))
        var refusedCall: StreamResponse?
        while refusedCall == nil { if case .response(let value) = try await stream.receive() { refusedCall = value } }
        #expect(refusedCall?.error?.code == "invalid")

        // Any other key is refused before the upgrade, a library member's included.
        let stranger = MemberRequestSigner(deviceID: UUID().uuidString.lowercased(), key: .init())
        await #expect(throws: StreamConnectionError.unauthorized) { _ = try await signed(stranger, port: route.port).receive() }
        let phoneKey = Curve25519.Signing.PrivateKey(), phoneID = UUID().uuidString.lowercased()
        try await fixture.host.peerSync.members().add(deviceID: phoneID, kind: .ios, name: "Phone",
            publicKey: phoneKey.publicKey.rawRepresentation, endpoints: [])
        let phone = MemberRequestSigner(deviceID: phoneID, key: phoneKey)
        await #expect(throws: StreamConnectionError.unauthorized) { _ = try await signed(phone, port: route.port).receive() }
        // And the Dev key opens nothing on the library's own (Tailscale) listener.
        let shared = try #require(URL(string: try fixture.loopbackURL(path: "").absoluteString)?.port.map(UInt16.init))
        let sharedURL = try #require(URL(string: "ws://127.0.0.1:\(shared)/wovenmatter/" + WovenMatterShared.StreamProtocol.path + "?" + WovenMatterShared.StreamProtocol.query))
        var sharedRequest = URLRequest(url: sharedURL)
        for (name, value) in try devSigner.headers(method: "GET", target: StreamEndpoint.target(of: sharedURL), audience: route.audience) {
            sharedRequest.setValue(value, forHTTPHeaderField: name)
        }
        let sharedTask = URLSession.shared.webSocketTask(with: sharedRequest); sharedTask.resume()
        await #expect(throws: (any Error).self) { _ = try await sharedTask.receive() }
        #expect((sharedTask.response as? HTTPURLResponse)?.statusCode == 401)

        // The same-user admission needs this Dev identity's current credential.
        let wrong = DevelopmentStreamRequest(deviceID: deviceID, credential: String(repeating: "x", count: 43),
                                             memberKey: key.publicKey.rawRepresentation)
        await #expect(throws: BackendRPCError.self) {
            _ = try await BackendRPCClient(socketURL: socket).call(method: "development.stream", payload: JSONEncoder().encode(wrong))
        }
        let again = DevelopmentStreamRequest(deviceID: deviceID, credential: connected.pairing.credential, memberKey: key.publicKey.rawRepresentation)
        let readmitted = try JSONDecoder().decode(DevelopmentStreamRoute.self, from: await BackendRPCClient(socketURL: socket).call(
            method: "development.stream", payload: JSONEncoder().encode(again)))
        #expect(readmitted == route)

        // Disconnecting (as quitting the Dev client does) revokes the key: the
        // open socket closes with 4401 and the key no longer upgrades.
        _ = try await BackendRPCClient(socketURL: socket).call(method: "development.disconnect",
            payload: JSONEncoder().encode(DevelopmentDisconnectRequest(deviceID: deviceID, credential: connected.pairing.credential)))
        var closeCode: Int?
        do { while true { _ = try await stream.receive() } }
        catch let closed as StreamTransportClosed { closeCode = closed.code }
        #expect(closeCode == WovenMatterShared.StreamProtocol.CloseCode.memberRemoved.rawValue)
        await #expect(throws: StreamConnectionError.unauthorized) { _ = try await signed(devSigner, port: route.port).receive() }
    }

    @Test func developmentDisconnectWithdrawsWorkspaceAndRestartReusesIdentity() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        await fixture.host.start()
        let database = try #require(fixture.model.dashboardStore?.database)
        let identity = try await database.libraryIdentity()
        let request = DevelopmentClientRequest(deviceID: UUID().uuidString.lowercased(), name: "Dev · fixture")
        let connection = try await fixture.host.connectLocalDevelopment(request)
        let workspace = try await database.registerExecutionWorkspace(.init(workspace: .init(
            id: request.deviceID, libraryID: identity.libraryID, ownerDeviceID: request.deviceID, kind: .mac,
            name: "Mac (Dev) · fixture", endpoint: URL(string: "https://fixture.test.ts.net/wovenmatter"),
            executionDeviceID: request.deviceID, developmentInstance: "fixture")), deviceID: identity.hostDeviceID)
        let absent = try await database.libraryConnectionWorkspaces(activeDeviceIDs: [])
        #expect(absent.first { $0.id == workspace.id }?.isVisibleInConnections == false)
        let reconnected = try await database.libraryConnectionWorkspaces(activeDeviceIDs: [request.deviceID])
        #expect(reconnected.first { $0.id == workspace.id }?.endpoint == workspace.endpoint)
        #expect(try await database.libraryExecutionWorkspaces().first { $0.id == workspace.id }?.revision == workspace.revision)
        try await fixture.host.disconnectLocalDevelopment(.init(deviceID: request.deviceID, credential: connection.pairing.credential))
        #expect(!fixture.host.pairedDevices.contains { $0.id == request.deviceID })
        let retained = try #require(try await database.libraryExecutionWorkspaces().first { $0.id == workspace.id })
        #expect(!retained.deleted && retained.endpoint == nil && !retained.isVisibleInConnections)
        _ = try await fixture.host.connectLocalDevelopment(request)
        #expect(fixture.host.pairedDevices.contains { $0.id == request.deviceID })
        var restarted = retained; restarted.endpoint = workspace.endpoint
        _ = try await database.registerExecutionWorkspace(.init(workspace: restarted, expectedRevision: retained.revision), deviceID: identity.hostDeviceID)
        await fixture.host.refreshStatus()
        #expect(fixture.host.executionWorkspaces.first { $0.id == workspace.id }?.isVisibleInConnections == true)
    }

    @Test func clickPairingHTTPRequiresLocalApprovalAndReturnsAccurateMetadata() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        await fixture.host.startForCentralDatabase()
        // The address is published before the workspace API is ready; wait for both.
        try await waitUntil { fixture.host.endpoint != nil && !fixture.host.isStarting && fixture.host.status == "Available to your paired devices" }
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
        let advertisement = try JSONDecoder().decode(DiscoveryAdvertisement.self, from: advertised)
        #expect(advertisement.role == .central && advertisement.identity.metadata.kind == .mac)
        #expect(!String(decoding: advertised, as: UTF8.self).contains("credential"))
        let request = PairingApprovalRequest(requestID: UUID().uuidString.lowercased(), requestSecret: UUID().uuidString + UUID().uuidString,
            identity: .init(deviceID: UUID().uuidString.lowercased(), deviceName: "Peer Mac", metadata: .init(kind: .mac, osVersion: "fixtureOS", appVersion: "fixtureApp")))
        let (pendingData, pendingStatus) = try await post("v1/pairing/request", JSONEncoder().encode(request))
        let pending = try JSONDecoder().decode(PairingApprovalResult.self, from: pendingData)
        #expect(pendingStatus == 200 && pending.state == .pending && pending.pairing == nil)
        await fixture.host.refreshStatus()
        #expect(fixture.host.pendingPairingRequests.first?.identity == request.identity)
        #expect(fixture.host.pairedDevices.isEmpty)
        let (_, forbidden) = try await post("v1/pairing/approve", Data("{}".utf8))
        #expect(forbidden != 200)
        await fixture.host.approvePairing(id: request.requestID)
        let (approvedData, status) = try await post("v1/pairing/result", JSONEncoder().encode(PairingPoll(requestID: request.requestID, requestSecret: request.requestSecret)))
        let approved = try JSONDecoder().decode(PairingApprovalResult.self, from: approvedData)
        #expect(status == 200 && approved.pairing?.deviceID == request.identity.deviceID)
        #expect(fixture.host.pairedDevices.first?.metadata == request.identity.metadata)
        #expect(fixture.host.pairedDevices.first?.lastSeenAt == nil)
        let principal = try #require(fixture.host.pairedDevices.first)
        let workspace = try #require(fixture.host.executionWorkspaces.first { $0.kind == .mac })
        let direct = try await fixture.host.provisionExecutionWorkspace(id: workspace.id, device: principal)
        #expect(try await fixture.executionStatus(direct) == 200)
        let (_, cancelled) = try await post("v1/pairing/cancel", JSONEncoder().encode(PairingPoll(requestID: request.requestID, requestSecret: request.requestSecret)))
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
        await #expect(throws: LibraryAPIError.self) {
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
    let existingPorts: Set<Int> = [443]
    var exposureCount = 0
    var children: [HostServingChild] = []
    var dnsName = "fixture.test.ts.net"

    init(isNode: Bool = false) async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "library-host-\(UUID())")
        suite = "library.host.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(isNode, forKey: LocalExecutionRole.libraryClientPreferenceKey)
        let store = try await DashboardStore(supportDirectory: directory)
        model = ApplicationModel(applicationDefaults: defaults, dashboardStore: store, startsAutomatically: false)
    }
    /// Local folders are bound to `device:<dashboard device id>`, generated apart
    /// from the registry id and host device id. A record an earlier build
    /// published without the folder owner gains it on the next refresh, under
    /// the same workspace id, so existing folders are never rewritten.
    @Test func theCentralMacPublishesTheFolderOwnerItsFoldersUse() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        await fixture.host.start()
        let database = try #require(fixture.model.dashboardStore?.database)
        let identity = try await database.libraryIdentity()
        let folderOwner = try await fixture.model.executionWorkspaceIdentity(workspaceID: nil)
        try await fixture.host.refreshExecutionRegistry()
        let published = try #require(try await database.libraryExecutionWorkspaces().first { $0.kind == .mac && $0.ownerDeviceID == identity.hostDeviceID })
        #expect(ExecutionWorkspace.displayID(folderOwner) != published.id)
        #expect(ExecutionWorkspace.displayID(folderOwner) != identity.hostDeviceID)
        #expect(published.folderOwnerID == folderOwner)
        #expect(ExecutionWorkspace.displayOwner(of: folderOwner, in: [published]) == published.id)

        var legacy = published; legacy.folderOwnerID = nil
        let downgraded = try await database.registerExecutionWorkspace(.init(workspace: legacy, expectedRevision: published.revision), deviceID: identity.hostDeviceID)
        #expect(ExecutionWorkspace.displayOwner(of: folderOwner, in: [downgraded]) == nil)
        try await fixture.host.refreshExecutionRegistry()
        let upgraded = try #require(try await database.libraryExecutionWorkspaces().first { $0.id == published.id })
        #expect(upgraded.folderOwnerID == folderOwner && upgraded.revision == downgraded.revision + 1)

        var forged = upgraded; forged.folderOwnerID = "remote:" + UUID().uuidString
        await #expect(throws: (any Error).self) {
            try await database.registerExecutionWorkspace(.init(workspace: forged, expectedRevision: upgraded.revision), deviceID: identity.hostDeviceID)
        }
    }

    func makeHost() -> LibraryHostController {
        // Fixtures never reach the user's Keychain: paired grants, pending
        // claims, legacy and direct execution credentials stay in memory.
        LibraryHostController(model: model, defaults: defaults, supportDirectory: directory, retryInterval: .milliseconds(25),
            peerStorage: storage, makeExposure: { [unowned self] in makeExposure() })
    }
    func pairAndProvision(name: String, deviceID: String = UUID().uuidString.lowercased()) async throws -> ExecutionCredential {
        await host.createPairingCode()
        let offer = try #require(host.pairingPayload)
        var request = URLRequest(url: try loopbackURL(path: "v1/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairRequest(token: offer.token,
            deviceID: deviceID, deviceName: name))
        let (bytes, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let paired = try JSONDecoder().decode(PairResponse.self, from: bytes)
        let device = try #require(host.pairedDevices.first { $0.id == paired.deviceID })
        let database = try #require(model.dashboardStore?.database)
        let identity = try await database.libraryIdentity()
        let workspaces = try await database.libraryExecutionWorkspaces()
        let workspace = try #require(workspaces.first { $0.kind == .mac && $0.ownerDeviceID == identity.hostDeviceID })
        return try await host.provisionExecutionWorkspace(id: workspace.id, device: device)
    }
    func executionStatus(_ credential: ExecutionCredential) async throws -> Int {
        var request = URLRequest(url: try loopbackURL(path: "v1/execution"))
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        request.setValue(String(LibraryProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
        request.setValue(credential.workspace.libraryID, forHTTPHeaderField: "X-Woven-Library")
        request.setValue(credential.workspace.id, forHTTPHeaderField: "X-Woven-Workspace")
        request.setValue(credential.deviceID, forHTTPHeaderField: "X-Woven-Device")
        let (_, response) = try await URLSession.shared.data(for: request)
        return try #require((response as? HTTPURLResponse)?.statusCode)
    }
    func libraryStatus(bearer: String) async throws -> Int {
        var request = URLRequest(url: try loopbackURL(path: "v1/snapshot"))
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue(String(LibraryProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
        let (_, response) = try await URLSession.shared.data(for: request)
        return try #require((response as? HTTPURLResponse)?.statusCode)
    }
    func loopbackURL(path: String) throws -> URL {
        let child = try #require(children.last { $0.isRunning })
        return try #require(URL(string: child.target)).appendingPathComponent(path)
    }
    func makeExposure() -> TailscaleServe {
        exposureCount += 1
        return TailscaleServe(executable: URL(fileURLWithPath: "/fixture/tailscale"),
            probe: { [self] _, arguments in try await probe(arguments) },
            launch: { [self] _, arguments in
                let child = HostServingChild(port: Int(arguments[1].dropFirst("--https=".count))!, target: arguments[3])
                children.append(child)
                return child
            })
    }
    func probe(_ arguments: [String]) throws -> Data {
        if arguments == ["status", "--json"] {
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
    func remove() {
        host.stopSharing()
        children.forEach { $0.forceStopped = true }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor private final class HostServingChild: TailscaleServingProcess {
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
    /// Every peer call, not only pairing, crosses each Mac's own loopback HTTP
    /// listener and production request routing.
    let overHTTP: Bool
    init(overHTTP: Bool = false) { self.overHTTP = overHTTP }
    /// Every request that reached a Mac, as "endpoint path", and a hook that
    /// runs after a successful response, before the caller resumes.
    var requested: [String] = []
    var afterResponse: (@MainActor (URL, String) async throws -> Void)?
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
        fixture.host.peerSync.peerTransport = LibraryPeerTransport { [weak self] endpoint, request in
            guard let self else { throw URLError(.cancelled) }
            return try await self.member(endpoint, request)
        }
        await fixture.host.start()
        let route = try await fixture.host.peerRoute()
        hosts[route.endpoint.absoluteString] = fixture
        deviceEndpoints[route.deviceID] = route.endpoint.absoluteString
        return fixture
    }
    var deviceEndpoints: [String: String] = [:]
    /// Signed member requests between Macs: the same offline rules, request
    /// log and lost-reply hook as bearer requests. An offline Mac also sends nothing.
    func member(_ endpoint: URL, _ request: LibraryHTTPRequest) async throws -> LibraryHTTPResponse {
        let caller = request.headers[MemberRequestSignature.deviceHeader].flatMap { deviceEndpoints[$0] }
        guard !offline.contains(endpoint.absoluteString), caller.map({ !offline.contains($0) }) ?? true,
              let fixture = hosts[endpoint.absoluteString] else { throw URLError(.notConnectedToInternet) }
        let path = String(MemberRequestSignature.canonicalTarget(request.target).drop { $0 == "/" })
        requested.append(endpoint.absoluteString + " " + path)
        let response: LibraryHTTPResponse
        if overHTTP {
            var http = URLRequest(url: try fixture.loopbackURL(path: path))
            http.httpMethod = request.method; http.httpBody = request.body
            for (name, value) in request.headers where name != "Host" { http.setValue(value, forHTTPHeaderField: name) }
            let (data, reply) = try await URLSession.shared.data(for: http)
            response = .init(status: (reply as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } else {
            let headers = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.key.lowercased(), $0.value) })
            response = try #require(await fixture.host.peerSync.handle(.init(method: request.method, target: request.target, headers: headers, body: request.body)))
        }
        if response.status == 200, loseReplyOnce.remove(path) != nil { throw URLError(.networkConnectionLost) }
        if response.status == 200 { try await afterResponse?(endpoint, path) }
        return response
    }
    func request(_ endpoint: URL, path: String, token: String?, libraryID: String?, body: Data?) async throws -> Data {
        guard !offline.contains(endpoint.absoluteString), let fixture = hosts[endpoint.absoluteString] else { throw URLError(.notConnectedToInternet) }
        requested.append(endpoint.absoluteString + " " + path)
        if path == "v1/discovery" && !overHTTP {
            let identity = try #require(fixture.host.peerIdentity)
            return try JSONEncoder().encode(DiscoveryAdvertisement(role: .central, identity: identity, capabilities: [PairedMacSyncController.capability]))
        }
        if overHTTP || ["v1/pair/preview", "v1/pair", "v1/pair/confirm"].contains(path) {
            var request = URLRequest(url: try fixture.loopbackURL(path: path))
            request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(String(LibraryProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            if let libraryID { request.setValue(libraryID, forHTTPHeaderField: "X-Woven-Workspace") }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw try JSONDecoder().decode(LibraryAPIError.self, from: data) }
            if loseReplyOnce.remove(path) != nil { throw URLError(.networkConnectionLost) }
            try await afterResponse?(endpoint, path)
            return data
        }
        var headers = ["x-woven-protocol": String(LibraryProtocol.version)]
        if let token { headers["authorization"] = "Bearer " + token }
        if let libraryID { headers["x-woven-workspace"] = libraryID }
        let response = try #require(await fixture.host.peerSync.handle(.init(method: body == nil ? "GET" : "POST", target: "/" + path, headers: headers, body: body ?? Data())))
        guard response.status == 200 else { throw try JSONDecoder().decode(LibraryAPIError.self, from: response.body) }
        if loseReplyOnce.remove(path) != nil { throw URLError(.networkConnectionLost) }
        try await afterResponse?(endpoint, path)
        return response.body
    }
    func pair(_ first: HostFixture, with second: HostFixture) async throws {
        let route = try await second.host.peerRoute()
        let own = try await first.host.peerRoute()
        let authentication = try await second.host.peerAuthentication()
        let offer = try await authentication.createOffer(endpoint: route.endpoint)
        let response = try await authentication.pair(.init(token: offer.payload.token, deviceID: own.deviceID, deviceName: own.name, metadata: .init(kind: .mac),
            purpose: PairingPurpose.peerMac), workspaceID: route.libraryID)
        try await first.host.peerSync.acceptPairing(endpoint: route.endpoint, response: response)
    }
    func remove() { for fixture in hosts.values { fixture.remove() }; hosts = [:] }
}

extension LibraryHostLifecycleTests {
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
        _ = try await airDB.applyLibraryMutation(.init(deviceID: airID, kind: .createNote, resourceID: first, title: "Air offline", content: try NoteDocument(blocks: [.richText(.init(text: "Air writing"))]).encoded()))
        _ = try await thirdDB.applyLibraryMutation(.init(deviceID: thirdID, kind: .createNote, resourceID: second, title: "Third offline", content: try NoteDocument(blocks: [.richText(.init(text: "Third writing"))]).encoded()))
        let remote = RemoteWorkspaceConfiguration(name: "Added from third Mac", workspaceID: "new-remote", hostName: "linux.fixture.ts.net", kind: .host)
        try await thirdDB.savePairedRemoteWorkspaces([remote])
        let phoneID = UUID().uuidString.lowercased()
        let authentication = try await third.host.peerAuthentication()
        let offer = try await authentication.createOffer(endpoint: third.host.peerRoute().endpoint)
        let phone = try await authentication.pair(.init(token: offer.payload.token, deviceID: phoneID, deviceName: "New iPhone", metadata: .init(kind: .iPhone)), workspaceID: thirdDB.libraryID())
        await air.host.peerSync.synchronize(force: true)
        await third.host.peerSync.synchronize(force: true)
        #expect(try await airDB.libraryNote(id: second)?.title == "Third offline")
        #expect(try await thirdDB.libraryNote(id: first)?.title == "Air offline")
        #expect(try await airDB.read { try !$0.historyRowsUnlocked("SELECT 1 FROM paired_remote_workspaces WHERE id=?", values: [remote.id.uuidString.lowercased()]).isEmpty })
        // The new phone is listed for display and delegation, but its bearer
        // authenticates only at the Mac it paired with.
        #expect(try await air.host.peerAuthentication().rosterName(for: phoneID) == "New iPhone")
        await #expect(throws: LibraryAPIError.self) { try await air.host.peerAuthentication().authenticate(bearer: phone.credential) }
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
            await #expect(throws: LibraryAPIError.self) { try await airAuth.authenticate(bearer: bearer) }
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
        let withdrawn = try #require(try await mini.model.dashboardStore?.database.libraryExecutionWorkspaces().first { $0.id == workspace.id })
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
        air.host.beforeLocalRevocation = { id in if id == phoneID { failures += 1; throw LibraryAPIError(code: "fixture", message: "Injected") } }
        let token = try #require(mesh.credentials["order-mini"]?.first { $0.route.deviceID == airID }?.token)
        let exchange = PairedMacExchange(deviceID: try await mini.host.peerRoute().deviceID, after: 0,
            page: .init(schema: "incompatible", entries: [], cursor: 0, hasMore: false), membership: await miniAuth.peerMembership())
        await #expect(throws: (any Error).self) {
            try await mesh.request(air.host.peerRoute().endpoint, path: "v1/peers/exchange", token: token, libraryID: nil, body: JSONEncoder().encode(exchange))
        }
        // The unpair still took effect before the page was rejected...
        #expect(try await air.executionStatus(execution) == 401)
        // The exchange attempted local revocation. The Air's own change-driven
        // sync may also learn the unpair from the Mini meanwhile and retry it
        // (and fail the same way), so more than one attempt is legitimate.
        #expect(failures >= 1)
        // ...but is recorded as applied only once local revocation succeeds.
        let applied = { air.defaults.stringArray(forKey: LibraryHostController.appliedPeerRevocationsKey) ?? [] }
        #expect(!applied().contains { $0.hasPrefix(phoneID + ":") })
        air.host.beforeLocalRevocation = nil
        try await air.host.applyPeerRevocations()
        #expect(applied().contains { $0.hasPrefix(phoneID + ":") })
    }
}


extension LibraryHostLifecycleTests {
    private func writeNote(_ fixture: HostFixture, _ id: String, _ title: String) async throws {
        let database = try #require(fixture.model.dashboardStore?.database)
        let deviceID = try await fixture.host.peerRoute().deviceID
        _ = try await database.applyLibraryMutation(.init(deviceID: deviceID, kind: .createNote, resourceID: id, title: title,
            content: try NoteDocument(blocks: [.richText(.init(text: title))]).encoded()))
    }
    private func httpMesh(_ prefix: String) async throws -> (PeerTestMesh, HostFixture, HostFixture, HostFixture) {
        let mesh = PeerTestMesh(overHTTP: true)
        let air = try await mesh.add(prefix + "-air"), mini = try await mesh.add(prefix + "-mini"), third = try await mesh.add(prefix + "-third")
        try await mesh.pair(air, with: mini); try await mesh.pair(third, with: mini)
        for _ in 0..<2 { for fixture in [air, third, mini] { await fixture.host.peerSync.synchronize(force: true) } }
        return (mesh, air, mini, third)
    }

    /// Three Macs, each with its own database, credential vault and loopback
    /// listener, synchronize only through production HTTP routes: the joining
    /// Mac goes offline, an exchange reply is lost after it committed, and a
    /// controller restarts over the same vault.
    @Test func threeMacsConvergeOverHTTPThroughAnOfflineJoinerALostReplyAndARestart() async throws {
        let (mesh, air, mini, third) = try await httpMesh("http")
        defer { mesh.remove() }
        let airDB = try #require(air.model.dashboardStore?.database), thirdDB = try #require(third.model.dashboardStore?.database)
        mesh.offline.insert(try await mini.host.peerRoute().endpoint.absoluteString)
        let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        try await writeNote(air, first, "Air over HTTP"); try await writeNote(third, second, "Third over HTTP")
        mesh.loseReplyOnce = ["v1/peers/sync"]
        await air.host.peerSync.synchronize(force: true)
        #expect(mesh.loseReplyOnce.isEmpty)
        var storage = air.storage
        storage.loadCredentials = { mesh.credentials["http-air"] ?? [] }; storage.saveCredentials = { mesh.credentials["http-air"] = $0 }
        air.host.peerSync = PairedMacSyncController(host: air.host, network: PairedMacNetwork(request: { endpoint, path, token, libraryID, body in
            try await mesh.request(endpoint, path: path, token: token, libraryID: libraryID, body: body)
        }), storage: storage)
        for _ in 0..<2 {
            await air.host.peerSync.synchronize(force: true)
            await third.host.peerSync.synchronize(force: true)
        }
        #expect(try await airDB.libraryNote(id: second)?.title == "Third over HTTP")
        #expect(try await thirdDB.libraryNote(id: first)?.title == "Air over HTTP")
        #expect(air.host.peerSync.errors.isEmpty && third.host.peerSync.errors.isEmpty)
    }

    /// A requester whose own unpair arrives in its exchange is refused before
    /// its page is accepted or any library content is returned.
    @Test func anExchangeCarryingItsRequestersUnpairIsRefusedBeforeAnyPage() async throws {
        let (mesh, air, mini, third) = try await httpMesh("gate")
        defer { mesh.remove() }
        let airID = try await air.host.peerRoute().deviceID, miniID = try await mini.host.peerRoute().deviceID
        let airDB = try #require(air.model.dashboardStore?.database), miniDB = try #require(mini.model.dashboardStore?.database)
        #expect(try await air.host.peerAuthentication().isActiveMac(miniID))
        await third.host.revoke(miniID)
        let unpair = try await third.host.peerAuthentication().peerMembership()
        let secret = UUID().uuidString.lowercased()
        try await writeNote(mini, secret, "Sent with its own unpair")
        let token = try #require(mesh.credentials["gate-mini"]?.first { $0.route.deviceID == airID && $0.isCompleted }?.token)
        let page = try await miniDB.pairedLibraryPage(after: miniDB.pairedLibraryCursors(airID).pushed)
        #expect(page.entries.contains { $0.table == "notes" && $0.key == "[\"\(secret)\"]" })
        let exchange = PairedMacExchange(deviceID: miniID, after: 0, page: page, membership: unpair)
        await #expect(throws: LibraryAPIError.self) {
            try await mesh.request(air.host.peerRoute().endpoint, path: "v1/peers/exchange", token: token, libraryID: nil, body: JSONEncoder().encode(exchange))
        }
        #expect(try await airDB.libraryNote(id: secret) == nil)
        #expect(try await !air.host.peerAuthentication().isActiveMac(miniID))
    }

    /// An unpair made on this Mac while a file transfer is in progress lets the
    /// request in flight finish but sends no further file request.
    @Test func anUnpairDuringAFileTransferSendsNoFurtherRequest() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("files-air"), mini = try await mesh.add("files-mini")
        try await mesh.pair(air, with: mini)
        await air.host.peerSync.synchronize(force: true)
        let airDB = try #require(air.model.dashboardStore?.database), miniDB = try #require(mini.model.dashboardStore?.database)
        let hash = try LibraryFileStore(supportDirectory: miniDB.supportDirectory).retain(Data(repeating: 91, count: 1_300_000))
        let miniRoute = try await mini.host.peerRoute()
        mesh.afterResponse = { endpoint, path in
            guard endpoint == miniRoute.endpoint, path == "v1/peers/file" else { return }
            mesh.afterResponse = nil
            await air.host.revoke(miniRoute.deviceID)
        }
        mesh.requested = []
        await air.host.peerSync.synchronize(force: true)
        #expect(mesh.requested.filter { $0 == miniRoute.endpoint.absoluteString + " v1/peers/file" }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: airDB.supportDirectory.appending(path: "library-files/" + hash).path))
    }

    /// A reply that carries the replying Mac's own unpair stops the exchange
    /// before its page is accepted.
    @Test func aReplyCarryingThePeersUnpairStopsTheExchangeBeforeItsPage() async throws {
        let (mesh, air, mini, third) = try await httpMesh("reply")
        defer { mesh.remove() }
        let miniID = try await mini.host.peerRoute().deviceID
        let airDB = try #require(air.model.dashboardStore?.database)
        await third.host.revoke(miniID)
        mesh.offline.insert(try await third.host.peerRoute().endpoint.absoluteString)
        // The Mini learns its own unpair and returns it in its next reply.
        let miniIdentity = try await mini.host.peerSync.identity()
        try await mini.host.peerAuthentication().mergeMembership(third.host.peerAuthentication().peerMembership(), own: miniIdentity)
        let secret = UUID().uuidString.lowercased()
        try await writeNote(mini, secret, "Returned with its own unpair")
        await air.host.peerSync.synchronize(force: true)
        #expect(try await airDB.libraryNote(id: secret) == nil)
        #expect(try await !air.host.peerAuthentication().isActiveMac(miniID))
    }

    /// A snapshot retires only copied owners in its own namespace. A paired
    /// Mac's workspace that arrives through another Mac's relay, before that
    /// Mac holds any grant here, stays live and raises no registry error.
    @Test func aSnapshotNeverRetiresAPeerWorkspaceLearnedBeforeItsDirectGrant() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("copied-air"), mini = try await mesh.add("copied-mini"), third = try await mesh.add("copied-third")
        try await mesh.pair(air, with: mini); try await mesh.pair(third, with: mini)
        await air.host.peerSync.synchronize(force: true)
        let airID = try await air.host.peerRoute().deviceID
        let airWorkspace = try #require(air.host.executionWorkspaces.first { $0.ownerDeviceID == airID && $0.kind == .mac })
        // The Air goes quiet, so it never obtains a grant at the third Mac.
        air.host.stopSharing()
        await mini.host.peerSync.synchronize(force: true)
        third.host.stopSharing()
        let thirdDB = try #require(third.model.dashboardStore?.database)
        let learned = try #require(try await thirdDB.libraryExecutionWorkspaces().first { $0.id == airWorkspace.id })
        let thirdAuth = try await third.host.peerAuthentication()
        #expect(await thirdAuth.isActiveMac(airID))
        #expect(!(await thirdAuth.devices().map(\.id)).contains(airID))
        third.host.retiresCopiedExecutionOwners = true
        try await third.host.refreshExecutionRegistry()
        let after = try #require(try await thirdDB.libraryExecutionWorkspaces().first { $0.id == airWorkspace.id })
        #expect(after.retainedHistory != true && after.endpoint == learned.endpoint && after.libraryID == airWorkspace.libraryID)
    }

    /// After a restart with the signing key unavailable, an unpair fails
    /// visibly and changes nothing; once the key loads again, a retry records a
    /// signed event that a paired Mac accepts.
    @Test func anUnpairWithoutItsSigningKeyFailsVisiblyAndASignedRetryReachesPeers() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("sign-air"), mini = try await mesh.add("sign-mini")
        try await mesh.pair(air, with: mini)
        let airID = try await air.host.peerRoute().deviceID
        let airAuth = try await air.host.peerAuthentication()
        let phoneID = UUID().uuidString.lowercased()
        let phone = try await airAuth.pair(.init(token: try await airAuth.createOffer(endpoint: air.host.peerRoute().endpoint).payload.token,
            deviceID: phoneID, deviceName: "Phone", metadata: .init(kind: .iPhone)), workspaceID: air.host.peerRoute().libraryID)
        // The Air restarts and its Keychain refuses the signing key.
        var keychainAvailable = false
        let load = air.storage.loadSigningKey
        air.storage.loadSigningKey = {
            guard keychainAvailable else { throw NSError(domain: NSOSStatusErrorDomain, code: -25308) }
            return try load()
        }
        air.host.stopSharing()
        air.host = air.makeHost()
        await air.host.revoke(phoneID)
        #expect(air.host.errorMessage?.contains("pairing key is unavailable") == true)
        let restarted = try await air.host.peerAuthentication()
        #expect(try await restarted.authenticate(bearer: phone.credential).id == phoneID)
        #expect(await restarted.revocationContext(for: phoneID).isEmpty)
        // The key is available again: the retry is a signed unpair.
        keychainAvailable = true
        await air.host.revoke(phoneID)
        #expect(air.host.errorMessage == nil)
        await #expect(throws: LibraryAPIError.self) { try await restarted.authenticate(bearer: phone.credential) }
        let event = try #require(await restarted.peerMembership().revocations.first { $0.deviceID == phoneID })
        #expect(event.revokerDeviceID == airID && event.signature.count == 64)
        let miniAuth = try await mini.host.peerAuthentication()
        try await miniAuth.mergeMembership(restarted.peerMembership(), own: mini.host.peerSync.identity())
        #expect(await miniAuth.revocationContext(for: phoneID) == [event.eventID])
    }

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
        let recovered = try await database.librarySnapshot().notes
        #expect(recovered.contains { $0.content == content })
        #expect(recovered.contains { $0.title.hasPrefix("Unsent message") })
        #expect(try await database.libraryIdentity().hostDeviceID == original.deviceID)
        #expect(await replica.snapshot().outbox == original.outbox)
        try await LegacyMacLibraryUpgrade.prepare(database: database, defaults: fixture.defaults)
        #expect(try await database.librarySnapshot().notes.count == recovered.count)
    }

    @Test func peerHistoryIsLocalButNativeControlStaysWithItsMac() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("history-air"), mini = try await mesh.add("history-mini")
        let source = try #require(air.model.dashboardStore?.database), other = try #require(mini.model.dashboardStore?.database)
        let id = try await source.createFixtureLocalACPSession(runtimeKind: .codex, title: "Owner's conversation", ownerDeviceID: UUID())
        let run = try await source.beginLocalACPRun(conversationID: id, input: .init(text: "Saved native input"))
        try await source.completeLocalACPRun(runID: run.runID, error: nil)
        let originalCount = try await source.read { try $0.historyRowsUnlocked("SELECT id FROM workspace_history_events WHERE conversation_id=?", values: [id]).count }
        try await mesh.pair(air, with: mini)
        await air.host.peerSync.synchronize(force: true)
        #expect(air.host.peerSync.errors.isEmpty)
        #expect(try await other.libraryExecutionOwner(conversationID: id) != nil)
        #expect(try await source.libraryExecutionOwner(conversationID: id) == nil)
        #expect(try await other.libraryFederatedTranscript(conversationID: id)?.messages.contains { $0.content == "Saved native input" } == true)
        #expect(try await other.read { try $0.historyRowsUnlocked("SELECT conversation_id FROM desktop_local_acp_sessions WHERE conversation_id=?", values: [id]).isEmpty })
        #expect(try await other.read { try $0.historyRowsUnlocked("SELECT id FROM workspace_history_events WHERE conversation_id=?", values: [id]).count } == originalCount)
        let sourceAgent = try #require(try await source.dashboardAgents().first)
        #expect(mini.model.peerAgentWorkspaces[sourceAgent.id] != nil)
        #expect(!mini.model.localCLIAgents.contains { $0.id == sourceAgent.id })
        #expect(mini.model.remoteWorkspaceAgents.contains { $0.id == sourceAgent.id })
        let workspace = try #require(try await other.libraryConversationExecutionWorkspace(conversationID: id))
        let own = try await mini.host.peerRoute()
        let credential = try await mini.host.provisionCentralExecutionWorkspace(id: workspace.id)
        #expect(credential.deviceID == own.deviceID && credential.workspace.libraryID == workspace.libraryID)
        await mini.host.peerSync.synchronize(force: true)
        #expect(try await source.libraryExecutionOwner(conversationID: id) == nil)
    }
}


extension LibraryHostLifecycleTests {
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


extension LibraryHostLifecycleTests {
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
        // One turn walks at most eight manifest pages; later exchanges (forced
        // here, change-driven or presence in production) continue from the cursor.
        let database = try #require(mini.model.dashboardStore?.database)
        let peer = try await air.host.peerRoute()
        for _ in 0..<4 {
            await mini.host.peerSync.synchronize(force: true)
            if try await database.pairedLibraryFileCursor(peer.deviceID) == "" { break }
        }
        #expect(mini.host.peerSync.errors.isEmpty)
        #expect(try await database.pairedLibraryFileCursor(peer.deviceID) == "")
        for item in contents.suffix(10) {
            #expect(try Data(contentsOf: mini.directory.appending(path: "library-files/" + item.0)) == item.1)
        }
    }
}

/// The retired node's original approved Mac, reached only through this fixture.
private final class LegacyCentralTransport: LibraryTransport, @unchecked Sendable {
    let database: WorkspaceDatabase
    var operations: [String] = []
    var results: [String] = []
    init(_ database: WorkspaceDatabase) { self.database = database }
    func mutate(_ mutation: LibraryMutation) async throws -> LibraryMutationResult {
        operations.append(mutation.operationID)
        let result = try await database.applyLibraryMutation(mutation)
        results.append("\(mutation.kind):\(result.status):\(result.message ?? "")")
        return result
    }
    func workspaceIdentity() async throws -> String { throw MobileConnectionError.offline }
    func snapshot() async throws -> LibrarySnapshot { throw MobileConnectionError.offline }
    func changes(after: Int64) async throws -> LibraryChangePage { throw MobileConnectionError.offline }
    func note(_ id: String) async throws -> LibraryNote { throw MobileConnectionError.offline }
    func providers() async throws -> [HarnessCapabilities] { throw MobileConnectionError.offline }
    func pending() async throws -> [PendingInteraction] { throw MobileConnectionError.offline }
    func transcript(_ id: String) async throws -> LibraryTranscript { throw MobileConnectionError.offline }
    func command(_ command: LibraryCommand) async throws -> LibraryCommandReceipt { throw MobileConnectionError.offline }
    func receipt(_ id: String) async throws -> LibraryCommandReceipt? { throw MobileConnectionError.offline }
}

extension LibraryHostLifecycleTests {
    @Test func unavailablePairedCredentialsNeverStopPhoneAndLibraryService() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        fixture.storage.loadCredentials = { throw NSError(domain: NSOSStatusErrorDomain, code: -25308) }
        await fixture.host.start()
        #expect(fixture.host.endpoint != nil)
        #expect(fixture.host.peerSync.errors["credentials"] != nil)
    }

    @Test func formerNodeWritingIsReconciledAtItsOriginalMacWithOriginalOperations() async throws {
        let fixture = try await HostFixture(isNode: true); defer { fixture.remove() }
        let centralPersistence = try PersistenceFixture(); defer { centralPersistence.remove() }
        let central = try await centralPersistence.openDatabase()
        let centralHost = try await central.libraryIdentity().hostDeviceID
        let content = { (text: String) in try NoteDocument(blocks: [.richText(.init(text: text))]).encoded() }
        let edited = UUID().uuidString.lowercased(), deleted = UUID().uuidString.lowercased(), folder = UUID().uuidString.lowercased()
        _ = try await central.applyLibraryMutation(.init(deviceID: centralHost, kind: .createNote, resourceID: edited, title: "Plan", content: content("Plan v1")))
        _ = try await central.applyLibraryMutation(.init(deviceID: centralHost, kind: .createNote, resourceID: deleted, title: "Draft", content: content("Draft v1")))
        let created = try await central.applyLibraryMutation(.init(deviceID: centralHost, kind: .createFolder, resourceID: folder, title: "Projects",
            folderExecution: .init(workspaceID: "local", rootPath: centralPersistence.directory.path)))
        #expect(created.status == .accepted)
        // The node cached the central library, then wrote offline.
        let replica = try MobileStore(file: fixture.directory.appending(path: "LibraryClient/library.json"))
        try await replica.bindWorkspace(central.libraryID())
        try await replica.apply(central.librarySnapshot())
        let plan = try #require(await replica.snapshot().notes[edited]), draft = try #require(await replica.snapshot().notes[deleted])
        try await replica.editNote(id: edited, title: "Plan", content: content("Plan edited offline"), folderID: nil, base: plan)
        try await replica.deleteWorkspaceNote(id: deleted, base: draft)
        try await replica.renameFolder(id: folder, name: "Renamed offline")
        let outbox = await replica.snapshot().outbox.map(\.mutation.operationID)
        #expect(outbox.count == 3)
        // Meanwhile the central Mac changed the draft, so deleting it must not apply silently.
        let current = try #require(try await central.libraryNote(id: deleted))
        _ = try await central.applyLibraryMutation(.init(deviceID: centralHost, kind: .updateNote, resourceID: deleted, expectedRevision: current.revision, title: "Draft", content: content("Draft v2")))
        let node = try #require(fixture.model.dashboardStore?.database)
        try await LegacyMacLibraryUpgrade.prepare(database: node, defaults: fixture.defaults)
        let state = await replica.snapshot()
        fixture.storage = .memory(legacy: .init(endpoint: URL(string: "https://central.fixture.ts.net/wovenmatter")!,
            workspaceID: try await central.libraryID(), deviceID: state.deviceID, token: String(repeating: "t", count: 43)))
        fixture.host.peerSync = PairedMacSyncController(host: fixture.host,
            network: PairedMacNetwork(request: { _, _, _, _, _ in throw URLError(.notConnectedToInternet) }), storage: fixture.storage)
        let transport = LegacyCentralTransport(central)
        await #expect(throws: (any Error).self) {
            try await LegacyMacLibraryUpgrade.reconnect(host: fixture.host, defaults: fixture.defaults, makeTransport: { _ in transport })
        }
        // The original approved Mac received the exact original operations.
        #expect(transport.operations == outbox, "\(transport.results)")
        #expect(try await central.libraryNote(id: edited)?.content.contains("Plan edited offline") == true)
        #expect(try await central.librarySnapshot().folders.first { $0.id == folder }?.name == "Renamed offline")
        #expect(try await central.libraryNote(id: deleted)?.content.contains("Draft v2") == true)
        // Nothing was replayed against this Mac's library, and the unapplied
        // deletion is visible rather than silently abandoned.
        #expect(try await node.libraryNote(id: edited) == nil)
        let notes = try await node.librarySnapshot().notes
        #expect(notes.filter { $0.title == "Draft (Deletion not applied before pairing upgrade)" }.count == 1)
        #expect(!fixture.defaults.bool(forKey: LegacyMacLibraryUpgrade.connectedKey))
        // A retry after the lost pairing reply is exact: no duplicate intent.
        await #expect(throws: (any Error).self) {
            try await LegacyMacLibraryUpgrade.reconnect(host: fixture.host, defaults: fixture.defaults, makeTransport: { _ in transport })
        }
        #expect(try await node.librarySnapshot().notes.count == notes.count)
        #expect(try await central.libraryNote(id: edited)?.content.contains("Plan edited offline") == true)
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

extension LibraryHostLifecycleTests {
    @Test func aFormerNodesInterruptedRunAndActiveGoalAreSafeOnTheUpgradeLaunch() async throws {
        let fixture = try await HostFixture(isNode: true); defer { fixture.remove() }
        let database = try #require(fixture.model.dashboardStore?.database)
        let replica = try MobileStore(file: fixture.directory.appending(path: "LibraryClient/library.json"))
        try await replica.bindWorkspace(UUID().uuidString.lowercased())
        let deviceID = await replica.snapshot().deviceID
        let executionDirectory = fixture.directory.appending(path: "LibraryClient/Execution/" + deviceID)
        try FileManager.default.createDirectory(at: executionDirectory, withIntermediateDirectories: true)
        let node = try await WorkspaceDatabase(url: executionDirectory.appending(path: "workspace.sqlite"))
        let session = try await node.createFixtureLocalACPSession(runtimeKind: .codex, title: "Node goal", ownerDeviceID: UUID(),
            fixtureLocation: .init(workspaceID: "local", rootPath: executionDirectory.path, managed: false))
        let goal = try #require(try await node.mutateGoal(sessionID: session, mutation: .set(objective: "Keep going", tokenBudget: nil, turnBudget: nil)))
        let run = try await node.beginLocalACPRun(conversationID: session, input: .init(text: "Interrupted by the upgrade"))
        try await LegacyMacLibraryUpgrade.prepare(database: database, defaults: fixture.defaults)
        // Without a second restart: the imported run is recovered and the goal
        // cannot continue automatically; the chat stays this Mac's own work.
        let status = try await database.read { try $0.historyRowsUnlocked("SELECT status FROM dashboard_runs WHERE id=?", values: [run.runID]).first?.objectValue?["status"]?.stringValue }
        #expect(status != nil && status != "running")
        #expect(try await database.sessionGoals().first { $0.id == goal.id }?.status == .paused)
        #expect(try await database.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await database.read { try $0.locallyOwnsConversationUnlocked(session) })
        // The retained original execution database was not modified.
        #expect(try await node.read { try $0.historyRowsUnlocked("SELECT status FROM dashboard_runs WHERE id=?", values: [run.runID]).first?.objectValue?["status"]?.stringValue } == "running")
    }
}

extension LibraryHostLifecycleTests {
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

extension LibraryHostLifecycleTests {
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

    func requests(_ workspace: ExecutionWorkspace) -> LibraryHostController.RemoteExecutionRequests {
        .init(issue: { [self] _, deviceID in
            if suspendNextIssue {
                suspendNextIssue = false
                await withCheckedContinuation { gate = $0; suspended = true }
            }
            if failNextIssue { failNextIssue = false; throw URLError(.notConnectedToInternet) }
            let token = UUID().uuidString + UUID().uuidString
            tokens[deviceID] = token
            return ExecutionCredential(workspace: workspace, deviceID: deviceID, token: token)
        }, revoke: { [self] _, deviceID in
            tokens.removeValue(forKey: deviceID); removals.append(deviceID)
        })
    }
    func untilSuspended() async throws {
        _ = try await pollUntil(attempts: 2_000, interval: .milliseconds(5)) { suspended }
        try #require(suspended)
    }
    func resume() { suspended = false; gate?.resume(); gate = nil }
}

extension LibraryHostLifecycleTests {
    /// The Air manages a remote workspace; the Mini's phone holds a grant there
    /// delegated through the Air, and the phone has also paired with the Air.
    private func remoteReplacementFixture(_ mesh: PeerTestMesh, _ prefix: String) async throws
        -> (air: HostFixture, miniID: String, workspaceID: String, phoneID: String, direct: PairedDevice, remote: FakeRemoteExecutionWorkspace) {
        let air = try await mesh.add(prefix + "-air"), mini = try await mesh.add(prefix + "-mini")
        try await mesh.pair(air, with: mini)
        await air.host.peerSync.synchronize(force: true)
        let airID = try await air.host.peerRoute().deviceID, miniID = try await mini.host.peerRoute().deviceID
        let database = try #require(air.model.dashboardStore?.database)
        let identity = try await database.libraryIdentity()
        let workspace = try await database.registerExecutionWorkspace(.init(workspace: .init(
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

    /// A phone that had the Air's own grant re-pairs with the Mini without the
    /// Air unpairing it. The Mini still obtains the Air's workspace for it; that
    /// grant now derives from the Mini and ends with the Mini's unpair.
    @Test func aPhoneThatMovedToAnotherMacStillReachesTheFormerMacsWorkspace() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let (air, miniID, workspaceID, phoneID, direct, remote) = try await remoteReplacementFixture(mesh, "moved")
        _ = try await air.host.provisionExecutionWorkspace(id: workspaceID, device: direct)
        #expect(try await air.host.peerAuthentication().delegations(provisionedBy: miniID).isEmpty)
        let moved = try await air.host.provisionDelegatedExecution(id: workspaceID, deviceID: phoneID, name: "Phone", provisionedBy: miniID)
        #expect(remote.tokens[phoneID] == moved.token)
        #expect(try await air.host.peerAuthentication().delegations(provisionedBy: miniID).map(\.workspaceID) == [workspaceID])
        await air.host.revoke(miniID)
        await air.host.retryPendingRevocations()
        #expect(remote.tokens[phoneID] == nil && remote.removals == [phoneID])
    }
}
