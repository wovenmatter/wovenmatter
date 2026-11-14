import Foundation
import WovenMatterCore
import WovenMatterClient
import WovenMatterLibraryStore

extension LibraryHostController {
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
            throw LibraryAPIError(code: "invalid_member", message: "The Linux host returned an invalid member identity.")
        }
        let directory = try await peerSync.members()
        let current = try await directory.list().members.first { $0.deviceID == deviceID.lowercased() }
        if current == nil || current?.revoked == true || current?.publicKey != key {
            try await directory.add(deviceID: deviceID, kind: .linux, name: configuration.name, publicKey: key, endpoints: [endpoint])
        }
        try await model.remoteWorkspaces.adoptMembers(configuration: configuration, adoption: JSONEncoder().encode(directory.adoption()),
            signer: directory.identity.signer, audience: deviceID.lowercased())
        await peerSync.librarySync?.scheduleAll()
    }

    /// Sends this Mac's Woven MCP tool defaults, session limits and harness
    /// defaults to a Linux host it added, over the administrative link, when
    /// they changed. The host publishes history into its own library and
    /// reaches Mac-only tools with signed member requests, so nothing else is
    /// provisioned here.
    func ensureExecutionToolSettings(workspace: ExecutionWorkspace, configuration: RemoteWorkspaceConfiguration) async throws {
        guard workspace.kind == .linux, workspace.executionDeviceID != nil,
              workspace.id == configuration.id.uuidString.lowercased(),
              let model, let database = model.libraryStore?.database else { return }
        let identity = try await database.libraryIdentity()
        guard !model.isBackendFrontend, workspace.libraryID == identity.libraryID else { return }
        let settings = try await database.toolSettings()
        var harnessDefaults: [String: JSONValue] = [:]
        let selectionScope = "remote:" + workspace.id
        for runtime in AgentRuntimeKind.allCases {
            let defaults = model.sessionSelectionPreferences.defaults(harness: runtime.rawValue, workspace: selectionScope)
            var value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(defaults)).objectValue ?? [:]
            value["usesProductPermissionDefault"] = .bool(model.sessionSelectionPreferences.usesProductPermissionDefault(harness: runtime.rawValue, workspace: selectionScope))
            harnessDefaults[runtime.rawValue] = .object(value)
        }
        let toolSettings: JSONValue = .object([
            "enabledByDefault": .array(settings.enabledByDefault.map(\.rawValue).sorted().map(JSONValue.string)),
            "maximumManagedSessions": .number(Double(settings.maximumManagedSessions)),
            "maximumRunningSessions": .number(Double(settings.maximumRunningSessions)),
            "harnessDefaults": .object(harnessDefaults)
        ])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let settingsFingerprint = String(decoding: try encoder.encode(toolSettings), as: UTF8.self)
        if mcpSettingsFingerprints[workspace.id] != settingsFingerprint {
            try await model.remoteWorkspaces.configureExecutionMCPSettings(configuration: configuration, settings: toolSettings)
            mcpSettingsFingerprints[workspace.id] = settingsFingerprint
        }
    }
}
