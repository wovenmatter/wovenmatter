import Foundation
import WovenMatterCore
import LibraryClient
import WovenMatterDashboardStore

enum FederatedExecutionAction: Codable, Sendable {
    case refresh(conversationID: String)
    case respond(PendingInteraction, InteractionResponse)
    case stop(conversationID: String, runID: String)
    case configure(conversationID: String, action: LibraryWorkspaceAction)
    case earlier(conversationID: String, before: String)
    /// The chat closed: a streamed workspace ends its `conversation` subscription.
    case close(conversationID: String)
}
struct FederatedExecutionSnapshot: Codable, Sendable {
    var workspace: ExecutionWorkspace
    var transcript: LibraryTranscript?
    var capability: HarnessCapabilities?
    var interactions: [PendingInteraction]
    var session: SessionSettings?
    var online: Bool
    var error: String?
    /// The workspace pushes every change on its stream: nothing polls it.
    var streamed: Bool? = nil
}

extension ApplicationModel {
    func sharedLibraryFileURL(id: String) async throws -> URL {
        if let client = liveLibraryClient { return try await client.exportFile(.libraryFile(id: id)) }
        if DevelopmentLaunch.isClient, isBackendFrontend {
            let bytes = try await callBackend(method: "library.command", payload: JSONEncoder().encode(BackendLibraryCommand.openShared(id: id)))
            guard let url = try JSONDecoder().decode(BackendLibraryResult.self, from: bytes).url else {
                throw WorkspaceToolError.invalid("The shared file is unavailable.")
            }
            return url
        }
        return try await library.fileURL(id: id)
    }

    /// Signed execution between members. In a Dev snapshot it reaches only the
    /// workspaces the snapshot itself knows live (its own, paired members',
    /// Linux hosts it added): `CentralExecutionClient` refuses every copied
    /// owner (`retainedHistory`), whose chats stay read-only history.
    func centralExecutionClient() throws -> CentralExecutionClient {
        guard !isBackendFrontend, let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        if let federatedExecutionClient { return federatedExecutionClient }
        // The command journal lives beside the library it addresses, never in a
        // global directory a fixture or another instance could share.
        let directory = dashboardStore.database.supportDirectory
        let storage = libraryHost.peerStorage
        let client = try CentralExecutionClient(database: dashboardStore.database,
            commandJournalURL: directory.appending(path: "central-execution-commands.json"),
            provision: { [weak self] id in
                guard let self else { throw CancellationError() }
                return try await self.libraryHost.provisionCentralExecutionWorkspace(id: id)
            }, loadCredential: storage.loadExecutionCredential, saveCredential: storage.saveExecutionCredential,
            makeSignedTransport: { [weak self] workspace in
                // The iPhone is never an execution destination for signed calls.
                // A workspace whose serving member is unknown cannot be addressed; its saved grant (if any) still works.
                guard let self, workspace.kind != .ios, let directory = try? await self.libraryHost.peerSync.members(),
                      let audience = await directory.audience(for: workspace) else { return nil }
                return try SignedExecutionWorkspaceTransport(workspace: workspace, signer: directory.identity.signer, audience: audience)
            },
            makeStream: { [weak self] workspace in
                // The live stream lives where the member key, the command journal
                // and the history cache are: this process, never a frontend window.
                guard let self, workspace.kind != .ios, let endpoint = workspace.endpoint,
                      let directory = try? await self.libraryHost.peerSync.members(),
                      let audience = await directory.audience(for: workspace) else { return nil }
                return try WebSocketStreamTransport.connector(endpoint: endpoint, signer: directory.identity.signer, audience: audience, headers: [
                    "X-Woven-Protocol": String(LibraryProtocol.version), "X-Woven-Library": workspace.libraryID,
                    "X-Woven-Workspace": workspace.id, "X-Woven-Device": directory.identity.deviceID
                ])
            },
            memberRevision: { [weak self] in try? await self?.libraryHost.peerSync.members().list().revision },
            onChange: { [weak self] in await self?.refreshWorkspace() })
        client.onLive = { [weak self] ids in self?.federatedLiveChanged(ids) }
        federatedExecutionClient = client
        return client
    }

