import AppKit
import CompanionClient
import CryptoKit
import Foundation
import Observation
import Security
import WovenMatterCore
import WovenMatterDashboardStore

struct PairedMacCredential: Codable, Sendable {
    var route: PairedMacRoute
    let deviceID: String
    let token: String
    var returnToken: String?
    var needsJoin: Bool?
    var confirmationPending: Bool?
    /// The exact signed join, persisted before it is sent, so a retry after a
    /// lost reply repeats the identical transcript.
    var join: PairedMacJoin?
    var isCompleted: Bool { needsJoin != true && confirmationPending != true }
}

/// Device-only paired-Mac secrets: Mac grants, pending pairing claims and the
/// retired node's original bearer. Production uses Keychain; fixtures inject
/// memory storage so tests can never reach the user's Keychain.
struct PairedMacDeviceStorage {
    var loadCredentials: @MainActor () throws -> [PairedMacCredential]
    var saveCredentials: @MainActor ([PairedMacCredential]) throws -> Void
    var loadClaim: (String) throws -> CompanionStoredPairingClaim?
    var saveClaim: (CompanionStoredPairingClaim?, String) throws -> Void
    var loadLegacyCredential: @MainActor () throws -> MobileCredential?
    var loadExecutionCredential: @MainActor (String) throws -> DirectWorkspaceCredential?
    var saveExecutionCredential: @MainActor (DirectWorkspaceCredential) throws -> Void
    /// This Mac's device-only Curve25519 signing key (raw representation).
    var loadSigningKey: @MainActor () throws -> Data?
    var saveSigningKey: @MainActor (Data) throws -> Void
    var restoresPairing = true

    /// Production uses Keychain. A test process fails closed to isolated
    /// memory storage even when a fixture forgets to inject its own.
    @MainActor static var standard: Self { isTestProcess ? .memory() : .keychain }
    static var isTestProcess: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestBundlePath"] != nil || environment["XCTestSessionIdentifier"] != nil
            || environment.keys.contains("XCTestConfigurationFilePath")
            || ["xctest", "swiftpm-testing-helper"].contains(ProcessInfo.processInfo.processName)
            || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }
    @MainActor static var keychain: Self {
        .init(loadCredentials: PairedMacCredentialVault.load, saveCredentials: PairedMacCredentialVault.save,
              loadClaim: { try CompanionPendingPairingVault.load(deviceID: $0) },
              saveClaim: { try CompanionPendingPairingVault.save($0, deviceID: $1) },
              loadLegacyCredential: { try MobileCredentialVault.load() },
              loadExecutionCredential: CentralExecutionCredentialVault.load,
              saveExecutionCredential: CentralExecutionCredentialVault.save,
              loadSigningKey: PairedMacCredentialVault.loadSigningKey, saveSigningKey: PairedMacCredentialVault.saveSigningKey)
    }
    /// Isolated storage for fixtures. Nothing is shared with other instances.
    @MainActor static func memory(credentials: [PairedMacCredential] = [], legacy: MobileCredential? = nil) -> Self {
        final class Box: @unchecked Sendable {
            var credentials: [PairedMacCredential] = []; var claims: [String: CompanionStoredPairingClaim] = [:]
            var execution: [String: DirectWorkspaceCredential] = [:]
            var signingKey: Data?
        }
        let box = Box(); box.credentials = credentials
        return .init(loadCredentials: { box.credentials }, saveCredentials: { box.credentials = $0 },
                     loadClaim: { box.claims[$0] }, saveClaim: { claim, id in box.claims[id] = claim },
                     loadLegacyCredential: { legacy },
                     loadExecutionCredential: { box.execution[$0] },
                     saveExecutionCredential: { box.execution[CentralExecutionCredentialVault.account(libraryID: $0.libraryID, workspaceID: $0.workspaceID, deviceID: $0.deviceID)] = $0 },
                     loadSigningKey: { box.signingKey }, saveSigningKey: { box.signingKey = $0 },
                     restoresPairing: false)
    }
}

