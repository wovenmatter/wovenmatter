import Foundation
import Observation
import Security
import WovenMatterCompanion
import WovenMatterDashboardStore

@Observable @MainActor
final class CompanionMacPairingController {
    private(set) var peers: [CompanionDiscoveredPeer] = []
    private(set) var invitations: [CompanionPairingInvitation] = []
    private(set) var isDiscovering = false
    private(set) var isPairingMode = false
    private(set) var isRequestPending = false
    private(set) var hasSubmittedRequest = false
    private(set) var status = ""
    private(set) var errorMessage: String?
    private let identity: @MainActor () -> CompanionPairingDeviceIdentity
    private let onPaired: @MainActor (URL, CompanionPairResponse) async throws -> Void
    private let discovery: CompanionMacDiscovery
    private let network = CompanionPairingNetwork()
    private let makeExposure: @MainActor () -> CompanionTailscaleServe
    private var server: CompanionHTTPServer?
    private var exposure: CompanionTailscaleServe?
    private var generation = UUID()
    private var requestGeneration = UUID()
    private var pollTask: Task<Void, Never>?
    private var modeTask: Task<Void, Never>?
    private var pendingClaim: CompanionStoredPairingClaim?
    private var isInstallingPairing = false
    private let loadClaim: (String) throws -> CompanionStoredPairingClaim?
    private let saveClaim: (CompanionStoredPairingClaim?, String) throws -> Void
    private let cancelClaim: @MainActor (URL, CompanionPairingPoll) async throws -> Void

