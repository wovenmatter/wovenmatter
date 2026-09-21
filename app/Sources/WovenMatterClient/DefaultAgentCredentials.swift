import CryptoKit
import Foundation
import WovenMatterCore

public struct DefaultAgentCredential: Codable, Equatable, Sendable {
    public var type: String
    public var key: String?
    public var access: String?
    public var refresh: String?
    public var expires: Double?
    public var accountId: String?
    public var borrowed: Bool = false
    public init(type: String, key: String? = nil) { self.type = type; self.key = key }
    enum CodingKeys: String, CodingKey { case type, key, access, refresh, expires, accountId, borrowed }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        access = try c.decodeIfPresent(String.self, forKey: .access)
        refresh = try c.decodeIfPresent(String.self, forKey: .refresh)
        expires = try c.decodeIfPresent(Double.self, forKey: .expires)
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId)
        borrowed = try c.decodeIfPresent(Bool.self, forKey: .borrowed) ?? false
    }
    public func borrowing() -> Self { var copy = self; copy.refresh = ""; copy.borrowed = true; return copy }
}
public struct DefaultAgentPayload: Codable, Sendable {
    public var config: DefaultAgentSettings
    public var credentials: [String: DefaultAgentCredential]
    public var workspace: String
    public var unlockKey: String?
    public var revision: String?
    public init(config: DefaultAgentSettings, credentials: [String: DefaultAgentCredential], workspace: String) {
        self.config = config; self.credentials = credentials; self.workspace = workspace
    }
    public func data() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return try encoder.encode(self) }
}
public struct AgentSignInStatus: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let state: String
    public let detail: String
    public var label: String {
        switch state {
        case "verified": "Signed in"
        case "credentials_present": "Credentials present"
        case "sign_in_required": "Sign-in required"
        case "not_installed": "Not installed"
        case "locked": "Locked"
        case "not_checked": "Not checked"
        default: "Could not check"
        }
    }
}
public struct DefaultAgentStatus: Decodable, Sendable {
    public let providers: [AgentSignInStatus]
    public let locked: Bool?
}
public struct DefaultAgentSyncReceipt: Decodable, Sendable {
    public let saved: Bool
    public let revision: String
    public let epoch: String
}