/// Each background server owns an independent full database and exchanges
/// durable observations with peers. No host changes role when a peer leaves.
@Observable @MainActor
final class PairedMacSyncController {
    private weak var host: CompanionHostController?
    private let network: PairedMacNetwork
    private let loadCredentials: @MainActor () throws -> [PairedMacCredential]
    private let saveCredentials: @MainActor ([PairedMacCredential]) throws -> Void
    private let restoresPairing: Bool
    private var syncing = false
    private var nextAttempt: [String: Date] = [:]
    private(set) var routes: [PairedMacRoute] = []
    private(set) var errors: [String: String] = [:]
    private(set) var conflicts: [PairedLibraryConflict] = []
    private(set) var lastSynchronized: [String: Date] = [:]
    private var restored = false
    private var files: PairedLibraryFiles?
    private var nextFileAttempt: [String: Date] = [:]
    private let storage: PairedMacDeviceStorage
    init(host: CompanionHostController, network: PairedMacNetwork = .init(), storage: PairedMacDeviceStorage) {
        self.host = host; self.network = network; self.storage = storage; self.restoresPairing = storage.restoresPairing
        self.loadCredentials = storage.loadCredentials; self.saveCredentials = storage.saveCredentials
    }
    @ObservationIgnored lazy var pairing = CompanionMacPairingController(identity: { [weak self] in
        self?.host?.peerIdentity ?? .init(deviceID: "00000000-0000-4000-8000-000000000000", deviceName: "Mac", metadata: .init(kind: .mac))
    }, onPaired: { [weak self] endpoint, response in
        guard let self else { throw CancellationError() }
        try await self.acceptPairing(endpoint: endpoint, response: response)
    }, loadClaim: storage.loadClaim, saveClaim: storage.saveClaim)
    func loadLegacyCredential() throws -> MobileCredential? { try storage.loadLegacyCredential() }
    nonisolated static let capability = "library.peers.v2"

