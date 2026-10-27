import Foundation
import WovenMatterCore
import CompanionClient
import WovenMatterDashboardStore

enum FederatedExecutionAction: Codable, Sendable {
    case refresh(conversationID: String)
    case respond(CompanionPendingInteraction, CompanionInteractionResponse)
    case stop(conversationID: String, runID: String)
    case configure(conversationID: String, action: CompanionWorkspaceAction)
    case earlier(conversationID: String, before: String)
}
struct FederatedExecutionSnapshot: Codable, Sendable {
    var workspace: CompanionExecutionWorkspace
    var transcript: CompanionTranscript?
    var capability: CompanionProvider?
    var interactions: [CompanionPendingInteraction]
    var session: CompanionSessionSettings?
    var online: Bool
    var error: String?
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

    func centralExecutionClient() throws -> CentralExecutionClient {
        guard !DevelopmentLaunch.isSnapshot else {
            throw WorkspaceToolError.invalid("Snapshot history is disconnected. Start a new session to test execution.")
        }
        guard !isBackendFrontend, let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        if let federatedExecutionClient { return federatedExecutionClient }
        let directory = try CompanionTestWorkspace.supportDirectory ?? Self.dashboardSupportDirectory()
        let client = try CentralExecutionClient(database: dashboardStore.database,
            commandJournalURL: directory.appending(path: "central-execution-commands.json"),
            provision: { [weak self] id in
                guard let self else { throw CancellationError() }
                return try await self.companionHost.provisionCentralExecutionWorkspace(id: id)
            }, onChange: { [weak self] in await self?.refreshWorkspace() })
        federatedExecutionClient = client
        return client
    }

    func refreshFederatedConversation(_ id: String) async {
        do {
            let snapshot: FederatedExecutionSnapshot?
            if isBackendFrontend { snapshot = try await sendBackendCommand(.federatedExecution(.refresh(conversationID: id))).federatedExecution }
            else { snapshot = try await performFederatedExecution(.refresh(conversationID: id)) }
            if let snapshot { federatedExecutionSnapshots[id] = snapshot }
            await refreshConversation(id: id)
        } catch { ensureConversationState(id: id).setError(error.localizedDescription) }
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

    func performFederatedExecution(_ action: FederatedExecutionAction) async throws -> FederatedExecutionSnapshot {
        if let client = liveLibraryClient { return try await client.desktopExecution(action) }
        if DevelopmentLaunch.isSnapshot { return try await savedDevelopmentExecution(action) }
        let client = try centralExecutionClient()
        let id: String
        var earlier: CompanionTranscript?
        switch action {
        case .refresh(let conversationID): id = conversationID
        case .stop(let conversationID, let runID): id = conversationID; try await cancelCanonicalRun(conversationID: id, runID: runID)
        case .respond(let interaction, let response): id = interaction.conversationID; _ = try await client.respond(interaction, response: response)
        case .configure(let conversationID, let command): id = conversationID; _ = try await client.perform(conversationID: id, action: command)
        case .earlier(let conversationID, let before): id = conversationID; earlier = try await client.earlierTranscript(conversationID: id, before: before)
        }
        guard let workspace = try await client.workspace(conversationID: id) else { throw CompanionAPIError(code: "unknown_workspace", message: "This conversation has no execution workspace.") }
        try? await client.refresh(conversationID: id)
        var session: CompanionSessionSettings?
        if client.onlineWorkspaces.contains(workspace.id), case .session(let value) = try? await client.readWorkspace(conversationID: id, request: .session(id: id)) { session = value }
        let snapshot = FederatedExecutionSnapshot(workspace: workspace, transcript: earlier ?? client.transcripts[id],
            capability: client.capabilities[id], interactions: client.pending[workspace.id]?.filter { $0.conversationID == id } ?? [],
            session: session, online: client.onlineWorkspaces.contains(workspace.id), error: client.errors[workspace.id])
        federatedExecutionSnapshots[id] = snapshot
        return snapshot
    }

    /// Snapshot history has no connection or credential to its former owner.
    func savedDevelopmentExecution(_ action: FederatedExecutionAction) async throws -> FederatedExecutionSnapshot {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let id: String
        let before: String?
        switch action {
        case .refresh(let value): id = value; before = nil
        case .earlier(let value, let cursor): id = value; before = cursor
        default: throw WorkspaceToolError.invalid("Snapshot history is disconnected. Start a new session to test execution.")
        }
        var transcript = try await database.companionFederatedTranscript(conversationID: id, before: before)
        transcript?.activeRunID = nil
        return .init(workspace: .init(id: "snapshot-history", libraryID: try await database.companionWorkspaceID(),
            ownerDeviceID: "snapshot-history", kind: .mac, name: "Snapshot history"),
            transcript: transcript, capability: nil, interactions: [], session: nil, online: false, error: nil)
    }

    /// Transfer existing idle native sessions once their workspace participates in
    /// federation. The database fence precedes enrollment; every retry uses the
    /// immutable adoption request, so a lost acknowledgement never creates a run.
    func adoptRegisteredRemoteConversationIfNeeded(_ conversation: WorkspaceConversationRecord) async throws {
        guard !conversation.isArchived, !isBackendFrontend, !isLibraryClient, !adoptedExecutionConversations.contains(conversation.id),
              let workspaceID = conversation.remoteWorkspaceID,
              let configuration = remoteWorkspaces.configuration(id: workspaceID),
              let store = dashboardStore,
              let native = try? await store.database.localACPSession(conversationID: conversation.id),
              native.acpSessionID != nil else { return }
        let id = workspaceID.uuidString.lowercased()
        guard try await store.database.companionExecutionWorkspaces().contains(where: { $0.id == id && !$0.deleted }) else { return }
        if let pending = federatedAdoptionTasks[conversation.id] { try await pending.value; return }
        let task = Task { @MainActor in
            let owner = try await store.database.companionExecutionOwner(conversationID: conversation.id)
            if owner == nil {
                // Leave a currently running legacy session on its current owner.
                // Its next idle refresh will perform the transfer.
                if try await store.database.activeRunID(conversationID: conversation.id) != nil { return }
                _ = try await self.companionHost.provisionCentralExecutionWorkspace(id: id)
                try await store.detachLocalACPForExecutionAdoption(conversationID: conversation.id)
            }
            let identity = try await store.database.companionLibraryIdentity()
            let adoption = try await store.database.prepareCompanionExecutionAdoption(conversationID: conversation.id,
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
            guard try await database.companionExecutionOwner(conversationID: conversationID) == nil else {
                throw WorkspaceToolError.invalid("This goal continuation belongs to the previous execution owner.")
            }
            return false
        }
        if let conversation = try await database.workspaceOverview().conversations.first(where: { $0.id == conversationID }) {
            try await adoptRegisteredRemoteConversationIfNeeded(conversation)
        }
        guard try await database.companionExecutionOwner(conversationID: conversationID) != nil else { return false }
        guard input.files.isEmpty else { throw CompanionAPIError(code: "attachment_unavailable", message: "Save this file to the workspace before referencing it in this remote conversation.") }
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
