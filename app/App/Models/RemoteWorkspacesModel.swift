import Foundation
import Observation
import Security
import WovenMatterClient
import WovenMatterCore

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
    struct PendingHostPreparation: Equatable, Identifiable {
        let configuration: RemoteWorkspaceConfiguration
        let inspection: RemoteWorkspacePreflight
        var id: UUID { configuration.id }
    }

    struct PreparedHarnessAction: Equatable, Identifiable {
        let action: String
        let harness: RemoteHarnessStatus
        let configuration: RemoteWorkspaceConfiguration
        let preview: RemoteInstallerPreview
        var id: String {
            "\(configuration.id.uuidString):\(harness.id.rawValue):\(action)"
        }
    }

    private(set) var workspaces: [RemoteWorkspaceConfiguration] = []
    private(set) var machineCandidates: [RemoteMachineCandidate] = []
    private(set) var statuses: [UUID: RemoteWorkspaceStatus] = [:]
    private(set) var harnesses: [UUID: [RemoteHarnessStatus]] = [:]
    var onRuntimeMaintenanceChanged: (@MainActor () async -> Void)?
    private var credentialEpoch = UUID()
    private var workspaceEpochs: [UUID: UUID] = [:]
    private var invalidatingWorkspaceIDs: Set<UUID> = []
    private var workspaceRoots: [UUID: String] = [:]
    private(set) var runtimeMaintenance: [UUID: [RemoteRuntimeMaintenance]] = [:]
    private var runtimeChecksVerifiedAfterError: [UUID: Set<AgentRuntimeKind>] = [:]
    private(set) var checkingRuntimeIDs: [UUID: Set<AgentRuntimeKind>] = [:]
    private(set) var runtimeCheckErrors: [UUID: [AgentRuntimeKind: String]] = [:]
    private(set) var runtimeErrors: [UUID: String] = [:]
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

    private let sshClient = RemoteWorkspaceSSHClient()
    private let credentials = RemoteWorkspaceCredentialStore()
    private var tunnels: [UUID: RemoteWorkspaceTunnel] = [:]
    private let defaults: UserDefaults
    private let storageKey = "wovenmatter.remote-workspaces.v1"
    private let credentialAccessDefaultsKey =
        "wovenmatter.remote-workspaces.credential-access-enabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isCredentialAccessEnabled = defaults.bool(
            forKey: credentialAccessDefaultsKey
        )
        load()
    }

    func enableCredentialAccess() {
        guard !isCredentialAccessEnabled else {
            refreshAll()
            return
        }
        isCredentialAccessEnabled = true
        defaults.set(true, forKey: credentialAccessDefaultsKey)
        refreshAll()
    }

    func disableCredentialAccess() {
        credentialEpoch = UUID()
        isCredentialAccessEnabled = false
        preparedHarnessAction = nil
        runtimeErrors.removeAll()
        runtimeCheckErrors.removeAll()
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
            for tunnel in activeTunnels { await tunnel.stop() }
        }
    }

    var readyChatTargets: [RemoteHarnessChatTarget] {
        workspaces.flatMap { configuration -> [RemoteHarnessChatTarget] in
            guard isCredentialAccessEnabled, !invalidatingWorkspaceIDs.contains(configuration.id), statuses[configuration.id]?.running == true else { return [] }
            return currentHarnesses(for: configuration).compactMap { harness in
                harness.state == "ready"
                    && !isRuntimeInventoryUnavailable(harness.id, configuration: configuration)
                    && self.runtimeMaintenance[configuration.id]?.contains(where: {
                        $0.id == harness.id && $0.enabled && $0.visible && $0.installed && $0.operation?.status != "running"
                    }) == true
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
            return $0.harness.displayName.localizedCaseInsensitiveCompare(
                $1.harness.displayName
            ) == .orderedAscending
        }
    }

    func currentHarnesses(for configuration: RemoteWorkspaceConfiguration) -> [RemoteHarnessStatus] {
        (harnesses[configuration.id] ?? []).map { harness in
            harness.reconcilingOpenCode(
                instance: workspaceInstances[configuration.id]?[.opencode],
                installed: runtimeMaintenance[configuration.id]?.first(where: { $0.id == .opencode })?.installed
            )
        }
    }

    func configuration(id: UUID) -> RemoteWorkspaceConfiguration? {
        workspaces.first { $0.id == id }
    }

    func isHarnessReady(
        _ runtimeKind: AgentRuntimeKind,
        in configuration: RemoteWorkspaceConfiguration
    ) -> Bool {
        isRuntimeEnabled(runtimeKind, in: configuration)
            && !isRuntimeInventoryUnavailable(runtimeKind, configuration: configuration)
            && statuses[configuration.id]?.running == true
            && currentHarnesses(for: configuration).contains {
                $0.id == runtimeKind && $0.state == "ready"
            } && runtimeMaintenance[configuration.id]?.contains(where: {
                $0.id == runtimeKind && $0.enabled && $0.installed && $0.operation?.status != "running"
            }) == true
    }

    func refreshAll() {
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

    func enabledRuntimeWorkspaces(_ kind: AgentRuntimeKind) -> [RemoteWorkspaceConfiguration] {
        guard isCredentialAccessEnabled else { return [] }
        return workspaces.filter { workspace in
            !invalidatingWorkspaceIDs.contains(workspace.id) && runtimeMaintenance[workspace.id]?.contains { $0.id == kind && $0.enabled } == true
        }
    }

    /// Called at startup/reopen only; never installs, upgrades, or launches runtimes.
    func checkRuntimeMaintenanceOnActivation() {
        guard isCredentialAccessEnabled else { return }
        for workspace in workspaces {
            performBusy(workspace) {
                await self.refreshRuntimeMaintenance(workspace, checkLatest: true)
            }
        }
    }

    func isRuntimeInventoryUnavailable(_ kind: AgentRuntimeKind, configuration: RemoteWorkspaceConfiguration) -> Bool {
        runtimeErrors[configuration.id] != nil && runtimeChecksVerifiedAfterError[configuration.id]?.contains(kind) != true
    }

    func checkRuntimeUpdates(_ kind: AgentRuntimeKind, configuration: RemoteWorkspaceConfiguration) {
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

    private func requestIdentity(_ configuration: RemoteWorkspaceConfiguration) throws -> RemoteWorkspaceRequestIdentity {
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
                try? await credentials.deleteToken(for: configuration.id)
                errorMessage = error.localizedDescription
            }
        }
    }

    func authorizeHostPreparation() {
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
                try? await credentials.deleteToken(for: pending.configuration.id)
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelHostPreparation() {
        pendingHostPreparation = nil
    }

    func refresh(_ configuration: RemoteWorkspaceConfiguration) {
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
        performBusy(configuration) {
            self.statuses[configuration.id] = try await self.sshClient.lifecycle(
                action,
                configuration: configuration
            )
            if action != .stop { await self.refreshService(configuration) }
        }
    }

    func updateContainer(_ configuration: RemoteWorkspaceConfiguration) {
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
        var updated = configuration
        updated.memoryLimit = memoryLimit
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        updated.swapLimit = swapLimit
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        performBusy(configuration) {
            self.checkingRuntimeIDs.removeValue(forKey: configuration.id)
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
        guard isCredentialAccessEnabled else {
            errorMessage = "Enable credential access before deleting a remote workspace."
            return
        }
        performBusy(configuration) {
            self.checkingRuntimeIDs.removeValue(forKey: configuration.id)
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
        guard action == "install" || action == "update",
              checkingRuntimeIDs[configuration.id]?.contains(harness.id) != true else { return }
        if action == "update", harness.id == .hermes,
           runtimeMaintenance[configuration.id]?.first(where: { $0.id == .hermes })?.installed == true {
            performBusy(configuration) {
                try await self.runRuntimeMaintenance(.hermes, action: "update", configuration: configuration)
            }
            return
        }
        performBusy(configuration) {
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

    func confirmPreparedHarnessAction() {
        guard let preparedHarnessAction else { return }
        self.preparedHarnessAction = nil
        performBusy(preparedHarnessAction.configuration) {
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

    func cancelPreparedHarnessAction() {
        preparedHarnessAction = nil
    }

    func startHarnessSignIn(
        harness: RemoteHarnessStatus,
        method: RemoteHarnessSetupMethod,
        configuration: RemoteWorkspaceConfiguration
    ) {
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
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard let identity = try? requestIdentity(configuration),
              busyWorkspaceIDs.insert(configuration.id).inserted else { return }
        errorMessage = nil
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
            }
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
            await refreshRuntimeMaintenance(configuration)
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
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        defaults.set(data, forKey: storageKey)
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