    /// This Mac's signing identity. The key is created once and persisted in
    /// device-only storage before it signs anything.
    private var signingKey: Curve25519.Signing.PrivateKey?
    func identity() async throws -> PeerSelf {
        guard let host, let database = host.model?.dashboardStore?.database else { throw CancellationError() }
        let library = try await database.companionLibraryIdentity()
        if signingKey == nil {
            if let raw = try storage.loadSigningKey() { signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw) }
            else {
                let key = Curve25519.Signing.PrivateKey()
                try storage.saveSigningKey(key.rawRepresentation)
                signingKey = key
            }
        }
        let identity = PeerSelf(deviceID: library.hostDeviceID, libraryID: library.libraryID, key: signingKey!)
        await (try? host.peerAuthentication())?.useIdentity(identity)
        return identity
    }

    /// Never fails library or phone availability. A device-only storage error is
    /// recorded for Settings and retried on the next synchronization turn.
    func restoreRecordingFailures() async {
        do { try await restore(); errors.removeValue(forKey: "credentials") }
        catch { errors["credentials"] = "Paired Mac credentials are unavailable: " + error.localizedDescription }
    }

    func restore() async throws {
        guard let host, let database = host.model?.dashboardStore?.database else { return }
        let own = try await host.peerRoute()
        files = PairedLibraryFiles(root: database.supportDirectory)
        try await database.savePairedMacRoute(own)
        routes = try await database.pairedMacRoutes()
        if !restored && restoresPairing { await pairing.restorePendingRequest() }
        restored = true
        for credential in try loadCredentials() where credential.deviceID == own.deviceID && credential.needsJoin == true {
            do { try await finishPairing(credential) }
            catch { if !(error is URLError) { errors[credential.route.deviceID] = error.localizedDescription } }
        }
    }

    func pairUsingLink(_ text: String) async throws {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host else {
            throw CompanionAPIError(code: "invalid_pairing", message: "Paste a current Woven Matter pairing link.")
        }
        let payload = try CompanionPairingPayload.parseURL(url)
        let own = try await host.peerRoute()
        let advertisement: CompanionDiscoveryAdvertisement = try await network.request(payload.endpoint, path: "v1/discovery")
        guard advertisement.capabilities?.contains(Self.capability) == true, advertisement.identity.deviceID != own.deviceID else {
            throw CompanionAPIError(code: "update_required", message: "Use a pairing link from another Mac that supports paired Mac synchronization.")
        }
        let preview: CompanionPairingPreview = try await network.request(payload.endpoint, path: "v1/pair/preview",
            body: JSONEncoder().encode(CompanionPairRequest(token: payload.token, deviceID: own.deviceID,
                deviceName: own.name, metadata: .init(kind: .mac), requiresConfirmation: true, purpose: CompanionPairingPurpose.peerMac)))
        let response: CompanionPairResponse = try await network.request(payload.endpoint, path: "v1/pair",
            body: JSONEncoder().encode(CompanionPairRequest(token: payload.token, deviceID: own.deviceID,
                deviceName: own.name, metadata: .init(kind: .mac), expectedWorkspaceID: preview.workspaceID, requiresConfirmation: true,
                purpose: CompanionPairingPurpose.peerMac)))
        guard response.workspaceID == preview.workspaceID, response.confirmationRequired == true else {
            throw CompanionAPIError(code: "wrong_peer", message: "The pairing link returned a different library or confirmation contract.")
        }
        try await acceptPairing(endpoint: payload.endpoint, response: response)
    }

    func acceptPairing(endpoint: URL, response: CompanionPairResponse) async throws {
        guard let host else { throw CancellationError() }
        let own = try await host.peerRoute()
        guard response.deviceID == own.deviceID else { throw CompanionAPIError(code: "wrong_device", message: "Pairing did not preserve this Mac's identity.") }
        let advertisement: CompanionDiscoveryAdvertisement = try await network.request(endpoint, path: "v1/discovery")
        guard advertisement.capabilities?.contains(Self.capability) == true else {
            throw CompanionAPIError(code: "update_required", message: "Update both Macs to a version that supports paired Mac synchronization.")
        }
        let route = PairedMacRoute(deviceID: advertisement.identity.deviceID, libraryID: response.workspaceID,
            endpoint: endpoint, name: advertisement.identity.deviceName)
        try route.validate()
        var credentials = try loadCredentials()
        let previous = credentials.first { $0.route.deviceID == route.deviceID && $0.token == response.credential }
        let reciprocal = try (previous?.returnToken ?? Self.secret())
        let credential = PairedMacCredential(route: route, deviceID: own.deviceID, token: response.credential, returnToken: reciprocal, needsJoin: true, confirmationPending: response.confirmationRequired)
        credentials.removeAll { $0.route.deviceID == route.deviceID }; credentials.append(credential)
        try saveCredentials(credentials)
        try await finishPairing(credential)
    }

    private func finishPairing(_ credential: PairedMacCredential) async throws {
        guard let host, let database = host.model?.dashboardStore?.database, let reciprocal = credential.returnToken else { throw CancellationError() }
        let own = try await host.peerRoute(), route = credential.route
        guard credential.deviceID == own.deviceID else { throw CancellationError() }
        // Persisted before confirmation: losing either reply can resume the same
        // grant after restart without minting another device identity.
        if credential.confirmationPending == true {
            struct Confirmation: Decodable, Sendable { let confirmed: Bool }
            let confirmation: Confirmation = try await network.request(route.endpoint, path: "v1/pair/confirm",
                token: credential.token, libraryID: route.libraryID, body: Data("{}".utf8))
            guard confirmation.confirmed else { throw CompanionAPIError(code: "pairing_pending", message: "Pairing confirmation is pending.") }
        }
        let authentication = try await host.peerAuthentication()
        let identity = try await identity()
        try await database.backUpBeforePeerSync()
        // The join is built once, persisted, and repeated verbatim after a lost
        // reply. It proves this Mac's key for exactly the revocation context the
        // other Mac reported at the explicitly paired endpoint; the reply proves
        // the other Mac's key for the reciprocal grant. Both keys are pinned.
        var join = credential.join
        if join == nil {
            let context: PairedMacJoinContext = try await network.request(route.endpoint, path: "v1/peers/join/prepare", token: credential.token,
                body: Data("{}".utf8))
            guard context.route.deviceID == route.deviceID, context.route.libraryID == route.libraryID else {
                throw CompanionAPIError(code: "wrong_peer", message: "The paired Mac changed its identity during pairing.")
            }
            let statement = PeerAdmission.subjectStatement(issuerDeviceID: route.deviceID, issuerLibraryID: route.libraryID,
                subjectDeviceID: identity.deviceID, subjectLibraryID: identity.libraryID, subjectPublicKey: identity.publicKey,
                acknowledgedRevocations: context.acknowledgedRevocations)
            join = PairedMacJoin(route: own, returnCredential: reciprocal, publicKey: identity.publicKey,
                acknowledgedRevocations: context.acknowledgedRevocations, subjectSignature: try identity.key.signature(for: statement),
                reciprocalRevocations: await authentication.revocationContext(for: route.deviceID))
            var saved = try loadCredentials()
            if let index = saved.firstIndex(where: { $0.route.deviceID == route.deviceID && $0.token == credential.token }) {
                saved[index].join = join; try saveCredentials(saved)
            }
        }
        guard let join else { throw CancellationError() }
        let reply: PairedMacJoinReply
        do {
            reply = try await network.request(route.endpoint, path: "v1/peers/join", token: credential.token, body: JSONEncoder().encode(join))
        } catch let error as CompanionAPIError where error.code == "revocation_context" {
            // Nothing was admitted; prepare again with the current context.
            var saved = try loadCredentials()
            if let index = saved.firstIndex(where: { $0.route.deviceID == route.deviceID && $0.token == credential.token }) {
                saved[index].join = nil; try saveCredentials(saved)
            }
            throw error
        }
        guard reply.route.deviceID == route.deviceID, reply.route.libraryID == route.libraryID else {
            throw CompanionAPIError(code: "wrong_peer", message: "The paired Mac changed its identity during pairing.")
        }
        try await authentication.enrollPeer(route: route, token: reciprocal, publicKey: reply.publicKey,
            subjectSignature: reply.subjectSignature, acknowledgedRevocations: join.reciprocalRevocations, own: identity)
        try await database.savePairedMacRoute(route)
        var credentials = try loadCredentials()
        if let index = credentials.firstIndex(where: { $0.route.deviceID == route.deviceID && $0.token == credential.token }) {
            credentials[index].needsJoin = nil; credentials[index].confirmationPending = nil
            try saveCredentials(credentials)
        }
        routes = try await database.pairedMacRoutes()
        errors.removeValue(forKey: route.deviceID)
        nextAttempt[route.deviceID] = .distantPast
    }

    func handle(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse? {
        let path = request.target.replacingOccurrences(of: "/wovenmatter/", with: "/")
        guard path.hasPrefix("/v1/peers/") else { return nil }
        do {
            guard let host, let database = host.model?.dashboardStore?.database, !host.peerSyncPaused,
                  request.headers["x-woven-protocol"] == String(CompanionProtocol.version) else {
                return .error("unavailable", "This Mac is not ready to synchronize.", status: 503)
            }
            let authentication = try await host.peerAuthentication()
            if path == "/v1/peers/proof", request.method == "POST", request.body.count <= 4096 {
                let challenge = try JSONDecoder().decode(PairedMacProofChallenge.self, from: request.body)
                return try .json(try await authentication.peerProof(challenge, route: host.peerRoute(), own: identity()))
            }
            // Learned-peer handshake: unauthenticated by bearer, authenticated by
            // a one-use challenge and the requester's pinned key.
            if path == "/v1/peers/challenge", request.method == "POST", request.body.count <= 4096 {
                let challengeRequest = try JSONDecoder().decode(PairedMacChallengeRequest.self, from: request.body)
                return try .json(try await authentication.issueChallenge(challengeRequest, route: host.peerRoute(), own: identity()))
            }
            if path == "/v1/peers/handshake", request.method == "POST", request.body.count <= 4096 {
                let handshake = try JSONDecoder().decode(PairedMacHandshake.self, from: request.body)
                let grant = try await authentication.completeHandshake(handshake, own: identity())
                nextAttempt[handshake.request.requesterDeviceID] = .distantPast
                return try .json(grant)
            }
            guard let bearer = request.bearer else { return .error("unauthorized", "Pair this Mac before synchronizing.", status: 401) }
            let principal = try await authentication.authenticate(bearer: bearer)
            guard !principal.isDevelopment else { return .error("wrong_device", "Only paired Macs may exchange full libraries.", status: 403) }
            if path == "/v1/peers/join/prepare", request.method == "POST", request.body.count <= 1024 {
                let identity = try await identity()
                return try .json(PairedMacJoinContext(route: try await host.peerRoute(), publicKey: identity.publicKey,
                    acknowledgedRevocations: try await authentication.joinContext(for: principal)))
            }
            if path == "/v1/peers/join", request.method == "POST", request.body.count <= 16_384 {
                let join = try JSONDecoder().decode(PairedMacJoin.self, from: request.body)
                try join.route.validate()
                guard join.route.deviceID == principal.id else {
                    return .error("wrong_peer", "The reciprocal grant belongs to another Mac.", status: 403)
                }
                // Only an explicitly approved Mac grant this Mac issued can join,
                // with its exact transcript; the admission persists before any reply.
                let identity = try await identity()
                try await authentication.admitJoin(principal, join: join, own: identity)
                try await database.backUpBeforePeerSync()
                let reciprocal = PeerAdmission.subjectStatement(issuerDeviceID: join.route.deviceID, issuerLibraryID: join.route.libraryID,
                    subjectDeviceID: identity.deviceID, subjectLibraryID: identity.libraryID, subjectPublicKey: identity.publicKey,
                    acknowledgedRevocations: join.reciprocalRevocations)
                // The reciprocal bearer was issued by the requester and is used
                // only at the requester; this Mac never accepts it itself.
                var credentials = try loadCredentials()
                credentials.removeAll { $0.route.deviceID == principal.id }
                credentials.append(.init(route: join.route, deviceID: identity.deviceID, token: join.returnCredential))
                try saveCredentials(credentials)
                try await database.savePairedMacRoute(join.route)
                routes = try await database.pairedMacRoutes()
                nextAttempt[principal.id] = .distantPast
                return try .json(PairedMacJoinReply(route: try await host.peerRoute(), publicKey: identity.publicKey,
                    subjectSignature: try identity.key.signature(for: reciprocal)))
            }
            // Every other paired-Mac endpoint needs a peer grant this Mac issued
            // for an identity it still admits. Metadata never grants access.
            guard await authentication.isAuthorizedPeer(principal) else {
                return .error("wrong_device", "Only admitted paired Macs may exchange full libraries. Pair this Mac again.", status: 403)
            }
            if path == "/v1/peers/credential", request.method == "POST", request.body.count <= 4096 {
                let enrollment = try JSONDecoder().decode(PairedWorkspaceEnrollment.self, from: request.body)
                let own = try await host.peerRoute()
                guard let workspace = try await database.companionExecutionWorkspaces().first(where: { $0.id == enrollment.workspaceID && !$0.deleted }),
                      workspace.ownerDeviceID == own.deviceID else {
                    return .error("unauthorized", "Request this workspace's grant from the Mac that manages it.", status: 403)
                }
                // A Mac enrolls itself directly. It may also enroll one of its own
                // mobile devices; that grant records the Mac as its provenance.
                if enrollment.deviceID == principal.id {
                    return try .json(try await host.provisionExecutionWorkspace(id: enrollment.workspaceID, device: principal))
                }
                let name = await authentication.rosterName(for: enrollment.deviceID) ?? "Device"
                return try .json(try await host.provisionDelegatedExecution(id: enrollment.workspaceID, deviceID: enrollment.deviceID,
                    name: name, provisionedBy: principal.id))
            }
            if path == "/v1/peers/files", request.method == "POST", request.body.count <= 4096 {
                let cursor = try JSONDecoder().decode(String.self, from: request.body)
                let files = files ?? PairedLibraryFiles(root: database.supportDirectory)
                return try .json(try await files.page(after: cursor))
            }
            if path == "/v1/peers/file", request.method == "POST", request.body.count <= 4096 {
                let chunk = try JSONDecoder().decode(PairedLibraryFileRequest.self, from: request.body)
                let files = files ?? PairedLibraryFiles(root: database.supportDirectory)
                return try .json(try await files.chunk(chunk))
            }
            if path == "/v1/peers/exchange", request.method == "POST", request.body.count <= 48 * 1_024 * 1_024 {
                let exchange = try JSONDecoder().decode(PairedMacExchange.self, from: request.body)
                guard exchange.deviceID == principal.id, exchange.after >= 0,
                      try await database.pairedMacRoutes().contains(where: { $0.deviceID == principal.id }) else {
                    return .error("wrong_peer", "Finish pairing before exchanging library content.", status: 403)
                }
                try await database.backUpBeforePeerSync()
                // Membership and its revocations apply before, and independently
                // of, any library row that might be rejected or still waiting.
                try await authentication.mergeMembership(exchange.membership, own: identity())
                do { try await host.applyPeerRevocations(); errors.removeValue(forKey: "revocations") }
                catch { errors["revocations"] = error.localizedDescription }
                try await database.receivePairedLibrary(exchange.page, from: principal.id)
                let own = try await host.peerRoute()
                let reply = try await PairedMacExchange(deviceID: own.deviceID, after: exchange.page.cursor,
                    page: database.pairedLibraryPage(after: exchange.after), membership: authentication.peerMembership())
                lastSynchronized[principal.id] = Date(); errors.removeValue(forKey: principal.id)
                Task { await host.model?.refreshWorkspace() }
                return try .json(reply)
            }
            return .error("not_found", "Unknown paired Mac endpoint.", status: 404)
        } catch let error as CompanionAPIError { return .error(error.code, error.message, status: error.code == "unauthorized" ? 401 : 409) }
        catch { return .error("peer_sync", "Synchronization paused; all local writing is retained. " + error.localizedDescription, status: 409) }
    }

    func synchronize(force: Bool = false) async {
        guard !syncing, let host, !host.peerSyncPaused, let database = host.model?.dashboardStore?.database else { return }
        syncing = true; defer { syncing = false }
        if force { nextAttempt = [:]; nextFileAttempt = [:] }
        do {
            await restoreRecordingFailures()
            let authentication = try await host.peerAuthentication()
            let own = try await host.peerRoute()
            let identity = try await identity()
            var credentials = (try? loadCredentials()) ?? []
            routes = try await database.pairedMacRoutes()
            for route in routes where route.deviceID != own.deviceID {
                guard !Task.isCancelled, (nextAttempt[route.deviceID] ?? .distantPast) <= Date(),
                      await authentication.isActiveMac(route.deviceID) else { continue }
                // A pending explicit pairing with this Mac finishes through its own
                // join; nothing may replace its reciprocal state.
                if credentials.contains(where: { $0.route.deviceID == route.deviceID && !$0.isCompleted }) { continue }
                // A route is dialed only with a key pinned from explicit pairing
                // or a signed admission. Unsigned earlier grants need re-pairing.
                guard let pin = await authentication.pin(for: route.deviceID), pin.libraryID == route.libraryID else {
                    errors[route.deviceID] = "Pair with \(route.name) again to use signed synchronization."
                    continue
                }
                do {
                    // Each Mac accepts only grants it issued itself. Without one for
                    // this Mac, obtain it directly from that Mac through a pinned
                    // mutual handshake; another Mac's bearer is never presented.
                    var credential = credentials.first(where: { $0.route.deviceID == route.deviceID && $0.deviceID == own.deviceID && $0.isCompleted })
                    if credential == nil {
                        let grant = try await network.handshake(route, own: identity, pin: pin, operationID: UUID().uuidString.lowercased())
                        let issued = PairedMacCredential(route: grant.route, deviceID: own.deviceID, token: grant.token)
                        credentials = try loadCredentials()
                        credentials.removeAll { $0.route.deviceID == route.deviceID && $0.isCompleted }
                        credentials.append(issued); try saveCredentials(credentials)
                        credential = issued
                    }
                    guard var credential else { continue }
                    // The target proves its pinned key before receiving the bearer.
                    // A signed display-name change is adopted, never an identity change.
                    let verified = try await network.verify(route, deviceID: own.deviceID, token: credential.token, pin: pin)
                    if verified != credential.route {
                        credential.route = verified
                        credentials = try loadCredentials()
                        if let index = credentials.firstIndex(where: { $0.route.deviceID == route.deviceID && $0.token == credential.token }) {
                            credentials[index].route = verified; try saveCredentials(credentials)
                        }
                    }
                    if verified.name != route.name { try await database.savePairedMacRoute(verified) }
                    // Bound each turn so a slow peer never starves other peers.
                    for _ in 0..<8 {
                        let cursors = try await database.pairedLibraryCursors(route.deviceID)
                        let page = try await database.pairedLibraryPage(after: cursors.pushed)
                        let exchange = PairedMacExchange(deviceID: own.deviceID, after: cursors.pulled, page: page, membership: await authentication.peerMembership())
                        let reply: PairedMacExchange = try await network.request(route.endpoint, path: "v1/peers/exchange", token: credential.token, body: JSONEncoder().encode(exchange))
                        guard reply.deviceID == route.deviceID, reply.after == page.cursor else { throw CompanionAPIError(code: "wrong_peer", message: "The peer did not acknowledge this exact page.") }
                        try await authentication.mergeMembership(reply.membership, own: identity)
                        try await database.receivePairedLibrary(reply.page, from: route.deviceID)
                        try await database.acknowledgePairedLibrary(peer: route.deviceID, cursor: page.cursor)
                        if !page.hasMore && !reply.page.hasMore { break }
                    }
                    if (nextFileAttempt[route.deviceID] ?? .distantPast) <= Date() {
                        // File failure is independent of durable row acceptance.
                        do { try await synchronizeFiles(route: route, credential: credential) }
                        catch { errors["files:" + route.deviceID] = error.localizedDescription }
                        nextFileAttempt[route.deviceID] = Date().addingTimeInterval(30)
                    }
                    nextAttempt[route.deviceID] = Date().addingTimeInterval(5)
                    lastSynchronized[route.deviceID] = Date(); errors.removeValue(forKey: route.deviceID)
                } catch {
                    nextAttempt[route.deviceID] = Date().addingTimeInterval(20)
                    // A grant that Mac no longer honors is dropped; the next turn
                    // obtains a fresh one through the pinned handshake.
                    if let error = error as? CompanionAPIError, error.code == "unauthorized" {
                        credentials = (try? loadCredentials()) ?? credentials
                        credentials.removeAll { $0.route.deviceID == route.deviceID && $0.isCompleted }
                        try? saveCredentials(credentials)
                    }
                    if let error = error as? CompanionAPIError {
                        if !["peer_unavailable", "unauthorized"].contains(error.code) { errors[route.deviceID] = error.message }
                    } else if !(error is URLError) { errors[route.deviceID] = error.localizedDescription }
                }
            }
            // Membership changes are independent of row materialization: a
            // waiting or malformed record can never delay a revocation.
            do { try await host.applyPeerRevocations() } catch { errors["revocations"] = error.localizedDescription }
            do {
                try await database.materializePendingPeerRecords()
                errors.removeValue(forKey: "pending")
            } catch { errors["pending"] = error.localizedDescription }
            conflicts = (try? await database.pairedLibraryConflicts()) ?? conflicts
            let quarantined = (try? await database.pairedLibraryQuarantineCount()) ?? 0
            if quarantined > 0 { errors["quarantine"] = "\(quarantined) shared record\(quarantined == 1 ? "" : "s") could not be applied. Local data is retained; update Woven Matter on every paired Mac." }
            else { errors.removeValue(forKey: "quarantine") }
            await host.model?.refreshWorkspace()
        } catch { errors["local"] = error.localizedDescription }
    }

    /// Execution access comes directly from the Mac that manages the
    /// workspace, authenticated with this Mac's own target-local grant there.
    func provision(workspace: CompanionExecutionWorkspace, deviceID: String) async throws -> CompanionExecutionCredential {
        guard let host, let database = host.model?.dashboardStore?.database,
              let route = try await database.pairedMacRoutes().first(where: { $0.deviceID == workspace.ownerDeviceID }) else {
            throw CompanionAPIError(code: "peer_unavailable", message: "Reconnect the Mac that added this workspace to finish device enrollment.")
        }
        let authentication = try await host.peerAuthentication(), identity = try await identity()
        guard await authentication.isActiveMac(route.deviceID), let pin = await authentication.pin(for: route.deviceID), pin.libraryID == route.libraryID else {
            throw CompanionAPIError(code: "peer_unavailable", message: "Pair with the Mac that added this workspace again to finish device enrollment.")
        }
        var credential = try loadCredentials().first(where: { $0.route.deviceID == route.deviceID && $0.deviceID == identity.deviceID && $0.isCompleted })
        if credential == nil {
            let grant = try await network.handshake(route, own: identity, pin: pin, operationID: UUID().uuidString.lowercased())
            let issued = PairedMacCredential(route: grant.route, deviceID: identity.deviceID, token: grant.token)
            var credentials = try loadCredentials()
            credentials.removeAll { $0.route.deviceID == route.deviceID && $0.isCompleted }
            credentials.append(issued); try saveCredentials(credentials)
            credential = issued
        }
        guard let credential else { throw CancellationError() }
        try await network.verify(route, deviceID: identity.deviceID, token: credential.token, pin: pin)
        let result: CompanionExecutionCredential = try await network.request(route.endpoint, path: "v1/peers/credential", token: credential.token,
            body: JSONEncoder().encode(PairedWorkspaceEnrollment(workspaceID: workspace.id, deviceID: deviceID)))
        guard result.workspace.id == workspace.id, result.workspace.ownerDeviceID == workspace.ownerDeviceID,
              result.workspace.libraryID == workspace.libraryID, result.deviceID == deviceID else {
            throw CompanionAPIError(code: "wrong_workspace", message: "The workspace returned a different execution identity.")
        }
        return result
    }

    private func synchronizeFiles(route: PairedMacRoute, credential: PairedMacCredential) async throws {
        guard let files, let database = host?.model?.dashboardStore?.database else { return }
        var cursor = try await database.pairedLibraryFileCursor(route.deviceID), chunks = 0
        for _ in 0..<8 {
            let page: PairedLibraryFilePage = try await network.request(route.endpoint, path: "v1/peers/files", token: credential.token, body: JSONEncoder().encode(cursor))
            for file in page.files {
                let errorKey = "file:" + route.deviceID + ":" + file.id
                do {
                    while let offset = try await files.nextOffset(file) {
                        guard !Task.isCancelled, chunks < 32 else { return }
                        let chunk: PairedLibraryFileChunk = try await network.request(route.endpoint, path: "v1/peers/file", token: credential.token,
                            body: JSONEncoder().encode(PairedLibraryFileRequest(file: file, offset: offset)))
                        guard chunk.file == file, chunk.offset == offset else { throw CompanionAPIError(code: "peer_file", message: "Shared file identity changed.") }
                        try await files.receive(chunk); chunks += 1
                    }
                    errors.removeValue(forKey: errorKey)
                } catch {
                    if error is URLError || Task.isCancelled { throw error }
                    errors[errorKey] = error.localizedDescription
                }
            }
            // Resume beyond the per-turn page bound. Wrap after a full scan so
            // newly added hashes before this cursor are discovered next time.
            cursor = page.hasMore ? page.cursor : ""
            try await database.savePairedLibraryFileCursor(cursor, peer: route.deviceID)
            if !page.hasMore { break }
        }
        errors.removeValue(forKey: "files:" + route.deviceID)
    }

    func revoke(_ deviceID: String) throws {
        var credentials = try loadCredentials()
        credentials.removeAll { $0.route.deviceID == deviceID }
        try saveCredentials(credentials)
    }

    static func secret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw POSIXError(.EIO) }
        return Data(bytes).base64EncodedString()
    }
}

