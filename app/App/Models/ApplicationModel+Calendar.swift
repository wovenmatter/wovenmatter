import Foundation
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

extension ApplicationModel {
    func resolveCalendarTask(callerID: String, command: WovenMatterToolCommand,
                             existing: WorkspaceCalendarTask?) async throws -> WorkspaceCalendarTask {
        guard let database = dashboardStore?.database,
              let source = try database.workspaceOverview().conversations.first(where: { $0.id == callerID }) else {
            throw WorkspaceToolError.invalid("The source session is unavailable.")
        }
        try database.requireTool(.sessions, sessionID: callerID)
        let title = command.options["title"] ?? existing?.configuration.title ?? "Scheduled task"
        var config: WorkspaceSessionCreationConfiguration
        if let existing {
            config = existing.configuration
            if let raw = command.options["harness"] {
                guard let runtime = AgentRuntimeKind(rawValue: raw) else { throw WorkspaceToolError.invalid("Unknown agent.") }
                config.runtimeKind = runtime
            }
            if let raw = command.options["workspace"] {
                guard raw == "local" || UUID(uuidString: raw) != nil else { throw WorkspaceToolError.invalid("Unknown workspace.") }
                config.workspaceID = raw == "local" ? nil : UUID(uuidString: raw)
            }
            if config.runtimeKind != existing.configuration.runtimeKind || config.workspaceID != existing.configuration.workspaceID {
                let defaults = calendarTaskDefaults(runtime: config.runtimeKind, workspaceID: config.workspaceID).configuration
                config.model = defaults.model; config.thinking = defaults.thinking
                config.permission = defaults.permission; config.tools = defaults.tools
                config.nativeWorkingDirectory = defaults.nativeWorkingDirectory; config.selectionWorkspace = defaults.selectionWorkspace
                config.nativeWorkspaceID = nil
            }
        } else {
            config = try await resolveToolSessionCreation(source: source, command: command, title: title)
        }
        if let model = command.options["model"] { config.model = model; config.thinking = nil }
        if let thinking = command.options["thinking"] { config.thinking = thinking }
        if let folder = command.options["folder"] { config.folderID = folder == "all" ? nil : folder }
        if let directory = command.options["directory"] {
            config.nativeWorkingDirectory = directory; config.nativeWorkspaceID = nil
            config.selectionWorkspace = config.workspaceID.map { "remote:" + $0.uuidString.lowercased() }
                ?? "local:" + URL(fileURLWithPath: directory).standardizedFileURL.path
        }
        config.title = title
        let prompt = try command.options["prompt"] ?? existing?.prompt ?? command.required("prompt")
        let mode: WorkspaceCalendarTask.SessionMode
        if let raw = command.options["session-mode"] {
            guard let parsed = WorkspaceCalendarTask.SessionMode(rawValue: raw) else { throw WorkspaceToolError.invalid("Choose same or new for --session-mode.") }
            mode = parsed
        } else { mode = existing?.sessionMode ?? .same }
        return .init(prompt: prompt, configuration: config, sessionMode: mode)
    }

    func saveCalendarEvent(_ draft: WorkspaceCalendarDraft, event: WorkspaceCalendarItemRecord? = nil,
                           detaching occurrence: Int? = nil) async -> Bool {
        calendarMutationError = nil
        isCreatingCalendarItem = true
        defer { isCreatingCalendarItem = false }
        do {
            guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
            try database.saveCalendarEvent(id: event?.id ?? UUID().uuidString.lowercased(), draft: draft,
                creating: event == nil, expectedRevision: event?.calendar.revision, detaching: occurrence)
            await refreshWorkspace()
            return true
        } catch { calendarMutationError = error.localizedDescription; return false }
    }

    func deleteCalendarEvent(_ event: WorkspaceCalendarItemRecord, occurrence: Int? = nil) async -> Bool {
        calendarMutationError = nil
        do {
            guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
            try database.deleteCalendarEvent(id: event.id, occurrence: occurrence, expectedRevision: event.calendar.revision)
            await refreshWorkspace()
            return true
        } catch { calendarMutationError = error.localizedDescription; return false }
    }

