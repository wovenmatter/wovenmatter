import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

extension ApplicationModel {
    /// Native host access is selected once for the workspace. Captured chat and
    /// calendar defaults cannot reintroduce approval prompts in Full root mode.
    func selectionsApplyingWorkspaceAccess(_ selections: SessionSelections, runtime: AgentRuntimeKind,
        workspaceID: UUID?) -> SessionSelections {
        guard let workspaceID,
              let permission = remoteWorkspaces.configuration(id: workspaceID)?.fullRootPermission(for: runtime) else { return selections }
        var result = selections
        result.permission = permission
        return result
    }

    /// Settings edits belong to the execution owner, which also captures defaults
    /// for scheduled and tool-created sessions. Conversation controls never call this.
    func agentSelectionDefaults(runtime: AgentRuntimeKind, workspace: String?) async throws
        -> (stored: SessionSelections, resolved: SessionSelections, usesShared: Bool) {
        if isBackendFrontend {
            let result = try await sendBackendCommand(.loadAgentDefaults(runtime: runtime, workspace: workspace))
            guard let stored = result.selections, let resolved = result.resolvedSelections else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            return (stored, resolved, result.usesSharedDefaults ?? stored.isEmpty)
        }
        if runtime == .defaultAgent {
            let legacy = sessionSelectionPreferences.storedDefaults(harness: runtime.rawValue, workspace: workspace)
            if let id = legacy.model {
                updatePiDefault(id, workspace: workspace)
                sessionSelectionPreferences.removeDefault(.model, harness: runtime.rawValue, workspace: workspace)
            }
        }
        let workspaceID = workspace.flatMap { $0.hasPrefix("remote:") ? UUID(uuidString: String($0.dropFirst(7))) : nil }
        return (sessionSelectionPreferences.storedDefaults(harness: runtime.rawValue, workspace: workspace),
            selectionsApplyingWorkspaceAccess(sessionSelectionPreferences.defaults(harness: runtime.rawValue, workspace: workspace), runtime: runtime, workspaceID: workspaceID),
            workspace.map { sessionSelectionPreferences.usesSharedDefaults(harness: runtime.rawValue, workspace: $0) } ?? false)
    }

    func saveAgentSelectionDefault(runtime: AgentRuntimeKind, workspace: String?,
        field: SessionSelectionField, selections: SessionSelections) async throws
        -> (stored: SessionSelections, resolved: SessionSelections, usesShared: Bool) {
        if isBackendFrontend {
            let result = try await sendBackendCommand(.saveAgentDefault(runtime: runtime, workspace: workspace,
                field: field, selections: selections))
            guard let stored = result.selections, let resolved = result.resolvedSelections else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            return (stored, resolved, result.usesSharedDefaults ?? stored.isEmpty)
        }
        if field == .tools, let tools = selections.tools { _ = try WorkspaceSessionTools(identifiers: tools) }
        if runtime == .defaultAgent, field == .model {
            updatePiDefault(selections.model, workspace: workspace)
            sessionSelectionPreferences.removeDefault(.model, harness: runtime.rawValue, workspace: workspace)
        } else {
            sessionSelectionPreferences.saveDefault(field, from: selections, harness: runtime.rawValue, workspace: workspace)
        }
        if field == .model {
            // The two writes are serialized in the execution owner's actor turn,
            // before a scheduled/new conversation can capture these defaults.
            sessionSelectionPreferences.removeDefault(.thinking, harness: runtime.rawValue, workspace: workspace)
        }
        return try await agentSelectionDefaults(runtime: runtime, workspace: workspace)
    }

    func setAgentDefaultsSharing(runtime: AgentRuntimeKind, workspace: String, shared: Bool) async throws
        -> (stored: SessionSelections, resolved: SessionSelections, usesShared: Bool) {
        if isBackendFrontend {
            let result = try await sendBackendCommand(.setAgentDefaultsSharing(runtime: runtime, workspace: workspace, shared: shared))
            guard let stored = result.selections, let resolved = result.resolvedSelections else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            return (stored, resolved, result.usesSharedDefaults ?? stored.isEmpty)
        }
        sessionSelectionPreferences.setUsesSharedDefaults(shared, harness: runtime.rawValue, workspace: workspace)
        return try await agentSelectionDefaults(runtime: runtime, workspace: workspace)
    }

