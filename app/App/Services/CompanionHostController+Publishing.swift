import Foundation
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

extension CompanionHostController {
    /// Provision through the existing administrative management link. The
    /// observing client's bearer is never sent to the workspace or reused here.
    func ensureExecutionPublisher(workspace: CompanionExecutionWorkspace, configuration: RemoteWorkspaceConfiguration) async throws {
        guard workspace.kind == .linux, workspace.executionDeviceID != nil,
              workspace.id == configuration.id.uuidString.lowercased(), let endpoint,
              let model, let database = model.dashboardStore?.database else { return }
        let identity = try await database.companionLibraryIdentity()
        guard !model.isBackendFrontend, !model.isLibraryClient, workspace.libraryID == identity.libraryID else { return }
        let current = try await model.remoteWorkspaces.executionPublisherStatus(configuration: configuration)
        if current.configured, let id = current.grantID,
           try await database.companionWorkspacePublisherMatches(workspaceID: workspace.id, grantID: id, endpoint: endpoint) { return }
        let grant = try await database.issueCompanionWorkspacePublisher(workspaceID: workspace.id, endpoint: endpoint, deviceID: identity.hostDeviceID)
        try await model.remoteWorkspaces.configureExecutionPublisher(configuration: configuration, grant: grant)
    }
}
