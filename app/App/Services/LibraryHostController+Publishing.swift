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
    ///
    /// A host that belongs to no library takes this from the Mac that holds
    /// its installer bearer, which this Mac's management link keeps current
    /// over SSH (`RemoteWorkspacesModel.serviceClient`). A host that belongs
    /// to a library takes it only from a Mac it trusts. When it trusts
    /// another library's Macs and not this one, nothing here can change
    /// that, and Settings → Workspaces says so and what to do.
    func ensureLinuxMember(configuration: RemoteWorkspaceConfiguration) async throws {
        guard let model, !model.isBackendFrontend else { return }
        let host = try await linuxHostIdentity(configuration)
        let directory = try await peerSync.members()
        let current = try await directory.list().members.first { $0.deviceID == host.deviceID }
        if current == nil || current?.revoked == true || current?.publicKey != host.key {
            try await directory.add(deviceID: host.deviceID, kind: .linux, name: configuration.name, publicKey: host.key, endpoints: [host.endpoint])
        }
        do {
            try await model.remoteWorkspaces.adoptMembers(configuration: configuration, adoption: JSONEncoder().encode(directory.adoption()),
                signer: directory.identity.signer, audience: host.deviceID)
            model.remoteWorkspaces.setMemberProblem(nil, for: configuration.id)
        } catch {
            if RemoteWorkspaceServiceClient.refusedAdoption(error) {
                model.remoteWorkspaces.setMemberProblem("\(configuration.name) belongs to a library this Mac is not part of, so this Mac cannot manage it. Pair this Mac with a Mac that \(configuration.name) trusts. If there is none, uninstall it here and add it again.", for: configuration.id)
            }
            throw error
        }
        await peerSync.librarySync?.scheduleAll()
    }

    /// The host's member identity, read through this Mac's management link:
    /// its device ID (kept as what its workspace's execution device must be),
    /// its key, and where its library is reached.
    func linuxHostIdentity(_ configuration: RemoteWorkspaceConfiguration) async throws -> (deviceID: String, key: Data, endpoint: URL) {
        guard let model else { throw CancellationError() }
        let value = try await model.remoteWorkspaces.memberIdentity(configuration: configuration)
        guard let object = value.objectValue, let deviceID = object["deviceID"]?.stringValue?.lowercased(), MemberRequestSignature.isDeviceID(deviceID),
              let key = object["publicKey"]?.stringValue.flatMap({ Data(base64Encoded: $0) }), key.count == 32,
              object["kind"]?.stringValue == MemberKind.linux.rawValue,
              let endpoint = (object["libraryEndpoint"]?.stringValue ?? object["endpoints"]?.arrayValue?.first?.stringValue)
                .flatMap(URL.init(string:)) ?? URL(string: "https://" + configuration.hostName + "/wovenmatter/") else {
            throw LibraryAPIError(code: "invalid_member", message: "The Linux host returned an invalid member identity.")
        }
        linuxHostMemberIDs[configuration.id.uuidString.lowercased()] = deviceID
        return (deviceID, key, endpoint)
    }
    func linuxHostMemberID(_ configuration: RemoteWorkspaceConfiguration) async throws -> String {
        try await linuxHostIdentity(configuration).deviceID
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
