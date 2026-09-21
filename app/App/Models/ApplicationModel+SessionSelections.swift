import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

extension ApplicationModel {
    /// Workspace identity includes its host. Local folders and remote paths must
    /// never accidentally share a permissions or model default.
    func sessionSelectionContext(conversationID: String) throws -> (harness: String, workspace: String) {
        if let captured = sessionSelectionPreferences.conversation(id: conversationID) {
            return (captured.harness, try sessionSelectionWorkspaceID?(conversationID) ?? captured.workspace)
        }
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        let session = try dashboardStore.database.localACPSession(conversationID: conversationID)
        let workspace: String
        if let resolved = try sessionSelectionWorkspaceID?(conversationID) {
            workspace = resolved
        } else if let remote = session.remoteWorkspaceID {
            workspace = "remote:" + remote.uuidString.lowercased()
        } else if let buzz = session.buzzWorkspaceLinkID {
            workspace = "buzz:" + buzz.uuidString.lowercased()
        } else {
            guard let root = localACPWorkspaceLaunchConfiguration?.rootURL else {
                throw ApplicationModelError.localACPRuntimeUnavailable
            }
            workspace = "local:" + root.standardizedFileURL.path
        }
        return (session.runtimeKind.rawValue, workspace)
    }

    /// Called only by explicit new-chat creation. Capturing before applying the
    /// values makes retries independent of subsequent edits to defaults.
    func prepareNewSessionSelections(conversationID: String, capturedDefaults: SessionSelections? = nil) async throws {
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        let context = try sessionSelectionContext(conversationID: conversationID)
        let native = try dashboardStore.database.localACPSession(conversationID: conversationID)
        _ = sessionSelectionPreferences.captureConversation(
            id: conversationID, harness: context.harness, workspace: context.workspace,
            selections: SessionSelections(),
            nativeFallback: SessionSelections(model: native.model, thinking: native.thinking,
                permission: native.permission, tools: currentSessionToolIDs?(conversationID)),
            capturedDefaults: capturedDefaults
        )
        try await applyPendingSessionSelections(conversationID: conversationID)
    }

    /// Recovery applies an already captured snapshot, never today's defaults.
    func applyPendingSessionSelections(conversationID: String) async throws {
        if let pending = applyingSessionSelectionTasks[conversationID] {
            try await pending.value
            return
        }
        guard sessionSelectionPreferences.conversation(id: conversationID)?.requiresApplication == true else { return }
        let task = Task { @MainActor in
            try await self.performPendingSessionSelections(conversationID: conversationID)
        }
        applyingSessionSelectionTasks[conversationID] = task
        defer { applyingSessionSelectionTasks[conversationID] = nil }
        try await task.value
    }

    private func performPendingSessionSelections(conversationID: String) async throws {
        try beginSessionSelectionApplication(conversationID: conversationID)
        defer { endSessionSelectionApplication(conversationID: conversationID) }
        guard let saved = sessionSelectionPreferences.conversation(id: conversationID),
              saved.requiresApplication else { return }
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        let desired = saved.desiredSelections
        let openCode = openCodeModel(for: conversationID)
        if openCode == nil, desired.tools != nil, applyInitialSessionToolIDs == nil {
            throw ApplicationModelError.unavailableSessionTools
        }
        var confirmedMetadata: LocalACPSessionMetadata?
        if let openCode {
            try await openCode.applySessionSelections(conversationID, selections: desired)
        } else if isOpenClawGatewayConversation(conversationID) {
            if desired.model != nil || desired.thinking != nil || desired.permission != nil {
                _ = try await dashboardStore.patchOpenClawGatewaySession(conversationID: conversationID,
                    preferences: OpenClawSessionPreferences(model: desired.model,
                        thinkingLevel: desired.thinking, permissionMode: desired.permission))
                let metadata = try await dashboardStore.openClawGatewaySessionMetadata(conversationID: conversationID)
                publishSessionSelectionMetadata(metadata, conversationID: conversationID, gateway: true)
                confirmedMetadata = metadata
            }
        } else {
            let native = try dashboardStore.database.localACPSession(conversationID: conversationID)
            // An unlinked OpenClaw chat will apply its captured native settings
            // after the gateway is linked, rather than treating a DB write as a patch.
            if native.runtimeKind == .openclaw { return }
            let permission = native.runtimeKind == .pi ? nil : desired.permission
            if desired.model != nil || desired.thinking != nil || permission != nil {
                guard let conversation = try dashboardStore.database.workspaceOverview().conversations
                    .first(where: { $0.id == conversationID }) else {
                    throw LocalACPSessionDatabaseError.sessionNotFound
                }
                let context = try directACPLaunchContext(conversation: conversation,
                    runtimeKind: native.runtimeKind, isBuzzWorkspaceSession: native.buzzWorkspaceLinkID != nil)
                // Configure the actual session, including a retained native client.
                // A DB seed alone cannot prove that its next prompt uses these values.
                let configuration = try await dashboardStore.updateLocalACPSessionConfiguration(
                    conversationID: conversationID, model: desired.model, thinking: desired.thinking,
                    permission: permission, launch: context?.launch, workspace: context?.workspace)
                let metadata = LocalACPSessionMetadata(sessionKey: conversationID,
                    model: configuration.model, thinking: configuration.thinking,
                    modelOptions: configuration.modelOptions, thinkingLevels: configuration.thinkingOptions,
                    slashCommands: configuration.slashCommands,
                    modelOptionMetadata: configuration.modelOptionMetadata,
                    thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                    permission: native.runtimeKind == .pi ? nil : configuration.permission,
                    permissionOptions: configuration.permissionOptions,
                    permissionOptionMetadata: configuration.permissionOptionMetadata)
                publishSessionSelectionMetadata(metadata, conversationID: conversationID, gateway: false)
                confirmedMetadata = metadata
            }
        }
        if openCode == nil, let tools = desired.tools {
            guard let applyInitialSessionToolIDs else {
                throw ApplicationModelError.unavailableSessionTools
            }
            try applyInitialSessionToolIDs(conversationID, tools)
        }
        if let metadata = confirmedMetadata {
            sessionSelectionPreferences.replaceConfirmedSelections(id: conversationID,
                selections: SessionSelections(model: metadata.model, thinking: metadata.thinking,
                    permission: metadata.permission, tools: currentSessionToolIDs?(conversationID) ?? saved.selections.tools))
        }
        sessionSelectionPreferences.markApplied(id: conversationID)
    }

