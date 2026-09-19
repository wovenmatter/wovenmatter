import Foundation
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

extension ApplicationModel {
    func startAgentToolRuntime() {
        toolRuntimeTask?.cancel()
        toolRuntimeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runAgentToolTick()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func runAgentToolTick() async {
        guard let database = dashboardStore?.database else { return }
        do {
            pendingSessionAccess = try database.pendingCoordinationAccessRequests()
            var notifications = try database.collectCoordinationTurnNotifications()
            for request in pendingLocalACPPermissions {
                if let delivery = try database.recordCoordinationNeedsInput(sessionID: request.conversationID,
                    requestID: request.id.uuidString, requiresUserApproval: true) { notifications.append(delivery) }
            }
            for request in pendingLocalACPInteractions {
                if let delivery = try database.recordCoordinationNeedsInput(sessionID: request.conversationID,
                    requestID: request.id.uuidString, requiresUserApproval: true) { notifications.append(delivery) }
            }
            for instance in openCodeInstances {
                for (sessionID, snapshot) in instance.snapshots {
                    for request in snapshot.permissions + snapshot.forms where !request["id"].text.isEmpty {
                        if let delivery = try database.recordCoordinationNeedsInput(sessionID: sessionID,
                            requestID: "opencode:" + request["id"].text, requiresUserApproval: true) { notifications.append(delivery) }
                    }
                }
            }
            for delivery in notifications {
                guard !Task.isCancelled else { return }
                do { _ = try await dispatchToolDelivery(delivery) }
                catch { agentTools?.error = error.localizedDescription }
            }
            let timers = try database.dueSessionTimers()
            for timer in timers {
                guard !Task.isCancelled, let id = timer.pendingDeliveryID,
                      try database.isTimerOccurrenceActive(id: timer.id, deliveryID: id) else { continue }
                if try database.toolDelivery(id: id) == nil {
                    let delivery = try database.reserveToolDelivery(sourceID: timer.sessionID, targetID: timer.sessionID,
                        text: timer.instruction, requestID: id, kind: .timer)
                    do { _ = try await dispatchToolDelivery(delivery) }
                    catch { agentTools?.error = error.localizedDescription }
                }
            }
            for delivery in try database.sessionDeliveries(queuedOnly: true) {
                guard !Task.isCancelled else { return }
                // Initial sends try steering. A deferred send waits for an idle
                // target instead of repeatedly trying an unsupported operation.
                guard !runningToolSessionIDs.contains(delivery.targetID) else { continue }
                do { _ = try await dispatchToolDelivery(delivery) }
                catch { agentTools?.error = error.localizedDescription }
            }
            for timer in timers {
                guard let id = timer.pendingDeliveryID,
                      let receipt = try database.toolDelivery(id: id),
                      !["queued", "sending"].contains(receipt.status) else { continue }
                try database.finishTimerOccurrence(id: timer.id, deliveryID: id)
            }
            try agentTools?.reload()
        } catch { agentTools?.error = error.localizedDescription }
    }

    func resolveSessionToolAccess(id: String, allowed: Bool) {
        guard let database = dashboardStore?.database else { return }
        do {
            let outcome = try database.resolveCoordinationAccess(requestID: id, allowed: allowed)
            pendingSessionAccess = try database.pendingCoordinationAccessRequests()
            try agentTools?.reload()
            sessionAccessError = outcome.state == "failed" ? outcome.error : nil
        } catch { sessionAccessError = error.localizedDescription }
    }

    func handleAgentNote(callerID: String, request: NoteEditingRequest, requestID: String) async throws -> NoteEditingResponse {
        guard let database = dashboardStore?.database else { throw CancellationError() }
        guard flushNoteDrafts() else { throw ApplicationModelError.noteDraftSaveFailed }
        let response: NoteEditingResponse = switch request.command {
        case .read: try database.readNoteForEditing(id: request.noteID, callerConversationID: callerID)
        case .apply: try database.applyNoteEdits(request, callerConversationID: callerID, requestID: requestID)
        }
        await adoptNoteEditingResponse(response)
        return response
    }

    func handleAgentUsage(_ command: WovenMatterToolCommand) async throws -> WovenMatterToolResponse {
        let start = try command.options["since"].map(WorkspaceAgentToolsModel.date) ?? Date(timeIntervalSince1970: 0)
        let end = try command.options["until"].map(WorkspaceAgentToolsModel.date) ?? Date()
        let samples = try await localUsageService.recordedSamples(from: start, to: end,
            limit: command.integer("limit", default: 100, range: 1...200),
            offset: command.integer("offset", default: 0, range: 0...(Int.max - 1)))
        return try .value(samples)
    }

    private func toolConversation(_ id: String) throws -> WorkspaceConversationRecord {
        guard let database = dashboardStore?.database,
              let conversation = try database.workspaceOverview().conversations.first(where: { $0.id == id }) else {
            throw WorkspaceToolError.invalid("The requested session is unavailable.")
        }
        return conversation
    }

    func handleSessionTool(callerID: String, command: WovenMatterToolCommand, request: WovenMatterToolRequest) async throws -> WovenMatterToolResponse {
        guard let database = dashboardStore?.database else { throw CancellationError() }
        try database.requireTool(.sessions, sessionID: callerID)
        let source = try toolConversation(callerID)
        switch command.action {
        case "create":
            return try await createToolSession(source: source, command: command, request: request)
        case "send":
            let delivery = try database.reserveToolDelivery(sourceID: callerID,
                targetID: command.required("id", allowPositional: true), text: command.required("text"), requestID: request.requestID)
            return try await dispatchToolDelivery(delivery)
        case "manage":
            let outcome = try database.requestCoordinationAccess(sourceID: callerID,
                targetID: command.required("id", allowPositional: true), purpose: command.required("purpose"),
                notifications: command.options["no-notify"] == nil, requestID: request.requestID)
            pendingSessionAccess = try database.pendingCoordinationAccessRequests()
            let value = try WovenMatterToolResponse.value(outcome)
            return .init(success: outcome.error == nil, result: value.result, error: outcome.error)
        case "release":
            let id = try command.required("id", allowPositional: true)
            try database.endCoordination(targetID: id, sourceID: callerID)
            return try .value(database.sessionRelationship(id))
        case "notifications":
            let id = try command.required("id", allowPositional: true)
            let raw = try command.required("enabled")
            guard ["true", "false"].contains(raw) else { throw WorkspaceToolError.invalid("--enabled must be true or false.") }
            try database.setCoordinationNotifications(sourceID: callerID, targetID: id, enabled: raw == "true")
            return try .value(database.sessionRelationship(id))
        case "receipts": return try .value(database.sessionDeliveries(sessionID: callerID,
            limit: command.integer("limit", default: 200, range: 1...500), beforeID: command.options["before"]))
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
            return .init(result: .array(local + remote))
        default: throw WorkspaceToolError.invalid("Unsupported session operation.")
        }
    }

    private func createToolSession(source: WorkspaceConversationRecord, command: WovenMatterToolCommand,
                                   request: WovenMatterToolRequest) async throws -> WovenMatterToolResponse {
        guard let store = dashboardStore else { throw CancellationError() }
        // Coalesce concurrent retries while native creation is suspended.
        let creationKey = source.id + ":" + request.requestID + ":" + String(decoding: try JSONEncoder().encode(request.operationArguments), as: UTF8.self)
        if let pending = toolCreationTasks[creationKey] { return try await pending.value }
        let task = Task { @MainActor in
            let title = try command.required("title")
            let text = try command.required("text")
            let purpose = try command.required("purpose")
            guard let runtime = command.options["harness"].flatMap(AgentRuntimeKind.init(rawValue:)) ?? source.localRuntimeKind else {
                throw WorkspaceToolError.invalid("Choose a configured harness.")
            }
            if let raw = command.options["harness"], AgentRuntimeKind(rawValue: raw) == nil { throw WorkspaceToolError.invalid("Unknown harness.") }
            let folder = command.options["folder"] ?? source.folderID
            if let folder, !(try store.database.workspaceOverview().folders.contains { $0.id == folder }) {
                throw WorkspaceToolError.invalid("The destination folder is unavailable.")
            }
            let workspace = command.options["workspace"] ?? source.remoteWorkspaceID?.uuidString.lowercased() ?? "local"
            let remoteTarget: RemoteHarnessChatTarget?
            if workspace == "local" { remoteTarget = nil }
            else {
                guard let id = UUID(uuidString: workspace), let configuration = self.remoteWorkspaces.configuration(id: id),
                      let harness = self.remoteWorkspaces.harnesses[id]?.first(where: { $0.id == runtime }),
                      self.remoteWorkspaces.isHarnessReady(runtime, in: configuration) else {
                    throw WorkspaceToolError.invalid("The destination workspace or harness is unavailable.")
                }
                remoteTarget = .init(configuration: configuration, harness: harness)
            }
            let reservation = try store.database.reserveToolSessionCreation(sourceID: source.id, requestID: request.requestID,
                arguments: request.operationArguments, purpose: purpose, managed: command.options["independent"] == nil)
            guard let id = reservation.objectValue?["target_id"]?.stringValue, let uuid = UUID(uuidString: id) else {
                throw WorkspaceToolError.invalid("Unable to reserve the new session.")
            }
            do {
                if reservation.objectValue?["status"]?.stringValue != "ready" {
                    if (try? self.toolConversation(id)) == nil {
                        let created: String?
                        if let remoteTarget { created = await self.createRemoteACPSession(target: remoteTarget, requestedConversationID: uuid) }
                        else { created = await self.createLocalACPSession(runtimeKind: runtime, requestedConversationID: uuid) }
                        guard created == id else { throw WorkspaceToolError.invalid(self.localRunError ?? "Unable to create the session.") }
                    }
                    let target = try self.toolConversation(id)
                    _ = try store.database.updateConversationTitleIfCurrent(id: id, expectedTitle: target.title, title: title)
                    guard try store.database.moveConversation(id: id, toFolderID: folder) else { throw WorkspaceToolError.invalid("Unable to set the destination folder.") }
                    if runtime == .opencode, let native = self.openCodeModel(for: id) {
                        _ = try await native.sessionCall(id, "/rename", method: "POST", body: ["title": .string(title)])
                    }
                    let sameRuntime = runtime == source.localRuntimeKind
                    if sameRuntime { await self.refreshLocalACPSession(conversation: source) }
                    let metadata = source.localRuntimeKind == .opencode ? self.openCodeModel(for: source.id)?.metadata(source.id) : self.localACPSessionMetadata[source.id]
                    let model = command.options["model"] ?? (sameRuntime ? metadata?.model : nil)
                    let thinking = command.options["thinking"] ?? (sameRuntime ? metadata?.thinking : nil)
                    if model != nil || thinking != nil {
                        if runtime == .opencode { self.openCodeModel(for: id)?.updateSelection(id, model: model, thinking: thinking) }
                        else {
                            let context = try self.directACPLaunchContext(conversation: target, runtimeKind: runtime, isBuzzWorkspaceSession: false)
                            _ = try await store.updateLocalACPSessionConfiguration(conversationID: id, model: model, thinking: thinking,
                                launch: context?.launch, workspace: context?.workspace)
                        }
                    }
                    try store.database.completeToolSessionCreation(requestID: request.requestID, sourceID: source.id)
                }
                let delivery = try store.database.reserveToolDelivery(sourceID: source.id, targetID: id, text: text,
                    requestID: request.requestID, kind: .created, purpose: purpose)
                await self.refreshWorkspace()
                return try await self.dispatchToolDelivery(delivery)
            } catch {
                try? store.database.failToolSessionCreation(requestID: request.requestID)
                throw error
            }
        }
        toolCreationTasks[creationKey] = task
        defer { toolCreationTasks.removeValue(forKey: creationKey) }
        return try await task.value
    }

    func dispatchToolDelivery(_ delivery: WorkspaceSessionDelivery) async throws -> WovenMatterToolResponse {
        guard let database = dashboardStore?.database else { throw CancellationError() }
        guard let claimed = try database.claimToolDelivery(id: delivery.id) else { return try .value(database.toolDelivery(id: delivery.id) ?? delivery) }
        do {
            let target = try toolConversation(claimed.targetID)
            let sent = try await dispatchAgentMessage(conversation: target,
                input: .init(text: claimed.text, historyDeliveryID: claimed.id))
            guard sent else {
                // Capacity is not a scheduler. No new queue is created by the limit.
                try database.setToolDeliveryStatus(id: claimed.id, status: "cancelled")
                return .init(silent: true)
            }
            try database.setToolDeliveryStatus(id: claimed.id, status: "accepted")
        } catch LocalACPSessionDatabaseError.steeringUnsupported {
            try database.setToolDeliveryStatus(id: claimed.id, status: "queued")
        } catch {
            // The transport may have accepted input before losing its reply. The
            // durable receipt prevents an automatic duplicate in that case.
            try database.setToolDeliveryStatus(id: claimed.id, status: "uncertain")
            throw error
        }
        return try .value(database.toolDelivery(id: claimed.id) ?? claimed)
    }
}
