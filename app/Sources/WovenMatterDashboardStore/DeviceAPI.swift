import Foundation
import WovenMatterCore

private struct MCPMalformedJSON: Error {}

@MainActor
public protocol DeviceCommandServing: AnyObject {
    func executeTool(_ request: LibraryToolRequest, deviceID: String) async throws -> WovenMatterToolResponse
    func registerExecutionManagement(_ grant: ExecutionManagementGrant, device: PairedDevice) async throws -> ExecutionWorkspace
    func provisionExecutionWorkspace(id: String, device: PairedDevice) async throws -> ExecutionCredential
    func readWorkspace(_ request: LibraryWorkspaceRead) async throws -> LibraryWorkspaceResult
    func analyticsPreference() async throws -> ProductAnalyticsPreference
    func setAnalyticsPreference(_ change: ProductAnalyticsPreferenceChange) async throws -> ProductAnalyticsPreference
    func ingestAnalytics(_ batch: ProductAnalyticsBatch) async throws -> ProductAnalyticsAcknowledgement
    func providers() -> [HarnessCapabilities]
    func pendingInteractions() async -> [PendingInteraction]
    func sessionCapabilities(conversationID: String) async throws -> HarnessCapabilities
    func transcript(conversationID: String, before: String?) async throws -> LibraryTranscript
    func receipt(commandID: String, deviceID: String) async throws -> LibraryCommandReceipt?
    func execute(_ command: LibraryCommand, deviceID: String) async throws -> LibraryCommandReceipt
}

private extension DeviceAPI {
    func mcpInput(_ request: LibraryHTTPRequest) throws -> (GatewayJSONValue, String, [WorkspaceToolGroup], String?) {
        guard request.method == "POST" else {
            throw LibraryAPIError(code: "method_not_allowed", message: "Woven MCP uses HTTP POST for JSON-RPC requests.")
        }
        guard request.body.count <= WovenMatterToolRequest.maximumHTMLRequestBytes else {
            throw LibraryAPIError(code: "too_large", message: "The MCP request exceeds its size limit.")
        }
        guard request.headers["origin"] == nil else {
            throw LibraryAPIError(code: "invalid_origin", message: "Browser-origin MCP requests are unavailable on this device route.")
        }
        if let version = request.headers["mcp-protocol-version"], !WovenMCPServer.supportedProtocolVersions.contains(version) {
            throw LibraryAPIError(code: "invalid_request", message: "The requested MCP protocol version is unsupported.")
        }
        guard let conversationID = request.headers["x-woven-conversation-id"], UUID(uuidString: conversationID) != nil,
              let rawGroups = request.headers["x-woven-enabled-groups"], rawGroups.utf8.count <= 512 else {
            throw LibraryAPIError(code: "invalid_request", message: "MCP requires a native conversation binding and current tool selection.")
        }
        let names = rawGroups.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        let groups = names.compactMap(WorkspaceToolGroup.init(rawValue:))
        guard groups.count == names.count else {
            throw LibraryAPIError(code: "invalid_request", message: "An unknown tool group was selected.")
        }
        let message: GatewayJSONValue
        do { message = try JSONDecoder().decode(GatewayJSONValue.self, from: request.body) }
        catch { throw MCPMalformedJSON() }
        guard request.body.count <= WovenMCPServer.maximumRequestBytes(for: message) else {
            throw LibraryAPIError(code: "too_large", message: "The MCP request exceeds its size limit.")
        }
        let capture = request.headers["x-woven-context-id"]
            ?? message.objectValue?["params"]?.objectValue?["_meta"]?.objectValue?["wovenContextID"]?.stringValue
        guard (capture?.utf8.count ?? 0) <= 128 else {
            throw LibraryAPIError(code: "invalid_request", message: "The input context is invalid.")
        }
        return (message, conversationID.lowercased(), Array(Set(groups)), capture)
    }

    func mcpTools(groups: [WorkspaceToolGroup]) -> Set<String> {
        let enabled = Set(groups)
        return Set(WovenMCPCatalog.tools.filter { tool in
            tool.name == "woven_context" || tool.name.hasSuffix("_cancel") && tool.group?.isAutomation == true
                || tool.group.map { enabled.contains($0) } == true
        }.map(\.name))
    }

