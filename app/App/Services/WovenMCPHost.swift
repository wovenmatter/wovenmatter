import CryptoKit
import Foundation
import Security
import WovenMatterCore
import WovenMatterDashboardStore

enum WovenMCPAccessAction: Codable, Sendable {
    case status
    case create(label: String, sessionID: String, groups: Set<WorkspaceToolGroup>, readOnly: Bool)
    case revoke(String)
}

struct WovenMCPClientGrant: Codable, Sendable, Identifiable {
    let id: String
    let label: String
    let sessionID: String
    let groups: Set<WorkspaceToolGroup>
    let readOnly: Bool
    let createdAt: Date
}

struct WovenMCPAccessSnapshot: Codable, Sendable {
    var endpointURL: String
    var clients: [WovenMCPClientGrant]
    var issuedConnection: WovenMCPConnection?
}

/// The bearer identifies the caller. Neither MCP arguments nor an MCP transport
/// session ID can choose a Woven conversation or increase its capabilities.
@MainActor
final class WovenMCPHost {
    private struct Credential: Codable, Sendable {
        let grant: WovenMCPClientGrant
        let tokenHash: String
        let persistent: Bool
        var lastAliveAt: Date
    }
    private struct SavedAccess: Codable {
        var port: UInt16
        var credentials: [Credential]
    }
    private let database: WorkspaceDatabase
    private let accessFile: URL
    private let perform: @MainActor @Sendable (WovenMatterToolRequest, String) async -> WovenMatterToolResponse
    private var credentials: [String: Credential] = [:]
    private var sessionConnections: [String: WovenMCPConnection] = [:]
    private var server: CompanionHTTPServer?
    private var startTask: Task<String, any Error>?
    private var endpointURL: String?
    private var preferredPort: UInt16 = 0
    private var generation = UUID()

    init(database: WorkspaceDatabase,
         perform: @escaping @MainActor @Sendable (WovenMatterToolRequest, String) async -> WovenMatterToolResponse) throws {
        self.database = database; self.perform = perform
        accessFile = database.supportDirectory.appending(path: "mcp-access.json")
        if FileManager.default.fileExists(atPath: accessFile.path) {
            let saved = try JSONDecoder().decode(SavedAccess.self, from: Data(contentsOf: accessFile))
            preferredPort = saved.port
            credentials = Dictionary(uniqueKeysWithValues: saved.credentials.filter(\.persistent).map { ($0.tokenHash, $0) })
        }
    }

