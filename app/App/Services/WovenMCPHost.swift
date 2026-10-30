import CryptoKit
import Foundation
import Network
import Security
import WovenMatterCore
import WovenMatterDashboardStore

enum WovenMCPAccessAction: Codable, Sendable {
    case status
    case setEnabled(Bool)
    case setGroup(WorkspaceToolGroup, enabled: Bool)
}

struct WovenMCPAccessSnapshot: Codable, Sendable {
    var endpointURL: String
    var settings: WorkspaceExternalMCPSettings
    var exposureError: String?
}

/// Native bearers identify conversation callers. The optional private Tailnet
/// endpoint resolves unauthenticated outside clients to the instance-wide policy.
/// Model arguments never choose the caller or change exposure settings.
@MainActor
final class WovenMCPHost {
    private struct Credential: Codable, Sendable {
        let sessionID: String
        let tokenHash: String
        var lastAliveAt: Date
    }
    private struct SavedAccess: Codable {
        var port: UInt16
        var httpsPort: Int?
    }
    private let exposure: CompanionTailscaleServe
    private var outsideEndpoint: String?
    private var exposureError: String?
    private var exposureTask: Task<Void, Never>?
    private var port: UInt16?
    private let database: WorkspaceDatabase
    private let accessFile: URL
    private let perform: @MainActor @Sendable (WovenMatterToolRequest, String) async -> WovenMatterToolResponse
    private var credentials: [String: Credential] = [:]
    private var sessionConnections: [String: WovenMCPConnection] = [:]
    private var server: CompanionHTTPServer?
    private var startTask: Task<String, any Error>?
    private var endpointURL: String?
    private var preferredPort: UInt16 = 0
    private var preferredHTTPSPort: Int?
    private var generation = UUID()

    init(database: WorkspaceDatabase, exposure: CompanionTailscaleServe = CompanionTailscaleServe(),
         perform: @escaping @MainActor @Sendable (WovenMatterToolRequest, String) async -> WovenMatterToolResponse) throws {
        self.database = database; self.perform = perform; self.exposure = exposure
        accessFile = database.supportDirectory.appending(path: "mcp-access.json")
        if FileManager.default.fileExists(atPath: accessFile.path) {
            let saved = try JSONDecoder().decode(SavedAccess.self, from: Data(contentsOf: accessFile))
            preferredPort = saved.port; preferredHTTPSPort = saved.httpsPort
        }
    }

