import CryptoKit
import Foundation
import Network
import Security
import WovenMatterCore
import WovenMatterDashboardStore

enum WovenMCPAccessAction: Codable, Sendable {
    case status
    case setBotsEnabled(Bool)
    case setBotsGroup(WorkspaceToolGroup, enabled: Bool)
    case setEnabled(Bool)
    case setGroup(WorkspaceToolGroup, enabled: Bool)
}

struct WovenMCPAccessSnapshot: Codable, Sendable {
    var endpointURL: String
    var botSettings: WorkspaceExternalMCPSettings
    var settings: WorkspaceExternalMCPSettings
    var exposureError: String?
}

struct WovenBotMCPGrant: Sendable {
    let endpointURL: String
    let bearerToken: String
}

struct WovenBotNotification: Sendable {
    let id: String
    let machineID: String
    let botID: String
    let text: String
}

enum WovenBotKeyError: LocalizedError {
    case revoked
    var errorDescription: String? { "This bot's Woven MCP key was revoked in Settings → Woven MCP." }
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
        /// Bot caller ID to the SHA-256 digest of its key. Plaintext never rests here.
        var botKeys: [String: String]?
    }
    private var botKeys: [String: String] = [:]
    private var revocationTask: Task<Void, any Error>?
    private var botDispatches: [UUID: (callerID: String, fence: AgentDispatchFence)] = [:]
    var botNotificationSink: (@MainActor (WovenBotNotification) async throws -> Void)?
    private let exposure: TailscaleServe
    private var outsideEndpoint: String?
    private var exposureError: String?
    private var exposureTask: Task<Void, Never>?
    private var port: UInt16?
    private let database: WorkspaceDatabase
    private let accessFile: URL
    private let perform: @MainActor @Sendable (WovenMatterToolRequest, String) async -> WovenMatterToolResponse
    private var credentials: [String: Credential] = [:]
    private var sessionConnections: [String: WovenMCPConnection] = [:]
    private var server: LibraryHTTPServer?
    private var startTask: Task<String, any Error>?
    private var endpointURL: String?
    private var preferredPort: UInt16 = 0
    private var preferredHTTPSPort: Int?
    private var generation = UUID()

    init(database: WorkspaceDatabase, exposure: TailscaleServe = TailscaleServe(),
         perform: @escaping @MainActor @Sendable (WovenMatterToolRequest, String) async -> WovenMatterToolResponse) throws {
        self.database = database; self.perform = perform; self.exposure = exposure
        accessFile = database.supportDirectory.appending(path: "mcp-access.json")
        if FileManager.default.fileExists(atPath: accessFile.path) {
            let saved = try JSONDecoder().decode(SavedAccess.self, from: Data(contentsOf: accessFile))
            preferredPort = saved.port; preferredHTTPSPort = saved.httpsPort
            botKeys = saved.botKeys ?? [:]
        }
    }

    func start() async throws -> String {
        if let endpointURL { return endpointURL }
        if let startTask { return try await startTask.value }
        let expected = generation
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            func makeListener() -> LibraryHTTPServer {
                LibraryHTTPServer { [weak self] request in
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

    /// Issues a new key for one bot of the runtime on `machineID`, replacing any
    /// previous key. A bot the user revoked stays revoked until reinstated.
    func issueBotKey(machineID: String, botID: String, botName: String) async throws -> WovenBotMCPGrant {
        guard WovenMCPCaller.isIdentifier(machineID), WovenMCPCaller.isIdentifier(botID) else {
            throw WorkspaceToolError.invalid("Invalid bot or machine ID.")
        }
        let callerID = WovenMCPCaller.bot(machineID: machineID, botID: botID)
        try await revocationTask?.value
        if try await database.botCallers().contains(where: { $0.callerID == callerID && $0.revoked }) { throw WovenBotKeyError.revoked }
        let endpoint = try await start()
        try await database.registerBotCaller(callerID, displayName: Self.botName(botName))
        let token = try Self.randomToken()
        let previous = botKeys[callerID]
        botKeys[callerID] = Self.hash(token)
        do { try save() } catch { botKeys[callerID] = previous; throw error }
        return .init(endpointURL: endpoint, bearerToken: token)
    }

    /// Drops a bot's key. `sticky` is the user's revoke: the runtime cannot get a new
    /// key until the user reinstates it. Otherwise the bot was deleted by its runtime.
    func revokeBotKey(callerID: String, sticky: Bool) {
        guard WovenMCPCaller.parseBot(callerID) != nil else { return }
        botKeys.removeValue(forKey: callerID)
        cancelBotDispatches { $0 == callerID }
        let database = database
        queueRevocation(saving: true) {
            if sticky { try await database.revokeBotCaller(callerID) }
            else { try await database.retireBotCaller(callerID) }
        }
    }

    func reinstateBot(callerID: String) async throws {
        try await revocationTask?.value
        try await database.reinstateBotCaller(callerID)
    }

    /// Pause stops every bot on `machineID` from calling; their keys stay and work again on resume.
    func setBotsPaused(machineID: String, paused: Bool) async throws {
        if paused { cancelBotDispatches { WovenMCPCaller.parseBot($0)?.machineID == machineID.lowercased() } }
        let database = database
        queueRevocation(saving: false) { try await database.setBotMachine(machineID, active: !paused) }
        try await revocationTask?.value
    }

    private func cancelBotDispatches(_ matches: (String) -> Bool) {
        for (id, dispatch) in botDispatches where matches(dispatch.callerID) {
            dispatch.fence.cancel()
            botDispatches.removeValue(forKey: id)
        }
    }

    /// Revocations apply in order, and every later bot request waits for them.
    private func queueRevocation(saving: Bool, _ work: @escaping @Sendable () async throws -> Void) {
        let previous = revocationTask
        let saveError: (any Error)?
        if saving { do { try save(); saveError = nil } catch { saveError = error } } else { saveError = nil }
        revocationTask = Task {
            _ = try? await previous?.value
            try await work()
            if let saveError { throw saveError }
        }
    }

    func trackBotDispatch(callerID: String, fence: AgentDispatchFence) throws -> UUID? {
        guard WovenMCPCaller.parseBot(callerID) != nil else { return nil }
        guard botKeys[callerID] != nil else {
            throw WorkspaceToolError.invalid("This bot's Woven MCP key was revoked.")
        }
        let id = UUID()
        botDispatches[id] = (callerID, fence)
        return id
    }

    func finishBotDispatch(_ id: UUID?) {
        if let id { botDispatches.removeValue(forKey: id) }
    }

    func deliverBotNotification(_ delivery: WorkspaceSessionDelivery) async throws -> Bool {
        // A bot's own timers are its schedules: they come back to it as messages.
        guard [.notification, .message, .timer].contains(delivery.kind), let bot = WovenMCPCaller.parseBot(delivery.targetID) else { return false }
        try await revocationTask?.value
        guard let claimed = try await database.claimToolDelivery(id: delivery.id) else { return true }
        do {
            try await database.validateClaimedToolDelivery(id: claimed.id)
            guard botKeys[delivery.targetID] != nil, let botNotificationSink else {
                throw WorkspaceToolError.invalid("The bot runtime is unavailable.")
            }
            // The stable delivery ID is the receiver's idempotency key, including
            // an acknowledgement lost after the receiver durably accepted it.
            try await botNotificationSink(.init(id: claimed.id, machineID: bot.machineID, botID: bot.botID, text: claimed.text))
            try await database.setToolDeliveryStatus(id: claimed.id, status: "accepted")
        } catch {
            try await database.failToolDeliveryAttempt(id: claimed.id)
            throw error
        }
        return true
    }

    func access(_ action: WovenMCPAccessAction) async throws -> WovenMCPAccessSnapshot {
        try await revocationTask?.value
        let localEndpoint = try await start()
        switch action {
        case .status: break
        case .setBotsEnabled(let enabled): try await database.updateBotMCP(enabled: enabled)
        case let .setBotsGroup(group, enabled): try await database.updateBotMCP(group: group, groupEnabled: enabled)
        case .setEnabled(let enabled): try await database.updateExternalMCP(enabled: enabled)
        case let .setGroup(group, enabled): try await database.updateExternalMCP(group: group, groupEnabled: enabled)
        }
        let outside = try await database.toolSettings().externalMCP ?? .init()
        await refreshExposure()
        return .init(endpointURL: outsideEndpoint ?? localEndpoint, botSettings: try await database.toolSettings().botMCP, settings: outside, exposureError: exposureError)
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
            let address = try await exposure.start(loopbackPort: port, preferredHTTPSPort: preferredHTTPSPort, allowPortFallback: true)
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
    func handle(_ request: LibraryHTTPRequest, allowOutside: Bool = false) async -> LibraryHTTPResponse? {
        let path = URLComponents(string: "http://localhost" + request.target)?.path
        guard path == "/mcp" || path == "/wovenmatter/mcp" else { return nil }
        let credential: Credential?
        var botAuthorization: String?
        let callerID: String
        if let token = request.bearer {
            let digest = Self.hash(token)
            // The key alone names the bot; attribution comes from its registration.
            if let bot = botKeys.first(where: { $0.value == digest })?.key {
                callerID = bot
                credential = nil
                botAuthorization = digest
            } else {
                guard var native = credentials[digest], Date().timeIntervalSince(native.lastAliveAt) <= 24 * 60 * 60 else { return nil }
                native.lastAliveAt = Date(); credentials[native.tokenHash] = native
                credential = native; callerID = native.sessionID
            }
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
            let authorizedBot = botAuthorization
            if let authorizedBot {
                try await revocationTask?.value
                guard botKeys[callerID] == authorizedBot else { return Self.unauthorizedResponse() }
            }
            if credential != nil { try await database.requireMCPCaller(callerID) }
            let current = try await database.sessionTools(callerID)
            let discovering = message.objectValue?["method"] == .string("tools/list")
            let outside = WovenMCPCaller.isAppWide(callerID)
            let allowed = Set(WovenMCPCatalog.tools.filter { tool in
                guard let group = tool.group else { return false }
                if outside { return current.enabled.contains(group) }
                return discovering || current.enabled.contains(group) || group == .history || tool.name.hasSuffix("_cancel")
            }.map(\.name))
            let metadata = message.objectValue?["params"]?.objectValue?["_meta"]?.objectValue
            let contextID = outside ? nil : metadata?["wovenContextID"]?.stringValue ?? request.headers["x-woven-context-id"]
            if message.objectValue?["params"]?.objectValue?["name"] == .string("woven_context"),
               let contextID, !contextID.isEmpty { _ = try await database.inputContext(id: contextID, callerID: callerID) }
            let result = await WovenMCPServer.handle(message, contextID: contextID, allowedTools: allowed, outsideCaller: outside,
                                                       botCaller: WovenMCPCaller.parseBot(callerID) != nil) { [weak self] call in
                guard let self else { return .init(success: false, error: "Woven MCP stopped.", code: "unavailable", requestID: call.requestID) }
                if let authorizedCredential { return await self.authorizedPerform(call, credential: authorizedCredential) }
                return await self.authorizedAppWidePerform(call, callerID: callerID, botKeyHash: authorizedBot)
            }
            guard let result else { return .init(status: 202, body: Data()) }
            return try .json(result)
        } catch {
            return (try? .json(WovenMCPServer.error(id: rpcID, code: decodedMessage ? -32602 : -32700, message: error.localizedDescription)))
                ?? .error("invalid_request", "The MCP request could not be decoded.", status: 400)
        }
    }

    private func authorizedAppWidePerform(_ call: WovenMatterToolRequest, callerID: String,
                                           botKeyHash: String?) async -> WovenMatterToolResponse {
        do {
            if let botKeyHash, botKeys[callerID] != botKeyHash {
                return .init(success: false, error: "This bot's key was revoked.", code: "unauthorized", requestID: call.requestID)
            }
            let command = try WovenMatterToolCommand(call.arguments)
            try await database.requireTool(command.group ?? .notes, sessionID: callerID)
            if let botKeyHash, botKeys[callerID] != botKeyHash {
                return .init(success: false, error: "This bot's key was revoked.", code: "unauthorized", requestID: call.requestID)
            }
            return await perform(call, callerID)
        } catch { return .init(success: false, error: error.localizedDescription, code: "tool_disabled", requestID: call.requestID) }
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
        for dispatch in botDispatches.values { dispatch.fence.cancel() }
        botDispatches.removeAll()
        generation = UUID(); startTask?.cancel(); startTask = nil
        server?.stop(); server = nil; endpointURL = nil
        exposureTask?.cancel(); exposureTask = nil; exposure.stop(); outsideEndpoint = nil; port = nil
        sessionConnections.removeAll(); credentials.removeAll()
    }

    private func issue(sessionID: String, endpoint: String) throws -> WovenMCPConnection {
        let token = try Self.randomToken()
        let hash = Self.hash(token)
        credentials[hash] = .init(sessionID: sessionID, tokenHash: hash, lastAliveAt: Date())
        return .init(endpointURL: endpoint, bearerToken: token)
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WorkspaceToolError.invalid("Woven could not create an MCP credential.")
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Names arrive from the runtime; keep them short and free of controls and bidi overrides.
    static func botName(_ raw: String?) -> String {
        let decoded = raw.map { String(decoding: $0.utf8.prefix(4_096), as: UTF8.self) } ?? "Bot"
        let scalars = decoded.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) }
        let name = String(String.UnicodeScalarView(scalars.prefix(128))).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Bot" : name
    }

    private func save() throws {
        let saved = SavedAccess(port: preferredPort, httpsPort: preferredHTTPSPort, botKeys: botKeys)
        try JSONEncoder().encode(saved).write(to: accessFile, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accessFile.path)
    }

    nonisolated private static func unauthorizedResponse() -> LibraryHTTPResponse {
        let body = Data("{\"error\":\"unauthorized\",\"message\":\"A valid Woven MCP bearer credential is required.\"}".utf8)
        return .init(status: 401, headers: ["WWW-Authenticate": "Bearer realm=\"woven\""], body: body)
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).hexString
    }
}