    init(identity: @escaping @MainActor () -> CompanionPairingDeviceIdentity,
         onPaired: @escaping @MainActor (URL, CompanionPairResponse) async throws -> Void,
         discovery: CompanionMacDiscovery = .init(),
         makeExposure: @escaping @MainActor () -> CompanionTailscaleServe = { CompanionTailscaleServe() },
         loadClaim: @escaping (String) throws -> CompanionStoredPairingClaim? = { try CompanionPendingPairingVault.load(deviceID: $0) },
         saveClaim: @escaping (CompanionStoredPairingClaim?, String) throws -> Void = { try CompanionPendingPairingVault.save($0, deviceID: $1) },
         cancelClaim: @escaping @MainActor (URL, CompanionPairingPoll) async throws -> Void = { endpoint, poll in
             let result: [String: Bool] = try await CompanionPairingNetwork().request(endpoint, path: "v1/pairing/cancel", body: JSONEncoder().encode(poll))
             guard result["cancelled"] == true else { throw CompanionAPIError(code: "invalid_response", message: "The Mac did not confirm cancellation.") }
         }) {
        self.identity = identity; self.onPaired = onPaired; self.discovery = discovery; self.makeExposure = makeExposure
        self.loadClaim = loadClaim; self.saveClaim = saveClaim; self.cancelClaim = cancelClaim
    }
    static var metadata: CompanionDeviceMetadata {
        .init(kind: .mac, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
              appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }
    func refreshDiscovery() async {
        guard !isDiscovering else { return }
        isDiscovering = true; errorMessage = nil
        defer { isDiscovering = false }
        do { peers = try await discovery.discover().filter { $0.advertisement.identity.deviceID != identity().deviceID } }
        catch { errorMessage = error.localizedDescription }
    }
    func startPairingMode() async {
        guard !isPairingMode else { return }
        generation = UUID(); let attempt = generation
        isPairingMode = true; errorMessage = nil; status = "Starting pairing…"
        do {
            if let exposure { try await exposure.waitUntilStopped() }
            guard generation == attempt else { return }
            let listener = CompanionHTTPServer { [weak self] request in
                guard let self else { return .error("unavailable", "Pairing is closed.", status: 503) }
                return await self.handle(request, generation: attempt)
            }
            server = listener
            let port = try await listener.start()
            guard generation == attempt else { listener.stop(); return }
            let serve = makeExposure(); exposure = serve
            _ = try await serve.start(loopbackPort: port)
            guard generation == attempt else { serve.stop(); return }
            status = "Available for a central database to invite"
            modeTask = Task { [weak self] in
                let deadline = Date().addingTimeInterval(600)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.generation == attempt, !Task.isCancelled else { return }
                    self.invitations.removeAll { $0.expiresAt <= Date() }
                    if Date() >= deadline || self.exposure?.isRunning != true { self.stopPairingMode(); return }
                }
            }
        } catch {
            guard generation == attempt else { return }
            stopPairingMode(); errorMessage = error.localizedDescription
        }
    }
    func stopPairingMode() {
        generation = UUID(); modeTask?.cancel(); modeTask = nil
        server?.stop(); server = nil; exposure?.stop()
        isPairingMode = false; invitations = []; status = ""
    }
    func requestPairing(with peer: CompanionDiscoveredPeer) async {
        guard !isRequestPending, pendingClaim == nil, peer.advertisement.role == .central else { return }
        do {
            let request = CompanionPairingApprovalRequest(requestID: UUID().uuidString.lowercased(), requestSecret: try Self.secret(), identity: identity())
            let claim = CompanionStoredPairingClaim(endpoint: peer.endpoint, request: request, expiresAt: Date().addingTimeInterval(600))
            // Stable, device-only Keychain storage precedes network acceptance.
            try saveClaim(claim, request.identity.deviceID)
            beginClaim(claim)
        } catch { errorMessage = error.localizedDescription }
    }
    func requestPairing(endpoint: URL) async throws {
        if let pendingClaim, pendingClaim.endpoint != endpoint {
            throw MacDeviceSetupError("Finish or cancel this Mac’s pending pairing request before pairing with another database.")
        }
        guard !isRequestPending else { return }
        let advertisement: CompanionDiscoveryAdvertisement = try await network.request(endpoint, path: "v1/discovery")
        guard advertisement.role == .central, advertisement.protocolVersion == CompanionProtocol.version else {
            throw MacDeviceSetupError("This Mac is not offering a compatible central database.")
        }
        await requestPairing(with: .init(endpoint: endpoint, advertisement: advertisement))
        if let errorMessage { throw MacDeviceSetupError(errorMessage) }
    }
    func restorePendingRequest() async {
        guard !isRequestPending else { return }
        do {
            guard let claim = try loadClaim(identity().deviceID) else { return }
            guard claim.request.identity.deviceID == identity().deviceID,
                  CompanionPairingPayload.isValidEndpoint(claim.endpoint), claim.expiresAt > Date() else {
                try saveClaim(nil, identity().deviceID)
                if claim.cancelled == true { errorMessage = "Cancellation could not be confirmed. Review paired devices on the central database before pairing again." }
                return
            }
            if claim.cancelled == true { beginCancellation(claim) } else { beginClaim(claim) }
        } catch { errorMessage = error.localizedDescription }
    }
    private func beginClaim(_ claim: CompanionStoredPairingClaim) {
        requestGeneration = UUID(); let attempt = requestGeneration
        pendingClaim = claim; isRequestPending = true; hasSubmittedRequest = false; errorMessage = nil
        status = "Waiting for approval on the central database"
        pollTask = Task { [weak self] in
            var registered = false
            while !Task.isCancelled {
                guard let self, self.requestGeneration == attempt else { return }
                do {
                    guard claim.expiresAt > Date() else { throw CompanionAPIError(code: "pairing_expired", message: "The pairing request expired. Try again.") }
                    let body = registered ? try JSONEncoder().encode(claim.poll) : try JSONEncoder().encode(claim.request)
                    let result: CompanionPairingApprovalResult = try await self.network.request(claim.endpoint,
                        path: registered ? "v1/pairing/result" : "v1/pairing/request", body: body)
                    registered = true
                    guard self.requestGeneration == attempt else { return }
                    self.hasSubmittedRequest = true
                    if try await self.acceptResult(result, endpoint: claim.endpoint, identity: claim.request.identity) { return }
                } catch let error as CompanionAPIError {
                    guard self.requestGeneration == attempt else { return }
                    self.errorMessage = error.localizedDescription
                    self.isRequestPending = false
                    // Keep approved claim material if local credential/replica
                    // installation failed; retry can still recover the same grant.
                    if ["pairing_denied", "pairing_expired", "invalid_pairing", "invalid_device", "unauthorized"].contains(error.code) {
                        try? self.saveClaim(nil, claim.request.identity.deviceID)
                        self.pendingClaim = nil
                    }
                    return
                } catch { /* A disconnected Mac retries the same persisted request. */ }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    private func acceptResult(_ result: CompanionPairingApprovalResult, endpoint: URL, identity: CompanionPairingDeviceIdentity) async throws -> Bool {
        if result.state == .denied { throw CompanionAPIError(code: "pairing_denied", message: "The central database declined this pairing request.") }
        guard result.state == .approved else { return false }
        guard let response = result.pairing, response.deviceID == identity.deviceID, response.protocolVersion == CompanionProtocol.version else {
            throw CompanionAPIError(code: "invalid_response", message: "The pairing response belongs to another device.")
        }
        isInstallingPairing = true
        defer { isInstallingPairing = false }
        try await onPaired(endpoint, response)
        try saveClaim(nil, identity.deviceID)
        pendingClaim = nil; isRequestPending = false; status = "Connected"
        stopPairingMode()
        return true
    }
    func cancelRequest() {
        guard !isInstallingPairing, var claim = pendingClaim else { return }
        do {
            claim.cancelled = true
            // Retain proof across disconnect/restart until the central database has
            // durably closed the request and queued any direct-access revokes.
            try saveClaim(claim, claim.request.identity.deviceID)
            beginCancellation(claim)
        } catch { errorMessage = error.localizedDescription }
    }
    private func beginCancellation(_ claim: CompanionStoredPairingClaim) {
        requestGeneration = UUID(); let attempt = requestGeneration
        pollTask?.cancel(); pendingClaim = claim; isRequestPending = true
        status = "Cancelling pairing…"; errorMessage = nil
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.requestGeneration == attempt else { return }
                do {
                    try await self.cancelClaim(claim.endpoint, claim.poll)
                    guard self.requestGeneration == attempt else { return }
                    try self.saveClaim(nil, claim.request.identity.deviceID)
                    self.pendingClaim = nil; self.isRequestPending = false; self.status = ""
                    return
                } catch {
                    guard self.requestGeneration == attempt else { return }
                    if claim.expiresAt <= Date() {
                        try? self.saveClaim(nil, claim.request.identity.deviceID)
                        self.pendingClaim = nil; self.isRequestPending = false
                        self.errorMessage = "Cancellation could not be confirmed. Review paired devices on the central database before pairing again."
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func acceptInvitation(id: String) async {
        guard !isRequestPending, pendingClaim == nil, let invitation = invitations.first(where: { $0.id == id }), invitation.expiresAt > Date() else { return }
        do {
            let request = CompanionPairingApprovalRequest(requestID: UUID().uuidString.lowercased(), requestSecret: try Self.secret(),
                identity: identity(), invitationToken: invitation.payload.token)
            let claim = CompanionStoredPairingClaim(endpoint: invitation.payload.endpoint, request: request,
                expiresAt: Date().addingTimeInterval(600))
            try saveClaim(claim, request.identity.deviceID)
            beginClaim(claim)
        } catch { errorMessage = error.localizedDescription }
    }
    func declineInvitation(id: String) { invitations.removeAll { $0.id == id } }

    func handle(_ request: CompanionHTTPRequest, generation attempt: UUID? = nil) async -> CompanionHTTPResponse {
        guard isPairingMode, attempt == nil || generation == attempt else { return .error("unavailable", "Pairing is closed.", status: 503) }
        let path = request.target.replacingOccurrences(of: "/wovenmatter/", with: "/")
        do {
            if request.method == "GET", path == "/v1/discovery" {
                return try .json(CompanionDiscoveryAdvertisement(role: .client, identity: identity()))
            }
            if request.method == "POST", path == "/v1/pairing/invite", request.body.count <= 8_192 {
                let invitation = try JSONDecoder().decode(CompanionPairingInvitation.self, from: request.body)
                guard UUID(uuidString: invitation.id) != nil, UUID(uuidString: invitation.central.deviceID) != nil,
                      invitation.central.metadata.kind == .mac, !invitation.central.deviceName.isEmpty,
                      [invitation.central.deviceName, invitation.central.metadata.osVersion, invitation.central.metadata.appVersion].compactMap({ $0 }).allSatisfy({ value in
                          value.utf8.count <= 120 && !value.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }
                      }),
                      invitation.expiresAt > Date(), invitation.expiresAt <= Date().addingTimeInterval(601),
                      CompanionPairingPayload.isValidEndpoint(invitation.payload.endpoint),
                      invitation.payload.protocolVersion == CompanionProtocol.version,
                      (32...256).contains(invitation.payload.token.utf8.count) else { throw CompanionAPIError(code: "invalid_pairing", message: "This invitation is invalid or expired.") }
                invitations.removeAll { $0.expiresAt <= Date() }
                if let old = invitations.first(where: { $0.id == invitation.id }) {
                    guard old == invitation else { throw CompanionAPIError(code: "pairing_conflict", message: "This invitation has changed.") }
                } else {
                    guard invitations.count < 8 else { return .error("rate_limited", "Too many pending invitations.", status: 429) }
                    invitations.append(invitation)
                }
                return try .json(["received": true])
            }
            return .error("not_found", "Unknown pairing endpoint.", status: 404)
        } catch { return .error("invalid_pairing", "This invitation is invalid or expired.", status: 400) }
    }
    private static func secret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CompanionAPIError(code: "random_failed", message: "Could not create a secure pairing request.")
        }
        return Data(bytes).base64EncodedString()
    }
}

struct CompanionStoredPairingClaim: Codable {
    let endpoint: URL
    let request: CompanionPairingApprovalRequest
    let expiresAt: Date
    var cancelled: Bool? = nil
    var poll: CompanionPairingPoll { .init(requestID: request.requestID, requestSecret: request.requestSecret) }
}

/// Pending claim secrets stay on this Mac and never enter defaults, app data,
/// backend snapshots, discovery responses, or the library sync journal.
private enum CompanionPendingPairingVault {
    private static func query(deviceID: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: (Bundle.main.bundleIdentifier ?? "com.wovenmatter") + ".pending-pairing",
         kSecAttrAccount: deviceID, kSecUseAuthenticationUI: kSecUseAuthenticationUIFail]
    }
    static func load(deviceID: String) throws -> CompanionStoredPairingClaim? {
        var request = query(deviceID: deviceID)
        request[kSecReturnData] = true; request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return try JSONDecoder().decode(CompanionStoredPairingClaim.self, from: data)
    }
    static func save(_ claim: CompanionStoredPairingClaim?, deviceID: String) throws {
        let request = query(deviceID: deviceID)
        guard let claim else {
            let status = SecItemDelete(request as CFDictionary)
            guard [errSecSuccess, errSecItemNotFound].contains(status) else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            return
        }
        let attributes: [CFString: Any] = [kSecValueData: try JSONEncoder().encode(claim),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var inserted = request.merging(attributes) { _, new in new }
            inserted.removeValue(forKey: kSecUseAuthenticationUI)
            let result = SecItemAdd(inserted as CFDictionary, nil)
            guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
