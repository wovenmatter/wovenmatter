import AppKit
import LibraryClient
import CryptoKit
import Foundation
import Observation
import Security
import WovenMatterCore
import WovenMatterLibraryStore

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

/// Device-only paired-Mac secrets: Mac grants and pending pairing claims.
/// Production uses Keychain; fixtures inject memory storage so tests can never
/// reach the user's Keychain.
struct PairedMacDeviceStorage {
    var loadCredentials: @MainActor () throws -> [PairedMacCredential]
    var saveCredentials: @MainActor ([PairedMacCredential]) throws -> Void
    var loadClaim: (String) throws -> StoredPairingClaim?
    var saveClaim: (StoredPairingClaim?, String) throws -> Void
    /// This Mac's device-only Curve25519 signing key (raw representation).
    var loadSigningKey: @MainActor () throws -> Data?
    var saveSigningKey: @MainActor (Data) throws -> Void
    var restoresPairing = true

    /// Production uses Keychain. A test process fails closed to isolated
    /// memory storage even when a fixture forgets to inject its own.
    @MainActor static var standard: Self { isTestProcess ? .memory() : .keychain }
    static var isTestProcess: Bool {
        ApplicationModel.isRunningUnitTests
            || ["xctest", "swiftpm-testing-helper"].contains(ProcessInfo.processInfo.processName)
            || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }
    @MainActor static var keychain: Self {
        .init(loadCredentials: PairedMacCredentialVault.load, saveCredentials: PairedMacCredentialVault.save,
              loadClaim: { try PendingPairingVault.load(deviceID: $0) },
              saveClaim: { try PendingPairingVault.save($0, deviceID: $1) },
              loadSigningKey: PairedMacCredentialVault.loadSigningKey, saveSigningKey: PairedMacCredentialVault.saveSigningKey)
    }
    /// Isolated storage for fixtures. Nothing is shared with other instances.
    @MainActor static func memory(credentials: [PairedMacCredential] = []) -> Self {
        final class Box: @unchecked Sendable {
            var credentials: [PairedMacCredential] = []; var claims: [String: StoredPairingClaim] = [:]
            var signingKey: Data?
        }
        let box = Box(); box.credentials = credentials
        return .init(loadCredentials: { box.credentials }, saveCredentials: { box.credentials = $0 },
                     loadClaim: { box.claims[$0] }, saveClaim: { claim, id in box.claims[id] = claim },
                     loadSigningKey: { box.signingKey }, saveSigningKey: { box.signingKey = $0 },
                     restoresPairing: false)
    }
}

/// Each background server owns an independent full database and exchanges
/// durable observations with peers. No host changes role when a peer leaves.
@Observable @MainActor
final class PairedMacSyncController {
    private weak var host: LibraryHostController?
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
    private let storage: PairedMacDeviceStorage
    /// Signed member records and change-driven peer synchronization
    /// (docs/architecture/WOVEN_EVERYWHERE.md). Pairing still uses the
    /// existing link and confirmation flow; its result is a member entry.
    private(set) var memberDirectory: MemberDirectory?
    private(set) var librarySync: LibraryPeerSync?
    private(set) var syncStatus: LibrarySyncStatus?
    @ObservationIgnored var peerTransport: LibraryPeerTransport = .urlSession()
    private var appliedMemberRemovals: Set<String> = []
    init(host: LibraryHostController, network: PairedMacNetwork = .init(), storage: PairedMacDeviceStorage) {
        self.host = host; self.network = network; self.storage = storage; self.restoresPairing = storage.restoresPairing
        self.loadCredentials = storage.loadCredentials; self.saveCredentials = storage.saveCredentials
    }
    @ObservationIgnored lazy var pairing = MacPairingController(identity: { [weak self] in
        self?.host?.peerIdentity ?? .init(deviceID: "00000000-0000-4000-8000-000000000000", deviceName: "Mac", metadata: .init(kind: .mac))
    }, onPaired: { [weak self] endpoint, response in
        guard let self else { throw CancellationError() }
        try await self.acceptPairing(endpoint: endpoint, response: response)
    }, loadClaim: storage.loadClaim, saveClaim: storage.saveClaim)
    nonisolated static let capability = "library.peers.v2"

