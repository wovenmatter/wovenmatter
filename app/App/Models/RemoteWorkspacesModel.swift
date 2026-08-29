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
    private var checkedHostKey: String?

    private let sshClient = RemoteWorkspaceSSHClient()
    private let credentials = RemoteWorkspaceCredentialStore()
    private var tunnels: [UUID: RemoteWorkspaceTunnel] = [:]
    private let defaults: UserDefaults
    private let storageKey = "wovenmatter.remote-workspaces.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    var readyChatTargets: [RemoteHarnessChatTarget] {
        workspaces.flatMap { configuration -> [RemoteHarnessChatTarget] in
            guard statuses[configuration.id]?.running == true else { return [] }
            return (harnesses[configuration.id] ?? []).compactMap { harness in
                harness.state == "ready"
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

    func configuration(id: UUID) -> RemoteWorkspaceConfiguration? {
        workspaces.first { $0.id == id }
    }

    func isHarnessReady(
        _ runtimeKind: AgentRuntimeKind,
        in configuration: RemoteWorkspaceConfiguration
    ) -> Bool {
        statuses[configuration.id]?.running == true
            && harnesses[configuration.id]?.contains {
                $0.id == runtimeKind && $0.state == "ready"
            } == true
    }

    func refreshAll() {
        for workspace in workspaces { refresh(workspace) }
    }

    func prepareOpenClawGateway(
        for configuration: RemoteWorkspaceConfiguration
    ) async throws -> RemoteOpenClawGatewayConnection {
        if let knownHarnesses = harnesses[configuration.id],
           !knownHarnesses.contains(where: {
               $0.id == .openclaw && $0.state == "ready"
           }) {
            throw RemoteWorkspaceClientError.harnessUnavailable
        }
        let client = try await serviceClient(for: configuration)
        var status = try await client.startOpenClawGateway()
        var attempts = 0
        while status.state != "running", attempts < 12 {
            try await Task.sleep(for: .milliseconds(150))
            status = try await client.openClawGatewayStatus()
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
        checkedHostKey == Self.inspectionKey(
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
                checkedHostKey = Self.inspectionKey(
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
                checkedHostKey = Self.inspectionKey(
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
                checkedHostKey = Self.inspectionKey(
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
            await self.refreshService(updated)
        }
    }

    func delete(
        _ configuration: RemoteWorkspaceConfiguration,
        removePersistentData: Bool
    ) {
        performBusy(configuration) {
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
            self.save()
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
        guard action == "install" || action == "update" else { return }
        performBusy(configuration) {
            let client = try await self.serviceClient(for: configuration)
            let preview = try await client.installerPreview(harnessID: harness.id)
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
            let client = try await self.serviceClient(
                for: preparedHarnessAction.configuration
            )
            var operation = try await client.perform(
                harnessID: preparedHarnessAction.harness.id,
                action: preparedHarnessAction.action,
                confirmed: true,
                sourceSHA256: preparedHarnessAction.preview.sha256
            )
            self.operations[preparedHarnessAction.configuration.id] = operation
            var checks = 0
            while operation.status == "running", checks < 300 {
                try await Task.sleep(for: .seconds(1))
                operation = try await client.operation(id: operation.id)
                self.operations[preparedHarnessAction.configuration.id] = operation
                checks += 1
            }
            self.harnesses[preparedHarnessAction.configuration.id] = try await client
                .harnesses()
        }
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
        guard busyWorkspaceIDs.insert(configuration.id).inserted else { return }
        errorMessage = nil
        Task {
            defer { busyWorkspaceIDs.remove(configuration.id) }
            do { try await operation() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func refreshService(
        _ configuration: RemoteWorkspaceConfiguration
    ) async {
        do {
            let client = try await serviceClient(for: configuration)
            _ = try await client.health()
            harnesses[configuration.id] = try await client.harnesses()
        } catch {
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
        guard let token = try await credentials.token(for: configuration.id) else {
            throw RemoteWorkspaceClientError.invalidResponse(
                "The workspace API token is missing from Keychain."
            )
        }
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

    private static func inspectionKey(
        hostName: String,
        userName: String
    ) -> String {
        hostKey(hostName: hostName, userName: userName)
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
