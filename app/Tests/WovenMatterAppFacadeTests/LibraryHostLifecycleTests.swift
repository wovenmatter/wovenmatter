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

/// What one mesh Mac's signed execution requests to another did: `cut` makes
/// the other Mac unreachable, as a closed lid would.
private final class MeshExecutionReach: @unchecked Sendable {
    typealias Command = @Sendable (LibraryCommand) async throws -> Void
    private let lock = NSLock()
    private var _cut = false, _requests = 0, _lostCommandReplies = 0
    private var _beforeRequest: (@Sendable () async -> Void)?, _command: Command?
    var cut: Bool { get { lock.withLock { _cut } } set { lock.withLock { _cut = newValue } } }
    var requests: Int { lock.withLock { _requests } }
    private var _log: [String] = []
    /// Every request that left, as "METHOD path".
    var log: [String] { lock.withLock { _log } }
    func count(_ request: URLRequest) {
        lock.withLock { _requests += 1; _log.append((request.httpMethod ?? "GET") + " " + (request.url?.path ?? "")) }
    }
    /// This many of the next commands run on the other Mac and their answers never arrive.
    var lostCommandReplies: Int { get { lock.withLock { _lostCommandReplies } } set { lock.withLock { _lostCommandReplies = newValue } } }
    func loseCommandReply() -> Bool {
        lock.withLock { guard _lostCommandReplies > 0 else { return false }; _lostCommandReplies -= 1; return true }
    }
    /// Runs once, before the next request of any kind leaves.
    var beforeNextRequest: (@Sendable () async -> Void)? {
        get { lock.withLock { _beforeRequest } } set { lock.withLock { _beforeRequest = newValue } }
    }
    func takeBeforeRequest() -> (@Sendable () async -> Void)? { lock.withLock { defer { _beforeRequest = nil }; return _beforeRequest } }
    /// Stands in, once, for the other Mac's handling of the next command.
    var nextCommand: Command? { get { lock.withLock { _command } } set { lock.withLock { _command = newValue } } }
    func takeCommand() -> Command? { lock.withLock { defer { _command = nil }; return _command } }
}