    func handleDeviceMCP(_ request: LibraryHTTPRequest, device: PairedDevice) async throws -> LibraryHTTPResponse {
        let (message, conversationID, groups, captureID) = try mcpInput(request)
        guard let workspace = try await database.libraryConversationExecutionWorkspace(conversationID: conversationID),
              workspace.kind == .ios || workspace.kind == .mac else {
            throw LibraryAPIError(code: "wrong_owner", message: "A paired-device MCP connection cannot impersonate a Linux execution workspace.")
        }
        // Even schema discovery needs a real, live conversation owned by this
        // paired device. A pasted conversation UUID is never a new grant.
        let identity = LibraryToolRequest(conversationID: conversationID,
            request: .init(arguments: ["context"]), enabledGroups: groups)
        try await database.authorizeLibraryTool(identity, deviceID: device.id)
        let result = await WovenMCPServer.handle(message, contextID: captureID, allowedTools: mcpTools(groups: groups)) { call in
            await self.performMCP(call, conversationID: conversationID, groups: groups, device: device)
        }
        guard isActive(), await isCurrent(device) else {
            return .error("unauthorized", "This paired device's MCP access has stopped.", status: 401)
        }
        guard let result else { return .init(status: 202, body: Data()) }
        return try .json(result)
    }

    func performMCP(_ call: WovenMatterToolRequest, conversationID: String, groups: [WorkspaceToolGroup],
                    device: PairedDevice) async -> WovenMatterToolResponse {
        do {
            guard isActive(), await isCurrent(device) else {
                throw LibraryAPIError(code: "unauthorized", message: "This paired device's MCP access was revoked.")
            }
            let request = LibraryToolRequest(conversationID: conversationID, request: call, enabledGroups: groups)
            try await database.authorizeLibraryTool(request, deviceID: device.id)
            let response = try await commands.executeTool(request, deviceID: device.id)
            if response.success { onMutation() }
            return response.bounded()
        } catch let error as LibraryAPIError {
            return .init(success: false, error: error.message, code: error.code, requestID: call.requestID)
        } catch {
            return .init(success: false, error: error.localizedDescription, code: "tool_unavailable", requestID: call.requestID)
        }
    }

    /// The caller of `/mcp/workspace`: a signed request from the Linux member
    /// that executes the workspace named by `X-Woven-Workspace-ID`.
    /// `current` re-checks it during and after a long call.
    struct WorkspaceMCPCaller: Sendable {
        let principal: ExecutionWorkspaceMCPPrincipal
        let current: @Sendable () async throws -> ExecutionWorkspaceMCPPrincipal
    }
    func authenticateWorkspaceMCP(_ request: LibraryHTTPRequest) async throws -> Result<WorkspaceMCPCaller, LibraryAPIError> {
        guard MemberRequestVerifier.isSigned(request.headers) else {
            return .failure(.init(code: "unauthorized", message: "Only a signed Linux member may call this route."))
        }
        guard let members else { return .failure(.init(code: "unauthorized", message: "This Mac does not accept member requests yet.")) }
        let key: MemberKey
        do {
            key = try await members.verifier.verify(method: request.method, target: request.target, headers: request.headers,
                                                    body: request.body, allowing: [.linux])
        } catch let error as MemberRequestError { return .failure(.init(code: error.code, message: error.message)) }
        guard let workspaceID = request.headers["x-woven-workspace-id"]?.lowercased() else {
            return .failure(.init(code: "invalid_request", message: "Name the Linux workspace in X-Woven-Workspace-ID."))
        }
        let database = database
        let current: @Sendable () async throws -> ExecutionWorkspaceMCPPrincipal = {
            guard await members.member(key.deviceID) != nil else { throw LibraryAPIError(code: "unauthorized", message: MemberRequestError.unknown.message) }
            // Any Mac checks the same synced rows: the registry and the member list.
            let workspace = try await database.libraryExecutionWorkspaces().first { $0.id == workspaceID }
            let serving = if let workspace { await members.audience(for: workspace) } else { String?.none }
            return try await database.executionWorkspaceMCPMember(workspaceID: workspaceID, deviceID: key.deviceID, serving: serving)
        }
        return .success(.init(principal: try await current(), current: current))
    }