    func calendarTaskDefaults(runtime: AgentRuntimeKind, workspaceID: UUID?, title: String = "") -> WorkspaceCalendarTask {
        let directory = try? defaultToolWorkingDirectory(workspaceID: workspaceID)
        let scope = workspaceID.map { "remote:" + $0.uuidString.lowercased() } ?? "local:" + (directory ?? "")
        let selections = sessionSelectionPreferences.defaults(harness: runtime.rawValue, workspace: scope)
        let tools = selections.tools.flatMap { try? WorkspaceSessionTools(identifiers: $0) }
            ?? WorkspaceSessionTools(enabled: agentTools?.settings.enabledByDefault ?? Set(WorkspaceToolGroup.allCases))
        return .init(prompt: "", configuration: .init(runtimeKind: runtime, workspaceID: workspaceID, title: title,
            model: selections.model, thinking: selections.thinking, permission: runtime == .pi ? nil : selections.permission,
            selectionWorkspace: scope, nativeWorkingDirectory: directory, tools: tools))
    }

    func calendarTaskMetadata(_ task: WorkspaceCalendarTask) async throws -> LocalACPSessionMetadata {
        let config = task.configuration
        let directory = try config.nativeWorkingDirectory ?? defaultToolWorkingDirectory(workspaceID: config.workspaceID)
        if config.runtimeKind == .opencode {
            if config.workspaceID != nil { await synchronizeRemoteOpenCodeInstances() }
            guard let instance = config.workspaceID.flatMap({ remoteOpenCodes[$0] }) ?? (config.workspaceID == nil ? openCode : nil) else {
                throw ApplicationModelError.remoteHarnessUnavailable
            }
            return try await instance.calendarTaskMetadata(directory: directory, model: config.model)
        }
        if config.runtimeKind == .openclaw {
            let agent = (localCLIAgents + remoteWorkspaceAgents).first {
                $0.runtimeKind == .openclaw && (config.workspaceID == nil ? $0.governingPlane == .wovenmatterMacOS : $0.runtimeDeviceID == config.workspaceID)
            }
            guard let agent, let store = dashboardStore, isOpenClawGatewayLinked(agentID: agent.id) else {
                throw WorkspaceToolError.invalid("Connect OpenClaw in this workspace's settings to load its models.")
            }
            return try await store.calendarOpenClawMetadata(agentID: agent.id, model: config.model)
        }
        let launch: LocalACPRuntimeLaunchConfiguration
        if let workspaceID = config.workspaceID {
            guard let remote = remoteWorkspaces.configuration(id: workspaceID), remoteWorkspaces.isHarnessReady(config.runtimeKind, in: remote) else {
                throw ApplicationModelError.remoteHarnessUnavailable
            }
            if config.runtimeKind == .hermes {
                guard let connection = remoteHermesConnections[workspaceID] else { throw WorkspaceToolError.invalid("Connect Hermes in this workspace's settings first.") }
                launch = .init(runtimeKind: .hermes, executableURL: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: [],
                    environment: ["WOVENMATTER_HERMES_CONNECTION": try JSONEncoder().encode(connection).base64EncodedString()],
                    processWorkingDirectoryURL: localACPWorkspaceLaunchConfiguration?.rootURL)
            } else {
                launch = try RemoteHarnessLaunchResolver.resolve(configuration: remote, runtimeKind: config.runtimeKind,
                    processWorkingDirectory: localACPWorkspaceLaunchConfiguration?.rootURL ?? FileManager.default.homeDirectoryForCurrentUser,
                    workspaceRoot: URL(fileURLWithPath: remoteWorkspaces.remoteWorkspaceRoot(for: remote)),
                    workingDirectory: URL(fileURLWithPath: directory)).launch
            }
        } else {
            guard let local = localACPLaunchConfigurations[config.runtimeKind] else { throw ApplicationModelError.localACPRuntimeUnavailable }
            if config.runtimeKind == .hermes { try requireLocalHermesLink() }
            launch = .init(runtimeKind: local.runtimeKind, executableURL: local.executableURL,
                arguments: local.arguments, environment: local.environment,
                environmentKeysToRemove: local.environmentKeysToRemove,
                environmentKeyPrefixesToRemove: local.environmentKeyPrefixesToRemove,
                processWorkingDirectoryURL: URL(fileURLWithPath: directory),
                requestedPermission: local.requestedPermission, wrappedCommand: local.wrappedCommand)
        }
        return try await CalendarSessionOptions.load(launch: launch, directory: URL(fileURLWithPath: directory), model: config.model)
    }

