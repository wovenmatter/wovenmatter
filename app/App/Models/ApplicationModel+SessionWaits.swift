import Foundation
import WovenMatterCore
import WovenMatterClient
import WovenMatterLibraryStore

/// `woven_sessions_wait` and wake-ups on this Mac (docs/architecture/WOVEN_EVERYWHERE.md,
/// "Streaming", "Agent to agent"; `SessionWakeUp` in shared/), with the same
/// behaviour as the Linux server. `SessionWakeUps` keeps the state; this
/// connects it to `MemberExecutionClient`'s streams, this Mac's own changes,
/// and the delivery path timers and coordination notifications use.
extension ApplicationModel {
    /// The key this Mac's own sessions use in `SessionWakeUps`.
    nonisolated static let sessionWaitThisMac = "this-mac"

    /// The coordinator, created (and its stored state loaded) on first use.
    func sessionWakeUps() async -> SessionWakeUps? {
        guard !isBackendFrontend, let agentTools, let database = libraryStore?.database else { return nil }
        if let existing = agentTools.sessionWakeUps { return existing }
        let coordinator = SessionWakeUps(database: database, hooks: .init(
            caller: { [weak self] id in await self?.sessionWakeUpCaller(id) ?? .gone },
            deliverToConversation: { [weak self] delivery in await self?.deliverSessionWakeUp(delivery) ?? false },
            deliverToBot: { [weak self] delivery in
                guard let self else { throw CancellationError() }
                try await self.deliverBotWakeUp(delivery)
            },
            reconcile: { [weak self] workspaceID in await self?.sessionWakeUpReconcile(workspaceID) },
            log: { NSLog("%@", $0) }))
        agentTools.sessionWakeUps = coordinator
        // Destinations' `workspace` streams, filtered there to watched sessions and waits.
        if let client = try? memberExecutionClient() {
            client.onWorkspaceItem = { [weak coordinator] workspaceID, payload in
                await coordinator?.remoteItem(workspaceID: workspaceID, payload)
            }
        }
        // This Mac's own sessions: every commit to its change tail.
        database.observeExecutionStreamChanges { [weak self] _ in
            Task { @MainActor in await self?.sessionWakeUpsLocalChanged([]) }
        }
        await coordinator.start()
        return coordinator
    }

    /// This Mac's own sessions changed (stored rows, or in-memory questions,
    /// approvals and run state): waits on them read their state again.
    func sessionWakeUpsLocalChanged(_ conversationIDs: Set<String>) async {
        guard let coordinator = agentTools?.sessionWakeUps, coordinator.isTracking(workspaceID: Self.sessionWaitThisMac) else { return }
        await coordinator.localChanged(workspaceID: Self.sessionWaitThisMac, conversationIDs: conversationIDs) { [weak self] id in
            await self?.localSessionSnapshot(id)
        }
    }

    /// One of this Mac's sessions, in `woven_sessions_status`'s terms.
    func localSessionSnapshot(_ id: String) async -> SessionWakeUps.Snapshot? {
        guard let database = libraryStore?.database else { return nil }
        let run = try? await database.activeRunID(conversationID: id)
        let pending = await libraryCommands.pendingInteractions().filter { $0.conversationID.lowercased() == id.lowercased() }
        // The stored run is what changes commit; it is the state, as on another workspace.
        return .init(state: SessionWakeUps.state(activeRunID: run, pending: pending), runID: run, pending: pending)
    }

    private func sessionWakeUpCaller(_ id: String) async -> SessionWakeUps.Caller {
        if WovenMCPCaller.parseBot(id) != nil { return .bot }
        guard let database = libraryStore?.database, (try? await database.sessionWakeUpCallerExists(id)) == true else { return .gone }
        let activeRun = try? await database.activeRunID(conversationID: id)
        let idle = !runningToolSessionIDs.contains(id) && activeRun == nil
        guard idle else { return .conversation(idle: false, wokenRunsInARow: 0) }
        return .conversation(idle: true, wokenRunsInARow: (try? await database.wakeUpRunsInARow(conversationID: id)) ?? 0)
    }

    /// Sends the wake-up into the idle caller like a coordination notification,
    /// never steering a running turn. False when it was not accepted.
    private func deliverSessionWakeUp(_ wakeUp: SessionWakeUps.Delivery) async -> Bool {
        guard let database = libraryStore?.database else { return false }
        do {
            let delivery = try await database.reserveSessionWakeUpDelivery(id: wakeUp.id, callerID: wakeUp.callerID, sessionID: wakeUp.sessionID,
                title: wakeUp.title, harness: wakeUp.harness, text: wakeUp.text, key: wakeUp.key)
            // An attempt that already went out (before a restart) is not sent again.
            if delivery.status == "accepted" { return true }
            guard delivery.status == "queued" else { return false }
            let response = try await dispatchToolDelivery(delivery, allowSteering: false)
            let final = try await database.toolDelivery(id: delivery.id)
            if final?.status == "queued" {
                // Not taken now: a later attempt gets its own delivery, so this one never goes out late.
                try? await database.setToolDeliveryStatus(id: delivery.id, status: "cancelled", failureCode: "caller_running",
                    failureReason: "The calling session was running.")
            }
            return response.success && final?.status == "accepted"
        } catch {
            NSLog("A wake-up could not be delivered: %@", error.localizedDescription)
            return false
        }
    }