    /// This Mac's signing identity. The key is created once and persisted in
    /// device-only storage before it signs anything.
    private var signingKey: Curve25519.Signing.PrivateKey?
    func identity() async throws -> PeerSelf {
        guard let host, let database = host.model?.libraryStore?.database else { throw CancellationError() }
        let library = try await database.libraryIdentity()
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

    /// This Mac's member directory, keyed by the same identity as pairing.
    func members() async throws -> MemberDirectory {
        if let memberDirectory { return memberDirectory }
        guard let database = host?.model?.libraryStore?.database else { throw CancellationError() }
        let directory = MemberDirectory(database: database, identity: MemberIdentity(try await identity(), kind: .mac))
        memberDirectory = directory
        return directory
    }

    /// Anchors this Mac, keeps its own entry's address current, converts Macs
    /// paired before members existed into members (their keys were already
    /// pinned by a signed join), and starts change-driven synchronization.
    private func startMembers(own: PairedMacRoute) async throws {
        guard let host else { return }
        let directory = try await members()
        try await directory.ensureSelf(name: own.name, endpoints: [own.endpoint])
        let authentication = try await host.peerAuthentication()
        let current = try await directory.list()
        for route in routes where route.deviceID != own.deviceID && current.active(route.deviceID) == nil {
            guard await authentication.isActiveMac(route.deviceID), let pin = await authentication.pin(for: route.deviceID),
                  pin.libraryID == route.libraryID else { continue }
            do { try await directory.add(deviceID: route.deviceID, kind: .mac, name: route.name, publicKey: pin.publicKey, endpoints: [route.endpoint]) }
            catch { errors[route.deviceID] = error.localizedDescription }
        }
        if librarySync == nil {
            let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "development"
            // The paired-Mac roster (Mac introductions, signed unpairs and
            // phone names for display) rides along each exchange.
            let attachments = LibraryPeerSync.Attachments(outgoing: { _ in
                try? JSONEncoder().encode(await authentication.peerMembership())
            }, incoming: { [weak self] data, peer in
                let membership = try JSONDecoder().decode(PeerMembership.self, from: data)
                guard let self else { return }
                try await self.mergeMembership(membership)
                // An unpair learned here ends the exchange before its page.
                guard await authentication.isActiveMac(peer) else {
                    throw LibraryAPIError(code: "unauthorized", message: "This Mac is no longer paired.")
                }
            })
            let sync = LibraryPeerSync(directory: directory, transport: peerTransport, configuration: .init(version: version), attachments: attachments)
            librarySync = sync
            await sync.start { [weak self] in await self?.peersChanged() }
            // After sleep every peer may have changed; catch up at once
            // instead of waiting out the offline backoff.
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { await sync.resume(reason: "wake") }
            }
        }
    }

    /// The other Mac's key was proven by the signed join; record it as a member.
    private func addMember(route: PairedMacRoute, publicKey: Data) async {
        do {
            try await members().add(deviceID: route.deviceID, kind: .mac, name: route.name, publicKey: publicKey, endpoints: [route.endpoint])
            await librarySync?.scheduleAll()
        } catch { errors[route.deviceID] = error.localizedDescription }
    }

    /// A user's unpair on this Mac also removes the device's membership,
    /// which every device applies as soon as it synchronizes.
    func removeMember(_ deviceID: String) async throws {
        let directory = try await members()
        guard try await directory.list().members.contains(where: { $0.deviceID == deviceID && !$0.revoked }) else { return }
        try await directory.remove(deviceID)
        appliedMemberRemovals.insert(deviceID)
    }

    /// Rows from a peer were applied: apply member removals learned there to
    /// this Mac's own grants, then refresh status and views.
    private func peersChanged() async {
        guard let host, let directory = memberDirectory else { return }
        await directory.invalidate()
        if let list = try? await directory.list() {
            let own = directory.identity.deviceID
            for member in list.members where member.revoked && member.deviceID != own && !appliedMemberRemovals.contains(member.deviceID) {
                appliedMemberRemovals.insert(member.deviceID)
                await host.applyMemberRemoval(member.deviceID)
            }
        }
        do { try await host.applyPeerRevocations() } catch { errors["revocations"] = error.localizedDescription }
        await refreshSyncStatus()
        // A synchronized workspace registration or member change opens, closes
        // or retries this Mac's streams.
        await host.connectExecutionStreams()
        await host.model?.refreshWorkspace()
    }