    /// Calendar owns scheduling; each prompt uses the normal session dispatch,
    /// native configuration, permission requests, and durable delivery path.
    func runCalendarTasks() async {
        guard let store = dashboardStore else { return }
        do {
            try await CalendarTaskRunner.tick(database: store.database,
                isRunning: { self.runningToolSessionIDs.contains($0) },
                hasCapacity: { self.runningToolSessionIDs.count < (self.agentTools?.settings.maximumRunningSessions ?? 16) },
                prepare: { try await self.prepareCalendarSession($0) },
                dispatch: { _ = try await self.dispatchToolDelivery($0) })
            if try store.database.dashboardRevision() != workspaceRevision { await refreshWorkspace() }
        } catch is CancellationError { }
        catch { calendarMutationError = error.localizedDescription }
    }

    private func prepareCalendarSession(_ run: WorkspaceCalendarRun) async throws {
        guard let store = dashboardStore, let id = UUID(uuidString: run.sessionID) else { throw ApplicationModelError.dashboardStoreUnavailable }
        let config = run.task.configuration
        if config.runtimeKind == .opencode, config.workspaceID == nil, openCode?.isEnabled != true {
            throw WorkspaceToolError.invalid("Enable OpenCode in Local agent workspace before running this task.")
        }
        let scope = config.selectionWorkspace ?? config.workspaceID.map { "remote:" + $0.uuidString.lowercased() }
            ?? "local:" + (config.nativeWorkingDirectory ?? "")
        let selections = SessionSelections(model: config.model, thinking: config.thinking,
            permission: config.runtimeKind == .pi ? nil : config.permission, tools: config.tools.enabled.map(\.rawValue).sorted())
        sessionSelectionPreferences.stageCalendarSelections(id: run.sessionID, harness: config.runtimeKind.rawValue,
            workspace: scope, selections: selections)
        if try store.database.workspaceOverview().conversations.first(where: { $0.id == run.sessionID }) == nil {
            // A deleted destination is not silently recreated under an old ID.
            if (try? store.database.localACPSession(conversationID: run.sessionID)) != nil {
                throw WorkspaceToolError.invalid("The task's session was deleted. Edit the task to use a new session.")
            }
            let created: String?
            let directory = config.nativeWorkingDirectory.map { URL(fileURLWithPath: $0) }
            if let workspaceID = config.workspaceID {
                guard let target = remoteWorkspaces.readyChatTargets.first(where: { $0.configuration.id == workspaceID && $0.harness.id == config.runtimeKind }) else {
                    throw ApplicationModelError.remoteHarnessUnavailable
                }
                created = await createRemoteACPSession(target: target, requestedConversationID: id,
                    nativeWorkingDirectory: directory, initialTitle: run.title, nativeWorkspaceID: config.nativeWorkspaceID)
            } else {
                created = await createLocalACPSession(runtimeKind: config.runtimeKind, requestedConversationID: id,
                    nativeWorkingDirectory: directory, initialTitle: run.title, nativeWorkspaceID: config.nativeWorkspaceID)
            }
            guard created == run.sessionID else { throw WorkspaceToolError.invalid(localRunError ?? "The scheduled session could not be created.") }
        }
        guard let conversation = try store.database.workspaceOverview().conversations.first(where: { $0.id == run.sessionID }) else {
            throw WorkspaceToolError.invalid("The scheduled session is unavailable.")
        }
        guard conversation.localRuntimeKind == config.runtimeKind, conversation.remoteWorkspaceID == config.workspaceID else {
            throw WorkspaceToolError.invalid("The session does not match the task's agent and workspace.")
        }
        guard try store.database.isCalendarRunActive(run.id) else { throw CancellationError() }
        if conversation.folderID != config.folderID {
            guard try store.database.moveConversation(id: run.sessionID, toFolderID: config.folderID) else {
                throw WorkspaceToolError.invalid("The scheduled session's folder could not be updated.")
            }
        }
        if config.runtimeKind == .openclaw { try await prepareCreatedOpenClawSession(conversation, configuration: config) }
        try store.database.setSessionTools(config.tools, sessionID: run.sessionID, confirmedPausingTimers: true)
        try await applyPendingSessionSelections(conversationID: run.sessionID)
        guard sessionSelectionPreferences.conversation(id: run.sessionID)?.requiresApplication == false else {
            throw WorkspaceToolError.invalid("The saved session settings could not be applied. Check the agent connection.")
        }
    }
}