    func start() async throws -> String {
        if let endpointURL { return endpointURL }
        if let startTask { return try await startTask.value }
        let expected = generation
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            let listener = CompanionHTTPServer { [weak self] request in
                guard let self else { return .error("unavailable", "Woven MCP stopped.", status: 503) }
                return await self.handle(request) ?? Self.unauthorizedResponse()
            }
            self.server = listener
            do {
                let port = try await listener.start(port: self.preferredPort)
                guard self.generation == expected, !Task.isCancelled else { listener.stop(); throw CancellationError() }
                let endpoint = "http://127.0.0.1:\(port)/mcp"
                self.preferredPort = port; self.endpointURL = endpoint
                try self.save()
                return endpoint
            } catch { listener.stop(); self.server = nil; self.endpointURL = nil; throw error }
        }
        startTask = task
        defer { startTask = nil }
        return try await task.value
    }

    func connection(sessionID: String, captureID: String?) async throws -> WovenMCPConnection {
        try await database.requireMCPCaller(sessionID)
        _ = try await database.sessionTools(sessionID)
        let endpoint = try await start()
        if let current = sessionConnections[sessionID],
           var credential = credentials[Self.hash(current.bearerToken)], Date().timeIntervalSince(credential.lastAliveAt) <= 24 * 60 * 60 {
            credential.lastAliveAt = Date(); credentials[credential.tokenHash] = credential
            return .init(endpointURL: endpoint, bearerToken: current.bearerToken, captureID: captureID, sessionID: sessionID)
        }
        revokeSession(sessionID)
        let grant = WovenMCPClientGrant(id: UUID().uuidString.lowercased(), label: "Woven session", sessionID: sessionID,
            groups: Set(WorkspaceToolGroup.allCases), readOnly: false, createdAt: Date())
        let connection = try issue(grant, endpoint: endpoint, persistent: false)
        sessionConnections[sessionID] = connection
        return .init(endpointURL: endpoint, bearerToken: connection.bearerToken, captureID: captureID, sessionID: sessionID)
    }

    func access(_ action: WovenMCPAccessAction, advertisedEndpoint: String? = nil) async throws -> WovenMCPAccessSnapshot {
        let localEndpoint = try await start()
        let endpoint = advertisedEndpoint ?? localEndpoint
        var issued: WovenMCPConnection?
        switch action {
        case .status: break
        case let .create(label, sessionID, groups, readOnly):
            let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.utf8.count <= 200, UUID(uuidString: sessionID) != nil, !groups.isEmpty else {
                throw WorkspaceToolError.invalid("Choose a label, an existing conversation and at least one tool group.")
            }
            let snapshot = try await database.companionSnapshot()
            guard snapshot.conversations.contains(where: { $0.id == sessionID }) else {
                throw WorkspaceToolError.notFound("The selected conversation is no longer available.")
            }
            try await database.requireMCPCaller(sessionID)
            let native = try await database.localACPSession(conversationID: sessionID)
            guard AgentRuntimeKind.allCases.contains(native.runtimeKind) else { throw WorkspaceToolError.invalid("Choose a currently supported harness conversation.") }
            _ = try await database.sessionTools(sessionID)
            let grant = WovenMCPClientGrant(id: UUID().uuidString.lowercased(), label: label, sessionID: sessionID,
                groups: groups, readOnly: readOnly, createdAt: Date())
            issued = try issue(grant, endpoint: endpoint, persistent: true)
            do { try save() } catch {
                credentials = credentials.filter { $0.value.grant.id != grant.id }; throw error
            }
        case .revoke(let id):
            let previous = credentials
            credentials = credentials.filter { $0.value.grant.id != id || !$0.value.persistent }
            do { try save() } catch { credentials = previous; throw error }
        }
        return .init(endpointURL: endpoint,
            clients: credentials.values.filter(\.persistent).map(\.grant).sorted { $0.createdAt < $1.createdAt },
            issuedConnection: issued)
    }

    /// nil allows the paired-device API to authenticate its separate credentials
    /// when both transports share the existing Tailscale HTTP listener.
    func handle(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse? {
        let path = URLComponents(string: "http://localhost" + request.target)?.path
        guard path == "/mcp" || path == "/wovenmatter/mcp" else { return nil }
        guard let token = request.bearer, var credential = credentials[Self.hash(token)] else { return nil }
        guard credential.persistent || Date().timeIntervalSince(credential.lastAliveAt) <= 24 * 60 * 60 else { return nil }
        credential.lastAliveAt = Date(); credentials[credential.tokenHash] = credential
        guard !credential.persistent || Date().timeIntervalSince(credential.grant.createdAt) < 30 * 24 * 60 * 60 else {
            return .error("credential_expired", "Create a new Woven MCP credential in Settings.", status: 401)
        }
        guard request.method == "POST" else {
            return .error("method_not_allowed", "Woven MCP accepts stateless JSON-RPC POST requests.", status: 405)
        }
        if let version = request.headers["mcp-protocol-version"], !WovenMCPServer.supportedProtocolVersions.contains(version) {
            return .error("protocol_version", "Unsupported MCP protocol version.", status: 400)
        }
        guard request.headers["origin"] == nil, request.body.count <= WovenMatterToolRequest.maximumHTMLRequestBytes else {
            return .error("invalid_request", "Invalid or oversized MCP request.", status: 400)
        }
        var rpcID: GatewayJSONValue = .null
        var decodedMessage = false
        do {
            let message = try JSONDecoder().decode(GatewayJSONValue.self, from: request.body)
            if request.body.count > 4 * 1_024 * 1_024 {
                guard message.objectValue?["method"] == .string("tools/call"),
                      ["woven_html_preview", "woven_html_render"].contains(message.objectValue?["params"]?.objectValue?["name"]?.stringValue ?? "") else {
                    throw WorkspaceToolError.invalid("The MCP request exceeds its size limit.")
                }
            }
            rpcID = message.objectValue?["id"] ?? .null
            decodedMessage = true
            let authorizedCredential = credential
            let grant = credential.grant
            try await database.requireMCPCaller(grant.sessionID)
            let current = try await database.sessionTools(grant.sessionID)
            let discovering = message.objectValue?["method"] == .string("tools/list")
            let allowed = Set(WovenMCPCatalog.tools.filter { tool in
                guard let group = tool.group, grant.groups.contains(group), !grant.readOnly || !tool.isMutation else { return false }
                // Native clients may cache discovery for their process lifetime.
                // Schema visibility follows the immutable credential ceiling;
                // current user policy still gates every tools/call below.
                if discovering { return true }
                // Explicit history attachments retain their own narrower checks.
                return current.enabled.contains(group) || group == .history || tool.name.hasSuffix("_cancel")
            }.map(\.name))
            let metadata = message.objectValue?["params"]?.objectValue?["_meta"]?.objectValue
            let contextID = credential.persistent ? nil : metadata?["wovenContextID"]?.stringValue ?? request.headers["x-woven-context-id"]
            if message.objectValue?["params"]?.objectValue?["name"] == .string("woven_context"),
               let contextID, !contextID.isEmpty { _ = try await database.inputContext(id: contextID, callerID: grant.sessionID) }
            let result = await WovenMCPServer.handle(message, contextID: contextID, allowedTools: allowed) { [weak self] call in
                guard let self else { return .init(success: false, error: "Woven MCP stopped.", code: "unavailable", requestID: call.requestID) }
                return await self.authorizedPerform(call, credential: authorizedCredential)
            }
            guard let result else { return .init(status: 202, body: Data()) }
            return try .json(result)
        } catch {
            return (try? .json(WovenMCPServer.error(id: rpcID, code: decodedMessage ? -32602 : -32700, message: error.localizedDescription)))
                ?? .error("invalid_request", "The MCP request could not be decoded.", status: 400)
        }
    }

    private func authorizedPerform(_ call: WovenMatterToolRequest, credential: Credential) async -> WovenMatterToolResponse {
        guard credentials[credential.tokenHash] != nil else {
            return .init(success: false, error: "This Woven MCP credential was revoked.", code: "unauthorized", requestID: call.requestID)
        }
        if credential.persistent, call.arguments == ["context"] {
            do { try await database.requireTool(.notes, sessionID: credential.grant.sessionID) }
            catch { return .init(success: false, error: error.localizedDescription, code: "tool_disabled", requestID: call.requestID) }
            return .init(result: .null, requestID: call.requestID)
        }
        return await perform(call, credential.grant.sessionID)
    }

    func revokeSession(_ sessionID: String) {
        sessionConnections.removeValue(forKey: sessionID)
        credentials = credentials.filter { $0.value.persistent || $0.value.grant.sessionID != sessionID }
    }

    func stop() {
        generation = UUID(); startTask?.cancel(); startTask = nil
        server?.stop(); server = nil; endpointURL = nil
        sessionConnections.removeAll(); credentials = credentials.filter { $0.value.persistent }
    }

    private func issue(_ grant: WovenMCPClientGrant, endpoint: String, persistent: Bool) throws -> WovenMCPConnection {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WorkspaceToolError.invalid("Woven could not create an MCP credential.")
        }
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let hash = Self.hash(token)
        credentials[hash] = .init(grant: grant, tokenHash: hash, persistent: persistent, lastAliveAt: Date())
        return .init(endpointURL: endpoint, bearerToken: token)
    }

    private func save() throws {
        let saved = SavedAccess(port: preferredPort, credentials: credentials.values.filter(\.persistent))
        try JSONEncoder().encode(saved).write(to: accessFile, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accessFile.path)
    }

    nonisolated private static func unauthorizedResponse() -> CompanionHTTPResponse {
        let body = Data("{\"error\":\"unauthorized\",\"message\":\"A valid Woven MCP bearer credential is required.\"}".utf8)
        return .init(status: 401, headers: ["WWW-Authenticate": "Bearer realm=\"woven\""], body: body)
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
