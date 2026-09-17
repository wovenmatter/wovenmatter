import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore


extension ApplicationModel {
    func isLocalACPSessionLaunchAvailable(_ conversation: WorkspaceConversationRecord) -> Bool {
        guard let runtimeKind = conversation.localRuntimeKind else { return false }
        if buzzBoundLocalACPConversationIDs.contains(conversation.id) { return true }
        if let workspaceID = conversation.remoteWorkspaceID {
            guard let configuration = remoteWorkspaces.configuration(id: workspaceID) else { return false }
            return remoteWorkspaces.isHarnessReady(runtimeKind, in: configuration)
        }
        return localACPLaunchConfigurations[runtimeKind] != nil
            && localACPWorkspaceLaunchConfiguration != nil
    }

    func refreshLocalACPSession(
        conversation: WorkspaceConversationRecord
    ) async {
        if conversation.localRuntimeKind == .opencode {
            if let openCode = openCodeModel(for: conversation.id), openCode.isEnabled, let link = openCode.links[conversation.id] {
                await openCode.coordinator.watch(link)
            }
            return
        }
        guard let runtimeKind = conversation.localRuntimeKind else {
            return
        }
        let isBuzzWorkspaceSession = buzzBoundLocalACPConversationIDs.contains(
            conversation.id
        )
        let context = try? directACPLaunchContext(
            conversation: conversation,
            runtimeKind: runtimeKind,
            isBuzzWorkspaceSession: isBuzzWorkspaceSession
        )
        let launch = context?.launch
        let workspace = context?.workspace
        guard isBuzzWorkspaceSession || (launch != nil && workspace != nil) else {
            return
        }
        let request = localACPSessionRefreshLifecycle.beginRefresh(
            for: conversation.id
        )
        defer { localACPSessionRefreshLifecycle.finish(request) }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let configuration = try await dashboardStore
                .localACPSessionConfiguration(
                    conversationID: conversation.id,
                    launch: launch,
                    workspace: workspace
                )
            guard !Task.isCancelled,
                  localACPSessionRefreshLifecycle.isCurrent(request) else {
                return
            }
            localACPSessionMetadata[conversation.id] = LocalACPSessionMetadata(
                sessionKey: conversation.id,
                model: configuration.model,
                thinking: configuration.thinking,
                modelOptions: configuration.modelOptions,
                thinkingLevels: configuration.thinkingOptions,
                slashCommands: configuration.slashCommands,
                modelOptionMetadata: configuration.modelOptionMetadata,
                thinkingOptionMetadata: configuration.thinkingOptionMetadata
            )
            ensureConversationState(id: conversation.id).setError(nil)
        } catch {
            guard !Task.isCancelled,
                  localACPSessionRefreshLifecycle.isCurrent(request) else {
                return
            }
            ensureConversationState(id: conversation.id).setError(
                error.localizedDescription
            )
        }
    }

    func updateLocalACPSession(
        conversation: WorkspaceConversationRecord,
        model: String? = nil,
        thinking: String? = nil
    ) {
        guard let runtimeKind = conversation.localRuntimeKind,
              model != nil || thinking != nil,
              !localRunningConversationIDs.contains(conversation.id),
              updatingLocalACPSessionIDs.insert(conversation.id).inserted else {
            return
        }
        let isBuzzWorkspaceSession = buzzBoundLocalACPConversationIDs.contains(
            conversation.id
        )
        let context = try? directACPLaunchContext(
            conversation: conversation,
            runtimeKind: runtimeKind,
            isBuzzWorkspaceSession: isBuzzWorkspaceSession
        )
        let launch = context?.launch
        let workspace = context?.workspace
        guard isBuzzWorkspaceSession || (launch != nil && workspace != nil) else {
            updatingLocalACPSessionIDs.remove(conversation.id)
            return
        }
        localRunError = nil
        ensureConversationState(id: conversation.id).setError(nil)
        Task {
            defer { updatingLocalACPSessionIDs.remove(conversation.id) }
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                let configuration = try await dashboardStore
                    .updateLocalACPSessionConfiguration(
                        conversationID: conversation.id,
                        model: model,
                        thinking: thinking,
                        launch: launch,
                        workspace: workspace
                    )
                localACPSessionMetadata[conversation.id] =
                    LocalACPSessionMetadata(
                        sessionKey: conversation.id,
                        model: configuration.model,
                        thinking: configuration.thinking,
                        modelOptions: configuration.modelOptions,
                        thinkingLevels: configuration.thinkingOptions,
                        slashCommands: configuration.slashCommands,
                        modelOptionMetadata: configuration.modelOptionMetadata,
                        thinkingOptionMetadata: configuration.thinkingOptionMetadata
                    )
            } catch {
                ensureConversationState(id: conversation.id).setError(
                    error.localizedDescription
                )
            }
        }
    }

    func createLocalACPSession(
        runtimeKind: AgentRuntimeKind
    ) async -> String? {
        if runtimeKind == .hermes {
            do { try requireLocalHermesLink(openSettings: true) }
            catch { localRunError = error.localizedDescription; return nil }
        }
        if runtimeKind == .opencode {
            do {
                guard let openCode else { throw OpenCodeError.message("OpenCode is still starting.") }
                guard let workspace = localACPWorkspaceLaunchConfiguration else { throw ApplicationModelError.localACPRuntimeUnavailable }
                let id = try await openCode.create(workspace: workspace.rootURL)
                await refreshWorkspace()
                return id
            } catch { localRunError = error.localizedDescription; return nil }
        }
        guard localACPLaunchConfigurations[runtimeKind] != nil,
              localACPWorkspaceLaunchConfiguration != nil,
              isLocalACPAgentReady(runtimeKind) else {
            localRunError = ApplicationModelError.localACPRuntimeUnavailable.localizedDescription
            return nil
        }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let openClawAgent = runtimeKind == .openclaw
                ? localCLIAgents.first(where: { $0.runtimeKind == .openclaw }) : nil
            let gatewayKey = Self.openClawSessionKey(conversationID: UUID().uuidString.lowercased())
            if let agent = openClawAgent, isOpenClawGatewayLinked(agentID: agent.id),
               let workspace = localACPWorkspaceLaunchConfiguration {
                try await dashboardStore.createOpenClawWorkspaceSession(agentID: agent.id, sessionKey: gatewayKey, cwd: workspace.rootURL)
            }
            let conversationID = try await dashboardStore.createLocalACPSession(
                runtimeKind: runtimeKind,
                title: "New \(runtimeKind.displayName) chat"
            )
            if runtimeKind == .openclaw,
               let agent = localCLIAgents.first(where: { $0.runtimeKind == .openclaw }),
               isOpenClawGatewayLinked(agentID: agent.id) {
                try await dashboardStore.attachOpenClawGatewaySession(
                    conversationID: conversationID,
                    agentID: agent.id,
                    sessionKey: gatewayKey
                )
                openClawGatewayConversationIDs.insert(conversationID)
            }
            localRunError = nil
            await refreshWorkspace()
            return conversationID
        } catch {
            NSLog(
                "Could not create %@ local ACP chat: %@",
                runtimeKind.rawValue,
                String(describing: error)
            )
            localRunError = error is WorkspaceDatabaseError
                ? "Woven Matter could not save this local chat. Reopen the app and try again."
                : error.localizedDescription
            return nil
        }
    }

    func createRemoteACPSession(
        target: RemoteHarnessChatTarget
    ) async -> String? {
        guard remoteWorkspaces.isHarnessReady(
            target.harness.id,
            in: target.configuration
        ) else {
            localRunError = "This remote harness is not ready. Refresh it in Settings and try again."
            return nil
        }
        do {
            if target.harness.id == .opencode {
                await synchronizeRemoteOpenCodeInstances()
                guard let instance = remoteOpenCodes[target.configuration.id] else {
                    throw ApplicationModelError.remoteHarnessUnavailable
                }
                try await instance.connectLocal()
                let directory = remoteWorkspaces.remoteWorkspaceRoot(for: target.configuration)
                let id = try await instance.create(workspace: URL(fileURLWithPath: directory))
                await refreshWorkspace()
                return id
            }
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            var unlinkedOpenClawAgentID: UUID?
            let conversationID = try await dashboardStore.createRemoteACPSession(
                runtimeKind: target.harness.id,
                remoteWorkspaceID: target.configuration.id,
                remoteWorkspaceName: target.configuration.name,
                title: "New \(target.harness.displayName) chat"
            )
            if target.harness.id == .openclaw {
                let agentID = try await dashboardStore.ensureRemoteHarnessAgent(
                    runtimeKind: .openclaw,
                    remoteWorkspaceID: target.configuration.id,
                    remoteWorkspaceName: target.configuration.name
                )
                if isOpenClawGatewayLinked(agentID: agentID) {
                    try await dashboardStore.attachOpenClawGatewaySession(
                        conversationID: conversationID,
                        agentID: agentID,
                        sessionKey: Self.openClawSessionKey(
                            conversationID: conversationID
                        )
                    )
                    openClawGatewayConversationIDs.insert(conversationID)
                } else {
                    unlinkedOpenClawAgentID = agentID
                }
            }
            localRunError = nil
            await refreshWorkspace()
            pendingOpenClawGatewayAgentID = unlinkedOpenClawAgentID
            return conversationID
        } catch {
            localRunError = error.localizedDescription
            return nil
        }
    }

    func directACPLaunchContext(
        conversation: WorkspaceConversationRecord,
        runtimeKind: AgentRuntimeKind,
        isBuzzWorkspaceSession: Bool
    ) throws -> RemoteHarnessLaunchContext? {
        if isBuzzWorkspaceSession { return nil }
        if let remoteWorkspaceID = conversation.remoteWorkspaceID {
            guard let configuration = remoteWorkspaces.configuration(
                id: remoteWorkspaceID
            ), remoteWorkspaces.isHarnessReady(runtimeKind, in: configuration) else {
                throw ApplicationModelError.remoteHarnessUnavailable
            }
            let processDirectory = localACPWorkspaceLaunchConfiguration?.rootURL
                ?? FileManager.default.homeDirectoryForCurrentUser
            if runtimeKind == .hermes {
                guard let connection = remoteHermesConnections[remoteWorkspaceID] else {
                    throw HermesGatewayError.message("Connect Hermes in this remote workspace's settings first.")
                }
                let encoded = try JSONEncoder().encode(connection).base64EncodedString()
                let root = URL(fileURLWithPath: remoteWorkspaces.remoteWorkspaceRoot(for: configuration))
                return RemoteHarnessLaunchContext(launch: LocalACPRuntimeLaunchConfiguration(runtimeKind: .hermes,
                    executableURL: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: [], environment: ["WOVENMATTER_HERMES_CONNECTION": encoded],
                    processWorkingDirectoryURL: processDirectory), workspace: LocalACPWorkspaceLaunchConfiguration(rootURL: root, repositoriesURL: root.appending(path: "REPOS")))
            }
            return try RemoteHarnessLaunchResolver.resolve(
                configuration: configuration,
                runtimeKind: runtimeKind,
                processWorkingDirectory: processDirectory
            )
        }
        if runtimeKind == .hermes { try requireLocalHermesLink(conversationID: conversation.id) }
        guard let launch = localACPLaunchConfigurations[runtimeKind],
              let workspace = localACPWorkspaceLaunchConfiguration else {
            throw ApplicationModelError.localACPRuntimeUnavailable
        }
        return RemoteHarnessLaunchContext(
            launch: launch,
            workspace: workspace
        )
    }

    func createBuzzWorkspaceLocalACPSession(
        enrollment: BuzzWorkspaceAgentEnrollment
    ) async -> String? {
        guard launchableBuzzWorkspaceEnrollmentIDs.contains(enrollment.id) else {
            localRunError = "The selected Buzz agent is not available from its linked workspace."
            return nil
        }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let conversationID = try await dashboardStore
                .createBuzzWorkspaceLocalACPSession(
                    enrollmentID: enrollment.id,
                    title: "New \(enrollment.displayNameSnapshot) chat"
                )
            buzzBoundLocalACPConversationIDs.insert(conversationID)
            if isOpenClawGatewayLinked(agentID: enrollment.id) {
                try await dashboardStore.attachOpenClawGatewaySession(
                    conversationID: conversationID,
                    agentID: enrollment.id,
                    sessionKey: Self.openClawSessionKey(conversationID: conversationID)
                )
                openClawGatewayConversationIDs.insert(conversationID)
            }
            localRunError = nil
            await refreshWorkspace()
            return conversationID
        } catch {
            localRunError = error.localizedDescription
            await refreshBuzzWorkspaces()
            return nil
        }
    }

    func refreshRuntimeInventory() {
        guard !checkingRuntimeInventory, checkingRuntimeKinds.isEmpty, installingLocalACPRuntimeKinds.isEmpty,
              preparedLocalACPRuntimeInstall == nil else { return }
        checkingRuntimeInventory = true
        runtimeInventoryGeneration &+= 1
        let generation = runtimeInventoryGeneration
        let enabled = enabledLocalACPRuntimeKinds
        let openCodeEnabled = openCode?.isEnabled == true
        Task {
            defer { checkingRuntimeInventory = false }
            await openCode?.resolveExecutable()
            let selectedOpenCode = openCode?.runtimeExecutable
            for definition in LocalACPRuntimeCatalog.definitions {
                guard installingLocalACPRuntimeKinds.isEmpty else { return }
                let kind = definition.runtimeKind
                checkingRuntimeKinds.insert(kind)
                let checkLatest = kind == .opencode ? openCodeEnabled : enabled.contains(kind)
                let inventory = await Task.detached(priority: .utility) {
                    await RuntimeMaintenance.inspect(kind, checkLatest: checkLatest, selectedOpenCode: selectedOpenCode)
                }.value
                checkingRuntimeKinds.remove(kind)
                guard installingLocalACPRuntimeKinds.isEmpty, generation == runtimeInventoryGeneration else { return }
                runtimeInventories[kind] = inventory
                if checkLatest { checkedRuntimeKinds.insert(kind) }
            }
        }
    }

    func checkRuntimeUpdate(_ kind: AgentRuntimeKind) {
        guard !checkingRuntimeInventory, checkingRuntimeKinds.insert(kind).inserted else { return }
        guard installingLocalACPRuntimeKinds.isEmpty, openCode?.isInstalling != true else {
            checkingRuntimeKinds.remove(kind)
            return
        }
        let generation = runtimeInventoryGeneration
        Task {
            defer { checkingRuntimeKinds.remove(kind) }
            if kind == .opencode { await openCode?.resolveExecutable() }
            let selectedOpenCode = openCode?.runtimeExecutable
            let inventory = await Task.detached(priority: .utility) {
                await RuntimeMaintenance.inspect(kind, checkLatest: true, selectedOpenCode: selectedOpenCode)
            }.value
            guard installingLocalACPRuntimeKinds.isEmpty, generation == runtimeInventoryGeneration else { return }
            runtimeInventories[kind] = inventory
            checkedRuntimeKinds.insert(kind)
        }
    }

    func runtimeDiagnostic(_ kind: AgentRuntimeKind) -> String {
        RuntimeMaintenance.diagnostic(inventory: runtimeInventories[kind], kind: kind,
            attempts: runtimeFailures[kind, default: 0], failure: runtimeFailureDetails[kind] ?? "unknown")
    }

    private func recordRuntimeFailure(_ kind: AgentRuntimeKind, error: any Error, update: Bool = false) {
        runtimeFailures[kind, default: 0] += 1
        if update { failedRuntimeUpdateKinds.insert(kind) }
        // Never copy arbitrary subprocess output or URLs into diagnostics.
        let category: String
        if let failure = error as? RuntimeMaintenanceError { category = failure.localizedDescription }
        else if let failure = error as? LocalACPRuntimeInstallError {
            switch failure {
            case .installFailed: category = "Installer exited unsuccessfully (output omitted)."
            case .executableMissing: category = "Installer did not produce the required executable."
            default: category = failure.localizedDescription
            }
        } else { category = "Runtime operation failed (private details omitted)." }
        runtimeFailureDetails[kind] = category
        localRunError = category
    }

    func usesLocallyInstalledRuntime(_ conversation: WorkspaceConversationRecord) -> Bool {
        conversation.localRuntimeKind != nil && conversation.remoteWorkspaceID == nil
            && !buzzBoundLocalACPConversationIDs.contains(conversation.id)
            && !isOpenClawGatewayConversation(conversation.id)
    }

    var localRuntimeMaintenanceHasActiveConversation: Bool {
        localRunningConversationIDs.contains { id in
            if buzzBoundLocalACPConversationIDs.contains(id) || isOpenClawGatewayConversation(id) { return false }
            // A newly accepted turn may precede the workspace snapshot refresh.
            // Keep maintenance blocked until its execution location is known.
            guard let conversation = workspaceOverview?.conversations.first(where: { $0.id == id }) else { return true }
            return usesLocallyInstalledRuntime(conversation)
        }
    }

    func installLocalACPRuntimeComponent(_ runtimeKind: AgentRuntimeKind) {
        // Finish the initial inventory before an install invalidates its generation.
        // Otherwise the remaining runtime rows can be left without an inventory.
        guard !checkingRuntimeInventory, installingLocalACPRuntimeKinds.isEmpty, openCode?.isInstalling != true, preparedLocalACPRuntimeInstall == nil,
              !localRuntimeMaintenanceHasActiveConversation,
              let definition = LocalACPRuntimeCatalog.definition(for: runtimeKind) else { return }
        let inventory = runtimeInventories[runtimeKind]
        let cliMissing = definition.underlyingCLIName.map { name in
            inventory?.components.contains { $0.name == name + " (sign-in CLI)" && !$0.present } == true
        } ?? false
        let needsCLI = cliMissing || (definition.adapterPackage == nil && inventory?.isInstalled != true)
        if needsCLI {
            runtimeInventoryGeneration &+= 1
            installingLocalACPRuntimeKinds.insert(runtimeKind)
            localRunError = nil
            Task {
                defer { installingLocalACPRuntimeKinds.remove(runtimeKind) }
                do {
                    let preview = try await localACPRuntimeInstaller.prepareCLIInstall(definition)
                    preparedLocalACPRuntimeInstall = PreparedLocalACPRuntimeInstall(definition: definition, preview: preview)
                } catch { recordRuntimeFailure(runtimeKind, error: error) }
            }
        } else { performRuntimeMaintenance(definition, update: false) }
    }

    func updateRuntime(_ kind: AgentRuntimeKind) {
        guard let definition = LocalACPRuntimeCatalog.definition(for: kind) else { return }
        performRuntimeMaintenance(definition, update: true)
    }

    func confirmPreparedLocalACPRuntimeInstall() {
        guard let prepared = preparedLocalACPRuntimeInstall else { return }
        preparedLocalACPRuntimeInstall = nil
        performRuntimeMaintenance(prepared.definition, update: false, preview: prepared.preview)
    }

    func cancelPreparedLocalACPRuntimeInstall() { preparedLocalACPRuntimeInstall = nil }

    private func performRuntimeMaintenance(_ definition: LocalACPRuntimeDefinition, update: Bool,
                                          preview: LocalACPInstallerPreview? = nil) {
        let kind = definition.runtimeKind
        guard !checkingRuntimeInventory, installingLocalACPRuntimeKinds.isEmpty, openCode?.isInstalling != true,
              preparedLocalACPRuntimeInstall == nil, !localRuntimeMaintenanceHasActiveConversation else { return }
        runtimeInventoryGeneration &+= 1
        installingLocalACPRuntimeKinds.insert(kind)
        if update { updatingRuntimeKinds.insert(kind) }
        localRunError = nil
        let installer = localACPRuntimeInstaller
        let before = runtimeInventories[kind]
        Task {
            defer { installingLocalACPRuntimeKinds.remove(kind); updatingRuntimeKinds.remove(kind) }
            do {
                if let preview {
                    _ = try await installer.install(definition, component: .cli,
                        expectedSourceSHA256: preview.sha256, expectedPackageSpec: preview.packageSpec)
                }
                if let package = definition.adapterPackage ?? (kind == .pi && preview == nil ? RuntimeMaintenance.npmPackage(kind) : nil) {
                    // Resolve a concrete version before npm is allowed to mutate anything.
                    let version: String
                    do { version = try await RuntimeMaintenance.registryVersion(package) }
                    catch {
                        guard !update, let pinned = definition.minimumAdapterVersion else { throw error }
                        version = pinned
                    }
                    _ = try await installer.installPackage(package, version: version, executableName: definition.commandName)
                } else if update {
                    try await RuntimeMaintenance.updateNative(kind, executable: before?.components.first?.executable)
                }
                if update, definition.adapterPackage != nil,
                   let cli = before?.components.first(where: { $0.name.hasSuffix("(sign-in CLI)") && $0.outdated }) {
                    try await RuntimeMaintenance.updateNative(kind, executable: cli.executable)
                }
                let inventory = await Task.detached(priority: .utility) {
                    await RuntimeMaintenance.inspect(kind, checkLatest: true)
                }.value
                runtimeInventories[kind] = inventory
                checkedRuntimeKinds.insert(kind)
                guard inventory.isInstalled else { throw RuntimeMaintenanceError.verification }
                if update {
                    // Success requires the outdated components to reach the observed
                    // target, not merely an exit-zero updater or a changed PATH.
                    for component in before?.components.filter(\.outdated) ?? [] {
                        guard let after = inventory.components.first(where: { $0.name == component.name }),
                              let installed = after.installed, let target = component.latest,
                              installed == target || RuntimeMaintenance.version(target, precedes: installed)
                        else { throw RuntimeMaintenanceError.verification }
                    }
                }
                runtimeFailures[kind] = 0; runtimeFailureDetails[kind] = nil
                failedRuntimeUpdateKinds.remove(kind)
                await refreshLocalACPRuntimes()
            } catch { recordRuntimeFailure(kind, error: error, update: update) }
        }
    }
    func refreshLocalACPRuntimesNow() {
        Task { await refreshLocalACPRuntimes() }
    }

    func setTitleGenerationEnabled(_ enabled: Bool) {
        titleGenerationSettings.isEnabled = enabled
        applicationDefaults.set(
            enabled,
            forKey: Self.titleGenerationEnabledDefaultsKey
        )
    }

    func setTitleGenerationModel(_ model: String) {
        titleGenerationSettings.model = model
        applicationDefaults.set(
            model,
            forKey: Self.titleGenerationModelDefaultsKey
        )
    }

    func setTitleGenerationThinking(_ thinking: String) {
        titleGenerationSettings.thinking = thinking
        applicationDefaults.set(
            thinking,
            forKey: Self.titleGenerationThinkingDefaultsKey
        )
    }

    func refreshTitleGenerationCapabilitiesNow() {
        Task { await refreshTitleGenerationCapabilities() }
    }

    func setUpLocalACPWorkspace(homeDirectory: URL) {
        Task {
            do {
                try await localACPWorkspaceStore.setUpWorkspace(
                    in: homeDirectory
                )
                localRunError = nil
                await refreshLocalACPWorkspace()
                await refreshLocalACPRuntimes()
            } catch {
                localRunError = error.localizedDescription
            }
        }
    }

    func configureLocalACPRepositories(_ repositoriesURL: URL?) {
        Task {
            do {
                try await localACPWorkspaceStore.configureRepositories(
                    repositoriesURL
                )
                localRunError = nil
                await refreshLocalACPWorkspace()
            } catch {
                localRunError = error.localizedDescription
            }
        }
    }

    func configureLocalACPDatabases(_ databasesURL: URL?) {
        Task {
            do {
                try await localACPWorkspaceStore.configureDatabases(databasesURL)
                localRunError = nil
                await refreshLocalACPWorkspace()
                await refreshDatabases()
            } catch {
                localRunError = error.localizedDescription
            }
        }
    }

    func resolveLocalACPPermission(id: UUID, optionID: String?) {
        guard let continuation = localACPPermissionContinuations.removeValue(forKey: id) else {
            return
        }
        pendingLocalACPPermissions.removeAll { $0.id == id }
        continuation.resume(returning: optionID)
    }

    func resolveLocalACPInteraction(
        id: UUID,
        response: LocalACPInteractionResponse
    ) {
        guard let continuation = localACPInteractionContinuations.removeValue(
            forKey: id
        ) else { return }
        pendingLocalACPInteractions.removeAll { $0.id == id }
        continuation.resume(returning: response)
    }

    func cancelLocalACPPrompt(conversationID: String) {
        if let openCode = openCodeModel(for: conversationID), openCode.links[conversationID] != nil {
            openCode.perform { _ = try await openCode.sessionCall(conversationID, "/interrupt", method: "POST") }
            return
        }
        let permissionIDs = pendingLocalACPPermissions
            .filter { $0.conversationID == conversationID }
            .map(\.id)
        for permissionID in permissionIDs {
            resolveLocalACPPermission(id: permissionID, optionID: nil)
        }
        cancelLocalACPInteractions(conversationID: conversationID)
        Task {
            await dashboardStore?.cancelLocalACPPrompt(conversationID: conversationID)
        }
    }

    func shutdownLocalACPSessions() {
        let permissionIDs = pendingLocalACPPermissions.map(\.id)
        for permissionID in permissionIDs {
            resolveLocalACPPermission(id: permissionID, optionID: nil)
        }
        let interactionIDs = pendingLocalACPInteractions.map(\.id)
        for interactionID in interactionIDs {
            resolveLocalACPInteraction(id: interactionID, response: .cancelled)
        }
        LocalACPClient.terminateAllProcesses()
        PiRPCClient.terminateAllProcesses()
        Task { for instance in openCodeInstances { await instance.coordinator.shutdown() }; await dashboardStore?.shutdownLocalACPSessions() }
    }

    func requestLocalACPPermission(
        conversationID: String,
        request: LocalACPPermissionRequest
    ) async -> String? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                localACPPermissionContinuations[id] = continuation
                pendingLocalACPPermissions.append(PendingLocalACPPermission(
                    id: id,
                    conversationID: conversationID,
                    title: request.title,
                    options: request.options
                ))
                if Task.isCancelled {
                    resolveLocalACPPermission(id: id, optionID: nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveLocalACPPermission(id: id, optionID: nil)
            }
        }
    }

    func requestLocalACPInteraction(
        conversationID: String,
        request: LocalACPInteractionRequest
    ) async -> LocalACPInteractionResponse {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                localACPInteractionContinuations[id] = continuation
                pendingLocalACPInteractions.append(PendingLocalACPInteraction(
                    id: id,
                    conversationID: conversationID,
                    request: request
                ))
                if Task.isCancelled {
                    resolveLocalACPInteraction(id: id, response: .cancelled)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveLocalACPInteraction(id: id, response: .cancelled)
            }
        }
    }

    func cancelLocalACPInteractions(conversationID: String) {
        let interactionIDs = pendingLocalACPInteractions
            .filter { $0.conversationID == conversationID }
            .map(\.id)
        for interactionID in interactionIDs {
            resolveLocalACPInteraction(id: interactionID, response: .cancelled)
        }
    }

    private func refreshLocalACPRuntimes() async {
        localACPRuntimeRefreshGeneration &+= 1
        let generation = localACPRuntimeRefreshGeneration
        let enabledRuntimeKinds = enabledLocalACPRuntimeKinds
        checkingLocalACPRuntimeKinds = Set(
            LocalACPRuntimeCatalog.definitions.compactMap {
                $0.readinessProbe == nil
                    || !enabledRuntimeKinds.contains($0.runtimeKind)
                    ? nil : $0.runtimeKind
            }
        )
        defer {
            if generation == localACPRuntimeRefreshGeneration {
                checkingLocalACPRuntimeKinds.removeAll()
            }
        }
        let resolver = localACPRuntimeResolver
        let definitions = LocalACPRuntimeCatalog.definitions
        let workingDirectory = localACPWorkspaceLaunchConfiguration?.rootURL
            ?? FileManager.default.homeDirectoryForCurrentUser
        let resolutions = await Task.detached(priority: .utility) {
            let resolver = resolver.snapshottingExecutableSearchDirectories()
            var resolutions: [LocalACPRuntimeResolution] = []
            for definition in definitions {
                let discovered = resolver.resolve(
                    runtimeKind: definition.runtimeKind
                )
                guard enabledRuntimeKinds.contains(definition.runtimeKind)
                else {
                    if let executablePath = discovered.availability.executablePath,
                       discovered.launchConfiguration != nil {
                        resolutions.append(LocalACPRuntimeResolution(
                            availability: LocalACPRuntimeAvailability(
                                runtimeKind: definition.runtimeKind,
                                displayName: definition.displayName,
                                state: .authenticationRequired,
                                detail: "Enable \(definition.displayName) before Woven Matter starts it or checks its account credentials.",
                                executablePath: executablePath
                            ),
                            launchConfiguration: nil
                        ))
                    } else {
                        resolutions.append(discovered)
                    }
                    continue
                }
                resolutions.append(await LocalACPRuntimeVerifier.verify(
                    definition: definition,
                    resolution: discovered,
                    workingDirectory: workingDirectory
                ))
            }
            return resolutions
        }.value
        guard !Task.isCancelled,
              generation == localACPRuntimeRefreshGeneration else {
            return
        }
        localACPRuntimeAvailability = resolutions.map(\.availability)
        localACPLaunchConfigurations = resolutions.reduce(into: [:]) {
            configurations, resolution in
            if let launchConfiguration = resolution.launchConfiguration {
                configurations[resolution.availability.runtimeKind] =
                    launchConfiguration
            }
        }
        let statuses = Dictionary(
            uniqueKeysWithValues: resolutions.map { resolution in
                let status: AgentRuntimeStatus = switch resolution.availability.state {
                case .ready: .ready
                case .authenticationRequired: .needsAuthentication
                case .executableUnavailable: .failed
                case .cliMissing, .adapterMissing, .adapterOutdated: .offline
                }
                return (resolution.availability.runtimeKind, status)
            }
        )
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            try await dashboardStore.reconcileLocalCLIAgentCatalog(statuses: statuses)
            localACPDatabaseReadyRuntimeKinds = Set(statuses.keys)
            localACPAgentReconciliationError = nil
            await refreshWorkspace()
        } catch {
            localACPDatabaseReadyRuntimeKinds.removeAll()
            localACPAgentReconciliationError =
                "The local workspace could not save Local CLI agents. Reopen Woven Matter and try again."
            NSLog(
                "Could not reconcile local CLI agents: %@",
                String(describing: error)
            )
        }
        await refreshTitleGenerationCapabilities()
    }

    private func refreshTitleGenerationCapabilities() async {
        guard !isRefreshingTitleGenerationCapabilities,
              let launch = localACPLaunchConfigurations[.codex],
              let workspace = localACPWorkspaceLaunchConfiguration else {
            titleGenerationCapabilities = nil
            titleGenerationStatus = "Codex CLI and codex-acp must be ready"
            return
        }
        isRefreshingTitleGenerationCapabilities = true
        defer { isRefreshingTitleGenerationCapabilities = false }
        do {
            let capabilities = try await conversationTitleGenerator.discover(
                launch: launch,
                workspace: workspace
            )
            titleGenerationCapabilities = capabilities
            if !capabilities.models.contains(titleGenerationSettings.model),
               let model = capabilities.currentModel ?? capabilities.models.first {
                setTitleGenerationModel(model)
            }
            if !capabilities.thinkingLevels.contains(titleGenerationSettings.thinking),
               let thinking = capabilities.currentThinking
                    ?? capabilities.thinkingLevels.first {
                setTitleGenerationThinking(thinking)
            }
            titleGenerationStatus = "Ready through your local Codex account"
        } catch {
            titleGenerationCapabilities = nil
            titleGenerationStatus = error.localizedDescription
        }
    }

    func scheduleConversationTitleGeneration(
        conversation: WorkspaceConversationRecord,
        firstPrompt: String
    ) {
        guard titleGenerationSettings.isEnabled,
              conversation.title.hasPrefix("New "),
              conversation.title.hasSuffix(" chat"),
              let launch = localACPLaunchConfigurations[.codex],
              let workspace = localACPWorkspaceLaunchConfiguration,
              let dashboardStore,
              generatingConversationTitleIDs.insert(conversation.id).inserted else { return }
        let expectedTitle = conversation.title
        let selectedModel = titleGenerationSettings.model.isEmpty
            ? nil : titleGenerationSettings.model
        let selectedThinking = titleGenerationSettings.thinking.isEmpty
            ? nil : titleGenerationSettings.thinking
        Task {
            defer { generatingConversationTitleIDs.remove(conversation.id) }
            do {
                let generatedTitle = try await conversationTitleGenerator.generate(
                    firstPrompt: firstPrompt,
                    model: selectedModel,
                    thinking: selectedThinking,
                    launch: launch,
                    workspace: workspace
                )
                if try await dashboardStore.updateConversationTitleIfCurrent(
                    id: conversation.id,
                    expectedTitle: expectedTitle,
                    title: generatedTitle
                ) {
                    await refreshWorkspace()
                }
            } catch {
                NSLog(
                    "Could not generate title for conversation %@: %@",
                    conversation.id,
                    String(describing: error)
                )
            }
        }
    }

    func refreshLocalACPWorkspace() async {
        let resolution = await localACPWorkspaceStore.resolve()
        localACPWorkspaceAvailability = resolution.availability
        localACPWorkspaceLaunchConfiguration = resolution.launchConfiguration
    }
}