    private func updatePiDefault(_ id: String?, workspace: String?) {
        let scope = workspace.map { $0.hasPrefix("remote:") ? String($0.dropFirst(7)) : "local" } ?? "global"
        DefaultAgentSupport.updateSettings { settings in
            var config = scope == "global" ? settings.global : settings.resolved(scope)
            config.defaultModel = id
            if let id, !config.models.contains(id) { config.models.append(id) }
            if scope == "global" { settings.global = config } else { settings.workspaces[scope] = config }
        }
    }

    /// Workspace identity includes its host. Local folders and remote paths must
    /// never accidentally share a permissions or model default.
    func sessionSelectionContext(conversationID: String) async throws -> (harness: String, workspace: String) {
        if let captured = sessionSelectionPreferences.conversation(id: conversationID) {
            return await (captured.harness, try sessionSelectionWorkspaceID?(conversationID) ?? captured.workspace)
        }
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        let session = try await dashboardStore.database.localACPSession(conversationID: conversationID)
        let workspace: String
        if let resolved = try await sessionSelectionWorkspaceID?(conversationID) {
            workspace = resolved
        } else if let remote = session.remoteWorkspaceID {
            workspace = "remote:" + remote.uuidString.lowercased()
        } else {
            guard let root = localACPWorkspaceLaunchConfiguration?.rootURL else {
                throw ApplicationModelError.localACPRuntimeUnavailable
            }
            workspace = "local:" + root.standardizedFileURL.path
        }
        return (session.runtimeKind.rawValue, workspace)
    }

    /// Creation owns the only application of captured defaults. A rejected or
    /// unavailable setting leaves an ordinary, editable session, never pending work
    /// for opening the chat or sending its first message to retry.
    func initializeNewSessionSelections(conversationID: String, capturedDefaults: SessionSelections? = nil,
        usesProductPermissionDefault: Bool? = nil) async throws {
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        let context = try await sessionSelectionContext(conversationID: conversationID)
        let native = try await dashboardStore.database.localACPSession(conversationID: conversationID)
        let forcedPermission = native.remoteWorkspaceID.flatMap { remoteWorkspaces.configuration(id: $0)?.fullRootPermission(for: native.runtimeKind) }
        let effectiveDefaults = selectionsApplyingWorkspaceAccess(
            capturedDefaults ?? sessionSelectionPreferences.defaults(harness: context.harness, workspace: context.workspace),
            runtime: native.runtimeKind, workspaceID: native.remoteWorkspaceID)
        let captured = await sessionSelectionPreferences.captureConversation(
            id: conversationID, harness: context.harness, workspace: context.workspace,
            selections: SessionSelections(),
            nativeFallback: SessionSelections(model: native.model, thinking: native.thinking,
                permission: native.permission, tools: currentSessionToolIDs?(conversationID)),
            capturedDefaults: effectiveDefaults, usesProductPermissionDefault: forcedPermission == nil ? usesProductPermissionDefault : false
        )
        guard captured.requiresApplication else { return }
        do {
            try await applyStagedSessionSelections(conversationID: conversationID)
        } catch {
            // Defaults are a starting preference, not a prerequisite for a chat.
            // Keep the native state that was actually accepted, including a
            // partially applied bundle, and leave its controls editable.
            let actual = try? await dashboardStore.database.localACPSession(conversationID: conversationID)
            let metadata = localACPSessionMetadata[conversationID]
            sessionSelectionPreferences.replaceConfirmedSelections(id: conversationID,
                selections: SessionSelections(model: metadata?.model ?? actual?.model,
                    thinking: metadata?.thinking ?? actual?.thinking,
                    permission: metadata?.permission ?? actual?.permission,
                    tools: await currentSessionToolIDs?(conversationID)))
            NSLog("New chat settings were unavailable; retaining native settings.")
        }
        sessionSelectionPreferences.markApplied(id: conversationID)
    }

    /// Explicit application for creation, scheduled tasks, and user edits only.
    /// Opening a chat and sending input never call this method.
    func applyStagedSessionSelections(conversationID: String) async throws {
        if let pending = applyingSessionSelectionTasks[conversationID] {
            try await pending.value
            return
        }
        guard sessionSelectionPreferences.conversation(id: conversationID)?.requiresApplication == true else { return }
        let task = Task { @MainActor in
            try await self.performStagedSessionSelections(conversationID: conversationID)
        }
        applyingSessionSelectionTasks[conversationID] = task
        defer { applyingSessionSelectionTasks[conversationID] = nil }
        try await task.value
    }

