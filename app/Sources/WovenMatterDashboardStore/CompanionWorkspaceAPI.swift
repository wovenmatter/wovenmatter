import Foundation
import WovenMatterCore

private struct MCPMalformedJSON: Error {}

@MainActor
public protocol CompanionCommandServing: AnyObject {
    func executeTool(_ request: CompanionToolRequest, deviceID: String) async throws -> WovenMatterToolResponse
    func registerExecutionManagement(_ grant: CompanionExecutionManagementGrant, device: CompanionPairedDevice) async throws -> CompanionExecutionWorkspace
    func provisionExecutionWorkspace(id: String, device: CompanionPairedDevice) async throws -> CompanionExecutionCredential
    func readWorkspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult
    func analyticsPreference() async throws -> ProductAnalyticsPreference
    func setAnalyticsPreference(_ change: ProductAnalyticsPreferenceChange) async throws -> ProductAnalyticsPreference
    func ingestAnalytics(_ batch: ProductAnalyticsBatch) async throws -> ProductAnalyticsAcknowledgement
    func providers() -> [CompanionProvider]
    func pendingInteractions() async -> [CompanionPendingInteraction]
    func sessionCapabilities(conversationID: String) async throws -> CompanionProvider
    func transcript(conversationID: String, before: String?) async throws -> CompanionTranscript
    func receipt(commandID: String, deviceID: String) async throws -> CompanionCommandReceipt?
    func execute(_ command: CompanionCommand, deviceID: String) async throws -> CompanionCommandReceipt
}