/// One Mac owns renewal. Ordinary sends compare cached revisions and deadlines.
/// All slow work is coalesced, and replacement refresh tokens reach Keychain
/// before any borrowed access token becomes visible to a session or remote.
@MainActor
public final class DefaultAgentCredentialCoordinator {
    public static let shared = DefaultAgentCredentialCoordinator()
    public typealias Refresh = @Sendable ([String]) async throws -> [String: DefaultAgentPayload]
    private let refresh: Refresh
    private let version: @Sendable () -> UInt64
    private let clock: @Sendable () -> Date
    private var knownScopes: Set<String> = ["local", "global"]
    private var cached: [String: DefaultAgentPayload] = [:]
    private var cachedVersion: UInt64?
    private var nextCheck = Date.distantPast
    private var pending: Task<Void, any Error>?
    private var timer: Task<Void, Never>?
    private var signInID: UUID?
    public private(set) var lastError: String?
    public init(refresh: @escaping Refresh = DefaultAgentCredentialCoordinator.refreshStored,
                version: @escaping @Sendable () -> UInt64 = { DefaultAgentSupport.revision },
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.refresh = refresh; self.version = version; self.clock = clock
    }
    public func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { _ = try await self.prepare("local") } catch { self.lastError = error.localizedDescription }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
    public func invalidate() { cachedVersion = nil; nextCheck = .distantPast }
    public func beginSignIn() async throws -> UUID {
        if let pending { try await pending.value }
        try Task.checkCancellation()
        guard signInID == nil else { throw DefaultAgentError.message("Finish the current Default Agent sign-in first.") }
        let id = UUID(); signInID = id
        return id
    }
    public func endSignIn(_ id: UUID) { guard signInID == id else { return }; signInID = nil; invalidate() }
    public func prepare(_ workspace: String) async throws -> DefaultAgentPayload {
        knownScopes.insert(workspace)
        if cachedVersion == version(), clock() < nextCheck, let value = cached[workspace] { return value }
        if signInID != nil {
            if let value = cached[workspace] { return value }
            throw DefaultAgentError.message("Finish Default Agent sign-in before connecting this workspace.")
        }
        if let pending { try await pending.value; return try await prepare(workspace) }
        let scopes = Array(knownScopes), revision = version()
        let task = Task {
            let values = try await refresh(scopes)
            guard !Task.isCancelled else { throw CancellationError() }
            var prepared: [String: DefaultAgentPayload] = [:]
            for (scope, var value) in values {
                value.revision = nil
                value.revision = SHA256.hash(data: try value.data()).map { String(format: "%02x", $0) }.joined()
                prepared[scope] = value
            }
            cached = prepared; cachedVersion = revision
            let now = clock()
            let expiry = prepared.values.flatMap { $0.credentials.values }.compactMap(\.expires).min()
            // A near-expiry token after an unsuccessful renewal gets backoff;
            // healthy credentials do not spawn a helper on ordinary sends.
            nextCheck = expiry.map { max(now.addingTimeInterval(30), Date(timeIntervalSince1970: $0 / 1000 - 300)) } ?? now.addingTimeInterval(300)
            nextCheck = min(nextCheck, now.addingTimeInterval(300))
            lastError = nil
            NotificationCenter.default.post(name: .init("wovenmatter.default-agent.snapshot-ready"), object: nil)
        }
        pending = task
        do { try await task.value; pending = nil } catch {
            pending = nil; lastError = error.localizedDescription
            // Preserve still-valid access on transient control/Keychain failures.
            nextCheck = clock().addingTimeInterval(30)
            if let existing = cached[workspace], cachedVersion == version() { return existing }
            throw error
        }
        return try await prepare(workspace)
    }
    nonisolated public static func refreshStored(_ scopes: [String]) async throws -> [String: DefaultAgentPayload] {
        try DefaultAgentSupport.migrateLocalOAuth()
        let settings = DefaultAgentSupport.settings
        let keyScopes = Set(["global"] + Array(settings.workspaces.keys))
        var issues: [String: [String: String]] = [:]
        for scope in keyScopes {
            var owned: [String: DefaultAgentCredential] = [:]
            for id in ["openai-codex", "xai"] { if let c = try DefaultAgentSupport.oauth(id, scope: scope) { owned[id] = c } }
            guard owned.values.contains(where: { ($0.expires ?? 0) <= Date().timeIntervalSince1970 * 1000 + 300000 }) else { continue }
            struct Request: Encodable { let action = "refresh"; let credentials: [String: DefaultAgentCredential] }
            struct Result: Decodable { let credentials: [String: DefaultAgentCredential]; let errors: [String: String] }
            let response = try await DefaultAgentControl.run(try JSONEncoder().encode(Request(credentials: owned)))
            let result = try JSONDecoder().decode(Result.self, from: response)
            issues[scope] = result.errors
            for (id, c) in result.credentials where c != owned[id] {
                if let original = owned[id] {
                    try DefaultAgentSupport.saveRenewedOAuth(c, replacing: original, provider: id, scope: scope)
                }
            }
        }
        var result: [String: DefaultAgentPayload] = [:]
        for scope in scopes {
            var value = try DefaultAgentSupport.snapshot(workspace: scope)
            let keyScope = settings.workspaces[scope] == nil ? "global" : scope
            for id in ["openai-codex", "xai"] {
                let owner = try DefaultAgentSupport.oauth(id, scope: keyScope) == nil ? "global" : keyScope
                if issues[owner]?[id] == "sign_in_required" { value.credentials.removeValue(forKey: id) }
            }
            if scope != "local" && scope != "global" { value.unlockKey = try DefaultAgentSupport.workspaceKey(scope) }
            result[scope] = value
        }
        return result
    }
}
