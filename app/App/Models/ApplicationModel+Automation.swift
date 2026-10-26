import Foundation
import WovenMatterClient
import WovenMatterCore

extension ApplicationModel {
    private static func automationSocket() throws -> URL {
        LocalExecutionRole.backendSocketURL(workspaceDirectory: try dashboardSupportDirectory())
            .deletingLastPathComponent().appending(path: "automation.sock")
    }
    func startAutomationHost() {
        guard automationHost == nil, let database = dashboardStore?.database else { return }
        do {
            let host = WovenAutomationHost(assets: workspaceAssets, database: database,
                allowsLocalSurfaces: LocalExecutionRole.current != .backend,
                remoteBrowser: { [weak self] callerID in
                    guard let self else { throw CancellationError() }
                    guard let configuration = try await self.automationRemoteWorkspace(callerID: callerID) else { return nil }
                    return .init(perform: { [weak self] input, requestID in
                        guard let self else { throw CancellationError() }
                        return try await self.remoteWorkspaces.browserMCP(configuration: configuration,
                            callerID: callerID, input: input, requestID: requestID)
                    }, cancel: { [weak self] requestID in
                        guard let self else { return }
                        _ = try await self.remoteWorkspaces.browserMCP(configuration: configuration,
                            callerID: callerID, input: .object(["id": .string(requestID)]),
                            requestID: UUID().uuidString.lowercased(), cancelling: true)
                    })
                })
            // Secondary Mac execution lives in this GUI process. It must not
            // replace the primary library's GUI/backend automation socket.
            if LocalExecutionRole.current != .backend, clientExecutionDirectory == nil {
                let url = try Self.automationSocket()
                try WovenMatterBackendProcess.removeStaleSocketAfterAcquiringLease(url)
                try host.start(at: url)
            }
            automationHost = host
        } catch { workspaceAssets.notice = error.localizedDescription }
    }
    func automationRemoteWorkspace(callerID: String) async throws -> RemoteWorkspaceConfiguration? {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        guard let root = try await database.sessionExecutionRoot(id: callerID), root.workspaceID.hasPrefix("remote:") else { return nil }
        guard let workspaceID = UUID(uuidString: String(root.workspaceID.dropFirst("remote:".count))),
              let configuration = remoteWorkspaces.configuration(id: workspaceID),
              try await database.localACPSession(conversationID: callerID).remoteWorkspaceID == workspaceID else {
            throw WorkspaceToolError.invalid("The browser caller's execution workspace is unavailable.")
        }
        return configuration
    }
    func handleAutomationTool(callerID: String, command: WovenMatterToolCommand,
                              request: WovenMatterToolRequest) async throws -> WovenMatterToolResponse {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        if command.action == "cancel" {
            let target = try command.required("id")
            if target == "all" { try await database.cancelAutomationRequests(callerID: callerID) }
            else { try await database.cancelAutomationRequest(callerID: callerID, requestID: target) }
        }
        let remoteBrowser = command.group == .browser ? (try await automationRemoteWorkspace(callerID: callerID)) != nil : false
        if LocalExecutionRole.current == .backend, !remoteBrowser {
            let client = BackendRPCClient(socketURL: try Self.automationSocket())
            _ = try await client.ping()
            let admitted = command.action == "cancel" ? true : try await database.reserveAutomationRequest(callerID: callerID, request: request)
            let invocation = WovenAutomationInvocation(callerID: callerID, request: request, admitted: admitted)
            return try JSONDecoder().decode(WovenMatterToolResponse.self, from:
                await client.call(method: "automation.call", payload: JSONEncoder().encode(invocation), requestID: request.requestID))
        }
        startAutomationHost()
        guard let host = automationHost else { throw WorkspaceToolError.invalid("Open Woven Matter's workspace to use automation.") }
        let admitted = command.action == "cancel" ? true : try await database.reserveAutomationRequest(callerID: callerID, request: request)
        return await host.handle(.init(callerID: callerID, request: request, admitted: admitted))
    }
    func cancelAutomation(callerID: String) async {
        if LocalExecutionRole.current == .backend {
            await automationHost?.cancel(callerID: callerID)
            let request = WovenMatterToolRequest(arguments: ["browser", "cancel", "--id", "all"])
            _ = try? await handleAutomationTool(callerID: callerID, command: WovenMatterToolCommand(request.arguments), request: request)
        } else {
            if let database = dashboardStore?.database, !database.isReadOnlyProjection {
                try? await database.cancelAutomationRequests(callerID: callerID)
            }
            await automationHost?.cancel(callerID: callerID)
        }
    }
}
