import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

extension ApplicationModel {
    func openCodeModel(for conversationID: String) -> OpenCodeModel? {
        openCodeInstances.first { $0.links[conversationID] != nil }
    }

    func synchronizeRemoteOpenCodeInstances() async {
        let generation = UUID()
        remoteOpenCodeSyncGeneration = generation
        guard let dashboardStore, let ownerDeviceID = try? await dashboardStore.dashboardDeviceID() else { return }
        guard remoteOpenCodeSyncGeneration == generation else { return }
        let configurations = remoteWorkspaces.workspaces
        let eligibleIDs = Set(configurations.map(\.id))
        for id in Array(remoteOpenCodes.keys) where !eligibleIDs.contains(id) {
            if let removed = remoteOpenCodes.removeValue(forKey: id) { await removed.suspendConnection() }
            guard remoteOpenCodeSyncGeneration == generation else { return }
        }
        for configuration in configurations {
            guard remoteOpenCodeSyncGeneration == generation,
                  remoteWorkspaces.configuration(id: configuration.id) == configuration else { return }
            if let existing = remoteOpenCodes[configuration.id], existing.remoteConfiguration != configuration {
                remoteOpenCodes[configuration.id] = nil
                await existing.suspendConnection()
                guard remoteOpenCodeSyncGeneration == generation,
                      remoteWorkspaces.configuration(id: configuration.id) == configuration else { return }
            }
            let instance: OpenCodeModel
            if let existing = remoteOpenCodes[configuration.id] { instance = existing }
            else {
                instance = OpenCodeModel(store: dashboardStore, ownerDeviceID: ownerDeviceID, defaults: applicationDefaults,
                    remoteConfiguration: configuration, remoteWorkspaces: remoteWorkspaces)
                remoteOpenCodes[configuration.id] = instance
                instance.onChange = { [weak self, weak instance] id in
                    guard let self, let instance, self.remoteOpenCodes[configuration.id] === instance else { return }
                    if instance.snapshots[id]?.active == true { self.localRunningConversationIDs.insert(id) }
                    else { self.localRunningConversationIDs.remove(id) }
                    await self.refreshWorkspaceIfChanged()
                    await self.refreshConversation(id: id)
                }
            }
            if remoteWorkspaces.isRuntimeEnabled(.opencode, in: configuration) {
                if !instance.isReady && !instance.isConnecting && instance.canRestoreAutomatically { await instance.restore() }
            } else { await instance.suspendConnection() }
        }
    }

    func prepareOpenCodeInstancesToQuit() async throws {
        for instance in openCodeInstances { try await instance.prepareToQuit() }
    }

    func restoreOpenCodeInstances() async {
        for instance in openCodeInstances { await instance.restore() }
        await synchronizeRemoteOpenCodeInstances()
    }

    func openCodeSettingsAgent(workspaceID: UUID?) async throws -> WorkspaceAgent {
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        if let workspaceID {
            guard let configuration = remoteWorkspaces.configuration(id: workspaceID) else { throw ApplicationModelError.remoteHarnessUnavailable }
            _ = try await dashboardStore.ensureRemoteHarnessAgent(runtimeKind: .opencode,
                remoteWorkspaceID: workspaceID, remoteWorkspaceName: configuration.name)
            await refreshWorkspace()
        }
        guard let agent = try dashboardStore.database.dashboardAgents().first(where: {
            $0.runtimeKind == .opencode && (workspaceID == nil ? $0.governingPlane == .wovenmatterMacOS : $0.runtimeDeviceID == workspaceID)
        }) else { throw ApplicationModelError.localACPRuntimeUnavailable }
        return agent
    }

    func renameOpenCodeAgent(agentID: UUID, displayName: String) async throws {
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        try dashboardStore.database.renameOpenCodeAgent(id: agentID, displayName: displayName)
        await refreshWorkspace()
    }

    func remoteOpenClawAgentID(for configuration: RemoteWorkspaceConfiguration) async throws -> UUID {
        guard let dashboardStore, remoteWorkspaces.configuration(id: configuration.id) == configuration else {
            throw ApplicationModelError.remoteHarnessUnavailable
        }
        let id = try await dashboardStore.ensureRemoteHarnessAgent(runtimeKind: .openclaw,
            remoteWorkspaceID: configuration.id, remoteWorkspaceName: configuration.name)
        await refreshWorkspace()
        return id
    }
}
