import AppKit
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
    init(host: CompanionHostController, network: PairedMacNetwork = .init(), restoresPairing: Bool = true,
         loadCredentials: @escaping @MainActor () throws -> [PairedMacCredential] = PairedMacCredentialVault.load,
         saveCredentials: @escaping @MainActor ([PairedMacCredential]) throws -> Void = PairedMacCredentialVault.save) {
        self.host = host; self.network = network; self.restoresPairing = restoresPairing
        self.loadCredentials = loadCredentials; self.saveCredentials = saveCredentials
    }
    @ObservationIgnored lazy var pairing = CompanionMacPairingController(identity: { [weak self] in
        self?.host?.peerIdentity ?? .init(deviceID: "00000000-0000-4000-8000-000000000000", deviceName: "Mac", metadata: .init(kind: .mac))
    }, onPaired: { [weak self] endpoint, response in
        guard let self else { throw CancellationError() }
        try await self.acceptPairing(endpoint: endpoint, response: response)
    })

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
        guard advertisement.capabilities?.contains("library.peers.v1") == true, advertisement.identity.deviceID != own.deviceID else {
            throw CompanionAPIError(code: "update_required", message: "Use a pairing link from another Mac that supports paired Mac synchronization.")
        }
        let preview: CompanionPairingPreview = try await network.request(payload.endpoint, path: "v1/pair/preview",
            body: JSONEncoder().encode(CompanionPairRequest(token: payload.token, deviceID: own.deviceID,
                deviceName: own.name, metadata: .init(kind: .mac), requiresConfirmation: true)))
        let response: CompanionPairResponse = try await network.request(payload.endpoint, path: "v1/pair",
            body: JSONEncoder().encode(CompanionPairRequest(token: payload.token, deviceID: own.deviceID,
                deviceName: own.name, metadata: .init(kind: .mac), expectedWorkspaceID: preview.workspaceID, requiresConfirmation: true)))
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
        guard advertisement.capabilities?.contains("library.peers.v1") == true else {
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
        try await authentication.enrollPeer(deviceID: route.deviceID, name: route.name, token: reciprocal)
        try await database.backUpBeforePeerSync()
        let reply: PairedMacRoute = try await network.request(route.endpoint, path: "v1/peers/join", token: credential.token,
            body: JSONEncoder().encode(PairedMacJoin(route: own, returnCredential: reciprocal)))
        guard reply == route else { throw CompanionAPIError(code: "wrong_peer", message: "The paired Mac changed its identity during pairing.") }
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
            guard let host, let database = host.model?.dashboardStore?.database,
                  request.headers["x-woven-protocol"] == String(CompanionProtocol.version) else {
                return .error("unavailable", "This Mac is not ready to synchronize.", status: 503)
            }
            let authentication = try await host.peerAuthentication()
            if path == "/v1/peers/proof", request.method == "POST", request.body.count <= 4096 {
                let challenge = try JSONDecoder().decode(PairedMacProofChallenge.self, from: request.body)
                let route = try await host.peerRoute()
                return try .json(try await authentication.peerProof(challenge, route: route))
            }
            guard let bearer = request.bearer else { return .error("unauthorized", "Pair this Mac before synchronizing.", status: 401) }
            let principal = try await authentication.authenticate(bearer: bearer)
            guard principal.kind == .mac, !principal.isDevelopment else { return .error("wrong_device", "Only paired Macs may exchange full libraries.", status: 403) }
            if path == "/v1/peers/join", request.method == "POST", request.body.count <= 8192 {
                let join = try JSONDecoder().decode(PairedMacJoin.self, from: request.body)
                try join.route.validate()
                guard join.route.deviceID == principal.id, (32...256).contains(join.returnCredential.utf8.count) else {
                    return .error("wrong_peer", "The reciprocal grant belongs to another Mac.", status: 403)
                }
                let own = try await host.peerRoute()
                try await database.backUpBeforePeerSync()
                var credentials = try loadCredentials()
                credentials.removeAll { $0.route.deviceID == principal.id }
                credentials.append(.init(route: join.route, deviceID: own.deviceID, token: join.returnCredential))
                try saveCredentials(credentials)
                try await database.savePairedMacRoute(join.route)
                routes = try await database.pairedMacRoutes()
                nextAttempt[principal.id] = .distantPast
                return try .json(own)
            }
            if path == "/v1/peers/credential", request.method == "POST", request.body.count <= 4096 {
                let enrollment = try JSONDecoder().decode(PairedWorkspaceEnrollment.self, from: request.body)
                let own = try await host.peerRoute()
                guard let device = await authentication.devices().first(where: { $0.id == enrollment.deviceID }),
                      let workspace = try await database.companionExecutionWorkspaces().first(where: { $0.id == enrollment.workspaceID }),
                      workspace.ownerDeviceID == own.deviceID else {
                    return .error("unauthorized", "Only an active paired device may receive this owner's workspace grant.", status: 403)
                }
                return try .json(try await host.provisionExecutionWorkspace(id: enrollment.workspaceID, device: device))
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
                try await authentication.mergePeerDevices(exchange.devices)
                try await database.receivePairedLibrary(exchange.page, from: principal.id)
                try await host.applyPeerRevocations()
                let own = try await host.peerRoute()
                let reply = try await PairedMacExchange(deviceID: own.deviceID, after: exchange.page.cursor,
                    page: database.pairedLibraryPage(after: exchange.after), devices: authentication.peerDevices())
                lastSynchronized[principal.id] = Date(); errors.removeValue(forKey: principal.id)
                Task { await host.model?.refreshWorkspace() }
                return try .json(reply)
            }
            return .error("not_found", "Unknown paired Mac endpoint.", status: 404)
        } catch let error as CompanionAPIError { return .error(error.code, error.message, status: error.code == "unauthorized" ? 401 : 409) }
        catch { return .error("peer_sync", "Synchronization paused; all local writing is retained. " + error.localizedDescription, status: 409) }
    }

    func synchronize(force: Bool = false) async {
        guard !syncing, let host, let database = host.model?.dashboardStore?.database else { return }
        syncing = true; defer { syncing = false }
        if force { nextAttempt = [:]; nextFileAttempt = [:] }
        do {
            try await restore()
            let authentication = try await host.peerAuthentication()
            let own = try await host.peerRoute()
            let members = await authentication.peerDevices()
            let active = Set(members.filter { $0.revokedAt == nil && $0.kind == .mac }.map(\.id))
            var credentials = try loadCredentials()
            routes = try await database.pairedMacRoutes()
            for route in routes where route.deviceID != own.deviceID && active.contains(route.deviceID) {
                guard !Task.isCancelled, (nextAttempt[route.deviceID] ?? .distantPast) <= Date() else { continue }
                // A learned mesh route can reuse this Mac's device credential
                // only after that route proves possession of its verifier.
                guard let source = credentials.first(where: { $0.route.deviceID == route.deviceID && $0.deviceID == own.deviceID })
                    ?? credentials.first(where: { $0.deviceID == own.deviceID }) else { continue }
                do {
                    try await network.verify(route, deviceID: own.deviceID, token: source.token)
                    var credential = source; credential.route = route
                    credentials = try loadCredentials()
                    if !credentials.contains(where: { $0.route == route && $0.token == source.token }) {
                        credentials.removeAll { $0.route.deviceID == route.deviceID }; credentials.append(credential)
                        try saveCredentials(credentials)
                    }
                    // Bound each turn so a slow peer never starves other peers.
                    for _ in 0..<8 {
                        let cursors = try await database.pairedLibraryCursors(route.deviceID)
                        let page = try await database.pairedLibraryPage(after: cursors.pushed)
                        let exchange = PairedMacExchange(deviceID: own.deviceID, after: cursors.pulled, page: page, devices: await authentication.peerDevices())
                        let reply: PairedMacExchange = try await network.request(route.endpoint, path: "v1/peers/exchange", token: credential.token, body: JSONEncoder().encode(exchange))
                        guard reply.deviceID == route.deviceID, reply.after == page.cursor else { throw CompanionAPIError(code: "wrong_peer", message: "The peer did not acknowledge this exact page.") }
                        try await authentication.mergePeerDevices(reply.devices)
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
                    if let error = error as? CompanionAPIError {
                        if !["peer_unavailable", "unauthorized"].contains(error.code) { errors[route.deviceID] = error.message }
                    } else if !(error is URLError) { errors[route.deviceID] = error.localizedDescription }
                }
            }
            try await database.materializePendingPeerRecords()
            conflicts = try await database.pairedLibraryConflicts()
            try await host.applyPeerRevocations()
            await host.model?.refreshWorkspace()
        } catch { errors["local"] = error.localizedDescription }
    }

    func provision(workspace: CompanionExecutionWorkspace, deviceID: String) async throws -> CompanionExecutionCredential {
        guard let host, let database = host.model?.dashboardStore?.database,
              let route = try await database.pairedMacRoutes().first(where: { $0.deviceID == workspace.ownerDeviceID }),
              let credential = try loadCredentials().first(where: { $0.route.deviceID == route.deviceID }) else {
            throw CompanionAPIError(code: "peer_unavailable", message: "Reconnect the Mac that added this workspace to finish device enrollment.")
        }
        try await network.verify(route, deviceID: credential.deviceID, token: credential.token)
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