/// Device-only private material; neither the database nor backend UI snapshots
/// contain these tokens. Reads fail silently when Keychain access is unavailable.
enum PairedMacCredentialVault {
    private static var signingQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: (Bundle.main.bundleIdentifier ?? "com.wovenmatter") + ".paired-mac-signing",
         kSecAttrAccount: CompanionTestWorkspace.supportDirectory?.path ?? DevelopmentLaunch.supportDirectory?.path ?? "production"]
    }
    static func loadSigningKey() throws -> Data? {
        var q = signingQuery; q[kSecReturnData] = true; q[kSecMatchLimit] = kSecMatchLimitOne; q[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return data
    }
    /// Created once; a device-only key is never replaced silently.
    static func saveSigningKey(_ key: Data) throws {
        let inserted = SecItemAdd(signingQuery.merging([kSecValueData: key, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, value in value } as CFDictionary, nil)
        guard inserted == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(inserted)) }
    }
    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: (Bundle.main.bundleIdentifier ?? "com.wovenmatter") + ".paired-macs",
         kSecAttrAccount: CompanionTestWorkspace.supportDirectory?.path ?? DevelopmentLaunch.supportDirectory?.path ?? "production"]
    }
    static func load() throws -> [PairedMacCredential] {
        var q = query; q[kSecReturnData] = true; q[kSecMatchLimit] = kSecMatchLimitOne; q[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return try JSONDecoder().decode([PairedMacCredential].self, from: data)
    }
    static func save(_ credentials: [PairedMacCredential]) throws {
        let attributes: [CFString: Any] = [kSecValueData: try JSONEncoder().encode(credentials), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let inserted = SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(inserted)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
