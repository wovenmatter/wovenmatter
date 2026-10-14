import Foundation
import WovenMatterClient
import WovenMatterCore

extension ApplicationModel {
    private static func automationSocket() throws -> URL {
        LocalExecutionRole.backendSocketURL(workspaceDirectory: try dashboardSupportDirectory())
            .deletingLastPathComponent().appending(path: "automation.sock")
    }
    func startAutomationHost() {
        guard LocalExecutionRole.current != .backend, automationHost == nil, let database = dashboardStore?.database else { return }
        do {
            let url = try Self.automationSocket()
            try WovenMatterBackendProcess.removeStaleSocketAfterAcquiringLease(url)
            let host = WovenAutomationHost(assets: workspaceAssets, database: database)
            try host.start(at: url); automationHost = host
        } catch { workspaceAssets.notice = error.localizedDescription }
    }
    func handleAutomationTool(callerID: String, command: WovenMatterToolCommand,
                              request: WovenMatterToolRequest) async throws -> WovenMatterToolResponse {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        if command.action == "cancel" {
            let target = try command.required("id")
            if target == "all" { try await database.cancelAutomationRequests(callerID: callerID) }
            else { try await database.cancelAutomationRequest(callerID: callerID, requestID: target) }
        }
        if LocalExecutionRole.current == .backend {
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