    private func mergeMembership(_ membership: PeerMembership) async throws {
        guard let host else { return }
        try await host.peerAuthentication().mergeMembership(membership, own: identity())
        do { try await host.applyPeerRevocations(); errors.removeValue(forKey: "revocations") }
        catch { errors["revocations"] = error.localizedDescription }
    }

    func refreshSyncStatus() async {
        guard let librarySync, let database = host?.model?.libraryStore?.database else { return }
        let status = await librarySync.status()
        syncStatus = status
        for peer in status.peers {
            switch peer.state {
            case .updateRequired: errors[peer.deviceID] = peer.error ?? "Update Woven Matter on every device to synchronize with \(peer.name)."
            case .failing: errors[peer.deviceID] = peer.error
            case .online, .offline: errors.removeValue(forKey: peer.deviceID)
            }
        }
        conflicts = (try? await database.pairedLibraryConflicts()) ?? conflicts
        if status.quarantined > 0 { errors["quarantine"] = "\(status.quarantined) shared record\(status.quarantined == 1 ? "" : "s") could not be applied. Local data is retained; update Woven Matter on every device." }
        else { errors.removeValue(forKey: "quarantine") }
        for peer in status.peers { if let date = peer.lastSynchronized { lastSynchronized[peer.deviceID] = date } }
    }

    func stopMembers() async {
        await librarySync?.stop()
        librarySync = nil
    }

    /// Never fails library or phone availability. A device-only storage error is
    /// recorded for Settings and retried on the next synchronization turn.
    func restoreRecordingFailures() async {
        do { try await restore(); errors.removeValue(forKey: "credentials") }
        catch { errors["credentials"] = "Paired Mac credentials are unavailable: " + error.localizedDescription }
    }

    func restore() async throws {
        guard let host, let database = host.model?.libraryStore?.database else { return }
        let own = try await host.peerRoute()
        try await database.savePairedMacRoute(own)
        routes = try await database.pairedMacRoutes()
        // A recovery backup interrupted by quitting resumes before any import.
        if (try? loadCredentials())?.isEmpty == false { database.prepareForPeerSync() }
        try await startMembers(own: own)
        if !restored && restoresPairing { await pairing.restorePendingRequest() }
        restored = true
        for credential in try loadCredentials() where credential.deviceID == own.deviceID && credential.needsJoin == true {
            do { try await finishPairing(credential) }
            catch { if !(error is URLError) { errors[credential.route.deviceID] = error.localizedDescription } }
        }
    }

    func pairUsingLink(_ text: String) async throws {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host else {
            throw LibraryAPIError(code: "invalid_pairing", message: "Paste a current Woven Matter pairing link.")
        }
        let payload = try PairingPayload.parseURL(url)
        let own = try await host.peerRoute()
        let advertisement: DiscoveryAdvertisement = try await network.request(payload.endpoint, path: "v1/discovery")
        guard advertisement.capabilities?.contains(Self.capability) == true, advertisement.identity.deviceID != own.deviceID else {
            throw LibraryAPIError(code: "update_required", message: "Use a pairing link from another Mac that supports paired Mac synchronization.")
        }
        let preview: PairingPreview = try await network.request(payload.endpoint, path: "v1/pair/preview",
            body: JSONEncoder().encode(PairRequest(token: payload.token, deviceID: own.deviceID,
                deviceName: own.name, metadata: .init(kind: .mac), requiresConfirmation: true, purpose: PairingPurpose.peerMac)))
        let response: PairResponse = try await network.request(payload.endpoint, path: "v1/pair",
            body: JSONEncoder().encode(PairRequest(token: payload.token, deviceID: own.deviceID,
                deviceName: own.name, metadata: .init(kind: .mac), expectedWorkspaceID: preview.workspaceID, requiresConfirmation: true,
                purpose: PairingPurpose.peerMac)))
        guard response.workspaceID == preview.workspaceID, response.confirmationRequired == true else {
            throw LibraryAPIError(code: "wrong_peer", message: "The pairing link returned a different library or confirmation contract.")
        }
        try await acceptPairing(endpoint: payload.endpoint, response: response)
    }