private extension CompanionWorkspaceAPI {
    func mcpInput(_ request: CompanionHTTPRequest) throws -> (GatewayJSONValue, String, [WorkspaceToolGroup], String?) {
        guard request.method == "POST" else {
            throw CompanionAPIError(code: "method_not_allowed", message: "Woven MCP uses HTTP POST for JSON-RPC requests.")
        }
        guard request.body.count <= 4 * 1_024 * 1_024 else {
            throw CompanionAPIError(code: "too_large", message: "The MCP request exceeds 4 MiB.")
        }
        guard request.headers["origin"] == nil else {
            throw CompanionAPIError(code: "invalid_origin", message: "Browser-origin MCP requests are unavailable on this device route.")
        }
        if let version = request.headers["mcp-protocol-version"], !WovenMCPServer.supportedProtocolVersions.contains(version) {
            throw CompanionAPIError(code: "invalid_request", message: "The requested MCP protocol version is unsupported.")
        }
        guard let conversationID = request.headers["x-woven-conversation-id"], UUID(uuidString: conversationID) != nil,
              let rawGroups = request.headers["x-woven-enabled-groups"], rawGroups.utf8.count <= 512 else {
            throw CompanionAPIError(code: "invalid_request", message: "MCP requires a native conversation binding and current tool selection.")
        }
        let names = rawGroups.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        let groups = names.compactMap(WorkspaceToolGroup.init(rawValue:))
        guard groups.count == names.count else {
            throw CompanionAPIError(code: "invalid_request", message: "An unknown tool group was selected.")
        }
        let message: GatewayJSONValue
        do { message = try JSONDecoder().decode(GatewayJSONValue.self, from: request.body) }
        catch { throw MCPMalformedJSON() }
        let capture = request.headers["x-woven-context-id"]
            ?? message.objectValue?["params"]?.objectValue?["_meta"]?.objectValue?["wovenContextID"]?.stringValue
        guard (capture?.utf8.count ?? 0) <= 128 else {
            throw CompanionAPIError(code: "invalid_request", message: "The input context is invalid.")
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

    func handleDeviceMCP(_ request: CompanionHTTPRequest, device: CompanionPairedDevice) async throws -> CompanionHTTPResponse {
        let (message, conversationID, groups, captureID) = try mcpInput(request)
        guard let workspace = try await database.companionConversationExecutionWorkspace(conversationID: conversationID),
              workspace.kind == .ios || workspace.kind == .mac else {
            throw CompanionAPIError(code: "wrong_owner", message: "A paired-device MCP connection cannot impersonate a Linux execution workspace.")
        }
        // Even schema discovery needs a real, live conversation owned by this
        // paired device. A pasted conversation UUID is never a new grant.
        let identity = CompanionToolRequest(conversationID: conversationID,
            request: .init(arguments: ["context"]), enabledGroups: groups)
        try await database.authorizeCompanionTool(identity, deviceID: device.id)
        let result = await WovenMCPServer.handle(message, contextID: captureID, allowedTools: mcpTools(groups: groups)) { call in
            await self.performMCP(call, conversationID: conversationID, groups: groups, device: device)
        }
        guard isActive(), await authentication.isCurrent(device) else {
            return .error("unauthorized", "This paired device's MCP access has stopped.", status: 401)
        }
        guard let result else { return .init(status: 202, body: Data()) }
        return try .json(result)
    }

    func performMCP(_ call: WovenMatterToolRequest, conversationID: String, groups: [WorkspaceToolGroup],
                    device: CompanionPairedDevice) async -> WovenMatterToolResponse {
        do {
            guard isActive(), await authentication.isCurrent(device) else {
                throw CompanionAPIError(code: "unauthorized", message: "This paired device's MCP access was revoked.")
            }
            let request = CompanionToolRequest(conversationID: conversationID, request: call, enabledGroups: groups)
            try await database.authorizeCompanionTool(request, deviceID: device.id)
            let response = try await commands.executeTool(request, deviceID: device.id)
            if response.success { onMutation() }
            return response.bounded()
        } catch let error as CompanionAPIError {
            return .init(success: false, error: error.message, code: error.code, requestID: call.requestID)
        } catch {
            return .init(success: false, error: error.localizedDescription, code: "tool_unavailable", requestID: call.requestID)
        }
    }

    func handleWorkspaceMCP(_ request: CompanionHTTPRequest) async throws -> CompanionHTTPResponse {
        guard request.headers["x-woven-protocol"] == String(CompanionProtocol.version), let bearer = request.bearer else {
            return .error("unauthorized", "A library MCP grant is required.", status: 401)
        }
        let principal = try await database.authenticateCompanionWorkspaceMCP(bearer: bearer)
        guard request.headers["x-woven-workspace"] == principal.libraryID else {
            return .error("library_mismatch", "This MCP grant belongs to another library.", status: 409)
        }
        let (message, conversationID, groups, captureID) = try mcpInput(request)
        try await database.authorizeCompanionWorkspaceMCPCaller(conversationID: conversationID, principal: principal)
        let result = await WovenMCPServer.handle(message, contextID: captureID, allowedTools: mcpTools(groups: groups)) { call in
            await self.performWorkspaceMCP(call, conversationID: conversationID, groups: groups, bearer: bearer, principal: principal)
        }
        guard isActive() else { return .error("unavailable", "The library MCP host stopped.", status: 503) }
        _ = try await database.authenticateCompanionWorkspaceMCP(bearer: bearer)
        guard let result else { return .init(status: 202, body: Data()) }
        return try .json(result)
    }

    func prepareWorkspaceMCP(_ request: CompanionHTTPRequest) async throws -> CompanionHTTPResponse {
        guard request.method == "POST" else { return .error("method_not_allowed", "Scheduled caller registration uses POST.", status: 405) }
        guard request.headers["x-woven-protocol"] == String(CompanionProtocol.version) else { return .error("version_mismatch", "Update the execution workspace to a compatible version.", status: 426) }
        guard request.body.count <= 1_048_576 else { return .error("too_large", "The scheduled caller registration exceeds 1 MiB.", status: 413) }
        guard let bearer = request.bearer else { return .error("unauthorized", "A library MCP grant is required.", status: 401) }
        let principal = try await database.authenticateCompanionWorkspaceMCP(bearer: bearer)
        guard request.headers["x-woven-workspace"] == principal.libraryID else {
            return .error("library_mismatch", "This MCP grant belongs to another library.", status: 409)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "An ISO-8601 schedule timestamp is required."))
            }
            return date
        }
        let preparation = try decoder.decode(CompanionScheduledMCPPreparation.self, from: request.body)
        let enabled = try await database.prepareCompanionScheduledMCP(preparation, principal: principal)
        guard isActive() else { return .error("unavailable", "The library MCP host stopped.", status: 503) }
        _ = try await database.authenticateCompanionWorkspaceMCP(bearer: bearer)
        onMutation()
        return try .json(["enabledGroups": enabled.map(\.rawValue)])
    }

    func performWorkspaceMCP(_ call: WovenMatterToolRequest, conversationID: String, groups: [WorkspaceToolGroup],
                             bearer: String, principal: CompanionWorkspaceMCPPrincipal) async -> WovenMatterToolResponse {
        do {
            guard isActive() else { throw CompanionAPIError(code: "unavailable", message: "The library MCP host stopped.") }
            let current = try await database.authenticateCompanionWorkspaceMCP(bearer: bearer)
            guard current.grantID == principal.grantID else {
                throw CompanionAPIError(code: "unauthorized", message: "The workspace's library MCP grant changed.")
            }
            try await database.authorizeCompanionWorkspaceMCPCaller(conversationID: conversationID, principal: current)
            let request = CompanionToolRequest(conversationID: conversationID, request: call, enabledGroups: groups)
            try await database.authorizeCompanionTool(request, deviceID: current.executionDeviceID)
            let response = try await commands.executeTool(request, deviceID: current.executionDeviceID)
            if response.success { onMutation() }
            return response.bounded()
        } catch let error as CompanionAPIError {
            return .init(success: false, error: error.message, code: error.code, requestID: call.requestID)
        } catch {
            return .init(success: false, error: error.localizedDescription, code: "tool_unavailable", requestID: call.requestID)
        }
    }
}

