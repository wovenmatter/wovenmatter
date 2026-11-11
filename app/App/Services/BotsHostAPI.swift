import CryptoKit
import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

enum BotsHostAPIError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

/// The Runtime host API: what this Mac's bots runtime asks of the Woven server that
/// supervises it. Loopback only, behind its own bearer, which only the runtime holds.
/// Routes and shapes are docs/architecture/WOVEN_EVERYWHERE.md, Bots → Runtime host API.
struct BotsHostAPI: Sendable {
    /// `null` when not connected; otherwise exactly one of the contract's shapes.
    enum Credential: Equatable, Sendable, Encodable {
        case apiKey(String)
        /// Access only; `expires` is epoch milliseconds. Renewal stays with this Mac.
        case oauth(access: String, expires: Double, accountId: String?)
        /// The Claude subscription: the native runtime's directories, no token material.
        case native(configDir: String, secureStorageDir: String?)

        private enum Keys: String, CodingKey { case type, key, access, expires, accountId, configDir, secureStorageDir }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case .apiKey(let key):
                try container.encode("api_key", forKey: .type); try container.encode(key, forKey: .key)
            case let .oauth(access, expires, accountId):
                try container.encode("oauth", forKey: .type); try container.encode(access, forKey: .access)
                try container.encode(expires, forKey: .expires); try container.encodeIfPresent(accountId, forKey: .accountId)
            case let .native(configDir, secureStorageDir):
                try container.encode("native", forKey: .type); try container.encode(configDir, forKey: .configDir)
                try container.encodeIfPresent(secureStorageDir, forKey: .secureStorageDir)
            }
        }
    }

    struct CredentialReply: Encodable, Equatable, Sendable {
        var credential: Credential?
        /// Only for `web-search`: the search provider selected in Woven settings.
        var searchProvider: String?
        private enum Keys: String, CodingKey { case credential, searchProvider }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(credential, forKey: .credential)
            try container.encodeIfPresent(searchProvider, forKey: .searchProvider)
        }
    }

    /// Woven connection ids the runtime may ask for, plus `web-search`.
    static let providers: Set<String> = Set(ProviderConnectionID.allCases.map(\.rawValue)).union(["web-search"])
    static let maximumMirrorEntries = 200

    var token: String
    var issueKey: @MainActor @Sendable (_ botID: String, _ botName: String) async throws -> WovenBotMCPGrant
    var revokeKey: @MainActor @Sendable (_ botID: String) async throws -> Void
    var publishPreview: @MainActor @Sendable (_ botID: String, _ port: Int, _ containerPort: Int) async throws -> URL
    var removePreview: @MainActor @Sendable (_ botID: String, _ port: Int) async -> Void
    var inferenceCredential: @MainActor @Sendable (_ provider: String) async throws -> CredentialReply
    var recordConversation: @MainActor @Sendable (_ botID: String, _ batch: BotConversationMirror) async throws -> Void

    private struct KeyRequest: Decodable { let botID: String; let botName: String? }
    private struct KeyResponse: Encodable { let endpoint: String; let token: String }
    private struct PreviewRequest: Decodable { let botID: String; let port: Int; let containerPort: Int }
    private struct PreviewResponse: Encodable { let url: String }
    private struct CredentialRequest: Decodable { let provider: String }
    private struct Done: Encodable { var ok = true }

    func handle(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        guard let bearer = request.bearer, Self.matches(bearer, token) else {
            return .error("unauthorized", "A valid bots host bearer is required.", status: 401)
        }
        let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.target
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts[0] == "v1", parts[1] == "bots-host" else {
            return .error("not_found", "Unknown bots host route.", status: 404)
        }
        do {
            switch (request.method, Array(parts.dropFirst(2))) {
            case ("POST", ["mcp-keys"]):
                let body = try decode(KeyRequest.self, request)
                try Self.requireIdentifier(body.botID)
                let grant = try await issueKey(body.botID, body.botName ?? "Bot")
                return try .json(KeyResponse(endpoint: grant.endpointURL, token: grant.bearerToken))
            case let ("DELETE", route) where route.count == 2 && route[0] == "mcp-keys":
                try Self.requireIdentifier(route[1])
                try await revokeKey(route[1])
                return try .json(Done())
            case ("POST", ["previews"]):
                let body = try decode(PreviewRequest.self, request)
                try Self.requireIdentifier(body.botID)
                guard (1024...65535).contains(body.port), (1...65535).contains(body.containerPort) else {
                    throw BotsHostAPIError.invalid("Invalid preview port.")
                }
                let url = try await publishPreview(body.botID, body.port, body.containerPort)
                return try .json(PreviewResponse(url: url.absoluteString))
            case let ("DELETE", route) where route.count == 3 && route[0] == "previews":
                try Self.requireIdentifier(route[1])
                guard let port = Int(route[2]), (1...65535).contains(port) else { throw BotsHostAPIError.invalid("Invalid preview port.") }
                await removePreview(route[1], port)
                return try .json(Done())
            case ("POST", ["inference-credentials"]):
                let body = try decode(CredentialRequest.self, request)
                guard Self.providers.contains(body.provider) else { throw BotsHostAPIError.invalid("Unknown provider.") }
                return try .json(try await inferenceCredential(body.provider))
            case let ("POST", route) where route.count == 3 && route[0] == "conversations" && route[2] == "entries":
                try Self.requireIdentifier(route[1])
                let batch = try decode(BotConversationMirror.self, request)
                guard batch.bot.id == route[1] else { throw BotsHostAPIError.invalid("The batch names another bot.") }
                guard batch.entries.count <= Self.maximumMirrorEntries else { throw BotsHostAPIError.invalid("Send at most 200 entries at a time.") }
                try await recordConversation(route[1], batch)
                return try .json(Done())
            default:
                return .error("not_found", "Unknown bots host route.", status: 404)
            }
        } catch let error as WovenBotKeyError {
            return .error("revoked", error.localizedDescription, status: 403)
        } catch is DecodingError {
            return .error("invalid_request", "Invalid request body.", status: 400)
        } catch {
            return .error("failed", error.localizedDescription, status: 400)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: CompanionHTTPRequest) throws -> T {
        try JSONDecoder().decode(T.self, from: request.body)
    }

    private static func requireIdentifier(_ value: String) throws {
        guard WovenMCPCaller.isIdentifier(value) else { throw BotsHostAPIError.invalid("Invalid bot ID.") }
    }

    static func matches(_ presented: String, _ expected: String) -> Bool {
        let a = Data(SHA256.hash(data: Data(presented.utf8))), b = Data(SHA256.hash(data: Data(expected.utf8)))
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0 && !expected.isEmpty
    }

    /// The same credentials this Mac's own Pi Durable receives: a borrowed, access-only
    /// snapshot from the coordinator that owns renewal. Refresh tokens never leave the Mac.
    @MainActor static func storedCredential(provider: String) async throws -> CredentialReply {
        if provider == ProviderConnectionID.claudeSubscription.rawValue {
            // The selected subscription account's profile, as the default agent uses it. Only a
            // signed-in account counts: the runtime directory alone outlives a sign-out, and
            // offering it would route bots to Claude only for Claude Code to answer "Not logged in".
            let id = ProviderConnectionID.claudeSubscription.rawValue
            guard let selected = (try? ProviderConnectionAccounts.list(provider: id))?.first(where: { $0.isSelected }) else {
                return .init()
            }
            let profile = try? ProviderConnectionAccounts.nativeProfile(selected.id, provider: id)
            return .init(credential: nativeClaude(profile: profile))
        }
        let payload = try await ProviderAccountCoordinator.shared.prepare("global")
        if provider == "web-search" {
            let selected = payload.config.searchProvider
            guard ProviderConnectionID.searchProviders.map(\.rawValue).contains(selected) else { return .init() }
            return .init(credential: credential(payload.credentials[selected]), searchProvider: selected)
        }
        return .init(credential: credential(payload.credentials[provider]))
    }

    static func credential(_ value: DefaultAgentCredential?) -> Credential? {
        guard let value else { return nil }
        if let key = value.key, !key.isEmpty, value.access == nil { return .apiKey(key) }
        if let access = value.access, !access.isEmpty { return .oauth(access: access, expires: value.expires ?? 0, accountId: value.accountId) }
        return nil
    }

    /// Where the bundled default agent keeps the native Claude runtime's state
    /// (default-agent/src/claude-runtime.mjs). Absent until the user signs in there.
    static func nativeClaude(home: URL = FileManager.default.homeDirectoryForCurrentUser, profile: String? = nil) -> Credential? {
        var root = home.appending(path: ".wovenmatter/default-agent")
        // Per-account profiles live in claude-accounts/<profile> (claude-runtime.mjs
        // profileDirectory); "legacy" and no profile use the original directories.
        if let profile, profile != "legacy" {
            guard (1...64).contains(profile.count), profile.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
            root = root.appending(path: "claude-accounts").appending(path: profile)
        }
        let config = root.appending(path: "claude-runtime"), storage = root.appending(path: "claude-keychain")
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: config.path, isDirectory: &directory), directory.boolValue else { return nil }
        let hasStorage = FileManager.default.fileExists(atPath: storage.path, isDirectory: &directory) && directory.boolValue
        return .native(configDir: config.path, secureStorageDir: hasStorage ? storage.path : nil)
    }
}
