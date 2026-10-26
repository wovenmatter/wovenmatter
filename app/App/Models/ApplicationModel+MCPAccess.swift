import Foundation

extension ApplicationModel {
    /// Enrollment and revocation run in the execution owner, including when this
    /// window is a projection of the background service.
    func controlMCPAccess(_ action: WovenMCPAccessAction) async throws -> WovenMCPAccessSnapshot {
        if isBackendFrontend {
            guard let snapshot = try await sendBackendCommand(.mcpAccess(action)).mcpAccess else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            return snapshot
        }
        guard let tools = agentTools else { throw ApplicationModelError.dashboardStoreUnavailable }
        return try await tools.mcpAccess(action)
    }
}
