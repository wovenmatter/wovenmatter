import CryptoKit
import Foundation
import Testing
import WovenMatterClient
import LibraryClient
import WorkspaceFixtures
import WovenMatterCore
import WovenMatterShared
@testable import WovenMatterLibraryStore
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


    /// A phone unpairs itself with its signed member request: this Mac
    /// removes it from the library as Apple Devices does (a signed unpair and
    /// a member removal both reach the other members). A Mac cannot.
    @Test func aPhoneMembersSignedUnpairRemovesItFromTheLibrary() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        await fixture.host.startServingLibrary()
        try await waitUntil { fixture.host.endpoint != nil && !fixture.host.isStarting && fixture.host.status == "Available to your paired devices" }
        let members = try await fixture.host.peerSync.members()
        try await members.ensureSelf(name: "Mac", endpoints: [])
        let phone = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .ios, key: .init())
        let mac = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .mac, key: .init())
        _ = try await members.add(deviceID: phone.deviceID, kind: .ios, name: "Phone", publicKey: phone.publicKey, endpoints: [])
        _ = try await members.add(deviceID: mac.deviceID, kind: .mac, name: "Other Mac", publicKey: mac.publicKey, endpoints: [])
        let url = try fixture.loopbackURL(path: "v1/pair/unpair")
        func unpair(_ member: MemberIdentity) async throws -> Int {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(String(LibraryProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
            for (name, value) in try member.signer.headers(method: "POST", target: url.path, body: Data("{}".utf8), audience: members.identity.deviceID) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (_, response) = try await URLSession.shared.data(for: request)
            return try #require((response as? HTTPURLResponse)?.statusCode)
        }
        #expect(try await unpair(mac) == 400)
        #expect(await members.member(mac.deviceID) != nil)
        #expect(try await unpair(phone) == 200)
        #expect(await members.member(phone.deviceID) == nil)
        #expect(try await members.list().members.contains { $0.deviceID == phone.deviceID && $0.revoked })
        #expect(try await !fixture.host.peerAuthentication().revocationContext(for: phone.deviceID).isEmpty)
        // Removed, its signature no longer reaches anything here.
        #expect(try await unpair(phone) == 401)
    }

    @Test func clickPairingHTTPRequiresLocalApprovalAndReturnsAccurateMetadata() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        await fixture.host.startServingLibrary()
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
        #expect(advertisement.identity.metadata.kind == .mac)
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
        let (_, cancelled) = try await post("v1/pairing/cancel", JSONEncoder().encode(PairingPoll(requestID: request.requestID, requestSecret: request.requestSecret)))
        #expect(cancelled == 200)
        #expect(fixture.host.pairedDevices.isEmpty)
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

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "library-host-\(UUID())")
        suite = "library.host.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        let store = try await LibraryStore(supportDirectory: directory)
        model = ApplicationModel(applicationDefaults: defaults, libraryStore: store, startsAutomatically: false)
    }
    /// Local folders are bound to `device:<device id>`, generated apart
    /// from the registry id and host device id. A record an earlier build
    /// published without the folder owner gains it on the next refresh, under
    /// the same workspace id, so existing folders are never rewritten.
    @Test func aMacPublishesTheFolderOwnerItsFoldersUse() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        await fixture.host.start()
        let database = try #require(fixture.model.libraryStore?.database)
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
            return try JSONEncoder().encode(DiscoveryAdvertisement(identity: identity, capabilities: [PairedMacSyncController.capability]))
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
        let response = try await authentication.pairConfirmed(.init(token: offer.payload.token, deviceID: own.deviceID, deviceName: own.name, metadata: .init(kind: .mac),
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
        let airDB = try #require(air.model.libraryStore?.database), thirdDB = try #require(third.model.libraryStore?.database)
        let joiningRoute = try await mini.host.peerRoute()
        mesh.offline.insert(joiningRoute.endpoint.absoluteString)
        let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        let airID = try await air.host.peerRoute().deviceID, thirdID = try await third.host.peerRoute().deviceID
        _ = try await airDB.applyLibraryMutation(.init(deviceID: airID, kind: .createNote, resourceID: first, title: "Air offline", content: try NoteDocument(blocks: [.richText(.init(text: "Air writing"))]).encoded()))
        _ = try await thirdDB.applyLibraryMutation(.init(deviceID: thirdID, kind: .createNote, resourceID: second, title: "Third offline", content: try NoteDocument(blocks: [.richText(.init(text: "Third writing"))]).encoded()))
        let remote = RemoteWorkspaceConfiguration(name: "Added from third Mac", workspaceID: "new-remote", hostName: "linux.fixture.ts.net", kind: .host)
        try await thirdDB.saveRemoteWorkspaceConfigurations([remote])
        let phoneID = UUID().uuidString.lowercased()
        let authentication = try await third.host.peerAuthentication()
        let offer = try await authentication.createOffer(endpoint: third.host.peerRoute().endpoint)
        let phone = try await authentication.pairConfirmed(.init(token: offer.payload.token, deviceID: phoneID, deviceName: "New iPhone", metadata: .init(kind: .iPhone)), workspaceID: thirdDB.libraryID())
        await air.host.peerSync.synchronize(force: true)
        await third.host.peerSync.synchronize(force: true)
        #expect(try await airDB.libraryNote(id: second)?.title == "Third offline")
        #expect(try await thirdDB.libraryNote(id: first)?.title == "Air offline")
        #expect(try await airDB.read { try !$0.historyRowsUnlocked("SELECT 1 FROM remote_workspace_configurations WHERE id=?", values: [remote.id.uuidString.lowercased()]).isEmpty })
        // The new phone is listed for display, but its bearer authenticates
        // only at the Mac it paired with.
        #expect(try await air.host.peerAuthentication().peerMembership().entries.contains { $0.deviceID == phoneID && $0.name == "New iPhone" })
        await #expect(throws: LibraryAPIError.self) { try await air.host.peerAuthentication().authenticate(bearer: phone.credential) }
        #expect(air.host.peerSync.errors.isEmpty && third.host.peerSync.errors.isEmpty)
    }

    @Test func bearersAnotherMacHoldsOrMintedNeverWorkHere() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("revoke-air"), mini = try await mesh.add("revoke-mini"), third = try await mesh.add("revoke-third")
        try await mesh.pair(air, with: mini); try await mesh.pair(third, with: mini)
        for _ in 0..<2 { for fixture in [air, third, mini] { await fixture.host.peerSync.synchronize(force: true) } }
        let miniID = try await mini.host.peerRoute().deviceID
        let miniAuth = try await mini.host.peerAuthentication(), airAuth = try await air.host.peerAuthentication()
        let phone = try await miniAuth.pairConfirmed(.init(token: try await miniAuth.createOffer(endpoint: mini.host.peerRoute().endpoint).payload.token,
            deviceID: UUID().uuidString.lowercased(), deviceName: "Phone", metadata: .init(kind: .iPhone)), workspaceID: mini.host.peerRoute().libraryID)
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
        // Membership never carries a bearer.
        await air.host.revoke(miniID)
        let wire = String(decoding: try JSONEncoder().encode(await airAuth.peerMembership()), as: UTF8.self)
        #expect(!wire.contains(phone.credential) && !wire.contains(minted) && !wire.contains(held))
    }
}


