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
        let publisherMatches: Bool
        if current.configured, let id = current.grantID {
            publisherMatches = try await database.companionWorkspacePublisherMatches(workspaceID: workspace.id, grantID: id, endpoint: endpoint)
        } else { publisherMatches = false }
        if !publisherMatches {
            let grant = try await database.issueCompanionWorkspacePublisher(workspaceID: workspace.id, endpoint: endpoint, deviceID: identity.hostDeviceID)
            try await model.remoteWorkspaces.configureExecutionPublisher(configuration: configuration, grant: grant)
        }
        // Library tools have a distinct, revocable grant. A previously valid
        // write-only publisher must not skip this new provisioning step.
        let settings = try await database.toolSettings()
        var harnessDefaults: [String: GatewayJSONValue] = [:]
        let selectionScope = "remote:" + workspace.id
        for runtime in AgentRuntimeKind.allCases {
            let defaults = model.sessionSelectionPreferences.defaults(harness: runtime.rawValue, workspace: selectionScope)
            var value = try JSONDecoder().decode(GatewayJSONValue.self, from: JSONEncoder().encode(defaults)).objectValue ?? [:]
            value["usesProductPermissionDefault"] = .bool(model.sessionSelectionPreferences.usesProductPermissionDefault(harness: runtime.rawValue, workspace: selectionScope))
            harnessDefaults[runtime.rawValue] = .object(value)
        }
        let toolSettings: GatewayJSONValue = .object([
            "enabledByDefault": .array(settings.enabledByDefault.map(\.rawValue).sorted().map(GatewayJSONValue.string)),
            "maximumManagedSessions": .number(Double(settings.maximumManagedSessions)),
            "maximumRunningSessions": .number(Double(settings.maximumRunningSessions)),
            "harnessDefaults": .object(harnessDefaults)
        ])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let settingsFingerprint = String(decoding: try encoder.encode(toolSettings), as: UTF8.self)
        let mcp = try await model.remoteWorkspaces.executionMCPLibraryStatus(configuration: configuration)
        let grantMatches: Bool
        if mcp.configured, let id = mcp.grantID {
            grantMatches = try await database.companionWorkspaceMCPMatches(workspaceID: workspace.id, grantID: id, endpoint: endpoint)
        } else { grantMatches = false }
        if !grantMatches {
            let grant = try await database.issueCompanionWorkspaceMCP(workspaceID: workspace.id, endpoint: endpoint, deviceID: identity.hostDeviceID)
            var payload = try JSONDecoder().decode(GatewayJSONValue.self, from: JSONEncoder().encode(grant)).objectValue ?? [:]
            payload["toolSettings"] = toolSettings
            try await model.remoteWorkspaces.configureExecutionMCPLibrary(configuration: configuration, grant: .object(payload))
        }
        if !grantMatches || mcpSettingsFingerprints[workspace.id] != settingsFingerprint {
            try await model.remoteWorkspaces.configureExecutionMCPSettings(configuration: configuration, settings: toolSettings)
            mcpSettingsFingerprints[workspace.id] = settingsFingerprint
        }
    }
}