    func handleWorkspaceMCP(_ request: LibraryHTTPRequest) async throws -> LibraryHTTPResponse {
        guard request.headers["x-woven-protocol"] == String(LibraryProtocol.version) else {
            return .error("version_mismatch", "Update Woven Matter on both devices.", status: 426)
        }
        let caller: WorkspaceMCPCaller
        switch try await authenticateWorkspaceMCP(request) {
        case .success(let value): caller = value
        case .failure(let error): return .error(error.code, error.message, status: error.code == "library_mismatch" ? 409 : 401)
        }
        let principal = caller.principal
        let (message, conversationID, groups, captureID) = try mcpInput(request)
        try await database.authorizeExecutionWorkspaceMCPCaller(conversationID: conversationID, principal: principal)
        let result = await WovenMCPServer.handle(message, contextID: captureID, allowedTools: mcpTools(groups: groups)) { call in
            await self.performWorkspaceMCP(call, conversationID: conversationID, groups: groups, caller: caller)
        }
        guard isActive() else { return .error("unavailable", "The library MCP host stopped.", status: 503) }
        _ = try await caller.current()
        guard let result else { return .init(status: 202, body: Data()) }
        return try .json(result)
    }

    func prepareWorkspaceMCP(_ request: LibraryHTTPRequest) async throws -> LibraryHTTPResponse {
        guard request.method == "POST" else { return .error("method_not_allowed", "Scheduled caller registration uses POST.", status: 405) }
        guard request.headers["x-woven-protocol"] == String(LibraryProtocol.version) else { return .error("version_mismatch", "Update the execution workspace to a compatible version.", status: 426) }
        guard request.body.count <= 1_048_576 else { return .error("too_large", "The scheduled caller registration exceeds 1 MiB.", status: 413) }
        let caller: WorkspaceMCPCaller
        switch try await authenticateWorkspaceMCP(request) {
        case .success(let value): caller = value
        case .failure(let error): return .error(error.code, error.message, status: error.code == "library_mismatch" ? 409 : 401)
        }
        let principal = caller.principal
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = WorkspaceDatabaseConnection.date(value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "An ISO-8601 schedule timestamp is required."))
            }
            return date
        }
        let preparation = try decoder.decode(ScheduledMCPPreparation.self, from: request.body)
        let enabled = try await database.prepareLibraryScheduledMCP(preparation, principal: principal)
        guard isActive() else { return .error("unavailable", "The library MCP host stopped.", status: 503) }
        _ = try await caller.current()
        onMutation()
        return try .json(["enabledGroups": enabled.map(\.rawValue)])
    }

    func performWorkspaceMCP(_ call: WovenMatterToolRequest, conversationID: String, groups: [WorkspaceToolGroup],
                             caller: WorkspaceMCPCaller) async -> WovenMatterToolResponse {
        do {
            guard isActive() else { throw LibraryAPIError(code: "unavailable", message: "The library MCP host stopped.") }
            let current = try await caller.current()
            try await database.authorizeExecutionWorkspaceMCPCaller(conversationID: conversationID, principal: current)
            let request = LibraryToolRequest(conversationID: conversationID, request: call, enabledGroups: groups)
            try await database.authorizeLibraryTool(request, deviceID: current.executionDeviceID)
            let response = try await commands.executeTool(request, deviceID: current.executionDeviceID)
            if response.success { onMutation() }
            return response.bounded()
        } catch let error as LibraryAPIError {
            return .init(success: false, error: error.message, code: error.code, requestID: call.requestID)
        } catch {
            return .init(success: false, error: error.localizedDescription, code: "tool_unavailable", requestID: call.requestID)
        }
    }
}

public extension DeviceCommandServing {
    func analyticsPreference() async throws -> ProductAnalyticsPreference { throw LibraryAPIError(code:"unsupported",message:"Update the central Mac to configure analytics.") }
    func setAnalyticsPreference(_ change: ProductAnalyticsPreferenceChange) async throws -> ProductAnalyticsPreference { throw LibraryAPIError(code:"unsupported",message:"Update the central Mac to configure analytics.") }
    func ingestAnalytics(_ batch: ProductAnalyticsBatch) async throws -> ProductAnalyticsAcknowledgement { throw LibraryAPIError(code:"unsupported",message:"Update the central Mac to configure analytics.") }

    func executeTool(_ request: LibraryToolRequest, deviceID: String) async throws -> WovenMatterToolResponse {
        throw LibraryAPIError(code: "unsupported", message: "Update the central Mac to use its tools from this device.")
    }
    func registerExecutionManagement(_ grant: ExecutionManagementGrant, device: PairedDevice) async throws -> ExecutionWorkspace {
        throw LibraryAPIError(code: "unsupported", message: "This host does not accept secondary execution management grants.")
    }
    func provisionExecutionWorkspace(id: String, device: PairedDevice) async throws -> ExecutionCredential {
        throw LibraryAPIError(code: "unsupported", message: "This host does not provision independent execution workspaces.")
    }
    func readWorkspace(_ request: LibraryWorkspaceRead) async throws -> LibraryWorkspaceResult {
        throw LibraryAPIError(code: "unsupported", message: "Update your Mac to use this feature.")
    }
}

