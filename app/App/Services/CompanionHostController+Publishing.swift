import Foundation
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

extension CompanionHostController {
    /// Adds a Linux host this Mac manages as a member: reads its identity
    /// through the administrative link, signs its entry (its published
    /// library endpoint, else `https://<host>/wovenmatter/`) and hands it the
    /// complete signed record set, so the host trusts this Mac and
    /// synchronizes with every member.
    func ensureLinuxMember(configuration: RemoteWorkspaceConfiguration) async throws {
        guard let model, !model.isBackendFrontend else { return }
        let value = try await model.remoteWorkspaces.memberIdentity(configuration: configuration)
        guard let object = value.objectValue, let deviceID = object["deviceID"]?.stringValue,
              let key = object["publicKey"]?.stringValue.flatMap({ Data(base64Encoded: $0) }), key.count == 32,
              object["kind"]?.stringValue == MemberKind.linux.rawValue,
              let endpoint = (object["libraryEndpoint"]?.stringValue ?? object["endpoints"]?.arrayValue?.first?.stringValue)
                .flatMap(URL.init(string:)) ?? URL(string: "https://" + configuration.hostName + "/wovenmatter/") else {
            throw CompanionAPIError(code: "invalid_member", message: "The Linux host returned an invalid member identity.")
        }
        let directory = try await peerSync.members()
        let current = try await directory.list().members.first { $0.deviceID == deviceID.lowercased() }
        if current == nil || current?.revoked == true || current?.publicKey != key {
            try await directory.add(deviceID: deviceID, kind: .linux, name: configuration.name, publicKey: key, endpoints: [endpoint])
        }
        try await model.remoteWorkspaces.adoptMembers(configuration: configuration, adoption: JSONEncoder().encode(directory.adoption()),
            signer: directory.identity.signer)
        await peerSync.librarySync?.scheduleAll()
    }

    /// Provision through the existing administrative management link. The
    /// observing client's bearer is never sent to the workspace or reused here.
    func ensureExecutionPublisher(workspace: CompanionExecutionWorkspace, configuration: RemoteWorkspaceConfiguration) async throws {
        guard workspace.kind == .linux, workspace.executionDeviceID != nil,
              workspace.id == configuration.id.uuidString.lowercased(), let endpoint,
              let model, let database = model.dashboardStore?.database else { return }
        let identity = try await database.companionLibraryIdentity()
        guard !model.isBackendFrontend, workspace.libraryID == identity.libraryID else { return }
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