    /// A bot's wake-up reaches its runtime the way its notifications do.
    private func deliverBotWakeUp(_ wakeUp: SessionWakeUps.Delivery) async throws {
        guard let database = libraryStore?.database, let agentTools else { throw ApplicationModelError.libraryStoreUnavailable }
        let delivery = try await database.reserveSessionWakeUpDelivery(id: wakeUp.id, callerID: wakeUp.callerID, sessionID: wakeUp.sessionID,
            title: wakeUp.title, harness: wakeUp.harness, text: wakeUp.text, key: wakeUp.key)
        if delivery.status == "accepted" { return }
        _ = try await agentTools.deliverBotNotification(delivery)
        guard try await database.toolDelivery(id: delivery.id)?.status == "accepted" else {
            throw WorkspaceToolError.invalid("The bots runtime did not take the wake-up.")
        }
    }

    /// After a restart: what a watched workspace runs now, read once, and its stream opened.
    private func sessionWakeUpReconcile(_ workspaceID: String) async -> (conversations: [LibraryConversation], pending: [PendingInteraction])? {
        guard let (_, others) = try? await agentToolWorkspaces(), let workspace = others.first(where: { $0.id == workspaceID }),
              workspace.endpoint != nil, let client = try? memberExecutionClient() else { return nil }
        await client.openStream(workspace)
        guard let conversations = try? await client.conversations(workspace: workspace) else { return nil }
        return (conversations, (try? await client.pendingInteractions(workspace: workspace)) ?? [])
    }

    /// Records what a call on a member session showed about its state.
    func observeMemberSession(callerID: String, workspace: ExecutionWorkspace, id: String, state: String,
                              response: WovenMatterToolResponse? = nil, created: Bool = false) async {
        guard let coordinator = await sessionWakeUps() else { return }
        let result = response?.result?.objectValue
        let session = result?["session"]?.objectValue, receipt = result?["receipt"]?.objectValue
        await coordinator.observe(callerID: callerID, workspaceID: workspace.id, workspaceName: workspace.name, id: id,
            title: session?["title"]?.stringValue, harness: session?["harness"]?.stringValue, state: state,
            runID: receipt?["runID"]?.stringValue ?? session?["runID"]?.stringValue,
            pendingIDs: result?["pending"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue } ?? [], created: created)
    }

    /// `woven_sessions_wait`: a session on another member's workspace resolves
    /// from that workspace's stream, one on this Mac from its own changes.
    func memberSessionWait(callerID: String, command: WovenMatterToolCommand, readsAll: Bool) async throws -> WovenMatterToolResponse {
        guard let database = libraryStore?.database, let coordinator = await sessionWakeUps() else {
            throw ApplicationModelError.libraryStoreUnavailable
        }
        let id = try command.required("id", allowPositional: true).lowercased()
        let until = try command.required("until")
        let seconds = try command.integer("timeout-seconds", default: StreamProtocol.maximumWaitSeconds, range: 1...StreamProtocol.maximumWaitSeconds)
        if let workspace = try await memberSessionWorkspace(id: id, named: command.options["workspace"]) {
            let creator = try await database.memberToolSession(id: id)?.callerID
            guard readsAll || creator == callerID else {
                throw WorkspaceToolError.invalid("Read only the sessions you created, or enable Conversation history.")
            }
            let client = try memberExecutionClient()
            await client.openStream(workspace)
            let result = try await coordinator.wait(callerID: callerID, workspaceID: workspace.id, id: id, until: until, timeout: .seconds(seconds)) {
                let response = try await self.memberSessionStatus(client: client, workspace: workspace, id: id, before: nil)
                let state = response.result?.objectValue?["session"]?.objectValue?["state"]?.stringValue ?? "idle"
                await self.observeMemberSession(callerID: callerID, workspace: workspace, id: id, state: state, response: response)
                return (response.result ?? .null, state)
            }
            return .init(result: result)
        }
        // This Mac's own session: the same body as its woven_sessions_status.
        let status = WovenMatterToolRequest(arguments: ["sessions", "status", "--id", id], requestID: UUID().uuidString.lowercased())
        let executor = WorkspaceToolExecutor(database: database)
        let result = try await coordinator.wait(callerID: callerID, workspaceID: Self.sessionWaitThisMac, id: id, until: until, timeout: .seconds(seconds)) {
            let response = await executor.execute(status, callerID: callerID, handlers: .init())
            guard response.success else { throw WorkspaceToolError.invalid(response.error ?? "The session's status could not be read.") }
            return (response.result ?? .null, await self.localSessionSnapshot(id)?.state ?? "idle")
        }
        return .init(result: result)
    }
}