    func acceptPairing(endpoint: URL, response: PairResponse) async throws {
        guard let host else { throw CancellationError() }
        let own = try await host.peerRoute()
        guard response.deviceID == own.deviceID else { throw LibraryAPIError(code: "wrong_device", message: "Pairing did not preserve this Mac's identity.") }
        let advertisement: DiscoveryAdvertisement = try await network.request(endpoint, path: "v1/discovery")
        guard advertisement.capabilities?.contains(Self.capability) == true else {
            throw LibraryAPIError(code: "update_required", message: "Update both Macs to a version that supports paired Mac synchronization.")
        }
        let route = PairedMacRoute(deviceID: advertisement.identity.deviceID, libraryID: response.workspaceID,
            endpoint: endpoint, name: advertisement.identity.deviceName)
        try route.validate()
        var credentials = try loadCredentials()
        let previous = credentials.first { $0.route.deviceID == route.deviceID && $0.token == response.credential }
        let reciprocal = try (previous?.returnToken ?? MacPairingController.secret())
        let credential = PairedMacCredential(route: route, deviceID: own.deviceID, token: response.credential, returnToken: reciprocal, needsJoin: true, confirmationPending: response.confirmationRequired)
        credentials.removeAll { $0.route.deviceID == route.deviceID }; credentials.append(credential)
        try saveCredentials(credentials)
        try await finishPairing(credential)
    }

    private func finishPairing(_ credential: PairedMacCredential) async throws {
        guard let host, let database = host.model?.libraryStore?.database, let reciprocal = credential.returnToken else { throw CancellationError() }
        let own = try await host.peerRoute(), route = credential.route
        guard credential.deviceID == own.deviceID else { throw CancellationError() }
        // Persisted before confirmation: losing either reply can resume the same
        // grant after restart without minting another device identity.
        if credential.confirmationPending == true {
            struct Confirmation: Decodable, Sendable { let confirmed: Bool }
            let confirmation: Confirmation = try await network.request(route.endpoint, path: "v1/pair/confirm",
                token: credential.token, libraryID: route.libraryID, body: Data("{}".utf8))
            guard confirmation.confirmed else { throw LibraryAPIError(code: "pairing_pending", message: "Pairing confirmation is pending.") }
        }
        let authentication = try await host.peerAuthentication()
        let identity = try await identity()
        // Writing the recovery backup of a large library takes minutes. Pairing
        // continues meanwhile; the first import from the other Mac waits for it.
        database.prepareForPeerSync()
        // The join is built once, persisted, and repeated verbatim after a lost
        // reply. It proves this Mac's key for exactly the revocation context the
        // other Mac reported at the explicitly paired endpoint; the reply proves
        // the other Mac's key for the reciprocal grant. Both keys are pinned.
        var join = credential.join
        if join == nil {
            let context: PairedMacJoinContext = try await network.request(route.endpoint, path: "v1/peers/join/prepare", token: credential.token,
                body: Data("{}".utf8))
            guard context.route.deviceID == route.deviceID, context.route.libraryID == route.libraryID else {
                throw LibraryAPIError(code: "wrong_peer", message: "The paired Mac changed its identity during pairing.")
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
        } catch let error as LibraryAPIError where error.code == "revocation_context" {
            // Nothing was admitted; prepare again with the current context.
            var saved = try loadCredentials()
            if let index = saved.firstIndex(where: { $0.route.deviceID == route.deviceID && $0.token == credential.token }) {
                saved[index].join = nil; try saveCredentials(saved)
            }
            throw error
        }
        guard reply.route.deviceID == route.deviceID, reply.route.libraryID == route.libraryID else {
            throw LibraryAPIError(code: "wrong_peer", message: "The paired Mac changed its identity during pairing.")
        }
        try await authentication.enrollPeer(route: route, token: reciprocal, publicKey: reply.publicKey,
            subjectSignature: reply.subjectSignature, acknowledgedRevocations: join.reciprocalRevocations, own: identity)
        try await database.savePairedMacRoute(route)
        await addMember(route: route, publicKey: reply.publicKey)
        var credentials = try loadCredentials()
        if let index = credentials.firstIndex(where: { $0.route.deviceID == route.deviceID && $0.token == credential.token }) {
            credentials[index].needsJoin = nil; credentials[index].confirmationPending = nil
            try saveCredentials(credentials)
        }
        routes = try await database.pairedMacRoutes()
        errors.removeValue(forKey: route.deviceID)
        nextAttempt[route.deviceID] = .distantPast
    }

    /// Reads one page of another Mac's usage with this Mac's existing grant for it.
    func requestUsage(route: PairedMacRoute, request: UsageDeviceExportRequest) async throws -> UsageDeviceExportPage {
        guard let credential = try loadCredentials().first(where: { $0.route.deviceID == route.deviceID && $0.isCompleted }) else {
            throw LibraryAPIError(code: "unauthorized", message: "\(route.name) has no completed pairing with this Mac.")
        }
        do {
            return try await network.request(route.endpoint, path: "v1/peers/usage", token: credential.token,
                body: JSONEncoder().encode(request))
        } catch let error as LibraryAPIError where error.code == "not_found" {
            throw UsageDeviceCollectionError.updateRequired
        }
    }

    func handle(_ request: LibraryHTTPRequest) async -> LibraryHTTPResponse? {
        let path = request.target.replacingOccurrences(of: "/wovenmatter/", with: "/")
        guard path.hasPrefix("/v1/peers/") else { return nil }
        if MemberRequestVerifier.isSigned(request.headers) {
            guard host != nil, let librarySync else {
                return .error("unavailable", "This Mac is not ready to synchronize.", status: 503)
            }
            return await librarySync.handle(request) ?? .error("not_found", "Unknown peer endpoint.", status: 404)
        }
        do {
            guard let host, let database = host.model?.libraryStore?.database,
                  request.headers["x-woven-protocol"] == String(LibraryProtocol.version) else {
                return .error("unavailable", "This Mac is not ready to synchronize.", status: 503)
            }
            let authentication = try await host.peerAuthentication()
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
                // The reply never waits for the recovery backup; this Mac's
                // first import from the joining Mac does.
                database.prepareForPeerSync()
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
                await addMember(route: join.route, publicKey: join.publicKey)
                return try .json(PairedMacJoinReply(route: try await host.peerRoute(), publicKey: identity.publicKey,
                    subjectSignature: try identity.key.signature(for: reciprocal)))
            }
            // Every other paired-Mac endpoint needs a peer grant this Mac issued
            // for an identity it still admits. Metadata never grants access.
            guard await authentication.isAuthorizedPeer(principal) else {
                return .error("wrong_device", "Only admitted paired Macs may exchange full libraries. Pair this Mac again.", status: 403)
            }
            if path == "/v1/peers/usage", request.method == "POST", request.body.count <= 4096 {
                guard let model = host.model else {
                    return .error("unavailable", "This Mac is not ready to synchronize.", status: 503)
                }
                return try .json(try await model.exportDeviceUsage(
                    try JSONDecoder().decode(UsageDeviceExportRequest.self, from: request.body)))
            }
            return .error("not_found", "Unknown paired Mac endpoint.", status: 404)
        } catch let error as LibraryAPIError { return .error(error.code, error.message, status: error.code == "unauthorized" ? 401 : 409) }
        catch { return .error("peer_sync", "Synchronization paused; all local writing is retained. " + error.localizedDescription, status: 409) }
    }

