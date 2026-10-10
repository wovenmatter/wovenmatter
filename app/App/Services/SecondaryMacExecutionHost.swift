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
    private var authentication: CompanionExecutionAuthentication?
    private var managementDeviceIDs: Set<String> = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let makeExposure: @MainActor () -> CompanionTailscaleServe
    private let afterManagementAuthentication: @MainActor () async -> Void
    private var generation = UUID()
    private var awakeActivity: NSObjectProtocol?
    init(workspace: SecondaryMacExecutionWorkspace, directory: URL,
         makeExposure: @escaping @MainActor () -> CompanionTailscaleServe = { CompanionTailscaleServe() },
         afterManagementAuthentication: @escaping @MainActor () async -> Void = {}) {
        self.workspace = workspace; self.directory = directory
        self.makeExposure = makeExposure; self.afterManagementAuthentication = afterManagementAuthentication
    }

    func start(preferredHTTPSPort: Int? = nil) async throws {
        guard endpoint == nil else { return }
        guard !starting else { throw CompanionAPIError(code: "starting", message: "Execution sharing is still starting or stopping. Retry shortly.") }
        starting = true
        generation = UUID(); let attempt = generation
        defer { starting = false; resumeIdleWaiters() }
        for previous in stoppingExposures { try await previous.waitUntilStopped() }
        stoppingExposures.removeAll()
        guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
        if authentication == nil { authentication = try CompanionExecutionAuthentication(fileURL: directory.appending(path: "execution-access.json")) }
        if management == nil { management = try CompanionExecutionAuthentication(fileURL: directory.appending(path: "management-access.json")) }
        guard let authentication, let management else { throw CancellationError() }
        let server = CompanionHTTPServer(handler: requestHandler())
        self.server = server
        let exposure = makeExposure(); self.exposure = exposure
        do {
            let port = try await server.start()
            guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
            let endpoint = try await exposure.start(loopbackPort: port, preferredHTTPSPort: preferredHTTPSPort)
            guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
            try await workspace.setEndpoint(endpoint)
            guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
            let descriptor = workspace.descriptor
            let api = CompanionMacExecutionAPI(database: workspace.database,
                commands: SecondaryMacExecutionCommands(workspace: workspace), authentication: authentication,
                descriptor: descriptor, isActive: { [weak self] in self?.generation == attempt && self?.endpoint != nil },
                events: { [workspace] after in try await workspace.events(after: after) })
            self.api = api; self.endpoint = endpoint
            inference = CompanionInferenceHost(authentication: authentication, descriptor: descriptor, directory: directory,
                isActive: { [weak self] in self?.generation == attempt && self?.endpoint != nil })
            let token = try await management.provision(deviceID: descriptor.libraryID, libraryID: descriptor.libraryID, workspaceID: descriptor.id)
            guard generation == attempt, !Task.isCancelled else {
                try await management.revoke(deviceID: descriptor.libraryID)
                throw CancellationError()
            }
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
        generation = UUID(); endpoint = nil; managementGrant = nil; api = nil; inference = nil
        server?.stop(); server = nil
        if let exposure {
            exposure.stop()
            if !stoppingExposures.contains(where: { $0 === exposure }) { stoppingExposures.append(exposure) }
            self.exposure = nil
        }
        if let awakeActivity { ProcessInfo.processInfo.endActivity(awakeActivity); self.awakeActivity = nil }
    }
    func waitUntilStopped() async throws {
        if starting || !managementDeviceIDs.isEmpty {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        // A cancelled startup can add its owned exposure while unwinding. Wait
        // for startup first, then drain the complete cleanup set before release.
        let pending = stoppingExposures
        for exposure in pending { try await exposure.waitUntilStopped() }
        stoppingExposures.removeAll { value in pending.contains { $0 === value } }
    }
    private func resumeIdleWaiters() {
        guard !starting, managementDeviceIDs.isEmpty else { return }
        let waiters = idleWaiters; idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func requestHandler() -> @MainActor @Sendable (CompanionHTTPRequest) async -> CompanionHTTPResponse {
        let attempt = generation
        return { [weak self] request in
            guard let self else { return .error("unavailable", "Execution sharing stopped.", status: 503) }
            return await self.handle(request, attempt: attempt)
        }
    }
    private func handle(_ request: CompanionHTTPRequest, attempt: UUID) async -> CompanionHTTPResponse {
        guard generation == attempt, let api, endpoint != nil else { return .error("unavailable", "Execution sharing is starting or stopped.", status: 503) }
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
            await afterManagementAuthentication()
            // The URL may be identical after a restart; only the exact serving
            // generation authorizes work admitted before crossing an actor.
            guard generation == attempt, endpoint != nil else { return .error("unavailable", "Execution sharing stopped.", status: 503) }
            guard !managementDeviceIDs.contains(device.deviceID) else {
                return .error("operation_in_progress", "This device has another enrollment or revocation in progress. Retry shortly.", status: 409)
            }
            managementDeviceIDs.insert(device.deviceID)
            defer { managementDeviceIDs.remove(device.deviceID); resumeIdleWaiters() }
            if path == "/v1/execution/manage/devices" {
                let credential = try await api.provision(deviceID: device.deviceID)
                guard generation == attempt, endpoint != nil else {
                    // Keep the device gate until cleanup completes so this cannot
                    // revoke a replacement enrollment from the next generation.
                    try await api.revoke(deviceID: device.deviceID)
                    return .error("unavailable", "Execution sharing stopped during enrollment.", status: 503)
                }
                return try .json(credential)
            }
            if path == "/v1/execution/manage/revoke" {
                try await api.revoke(deviceID: device.deviceID)
                guard generation == attempt, endpoint != nil else { return .error("unavailable", "Execution sharing stopped during revocation.", status: 503) }
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