extension LibraryHostLifecycleTests {
    private func writeNote(_ fixture: HostFixture, _ id: String, _ title: String) async throws {
        let database = try #require(fixture.model.libraryStore?.database)
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
        let airDB = try #require(air.model.libraryStore?.database), thirdDB = try #require(third.model.libraryStore?.database)
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

    /// An unpair made on this Mac while a file transfer is in progress lets the
    /// request in flight finish but sends no further file request.
    @Test func anUnpairDuringAFileTransferSendsNoFurtherRequest() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("files-air"), mini = try await mesh.add("files-mini")
        try await mesh.pair(air, with: mini)
        await air.host.peerSync.synchronize(force: true)
        let airDB = try #require(air.model.libraryStore?.database), miniDB = try #require(mini.model.libraryStore?.database)
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
        let airDB = try #require(air.model.libraryStore?.database)
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
        let thirdDB = try #require(third.model.libraryStore?.database)
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
        let phone = try await airAuth.pairConfirmed(.init(token: try await airAuth.createOffer(endpoint: air.host.peerRoute().endpoint).payload.token,
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

    @Test func peerHistoryIsLocalButNativeControlStaysWithItsMac() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("history-air"), mini = try await mesh.add("history-mini")
        let source = try #require(air.model.libraryStore?.database), other = try #require(mini.model.libraryStore?.database)
        let id = try await source.createFixtureLocalACPSession(runtimeKind: .codex, title: "Owner's conversation", ownerDeviceID: UUID())
        let run = try await source.beginLocalACPRun(conversationID: id, input: .init(text: "Saved native input"))
        try await source.completeLocalACPRun(runID: run.runID, error: nil)
        let originalCount = try await source.read { try $0.historyRowsUnlocked("SELECT id FROM history_events WHERE conversation_id=?", values: [id]).count }
        try await mesh.pair(air, with: mini)
        await air.host.peerSync.synchronize(force: true)
        #expect(air.host.peerSync.errors.isEmpty)
        #expect(try await other.libraryExecutionOwner(conversationID: id) != nil)
        #expect(try await source.libraryExecutionOwner(conversationID: id) == nil)
        #expect(try await other.libraryFederatedTranscript(conversationID: id)?.messages.contains { $0.content == "Saved native input" } == true)
        #expect(try await other.read { try $0.historyRowsUnlocked("SELECT conversation_id FROM harness_sessions WHERE conversation_id=?", values: [id]).isEmpty })
        #expect(try await other.read { try $0.historyRowsUnlocked("SELECT id FROM history_events WHERE conversation_id=?", values: [id]).count } == originalCount)
        let sourceAgent = try #require(try await source.workspaceAgents().first)
        #expect(mini.model.peerAgentWorkspaces[sourceAgent.id] != nil)
        #expect(!mini.model.localCLIAgents.contains { $0.id == sourceAgent.id })
        #expect(mini.model.remoteWorkspaceAgents.contains { $0.id == sourceAgent.id })
        _ = try #require(try await other.libraryConversationExecutionWorkspace(conversationID: id))
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
        let database = try #require(mini.model.libraryStore?.database)
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

extension LibraryHostLifecycleTests {
    @Test func unavailablePairedCredentialsNeverStopPhoneAndLibraryService() async throws {
        let fixture = try await HostFixture(); defer { fixture.remove() }
        fixture.storage.loadCredentials = { throw NSError(domain: NSOSStatusErrorDomain, code: -25308) }
        await fixture.host.start()
        #expect(fixture.host.endpoint != nil)
        #expect(fixture.host.peerSync.errors["credentials"] != nil)
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
    @Test func anotherMacsChatTrashAndMoveGoToItsOwnerAndNeverApplyLocally() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("route-air"), mini = try await mesh.add("route-mini")
        try await mesh.pair(air, with: mini)
        await air.host.peerSync.synchronize(force: true)
        let airDB = try #require(air.model.libraryStore?.database), miniDB = try #require(mini.model.libraryStore?.database)
        let id = try await airDB.createFixtureLocalACPSession(runtimeKind: .codex, title: "Air's chat", ownerDeviceID: UUID())
        await air.host.peerSync.synchronize(force: true)
        let airID = try await air.host.peerRoute().deviceID
        #expect(try await mini.model.pairedOwnerWorkspace(conversationID: id)?.ownerDeviceID == airID)
        // The owner is unreachable: no transport, so routing fails closed.
        mini.model.federatedExecutionClient = try MemberExecutionClient(database: miniDB,
            commandJournalURL: mini.directory.appending(path: "route-commands.json"),
            makeSignedTransport: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: (any Error).self) { try await mini.model.mutateConversation(id: id, mutation: .moveToTrash) }
        #expect(await mini.model.moveConversation(id: id, toFolderID: nil) == false)
        let deleted = { (database: WorkspaceDatabase) in
            try await database.read { try $0.historyRowsUnlocked("SELECT deleted_at FROM conversations WHERE id=?", values: [id]).first?.objectValue?["deleted_at"]?.stringValue }
        }
        #expect(try await deleted(miniDB) == nil)
        // Rename stays a shared edit the observer may make.
        try await mini.model.mutateConversation(id: id, mutation: .rename("Renamed on the Mini"))
        await mini.host.peerSync.synchronize(force: true)
        #expect(try await deleted(airDB) == nil)
        #expect(try await airDB.read { try $0.historyRowsUnlocked("SELECT title FROM conversations WHERE id=?", values: [id]).first?.objectValue?["title"]?.stringValue } == "Renamed on the Mini")
    }
}