/// One authenticated, workspace-bound API per serving attempt. The activity
/// predicate captures that attempt, so a delayed request cannot cross stop/restart.
@MainActor
public final class DeviceAPI {
    private let database: WorkspaceDatabase
    private let authentication: DeviceAuthentication
    private let commands: any DeviceCommandServing
    private let isActive: @MainActor @Sendable () -> Bool
    private let onCancelPairing: @MainActor @Sendable (PairedDevice) async throws -> Void
    private let discovery: @MainActor @Sendable () -> DiscoveryAdvertisement?
    private let onPair: @MainActor @Sendable () async -> Void
    private let onMutation: @MainActor @Sendable () -> Void
    private let onRequest: @MainActor @Sendable () -> Void
    private let linkedData: @MainActor @Sendable (DatabaseArtifactLink) async throws -> DatabaseTabularData
    private var linkedReadInFlight = false
    /// Signed member requests (any Mac or Linux library host). A phone or Mac
    /// member is authenticated by its signature; no grant is issued.
    private let members: MemberDirectory?
    /// A phone paired with its member key: the host signs its member entry
    /// (replacing an earlier key the user is pairing again). Throws to refuse.
    private let onMemberPaired: @MainActor @Sendable (_ deviceID: String, _ name: String, _ publicKey: Data) async throws -> Void
    /// `GET /v1/sync/status`: every peer's state, so a phone can show
    /// "Update everything" when devices disagree on versions.
    private let syncStatus: @MainActor @Sendable () async -> LibrarySyncStatus?
    /// The name `GET /v1/hello` reports; nil falls back to this machine's name.
    private let hostName: @MainActor @Sendable () async -> String?
    public init(database: WorkspaceDatabase, authentication: DeviceAuthentication,
                commands: any DeviceCommandServing,
                isActive: @escaping @MainActor @Sendable () -> Bool,
                onCancelPairing: @escaping @MainActor @Sendable (PairedDevice) async throws -> Void = { _ in
                    throw LibraryAPIError(code: "unavailable", message: "Revoke this device from the central Mac settings.")
                },
                discovery: @escaping @MainActor @Sendable () -> DiscoveryAdvertisement? = { nil },
                onPair: @escaping @MainActor @Sendable () async -> Void = {},
                onMutation: @escaping @MainActor @Sendable () -> Void = {},
                onRequest: @escaping @MainActor @Sendable () -> Void = {},
                linkedData: @escaping @MainActor @Sendable (DatabaseArtifactLink) async throws -> DatabaseTabularData = { _ in
                    throw LibraryAPIError(code: "linked_data_unavailable", message: "This database is unavailable on the Mac.")
                }, members: MemberDirectory? = nil,
                onMemberPaired: @escaping @MainActor @Sendable (String, String, Data) async throws -> Void = { _, _, _ in },
                syncStatus: @escaping @MainActor @Sendable () async -> LibrarySyncStatus? = { nil },
                hostName: @escaping @MainActor @Sendable () async -> String? = { nil }) {
        self.hostName = hostName
        self.members = members; self.onMemberPaired = onMemberPaired; self.syncStatus = syncStatus
        self.database = database; self.authentication = authentication; self.commands = commands
        self.isActive = isActive; self.onPair = onPair; self.onMutation = onMutation; self.onRequest = onRequest
        self.linkedData = linkedData; self.discovery = discovery; self.onCancelPairing = onCancelPairing
    }

    /// The Mac's user-facing computer name; Linux Foundation has none, so
    /// other platforms report the host name.
    static var machineName: String {
        #if os(macOS)
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }

    /// A long request re-checks its principal: a grant must still be issued,
    /// a member must still be on the member list.
    func isCurrent(_ device: PairedDevice) async -> Bool {
        if device.isMember { return await members?.member(device.id) != nil }
        return await authentication.isCurrent(device)
    }
    func reauthenticate(_ device: PairedDevice, bearer: String) async throws {
        if device.isMember {
            guard await members?.member(device.id) != nil else { throw LibraryAPIError(code: "unauthorized", message: MemberRequestError.unknown.message) }
        } else { _ = try await authentication.authenticate(bearer: bearer) }
    }