    /// Called by the host's local housekeeping loop. Peer synchronization
    /// itself is change-driven inside `LibraryPeerSync`; this only refreshes
    /// local state, and with `force` ("Sync now") catches up every peer once.
    func synchronize(force: Bool = false) async {
        guard !syncing, let host, let database = host.model?.libraryStore?.database else { return }
        syncing = true; defer { syncing = false }
        await restoreRecordingFailures()
        if force { await librarySync?.synchronizeAll() }
        do { try await host.applyPeerRevocations() } catch { errors["revocations"] = error.localizedDescription }
        do {
            try await database.materializePendingPeerRecords()
            errors.removeValue(forKey: "pending")
        } catch { errors["pending"] = error.localizedDescription }
        await refreshSyncStatus()
    }

    func revoke(_ deviceID: String) throws {
        var credentials = try loadCredentials()
        credentials.removeAll { $0.route.deviceID == deviceID }
        try saveCredentials(credentials)
    }
}

/// Device-only private material; neither the database nor backend UI snapshots
/// contain these tokens. Reads fail silently when Keychain access is unavailable.
enum PairedMacCredentialVault {
    private static var signingQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: (Bundle.main.bundleIdentifier ?? "com.wovenmatter") + ".paired-mac-signing",
         kSecAttrAccount: IsolatedTestWorkspace.supportDirectory?.path ?? DevelopmentLaunch.supportDirectory?.path ?? "production"]
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
         kSecAttrAccount: IsolatedTestWorkspace.supportDirectory?.path ?? DevelopmentLaunch.supportDirectory?.path ?? "production"]
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
