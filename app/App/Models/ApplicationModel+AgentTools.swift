import Foundation
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

/// Defaults for a tool-created destination. Outside callers have no source chat.
struct WorkspaceToolCallerSource {
    let id: String
    let localRuntimeKind: AgentRuntimeKind?
    let remoteWorkspaceID: UUID?
    let folderID: String?
    init(_ conversation: WorkspaceConversationRecord) {
        id = conversation.id; localRuntimeKind = conversation.localRuntimeKind
        remoteWorkspaceID = conversation.remoteWorkspaceID; folderID = conversation.folderID
    }
    init() {
        id = WovenMCPCaller.outside; localRuntimeKind = .pi; remoteWorkspaceID = nil; folderID = nil
    }
}

extension ApplicationModel {
    func configureSessionToolSelectionAdapter() {
        sessionSelectionWorkspaceID = { [weak self] id in
            try await self?.sessionToolSelectionWorkspace(conversationID: id)
        }
        currentSessionToolIDs = { [weak self] id in
            guard let database = self?.dashboardStore?.database,
                  let tools = try? await database.sessionTools(id) else { return nil }
            return tools.enabled.map(\.rawValue).sorted()
        }
        applyInitialSessionToolIDs = { [weak self] id, identifiers in
            guard let self, let database = self.dashboardStore?.database else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            try await database.applyInitialSessionTools(WorkspaceSessionTools(identifiers: identifiers), sessionID: id)
            try await self.agentTools?.reload()
        }
    }

    /// Resolves the actual native folder for local sessions, rather than assuming
    /// that an imported or tool-created chat uses the app's default working root.
    func sessionToolSelectionWorkspace(conversationID: String) async throws -> String {
        guard let store = dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        let database = store.database
        let session = try await database.localACPSession(conversationID: conversationID)
        let root = try await database.availableSessionExecutionRoot(id: conversationID)
        guard try await executionWorkspaceMatches(root.workspaceID, workspaceID: session.remoteWorkspaceID) else {
            throw WorkspaceToolError.invalid("This chat belongs to a different execution workspace.")
        }
        if let remote = session.remoteWorkspaceID { return "remote:" + remote.uuidString.lowercased() }
        if let scratch = try await database.sessionScratchDirectory(id: conversationID), scratch.rootPath == root.rootPath {
            return "local:" + (try defaultToolWorkingDirectory(workspaceID: nil))
        }
        return "local:" + URL(fileURLWithPath: root.rootPath).standardizedFileURL.path
    }

    private func captureToolSessionSelections(id: String, configuration: WorkspaceSessionCreationConfiguration,
                                              alreadyConfigured: Bool) throws {
        let scope: String
        if let saved = configuration.selectionWorkspace { scope = saved }
        else if let remote = configuration.workspaceID { scope = "remote:" + remote.uuidString.lowercased() }
        else {
            let path = try configuration.nativeWorkingDirectory ?? defaultToolWorkingDirectory(workspaceID: nil)
            scope = "local:" + URL(fileURLWithPath: path).standardizedFileURL.path
        }
        let selections = SessionSelections(model: configuration.model, thinking: configuration.thinking,
            permission: configuration.permission, tools: configuration.tools.enabled.map(\.rawValue).sorted())
        if alreadyConfigured {
            // Old reservations may predate preference snapshots; do not replay
            // their already-confirmed configuration over a later user change.
            sessionSelectionPreferences.captureExistingConversation(id: id,
                harness: configuration.runtimeKind.rawValue, workspace: scope, selections: selections)
        } else {
            sessionSelectionPreferences.captureConversation(id: id, harness: configuration.runtimeKind.rawValue,
                workspace: scope, selections: selections, capturedDefaults: SessionSelections(),
                usesProductPermissionDefault: configuration.usesProductPermissionDefault ?? false)
        }
    }