public extension CompanionCommandServing {
    func analyticsPreference() async throws -> ProductAnalyticsPreference { throw CompanionAPIError(code:"unsupported",message:"Update the central Mac to configure analytics.") }
    func setAnalyticsPreference(_ change: ProductAnalyticsPreferenceChange) async throws -> ProductAnalyticsPreference { throw CompanionAPIError(code:"unsupported",message:"Update the central Mac to configure analytics.") }
    func ingestAnalytics(_ batch: ProductAnalyticsBatch) async throws -> ProductAnalyticsAcknowledgement { throw CompanionAPIError(code:"unsupported",message:"Update the central Mac to configure analytics.") }

    func executeTool(_ request: CompanionToolRequest, deviceID: String) async throws -> WovenMatterToolResponse {
        throw CompanionAPIError(code: "unsupported", message: "Update the central Mac to use its tools from this device.")
    }
    func registerExecutionManagement(_ grant: CompanionExecutionManagementGrant, device: CompanionPairedDevice) async throws -> CompanionExecutionWorkspace {
        throw CompanionAPIError(code: "unsupported", message: "This host does not accept secondary execution management grants.")
    }
    func provisionExecutionWorkspace(id: String, device: CompanionPairedDevice) async throws -> CompanionExecutionCredential {
        throw CompanionAPIError(code: "unsupported", message: "This host does not provision independent execution workspaces.")
    }
    func readWorkspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult {
        throw CompanionAPIError(code: "unsupported", message: "Update your Mac to use this feature.")
    }
}

/// One authenticated, workspace-bound API per serving attempt. The activity
/// predicate captures that attempt, so a delayed request cannot cross stop/restart.
@MainActor
public final class CompanionWorkspaceAPI {
    private let database: WorkspaceDatabase
    private let authentication: CompanionAuthentication
    private let commands: any CompanionCommandServing
    private let isActive: @MainActor @Sendable () -> Bool
    private let onCancelPairing: @MainActor @Sendable (CompanionPairedDevice) async throws -> Void
    private let discovery: @MainActor @Sendable () -> CompanionDiscoveryAdvertisement?
    private let onPair: @MainActor @Sendable () async -> Void
    private let onMutation: @MainActor @Sendable () -> Void
    private let onRequest: @MainActor @Sendable () -> Void
    private let linkedData: @MainActor @Sendable (DatabaseArtifactLink) async throws -> DatabaseTabularData
    private var linkedReadInFlight = false
    public init(database: WorkspaceDatabase, authentication: CompanionAuthentication,
                commands: any CompanionCommandServing,
                isActive: @escaping @MainActor @Sendable () -> Bool,
                onCancelPairing: @escaping @MainActor @Sendable (CompanionPairedDevice) async throws -> Void = { _ in
                    throw CompanionAPIError(code: "unavailable", message: "Revoke this device from the central Mac settings.")
                },
                discovery: @escaping @MainActor @Sendable () -> CompanionDiscoveryAdvertisement? = { nil },
                onPair: @escaping @MainActor @Sendable () async -> Void = {},
                onMutation: @escaping @MainActor @Sendable () -> Void = {},
                onRequest: @escaping @MainActor @Sendable () -> Void = {},
                linkedData: @escaping @MainActor @Sendable (DatabaseArtifactLink) async throws -> DatabaseTabularData = { _ in
                    throw CompanionAPIError(code: "linked_data_unavailable", message: "This database is unavailable on the Mac.")
                }) {
        self.database = database; self.authentication = authentication; self.commands = commands
        self.isActive = isActive; self.onPair = onPair; self.onMutation = onMutation; self.onRequest = onRequest
        self.linkedData = linkedData; self.discovery = discovery; self.onCancelPairing = onCancelPairing
    }

