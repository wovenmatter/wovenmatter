import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore


extension ApplicationModel {
    func isOpenClawGatewayLinked(agentID: UUID) -> Bool {
        openClawGatewayLinks.contains { $0.agentID == agentID }
    }

    func isOpenClawGatewayConversation(_ conversationID: String) -> Bool {
        openClawGatewayConversationIDs.contains(conversationID)
    }

    func openClawGatewayLink(agentID: UUID) -> OpenClawGatewayLink? {
        openClawGatewayLinks.first { $0.agentID == agentID }
    }

    func renameOpenClawAgent(agentID: UUID, displayName: String) {
        guard let dashboardStore else { return }
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            openClawGatewayErrors[agentID] = "Enter a Woven Matter agent name."
            return
        }
        openClawGatewayOperationAgentIDs.insert(agentID)
        openClawGatewayErrors[agentID] = nil
        openClawGatewayNotices[agentID] = nil
        Task {
            defer { openClawGatewayOperationAgentIDs.remove(agentID) }
            do {
                try await dashboardStore.renameOpenClawAgent(
                    agentID: agentID,
                    displayName: cleanName
                )
                await refreshWorkspace()
                openClawGatewayNotices[agentID] = "Woven Matter name updated."
            } catch {
                openClawGatewayErrors[agentID] = error.localizedDescription
            }
        }
    }

    func linkOpenClawGateway(agent: WorkspaceAgent) {
        guard agent.runtimeKind == .openclaw, let dashboardStore else {
            openClawGatewayErrors[agent.id] = OpenClawGatewayEndpointResolutionError
                .openClawRequired.localizedDescription
            return
        }
        openClawGatewayOperationAgentIDs.insert(agent.id)
        openClawGatewayOperationStatuses[agent.id] = .connecting
        openClawGatewayErrors[agent.id] = nil
        openClawGatewayNotices[agent.id] = nil
        Task {
            defer {
                openClawGatewayOperationAgentIDs.remove(agent.id)
                openClawGatewayOperationStatuses[agent.id] = nil
            }
            do {
                let link = try await preparedOpenClawGatewayLink(
                    for: agent,
                    status: .connecting
                )
                let linked = try await dashboardStore.linkOpenClawGateway(link)
                if linked.connectionStatus == .ready {
                    try await dashboardStore.syncOpenClawCron(agentID: agent.id)
                }
                await refreshOpenClawGateways()
                await loadOpenClawCronSnapshot()
                openClawGatewayNotices[agent.id] = "Gateway connected and healthy."
            } catch {
                openClawGatewayErrors[agent.id] = error.localizedDescription
                await refreshOpenClawGateways()
            }
        }
    }

    func confirmPendingOpenClawGatewayLink() {
        guard let agentID = pendingOpenClawGatewayAgentID else { return }
        pendingOpenClawGatewayAgentID = nil
        guard let agent = openClawAgent(agentID: agentID) else { return }
        linkOpenClawGateway(agent: agent)
    }

    func dismissPendingOpenClawGatewayLink() {
        pendingOpenClawGatewayAgentID = nil
    }

    func unlinkOpenClawGateway(agentID: UUID) {
        guard let dashboardStore else { return }
        openClawGatewayOperationAgentIDs.insert(agentID)
        openClawGatewayOperationStatuses[agentID] = .unlinking
        openClawGatewayErrors[agentID] = nil
        openClawGatewayNotices[agentID] = nil
        Task {
            defer {
                openClawGatewayOperationAgentIDs.remove(agentID)
                openClawGatewayOperationStatuses[agentID] = nil
            }
            do {
                try await dashboardStore.unlinkOpenClawGateway(agentID: agentID)
                await refreshOpenClawGateways()
                openClawGatewayNotices[agentID] = "Gateway unlinked from this Mac."
            } catch {
                openClawGatewayErrors[agentID] = error.localizedDescription
            }
        }
    }

    func reconnectOpenClawGateway(agentID: UUID) {
        guard let existing = openClawGatewayLink(agentID: agentID),
              let agent = openClawAgent(agentID: agentID),
              let dashboardStore else { return }
        openClawGatewayOperationAgentIDs.insert(agentID)
        openClawGatewayOperationStatuses[agentID] = .reconnecting
        openClawGatewayErrors[agentID] = nil
        openClawGatewayNotices[agentID] = nil
        Task {
            defer {
                openClawGatewayOperationAgentIDs.remove(agentID)
                openClawGatewayOperationStatuses[agentID] = nil
            }
            do {
                _ = try await dashboardStore.markOpenClawGateway(
                    agentID: agentID,
                    status: .reconnecting
                )
                await refreshOpenClawGateways()
                let link = try await preparedOpenClawGatewayLink(
                    for: agent,
                    existing: existing,
                    status: .reconnecting
                )
                _ = try await dashboardStore.linkOpenClawGateway(link)
                await refreshOpenClawGateways()
                openClawGatewayNotices[agentID] = "Gateway reconnected and healthy."
            } catch {
                openClawGatewayErrors[agentID] = error.localizedDescription
                _ = try? await dashboardStore.markOpenClawGateway(
                    agentID: agentID,
                    status: .unavailable
                )
                await refreshOpenClawGateways()
            }
        }
    }

    func restartOpenClawGateway(agentID: UUID) {
        guard let existing = openClawGatewayLink(agentID: agentID),
              let agent = openClawAgent(agentID: agentID),
              let dashboardStore else { return }
        openClawGatewayOperationAgentIDs.insert(agentID)
        openClawGatewayOperationStatuses[agentID] = .restarting
        openClawGatewayErrors[agentID] = nil
        openClawGatewayNotices[agentID] = nil
        Task {
            defer {
                openClawGatewayOperationAgentIDs.remove(agentID)
                openClawGatewayOperationStatuses[agentID] = nil
            }
            do {
                if existing.location == .localAgentWorkspace || existing.location == .buzzLocal {
                    let prepared = try await preparedOpenClawGatewayLink(
                        for: agent,
                        existing: existing,
                        status: .reconnecting
                    )
                    _ = try await dashboardStore.linkOpenClawGateway(prepared)
                }
                _ = try await dashboardStore.restartOpenClawGateway(agentID: agentID)
                await refreshOpenClawGateways()
                openClawGatewayNotices[agentID] = "Gateway restarted, reconnected, and passed health checks."
            } catch {
                openClawGatewayErrors[agentID] = error.localizedDescription
                _ = try? await dashboardStore.markOpenClawGateway(
                    agentID: agentID,
                    status: .unavailable
                )
                await refreshOpenClawGateways()
            }
        }
    }

    func refreshOpenClawGatewayStatus(agentID: UUID) async {
        guard openClawGatewayLink(agentID: agentID) != nil,
              !openClawGatewayOperationAgentIDs.contains(agentID),
              let dashboardStore else { return }
        do {
            _ = try await dashboardStore.refreshOpenClawGatewayStatus(agentID: agentID)
            openClawGatewayErrors[agentID] = nil
        } catch {
            openClawGatewayErrors[agentID] = error.localizedDescription
        }
        await refreshOpenClawGateways()
    }

    func loadOpenClawHeartbeat(agentID: UUID) async {
        guard let dashboardStore else { return }
        do {
            openClawHeartbeatConfigurations[agentID] = try await dashboardStore
                .openClawHeartbeatConfiguration(agentID: agentID)
            openClawHeartbeatMessages[agentID] = nil
            openClawHeartbeatErrorAgentIDs.remove(agentID)
        } catch {
            openClawHeartbeatMessages[agentID] = error.localizedDescription
            openClawHeartbeatErrorAgentIDs.insert(agentID)
        }
    }

    func saveOpenClawHeartbeat(
        agentID: UUID,
        configuration: OpenClawHeartbeatConfiguration
    ) {
        guard let dashboardStore else { return }
        openClawHeartbeatSavingAgentIDs.insert(agentID)
        openClawHeartbeatMessages[agentID] = nil
        Task {
            defer { openClawHeartbeatSavingAgentIDs.remove(agentID) }
            do {
                openClawHeartbeatConfigurations[agentID] = try await dashboardStore
                    .updateOpenClawHeartbeat(
                        agentID: agentID,
                        configuration: configuration
                    )
                openClawHeartbeatMessages[agentID] = "Heartbeat saved and confirmed by OpenClaw."
                openClawHeartbeatErrorAgentIDs.remove(agentID)
            } catch {
                openClawHeartbeatMessages[agentID] = error.localizedDescription
                openClawHeartbeatErrorAgentIDs.insert(agentID)
            }
        }
    }

    func openClawAgent(agentID: UUID) -> WorkspaceAgent? {
        (localCLIAgents + remoteWorkspaceAgents + buzzWorkspaceAgents)
            .first { $0.id == agentID }
    }

    private func preparedOpenClawGatewayLink(
        for agent: WorkspaceAgent,
        existing: OpenClawGatewayLink? = nil,
        status: OpenClawGatewayConnectionStatus
    ) async throws -> OpenClawGatewayLink {
        guard let dashboardStore else {
            throw ApplicationModelError.dashboardStoreUnavailable
        }
        let location: OpenClawGatewayLocation
        let endpoint: OpenClawGatewayEndpoint
        if agent.governingPlane == .remoteWorkspace {
            location = .remoteWorkspace
            guard let remoteWorkspaceID = agent.runtimeDeviceID,
                  let configuration = remoteWorkspaces.configuration(
                    id: remoteWorkspaceID
                  ) else {
                throw ApplicationModelError.remoteHarnessUnavailable
            }
            let connection = try await remoteWorkspaces.prepareOpenClawGateway(
                for: configuration
            )
            await dashboardStore.configureOpenClawGatewayTransport(
                agentID: agent.id,
                endpoint: connection.endpoint,
                requestHeaders: connection.requestHeaders
            )
            endpoint = connection.endpoint
        } else if let enrollment = buzzWorkspaceSnapshot.enrollments
            .first(where: { $0.id == agent.id }) {
            location = .buzzLocal
            endpoint = try await dashboardStore.prepareBuzzLocalOpenClawGateway(
                enrollmentID: enrollment.id,
                workspaceLinkID: enrollment.workspaceLinkID,
                remoteAgentID: enrollment.agentID
            )
        } else {
            location = .localAgentWorkspace
            guard let workspace = localACPWorkspaceLaunchConfiguration else {
                throw ApplicationModelError.localACPRuntimeUnavailable
            }
            endpoint = try await dashboardStore.prepareLocalWorkspaceOpenClawGateway(
                agentID: agent.id,
                workingDirectory: workspace.rootURL
            )
        }
        return OpenClawGatewayLink(
            agentID: agent.id,
            location: location,
            endpoint: endpoint,
            status: status.rawValue,
            openClawVersion: existing?.openClawVersion,
            lastConnectedAt: existing?.lastConnectedAt,
            lastError: nil,
            linkedAt: existing?.linkedAt ?? Date(),
            updatedAt: Date()
        )
    }

    func cancelOpenClawGatewayPrompt(conversationID: String) {
        let permissionIDs = pendingLocalACPPermissions
            .filter { $0.conversationID == conversationID }
            .map(\.id)
        for permissionID in permissionIDs {
            resolveLocalACPPermission(id: permissionID, optionID: nil)
        }
        Task {
            guard let dashboardStore else { return }
            do {
                try await dashboardStore.cancelOpenClawGatewayPrompt(
                    conversationID: conversationID
                )
                ensureConversationState(id: conversationID).setError(nil)
            } catch {
                await refreshConversation(id: conversationID)
                ensureConversationState(id: conversationID).setError(
                    "Unable to stop OpenClaw Gateway run: \(error.localizedDescription)"
                )
            }
        }
    }

    func patchOpenClawGatewaySession(
        conversationID: String,
        model: String?,
        thinkingLevel: String?
    ) {
        guard let dashboardStore else { return }
        Task {
            do {
                _ = try await dashboardStore
                    .patchOpenClawGatewaySession(
                        conversationID: conversationID,
                        preferences: OpenClawSessionPreferences(
                            model: model,
                            thinkingLevel: thinkingLevel
                        )
                    )
                openClawGatewaySessionMetadata[conversationID] = try await dashboardStore
                    .openClawGatewaySessionMetadata(conversationID: conversationID)
                ensureConversationState(id: conversationID).setError(nil)
            } catch {
                ensureConversationState(id: conversationID).setError(
                    error.localizedDescription
                )
            }
        }
    }

    func refreshOpenClawGatewaySession(conversationID: String) async {
        guard let dashboardStore else { return }
        do {
            _ = try await dashboardStore.synchronizeOpenClawSession(conversationID: conversationID)
            openClawGatewaySessionMetadata[conversationID] = try await dashboardStore
                .openClawGatewaySessionMetadata(conversationID: conversationID)
            ensureConversationState(id: conversationID).setError(nil)
        } catch {
            ensureConversationState(id: conversationID).setError(
                error.localizedDescription
            )
        }
    }

    func refreshOpenClawGateways() async {
        do {
            guard let dashboardStore else { return }
            openClawGatewayLinks = try await dashboardStore.openClawGatewayLinks()
            openClawGatewayConversationIDs = try await dashboardStore
                .openClawGatewayConversationIDs()
        } catch {
            for link in openClawGatewayLinks {
                openClawGatewayErrors[link.agentID] = error.localizedDescription
            }
        }
    }

    func openClawNativeSessions(agentID: UUID, offset: Int = 0) async throws -> (sessions: [OpenClawGatewaySession], nextOffset: Int?) {
        guard let dashboardStore else { throw OpenClawGatewayClientError.connectionClosed }
        return try await dashboardStore.openClawNativeSessions(agentID: agentID, offset: offset)
    }

    func importOpenClawSession(agentID: UUID, session: OpenClawGatewaySession) async throws {
        guard let dashboardStore else { throw OpenClawGatewayClientError.connectionClosed }
        _ = try await dashboardStore.importOpenClawSession(agentID: agentID, session: session)
        await refreshOpenClawGateways()
        await refreshWorkspace()
    }

    func restoreOpenClawGatewayLinks() async {
        guard let dashboardStore else { return }
        for persisted in openClawGatewayLinks {
            do {
                var link = persisted
                switch persisted.location {
                case .buzzLocal:
                    guard let enrollment = buzzWorkspaceSnapshot.enrollments.first(where: {
                        $0.id == persisted.agentID
                    }) else { throw BuzzWorkspaceDatabaseError.enrollmentNotFound }
                    link.endpoint = try await dashboardStore.prepareBuzzLocalOpenClawGateway(
                        enrollmentID: enrollment.id,
                        workspaceLinkID: enrollment.workspaceLinkID,
                        remoteAgentID: enrollment.agentID
                    )
                case .localAgentWorkspace:
                    guard let workspace = localACPWorkspaceLaunchConfiguration else {
                        throw ApplicationModelError.localACPRuntimeUnavailable
                    }
                    link.endpoint = try await dashboardStore.prepareLocalWorkspaceOpenClawGateway(
                        agentID: persisted.agentID,
                        workingDirectory: workspace.rootURL
                    )
                case .remoteWorkspace:
                    // Remote workspace tokens are intentionally not read during
                    // app startup. The user can reconnect this gateway from its
                    // workspace controls when they want Keychain access.
                    continue
                }
                _ = try await dashboardStore.linkOpenClawGateway(link)
            } catch {
                openClawGatewayErrors[persisted.agentID] = error.localizedDescription
            }
        }
        await refreshOpenClawGateways()
    }

    func refreshOpenClawCron() async {
        guard !isRefreshingOpenClawCron, let dashboardStore else { return }
        isRefreshingOpenClawCron = true
        lastOpenClawCronRefresh = Date()
        defer { isRefreshingOpenClawCron = false }
        var failures: [String] = []
        for link in openClawGatewayLinks {
            do {
                try await dashboardStore.syncOpenClawCron(agentID: link.agentID)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        await loadOpenClawCronSnapshot()
        openClawCronError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func saveOpenClawCron(agentID: UUID, job: OpenClawCronJob?, name: String, message: String,
                          expression: String, timeZone: String, declarationKey: String,
                          destination: String, preserveSchedule: Bool = false) async -> String? {
        guard let dashboardStore, !openClawCronBusy else { return "Another job change is in progress." }
        openClawCronBusy = true
        defer { openClawCronBusy = false }
        do {
            if let job {
                var patch: [String: GatewayJSONValue] = ["name": .string(name),
                    "schedule": .object(["kind": .string("cron"), "expr": .string(expression), "tz": .string(timeZone)])]
                if preserveSchedule { patch.removeValue(forKey: "schedule") }
                if !message.isEmpty { patch["payload"] = .object(["message": .string(message)]) }
                try await dashboardStore.updateOpenClawCron(job: job, patch: .object(patch))
                try await dashboardStore.setOpenClawResultRoute(agentID: agentID, jobID: job.id, destination: destination)
            } else {
                try await dashboardStore.createOpenClawCron(agentID: agentID, name: name, message: message,
                    expression: expression, timeZone: timeZone, declarationKey: declarationKey, destination: destination)
            }
            await refreshOpenClawCron()
            return nil
        } catch {
            return error.localizedDescription + " Refresh the job list before retrying; the Gateway may have accepted the change."
        }
    }

    func performOpenClawCronAction(job: OpenClawCronJob, action: String) {
        guard let dashboardStore, !openClawCronBusy else { return }
        openClawCronBusy = true
        Task {
            defer { openClawCronBusy = false }
            do {
                if action == "toggle" {
                    try await dashboardStore.updateOpenClawCron(job: job, patch: .object(["enabled": .bool(!job.enabled)]))
                } else {
                    try await dashboardStore.performOpenClawCronAction(job: job, action: action)
                }
                await refreshOpenClawCron()
            } catch {
                openClawCronError = error.localizedDescription + " Refresh before retrying; this action was not automatically retried."
            }
        }
    }

    func setOpenClawResultRoute(job: OpenClawCronJob, destination: String) {
        guard let dashboardStore else { return }
        Task {
            do {
                try await dashboardStore.setOpenClawResultRoute(agentID: job.agentID, jobID: job.id, destination: destination)
                await loadOpenClawCronSnapshot()
                await refreshOpenClawCron()
                await refreshWorkspace()
            } catch { openClawCronError = error.localizedDescription }
        }
    }

    func emptyOpenClawCronTrash() {
        guard let dashboardStore else { return }
        Task {
            do {
                try await dashboardStore.emptyOpenClawCronTrash()
                await loadOpenClawCronSnapshot()
            } catch {
                openClawCronError = error.localizedDescription
            }
        }
    }

    func createOpenClawContextConversation(
        agentID: UUID,
        context: String? = nil
    ) async -> String? {
        let conversationID: String?
        if let enrollment = buzzWorkspaceSnapshot.enrollments.first(where: {
            $0.id == agentID
        }) {
            conversationID = await createBuzzWorkspaceLocalACPSession(
                enrollment: enrollment
            )
        } else if localCLIAgents.contains(where: {
            $0.id == agentID && $0.runtimeKind == .openclaw
        }) {
            conversationID = await createLocalACPSession(runtimeKind: .openclaw)
        } else {
            localRunError = "The selected OpenClaw is no longer available."
            return nil
        }
        guard let conversationID else { return nil }
        if let context,
           let conversation = workspaceOverview?.conversations.first(where: {
               $0.id == conversationID
           }) {
            _ = await sendAgentMessage(
                conversation: conversation,
                content: context
            )
        }
        return conversationID
    }

    private func loadOpenClawCronSnapshot() async {
        guard let dashboardStore else { return }
        do {
            openClawCronJobs = try await dashboardStore.openClawCronJobs()
            openClawCronRuns = try await dashboardStore.openClawCronRuns()
            for link in openClawGatewayLinks {
                openClawResultRoutes[link.agentID] = try await dashboardStore.openClawResultRoutes(agentID: link.agentID)
            }
        } catch {
            openClawCronError = error.localizedDescription
        }
    }

    static func openClawSessionKey(conversationID: String) -> String {
        "agent:main:wovenmatter:\(conversationID)"
    }

    static func expandedLocalFileURL(_ rawPath: String) -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded: String
        if trimmed == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if trimmed.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: String(trimmed.dropFirst(2)))
                .path
        } else {
            expanded = trimmed
        }
        return URL(filePath: expanded).standardizedFileURL
    }
}
