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
/// Routes and shapes are in docs/architecture/WOVEN_EVERYWHERE.md ("Runtime host API").
struct BotsHostAPI: Sendable {
    struct Credential: Codable, Equatable, Sendable {
        var type: String
        var key: String?
        var access: String?
        var expires: Double?
        var accountId: String?
    }

    var token: String
    var issueKey: @MainActor @Sendable (_ botID: String, _ botName: String) async throws -> WovenBotMCPGrant
    var revokeKey: @MainActor @Sendable (_ botID: String) async throws -> Void
    var publishPreview: @MainActor @Sendable (_ botID: String, _ port: Int) async throws -> URL
    var removePreview: @MainActor @Sendable (_ botID: String, _ port: Int) async -> Void
    var previews: @MainActor @Sendable () async -> [BotPreview]
    var inferenceCredential: @MainActor @Sendable (_ provider: String) async throws -> Credential?
    var recordConversation: @MainActor @Sendable (_ botID: String, _ report: BotConversationReport) async throws -> Int
    var deleteConversations: @MainActor @Sendable (_ botID: String) async throws -> Void

    private struct KeyRequest: Decodable { let botID: String; let botName: String? }
    private struct KeyResponse: Encodable { let endpoint: String; let token: String }
    private struct PreviewRequest: Decodable { let botID: String; let port: Int }
    private struct PreviewResponse: Encodable { let url: String }
    private struct PreviewList: Encodable { let previews: [BotPreview] }
    private struct CredentialRequest: Decodable { let provider: String }
    private struct CredentialResponse: Encodable { let provider: String; let credential: Credential }
    private struct Recorded: Encodable { let recorded: Int }
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
                let url = try await publishPreview(body.botID, body.port)
                return try .json(PreviewResponse(url: url.absoluteString))
            case ("GET", ["previews"]):
                return try .json(PreviewList(previews: await previews()))
            case let ("DELETE", route) where route.count == 3 && route[0] == "previews":
                try Self.requireIdentifier(route[1])
                guard let port = Int(route[2]), (1...65535).contains(port) else { throw BotsHostAPIError.invalid("Invalid preview port.") }
                await removePreview(route[1], port)
                return try .json(Done())
            case ("POST", ["inference-credentials"]):
                let body = try decode(CredentialRequest.self, request)
                guard WovenMCPCaller.isIdentifier(body.provider) else { throw BotsHostAPIError.invalid("Invalid provider.") }
                guard let credential = try await inferenceCredential(body.provider) else {
                    return .error("not_connected", "Connect \(body.provider) in Settings → Connections first.", status: 404)
                }
                return try .json(CredentialResponse(provider: body.provider, credential: credential))
            case let ("POST", route) where route.count == 3 && route[0] == "conversations" && route[2] == "entries":
                try Self.requireIdentifier(route[1])
                let report = try decode(BotConversationReport.self, request)
                return try .json(Recorded(recorded: try await recordConversation(route[1], report)))
            case let ("DELETE", route) where route.count == 2 && route[0] == "conversations":
                try Self.requireIdentifier(route[1])
                try await deleteConversations(route[1])
                return try .json(Done())
            default:
                return .error("not_found", "Unknown bots host route.", status: 404)
            }
        } catch let error as WovenBotKeyError {
            return .error("revoked", error.localizedDescription, status: 403)
        } catch let error as DecodingError {
            return .error("invalid_request", "Invalid request body: \(Self.describe(error))", status: 400)
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

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): "missing \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            context.codingPath.map(\.stringValue).joined(separator: ".")
        @unknown default: "malformed"
        }
    }

    /// Borrowed, access-only credentials, the same snapshot the Mac's own Pi Durable receives.
    /// Refresh tokens never leave this Mac.
    @MainActor static func storedCredential(provider: String) async throws -> Credential? {
        let payload = try await ProviderAccountCoordinator.shared.prepare("global")
        guard let value = payload.credentials[provider] else { return nil }
        let borrowed = value.borrowing()
        return Credential(type: borrowed.type, key: borrowed.key, access: borrowed.access,
                          expires: borrowed.expires, accountId: borrowed.accountId)
    }
}