    /// A manual correction replaces only the chosen fields in an unfinished
    /// initial bundle. The remaining captured defaults still need confirmation.
    @discardableResult
    func retryPendingSessionSelections(conversationID: String, selections: SessionSelections) -> Bool {
        guard let pending = sessionSelectionPreferences.conversation(id: conversationID),
              pending.requiresApplication else { return false }
        guard !localRunningConversationIDs.contains(conversationID),
              !updatingLocalACPSessionIDs.contains(conversationID),
              applyingSessionSelectionTasks[conversationID] == nil else { return true }
        let desired = pending.desiredSelections.applyingPendingCorrection(selections)
        sessionSelectionPreferences.updateConversation(id: conversationID, selections: desired)
        if pending.desiredSelections.thinking != nil, desired.thinking == nil {
            sessionSelectionPreferences.updateConversation(id: conversationID, field: .thinking, from: desired)
        }
        ensureConversationState(id: conversationID).setError(nil)
        Task {
            do {
                try await applyPendingSessionSelections(conversationID: conversationID)
                ensureConversationState(id: conversationID).setError(nil)
            } catch {
                ensureConversationState(id: conversationID).setError(error.localizedDescription)
            }
        }
        return true
    }

    func recordConfirmedSessionSelections(conversationID: String, metadata: LocalACPSessionMetadata) {
        guard let context = try? sessionSelectionContext(conversationID: conversationID) else { return }
        let selections = SessionSelections(model: metadata.model, thinking: metadata.thinking,
            permission: context.harness == AgentRuntimeKind.pi.rawValue ? nil : metadata.permission,
            tools: currentSessionToolIDs?(conversationID)
                ?? sessionSelectionPreferences.conversation(id: conversationID)?.selections.tools)
        if sessionSelectionPreferences.conversation(id: conversationID) == nil {
            _ = sessionSelectionPreferences.captureExistingConversation(id: conversationID,
                harness: context.harness, workspace: context.workspace, selections: selections)
        } else if sessionSelectionPreferences.conversation(id: conversationID)?.requiresApplication == false {
            sessionSelectionPreferences.replaceConfirmedSelections(id: conversationID, selections: selections)
        }
    }

    func saveSessionDefault(conversation: WorkspaceConversationRecord, field: SessionSelectionField, workspaceOnly: Bool) {
        guard !updatingLocalACPSessionIDs.contains(conversation.id),
              openCodeModel(for: conversation.id)?.updatingSessions.contains(conversation.id) != true else { return }
        do {
            let context = try sessionSelectionContext(conversationID: conversation.id)
            let metadata = openCodeModel(for: conversation.id)?.metadata(conversation.id)
                ?? openClawGatewaySessionMetadata[conversation.id] ?? localACPSessionMetadata[conversation.id]
            let selection = SessionSelections(model: metadata?.model, thinking: metadata?.thinking,
                permission: metadata?.permission, tools: currentSessionToolIDs?(conversation.id))
            sessionSelectionPreferences.saveDefault(field, from: selection,
                harness: context.harness, workspace: workspaceOnly ? context.workspace : nil)
            ensureConversationState(id: conversation.id).setError(nil)
        } catch { ensureConversationState(id: conversation.id).setError(error.localizedDescription) }
    }

    func clearSessionDefault(conversation: WorkspaceConversationRecord, field: SessionSelectionField, workspaceOnly: Bool) {
        do {
            let context = try sessionSelectionContext(conversationID: conversation.id)
            sessionSelectionPreferences.removeDefault(field, harness: context.harness,
                workspace: workspaceOnly ? context.workspace : nil)
            ensureConversationState(id: conversation.id).setError(nil)
        } catch { ensureConversationState(id: conversation.id).setError(error.localizedDescription) }
    }
}