    private func performStagedSessionSelections(conversationID: String) async throws {
        try beginSessionSelectionApplication(conversationID: conversationID)
        defer { endSessionSelectionApplication(conversationID: conversationID) }
        guard let saved = sessionSelectionPreferences.conversation(id: conversationID),
              saved.requiresApplication else { return }
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        let native = try await dashboardStore.database.localACPSession(conversationID: conversationID)
        let forcedPermission = native.remoteWorkspaceID.flatMap { remoteWorkspaces.configuration(id: $0)?.fullRootPermission(for: native.runtimeKind) }
        var desired = selectionsApplyingWorkspaceAccess(saved.desiredSelections, runtime: native.runtimeKind, workspaceID: native.remoteWorkspaceID)
        let openCode = openCodeModel(for: conversationID)
        if openCode == nil, desired.tools != nil, applyInitialSessionToolIDs == nil {
            throw ApplicationModelError.unavailableSessionTools
        }
        if openCode == nil, let tools = desired.tools {
            try await applyInitialSessionToolIDs?(conversationID, tools)
        }
        var confirmedMetadata: LocalACPSessionMetadata?
        if let openCode {
            try await openCode.applySessionSelections(conversationID, selections: desired)
        } else {
            let permission = desired.permission
            if desired.model != nil || desired.thinking != nil || permission != nil {
                guard let conversation = try await dashboardStore.database.workspaceOverview().conversations
                    .first(where: { $0.id == conversationID }) else {
                    throw LocalACPSessionDatabaseError.sessionNotFound
                }
                let context = try await directACPLaunchContext(conversation: conversation,
                    runtimeKind: native.runtimeKind)
                if saved.usesProductPermissionDefault && forcedPermission == nil {
                    let available = try await dashboardStore.localACPSessionConfiguration(conversationID: conversationID,
                        launch: context.launch, workspace: context.workspace)
                    desired = sessionSelectionPreferences.reconcileProductPermissionDefault(id: conversationID,
                        options: available.permissionOptions, nativePermission: available.permission)?.desiredSelections ?? desired
                }
                // Configure the actual session, including a retained native client.
                // A DB seed alone cannot prove that its next prompt uses these values.
                let configuration = try await dashboardStore.updateLocalACPSessionConfiguration(
                    conversationID: conversationID, model: desired.model, thinking: desired.thinking,
                    permission: desired.permission,
                    launch: context.launch, workspace: context.workspace)
                let metadata = LocalACPSessionMetadata(sessionKey: conversationID,
                    model: configuration.model, thinking: configuration.thinking,
                    modelOptions: configuration.modelOptions, thinkingLevels: configuration.thinkingOptions,
                    slashCommands: configuration.slashCommands,
                    modelOptionMetadata: configuration.modelOptionMetadata,
                    thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                    permission: configuration.permission,
                    permissionOptions: configuration.permissionOptions,
                    permissionOptionMetadata: configuration.permissionOptionMetadata,
                    workingDirectory: configuration.workingDirectory)
                publishSessionSelectionMetadata(metadata, conversationID: conversationID)
                confirmedMetadata = metadata
            }
        }
        if let metadata = confirmedMetadata {
            await sessionSelectionPreferences.replaceConfirmedSelections(id: conversationID,
                selections: SessionSelections(model: metadata.model, thinking: metadata.thinking,
                    permission: metadata.permission, tools: currentSessionToolIDs?(conversationID) ?? saved.selections.tools))
        }
        sessionSelectionPreferences.markApplied(id: conversationID)
    }

    func recordConfirmedSessionSelections(conversationID: String, metadata: LocalACPSessionMetadata) async {
        if isBackendFrontend {
            // Confirmation belongs to the execution owner; a stale UI snapshot must
            // never overwrite newer backend model/permission preferences.
            return
        }

        guard let context = try? await sessionSelectionContext(conversationID: conversationID) else { return }
        let selections = await SessionSelections(model: metadata.model, thinking: metadata.thinking,
            permission: metadata.permission,
            tools: currentSessionToolIDs?(conversationID)
                ?? sessionSelectionPreferences.conversation(id: conversationID)?.selections.tools)
        if sessionSelectionPreferences.conversation(id: conversationID) == nil {
            _ = sessionSelectionPreferences.captureExistingConversation(id: conversationID,
                harness: context.harness, workspace: context.workspace, selections: selections)
        } else if sessionSelectionPreferences.conversation(id: conversationID)?.requiresApplication == false {
            sessionSelectionPreferences.replaceConfirmedSelections(id: conversationID, selections: selections)
        }
    }
}
