import AppKit
import Foundation
import Observation
import Security
import WovenMatterClient
import WovenMatterCore

struct RemoteDatabaseCatalogIdentity: Equatable {
    let configurations: [RemoteWorkspaceConfiguration]
    let credentialEpoch: UUID
    let workspaceEpochs: [UUID: UUID]
    let credentialsEnabled: Bool
}

struct RemoteHarnessChatTarget: Equatable, Identifiable {
    let configuration: RemoteWorkspaceConfiguration
    let harness: RemoteHarnessStatus

    var id: String {
        "\(configuration.id.uuidString):\(harness.id.rawValue)"
    }
}

@MainActor
@Observable
final class RemoteWorkspacesModel {
    struct PendingHostPreparation: Codable, Equatable, Identifiable {
        let configuration: RemoteWorkspaceConfiguration
        let inspection: RemoteWorkspacePreflight
        var id: UUID { configuration.id }
    }

    struct PreparedHarnessAction: Codable, Equatable, Identifiable {
        let action: String
        let harness: RemoteHarnessStatus
        let configuration: RemoteWorkspaceConfiguration
        let preview: RemoteInstallerPreview
        var id: String {
            "\(configuration.id.uuidString):\(harness.id.rawValue):\(action)"
        }
    }

    private(set) var workspaces: [RemoteWorkspaceConfiguration] = []
    private(set) var taskGatewayStatuses: [UUID: RemoteTaskGatewayStatus] = [:]
    private(set) var taskGatewayErrors: [UUID: String] = [:]
    private(set) var changingTaskGatewayIDs: Set<UUID> = []
    var onTaskGatewayChangeRequested: (@MainActor (RemoteWorkspaceConfiguration, Bool) async throws -> RemoteTaskGatewayStatus)?
    private(set) var machineCandidates: [RemoteMachineCandidate] = []
    private(set) var statuses: [UUID: RemoteWorkspaceStatus] = [:]
    private(set) var harnesses: [UUID: [RemoteHarnessStatus]] = [:]
    var onRuntimeMaintenanceChanged: (@MainActor () async -> Void)?
    private var credentialEpoch = UUID()
    private var authorizingWorkspaceIDs: Set<UUID> = []
    private var workspaceEpochs: [UUID: UUID] = [:]
    private var invalidatingWorkspaceIDs: Set<UUID> = []
    private var workspaceRoots: [UUID: String] = [:]
    private(set) var runtimeMaintenance: [UUID: [RemoteRuntimeMaintenance]] = [:]
    private var runtimeChecksVerifiedAfterError: [UUID: Set<AgentRuntimeKind>] = [:]
    private(set) var checkingRuntimeIDs: [UUID: Set<AgentRuntimeKind>] = [:]
    private(set) var runtimeCheckErrors: [UUID: [AgentRuntimeKind: String]] = [:]
    private(set) var runtimeErrors: [UUID: String] = [:]
    private(set) var actionErrors: [UUID: [AgentRuntimeKind: String]] = [:]
    private(set) var workspaceInstances: [UUID: [AgentRuntimeKind: RemoteWorkspaceInstanceStatus]] = [:]
    private(set) var operations: [UUID: RemoteHarnessOperation] = [:]
    private(set) var authenticationSessions: [UUID: RemoteHarnessAuthenticationSession] = [:]
    private(set) var preparedHarnessAction: PreparedHarnessAction?
    private(set) var pendingHostPreparation: PendingHostPreparation?
    private(set) var busyWorkspaceIDs: Set<UUID> = []
    private(set) var isDiscovering = false
    private(set) var isCheckingHost = false
    private(set) var isCreating = false
    private(set) var progress: String?
    private(set) var errorMessage: String?
    private(set) var checkedPreflight: RemoteWorkspacePreflight?
    private(set) var isCredentialAccessEnabled = false
    private var checkedHostKey: String?

    let isBackendProjection: Bool
    var backendRequest: (@MainActor (String, Data) async throws -> Data)?
    private let sshClient = RemoteWorkspaceSSHClient()
    private let credentials = RemoteWorkspaceCredentialStore()
    private var tunnels: [UUID: RemoteWorkspaceTunnel] = [:]
    private let defaults: UserDefaults
    private let storageKey = "wovenmatter.remote-workspaces.v1"
    private let credentialAccessDefaultsKey =
        "wovenmatter.remote-workspaces.credential-access-enabled"

    private struct DefaultAgentAcknowledgment {
        let revision: String
        let identity: RemoteWorkspaceRequestIdentity
    }
    private var defaultAgentAcknowledgments: [UUID: DefaultAgentAcknowledgment] = [:]
    private var defaultAgentSyncTasks: [UUID: (id: UUID, task: Task<Void, any Error>)] = [:]
    private var defaultAgentObservers: [any NSObjectProtocol] = []
    private(set) var signInStatuses: [UUID: [AgentSignInStatus]] = [:]
    private(set) var checkingSignIn: Set<UUID> = []
    private(set) var signInErrors: [UUID: String] = [:]