    public func handle(_ request: LibraryHTTPRequest) async -> LibraryHTTPResponse {
        guard isActive() else { return .error("unavailable", "Sharing with devices is stopped.", status: 503) }
        do {
            guard let target = URLComponents(string: "http://localhost" + request.target) else {
                return .error("invalid_request", "Invalid request path.", status: 400)
            }
            var path = target.path
            if path.hasPrefix("/wovenmatter/") { path = String(path.dropFirst("/wovenmatter".count)) }
            let workspaceID = try await database.libraryID()
            if path == "/v1/discovery", request.method == "GET", let advertisement = discovery() {
                return try .json(advertisement)
            }
            if path == "/mcp/workspace/prepare" {
                return try await prepareWorkspaceMCP(request)
            }
            if path == "/mcp/workspace" {
                return try await handleWorkspaceMCP(request)
            }
            if path == "/v1/pairing/request", request.method == "POST" {
                guard request.body.count <= 8_192 else { return .error("too_large", "The pairing request is too large.", status: 413) }
                let pending = try JSONDecoder().decode(PairingApprovalRequest.self, from: request.body)
                let result = try await authentication.requestPairing(pending, workspaceID: workspaceID)
                return try .json(result)
            }
            if path == "/v1/pairing/result", request.method == "POST" {
                guard request.body.count <= 1_024 else { return .error("too_large", "The pairing request is too large.", status: 413) }
                let poll = try JSONDecoder().decode(PairingPoll.self, from: request.body)
                return try .json(try await authentication.pairingResult(poll))
            }
            if path == "/v1/pairing/cancel", request.method == "POST" {
                guard request.body.count <= 1_024 else { return .error("too_large", "The pairing request is too large.", status: 413) }
                let poll = try JSONDecoder().decode(PairingPoll.self, from: request.body)
                if let principal = try await authentication.preparePairingCancellation(poll) {
                    try await onCancelPairing(principal)
                }
                try await authentication.cancelPairing(poll)
                await onPair()
                return try .json(["cancelled": true])
            }
            if request.method == "POST", path == "/v1/pair/preview" {
                guard request.body.count <= 8_192 else { return .error("too_large", "The pairing request is too large.", status: 413) }
                let command = try JSONDecoder().decode(PairRequest.self, from: request.body)
                return try .json(try await authentication.previewPairing(command, workspaceID: workspaceID))
            }
            if request.method == "POST", path == "/v1/pair/confirm" {
                guard request.headers["x-woven-protocol"] == String(LibraryProtocol.version),
                    request.headers["x-woven-workspace"] == workspaceID, let bearer = request.bearer else {
                    return .error("unauthorized", "Complete pairing on this device.", status: 401)
                }
                // The phone's member entry is signed when its pairing is
                // confirmed, before the grant is issued, so a pairing that is
                // never confirmed adds no member and a refusal reaches the phone.
                if members != nil, let pending = await authentication.pendingPhoneMember(bearer: bearer, workspaceID: workspaceID) {
                    do { try await onMemberPaired(pending.deviceID, pending.name, pending.publicKey) }
                    catch let error as LibraryAPIError { return .error(error.code, error.message, status: 409) }
                }
                try await authentication.confirmPairing(bearer: bearer, workspaceID: workspaceID)
                await onPair()
                return try .json(["confirmed": true])
            }
            if request.method == "POST", path == "/v1/pair" {
                guard request.body.count <= 8_192 else { return .error("too_large", "The pairing request is too large.", status: 413) }
                let command = try JSONDecoder().decode(PairRequest.self, from: request.body)
                let memberKey = command.memberPublicKey.flatMap { key in
                    key.count == 32 && command.purpose != PairingPurpose.peerMac
                        && [.iPhone, .iPad].contains(command.metadata?.kind ?? .unknown) ? key : nil
                }
                // Refuse before the pairing code is spent when this Mac could
                // not add the phone with that key.
                if let members, let memberKey {
                    do { try await members.checkAdd(deviceID: command.deviceID, kind: .ios, publicKey: memberKey, replacingKey: true) }
                    catch let error as LibraryAPIError { return .error(error.code, error.message, status: 409) }
                }
                var result = try await authentication.pair(command, workspaceID: workspaceID)
                if let members {
                    result.hostDeviceID = members.identity.deviceID
                    // Whether the phone's current library is one this Mac
                    // shares, decided before any signed request can work.
                    if memberKey != nil {
                        result.libraryIDs = Array(Set(try await database.libraryExecutionWorkspaces().filter { !$0.deleted }.map(\.libraryID))).sorted()
                    }
                }
                // A client that confirms nothing is added at once, as before.
                if let memberKey, command.requiresConfirmation != true {
                    do { try await onMemberPaired(command.deviceID.lowercased(), command.deviceName, memberKey) }
                    catch let error as LibraryAPIError { return .error(error.code, error.message, status: 409) }
                }
                await onPair()
                return try .json(result)
            }
            guard request.headers["x-woven-protocol"] == String(LibraryProtocol.version) else {
                return .error("version_mismatch", "Update Woven Matter on both devices to compatible versions.", status: 426)
            }
            let device: PairedDevice
            let bearer: String
            if MemberRequestVerifier.isSigned(request.headers) {
                guard let members else { return .error("unauthorized", "This device does not accept member requests yet.", status: 401) }
                let key: MemberKey
                do {
                    key = try await members.verifier.verify(method: request.method, target: request.target, headers: request.headers,
                                                            body: request.body, allowing: [.ios, .mac])
                } catch let error as MemberRequestError {
                    return .error(error.code, error.message, status: error.code == "wrong_device" ? 403 : 401)
                }
                guard let member = await members.member(key.deviceID) else { return .error("unauthorized", MemberRequestError.unknown.message, status: 401) }
                device = .member(member); bearer = ""
            } else {
                guard let presented = request.bearer else { return .error("unauthorized", "Pair this iPhone in Mac Settings.", status: 401) }
                let metadata: DeviceMetadata?
                if let rawKind = request.headers["x-woven-device-kind"], let kind = DeviceKind(rawValue: rawKind) {
                    metadata = .init(kind: kind, osVersion: request.headers["x-woven-os-version"], appVersion: request.headers["x-woven-app-version"], developmentInstance: request.headers["x-woven-development-instance"])
                } else { metadata = nil }
                device = try await authentication.authenticate(bearer: presented, metadata: metadata)
                bearer = presented
            }
            guard isActive() else {
                return .error("unavailable", "Sharing with devices stopped before this request was accepted.", status: 503)
            }
            guard request.headers["x-woven-workspace"] == workspaceID || (device.isMember && request.headers["x-woven-workspace"] == nil) else {
                return .error("workspace_mismatch", "This credential belongs to a different workspace. Your local writing is preserved.", status: 409)
            }
            onRequest()
            if request.method == "POST", path == "/v1/devices/development/disconnect" {
                guard device.isDevelopment, !device.isMember else { return .error("invalid_device", "Only a development connection has temporary presence.", status: 403) }
                try await authentication.suspendLocalDevelopment(deviceID: device.id, credential: bearer)
                try await database.withdrawDevelopmentWorkspaces(ownedBy: device.id)
                onMutation()
                return try .json(["disconnected": true])
            }
            if path == "/mcp" {
                return try await handleDeviceMCP(request, device: device)
            }
            if path == "/v1/analytics/preference", request.method == "GET" { return try .json(await commands.analyticsPreference()) }
            if path == "/v1/analytics/preference", request.method == "POST" { return try .json(await commands.setAnalyticsPreference(JSONDecoder().decode(ProductAnalyticsPreferenceChange.self,from:request.body))) }
            if path == "/v1/analytics/events", request.method == "POST" { return try .json(await commands.ingestAnalytics(JSONDecoder().decode(ProductAnalyticsBatch.self,from:request.body))) }
            if request.method == "POST", path == "/v1/pair/unpair" {
                guard !device.isMember else { return .error("unsupported", "Remove this device from a Mac's device list.", status: 400) }
                try await onCancelPairing(device)
                if await authentication.isCurrent(device) { try await authentication.revoke(deviceID: device.id, expected: device) }
                await onPair()
                return try .json(["unpaired": true])
            }
            let values = target.queryItems ?? []
            func query(_ name: String) -> String? { values.first(where: { $0.name == name })?.value }
            if request.method == "GET", path == "/v1/federation/workspaces" {
                var active = Set(await authentication.devices().map(\.id))
                if let members { active.formUnion(((try? await members.list().members) ?? []).filter { !$0.revoked }.map(\.deviceID)) }
                return try .json(try await database.libraryConnectionWorkspaces(activeDeviceIDs: active))
            }
            if path.hasPrefix("/v1/federation/") {
                let response = try await FederationAPI.handle(request, path: path, query: values, device: device, database: database, commands: commands)
                if request.method == "POST", response.status == 200 { onMutation() }
                return response
            }
            if path == "/v1/dictations", request.method == "GET" {
                guard let after = Int64(query("after") ?? "0"), after >= 0 else {
                    return .error("invalid_cursor", "The dictation cursor is invalid.", status: 400)
                }
                return try .json(try await database.dictationChanges(after: after))
            }
            if path == "/v1/dictations", request.method == "POST" {
                guard request.body.count <= 8_388_608 else { return .error("too_large", "The dictation is too large.", status: 413) }
                let record = try JSONDecoder().decode(DictationRecord.self, from: request.body)
                try await database.saveDictation(record)
                onMutation(); return try .json(record)
            }
            if path == "/v1/calendar", request.method == "GET" {
                return try .json(try await database.libraryCalendarSnapshot())
            }
            if path == "/v1/calendar/runs", request.method == "POST" {
                let runs = try JSONDecoder().decode([LibraryCalendarRun].self, from: request.body)
                let accepted = try await database.libraryCalendarPublishRuns(runs, deviceID: device.id)
                onMutation(); return try .json(accepted)
            }
            if path == "/v1/calendar/mutations", request.method == "POST" {
                let mutation = try JSONDecoder().decode(LibraryCalendarMutation.self, from: request.body)
                let receipt = try await database.libraryCalendarMutate(mutation, deviceID: device.id)
                onMutation()
                return try .json(receipt)
            }
            if request.method == "GET" {
                switch path {
                case "/v1/devices": return try .json(await authentication.deviceConnections())
                case "/v1/hello":
                    return try .json(LibraryHello(workspaceID: workspaceID,
                        hostName: await hostName() ?? Self.machineName,
                        capabilities: [FederationProtocol.capability, "notes.conditional.v1", "folders.flat.v1", "changes.replay.v1", "commands.receipts.v1", "interactions.first-response.v1", "transcripts.paged.v1", "assets.linked-data.v1", "workspace.library.v1", "workspace.calendar.v1", "calendar.replicas.v1", "workspace.management.v1", "workspace.tools.v1"]))
                case "/v1/snapshot": return try .json(try await database.librarySnapshot())
                case "/v1/changes":
                    guard let after = Int64(query("after") ?? query("cursor") ?? "0"), after >= 0 else {
                        return .error("invalid_cursor", "The change cursor is invalid.", status: 400)
                    }
                    let limit = max(1, min(200, Int(query("limit") ?? "200") ?? 200))
                    let wait = max(0, min(25, Double(query("wait") ?? "0") ?? 0))
                    let deadline = Date().addingTimeInterval(wait)
                    var page = try await database.libraryChanges(after: after, limit: limit)
                    while page.changes.isEmpty && !page.resetRequired && Date() < deadline && isActive() {
                        try await Task.sleep(for: .milliseconds(250))
                        try await reauthenticate(device, bearer: bearer)
                        page = try await database.libraryChanges(after: after, limit: limit)
                    }
                    return try .json(page)
                case "/v1/providers": return try .json(commands.providers())
                case "/v1/members":
                    // A phone learns every Mac and Linux member (with endpoints)
                    // from whichever one it syncs with, so it has no home Mac.
                    guard let members else { return .error("unavailable", "This device does not serve members yet.", status: 503) }
                    return try .json(try await members.list())
                case "/v1/sync/status":
                    guard let status = await syncStatus() else { return .error("unavailable", "Synchronization has not started.", status: 503) }
                    return try .json(status)
                case "/v1/pending": return try .json(await commands.pendingInteractions())
                default: break
                }
                let components = path.split(separator: "/").map(String.init)
                if components.count == 4, components[0] == "v1", components[1] == "assets", components[3] == "linked-data" {
                    guard let note = try await database.libraryNote(id: components[2]),
                          let document = try? NoteDocument.editableDocument(from: note.content) else {
                        return .error("not_found", "This document cannot be previewed by this version of the Mac app.", status: 404)
                    }
                    let tableID = query("tableID")
                    let link: DatabaseArtifactLink?
                    if let tableID {
                        guard let block = document.blocks.first(where: { $0.id == tableID }), case .table(let table) = block else {
                            return .error("not_found", "This table is no longer in the document.", status: 404)
                        }
                        link = table.databaseLink ?? document.databaseLink
                    } else { link = document.databaseLink }
                    guard let link else { return .error("not_found", "This document has no linked database.", status: 404) }
                    guard !linkedReadInFlight else {
                        return .error("rate_limited", "A database preview is already loading. Try again shortly.", status: 429)
                    }
                    linkedReadInFlight = true
                    defer { linkedReadInFlight = false }
                    let data = try await linkedData(link)
                    guard isActive() else { return .error("unavailable", "Sharing with devices is stopped.", status: 503) }
                    try await reauthenticate(device, bearer: bearer)
                    let response = try LibraryHTTPResponse.json(LinkedDataPreview(noteID: note.id, noteRevision: note.revision,
                        tableID: tableID, columns: data.columns, rows: data.rows, json: data.json))
                    guard response.body.count <= 32 * 1_024 * 1_024 else {
                        return .error("preview_too_large", "Open this large database preview on your Mac.", status: 413)
                    }
                    return response
                }
                if components.count == 3, components[0] == "v1", components[1] == "command-receipts" {
                    guard let receipt = try await commands.receipt(commandID: components[2], deviceID: device.id) else {
                        return .error("not_found", "The Mac has no receipt for this command. Retry explicitly using the same command ID.", status: 404)
                    }
                    return try .json(receipt)
                }
                if components.count == 4, components[0] == "v1", components[1] == "sessions" {
                    if components[3] == "transcript" {
                        if let transcript = try await database.libraryFederatedTranscript(conversationID: components[2], before: query("before")) {
                            return try .json(transcript)
                        }
                        return try .json(try await commands.transcript(conversationID: components[2], before: query("before")))
                    }
                    if components[3] == "capabilities" {
                        return try .json(try await commands.sessionCapabilities(conversationID: components[2]))
                    }
                    if components[3] == "activity" {
                        return try .json(try await database.libraryActivityDetails(conversationID: components[2],
                            runID: query("run"), activityID: query("id") ?? ""))
                    }
                }
                if components.count == 3, components[0] == "v1", ["assets", "notes"].contains(components[1]) {
                    guard let note = try await database.libraryNote(id: components[2]) else {
                        return .error("not_found", "This document is no longer available.", status: 404)
                    }
                    return try .json(note)
                }
            } else if request.method == "POST" {
                if path == "/v1/workspace-read" {
                    let read = try JSONDecoder().decode(LibraryWorkspaceRead.self, from: request.body)
                    let value = try await commands.readWorkspace(read)
                    guard isActive() else { return .error("unavailable", "Sharing with devices is stopped.", status: 503) }
                    try await reauthenticate(device, bearer: bearer)
                    return try .json(value)
                }
                if path == "/v1/mutations" {
                    let mutation = try JSONDecoder().decode(LibraryMutation.self, from: request.body)
                    guard mutation.deviceID == device.id else { return .error("wrong_device", "Mutation belongs to another device.", status: 403) }
                    let result = try await database.applyLibraryMutation(mutation)
                    onMutation()
                    return try .json(result)
                }
                if path == "/v1/commands" {
                    let command = try JSONDecoder().decode(LibraryCommand.self, from: request.body)
                    guard command.deviceID == device.id else { return .error("wrong_device", "Command belongs to another device.", status: 403) }
                    return try .json(try await commands.execute(command, deviceID: device.id))
                }
            }
            return .error("not_found", "Unknown library endpoint.", status: 404)
        } catch is MCPMalformedJSON {
            return (try? .json(WovenMCPServer.error(code: -32700, message: "Invalid JSON."), status: 400))
                ?? .error("invalid_request", "Invalid JSON.", status: 400)
        } catch let error as LibraryAPIError {
            let status = error.code == "unauthorized" ? 401 : ["wrong_owner", "invalid_origin"].contains(error.code) ? 403 : error.code == "not_found" ? 404 : error.code == "method_not_allowed" ? 405 : error.code == "too_large" ? 413 : error.code == "version_mismatch" ? 426 : error.code == "rate_limited" ? 429 : ["revision_conflict", "event_conflict", "origin_gap", "receipt_conflict", "record_conflict", "chunk_conflict"].contains(error.code) ? 409 : 400
            return .error(error.code, error.message, status: status)
        } catch let error as LibraryCalendarError {
            let status: Int
            switch error {
            case .conflict, .requestMismatch, .wrongWorkspace: status = 409
            case .missing: status = 404
            default: status = 400
            }
            return .error("calendar_error", error.localizedDescription, status: status)
        } catch let error as WorkspaceToolError {
            return .error("tool_unavailable", error.localizedDescription, status: 400)
        } catch is DecodingError { return .error("invalid_request", "The request did not match the library protocol.", status: 400) }
        catch { return .error("workspace_error", "The Mac could not complete this request. Your pending writing is preserved; check the Mac and retry.", status: 500) }
    }
}