    func refreshFederatedConversation(_ id: String, reloadingConversation: Bool = true) async {
        do {
            let snapshot: FederatedExecutionSnapshot?
            if isBackendFrontend { snapshot = try await sendBackendCommand(.federatedExecution(.refresh(conversationID: id))).federatedExecution }
            else { snapshot = try await performFederatedExecution(.refresh(conversationID: id)) }
            if let snapshot { federatedExecutionSnapshots[id] = snapshot }
            if reloadingConversation { await refreshConversation(id: id) }
        } catch { ensureConversationState(id: id).setError(error.localizedDescription) }
    }

    /// A stream pushed live state for these chats. A background server tells
    /// its windows; a window showing one of them reads the new snapshot.
    func federatedLiveChanged(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        if let service = backendApplicationService {
            Task { await service.invalidations.publish(scopes: [.execution], conversationIDs: ids) }
        }
        // A headless background server shows nothing itself.
        guard LocalExecutionRole.current != .backend else { return }
        for id in ids where federatedExecutionSnapshots[id] != nil { refreshLiveFederatedConversation(id) }
    }

    /// One snapshot read at a time per chat; pushes that arrive meanwhile are
    /// folded into one more read.
    func refreshLiveFederatedConversation(_ id: String) {
        if federatedLiveRefreshes[id] != nil { federatedLiveRefreshes[id] = true; return }
        federatedLiveRefreshes[id] = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.federatedLiveRefreshes[id] = false
                await self.refreshFederatedConversation(id, reloadingConversation: false)
            } while self.federatedLiveRefreshes[id] == true
            self.federatedLiveRefreshes[id] = nil
        }
    }

    /// The chat closed: its live subscription ends (streamed workspaces only).
    func closeFederatedConversation(_ id: String) {
        guard federatedExecutionSnapshots[id]?.streamed == true else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.isBackendFrontend { _ = try? await self.sendBackendCommand(.federatedExecution(.close(conversationID: id))) }
            else { _ = try? await self.performFederatedExecution(.close(conversationID: id)) }
        }
    }

    @discardableResult
    func actOnFederatedConversation(_ action: FederatedExecutionAction, conversationID: String) async -> FederatedExecutionSnapshot? {
        do {
            let snapshot: FederatedExecutionSnapshot?
            if isBackendFrontend { snapshot = try await sendBackendCommand(.federatedExecution(action)).federatedExecution }
            else { snapshot = try await performFederatedExecution(action) }
            if let snapshot { federatedExecutionSnapshots[conversationID] = snapshot }
            ensureConversationState(id: conversationID).setError(nil)
            return snapshot
        } catch { ensureConversationState(id: conversationID).setError(error.localizedDescription) }
        return nil
    }

    static let quickChatReadOnlyMessage = "Quick Chat runs only on its iPhone or iPad. Synced history is read-only here."

    func performFederatedExecution(_ action: FederatedExecutionAction) async throws -> FederatedExecutionSnapshot {
        if let client = liveLibraryClient { return try await client.desktopExecution(action) }
        let client = try centralExecutionClient()
        let targetID: String
        switch action {
        case .refresh(let id), .earlier(let id, _), .close(let id): targetID = id
        case .stop(let id, _), .configure(let id, _): targetID = id
        case .respond(let interaction, _): targetID = interaction.conversationID
        }
        if case .close(let id) = action {
            await client.unwatch(id)
            guard let workspace = try await client.workspace(conversationID: id) else {
                throw LibraryAPIError(code: "unknown_workspace", message: "This conversation has no execution workspace.")
            }
            return federatedSnapshot(id, workspace: workspace, client: client, transcript: client.transcripts[id], session: nil)
        }
        // A snapshot's copied conversation has no live owner here: read its saved history.
        if readsCopiedHistoryOnly, try await client.workspace(conversationID: targetID).map({ $0.retainedHistory == true }) ?? true {
            return try await savedDevelopmentExecution(action)
        }
        // Quick Chat runs only on the iPhone or iPad that owns it; other devices read its synced history.
        if try await client.workspace(conversationID: targetID)?.kind == .ios {
            switch action {
            case .refresh, .earlier: break
            default: throw WorkspaceToolError.invalid(Self.quickChatReadOnlyMessage)
            }
        }
        let id: String
        var earlier: LibraryTranscript?
        switch action {
        case .refresh(let conversationID): id = conversationID
        case .stop(let conversationID, let runID): id = conversationID; try await cancelCanonicalRun(conversationID: id, runID: runID)
        case .respond(let interaction, let response): id = interaction.conversationID; _ = try await client.respond(interaction, response: response)
        case .configure(let conversationID, let command): id = conversationID; _ = try await client.perform(conversationID: id, action: command)
        case .earlier(let conversationID, let before): id = conversationID; earlier = try await client.earlierTranscript(conversationID: id, before: before)
        case .close(let conversationID): id = conversationID
        }
        guard let workspace = try await client.workspace(conversationID: id) else { throw LibraryAPIError(code: "unknown_workspace", message: "This conversation has no execution workspace.") }
        try? await client.refresh(conversationID: id)
        var refreshing = false
        if case .refresh = action { refreshing = true }
        let session = await client.sessionSettings(conversationID: id, workspace: workspace, force: !refreshing)
        let snapshot = federatedSnapshot(id, workspace: workspace, client: client, transcript: earlier ?? client.transcripts[id], session: session)
        federatedExecutionSnapshots[id] = snapshot
        return snapshot
    }

    private func federatedSnapshot(_ id: String, workspace: ExecutionWorkspace, client: CentralExecutionClient,
                                   transcript: LibraryTranscript?, session: SessionSettings?) -> FederatedExecutionSnapshot {
        FederatedExecutionSnapshot(workspace: workspace, transcript: transcript,
            capability: client.capabilities[id], interactions: client.pending[workspace.id]?.filter { $0.conversationID == id } ?? [],
            session: session, online: client.onlineWorkspaces.contains(workspace.id), error: client.errors[workspace.id],
            streamed: client.isStreamed(workspace.id))
    }

    /// A snapshot's copied history has no connection or credential to its former owner.
    func savedDevelopmentExecution(_ action: FederatedExecutionAction) async throws -> FederatedExecutionSnapshot {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let id: String
        let before: String?
        switch action {
        case .refresh(let value): id = value; before = nil
        case .earlier(let value, let cursor): id = value; before = cursor
        default: throw WorkspaceToolError.invalid("Snapshot history is disconnected. Start a new session to test execution.")
        }
        var transcript = try await database.libraryFederatedTranscript(conversationID: id, before: before)
        transcript?.activeRunID = nil
        return .init(workspace: .init(id: "snapshot-history", libraryID: try await database.libraryID(),
            ownerDeviceID: "snapshot-history", kind: .mac, name: "Snapshot history"),
            transcript: transcript, capability: nil, interactions: [], session: nil, online: false, error: nil)
    }

    /// Transfer existing idle native sessions once their workspace participates in
    /// federation. The database fence precedes enrollment; every retry uses the
    /// immutable adoption request, so a lost acknowledgement never creates a run.
    func adoptRegisteredRemoteConversationIfNeeded(_ conversation: WorkspaceConversationRecord) async throws {
        guard !conversation.isArchived, !isBackendFrontend, !adoptedExecutionConversations.contains(conversation.id),
              let workspaceID = conversation.remoteWorkspaceID,
              let configuration = remoteWorkspaces.configuration(id: workspaceID),
              let store = dashboardStore,
              let native = try? await store.database.localACPSession(conversationID: conversation.id),
              native.acpSessionID != nil else { return }
        let id = workspaceID.uuidString.lowercased()
        guard try await store.database.libraryExecutionWorkspaces().contains(where: { $0.id == id && !$0.deleted }) else { return }
        if let pending = federatedAdoptionTasks[conversation.id] { try await pending.value; return }
        let task = Task { @MainActor in
            let owner = try await store.database.libraryExecutionOwner(conversationID: conversation.id)
            if owner == nil {
                // Leave a currently running legacy session on its current owner.
                // Its next idle refresh will perform the transfer.
                if try await store.database.activeRunID(conversationID: conversation.id) != nil { return }
                _ = try await self.libraryHost.provisionCentralExecutionWorkspace(id: id)
                try await store.detachLocalACPForExecutionAdoption(conversationID: conversation.id)
            }
            let identity = try await store.database.libraryIdentity()
            let adoption = try await store.database.prepareExecutionAdoption(conversationID: conversation.id,
                workspaceID: id, deviceID: identity.hostDeviceID)
            self.federatedExecutionOwners[conversation.id] = id
            _ = try await self.remoteWorkspaces.adoptExecutionConversation(configuration: configuration, adoption: adoption)
            self.adoptedExecutionConversations.insert(conversation.id)
            await self.refreshWorkspace()
        }
        federatedAdoptionTasks[conversation.id] = task
        defer { federatedAdoptionTasks.removeValue(forKey: conversation.id) }
        try await task.value
    }

    /// Called before any native runtime selection or preparation. Imported
    /// execution ownership is looked up live as well as cached for presentation.
    func dispatchFederatedMessage(conversationID: String, input: AgentMessageInput, note: WorkspaceNoteRecord?,
                                  expectedRunID: String?, requiresIdle: Bool, dispatchFence: AgentDispatchFence) async throws -> Bool {
        guard let database = dashboardStore?.database else { return false }
        if let id = input.historyDeliveryID, try await database.toolDelivery(id: id)?.kind == .goal {
            // A primary-owner reservation can never become a foreign-owner send.
            // Adoption cancels this reservation; the new owner resumes its own goal.
            try await database.validateClaimedToolDelivery(id: id)
            guard try await database.libraryExecutionOwner(conversationID: conversationID) == nil else {
                throw WorkspaceToolError.invalid("This goal continuation belongs to the previous execution owner.")
            }
            return false
        }
        if let conversation = try await database.workspaceOverview().conversations.first(where: { $0.id == conversationID }) {
            try await adoptRegisteredRemoteConversationIfNeeded(conversation)
        }
        guard try await database.libraryExecutionOwner(conversationID: conversationID) != nil else { return false }
        if try await database.libraryConversationExecutionWorkspace(conversationID: conversationID)?.kind == .ios {
            throw WorkspaceToolError.invalid(Self.quickChatReadOnlyMessage)
        }
        guard input.files.isEmpty else { throw LibraryAPIError(code: "attachment_unavailable", message: "Save this file to the workspace before referencing it in this remote conversation.") }
        try await waitForAgentStop(conversationID: conversationID)
        try dispatchFence.check()
        let client = try centralExecutionClient()
        try await client.refresh(conversationID: conversationID)
        try dispatchFence.check()
        // The owner's live state can be newer than its central publication.
        let active = client.transcripts[conversationID]?.activeRunID
        if requiresIdle && active != nil { throw LocalACPSessionDatabaseError.runAlreadyActive }
        if let expectedRunID, expectedRunID != active { throw LocalACPSessionDatabaseError.runNotFound }
        var prompt = input.text
        for reference in input.references {
            prompt += "\n\nReferenced content: \(reference.titleSnapshot)\n\(reference.contentSnapshot)"
        }
        if let note, !input.references.contains(where: { $0.resourceID == note.id }) {
            prompt += "\n\nReferenced note: \(note.title)\n\(note.content)"
        }
        _ = try await client.send(conversationID: conversationID, text: prompt, expectedRunID: expectedRunID ?? active,
            beforeDispatch: { try dispatchFence.claimDispatch() })
        return true
    }
}