    public func handle(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        guard isActive() else { return .error("unavailable", "Companion sharing is stopped.", status: 503) }
        do {
            guard let target = URLComponents(string: "http://localhost" + request.target) else {
                return .error("invalid_request", "Invalid request path.", status: 400)
            }
            var path = target.path
            if path.hasPrefix("/wovenmatter/") { path = String(path.dropFirst("/wovenmatter".count)) }
            let workspaceID = try await database.companionWorkspaceID()
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
                let pending = try JSONDecoder().decode(CompanionPairingApprovalRequest.self, from: request.body)
                let result = try await authentication.requestPairing(pending, workspaceID: workspaceID)
                return try .json(result)
            }
            if path == "/v1/pairing/result", request.method == "POST" {
                guard request.body.count <= 1_024 else { return .error("too_large", "The pairing request is too large.", status: 413) }
                let poll = try JSONDecoder().decode(CompanionPairingPoll.self, from: request.body)
                return try .json(try await authentication.pairingResult(poll))
            }
            if path == "/v1/pairing/cancel", request.method == "POST" {
                guard request.body.count <= 1_024 else { return .error("too_large", "The pairing request is too large.", status: 413) }
                let poll = try JSONDecoder().decode(CompanionPairingPoll.self, from: request.body)
                if let principal = try await authentication.preparePairingCancellation(poll) {
                    try await onCancelPairing(principal)
                }
                try await authentication.cancelPairing(poll, revokeApproved: false)
                await onPair()
                return try .json(["cancelled": true])
            }
            if path.hasPrefix("/v1/federation/publisher/") {
                guard request.headers["x-woven-protocol"] == String(CompanionProtocol.version) else {
                    return .error("version_mismatch", "Update Woven Matter on both devices.", status: 426)
                }
                guard isActive() else { return .error("unavailable", "Companion sharing stopped.", status: 503) }
                let response = try await CompanionWorkspacePublisherAPI.handle(request, path: path, database: database)
                guard isActive() else { return .error("unavailable", "Companion sharing stopped.", status: 503) }
                if request.method == "POST", response.status == 200 { onMutation() }
                return response
            }
            if request.method == "POST", path == "/v1/pair/preview" {
                guard request.body.count <= 8_192 else { return .error("too_large", "The pairing request is too large.", status: 413) }
                let command = try JSONDecoder().decode(CompanionPairRequest.self, from: request.body)
                return try .json(try await authentication.previewPairing(command, workspaceID: workspaceID))
            }
            if request.method == "POST", path == "/v1/pair/confirm" {
                guard request.headers["x-woven-protocol"] == String(CompanionProtocol.version),
                    request.headers["x-woven-workspace"] == workspaceID, let bearer = request.bearer else {
                    return .error("unauthorized", "Complete pairing on this device.", status: 401)
                }
                try await authentication.confirmPairing(bearer: bearer, workspaceID: workspaceID)
                await onPair()
                return try .json(["confirmed": true])
            }
            if request.method == "POST", path == "/v1/pair" {
                guard request.body.count <= 8_192 else { return .error("too_large", "The pairing request is too large.", status: 413) }
                let command = try JSONDecoder().decode(CompanionPairRequest.self, from: request.body)
                let result = try await authentication.pair(command, workspaceID: workspaceID)
                await onPair()
                return try .json(result)
            }
            guard request.headers["x-woven-protocol"] == String(CompanionProtocol.version) else {
                return .error("version_mismatch", "Update Woven Matter on both devices to compatible versions.", status: 426)
            }
            guard let bearer = request.bearer else { return .error("unauthorized", "Pair this iPhone in Mac Settings.", status: 401) }
            let metadata: CompanionDeviceMetadata?
            if let rawKind = request.headers["x-woven-device-kind"], let kind = CompanionDeviceKind(rawValue: rawKind) {
                metadata = .init(kind: kind, osVersion: request.headers["x-woven-os-version"], appVersion: request.headers["x-woven-app-version"])
            } else { metadata = nil }
            let device = try await authentication.authenticate(bearer: bearer, metadata: metadata)
            guard isActive() else {
                return .error("unavailable", "Companion sharing stopped before this request was accepted.", status: 503)
            }
            guard request.headers["x-woven-workspace"] == workspaceID else {
                return .error("workspace_mismatch", "This credential belongs to a different workspace. Your local writing is preserved.", status: 409)
            }
            onRequest()
            if path == "/mcp" {
                return try await handleDeviceMCP(request, device: device)
            }
            if path == "/v1/analytics/preference", request.method == "GET" { return try .json(await commands.analyticsPreference()) }
            if path == "/v1/analytics/preference", request.method == "POST" { return try .json(await commands.setAnalyticsPreference(JSONDecoder().decode(ProductAnalyticsPreferenceChange.self,from:request.body))) }
            if path == "/v1/analytics/events", request.method == "POST" { return try .json(await commands.ingestAnalytics(JSONDecoder().decode(ProductAnalyticsBatch.self,from:request.body))) }
            if request.method == "POST", path == "/v1/pair/unpair" {
                try await onCancelPairing(device)
                if await authentication.isCurrent(device) { try await authentication.revoke(deviceID: device.id, expected: device) }
                await onPair()
                return try .json(["unpaired": true])
            }
            let values = target.queryItems ?? []
            func query(_ name: String) -> String? { values.first(where: { $0.name == name })?.value }
            if path.hasPrefix("/v1/federation/") {
                let response = try await CompanionFederationAPI.handle(request, path: path, query: values, device: device, database: database, commands: commands)
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
                return try .json(try await database.companionCalendarSnapshot())
            }
            if path == "/v1/calendar/runs", request.method == "POST" {
                let runs = try JSONDecoder().decode([CompanionCalendarRun].self, from: request.body)
                let accepted = try await database.companionCalendarPublishRuns(runs, deviceID: device.id)
                onMutation(); return try .json(accepted)
            }
            if path == "/v1/calendar/mutations", request.method == "POST" {
                let mutation = try JSONDecoder().decode(CompanionCalendarMutation.self, from: request.body)
                let receipt = try await database.companionCalendarMutate(mutation, deviceID: device.id)
                onMutation()
                return try .json(receipt)
            }
            if request.method == "GET" {
                switch path {
                case "/v1/devices": return try .json(await authentication.deviceConnections())
                case "/v1/hello":
                    return try .json(CompanionHello(workspaceID: workspaceID,
                        hostName: Host.current().localizedName ?? "Woven Matter Mac",
                        capabilities: [CompanionFederationProtocol.capability, "notes.conditional.v1", "folders.flat.v1", "changes.replay.v1", "commands.receipts.v1", "interactions.first-response.v1", "transcripts.paged.v1", "assets.linked-data.v1", "workspace.library.v1", "workspace.calendar.v1", "calendar.replicas.v1", "workspace.management.v1", "workspace.tools.v1"]))
                case "/v1/snapshot": return try .json(try await database.companionSnapshot())
                case "/v1/changes":
                    guard let after = Int64(query("after") ?? query("cursor") ?? "0"), after >= 0 else {
                        return .error("invalid_cursor", "The change cursor is invalid.", status: 400)
                    }
                    let limit = max(1, min(200, Int(query("limit") ?? "200") ?? 200))
                    let wait = max(0, min(25, Double(query("wait") ?? "0") ?? 0))
                    let deadline = Date().addingTimeInterval(wait)
                    var page = try await database.companionChanges(after: after, limit: limit)
                    while page.changes.isEmpty && !page.resetRequired && Date() < deadline && isActive() {
                        try await Task.sleep(for: .milliseconds(250))
                        _ = try await authentication.authenticate(bearer: bearer)
                        page = try await database.companionChanges(after: after, limit: limit)
                    }
                    return try .json(page)
                case "/v1/providers": return try .json(commands.providers())
                case "/v1/pending": return try .json(await commands.pendingInteractions())
                default: break
                }
                let components = path.split(separator: "/").map(String.init)
                if components.count == 4, components[0] == "v1", components[1] == "assets", components[3] == "linked-data" {
                    guard let note = try await database.companionNote(id: components[2]),
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
                    guard isActive() else { return .error("unavailable", "Companion sharing is stopped.", status: 503) }
                    _ = try await authentication.authenticate(bearer: bearer)
                    let response = try CompanionHTTPResponse.json(CompanionLinkedData(noteID: note.id, noteRevision: note.revision,
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
                        if let transcript = try await database.companionFederatedTranscript(conversationID: components[2], before: query("before")) {
                            return try .json(transcript)
                        }
                        return try .json(try await commands.transcript(conversationID: components[2], before: query("before")))
                    }
                    if components[3] == "capabilities" {
                        return try .json(try await commands.sessionCapabilities(conversationID: components[2]))
                    }
                }
                if components.count == 3, components[0] == "v1", ["assets", "notes"].contains(components[1]) {
                    guard let note = try await database.companionNote(id: components[2]) else {
                        return .error("not_found", "This document is no longer available.", status: 404)
                    }
                    return try .json(note)
                }
            } else if request.method == "POST" {
                if path == "/v1/workspace-read" {
                    let read = try JSONDecoder().decode(CompanionWorkspaceRead.self, from: request.body)
                    let value = try await commands.readWorkspace(read)
                    guard isActive() else { return .error("unavailable", "Companion sharing is stopped.", status: 503) }
                    _ = try await authentication.authenticate(bearer: bearer)
                    return try .json(value)
                }
                if path == "/v1/mutations" {
                    let mutation = try JSONDecoder().decode(CompanionMutation.self, from: request.body)
                    guard mutation.deviceID == device.id else { return .error("wrong_device", "Mutation belongs to another device.", status: 403) }
                    let result = try await database.applyCompanionMutation(mutation)
                    onMutation()
                    return try .json(result)
                }
                if path == "/v1/commands" {
                    let command = try JSONDecoder().decode(CompanionCommand.self, from: request.body)
                    guard command.deviceID == device.id else { return .error("wrong_device", "Command belongs to another device.", status: 403) }
                    return try .json(try await commands.execute(command, deviceID: device.id))
                }
            }
            return .error("not_found", "Unknown companion endpoint.", status: 404)
        } catch is MCPMalformedJSON {
            return (try? .json(WovenMCPServer.error(code: -32700, message: "Invalid JSON."), status: 400))
                ?? .error("invalid_request", "Invalid JSON.", status: 400)
        } catch let error as CompanionAPIError {
            let status = error.code == "unauthorized" ? 401 : ["wrong_owner", "invalid_origin"].contains(error.code) ? 403 : error.code == "not_found" ? 404 : error.code == "method_not_allowed" ? 405 : error.code == "too_large" ? 413 : error.code == "version_mismatch" ? 426 : error.code == "rate_limited" ? 429 : ["revision_conflict", "event_conflict", "origin_gap", "receipt_conflict", "record_conflict", "chunk_conflict"].contains(error.code) ? 409 : 400
            return .error(error.code, error.message, status: status)
        } catch let error as CompanionCalendarError {
            let status: Int
            switch error {
            case .conflict, .requestMismatch, .wrongWorkspace: status = 409
            case .missing: status = 404
            default: status = 400
            }
            return .error("calendar_error", error.localizedDescription, status: status)
        } catch let error as WorkspaceToolError {
            return .error("tool_unavailable", error.localizedDescription, status: 400)
        } catch is DecodingError { return .error("invalid_request", "The request did not match the companion protocol.", status: 400) }
        catch { return .error("workspace_error", "The Mac could not complete this request. Your pending writing is preserved; check the Mac and retry.", status: 500) }
    }
}