/// Folders on another Mac (docs/architecture/WOVEN_EVERYWHERE.md, "Folder
/// owners"): the owning Mac creates the directory and its own rows from a
/// signed command, and the requesting Mac receives them by library sync.
extension LibraryHostLifecycleTests {
    /// Two paired Macs with their own workspace roots. Each one's signed
    /// execution requests cross the other's loopback listener and production
    /// routing, and peer sync runs between them as it does in the app.
    private func folderMesh(_ prefix: String) async throws -> (mesh: PeerTestMesh, air: HostFixture, mini: HostFixture, reach: MeshExecutionReach) {
        let mesh = PeerTestMesh()
        let air = try await mesh.add(prefix + "-air"), mini = try await mesh.add(prefix + "-mini")
        try await mesh.pair(air, with: mini)
        for _ in 0..<2 { for fixture in [air, mini] { await fixture.host.peerSync.synchronize(force: true) } }
        let listeners = try Dictionary(uniqueKeysWithValues: [air, mini].map { ($0.dnsName, try $0.loopbackURL(path: "")) })
        let reach = MeshExecutionReach()
        let send: MemberSignedHTTPClient.Send = { request in
            guard !reach.cut else { throw URLError(.notConnectedToInternet) }
            reach.count(request)
            await reach.takeBeforeRequest()?()
            let url = try #require(request.url), listener = try #require(listeners[url.host() ?? ""])
            let isCommand = request.httpMethod == "POST" && url.path.hasSuffix("/v1/execution/commands")
            if isCommand, let command = reach.takeCommand() {
                try await command(JSONDecoder().decode(LibraryCommand.self, from: try #require(request.httpBody)))
            }
            var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            components.scheme = listener.scheme; components.host = listener.host(); components.port = listener.port
            components.percentEncodedPath = MemberRequestSignature.canonicalTarget(components.percentEncodedPath)
            var local = request
            local.url = components.url
            let (data, response) = try await URLSession.shared.data(for: local)
            if isCommand, reach.loseCommandReply() { throw URLError(.networkConnectionLost) }
            return (data, try #require(response as? HTTPURLResponse))
        }
        for fixture in [air, mini] {
            try await fixture.model.configureFacadeFixture(directory: fixture.directory)
            fixture.model.libraryHost = fixture.host
            let signer = try await fixture.host.memberSigner(), members = try await fixture.host.peerSync.members()
            fixture.model.federatedExecutionClient = try MemberExecutionClient(database: try #require(fixture.model.libraryStore?.database),
                commandJournalURL: fixture.directory.appending(path: "folder-commands.json"),
                makeSignedTransport: { workspace in
                    guard let audience = await members.audience(for: workspace) else { return nil }
                    return try SignedExecutionWorkspaceTransport(workspace: workspace, signer: signer, audience: audience, send: send)
                })
        }
        return (mesh, air, mini, reach)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    @Test func aFolderForAnotherMacIsMadeByThatMacAndArrivesHereBySync() async throws {
        let (mesh, air, mini, reach) = try await folderMesh("folder"); defer { mesh.remove() }
        let airDB = try #require(air.model.libraryStore?.database), miniDB = try #require(mini.model.libraryStore?.database)
        let airOwner = try await air.model.executionWorkspaceIdentity(workspaceID: nil)
        let miniOwner = try await mini.model.executionWorkspaceIdentity(workspaceID: nil)
        let miniID = try await mini.host.peerRoute().deviceID
        let registry = try await airDB.libraryExecutionWorkspaces().filter { $0.kind == .mac }
        let row = try #require(registry.first { $0.ownerDeviceID == miniID }), own = try #require(registry.first { $0.ownerDeviceID != miniID })
        #expect(row.capabilities.contains(LibraryWorkspaceAction.createFolderCapability) && row.folderOwnerID == miniOwner)

        let id = try #require(await air.model.createFolder(name: " Field notes ", onWorkspace: row.id), "\(air.model.folderMutationError ?? "")")
        // The directory is the Mini's, in its managed root, with the Mini's own rows under the requested ID.
        let root = mini.directory.appendingPathComponent("Field notes", isDirectory: true)
        #expect(isDirectory(root))
        let made = try #require(try await miniDB.folderExecutionLocation(id: id))
        #expect(made == .init(workspaceID: miniOwner, rootPath: root.path, managed: true))
        #expect(try await miniDB.workspaceOverview().folders.first { $0.id == id }?.name == "Field notes")
        // It is already here when the call returns, bound to the Mini and never to this Mac, whose disk is untouched.
        #expect(try await airDB.folderExecutionLocation(id: id) == made)
        #expect(made.workspaceID != airOwner)
        #expect(try await shows(air) { $0.id == id && $0.name == "Field notes" && $0.executionWorkspaceID == miniOwner })
        #expect(!FileManager.default.fileExists(atPath: air.directory.appending(path: "Field notes").path))
        // This Mac asked the Mini for an exchange rather than waiting for its announcement.
        let sync = try #require(air.host.peerSync.librarySync)
        var asked = 0
        for _ in 0..<50 where asked == 0 {
            asked = await sync.exchanges["request"] ?? 0
            if asked == 0 { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(asked >= 1)

        // The same command again replays the Mini's receipt, on the Mini and
        // from here; the same folder under another command is still one folder.
        let client = try air.model.memberExecutionClient(), airDevice = try await airDB.libraryIdentity().hostDeviceID
        func command(_ action: LibraryWorkspaceAction, id: String = UUID().uuidString.lowercased()) -> LibraryCommand {
            .init(commandID: id, deviceID: airDevice, kind: .workspace, workspaceAction: action, libraryID: row.libraryID, workspaceID: row.id)
        }
        let first = command(.createFolder(id: id, name: "Field notes"), id: id)
        #expect(try await mini.model.libraryCommands.execute(first, deviceID: airDevice).status == .completed)
        #expect(try await client.submit(first, workspace: row).status == .completed)
        #expect(try await client.submit(command(.createFolder(id: id, name: "Field notes")), workspace: row).status == .completed)
        #expect(try await miniDB.workspaceOverview().folders.filter { $0.name == "Field notes" }.map(\.id) == [id])

        // The Mini applies the rules of a local "Create New", in the same words.
        #expect(await air.model.createFolder(name: "scratch", onWorkspace: row.id) == nil)
        #expect(air.model.folderMutationError == LocalACPWorkspaceError.invalidProjectName.localizedDescription)
        #expect(await mini.model.createFolder(name: "scratch") == nil)
        #expect(mini.model.folderMutationError == air.model.folderMutationError)
        #expect(await air.model.createFolder(name: "Field notes", onWorkspace: row.id) == nil)
        #expect(air.model.folderMutationError == LocalACPWorkspaceError.projectAlreadyExists.localizedDescription)
        #expect(try await miniDB.workspaceOverview().folders.count == 1)
        // An ID that is not a lowercase UUID is refused before anything is made.
        for malformed in ["not-a-uuid", UUID().uuidString] {
            await #expect(throws: LibraryAPIError.self) { _ = try await client.submit(command(.createFolder(id: malformed, name: "Malformed")), workspace: row) }
        }
        #expect(!FileManager.default.fileExists(atPath: mini.directory.appending(path: "Malformed").path))
        // Library data still never crosses as a command.
        await #expect(throws: (any Error).self) { _ = try await client.submit(command(.retryLibrary(id: id)), workspace: row) }
        await #expect(throws: (any Error).self) {
            _ = try await client.submit(command(.note(id: id, action: "trash", revision: "1", title: nil, folderID: nil)), workspace: row)
        }

        // This Mac's own row is the local path: no request leaves it.
        let sent = reach.requests
        let mine = try #require(await air.model.createFolder(name: "Mine", onWorkspace: own.id), "\(air.model.folderMutationError ?? "")")
        #expect(try await airDB.folderExecutionLocation(id: mine)?.workspaceID == airOwner)
        #expect(isDirectory(air.directory.appending(path: "Mine")))
        #expect(reach.requests == sent)

        // A phone's host route (`POST /v1/commands`) runs the action on the Mac it reaches, never elsewhere.
        let phone = UUID().uuidString.lowercased(), phoneFolder = UUID().uuidString.lowercased()
        let viaPhone = LibraryCommand(commandID: phoneFolder, deviceID: phone, kind: .workspace, workspaceAction: .createFolder(id: phoneFolder, name: "From the phone"))
        #expect(try await mini.model.libraryCommands.execute(viaPhone, deviceID: phone).status == .completed)
        #expect(try await miniDB.folderExecutionLocation(id: phoneFolder)?.workspaceID == miniOwner)
        #expect(isDirectory(mini.directory.appending(path: "From the phone")))

        // A window asks the background server, which sends the Mini the same
        // request and answers with the folder or with the Mini's refusal.
        let backend = BackendApplicationService(model: air.model)
        func fromWindow(_ name: String) async throws -> BackendRPCResponse {
            await backend.handle(.init(method: "application.command", payload: try JSONEncoder().encode(
                BackendApplicationCommand.workspaceMutation(.createFolderOnWorkspace(name: name, registryID: row.id)))))
        }
        let windowReply = try #require(try await fromWindow("From a window").result)
        let windowFolder = try #require(try JSONDecoder().decode(BackendApplicationResult.self, from: windowReply).entityID)
        let windowRoot = mini.directory.appendingPathComponent("From a window", isDirectory: true)
        #expect(try await miniDB.folderExecutionLocation(id: windowFolder) == .init(workspaceID: miniOwner, rootPath: windowRoot.path, managed: true))
        #expect(try await airDB.folderExecutionLocation(id: windowFolder)?.workspaceID == miniOwner)
        #expect(try await fromWindow("From a window").error?.contains(LocalACPWorkspaceError.projectAlreadyExists.localizedDescription) == true)

        // This Mac records nothing of the folder itself. With library sync to
        // the Mini down the request still crosses and the Mini makes the
        // folder, but no row of it is here until an exchange brings the Mini's.
        let miniEndpoint = try await mini.host.peerRoute().endpoint.absoluteString
        mesh.offline.insert(miniEndpoint)
        let pending = try #require(await air.model.createFolder(name: "On its way", onWorkspace: row.id), "\(air.model.folderMutationError ?? "")")
        let theirs = try #require(try await miniDB.folderExecutionLocation(id: pending))
        #expect(theirs.workspaceID == miniOwner)
        #expect(try await airDB.folderName(id: pending) == nil)
        #expect(air.model.workspaceOverview?.folders.contains { $0.id == pending } == false)
        mesh.offline.remove(miniEndpoint)
        #expect(try await folder(pending, reaches: air) == theirs)
    }

    /// Synchronizes until `fixture`'s library holds the folder, and returns where it is bound.
    private func folder(_ id: String, reaches fixture: HostFixture) async throws -> WorkspaceFolderLocation? {
        let database = try #require(fixture.model.libraryStore?.database)
        for _ in 0..<100 {
            await fixture.host.peerSync.synchronize(force: true)
            if let location = try await database.folderExecutionLocation(id: id) { return location }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Whether the model shows a folder. The rows are in the library when a
    /// request returns; the model's own refresh can be superseded by the one
    /// library sync starts for the same rows, which lands a moment later.
    private func shows(_ fixture: HostFixture, _ matches: (WorkspaceFolderRecord) -> Bool) async throws -> Bool {
        for _ in 0..<50 {
            if fixture.model.workspaceOverview?.folders.contains(where: matches) == true { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// The IDs this Mac requested for a folder name, from its command journal.
    private func requestedFolders(_ name: String, by fixture: HostFixture) async throws -> Set<String> {
        let journal = try WorkspaceJournal(file: fixture.directory.appending(path: "folder-commands.json"))
        return Set(await journal.snapshot().commands.values.compactMap { record -> String? in
            guard case .createFolder(let folder, name)? = record.command.workspaceAction else { return nil }
            return folder
        })
    }

    /// With the other Mac unreachable nothing is created anywhere and the
    /// failure is reported; asking again once it is back is the same request,
    /// so the folder exists once.
    @Test func aFolderRequestToAnUnreachableMacFailsAndItsRetryMakesOneFolder() async throws {
        let (mesh, air, mini, reach) = try await folderMesh("retry"); defer { mesh.remove() }
        let airDB = try #require(air.model.libraryStore?.database), miniDB = try #require(mini.model.libraryStore?.database)
        let miniID = try await mini.host.peerRoute().deviceID
        let row = try #require(try await airDB.libraryExecutionWorkspaces().first { $0.kind == .mac && $0.ownerDeviceID == miniID })
        reach.cut = true
        #expect(await air.model.createFolder(name: "Later", onWorkspace: row.id) == nil)
        #expect(air.model.folderMutationError?.isEmpty == false)
        #expect(try await miniDB.workspaceOverview().folders.isEmpty)
        #expect(try await airDB.workspaceOverview().folders.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: mini.directory.appending(path: "Later").path))
        #expect(!FileManager.default.fileExists(atPath: air.directory.appending(path: "Later").path))

        reach.cut = false
        let id = try #require(await air.model.createFolder(name: "Later", onWorkspace: row.id), "\(air.model.folderMutationError ?? "")")
        #expect(try await requestedFolders("Later", by: air) == [id])
        #expect(try await miniDB.workspaceOverview().folders.map(\.id) == [id])
        #expect(try await airDB.folderExecutionLocation(id: id)?.workspaceID == mini.model.executionWorkspaceIdentity(workspaceID: nil))
    }

    /// The request reaches the other Mac, which makes the folder, and only its
    /// answer is lost. Asking again is that request: the owner replays its
    /// receipt, and there is one folder, under the first ID.
    @Test func aFolderRequestWhoseAnswerWasLostIsTheSameRequestWhenAskedAgain() async throws {
        let (mesh, air, mini, reach) = try await folderMesh("lost"); defer { mesh.remove() }
        let airDB = try #require(air.model.libraryStore?.database), miniDB = try #require(mini.model.libraryStore?.database)
        let route = try await mini.host.peerRoute(), endpoint = route.endpoint.absoluteString
        let row = try #require(try await airDB.libraryExecutionWorkspaces().first { $0.kind == .mac && $0.ownerDeviceID == route.deviceID })
        // The connection drops for everything: the answer is lost and no library sync brings the folder either.
        mesh.offline.insert(endpoint)
        reach.lostCommandReplies = 1
        #expect(await air.model.createFolder(name: "Lost", onWorkspace: row.id) == nil)
        #expect(air.model.folderMutationError?.isEmpty == false)
        let made = try await miniDB.workspaceOverview().folders
        #expect(made.map(\.name) == ["Lost"], "the Mini ran the request")
        #expect(isDirectory(mini.directory.appending(path: "Lost")))
        #expect(try await airDB.workspaceOverview().folders.isEmpty)

        // The Mini is back when the retry leaves this Mac.
        reach.beforeNextRequest = { await MainActor.run { _ = mesh.offline.remove(endpoint) } }
        let id = try #require(await air.model.createFolder(name: "Lost", onWorkspace: row.id), "\(air.model.folderMutationError ?? "")")
        #expect(made.map(\.id) == [id])
        #expect(try await requestedFolders("Lost", by: air) == [id])
        #expect(try await miniDB.workspaceOverview().folders.map(\.id) == [id])
        let theirs = try await miniDB.folderExecutionLocation(id: id)
        #expect(try await airDB.folderExecutionLocation(id: id) == theirs)
        #expect(try await shows(air) { $0.id == id && $0.name == "Lost" })
    }

    /// Once the folder of a request whose answer was lost is here, asking for
    /// its name again asks for a second folder: it goes out under a new ID and
    /// the owner refuses the taken name, rather than replaying an old success.
    @Test func aFolderThatArrivedAfterALostAnswerIsNotAskedForAgainUnderItsID() async throws {
        let (mesh, air, mini, reach) = try await folderMesh("kept"); defer { mesh.remove() }
        let airDB = try #require(air.model.libraryStore?.database), miniDB = try #require(mini.model.libraryStore?.database)
        let miniID = try await mini.host.peerRoute().deviceID
        let row = try #require(try await airDB.libraryExecutionWorkspaces().first { $0.kind == .mac && $0.ownerDeviceID == miniID })
        reach.lostCommandReplies = 1
        #expect(await air.model.createFolder(name: "Kept", onWorkspace: row.id) == nil)
        let first = try #require(try await miniDB.workspaceOverview().folders.first { $0.name == "Kept" }?.id)
        #expect(try await folder(first, reaches: air) != nil)

        #expect(await air.model.createFolder(name: "Kept", onWorkspace: row.id) == nil)
        #expect(air.model.folderMutationError == LocalACPWorkspaceError.projectAlreadyExists.localizedDescription)
        let requested = try await requestedFolders("Kept", by: air)
        #expect(requested.count == 2 && requested.contains(first))
        #expect(try await miniDB.workspaceOverview().folders.map(\.id) == [first])
        #expect(try await airDB.workspaceOverview().folders.map(\.id) == [first])
    }

    /// The folder of a request whose answer was lost arrived and was removed
    /// since. Its ID is not that folder any more: asked again, the owner would
    /// replay "done" and create nothing, so the request goes out as a new one
    /// and the folder really exists afterwards.
    @Test func aFolderRemovedSinceALostAnswerIsCreatedAgainUnderANewID() async throws {
        let (mesh, air, mini, reach) = try await folderMesh("gone"); defer { mesh.remove() }
        let airDB = try #require(air.model.libraryStore?.database), miniDB = try #require(mini.model.libraryStore?.database)
        let miniID = try await mini.host.peerRoute().deviceID
        let row = try #require(try await airDB.libraryExecutionWorkspaces().first { $0.kind == .mac && $0.ownerDeviceID == miniID })
        /// A request whose answer is lost, its folder arriving by sync, then the
        /// folder and its directory removed on the Mini and gone from here too.
        func lostThenRemoved(_ name: String) async throws -> String {
            reach.lostCommandReplies = 1
            #expect(await air.model.createFolder(name: name, onWorkspace: row.id) == nil)
            let id = try #require(try await miniDB.workspaceOverview().folders.first { $0.name == name }?.id)
            #expect(try await folder(id, reaches: air) != nil)
            try FileManager.default.removeItem(at: mini.directory.appending(path: name))
            #expect(await mini.model.deleteFolder(id: id))
            for _ in 0..<100 {
                for fixture in [mini, air] { await fixture.host.peerSync.synchronize(force: true) }
                if try await airDB.folderName(id: id) == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(try await airDB.folderName(id: id) == nil)
            return id
        }
        func receiptRequests(_ id: String) -> Int { reach.log.filter { $0.hasPrefix("GET ") && $0.hasSuffix("/v1/execution/commands/" + id) }.count }

        // Soon after: the old ID is asked once more, the Mini answers it as
        // done, no folder arrives for it, and a new request makes the folder.
        let first = try await lostThenRemoved("Gone")
        let asked = receiptRequests(first)
        let second = try #require(await air.model.createFolder(name: "Gone", onWorkspace: row.id), "\(air.model.folderMutationError ?? "")")
        #expect(second != first && receiptRequests(first) == asked + 1)
        #expect(isDirectory(mini.directory.appending(path: "Gone")))
        #expect(try await miniDB.workspaceOverview().folders.map(\.id) == [second])
        let theirs = try #require(try await miniDB.folderExecutionLocation(id: second))
        #expect(try await airDB.folderExecutionLocation(id: second) == theirs)
        #expect(try await requestedFolders("Gone", by: air) == [first, second])

        // Past the retry window the old ID is not asked about at all.
        let old = try await lostThenRemoved("Much later")
        let before = receiptRequests(old)
        try air.model.memberExecutionClient().folderRetryWindow = .zero
        let new = try #require(await air.model.createFolder(name: "Much later", onWorkspace: row.id), "\(air.model.folderMutationError ?? "")")
        #expect(new != old && receiptRequests(old) == before)
        #expect(isDirectory(mini.directory.appending(path: "Much later")))
        #expect(try await airDB.folderExecutionLocation(id: new) != nil)
    }

    /// The owner durably accepted a request and quit before running it: it
    /// never runs that ID and answers that its outcome is unknown. That is
    /// said in the folder's terms, and the next request is a new one.
    @Test func aFolderRequestTheOwnerNeverFinishedDoesNotBlockItsName() async throws {
        let (mesh, air, mini, reach) = try await folderMesh("stuck"); defer { mesh.remove() }
        let airDB = try #require(air.model.libraryStore?.database), miniDB = try #require(mini.model.libraryStore?.database)
        let miniID = try await mini.host.peerRoute().deviceID
        let row = try #require(try await airDB.libraryExecutionWorkspaces().first { $0.kind == .mac && $0.ownerDeviceID == miniID })
        reach.nextCommand = { command in
            #expect(try await miniDB.reserveLibraryCommand(command).isNew)
            throw URLError(.networkConnectionLost)
        }
        #expect(await air.model.createFolder(name: "Stuck", onWorkspace: row.id) == nil)
        let unfinished = try await requestedFolders("Stuck", by: air)
        #expect(unfinished.count == 1)

        #expect(await air.model.createFolder(name: "Stuck", onWorkspace: row.id) == nil)
        #expect(air.model.folderMutationError == "\(row.name) stopped before it finished creating “Stuck”. If the folder does not appear, create it again.")
        #expect(try await requestedFolders("Stuck", by: air) == unfinished, "the same request was asked about")
        #expect(try await miniDB.workspaceOverview().folders.isEmpty)

        let id = try #require(await air.model.createFolder(name: "Stuck", onWorkspace: row.id), "\(air.model.folderMutationError ?? "")")
        #expect(!unfinished.contains(id))
        #expect(try await miniDB.workspaceOverview().folders.map(\.id) == [id])
        #expect(isDirectory(mini.directory.appending(path: "Stuck")))
        #expect(try await airDB.folderExecutionLocation(id: id) != nil)
    }
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
            if try await database.peerSyncFileCursor(peer.deviceID) == "" { break }
        }
        #expect(mini.host.peerSync.errors.isEmpty)
        #expect(try await database.peerSyncFileCursor(peer.deviceID) == "")
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

extension LibraryHostLifecycleTests {
    /// Another Mac's agent is listed under that Mac's workspace by its plain
    /// harness name, and never under this Mac, also while its owner record or
    /// its Mac's registry row has not arrived. Either one arriving alone, with
    /// no agent or chat changing, is enough for the views to place it: a
    /// window reads the workspace again only when the change counter moved.
    @Test func anotherMacsAgentIsNeverLocalAndIsPlacedWhenItsOwnerOrRegistryRowArrivesAlone() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("place-air"), mini = try await mesh.add("place-mini")
        let source = try #require(air.model.libraryStore?.database), other = try #require(mini.model.libraryStore?.database)
        _ = try await source.createFixtureLocalACPSession(runtimeKind: .codex, title: "Air's chat", ownerDeviceID: UUID())
        let agent = try #require(try await source.workspaceAgents().first)
        try await mesh.pair(air, with: mini)
        await air.host.peerSync.synchronize(force: true)
        let airID = try await air.host.peerRoute().deviceID, key = agent.id.uuidString.lowercased()
        let workspace = try #require(try await other.libraryExecutionWorkspaces().first { $0.kind == .mac && $0.ownerDeviceID == airID })
        // As a receive applies a row: nothing is recorded to send back.
        func arrive(_ sql: String, _ values: [String]) async throws {
            try await other.write { connection in
                try connection.executeUnlocked("UPDATE peer_sync_clock SET applying=1")
                try connection.toolsExecuteUnlocked(sql, values)
                try connection.executeUnlocked("UPDATE peer_sync_clock SET applying=0")
            }
        }
        // What a window does when its server reports a workspace change.
        func placed(_ expected: Bool) async throws -> Bool {
            try await pollUntil(attempts: 200, interval: .milliseconds(10)) {
                try await mini.model.applyServerScopes([.workspace], reloadAll: false)
                guard !mini.model.localCLIAgents.contains(where: { $0.id == agent.id }) else { return false }
                let listed = mini.model.remoteWorkspaceAgents.first { $0.id == agent.id }
                guard expected else { return listed == nil && mini.model.peerAgentWorkspaces[agent.id] == nil }
                return listed?.executionLocation == .remote && listed?.displayName == AgentRuntimeKind.codex.displayName
                    && listed?.runtimeDeviceID == UUID(uuidString: workspace.id) && mini.model.peerAgentWorkspaces[agent.id]?.id == workspace.id
            }
        }
        await air.model.refreshWorkspace(); await mini.model.refreshWorkspace()
        #expect(air.model.localCLIAgents.contains { $0.id == agent.id } && !air.model.remoteWorkspaceAgents.contains { $0.id == agent.id })
        #expect(try await placed(true))
        #expect(mini.model.remoteWorkspaceAgents.first { $0.id == agent.id }.map(agentDisplayName) == "Codex")

        // Its owner record is not here yet: unknown, so not listed anywhere.
        var revision = try await other.workspaceRevision()
        try await arrive("DELETE FROM agent_owners WHERE id=?", [key])
        #expect(try await placed(false))
        try await arrive("INSERT INTO agent_owners VALUES(?,?)", [key, airID])
        #expect(try await other.workspaceRevision() > revision)
        #expect(try await placed(true))

        // Its Mac's registry row is not here yet.
        let stored = try await other.read { connection in
            try #require(try connection.historyRowsUnlocked("SELECT owner_device_id,revision,deleted,payload FROM execution_workspaces WHERE id=?", values: [workspace.id]).first?.objectValue)
        }
        try await arrive("DELETE FROM execution_workspaces WHERE id=?", [workspace.id])
        #expect(try await placed(false))
        revision = try await other.workspaceRevision()
        try await arrive("INSERT INTO execution_workspaces(id,owner_device_id,revision,deleted,payload) VALUES(?,?,CAST(? AS INTEGER),CAST(? AS INTEGER),?)",
            [workspace.id, try #require(stored["owner_device_id"]?.stringValue), String(try #require(stored["revision"]?.intValue)),
             String(try #require(stored["deleted"]?.intValue)), try #require(stored["payload"]?.stringValue)])
        #expect(try await other.workspaceRevision() > revision)
        #expect(try await placed(true))
        #expect(!mini.model.localCLIAgents.contains { $0.ownerDeviceID == agent.ownerDeviceID })
    }

    /// Any Mac names any workspace. The name reaches every Mac, the owner
    /// publishes it as its registry name for devices that only read the
    /// registry, and clearing it returns the default: a Mac's tailnet name.
    @Test func aWorkspaceNameChosenOnAnotherMacSynchronizesAndItsOwnerPublishesIt() async throws {
        let mesh = PeerTestMesh(); defer { mesh.remove() }
        let air = try await mesh.add("names-air"), mini = try await mesh.add("names-mini")
        try await mesh.pair(air, with: mini)
        await air.host.peerSync.synchronize(force: true)
        let airDB = try #require(air.model.libraryStore?.database), miniDB = try #require(mini.model.libraryStore?.database)
        let airID = try await air.host.peerRoute().deviceID
        func row(_ database: WorkspaceDatabase) async throws -> ExecutionWorkspace {
            try #require(try await database.libraryExecutionWorkspaces().first { $0.kind == .mac && $0.ownerDeviceID == airID })
        }
        let original = try await row(miniDB)
        await mini.model.refreshWorkspace()
        #expect(original.name == DevelopmentLaunch.deviceName() && mini.model.workspaceDisplayName(original) == "names-air")

        #expect(await mini.model.renameWorkspace(registryID: original.id, name: " Studio "))
        #expect(mini.model.workspaceNameOverrides == [original.id: "Studio"] && mini.model.workspaceDisplayName(original) == "Studio")
        // Only the owner writes its registry row.
        #expect(try await row(miniDB) == original)
        await mini.host.peerSync.synchronize(force: true)
        #expect(try await airDB.executionWorkspaceNames() == [original.id: "Studio"])
        try await air.host.refreshExecutionRegistry()
        let published = try await row(airDB)
        #expect(published.name == "Studio" && published.revision == original.revision + 1)
        // Refreshing the registry with the same name writes nothing.
        let head = try await airDB.peerSyncHead(), revision = try await airDB.workspaceRevision()
        for _ in 0..<3 { try await air.host.refreshExecutionRegistry() }
        #expect(try await row(airDB) == published)
        #expect(try await airDB.peerSyncHead() == head)
        #expect(try await airDB.workspaceRevision() == revision)
        await air.host.peerSync.synchronize(force: true)
        #expect(try await row(miniDB).name == "Studio")

        // Cleared on the owner: its row and every Mac return to the default.
        #expect(await air.model.renameWorkspace(registryID: original.id, name: nil))
        try await air.host.refreshExecutionRegistry()
        let cleared = try await row(airDB)
        #expect(cleared.name == DevelopmentLaunch.deviceName() && cleared.revision == published.revision + 1)
        await air.host.peerSync.synchronize(force: true)
        await mini.model.refreshWorkspace()
        #expect(mini.model.workspaceNameOverrides.isEmpty)
        let restored = try await row(miniDB)
        #expect(mini.model.workspaceDisplayName(restored) == "names-air" && restored.name == DevelopmentLaunch.deviceName())
        #expect(air.host.peerSync.errors.isEmpty && mini.host.peerSync.errors.isEmpty)

        // A name the registry would refuse is refused, and reported like a folder rename.
        #expect(await mini.model.renameWorkspace(registryID: original.id, name: String(repeating: "n", count: 257)) == false)
        #expect(mini.model.folderMutationError != nil && mini.model.workspaceNameOverrides.isEmpty)
    }
}