    func startAgentToolRuntime() {
        toolRuntimeTask?.cancel()
        toolRuntimeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runAgentToolTick()
                if let self, Date().timeIntervalSince(self.lastDatabaseSyncAt) >= 120 { await self.refreshDatabases() }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func runAgentToolTick() async {
        guard let database = dashboardStore?.database else { return }
        do {
            await runCalendarTasks()
            pendingSessionAccess = try await database.pendingCoordinationAccessRequests()
            var notifications = try await database.collectCoordinationTurnNotifications()
            for request in pendingLocalACPPermissions {
                if let delivery = try await database.recordCoordinationNeedsInput(sessionID: request.conversationID,
                    requestID: request.id.uuidString, requiresUserApproval: true) { notifications.append(delivery) }
            }
            for request in pendingLocalACPInteractions {
                let kind: ProgramStatus.Kind = switch request.request {
                case .plan: .permission
                case .questions, .form: .question
                case .secret: .auth
                }
                if let delivery = try await database.recordCoordinationNeedsInput(sessionID: request.conversationID,
                    requestID: request.id.uuidString, requiresUserApproval: kind == .permission, kind: kind) { notifications.append(delivery) }
            }
            for instance in openCodeInstances {
                for (sessionID, snapshot) in instance.snapshots where instance.isLocalSession(sessionID) {
                    for request in snapshot.permissions where !request["id"].text.isEmpty {
                        if let delivery = try await database.recordCoordinationNeedsInput(sessionID: sessionID,
                            requestID: "opencode:" + request["id"].text, requiresUserApproval: true) { notifications.append(delivery) }
                    }
                    for request in snapshot.forms where !request["id"].text.isEmpty {
                        if let delivery = try await database.recordCoordinationNeedsInput(sessionID: sessionID,
                            requestID: "opencode:" + request["id"].text, requiresUserApproval: false) { notifications.append(delivery) }
                    }
                }
            }
            for delivery in notifications {
                guard !Task.isCancelled else { return }
                do { _ = try await dispatchToolDelivery(delivery) }
                catch { agentTools?.error = error.localizedDescription }
            }
            let timers = try await database.dueSessionTimers()
            for timer in timers {
                guard !Task.isCancelled, let id = timer.pendingDeliveryID,
                      try await database.isTimerOccurrenceActive(id: timer.id, deliveryID: id) else { continue }
                if try await database.toolDelivery(id: id) == nil {
                    let delivery = try await database.reserveToolDelivery(sourceID: timer.sessionID, targetID: timer.sessionID,
                        text: timer.instruction, requestID: id, kind: .timer)
                    do { _ = try await dispatchToolDelivery(delivery) }
                    catch { agentTools?.error = error.localizedDescription }
                }
            }
            for delivery in try await database.sessionDeliveries(queuedOnly: true, includeCalendar: false) where delivery.kind != .goal {
                guard !Task.isCancelled else { return }
                // Initial sends try steering. A deferred send waits for an idle
                // target instead of repeatedly trying an unsupported operation.
                guard !runningToolSessionIDs.contains(delivery.targetID) else { continue }
                do { _ = try await dispatchToolDelivery(delivery) }
                catch { agentTools?.error = error.localizedDescription }
            }
            for timer in timers {
                guard let id = timer.pendingDeliveryID,
                      let receipt = try await database.toolDelivery(id: id),
                      ["accepted", "cancelled"].contains(receipt.status) else { continue }
                try await database.finishTimerOccurrence(id: timer.id, deliveryID: id)
            }
            await runConversationGoals()
            try await database.settleCalendarRuns()
            try await agentTools?.reloadInBackground()
        } catch { agentTools?.error = error.localizedDescription }
    }

    func resolveSessionToolAccess(id: String, allowed: Bool) async {
        if isBackendFrontend {
            Task {
                do { _ = try await sendBackendCommand(.resolveSessionAccess(id: id, allowed: allowed)) }
                catch { sessionAccessError = error.localizedDescription }
            }
            return
        }
        guard let database = dashboardStore?.database else { return }
        do {
            let outcome = try await database.resolveCoordinationAccess(requestID: id, allowed: allowed)
            pendingSessionAccess = try await database.pendingCoordinationAccessRequests()
            try await agentTools?.reload()
            sessionAccessError = outcome.state == "failed" ? outcome.error : nil
        } catch { sessionAccessError = error.localizedDescription }
    }

    func handleAgentNote(callerID: String, request: NoteEditingRequest, requestID: String) async throws -> NoteEditingResponse {
        guard let database = dashboardStore?.database else { throw CancellationError() }
        guard await flushNoteDrafts(), !noteEditingSuspended, !backendStopping else {
            throw ApplicationModelError.noteDraftSaveFailed
        }
        let response: NoteEditingResponse = switch request.command {
        case .read: try await database.readNoteForEditing(id: request.noteID, callerConversationID: callerID)
        case .apply: try await database.applyNoteEdits(request, callerConversationID: callerID, requestID: requestID)
        }
        await adoptNoteEditingResponse(response)
        return response
    }

    func handleAgentUsage(_ command: WovenMatterToolCommand) async throws -> WovenMatterToolResponse {
        let start = try command.options["since"].map(WorkspaceAgentToolsModel.date) ?? Date(timeIntervalSince1970: 0)
        let end = try command.options["until"].map(WorkspaceAgentToolsModel.date) ?? Date()
        guard end >= start else { throw WorkspaceToolError.invalid("--until must be at or after --since.") }
        let samples = try await recordedUsageSamples(from: start, to: end,
            limit: command.integer("limit", default: 100, range: 1...200),
            offset: command.integer("offset", default: 0, range: 0...(Int.max - 1)))
        struct UsageResult: Encodable {
            let samples: [UsageSample]
            let limits: [UsageLimitAccount]
        }
        return try .value(UsageResult(samples: samples, limits: localUsage?.limits ?? []))
    }

    func toolCallerSource(_ callerID: String) async throws -> WorkspaceToolCallerSource {
        if callerID == WovenMCPCaller.outside { return .init() }
        return try await .init(toolConversation(callerID))
    }

    private func toolConversation(_ id: String) async throws -> WorkspaceConversationRecord {
        guard let database = dashboardStore?.database,
              let conversation = try await database.workspaceOverview().conversations.first(where: { $0.id == id }) else {
            throw WorkspaceToolError.notFound("The requested session is unavailable.")
        }
        return conversation
    }

    func handleSessionTool(callerID: String, command: WovenMatterToolCommand, request: WovenMatterToolRequest) async throws -> WovenMatterToolResponse {
        guard let database = dashboardStore?.database else { throw CancellationError() }
        if command.isDatabaseCommand { return try await handleDatabaseTool(callerID: callerID, command: command) }
        try await database.requireTool(.sessions, sessionID: callerID)
        let source = try await toolCallerSource(callerID)
        switch command.action {
        case "create":
            return try await createToolSession(source: source, command: command, request: request)
        case "send":
            let delivery = try await database.reserveToolDelivery(sourceID: callerID,
                targetID: command.required("id", allowPositional: true), text: command.required("text"), requestID: request.requestID)
            return try await dispatchToolDelivery(delivery)
        case "manage":
            let outcome = try await database.requestCoordinationAccess(sourceID: callerID,
                targetID: command.required("id", allowPositional: true), purpose: command.required("purpose"),
                notifications: command.options["no-notify"] == nil, requestID: request.requestID)
            pendingSessionAccess = try await database.pendingCoordinationAccessRequests()
            let value = try WovenMatterToolResponse.value(outcome)
            return .init(success: outcome.error == nil, result: value.result, error: outcome.error)
        case "release":
            let id = try command.required("id", allowPositional: true)
            return try await .value(database.releaseAgentCoordination(sourceID: callerID, targetID: id,
                epoch: command.required("epoch"), requestID: request.requestID))
        case "notifications":
            let id = try command.required("id", allowPositional: true)
            let raw = try command.required("enabled")
            guard ["true", "false"].contains(raw) else { throw WorkspaceToolError.invalid("--enabled must be true or false.") }
            return try await .value(database.setAgentCoordinationNotifications(sourceID: callerID, targetID: id,
                epoch: command.required("epoch"), enabled: raw == "true", requestID: request.requestID))
        case "receipts":
            let limit = try command.integer("limit", default: 100, range: 1...200)
            var receipts = try await database.sessionDeliveries(sessionID: callerID,
                limit: limit + 1, beforeID: command.options["before"])
            let more = receipts.count > limit
            if more { receipts.removeLast() }
            return .init(result: .object([
                "rows": .array(try receipts.map(compactToolDelivery)),
                "hasMore": .bool(more),
                "nextCursor": receipts.last.map { .string($0.id) } ?? .null
            ]))
        case "harnesses":
            let local: [GatewayJSONValue] = LocalACPRuntimeCatalog.definitions.map {
                .object(["harness": .string($0.runtimeKind.rawValue), "workspace": .string("local"), "ready": .bool(isLocalACPAgentReady($0.runtimeKind))])
            }
            let remote: [GatewayJSONValue] = remoteWorkspaces.workspaces.flatMap { workspace in
                (remoteWorkspaces.harnesses[workspace.id] ?? []).map { harness in
                    .object(["harness": .string(harness.id.rawValue), "workspace": .string(workspace.id.uuidString.lowercased()),
                        "workspaceName": .string(workspace.name), "ready": .bool(remoteWorkspaces.isHarnessReady(harness.id, in: workspace))])
                }
            }
            let rows = local + remote
            let offset = try command.integer("offset", default: 0, range: 0...(Int.max - 1))
            let limit = try command.integer("limit", default: 100, range: 1...200)
            let page = Array(rows.dropFirst(offset).prefix(limit))
            let next = offset + page.count
            return .init(result: .object(["rows": .array(page), "hasMore": .bool(next < rows.count),
                "nextOffset": .number(Double(next))]))
        default: throw WorkspaceToolError.invalid("Unsupported session operation.")
        }
    }

    private func createToolSession(source: WorkspaceToolCallerSource, command: WovenMatterToolCommand,
                                   request: WovenMatterToolRequest) async throws -> WovenMatterToolResponse {
        guard let store = dashboardStore else { throw CancellationError() }
        // Coalesce concurrent retries while native creation is suspended.
        let creationKey = source.id + ":" + request.requestID + ":" + String(decoding: try JSONEncoder().encode(request.operationArguments), as: UTF8.self)
        if let pending = toolCreationTasks[creationKey] { return try await pending.value }
        let task = Task { @MainActor in
            let title = try command.required("title")
            let text = try command.required("text")
            let purpose = try command.required("purpose")
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.utf8.count <= 4_096 else {
                throw WorkspaceToolError.invalid("A session title must be at most 4 KiB.")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 65_536 else {
                throw WorkspaceToolError.invalid("A session instruction must be at most 64 KiB.")
            }
            guard !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  purpose.utf8.count <= 65_536 else {
                throw WorkspaceToolError.invalid("A session purpose must be at most 64 KiB.")
            }
            let reservation = try await store.database.reserveToolSessionCreation(sourceID: source.id, requestID: request.requestID,
                arguments: request.operationArguments, purpose: purpose, managed: source.id != WovenMCPCaller.outside && command.options["independent"] == nil)
            guard let id = reservation.objectValue?["target_id"]?.stringValue, let uuid = UUID(uuidString: id) else {
                throw WorkspaceToolError.invalid("Unable to reserve the new session.")
            }
            let dispatchFence = self.beginAgentDispatch(conversationID: id)
            defer { self.finishAgentDispatch(conversationID: id, fence: dispatchFence) }
            // Completed delivery receipts must replay before admission: unrelated
            // running sessions cannot turn a successful creation into at_capacity.
            if reservation.objectValue?["status"]?.stringValue == "ready",
               try await store.database.toolDelivery(id: request.requestID) != nil {
                let delivery = try await store.database.reserveToolDelivery(sourceID: source.id, targetID: id, text: text,
                    requestID: request.requestID, kind: .created, purpose: purpose)
                return try await self.dispatchToolDelivery(delivery, dispatchFence: dispatchFence)
            }
            guard let agentTools = self.agentTools else { throw ApplicationModelError.dashboardStoreUnavailable }
            let admission = self.toolSessionAdmission.begin(id, running: self.runningToolSessionIDs,
                limit: agentTools.settings.maximumRunningSessions)
            if admission == .atCapacity {
                try? await store.database.failToolSessionCreation(requestID: request.requestID)
                throw WorkspaceToolError.atCapacity(agentTools.settings.maximumRunningSessions)
            }
            if admission == .preparing { throw ApplicationModelError.localSessionConfigurationInProgress }
            defer { self.toolSessionAdmission.finish(id) }
            do {
                try dispatchFence.check()
                if reservation.objectValue?["status"]?.stringValue != "ready" {
                    let configuration: WorkspaceSessionCreationConfiguration
                    if let json = reservation.objectValue?["configuration_json"]?.stringValue {
                        configuration = try JSONDecoder().decode(WorkspaceSessionCreationConfiguration.self, from: Data(json.utf8))
                    } else {
                        let proposed = try await self.resolveToolSessionCreation(source: source, command: command, title: title)
                        try dispatchFence.check()
                        configuration = try await store.database.saveToolSessionCreationConfiguration(requestID: request.requestID,
                            sourceID: source.id, configuration: proposed)
                    }
                    try dispatchFence.check()
                    let runtime = configuration.runtimeKind
                    let alreadyConfigured = reservation.objectValue?["configuration_applied"]?.intValue == 1
                    try self.captureToolSessionSelections(id: id, configuration: configuration, alreadyConfigured: alreadyConfigured)
                    let remoteTarget: RemoteHarnessChatTarget?
                    if let workspaceID = configuration.workspaceID {
                        guard let workspace = self.remoteWorkspaces.configuration(id: workspaceID),
                              let harness = self.remoteWorkspaces.harnesses[workspaceID]?.first(where: { $0.id == runtime }),
                              self.remoteWorkspaces.isHarnessReady(runtime, in: workspace) else {
                            throw WorkspaceToolError.invalid("The destination workspace or harness is unavailable.")
                        }
                        remoteTarget = .init(configuration: workspace, harness: harness)
                    } else { remoteTarget = nil }
                    if (try? await self.toolConversation(id)) == nil {
                        try dispatchFence.check()
                        let directory = configuration.nativeWorkingDirectory.map { URL(fileURLWithPath: $0) }
                        let created: String?
                        if let remoteTarget {
                            created = await self.createRemoteACPSession(target: remoteTarget, requestedConversationID: uuid,
                                nativeWorkingDirectory: directory, initialTitle: configuration.title, nativeWorkspaceID: configuration.nativeWorkspaceID, folderID: configuration.folderID)
                        } else {
                            created = await self.createLocalACPSession(runtimeKind: runtime, requestedConversationID: uuid,
                                nativeWorkingDirectory: directory, initialTitle: configuration.title, nativeWorkspaceID: configuration.nativeWorkspaceID, folderID: configuration.folderID)
                        }
                        guard created == id else { throw WorkspaceToolError.invalid(self.localRunError ?? "Unable to create the session.") }
                    }
                    let target = try await self.toolConversation(id)
                    try dispatchFence.check()
                    guard target.localRuntimeKind == runtime, target.remoteWorkspaceID == configuration.workspaceID else {
                        throw WorkspaceToolError.invalid("The saved session does not match this creation request's destination.")
                    }
                    try await store.database.requireTool(.sessions, sessionID: source.id)
                    try dispatchFence.check()

                    // Initial title/folder/tools commit with session insertion.
                    // Retrying preparation must preserve any later user edits.
                    try dispatchFence.check()
                    if !alreadyConfigured {
                        try dispatchFence.check()
                        try await store.database.markToolSessionCreationConfigured(requestID: request.requestID, sourceID: source.id)
                    }
                    try dispatchFence.check()
                    try await store.database.completeToolSessionCreation(requestID: request.requestID, sourceID: source.id)
                }
                try dispatchFence.check()
                let delivery = try await store.database.reserveToolDelivery(sourceID: source.id, targetID: id, text: text,
                    requestID: request.requestID, kind: .created, purpose: purpose)
                await self.refreshWorkspace()
                return try await self.dispatchToolDelivery(delivery, admissionDecision: admission,
                    dispatchFence: dispatchFence)
            } catch {
                try? await store.database.failToolSessionCreation(requestID: request.requestID)
                if let delivery = try? await store.database.toolDelivery(id: request.requestID) {
                    return try self.toolDeliveryResponse(delivery)
                }
                if (try? await self.toolConversation(id)) != nil {
                    return .init(success: false, result: .object([
                        "id": .string(id), "state": .string("created_not_started")
                    ]), error: error.localizedDescription, code: "created_not_started")
                }
                throw error
            }
        }
        toolCreationTasks[creationKey] = task
        defer { toolCreationTasks.removeValue(forKey: creationKey) }
        return try await task.value
    }

    func resolveToolSessionCreation(source: WorkspaceConversationRecord, command: WovenMatterToolCommand,
                                            title: String) async throws -> WorkspaceSessionCreationConfiguration {
        try await resolveToolSessionCreation(source: WorkspaceToolCallerSource(source), command: command, title: title)
    }

    func resolveToolSessionCreation(source: WorkspaceToolCallerSource, command: WovenMatterToolCommand,
                                            title: String) async throws -> WorkspaceSessionCreationConfiguration {
        if let raw = command.options["harness"], AgentRuntimeKind(rawValue: raw) == nil {
            throw WorkspaceToolError.invalid("Unknown harness.")
        }
        guard let runtime = command.options["harness"].flatMap(AgentRuntimeKind.init(rawValue:)) ?? source.localRuntimeKind ?? (source.id == WovenMCPCaller.outside ? .pi : nil) else {
            throw WorkspaceToolError.invalid("Choose a configured harness.")
        }
        guard AgentRuntimeKind.allCases.contains(runtime) else { throw WorkspaceToolError.invalid("This harness has been retired.") }
        let workspace = command.options["workspace"] ?? source.remoteWorkspaceID?.uuidString.lowercased() ?? "local"
        let workspaceID: UUID?
        if workspace == "local" { workspaceID = source.remoteWorkspaceID }
        else {
            guard let id = UUID(uuidString: workspace) else { throw WorkspaceToolError.invalid("The destination workspace is unavailable.") }
            workspaceID = id
        }
        guard let store = dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        let federatedSource = try await store.database.companionExecutionOwner(conversationID: source.id) != nil
        if federatedSource, command.options["workspace"] == nil || command.options["harness"] == nil {
            throw WorkspaceToolError.invalid("Choose an explicit --workspace and --harness when creating a central session from another device.")
        }
        let sameWorkspace = !federatedSource && workspaceID == source.remoteWorkspaceID
        let destinationFolder: String?
        if let selected = command.options["folder"] {
            destinationFolder = ["all", "ungrouped"].contains(selected) ? nil : selected
        } else { destinationFolder = sameWorkspace ? source.folderID : nil }
        let directory = try await folderWorkingDirectory(folderID: destinationFolder, workspaceID: workspaceID,
            explicit: command.options["directory"].map { URL(fileURLWithPath: $0) }).path
        let scope = workspaceID.map { "remote:" + $0.uuidString.lowercased() }
            ?? "local:" + URL(fileURLWithPath: directory).standardizedFileURL.path
        let explicit = SessionSelections(model: command.options["model"], thinking: command.options["thinking"])
        let resolved = explicit.overlaying(sessionSelectionPreferences.defaults(harness: runtime.rawValue, workspace: scope))
        let settings = try await store.database.toolSettings()
        var tools: WorkspaceSessionTools
        if let identifiers = resolved.tools { tools = try WorkspaceSessionTools(identifiers: identifiers) }
        else { tools = WorkspaceSessionTools(enabled: settings.enabledByDefault) }
        tools.executorProfiles = settings.executor?.defaultProfiles ?? []
        return .init(runtimeKind: runtime, workspaceID: workspaceID, folderID: destinationFolder,
            title: title, model: resolved.model, thinking: resolved.thinking,
            permission: runtime == .pi ? nil : resolved.permission,
            usesProductPermissionDefault: sessionSelectionPreferences.usesProductPermissionDefault(harness: runtime.rawValue, workspace: scope),
            selectionWorkspace: scope,
            nativeWorkingDirectory: directory,
            nativeWorkspaceID: nil, tools: tools)
    }

    func dispatchToolDelivery(_ delivery: WorkspaceSessionDelivery,
                              admissionDecision: WorkspaceSessionAdmission.Decision? = nil,
                              dispatchFence suppliedFence: AgentDispatchFence? = nil) async throws -> WovenMatterToolResponse {
        guard let database = dashboardStore?.database else { throw CancellationError() }
        // Claiming and loading the target are part of preparation. Stop owns
        // the same fence across these waits and any earlier reserved creation.
        let dispatchFence = suppliedFence ?? beginAgentDispatch(conversationID: delivery.targetID)
        defer { if suppliedFence == nil { finishAgentDispatch(conversationID: delivery.targetID, fence: dispatchFence) } }
        guard let claimed = try await database.claimToolDelivery(id: delivery.id) else {
            return try await toolDeliveryResponse(database.toolDelivery(id: delivery.id) ?? delivery)
        }
        do {
            try dispatchFence.check()
            let target = try await toolConversation(claimed.targetID)
            try dispatchFence.check()
            if claimed.kind == .calendar, target.localRuntimeKind == .opencode,
               target.remoteWorkspaceID == nil, openCode?.isEnabled != true {
                throw WorkspaceToolError.invalid("Install and connect OpenCode in Local workspace before running this task.")
            }
            let sent = try await dispatchAgentMessage(conversation: target,
                input: .init(text: claimed.text, historyDeliveryID: claimed.id),
                allowSteering: claimed.kind != .calendar && claimed.kind != .goal, admissionDecision: admissionDecision,
                dispatchFence: dispatchFence)
            guard sent else {
                if claimed.kind == .calendar || claimed.kind == .goal {
                    try await database.setToolDeliveryStatus(id: claimed.id, status: "queued")
                    return try await .value(database.toolDelivery(id: claimed.id) ?? claimed)
                }
                // Capacity is not a scheduler. No new queue is created by the limit.
                let limit = agentTools?.settings.maximumRunningSessions ?? 16
                let error = WorkspaceToolError.atCapacity(limit)
                try await database.setToolDeliveryStatus(id: claimed.id, status: "cancelled",
                    failureCode: "at_capacity", failureReason: error.localizedDescription)
                return try await toolDeliveryResponse(database.toolDelivery(id: claimed.id) ?? claimed)
            }
            try await database.setToolDeliveryStatus(id: claimed.id, status: "accepted")
        } catch LocalACPSessionDatabaseError.steeringUnsupported {
            try await database.setToolDeliveryStatus(id: claimed.id, status: "queued")
        } catch {
            if dispatchFence.isCancelled, !dispatchFence.hasDispatched {
                // A user-stopped occurrence cannot return to a retry queue.
                try await database.setToolDeliveryStatus(id: claimed.id, status: "cancelled")
            } else if !dispatchFence.hasDispatched, (error as? OpenCodeError) == .executionRootMismatch {
                try await database.setToolDeliveryStatus(id: claimed.id, status: "failed")
            } else { try await database.failToolDeliveryAttempt(id: claimed.id) }
            if let failed = try await database.toolDelivery(id: claimed.id),
               ["cancelled", "failed", "uncertain"].contains(failed.status) {
                let code = failed.status == "uncertain" ? "delivery_uncertain"
                    : failed.status == "cancelled" ? "delivery_cancelled" : "delivery_failed"
                try await database.setToolDeliveryStatus(id: failed.id, status: failed.status,
                    failureCode: code, failureReason: String(error.localizedDescription.prefix(256)))
                return try await toolDeliveryResponse(database.toolDelivery(id: failed.id) ?? failed)
            }
            throw error
        }
        return try await toolDeliveryResponse(database.toolDelivery(id: claimed.id) ?? claimed)
    }

    private func toolDeliveryResponse(_ delivery: WorkspaceSessionDelivery) throws -> WovenMatterToolResponse {
        let encoded = try WovenMatterToolResponse.value(delivery)
        switch delivery.status {
        case "cancelled", "failed", "uncertain":
            let code = delivery.failureCode ?? (delivery.status == "uncertain" ? "delivery_uncertain" : delivery.status)
            let message = delivery.failureReason ?? "The delivery is \(delivery.status)."
            return .init(success: false, result: encoded.result, error: message, code: code)
        default:
            return encoded
        }
    }

    private func compactToolDelivery(_ delivery: WorkspaceSessionDelivery) throws -> GatewayJSONValue {
        guard var value = try WovenMatterToolResponse.value(delivery).result?.objectValue else { return .null }
        let preview = String(delivery.text.prefix(4_096))
        value["text"] = .string(preview)
        value["textCharacters"] = .number(Double(delivery.text.count))
        value["textHasMore"] = .bool(preview.count < delivery.text.count)
        if let purpose = delivery.purpose {
            let purposePreview = String(purpose.prefix(4_096))
            value["purpose"] = .string(purposePreview)
            value["purposeCharacters"] = .number(Double(purpose.count))
            value["purposeHasMore"] = .bool(purposePreview.count < purpose.count)
        }
        return .object(value)
    }
}


extension ApplicationModel {
    func handleDatabaseTool(callerID: String, command: WovenMatterToolCommand) async throws -> WovenMatterToolResponse {
        guard let store = dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        try await store.database.requireTool(.notes, sessionID: callerID)
        let source = try await toolCallerSource(callerID)
        let action = String(command.action.dropFirst("database-".count))
        if let workspaceID = source.remoteWorkspaceID {
            guard let configuration = remoteWorkspaces.configuration(id: workspaceID) else { throw ApplicationModelError.remoteHarnessUnavailable }
            if action == "list" { return try WovenMatterToolResponse.value(await remoteWorkspaces.databases(for: configuration)) }
            if action == "create" { return try WovenMatterToolResponse.value(await remoteWorkspaces.createDatabase(name: command.required("title"), in: configuration)) }
            let result = try await remoteWorkspaces.datasetOperation(action: action, id: command.required("database-id"), sql: command.required("query"), in: configuration)
            if action == "execute" { await refreshDatabases() }
            return .init(result: result)
        }
        guard let root = localACPWorkspaceLaunchConfiguration?.databasesURL else { throw ApplicationModelError.localACPRuntimeUnavailable }
        let owner = try await executionWorkspaceIdentity(workspaceID: nil)
        let id = command.options["database-id"] ?? "", sql = command.options["query"] ?? "", title = command.options["title"] ?? ""
        switch action {
        case "list": return try WovenMatterToolResponse.value(await Task.detached { try AgentDatabaseCatalog.list(at: root) }.value)
        case "create":
            let row = try await Task.detached { try AgentDatabaseCatalog.create(named: title, in: root, owner: owner) }.value
            await refreshDatabases(); return try WovenMatterToolResponse.value(row)
        case "query": return try WovenMatterToolResponse.value(await Task.detached { try AgentDatabaseCatalog.query(id: id, sql: sql, in: root) }.value)
        case "execute":
            let row = try await Task.detached { try AgentDatabaseCatalog.execute(id: id, sql: sql, in: root, owner: owner) }.value
            await refreshDatabases(); return try WovenMatterToolResponse.value(row)
        default: throw WorkspaceToolError.invalid("Unsupported database command.")
        }
    }
}
