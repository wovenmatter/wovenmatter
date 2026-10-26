import Foundation

extension BackendApplicationService {
    func executeMCPAccess(_ action: WovenMCPAccessAction) async throws -> BackendApplicationResult {
        guard let tools = model.agentTools else { throw ApplicationModelError.dashboardStoreUnavailable }
        let snapshot = try await tools.mcpAccess(action)
        await invalidations.publish(scopes: [.settings])
        return .init(mcpAccess: snapshot)
    }
}
