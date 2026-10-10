import CompanionClient
import Foundation
import WovenMatterCore
import WovenMatterDashboardStore

/// Only explicitly enabled secondary workspaces expose this endpoint. Device
/// grants and the central host's management grant use separate credential stores.
@MainActor
final class SecondaryMacExecutionHost {
    private(set) var endpoint: URL?
    private(set) var managementGrant: CompanionExecutionManagementGrant?
    private let workspace: SecondaryMacExecutionWorkspace
    private let directory: URL
    private var server: CompanionHTTPServer?
    private var exposure: CompanionTailscaleServe?
    private var stoppingExposures: [CompanionTailscaleServe] = []
    private var inference: CompanionInferenceHost?
    private var starting = false
    private var api: CompanionMacExecutionAPI?
    private var management: CompanionExecutionAuthentication?
    private var generation = UUID()
    private var awakeActivity: NSObjectProtocol?
    init(workspace: SecondaryMacExecutionWorkspace, directory: URL) { self.workspace = workspace; self.directory = directory }

    func start(preferredHTTPSPort: Int? = nil) async throws {
        guard endpoint == nil, !starting else { return }
        starting = true
        generation = UUID(); let attempt = generation
        defer { if generation == attempt { starting = false } }
        for previous in stoppingExposures { try await previous.waitUntilStopped() }
        stoppingExposures.removeAll()
        guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
        let authentication = try CompanionExecutionAuthentication(fileURL: directory.appending(path: "execution-access.json"))
        let management = try CompanionExecutionAuthentication(fileURL: directory.appending(path: "management-access.json"))
        self.management = management
        let server = CompanionHTTPServer { [weak self] request in
            guard let self else { return .error("unavailable", "Execution sharing stopped.", status: 503) }
            return await self.handle(request, attempt: attempt)
        }
        self.server = server
        let exposure = CompanionTailscaleServe(); self.exposure = exposure
        do {
            let port = try await server.start()
            let endpoint = try await exposure.start(loopbackPort: port, preferredHTTPSPort: preferredHTTPSPort)
            guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
            try await workspace.setEndpoint(endpoint)
            let descriptor = workspace.descriptor
            let api = CompanionMacExecutionAPI(database: workspace.database,
                commands: SecondaryMacExecutionCommands(workspace: workspace), authentication: authentication,
                descriptor: descriptor, isActive: { [weak self] in self?.generation == attempt && self?.endpoint != nil },
                events: { [workspace] after in try await workspace.events(after: after) })
            self.api = api; self.endpoint = endpoint
            inference = CompanionInferenceHost(authentication: authentication, descriptor: descriptor, directory: directory,
                isActive: { [weak self] in self?.generation == attempt && self?.endpoint != nil })
            let token = try await management.provision(deviceID: descriptor.libraryID, libraryID: descriptor.libraryID, workspaceID: descriptor.id)
            managementGrant = .init(workspaceID: descriptor.id, endpoint: endpoint, token: token)
            awakeActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiatedAllowingIdleSystemSleep], reason: "Share this Mac’s Woven Matter execution workspace")
        } catch {
            server.stop(); exposure.stop()
            if !stoppingExposures.contains(where: { $0 === exposure }) { stoppingExposures.append(exposure) }
            if generation == attempt { stop() }
            throw error
        }
    }
    func stop() {
        generation = UUID(); starting = false; endpoint = nil; managementGrant = nil; api = nil; inference = nil
        server?.stop(); server = nil
        if let exposure {
            exposure.stop()
            if !stoppingExposures.contains(where: { $0 === exposure }) { stoppingExposures.append(exposure) }
            self.exposure = nil
        }
        if let awakeActivity { ProcessInfo.processInfo.endActivity(awakeActivity); self.awakeActivity = nil }
    }
    func waitUntilStopped() async throws {
        for exposure in stoppingExposures { try await exposure.waitUntilStopped() }
        stoppingExposures.removeAll()
    }
    private func handle(_ request: CompanionHTTPRequest, attempt: UUID) async -> CompanionHTTPResponse {
        guard generation == attempt, let api, let endpoint else { return .error("unavailable", "Execution sharing is starting or stopped.", status: 503) }
        let target = URLComponents(string: "http://localhost" + request.target)?.path ?? ""
        let path = target.hasPrefix("/wovenmatter/") ? String(target.dropFirst("/wovenmatter".count)) : target
        if path.hasPrefix("/v1/inference/"), let inference { return await inference.handle(request) }
        guard path.hasPrefix("/v1/execution/manage/") else { return await api.handle(request) }
        do {
            guard request.method == "POST", request.headers["x-woven-protocol"] == String(CompanionProtocol.version),
                  let bearer = request.bearer, let management else { return .error("unauthorized", "Missing management grant.", status: 401) }
            let scope = try await management.authenticate(bearer: bearer)
            let descriptor = workspace.descriptor
            guard scope.deviceID == descriptor.libraryID, scope.libraryID == descriptor.libraryID, scope.workspaceID == descriptor.id,
                  request.headers["x-woven-library"] == descriptor.libraryID, request.headers["x-woven-workspace"] == descriptor.id else {
                return .error("unauthorized", "The management grant belongs to another library or workspace.", status: 403)
            }
            struct Device: Decodable { let deviceID: String }
            let device = try JSONDecoder().decode(Device.self, from: request.body)
            guard UUID(uuidString: device.deviceID) != nil else { return .error("invalid_device", "A device UUID is required.", status: 400) }
            // Recheck serving generation after crossing the authentication actor.
            guard self.endpoint == endpoint else { return .error("unavailable", "Execution sharing stopped.", status: 503) }
            if path == "/v1/execution/manage/devices" { return try .json(try await api.provision(deviceID: device.deviceID)) }
            if path == "/v1/execution/manage/revoke" {
                try await api.revoke(deviceID: device.deviceID)
                return try .json(["revoked": true])
            }
            return .error("not_found", "Unknown management operation.", status: 404)
        } catch { return .error("unauthorized", "The central library management grant is invalid or its request could not be applied.", status: 403) }
    }
}

@MainActor
private final class SecondaryMacExecutionCommands: CompanionCommandServing {
    let workspace: SecondaryMacExecutionWorkspace
    init(workspace: SecondaryMacExecutionWorkspace) { self.workspace = workspace }
    func providers() -> [CompanionProvider] { workspace.model.companionCommands.providers().filter { $0.id.hasPrefix("local:") } }
    func pendingInteractions() async -> [CompanionPendingInteraction] { await workspace.model.companionCommands.pendingInteractions() }
    func sessionCapabilities(conversationID: String) async throws -> CompanionProvider { try await workspace.capabilities(conversationID) }
    func transcript(conversationID: String, before: String?) async throws -> CompanionTranscript {
        try await workspace.model.companionCommands.transcript(conversationID: conversationID, before: before)
    }
    func receipt(commandID: String, deviceID: String) async throws -> CompanionCommandReceipt? {
        try await workspace.model.companionCommands.receipt(commandID: commandID, deviceID: deviceID)
    }
    func execute(_ command: CompanionCommand, deviceID: String) async throws -> CompanionCommandReceipt {
        guard command.deviceID == deviceID else { throw MobileConnectionError.revoked }
        return try await workspace.command(command)
    }
    func readWorkspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult { try await workspace.readWorkspace(request) }
}