    func startDefaultAgentMaintenance() {
        guard !isBackendProjection else { return }
        guard defaultAgentObservers.isEmpty else { return }
        ProviderAccountCoordinator.shared.start()
        for name in [DefaultAgentSupport.credentialsChanged, Notification.Name("wovenmatter.default-agent.snapshot-ready")] {
            defaultAgentObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.relayDefaultAgentCredentials() }
            })
        }
        defaultAgentObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                ProviderAccountCoordinator.shared.invalidate()
                self?.defaultAgentAcknowledgments.removeAll()
                await self?.relayDefaultAgentCredentials()
            }
        })
        defaultAgentObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                ProviderAccountCoordinator.shared.invalidate()
                await self?.relayDefaultAgentCredentials()
            }
        })
    }
    private func relayDefaultAgentCredentials() async {
        guard !isBackendProjection else { return }
        _ = try? await ProviderAccountCoordinator.shared.prepare("local")
        guard isCredentialAccessEnabled else { return }
        for workspace in workspaces where tunnels[workspace.id] != nil {
            do { try await ensureDefaultAgent(workspace) }
            catch { signInErrors[workspace.id] = "Built-in credentials could not synchronize. Reconnect this workspace to retry." }
        }
    }
    func refreshSignInStatus(_ configuration: RemoteWorkspaceConfiguration) async {
        if isBackendProjection { await forwardToBackendAndWait(.refreshSignIn(configuration.id)); return }
        guard !checkingSignIn.contains(configuration.id), let identity = try? requestIdentity(configuration) else { return }
        checkingSignIn.insert(configuration.id)
        defer { checkingSignIn.remove(configuration.id) }
        do {
            let client = try await serviceClient(for: configuration)
            let result = try await client.signInStatuses()
            try requireCurrent(identity)
            signInStatuses[configuration.id] = result
            signInErrors[configuration.id] = nil
        } catch {
            guard (try? requireCurrent(identity)) != nil else { return }
            signInErrors[configuration.id] = "Could not check sign-in status. The workspace may be unreachable; previous results are unchanged."
        }
    }

    init(defaults: UserDefaults = .standard, backendProjection: Bool = LocalExecutionRole.current == .frontend) {
        self.defaults = defaults
        self.isBackendProjection = backendProjection
        guard !backendProjection else { return }
        isCredentialAccessEnabled = defaults.bool(
            forKey: credentialAccessDefaultsKey
        )
        load()
    }

    func enableCredentialAccess() {
        if forwardToBackend(.enableCredentialAccess) { return }
        guard !isCredentialAccessEnabled else { return }
        isCredentialAccessEnabled = true
        defaults.set(true, forKey: credentialAccessDefaultsKey)
        let authorizationEpoch = credentialEpoch
        let requestedWorkspaces = workspaces
        // Enabling access is an explicit action. Subsequent automatic refreshes
        // only use credentials that are already available without a prompt.
        Task {
            do {
                for workspace in requestedWorkspaces {
                    guard isCredentialAccessEnabled, credentialEpoch == authorizationEpoch else {
                        throw CancellationError()
                    }
                    try await authorizeCredentialAccess(for: workspace)
                }
                guard isCredentialAccessEnabled, credentialEpoch == authorizationEpoch else { return }
                refreshAll()
            } catch is CancellationError {
                // Disabling access while authorization is pending wins.
            } catch {
                guard isCredentialAccessEnabled, credentialEpoch == authorizationEpoch else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func authorizeCredentialAccess(for configuration: RemoteWorkspaceConfiguration) async throws {
        let identity = try requestIdentity(configuration)
        // A second button or Gateway using the same workspace must not queue
        // another system prompt behind an authorization already in progress.
        guard authorizingWorkspaceIDs.insert(configuration.id).inserted else {
            throw CancellationError()
        }
        defer { authorizingWorkspaceIDs.remove(configuration.id) }
        guard let token = try await credentials.authorizeToken(for: configuration.id), !token.isEmpty else {
            throw RemoteWorkspaceClientError.invalidResponse("The workspace API token is missing from Keychain.")
        }
        try requireCurrent(identity)
    }

    func reconnect(_ configuration: RemoteWorkspaceConfiguration) {
        if forwardToBackend(.reconnect(configuration.id)) { return }
        guard isCredentialAccessEnabled else { return }
        performBusy(configuration) {
            try await self.authorizeCredentialAccess(for: configuration)
            self.statuses[configuration.id] = try await self.sshClient.status(configuration: configuration)
            await self.refreshService(configuration)
        }
    }

    func disableCredentialAccess() {
        if forwardToBackend(.disableCredentialAccess) { return }
        credentialEpoch = UUID()
        isCredentialAccessEnabled = false
        preparedHarnessAction = nil
        runtimeErrors.removeAll()
        runtimeCheckErrors.removeAll()
        actionErrors.removeAll()
        runtimeChecksVerifiedAfterError.removeAll()
        checkingRuntimeIDs.removeAll()
        workspaceRoots.removeAll()
        defaults.set(false, forKey: credentialAccessDefaultsKey)
        statuses.removeAll()
        harnesses.removeAll()
        runtimeMaintenance.removeAll()
        workspaceInstances.removeAll()
        Task { await onRuntimeMaintenanceChanged?() }
        let activeTunnels = Array(tunnels.values)
        tunnels.removeAll()
        Task {
            await credentials.clearCachedTokens()
            for tunnel in activeTunnels { await tunnel.stop() }
        }
    }

    var readyChatTargets: [RemoteHarnessChatTarget] {
        workspaces.flatMap { configuration -> [RemoteHarnessChatTarget] in
            guard isCredentialAccessEnabled, !invalidatingWorkspaceIDs.contains(configuration.id), statuses[configuration.id]?.running == true else { return [] }
            return currentHarnesses(for: configuration).compactMap { harness in
                harness.state == "ready"
                    && !isRuntimeInventoryUnavailable(harness.id, configuration: configuration)
                    && (harness.id == .defaultAgent || self.runtimeMaintenance[configuration.id]?.contains(where: {
                        $0.id == harness.id && $0.enabled && $0.visible && $0.installed && $0.operation?.status != "running"
                    }) == true)
                    ? RemoteHarnessChatTarget(
                        configuration: configuration,
                        harness: harness
                    )
                    : nil
            }
        }.sorted {
            if $0.configuration.name != $1.configuration.name {
                return $0.configuration.name.localizedCaseInsensitiveCompare(
                    $1.configuration.name
                ) == .orderedAscending
            }
            return $0.harness.id.presentationRank < $1.harness.id.presentationRank
        }
    }

    func currentHarnesses(for configuration: RemoteWorkspaceConfiguration) -> [RemoteHarnessStatus] {
        (harnesses[configuration.id] ?? []).map { harness in
            harness.reconcilingOpenCode(
                instance: workspaceInstances[configuration.id]?[.opencode],
                installed: runtimeMaintenance[configuration.id]?.first(where: { $0.id == .opencode })?.installed
            )
        }.sorted { $0.id.presentationRank < $1.id.presentationRank }
    }

    func configuration(id: UUID) -> RemoteWorkspaceConfiguration? {
        workspaces.first { $0.id == id }
    }

    /// Copies the input's files into the workspace container and returns the
    /// input with each file carrying its container path. Local conversations
    /// (`workspaceID == nil`) pass through unchanged.
    func stagingFiles(
        of input: AgentMessageInput,
        in workspaceID: UUID?
    ) async throws -> AgentMessageInput {
        guard !isBackendProjection else { throw BackendRPCError.remote("Remote connections are owned by the background service.") }
        guard let workspaceID, !input.files.isEmpty else { return input }
        guard let configuration = configuration(id: workspaceID) else {
            throw AgentMessageAttachmentError.unsupportedForAgent(
                "This conversation's remote workspace is no longer configured."
            )
        }
        let stager = RemoteAttachmentStager()
        return try await input.mappingFiles { file in
            file.staged(at: try await stager.stage(file, in: configuration))
        }
    }

    func isHarnessReady(
        _ runtimeKind: AgentRuntimeKind,
        in configuration: RemoteWorkspaceConfiguration
    ) -> Bool {
        (runtimeKind == .defaultAgent || isRuntimeEnabled(runtimeKind, in: configuration))
            && !isRuntimeInventoryUnavailable(runtimeKind, configuration: configuration)
            && statuses[configuration.id]?.running == true
            && currentHarnesses(for: configuration).contains {
                $0.id == runtimeKind && $0.state == "ready"
            } && (runtimeKind == .defaultAgent || runtimeMaintenance[configuration.id]?.contains(where: {
                $0.id == runtimeKind && $0.enabled && $0.installed && $0.operation?.status != "running"
            }) == true)
    }

    func libraryConfiguration(id: String) -> RemoteWorkspaceConfiguration? {
        guard isCredentialAccessEnabled, let id = UUID(uuidString: id),
              !invalidatingWorkspaceIDs.contains(id), statuses[id]?.running == true else { return nil }
        return configuration(id: id)
    }

    func refreshAll() {
        if forwardToBackend(.refreshAll) { return }
        guard isCredentialAccessEnabled else { return }
        for workspace in workspaces { refresh(workspace) }
    }

    func isRuntimeEnabled(_ kind: AgentRuntimeKind, in configuration: RemoteWorkspaceConfiguration) -> Bool {
        isCredentialAccessEnabled && self.configuration(id: configuration.id) == configuration
            && !invalidatingWorkspaceIDs.contains(configuration.id)
            && runtimeMaintenance[configuration.id]?.contains { $0.id == kind && $0.enabled && $0.installed } == true
    }

    func refreshRuntimeMaintenanceAtStartup() { checkRuntimeMaintenanceOnActivation() }

    func remoteWorkspaceRoot(for configuration: RemoteWorkspaceConfiguration) -> String {
        workspaceRoots[configuration.id] ?? "/home/.woven-matter"
    }

    func stopOpenCode(for configuration: RemoteWorkspaceConfiguration) async throws {
        let identity = try requestIdentity(configuration)
        let client = try await serviceClient(for: configuration)
        try requireCurrent(identity)
        let status = try await client.workspaceInstance(.opencode, action: "stop")
        try requireCurrent(identity)
        workspaceInstances[configuration.id, default: [:]][.opencode] = status
    }

    /// Called at startup/reopen only; never installs, upgrades, or launches runtimes.
    func checkRuntimeMaintenanceOnActivation() {
        guard !isBackendProjection else { return }
        guard isCredentialAccessEnabled else { return }
        for workspace in workspaces {
            performBusy(workspace) {
                await self.refreshRuntimeMaintenance(workspace, checkLatest: true)
            }
        }
    }

    func runtimeMaintenanceError(_ kind: AgentRuntimeKind, workspaceID: UUID) -> String? {
        runtimeMaintenance[workspaceID]?.first { $0.id == kind }?.operation?.error
            ?? runtimeCheckErrors[workspaceID]?[kind]
            ?? actionErrors[workspaceID]?[kind]
            ?? runtimeErrors[workspaceID]
    }

    func isRuntimeInventoryUnavailable(_ kind: AgentRuntimeKind, configuration: RemoteWorkspaceConfiguration) -> Bool {
        kind != .defaultAgent && runtimeErrors[configuration.id] != nil && runtimeChecksVerifiedAfterError[configuration.id]?.contains(kind) != true
    }

    func checkRuntimeUpdates(_ kind: AgentRuntimeKind, configuration: RemoteWorkspaceConfiguration) {
        if forwardToBackend(.checkRuntimeUpdates(configuration.id, kind)) { return }
        guard let identity = try? requestIdentity(configuration),
              !busyWorkspaceIDs.contains(configuration.id),
              runtimeMaintenance[configuration.id]?.first(where: { $0.id == kind })?.operation?.status != "running",
              checkingRuntimeIDs[configuration.id]?.contains(kind) != true else { return }
        checkingRuntimeIDs[configuration.id, default: []].insert(kind)
        runtimeCheckErrors[configuration.id]?.removeValue(forKey: kind)
        Task {
            defer {
                if credentialEpoch == identity.credentialEpoch && workspaceEpochs[configuration.id] == identity.workspaceEpoch {
                    checkingRuntimeIDs[configuration.id]?.remove(kind)
                }
            }
            do {
                let client = try await serviceClient(for: configuration)
                try requireCurrent(identity)
                let inventory = try await client.checkRuntimeUpdates(kind)
                try requireCurrent(identity)
                guard inventory.id == kind else { throw RemoteWorkspaceClientError.invalidResponse("The runtime check returned a different runtime.") }
                var rows = runtimeMaintenance[configuration.id] ?? []
                if let index = rows.firstIndex(where: { $0.id == kind }) { rows[index] = inventory }
                else { rows.append(inventory) }
                runtimeMaintenance[configuration.id] = rows
                runtimeChecksVerifiedAfterError[configuration.id, default: []].insert(kind)
                runtimeCheckErrors[configuration.id]?.removeValue(forKey: kind)
                await onRuntimeMaintenanceChanged?()
            } catch {
                guard (try? requireCurrent(identity)) != nil else { return }
                runtimeCheckErrors[configuration.id, default: [:]][kind] = "Update check unavailable"
            }
        }
    }

    func setRuntimePreferences(
        _ runtime: RemoteRuntimeMaintenance, configuration: RemoteWorkspaceConfiguration,
        enabled: Bool? = nil, visible: Bool? = nil
    ) {
        if forwardToBackend(.setRuntimePreferences(configuration.id, runtime.id, enabled: enabled, visible: visible)) { return }
        guard enabled != true || runtime.installed else { return }
        performBusy(configuration) {
            let identity = try self.requestIdentity(configuration)
            let client = try await self.serviceClient(for: configuration)
            try self.requireCurrent(identity)
            try await client.setRuntimePreferences(runtime.id, enabled: enabled, visible: visible)
            try self.requireCurrent(identity)
            await self.refreshRuntimeMaintenance(configuration)
        }
    }

    func refreshWorkspaceInstance(_ kind: AgentRuntimeKind, configuration: RemoteWorkspaceConfiguration,
                                  action: String? = nil) {
        if forwardToBackend(.workspaceInstance(configuration.id, kind, action: action)) { return }
        performBusy(configuration) {
            let identity = try self.requestIdentity(configuration)
            let client = try await self.serviceClient(for: configuration)
            try self.requireCurrent(identity)
            if action == "start", !self.isRuntimeEnabled(kind, in: configuration) { throw CancellationError() }
            let status = try await client.workspaceInstance(kind, action: action)
            try self.requireCurrent(identity)
            self.workspaceInstances[configuration.id, default: [:]][kind] = status
        }
    }

    func restartHermes(for configuration: RemoteWorkspaceConfiguration, action: String = "restart") async throws {
        let identity=try requestIdentity(configuration)
        let client=try await serviceClient(for:configuration)
        try requireCurrent(identity)
        _ = try await client.workspaceInstance(.hermes,action:action)
        try requireCurrent(identity)
    }

    func hermesResults(for configuration: RemoteWorkspaceConfiguration, offset: Int) async throws -> [HermesScheduledResult] {
        let identity = try requestIdentity(configuration)
        let client = try await serviceClient(for:configuration)
        try requireCurrent(identity)
        let results = try await client.hermesResults(offset:offset)
        try requireCurrent(identity)
        return results
    }

    func prepareHermesConnection(for configuration: RemoteWorkspaceConfiguration) async throws -> HermesGatewayConnection {
        let identity = try requestIdentity(configuration)
        guard isRuntimeEnabled(.hermes, in: configuration) else { throw RemoteWorkspaceClientError.harnessUnavailable }
        let client = try await serviceClient(for: configuration)
        try requireCurrent(identity)
        let status = try await client.workspaceInstance(.hermes, action: "start")
        try requireCurrent(identity)
        guard status.state == "running", let port = await tunnels[configuration.id]?.localPort,
              let token = try await credentials.token(for: configuration.id) else {
            throw RemoteWorkspaceClientError.invalidResponse("The workspace Hermes Gateway is unavailable.")
        }
        try requireCurrent(identity)
        workspaceInstances[configuration.id, default: [:]][.hermes] = status
        return HermesGatewayConnection(home: "/home/.hermes", port: port, token: token, pid: 0, remoteWorkspaceID: configuration.id)
    }

    func prepareOpenCodeConnection(for configuration: RemoteWorkspaceConfiguration, allowStart: Bool = true) async throws -> OpenCodeConnection {
        let identity = try requestIdentity(configuration)
        guard isRuntimeEnabled(.opencode, in: configuration), runtimeMaintenance[configuration.id]?.contains(where: {
            $0.id == .opencode && $0.installed && $0.enabled && $0.operation?.status != "running"
        }) == true else { throw RemoteWorkspaceClientError.harnessUnavailable }
        let client = try await serviceClient(for: configuration)
        try requireCurrent(identity)
        let health = try await client.health()
        try requireCurrent(identity)
        guard isRuntimeEnabled(.opencode, in: configuration) else { throw CancellationError() }
        let status = try await client.workspaceInstance(.opencode, action: allowStart ? "start" : nil)
        try requireCurrent(identity)
        workspaceRoots[configuration.id] = health.workspaceRoot
        workspaceInstances[configuration.id, default: [:]][.opencode] = status
        guard status.state == "running", let port = await tunnels[configuration.id]?.localPort,
              let token = try await credentials.token(for: configuration.id) else {
            throw RemoteWorkspaceClientError.invalidResponse(status.lastError ?? "The workspace OpenCode server is unavailable.")
        }
        try requireCurrent(identity)
        guard isRuntimeEnabled(.opencode, in: configuration) else { throw CancellationError() }
        return try OpenCodeConnection(
            identity: "remote-workspace:\(configuration.id.uuidString.lowercased())",
            url: URL(string: "http://127.0.0.1:\(port)")!, password: "",
            version: status.version, servicePathPrefix: "/v1/workspace-instances/opencode", bearerToken: token
        )
    }

    private func refreshRuntimeMaintenance(_ configuration: RemoteWorkspaceConfiguration,
                                          checkLatest: Bool = false) async {
        guard let identity = try? requestIdentity(configuration) else { return }
        let checking: Set<AgentRuntimeKind> = checkLatest
            ? Set((runtimeMaintenance[configuration.id] ?? []).filter(\.enabled).map(\.id)) : []
        checkingRuntimeIDs[configuration.id, default: []].formUnion(checking)
        defer {
            if credentialEpoch == identity.credentialEpoch && workspaceEpochs[configuration.id] == identity.workspaceEpoch {
                checkingRuntimeIDs[configuration.id]?.subtract(checking)
            }
        }
        do {
            let client = try await serviceClient(for: configuration)
            try requireCurrent(identity)
            let inventory = try await client.runtimeMaintenance(checkLatest: checkLatest)
            try requireCurrent(identity)
            runtimeMaintenance[configuration.id] = inventory
            runtimeErrors.removeValue(forKey: configuration.id)
            runtimeChecksVerifiedAfterError.removeValue(forKey: configuration.id)
            runtimeCheckErrors.removeValue(forKey: configuration.id)
            await onRuntimeMaintenanceChanged?()
        } catch {
            guard (try? requireCurrent(identity)) != nil else { return }
            runtimeChecksVerifiedAfterError.removeValue(forKey: configuration.id)
            runtimeErrors[configuration.id] = "Runtime inventory unavailable. Update this workspace service if it predates runtime management. " + error.localizedDescription
        }
    }

    var databaseCatalogIdentity: RemoteDatabaseCatalogIdentity {
        RemoteDatabaseCatalogIdentity(configurations: workspaces, credentialEpoch: credentialEpoch,
                                      workspaceEpochs: workspaceEpochs, credentialsEnabled: isCredentialAccessEnabled)
    }

    // Validate both sides of every suspension so credentials or destination changes
    // cannot publish a result belonging to an obsolete workspace connection.
    func databases(for configuration: RemoteWorkspaceConfiguration) async throws -> [RemoteAgentDatabase] {
        if isBackendProjection {
            let response = try await requestBackend(.databases(configuration.id))
            guard let value = response.databases else { throw BackendRPCError.remote("The background service returned no database result.") }; return value
        }
        return try await databaseRequest(configuration) { try await $0.databases() }
    }

    func createDatabase(name: String, preference: AgentDatabasePreference,
                        in configuration: RemoteWorkspaceConfiguration) async throws -> RemoteAgentDatabase {
        if isBackendProjection {
            let response = try await requestBackend(.createDatabase(configuration.id, name: name, preference: preference))
            guard let value = response.database else { throw BackendRPCError.remote("The background service returned no database result.") }; return value
        }
        return try await databaseRequest(configuration) { try await $0.createDatabase(name: name, preference: preference) }
    }

    func setDatabasePreference(_ preference: AgentDatabasePreference, databaseID: String,
                               in configuration: RemoteWorkspaceConfiguration) async throws {
        if isBackendProjection { _ = try await requestBackend(.databasePreference(configuration.id, databaseID, preference)); return }
        _ = try await databaseRequest(configuration) { try await $0.setDatabasePreference(preference, databaseID: databaseID) }
    }

    func databaseData(for link: DatabaseArtifactLink,
                      in configuration: RemoteWorkspaceConfiguration) async throws -> RemoteDatabaseData {
        if isBackendProjection {
            let response = try await requestBackend(.databaseData(configuration.id, link))
            guard let value = response.databaseData else { throw BackendRPCError.remote("The background service returned no database result.") }; return value
        }
        return try await databaseRequest(configuration) { try await $0.databaseData(for: link) }
    }

    func publishTaskGatewaySchedules(_ publication: RemoteTaskGatewayPublication,
                                     for configuration: RemoteWorkspaceConfiguration) async throws -> RemoteTaskGatewayStatus {
        try await databaseRequest(configuration) { try await $0.publishTaskGatewaySchedules(publication) }
    }

    func taskGatewaySchedules(for configuration: RemoteWorkspaceConfiguration) async throws -> RemoteTaskGatewaySchedules {
        try await databaseRequest(configuration) { try await $0.taskGatewaySchedules() }
    }

    func taskGatewayResults(after cursor: String = "0", for configuration: RemoteWorkspaceConfiguration) async throws -> RemoteTaskGatewayResults {
        try await databaseRequest(configuration) { try await $0.taskGatewayResults(after: cursor) }
    }

    func taskGatewayStatus(for configuration: RemoteWorkspaceConfiguration) async throws -> RemoteTaskGatewayStatus {
        try await databaseRequest(configuration) { try await $0.taskGatewayStatus() }
    }

    func setTaskGatewayEnabled(_ enabled: Bool, for configuration: RemoteWorkspaceConfiguration) async throws -> RemoteTaskGatewayStatus {
        try await databaseRequest(configuration) { try await $0.setTaskGatewayEnabled(enabled) }
    }

    func refreshTaskGateway(_ configuration: RemoteWorkspaceConfiguration) async {
        if isBackendProjection { await forwardToBackendAndWait(.refreshTaskGateway(configuration.id)); return }
        guard let identity = try? requestIdentity(configuration) else { return }
        do {
            let status = try await taskGatewayStatus(for: configuration)
            try requireCurrent(identity)
            taskGatewayStatuses[configuration.id] = status
            taskGatewayErrors[configuration.id] = nil
        } catch {
            guard (try? requireCurrent(identity)) != nil else { return }
            taskGatewayErrors[configuration.id] = error.localizedDescription
        }
    }

    func setBackgroundExecution(_ enabled: Bool, for configuration: RemoteWorkspaceConfiguration) {
        if forwardToBackend(.backgroundExecution(configuration.id, enabled)) { return }
        guard !changingTaskGatewayIDs.contains(configuration.id),
              (try? requestIdentity(configuration)) != nil,
              let index = workspaces.firstIndex(where: { $0.id == configuration.id }) else { return }
        // Persist intent before contacting the service: a disconnected disable must
        // not be undone by the next synchronization tick or app restart.
        workspaces[index].backgroundExecutionEnabled = enabled
        save()
        let updated = workspaces[index]
        guard let identity = try? requestIdentity(updated) else { return }
        changingTaskGatewayIDs.insert(configuration.id)
        Task {
            defer { changingTaskGatewayIDs.remove(configuration.id) }
            do {
                guard let onTaskGatewayChangeRequested else {
                    throw RemoteWorkspaceClientError.invalidResponse("Background execution is not ready. Try again shortly.")
                }
                let status = try await onTaskGatewayChangeRequested(updated, enabled)
                try requireCurrent(identity)
                guard status.enabled == enabled else {
                    throw RemoteWorkspaceClientError.invalidResponse("The remote gateway did not confirm this setting.")
                }
                taskGatewayStatuses[configuration.id] = status
                taskGatewayErrors[configuration.id] = nil
            } catch {
                guard (try? requireCurrent(identity)) != nil else { return }
                taskGatewayErrors[configuration.id] = error.localizedDescription
            }
        }
    }

    private func databaseRequest<Value: Sendable>(
        _ configuration: RemoteWorkspaceConfiguration,
        operation: (RemoteWorkspaceServiceClient) async throws -> Value
    ) async throws -> Value {
        guard isCredentialAccessEnabled else {
            throw RemoteWorkspaceClientError.invalidResponse("Enable credential access in Settings to connect.")
        }
        let identity = try requestIdentity(configuration)
        let client = try await serviceClient(for: configuration)
        try requireCurrent(identity)
        let value = try await operation(client)
        try requireCurrent(identity)
        return value
    }

    private func requestIdentity(_ configuration: RemoteWorkspaceConfiguration) throws -> RemoteWorkspaceRequestIdentity {
        guard !isBackendProjection else { throw BackendRPCError.remote("Remote connections are owned by the background service.") }
        let epoch = workspaceEpochs[configuration.id] ?? UUID()
        workspaceEpochs[configuration.id] = epoch
        let identity = RemoteWorkspaceRequestIdentity(configuration: configuration,
                                                     credentialEpoch: credentialEpoch, workspaceEpoch: epoch)
        try requireCurrent(identity)
        return identity
    }

    private func requireCurrent(_ identity: RemoteWorkspaceRequestIdentity) throws {
        guard !invalidatingWorkspaceIDs.contains(identity.configuration.id),
              identity.isCurrent(configuration: configuration(id: identity.configuration.id),
                                 credentialsEnabled: isCredentialAccessEnabled,
                                 credentialEpoch: credentialEpoch,
                                 workspaceEpoch: workspaceEpochs[identity.configuration.id] ?? UUID()) else {
            throw CancellationError()
        }
    }

    func prepareOpenClawGateway(
        for configuration: RemoteWorkspaceConfiguration
    ) async throws -> RemoteOpenClawGatewayConnection {
        let identity = try requestIdentity(configuration)
        guard isRuntimeEnabled(.openclaw, in: configuration),
              runtimeMaintenance[configuration.id]?.first(where: { $0.id == .openclaw })?.operation?.status != "running" else {
            throw RemoteWorkspaceClientError.harnessUnavailable
        }
        if let knownHarnesses = harnesses[configuration.id],
           !knownHarnesses.contains(where: {
               $0.id == .openclaw && $0.state == "ready"
           }) {
            throw RemoteWorkspaceClientError.harnessUnavailable
        }
        let client = try await serviceClient(for: configuration)
        try requireCurrent(identity)
        var status = try await client.startOpenClawGateway()
        try requireCurrent(identity)
        var attempts = 0
        while status.state != "running", attempts < 12 {
            try await Task.sleep(for: .milliseconds(150))
            try requireCurrent(identity)
            status = try await client.openClawGatewayStatus()
            try requireCurrent(identity)
            attempts += 1
        }
        guard status.state == "running" else {
            throw RemoteWorkspaceClientError.invalidResponse(
                status.lastError ?? "The remote OpenClaw Gateway did not become ready."
            )
        }
        guard let token = try await credentials.token(for: configuration.id) else {
            throw RemoteWorkspaceClientError.invalidResponse(
                "The workspace API token is missing from Keychain."
            )
        }
        guard let localPort = await tunnels[configuration.id]?.localPort else {
            throw RemoteWorkspaceClientError.invalidResponse(
                "The SSH loopback tunnel did not report a local port."
            )
        }
        try requireCurrent(identity)
        guard isRuntimeEnabled(.openclaw, in: configuration) else { throw CancellationError() }
        return RemoteOpenClawGatewayConnection(
            endpoint: OpenClawGatewayEndpoint(
                url: URL(
                    string: "ws://127.0.0.1:\(localPort)\(status.socketPath)"
                )!,
                authorization: .remoteWorkspace
            ),
            requestHeaders: ["Authorization": "Bearer \(token)"]
        )
    }

    func discoverMachines() {
        if forwardToBackend(.discoverMachines) { return }
        guard !isDiscovering else { return }
        isDiscovering = true
        errorMessage = nil
        Task {
            defer { isDiscovering = false }
            do {
                machineCandidates = try await Task.detached {
                    try RemoteMachineDiscovery.tailnetMachines()
                }.value
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func preflight(
        hostName: String,
        userName: String
    ) -> RemoteWorkspacePreflight? {
        checkedHostKey == Self.hostKey(
            hostName: hostName,
            userName: userName
        )
            ? checkedPreflight
            : nil
    }

    func checkHost(hostName: String, userName: String) {
        if forwardToBackend(.checkHost(hostName: hostName, userName: userName)) { return }
        guard !isCheckingHost else { return }
        let cleanHost = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else {
            errorMessage = "Enter an SSH hostname before checking the host."
            return
        }
        isCheckingHost = true
        errorMessage = nil
        Task {
            defer { isCheckingHost = false }
            do {
                _ = try RemoteWorkspaceSSHClient.validatedDestination(
                    hostName: cleanHost,
                    userName: cleanUser.nilIfEmpty
                )
                let result = try await sshClient.preflight(
                    hostName: cleanHost,
                    userName: cleanUser.nilIfEmpty
                )
                checkedHostKey = Self.hostKey(
                    hostName: cleanHost,
                    userName: cleanUser
                )
                checkedPreflight = result
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func create(
        name: String,
        workspaceID: String,
        hostName: String,
        userName: String,
        port: Int,
        memoryLimit: String,
        swapLimit: String
    ) {
        if forwardToBackend(.create(name: name, workspaceID: workspaceID, hostName: hostName, userName: userName, port: port, memoryLimit: memoryLimit, swapLimit: swapLimit)) { return }
        guard isCredentialAccessEnabled else {
            errorMessage = "Enable credential access before creating a remote workspace."
            return
        }
        guard !isCreating else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHost = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanID.isEmpty, !cleanHost.isEmpty else {
            errorMessage = "Enter a name, workspace ID, and SSH hostname."
            return
        }
        let configuration = RemoteWorkspaceConfiguration(
            name: cleanName,
            workspaceID: cleanID,
            hostName: cleanHost,
            userName: userName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            remotePort: port,
            memoryLimit: memoryLimit.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            swapLimit: swapLimit.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        do {
            try RemoteWorkspaceSSHClient.validateConfiguration(configuration)
            if workspaces.contains(where: {
                Self.hostKey(
                    hostName: $0.hostName,
                    userName: $0.userName ?? ""
                ) == Self.hostKey(
                    hostName: configuration.hostName,
                    userName: configuration.userName ?? ""
                ) && $0.workspaceID == configuration.workspaceID
            }) {
                throw RemoteWorkspaceClientError.invalidResourceLimit(
                    "That workspace ID is already configured on this SSH host."
                )
            }
            if workspaces.contains(where: {
                Self.hostKey(
                    hostName: $0.hostName,
                    userName: $0.userName ?? ""
                ) == Self.hostKey(
                    hostName: configuration.hostName,
                    userName: configuration.userName ?? ""
                ) && $0.remotePort == configuration.remotePort
            }) {
                throw RemoteWorkspaceClientError.invalidResourceLimit(
                    "That remote loopback port is already assigned to another workspace on this SSH host."
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isCreating = true
        errorMessage = nil
        Task {
            defer {
                isCreating = false
                progress = nil
            }
            do {
                progress = "Checking the remote machine…"
                let preflight = try await sshClient.preflight(
                    hostName: configuration.hostName,
                    userName: configuration.userName
                )
                checkedHostKey = Self.hostKey(
                    hostName: configuration.hostName,
                    userName: configuration.userName ?? ""
                )
                checkedPreflight = preflight
                if preflight.preparationRequired == true {
                    guard preflight.canPrepare == true else {
                        let blockers = preflight.blockingIssues ?? []
                        throw RemoteWorkspaceClientError.commandFailed(
                            (blockers.isEmpty ? preflight.limitations : blockers)
                                .joined(separator: " ")
                        )
                    }
                    pendingHostPreparation = PendingHostPreparation(
                        configuration: configuration,
                        inspection: preflight
                    )
                    return
                }
                guard preflight.ready else {
                    throw RemoteWorkspaceClientError.commandFailed(
                        preflight.limitations.joined(separator: " ")
                    )
                }
                try Self.requireCapabilities(
                    preflight,
                    for: configuration
                )
                try await provision(configuration)
            } catch {
                try? await credentials.deleteToken(for: configuration.id, allowInteraction: false)
                errorMessage = error.localizedDescription
            }
        }
    }

    func authorizeHostPreparation() {
        if forwardToBackend(.authorizeHostPreparation) { return }
        guard let pending = pendingHostPreparation, !isCreating else { return }
        pendingHostPreparation = nil
        isCreating = true
        errorMessage = nil
        Task {
            defer {
                isCreating = false
                progress = nil
            }
            do {
                progress = "Preparing the authorized remote host…"
                _ = try await sshClient.prepareHost(
                    hostName: pending.configuration.hostName,
                    userName: pending.configuration.userName
                )
                progress = "Verifying the prepared host…"
                let verified = try await sshClient.preflight(
                    hostName: pending.configuration.hostName,
                    userName: pending.configuration.userName
                )
                checkedHostKey = Self.hostKey(
                    hostName: pending.configuration.hostName,
                    userName: pending.configuration.userName ?? ""
                )
                checkedPreflight = verified
                guard verified.ready,
                      verified.preparationRequired != true else {
                    throw RemoteWorkspaceClientError.commandFailed(
                        verified.limitations.joined(separator: " ")
                    )
                }
                try Self.requireCapabilities(
                    verified,
                    for: pending.configuration
                )
                try await provision(pending.configuration)
            } catch {
                try? await credentials.deleteToken(for: pending.configuration.id, allowInteraction: false)
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelHostPreparation() {
        if forwardToBackend(.cancelHostPreparation) { return }
        pendingHostPreparation = nil
    }

    func refresh(_ configuration: RemoteWorkspaceConfiguration) {
        if forwardToBackend(.refresh(configuration.id)) { return }
        guard isCredentialAccessEnabled else { return }
        performBusy(configuration) {
            self.statuses[configuration.id] = try await self.sshClient.status(
                configuration: configuration
            )
            await self.refreshService(configuration)
        }
    }

    func lifecycle(
        _ action: RemoteWorkspaceLifecycleAction,
        configuration: RemoteWorkspaceConfiguration
    ) {
        if forwardToBackend(.lifecycle(configuration.id, action.rawValue)) { return }
        performBusy(configuration) {
            self.statuses[configuration.id] = try await self.sshClient.lifecycle(
                action,
                configuration: configuration
            )
            if action != .stop { await self.refreshService(configuration) }
        }
    }

    func updateContainer(_ configuration: RemoteWorkspaceConfiguration) {
        if forwardToBackend(.updateContainer(configuration.id)) { return }
        performBusy(configuration) {
            self.progress = "Building the updated workspace image…"
            defer { self.progress = nil }
            try await self.sshClient.deployService(
                hostName: configuration.hostName,
                userName: configuration.userName
            )
            self.progress = "Recreating the container and preserving its home…"
            self.statuses[configuration.id] = try await self.sshClient.update(
                configuration: configuration
            )
            await self.refreshService(configuration)
        }
    }

    func applyResources(
        _ configuration: RemoteWorkspaceConfiguration,
        memoryLimit: String,
        swapLimit: String
    ) {
        if forwardToBackend(.resources(configuration.id, memoryLimit: memoryLimit, swapLimit: swapLimit)) { return }
        var updated = configuration
        updated.memoryLimit = memoryLimit
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        updated.swapLimit = swapLimit
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        performBusy(configuration) {
            self.checkingRuntimeIDs.removeValue(forKey: configuration.id)
            self.actionErrors.removeValue(forKey: configuration.id)
            self.workspaceEpochs[configuration.id] = UUID()
            self.invalidatingWorkspaceIDs.insert(configuration.id)
            defer { self.invalidatingWorkspaceIDs.remove(configuration.id) }
            try RemoteWorkspaceSSHClient.validateConfiguration(updated)
            let preflight = try await self.sshClient.preflight(
                hostName: updated.hostName,
                userName: updated.userName
            )
            try Self.requireCapabilities(preflight, for: updated)
            self.statuses[configuration.id] = try await self.sshClient.update(
                configuration: updated
            )
            if let index = self.workspaces.firstIndex(where: {
                $0.id == configuration.id
            }) {
                self.workspaces[index] = updated
                self.save()
            }
            self.invalidatingWorkspaceIDs.remove(configuration.id)
            await self.refreshService(updated)
        }
    }

    func delete(
        _ configuration: RemoteWorkspaceConfiguration,
        removePersistentData: Bool
    ) {
        if forwardToBackend(.delete(configuration.id, removePersistentData: removePersistentData)) { return }
        guard isCredentialAccessEnabled else {
            errorMessage = "Enable credential access before deleting a remote workspace."
            return
        }
        performBusy(configuration) {
            self.checkingRuntimeIDs.removeValue(forKey: configuration.id)
            self.actionErrors.removeValue(forKey: configuration.id)
            self.workspaceEpochs[configuration.id] = UUID()
            self.invalidatingWorkspaceIDs.insert(configuration.id)
            defer { self.invalidatingWorkspaceIDs.remove(configuration.id) }
            try await self.sshClient.delete(
                configuration: configuration,
                removePersistentData: removePersistentData
            )
            await self.tunnels[configuration.id]?.stop()
            self.tunnels.removeValue(forKey: configuration.id)
            try await self.credentials.deleteToken(for: configuration.id)
            self.workspaces.removeAll { $0.id == configuration.id }
            self.statuses.removeValue(forKey: configuration.id)
            self.harnesses.removeValue(forKey: configuration.id)
            self.authenticationSessions.removeValue(forKey: configuration.id)
            self.runtimeMaintenance.removeValue(forKey: configuration.id)
            self.workspaceInstances.removeValue(forKey: configuration.id)
            self.save()
            await self.onRuntimeMaintenanceChanged?()
        }
    }

    func performHarnessAction(
        _ action: String,
        harness: RemoteHarnessStatus,
        configuration: RemoteWorkspaceConfiguration
    ) {
        if forwardToBackend(.performHarness(configuration.id, harness.id, action)) { return }
        performBusy(configuration) {
            let client = try await self.serviceClient(for: configuration)
            var operation = try await client.perform(
                harnessID: harness.id,
                action: action
            )
            self.operations[configuration.id] = operation
            var checks = 0
            while operation.status == "running", checks < 300 {
                try await Task.sleep(for: .seconds(1))
                operation = try await client.operation(id: operation.id)
                self.operations[configuration.id] = operation
                checks += 1
            }
            self.harnesses[configuration.id] = try await client.harnesses()
        }
    }

    func prepareHarnessAction(
        _ action: String,
        harness: RemoteHarnessStatus,
        configuration: RemoteWorkspaceConfiguration
    ) {
        if forwardToBackend(.prepareHarness(configuration.id, harness.id, action)) { return }
        guard action == "install" || action == "update",
              checkingRuntimeIDs[configuration.id]?.contains(harness.id) != true else { return }
        if action == "update", harness.id == .hermes,
           runtimeMaintenance[configuration.id]?.first(where: { $0.id == .hermes })?.installed == true {
            performBusy(configuration, actionErrorRuntimeKind: harness.id) {
                try await self.runRuntimeMaintenance(.hermes, action: "update", configuration: configuration)
            }
            return
        }
        performBusy(configuration, actionErrorRuntimeKind: harness.id) {
            let identity = try self.requestIdentity(configuration)
            let client = try await self.serviceClient(for: configuration)
            try self.requireCurrent(identity)
            let preview: RemoteInstallerPreview
            do {
                preview = try await client.installerPreview(harnessID: harness.id)
            } catch {
                await self.refreshRuntimeMaintenance(configuration)
                throw error
            }
            try self.requireCurrent(identity)
            self.preparedHarnessAction = PreparedHarnessAction(
                action: action,
                harness: harness,
                configuration: configuration,
                preview: preview
            )
        }
    }

    func confirmPreparedHarnessAction(
        workspaceID: UUID? = nil,
        harnessID: AgentRuntimeKind? = nil,
        action: String? = nil
    ) {
        if forwardToBackend(.confirmHarness(workspaceID, harnessID, action)) { return }
        guard let preparedHarnessAction,
              workspaceID == nil || preparedHarnessAction.configuration.id == workspaceID,
              harnessID == nil || preparedHarnessAction.harness.id == harnessID,
              action == nil || preparedHarnessAction.action == action else { return }
        self.preparedHarnessAction = nil
        performBusy(
            preparedHarnessAction.configuration,
            actionErrorRuntimeKind: preparedHarnessAction.harness.id
        ) {
            try await self.runRuntimeMaintenance(
                preparedHarnessAction.harness.id, action: preparedHarnessAction.action,
                configuration: preparedHarnessAction.configuration,
                sourceSHA256: preparedHarnessAction.preview.sha256,
                packageSpec: preparedHarnessAction.preview.packageSpec
            )
        }
    }

    private func runRuntimeMaintenance(_ kind: AgentRuntimeKind, action: String,
                                       configuration: RemoteWorkspaceConfiguration,
                                       sourceSHA256: String? = nil, packageSpec: String? = nil) async throws {
        let identity = try requestIdentity(configuration)
        let client = try await serviceClient(for: configuration)
        try requireCurrent(identity)
        var operation = try await client.maintainRuntime(kind, action: action,
                                                       sourceSHA256: sourceSHA256, packageSpec: packageSpec)
        try requireCurrent(identity)
        operations[configuration.id] = operation
        await refreshRuntimeMaintenance(configuration)
        var checks = 0
        while operation.status == "running", checks < 900 {
            try await Task.sleep(for: .seconds(1))
            try requireCurrent(identity)
            operation = try await client.operation(id: operation.id)
            try requireCurrent(identity)
            operations[configuration.id] = operation
            checks += 1
        }
        await refreshRuntimeMaintenance(configuration)
        try requireCurrent(identity)
        let updatedHarnesses = try await client.harnesses()
        try requireCurrent(identity)
        harnesses[configuration.id] = updatedHarnesses
    }

    func cancelPreparedHarnessAction(
        workspaceID: UUID? = nil,
        harnessID: AgentRuntimeKind? = nil,
        action: String? = nil
    ) {
        if forwardToBackend(.cancelHarness(workspaceID, harnessID, action)) { return }
        guard let preparedHarnessAction,
              workspaceID == nil || preparedHarnessAction.configuration.id == workspaceID,
              harnessID == nil || preparedHarnessAction.harness.id == harnessID,
              action == nil || preparedHarnessAction.action == action else { return }
        self.preparedHarnessAction = nil
    }

    func startHarnessSignIn(
        harness: RemoteHarnessStatus,
        method: RemoteHarnessSetupMethod,
        configuration: RemoteWorkspaceConfiguration
    ) {
        if forwardToBackend(.signIn(configuration.id, harness.id, method.id)) { return }
        performBusy(configuration) {
            let client = try await self.serviceClient(for: configuration)
            var session = try await client.startSignIn(
                harnessID: harness.id,
                methodID: method.id
            )
            self.authenticationSessions[configuration.id] = session
            var checks = 0
            while session.state == "waiting_for_user", checks < 1_800 {
                try await Task.sleep(for: .seconds(1))
                session = try await client.authenticationSession(id: session.id)
                self.authenticationSessions[configuration.id] = session
                checks += 1
            }
            self.harnesses[configuration.id] = try await client.harnesses()
        }
    }

    func submitAuthorizationCode(
        _ code: String,
        configuration: RemoteWorkspaceConfiguration
    ) {
        if forwardToBackend(.authorizationCode(configuration.id, code)) { return }
        guard let session = authenticationSessions[configuration.id],
              session.state == "waiting_for_user",
              session.acceptsAuthorizationCode else { return }
        errorMessage = nil
        Task {
            do {
                let client = try await serviceClient(for: configuration)
                try await client.submitAuthorizationCode(
                    id: session.id,
                    code: code
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelHarnessSignIn(configuration: RemoteWorkspaceConfiguration) {
        if forwardToBackend(.cancelSignIn(configuration.id)) { return }
        guard let session = authenticationSessions[configuration.id] else { return }
        Task {
            do {
                let client = try await serviceClient(for: configuration)
                try await client.cancelAuthenticationSession(id: session.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performBusy(
        _ configuration: RemoteWorkspaceConfiguration,
        actionErrorRuntimeKind: AgentRuntimeKind? = nil,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard let identity = try? requestIdentity(configuration),
              busyWorkspaceIDs.insert(configuration.id).inserted else { return }
        errorMessage = nil
        if let actionErrorRuntimeKind {
            actionErrors[configuration.id]?.removeValue(forKey: actionErrorRuntimeKind)
        }
        Task {
            defer { busyWorkspaceIDs.remove(configuration.id) }
            do {
                try requireCurrent(identity)
                try await operation()
            } catch is CancellationError {
                // Credential or destination changes invalidate this request silently.
            } catch {
                guard isCredentialAccessEnabled, credentialEpoch == identity.credentialEpoch,
                      self.configuration(id: configuration.id) == configuration else { return }
                errorMessage = error.localizedDescription
                if let actionErrorRuntimeKind {
                    actionErrors[configuration.id, default: [:]][actionErrorRuntimeKind] = error.localizedDescription
                }
            }
        }
    }

    func synchronizeDefaultAgent(_ configuration: RemoteWorkspaceConfiguration) async throws {
        if isBackendProjection { _ = try await requestBackend(.synchronizeDefaultAgent(configuration.id)); return }
        try await waitForDefaultAgentSync(configuration.id)
        defaultAgentAcknowledgments.removeValue(forKey: configuration.id)
        try await ensureDefaultAgent(configuration)
    }
    private func clearDefaultAgentSync(_ workspaceID: UUID, operationID: UUID) {
        if defaultAgentSyncTasks[workspaceID]?.id == operationID {
            defaultAgentSyncTasks[workspaceID] = nil
        }
    }
    private func waitForDefaultAgentSync(_ workspaceID: UUID) async throws {
        guard let pending = defaultAgentSyncTasks[workspaceID] else { return }
        defer { clearDefaultAgentSync(workspaceID, operationID: pending.id) }
        try await pending.task.value
    }
    func ensureDefaultAgent(_ configuration: RemoteWorkspaceConfiguration) async throws {
        let identity = try requestIdentity(configuration)
        let payload = try await ProviderAccountCoordinator.shared.prepare(configuration.id.uuidString.lowercased())
        try requireCurrent(identity)
        if let ack = defaultAgentAcknowledgments[configuration.id], ack.revision == payload.revision, ack.identity == identity { return }
        if defaultAgentSyncTasks[configuration.id] != nil {
            try await waitForDefaultAgentSync(configuration.id)
            return try await ensureDefaultAgent(configuration)
        }
        let task = Task {
            let client = try await serviceClient(for: configuration)
            try requireCurrent(identity)
            let receipt = try await client.configureDefaultAgent(payload.data())
            try requireCurrent(identity)
            guard receipt.saved, receipt.revision == payload.revision else {
                throw DefaultAgentError.message("The workspace did not acknowledge the current Built-in credentials.")
            }
            defaultAgentAcknowledgments[configuration.id] = .init(revision: receipt.revision, identity: identity)
        }
        let operationID = UUID()
        defaultAgentSyncTasks[configuration.id] = (operationID, task)
        do { try await task.value; clearDefaultAgentSync(configuration.id, operationID: operationID) }
        catch {
            clearDefaultAgentSync(configuration.id, operationID: operationID)
            defaultAgentAcknowledgments.removeValue(forKey: configuration.id)
            throw error
        }
    }

    private func refreshService(
        _ configuration: RemoteWorkspaceConfiguration
    ) async {
        guard let identity = try? requestIdentity(configuration) else { return }
        // A lifecycle snapshot from before this refresh must not override newer
        // harness inventory (for example after an external stop or container restart).
        // Responses from lifecycle requests arriving during/after these awaits stay
        // in the cache and remain authoritative over the pre-launch inventory.
        workspaceInstances[configuration.id]?.removeValue(forKey: .opencode)
        do {
            let client = try await serviceClient(for: configuration)
            try requireCurrent(identity)
            let health = try await client.health()
            try requireCurrent(identity)
            let inventory = try await client.harnesses()
            try requireCurrent(identity)
            workspaceRoots[configuration.id] = health.workspaceRoot
            harnesses[configuration.id] = inventory
            if inventory.contains(where: { $0.id == .defaultAgent }) { try await synchronizeDefaultAgent(configuration) }
            await refreshRuntimeMaintenance(configuration)
            await refreshTaskGateway(configuration)
        } catch {
            guard (try? requireCurrent(identity)) != nil else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func provision(
        _ configuration: RemoteWorkspaceConfiguration
    ) async throws {
        progress = "Provisioning the pinned workspace image…"
        try await sshClient.deployService(
            hostName: configuration.hostName,
            userName: configuration.userName
        )
        let token = try Self.generateToken()
        try await credentials.save(token: token, for: configuration.id)
        progress = "Creating and health-checking the loopback-only container…"
        let status = try await sshClient.create(
            configuration: configuration,
            token: token
        )
        workspaces.append(configuration)
        workspaces.sort { $0.createdAt < $1.createdAt }
        statuses[configuration.id] = status
        save()
        await refreshService(configuration)
    }

    private func serviceClient(
        for configuration: RemoteWorkspaceConfiguration
    ) async throws -> RemoteWorkspaceServiceClient {
        guard !isBackendProjection else { throw BackendRPCError.remote("Remote connections are owned by the background service.") }
        let identity = try requestIdentity(configuration)
        guard isCredentialAccessEnabled else {
            throw RemoteWorkspaceClientError.invalidResponse(
                "Enable Remote Workspace credential access before connecting."
            )
        }
        guard let token = try await credentials.token(for: configuration.id) else {
            throw RemoteWorkspaceClientError.invalidResponse(
                "The workspace API token is missing from Keychain."
            )
        }
        try requireCurrent(identity)
        let tunnel = tunnels[configuration.id] ?? RemoteWorkspaceTunnel()
        tunnels[configuration.id] = tunnel
        let localPort = Self.localPort(for: configuration.id)
        let readinessConfiguration = URLSessionConfiguration.ephemeral
        readinessConfiguration.timeoutIntervalForRequest = 1
        readinessConfiguration.timeoutIntervalForResource = 1
        let readinessSession = URLSession(configuration: readinessConfiguration)
        try await tunnel.start(
            configuration: configuration,
            localPort: localPort
        ) { candidatePort in
            let candidate = RemoteWorkspaceServiceClient(
                baseURL: URL(string: "http://127.0.0.1:\(candidatePort)")!,
                token: token,
                session: readinessSession
            )
            guard let health = try? await candidate.health() else { return false }
            return health.status == "ready"
        }
        guard let activePort = await tunnel.localPort else {
            throw RemoteWorkspaceClientError.invalidResponse(
                "The SSH loopback tunnel did not report a local port."
            )
        }
        do { try requireCurrent(identity) }
        catch {
            // Do not stop a tunnel that a newer request still owns.
            if tunnels[configuration.id] !== tunnel { await tunnel.stop() }
            throw error
        }
        return RemoteWorkspaceServiceClient(
            baseURL: URL(string: "http://127.0.0.1:\(activePort)")!,
            token: token
        )
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(
                [RemoteWorkspaceConfiguration].self,
                from: data
              ) else { return }
        workspaces = decoded
    }

    private func save() {
        guard !isBackendProjection else { return }
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        defaults.set(data, forKey: storageKey)
    }


    struct BackendSnapshot: Codable {
        let workspaces: [RemoteWorkspaceConfiguration]
        let taskGatewayStatuses: [UUID: RemoteTaskGatewayStatus]
        let taskGatewayErrors: [UUID: String]
        let changingTaskGatewayIDs: Set<UUID>
        let machineCandidates: [RemoteMachineCandidate]
        let statuses: [UUID: RemoteWorkspaceStatus]
        let harnesses: [UUID: [RemoteHarnessStatus]]
        let workspaceEpochs: [UUID: UUID]
        let invalidatingWorkspaceIDs: Set<UUID>
        let workspaceRoots: [UUID: String]
        let runtimeMaintenance: [UUID: [RemoteRuntimeMaintenance]]
        let runtimeChecksVerifiedAfterError: [UUID: Set<AgentRuntimeKind>]
        let checkingRuntimeIDs: [UUID: Set<AgentRuntimeKind>]
        let runtimeCheckErrors: [UUID: [AgentRuntimeKind: String]]
        let runtimeErrors: [UUID: String]
        let actionErrors: [UUID: [AgentRuntimeKind: String]]
        let workspaceInstances: [UUID: [AgentRuntimeKind: RemoteWorkspaceInstanceStatus]]
        let operations: [UUID: RemoteHarnessOperation]
        let authenticationSessions: [UUID: RemoteHarnessAuthenticationSession]
        let busyWorkspaceIDs: Set<UUID>
        let signInStatuses: [UUID: [AgentSignInStatus]]
        let checkingSignIn: Set<UUID>
        let signInErrors: [UUID: String]
        let credentialEpoch: UUID
        let preparedHarnessAction: PreparedHarnessAction?
        let pendingHostPreparation: PendingHostPreparation?
        let isDiscovering: Bool
        let isCheckingHost: Bool
        let isCreating: Bool
        let progress: String?
        let errorMessage: String?
        let checkedPreflight: RemoteWorkspacePreflight?
        let isCredentialAccessEnabled: Bool
        let checkedHostKey: String?
    }

    func backendSnapshot() -> BackendSnapshot {
        BackendSnapshot(
            workspaces: workspaces,
            taskGatewayStatuses: taskGatewayStatuses,
            taskGatewayErrors: taskGatewayErrors,
            changingTaskGatewayIDs: changingTaskGatewayIDs,
            machineCandidates: machineCandidates,
            statuses: statuses,
            harnesses: harnesses,
            workspaceEpochs: workspaceEpochs,
            invalidatingWorkspaceIDs: invalidatingWorkspaceIDs,
            workspaceRoots: workspaceRoots,
            runtimeMaintenance: runtimeMaintenance,
            runtimeChecksVerifiedAfterError: runtimeChecksVerifiedAfterError,
            checkingRuntimeIDs: checkingRuntimeIDs,
            runtimeCheckErrors: runtimeCheckErrors,
            runtimeErrors: runtimeErrors,
            actionErrors: actionErrors,
            workspaceInstances: workspaceInstances,
            operations: operations,
            authenticationSessions: authenticationSessions,
            busyWorkspaceIDs: busyWorkspaceIDs,
            signInStatuses: signInStatuses,
            checkingSignIn: checkingSignIn,
            signInErrors: signInErrors,
            credentialEpoch: credentialEpoch,
            preparedHarnessAction: preparedHarnessAction,
            pendingHostPreparation: pendingHostPreparation,
            isDiscovering: isDiscovering,
            isCheckingHost: isCheckingHost,
            isCreating: isCreating,
            progress: progress,
            errorMessage: errorMessage,
            checkedPreflight: checkedPreflight,
            isCredentialAccessEnabled: isCredentialAccessEnabled,
            checkedHostKey: checkedHostKey)
    }

    func applyBackendSnapshot(_ snapshot: BackendSnapshot) {
        guard isBackendProjection else { return }
        workspaces = snapshot.workspaces
        taskGatewayStatuses = snapshot.taskGatewayStatuses
        taskGatewayErrors = snapshot.taskGatewayErrors
        changingTaskGatewayIDs = snapshot.changingTaskGatewayIDs
        machineCandidates = snapshot.machineCandidates
        statuses = snapshot.statuses
        harnesses = snapshot.harnesses
        workspaceEpochs = snapshot.workspaceEpochs
        invalidatingWorkspaceIDs = snapshot.invalidatingWorkspaceIDs
        workspaceRoots = snapshot.workspaceRoots
        runtimeMaintenance = snapshot.runtimeMaintenance
        runtimeChecksVerifiedAfterError = snapshot.runtimeChecksVerifiedAfterError
        checkingRuntimeIDs = snapshot.checkingRuntimeIDs
        runtimeCheckErrors = snapshot.runtimeCheckErrors
        runtimeErrors = snapshot.runtimeErrors
        actionErrors = snapshot.actionErrors
        workspaceInstances = snapshot.workspaceInstances
        operations = snapshot.operations
        authenticationSessions = snapshot.authenticationSessions
        busyWorkspaceIDs = snapshot.busyWorkspaceIDs
        signInStatuses = snapshot.signInStatuses
        checkingSignIn = snapshot.checkingSignIn
        signInErrors = snapshot.signInErrors
        credentialEpoch = snapshot.credentialEpoch
        preparedHarnessAction = snapshot.preparedHarnessAction
        pendingHostPreparation = snapshot.pendingHostPreparation
        isDiscovering = snapshot.isDiscovering
        isCheckingHost = snapshot.isCheckingHost
        isCreating = snapshot.isCreating
        progress = snapshot.progress
        errorMessage = snapshot.errorMessage
        checkedPreflight = snapshot.checkedPreflight
        isCredentialAccessEnabled = snapshot.isCredentialAccessEnabled
        checkedHostKey = snapshot.checkedHostKey
    }

    private func forwardToBackend(_ command: BackendRemoteWorkspaceCommand) -> Bool {
        guard isBackendProjection else { return false }
        Task { await forwardToBackendAndWait(command) }
        return true
    }

    private func forwardToBackendAndWait(_ command: BackendRemoteWorkspaceCommand) async {
        do { _ = try await requestBackend(command) }
        catch { errorMessage = error.localizedDescription }
    }

    private func requestBackend(_ command: BackendRemoteWorkspaceCommand) async throws -> BackendRemoteWorkspaceResponse {
        guard isBackendProjection, let backendRequest else {
            throw BackendRPCError.remote("The background service is not connected.")
        }
        let data = try await backendRequest("remoteWorkspaces.command", JSONEncoder().encode(command))
        let response = try JSONDecoder().decode(BackendRemoteWorkspaceResponse.self, from: data)
        applyBackendSnapshot(response.snapshot)
        return response
    }

    private static func localPort(for id: UUID) -> Int {
        let value = Int(id.uuid.0) << 8 | Int(id.uuid.1)
        return 40_000 + value % 20_000
    }

    private static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw RemoteWorkspaceClientError.keychain(status)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func hostKey(hostName: String, userName: String) -> String {
        "\(userName.trimmingCharacters(in: .whitespacesAndNewlines))@\(hostName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private static func requireCapabilities(
        _ preflight: RemoteWorkspacePreflight,
        for configuration: RemoteWorkspaceConfiguration
    ) throws {
        if configuration.memoryLimit != nil, !preflight.capabilities.memory {
            throw RemoteWorkspaceClientError.unsupportedResource(
                "This host cannot enforce a container memory limit."
            )
        }
        if configuration.swapLimit != nil, !preflight.capabilities.swap {
            throw RemoteWorkspaceClientError.unsupportedResource(
                "This host cannot enforce an additional swap limit."
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