    func start() async throws -> String {
        if let endpointURL { return endpointURL }
        if let startTask { return try await startTask.value }
        let expected = generation
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            func makeListener() -> CompanionHTTPServer {
                CompanionHTTPServer { [weak self] request in
                    guard let self else { return .error("unavailable", "Woven MCP stopped.", status: 503) }
                    return await self.handle(request, allowOutside: self.outsideEndpoint != nil) ?? Self.unauthorizedResponse()
                }
            }
            var listener = makeListener()
            self.server = listener
            do {
                let port: UInt16
                do {
                    port = try await listener.start(port: self.preferredPort)
                } catch NWError.posix(.EADDRINUSE) where self.preferredPort != 0 {
                    // A recently closed TCP connection can retain the saved port.
                    // Native credentials are reissued after restart. Outside
                    // clients use the separately advertised Tailnet endpoint. Keep exclusive
                    // binding and let the OS choose a free port instead.
                    listener.stop()
                    guard self.generation == expected, !Task.isCancelled else { throw CancellationError() }
                    listener = makeListener()
                    self.server = listener
                    port = try await listener.start()
                }
                guard self.generation == expected, !Task.isCancelled else { listener.stop(); throw CancellationError() }
                let endpoint = "http://127.0.0.1:\(port)/mcp"
                self.preferredPort = port; self.port = port; self.endpointURL = endpoint
                try self.save()
                self.startExposureMonitor()
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
        let connection = try issue(sessionID: sessionID, endpoint: endpoint)
        sessionConnections[sessionID] = connection
        return .init(endpointURL: endpoint, bearerToken: connection.bearerToken, captureID: captureID, sessionID: sessionID)
    }

    func access(_ action: WovenMCPAccessAction) async throws -> WovenMCPAccessSnapshot {
        let localEndpoint = try await start()
        switch action {
        case .status: break
        case .setEnabled(let enabled): try await database.updateExternalMCP(enabled: enabled)
        case let .setGroup(group, enabled): try await database.updateExternalMCP(group: group, groupEnabled: enabled)
        }
        let outside = try await database.toolSettings().externalMCP ?? .init()
        await refreshExposure()
        return .init(endpointURL: outsideEndpoint ?? localEndpoint, settings: outside, exposureError: exposureError)
    }

    private func startExposureMonitor() {
        guard exposureTask == nil else { return }
        exposureTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshExposure()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private var refreshingExposure = false
    private func refreshExposure() async {
        while refreshingExposure {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        }
        refreshingExposure = true
        defer { refreshingExposure = false }
        let expected = generation
        do {
            let enabled = try await database.toolSettings().externalMCP?.isEnabled == true
            guard generation == expected else { return }
            if !enabled {
                outsideEndpoint = nil; exposureError = nil; exposure.stop()
                return
            }
            guard outsideEndpoint == nil || !exposure.isRunning else { return }
            outsideEndpoint = nil; exposure.stop()
            try await exposure.waitUntilStopped()
            guard generation == expected, let port else { return }
            let address = try await exposure.start(loopbackPort: port, preferredHTTPSPort: preferredHTTPSPort)
            guard generation == expected, try await database.toolSettings().externalMCP?.isEnabled == true else {
                exposure.stop(); return
            }
            preferredHTTPSPort = address.port
            try save()
            outsideEndpoint = address.appending(path: "mcp").absoluteString
            exposureError = nil
        } catch {
            guard generation == expected else { return }
            exposure.stop(); outsideEndpoint = nil; exposureError = error.localizedDescription
        }
    }

    /// nil allows the paired-device API to authenticate its separate credentials
    /// when both transports share the existing Tailscale HTTP listener.
    func handle(_ request: CompanionHTTPRequest, allowOutside: Bool = false) async -> CompanionHTTPResponse? {
        let path = URLComponents(string: "http://localhost" + request.target)?.path
        guard path == "/mcp" || path == "/wovenmatter/mcp" else { return nil }
        let credential: Credential?
        let callerID: String
        if let token = request.bearer {
            guard var native = credentials[Self.hash(token)], Date().timeIntervalSince(native.lastAliveAt) <= 24 * 60 * 60 else { return nil }
            native.lastAliveAt = Date(); credentials[native.tokenHash] = native
            credential = native; callerID = native.sessionID
        } else {
            guard allowOutside else { return nil }
            guard (try? await database.toolSettings().externalMCP?.isEnabled) == true else {
                return .error("access_disabled", "Outside MCP access is disabled.", status: 403)
            }
            credential = nil; callerID = WovenMCPCaller.outside
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
            if credential != nil { try await database.requireMCPCaller(callerID) }
            let current = try await database.sessionTools(callerID)
            let discovering = message.objectValue?["method"] == .string("tools/list")
            let outside = callerID == WovenMCPCaller.outside
            let allowed = Set(WovenMCPCatalog.tools.filter { tool in
                guard let group = tool.group else { return false }
                if outside { return current.enabled.contains(group) }
                return discovering || current.enabled.contains(group) || group == .history || tool.name.hasSuffix("_cancel")
            }.map(\.name))
            let metadata = message.objectValue?["params"]?.objectValue?["_meta"]?.objectValue
            let contextID = outside ? nil : metadata?["wovenContextID"]?.stringValue ?? request.headers["x-woven-context-id"]
            if message.objectValue?["params"]?.objectValue?["name"] == .string("woven_context"),
               let contextID, !contextID.isEmpty { _ = try await database.inputContext(id: contextID, callerID: callerID) }
            let result = await WovenMCPServer.handle(message, contextID: contextID, allowedTools: allowed, outsideCaller: outside) { [weak self] call in
                guard let self else { return .init(success: false, error: "Woven MCP stopped.", code: "unavailable", requestID: call.requestID) }
                if let authorizedCredential { return await self.authorizedPerform(call, credential: authorizedCredential) }
                // Recheck settings after suspension and before service dispatch.
                do {
                    let command = try WovenMatterToolCommand(call.arguments)
                    let group = command.group ?? .notes
                    try await self.database.requireTool(group, sessionID: WovenMCPCaller.outside)
                    return await self.perform(call, WovenMCPCaller.outside)
                } catch { return .init(success: false, error: error.localizedDescription, code: "tool_disabled", requestID: call.requestID) }
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
        return await perform(call, credential.sessionID)
    }

    func revokeSession(_ sessionID: String) {
        sessionConnections.removeValue(forKey: sessionID)
        credentials = credentials.filter { $0.value.sessionID != sessionID }
    }

    func stop() {
        generation = UUID(); startTask?.cancel(); startTask = nil
        server?.stop(); server = nil; endpointURL = nil
        exposureTask?.cancel(); exposureTask = nil; exposure.stop(); outsideEndpoint = nil; port = nil
        sessionConnections.removeAll(); credentials.removeAll()
    }

    private func issue(sessionID: String, endpoint: String) throws -> WovenMCPConnection {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WorkspaceToolError.invalid("Woven could not create an MCP credential.")
        }
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let hash = Self.hash(token)
        credentials[hash] = .init(sessionID: sessionID, tokenHash: hash, lastAliveAt: Date())
        return .init(endpointURL: endpoint, bearerToken: token)
    }

    private func save() throws {
        let saved = SavedAccess(port: preferredPort, httpsPort: preferredHTTPSPort)
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
