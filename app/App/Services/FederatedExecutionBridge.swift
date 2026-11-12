import CryptoKit
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
/// A chat that ran over SSH before and could not move to its Linux host's
/// server. It stays in the library, readable; sending to it says why.
struct LegacyRemoteChatError: LocalizedError, Equatable {
    var workspace: String
    var reason: String
    var errorDescription: String? {
        "This chat ran on \(workspace) over SSH, which Woven Matter no longer uses, and it could not move to \(workspace)'s server: "
            + reason.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) + ". Its history stays here, read-only. Start a new chat to continue."
    }
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
        // A Linux host's Pi Durable vault opens with this Mac's key for that
        // workspace (its registry id is the Keychain scope).
        client.unlockDefaultAgentHandler = { workspace, routes in
            try await DefaultAgentHostUnlock.unlock(scope: workspace.id, routes: routes)
        }
        federatedExecutionClient = client
        return client
    }

    /// The signed member routes of a Linux host this Mac added, by its
    /// configuration ID (which is its registry ID).
    func linuxMemberRoutes(_ id: UUID) async throws -> any MemberExecutionRoutes {
        guard let database = dashboardStore?.database,
              let workspace = try await database.libraryExecutionWorkspaces().first(where: { $0.id == id.uuidString.lowercased() && !$0.deleted }) else {
            throw LibraryAPIError(code: "unknown_workspace", message: "This Linux workspace is not in this library's workspaces yet. Reconnect it in Settings → Workspaces.")
        }
        return try await centralExecutionClient().memberRoutes(for: workspace)
    }

    /// An agent's file on a Linux host, for Library retention: `path` as the
    /// agent wrote it, resolved by the host in the chat's directory. A chat the
    /// host does not run (history that never moved there) reads `underRoot`,
    /// the path under the directory this library recorded for it.
    func readLinuxLibraryFile(workspaceID: String, conversationID: String, path: String, underRoot: String? = nil) async throws -> Data {
        guard let id = UUID(uuidString: workspaceID) else { throw WorkspaceToolError.invalid("Reconnect this remote workspace to save the file.") }
        let routes = try await linuxMemberRoutes(id)
        let file: MemberLibraryFile
        do { file = try await routes.libraryFile(conversationID: conversationID, path: path) }
        catch let error as LibraryAPIError where error.code == "http_404" {
            file = try await routes.libraryFile(conversationID: nil, path: underRoot ?? path)
        }
        guard let data = Data(base64Encoded: file.data), Int64(data.count) == file.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
            throw WorkspaceToolError.invalid("The workspace returned a damaged copy of this file. Try again.")
        }
        return data
    }

    /// The chat's workspace, connection and saved state when it opens; a
    /// window then follows its live state on its `conversation` subscription.
    func refreshFederatedConversation(_ id: String, reloadingConversation: Bool = true) async {
        do {
            let snapshot: FederatedExecutionSnapshot?
            if isBackendFrontend { snapshot = try await sendBackendCommand(.federatedExecution(.refresh(conversationID: id))).federatedExecution }
            else { snapshot = try await performFederatedExecution(.refresh(conversationID: id)) }
            if let snapshot { storeFederatedSnapshot(snapshot, conversationID: id) }
            if reloadingConversation { await refreshConversation(id: id) }
        } catch { ensureConversationState(id: id).setError(error.localizedDescription) }
    }

    /// A stream pushed live state for these chats: a background server relays
    /// it to the windows that follow them.
    func federatedLiveChanged(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        windowStreamRelayChanged(ids)
    }

    /// The chat closed. A window's `conversation` subscription ends with the
    /// view that held it, and with it the background server's own; a process
    /// that runs its own execution client ends that subscription here.
    func closeFederatedConversation(_ id: String) {
        guard !isBackendFrontend, federatedExecutionSnapshots[id]?.streamed == true else { return }
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
            if let snapshot { storeFederatedSnapshot(snapshot, conversationID: conversationID) }
            ensureConversationState(id: conversationID).setError(nil)
            return snapshot
        } catch { ensureConversationState(id: conversationID).setError(error.localizedDescription) }
        return nil
    }

    static let quickChatReadOnlyMessage = "Quick Chat runs only on its iPhone or iPad. Synced history is read-only here."

    func performFederatedExecution(_ action: FederatedExecutionAction) async throws -> FederatedExecutionSnapshot {
        let targetID: String
        switch action {
        case .refresh(let id), .earlier(let id, _), .close(let id): targetID = id
        case .stop(let id, _), .configure(let id, _): targetID = id
        case .respond(let interaction, _): targetID = interaction.conversationID
        }
        if let client = liveLibraryClient {
            let snapshot = try await client.desktopExecution(action)
            switch action {
            case .refresh, .close, .earlier: break
            case .stop, .configure, .respond: windowStreamRelayChanged([targetID])
            }
            return snapshot
        }
        let client = try centralExecutionClient()
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
        // An action's effect reaches the windows that follow this chat.
        if !refreshing { windowStreamRelayChanged([id]) }
        return snapshot
    }

    /// What this process still holds for a chat whose live read failed: its
    /// workspace and saved transcript, shown offline.
    func federatedSnapshotAfterFailure(_ id: String) async -> FederatedExecutionSnapshot? {
        guard liveLibraryClient == nil, let client = federatedExecutionClient,
              let workspace = try? await client.workspace(conversationID: id) else { return nil }
        return federatedSnapshot(id, workspace: workspace, client: client, transcript: client.transcripts[id], session: nil)
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

    /// A chat that ran over SSH before moves to its Linux host's server on
    /// first open, refresh or send: the host adopts its native session
    /// (`POST v1/execution/adopt`, signed) with the transcript this Mac shows.
    /// The database fence precedes the request; every retry sends the same
    /// immutable adoption, so a lost acknowledgement never creates a run.
    /// Nothing runs a chat over SSH any more, so one that cannot move stays
    /// here as read-only history and this throws `LegacyRemoteChatError`.
    func adoptRegisteredRemoteConversationIfNeeded(_ conversation: WorkspaceConversationRecord) async throws {
        guard !conversation.isArchived, !isBackendFrontend, !adoptedExecutionConversations.contains(conversation.id),
              let workspaceID = conversation.remoteWorkspaceID, let store = dashboardStore else { return }
        let id = workspaceID.uuidString.lowercased()
        let owner = try await store.database.libraryExecutionOwner(conversationID: conversation.id)
        // Created on the host's server: there is nothing to move.
        if owner != nil, try await !store.database.hasExecutionAdoption(conversationID: conversation.id) {
            adoptedExecutionConversations.insert(conversation.id); return
        }
        let name = remoteWorkspaces.configuration(id: workspaceID)?.name ?? "its Linux workspace"
        guard remoteWorkspaces.configuration(id: workspaceID) != nil else {
            throw LegacyRemoteChatError(workspace: name, reason: "That workspace is no longer set up on this Mac.")
        }
        guard let workspace = try await store.database.libraryExecutionWorkspaces().first(where: { $0.id == id && !$0.deleted }) else {
            throw LegacyRemoteChatError(workspace: name, reason: "It is not in this library's workspaces yet. Reconnect it in Settings → Workspaces.")
        }
        if let pending = federatedAdoptionTasks[conversation.id] { try await pending.value; return }
        let task = Task { @MainActor in
            if owner == nil {
                // The SSH session that ran it is gone with the app that started
                // it; an unsettled run is interrupted so the chat can move.
                try await store.database.interruptLegacyRemoteRuns(conversationID: conversation.id)
                try await store.detachLocalACPForExecutionAdoption(conversationID: conversation.id)
            }
            let identity = try await store.database.libraryIdentity()
            let adoption: ExecutionAdoption
            do {
                adoption = try await store.database.prepareExecutionAdoption(conversationID: conversation.id,
                    workspaceID: id, deviceID: identity.hostDeviceID)
            } catch let error as LibraryAPIError {
                throw LegacyRemoteChatError(workspace: name, reason: error.message)
            }
            self.federatedExecutionOwners[conversation.id] = id
            do {
                let routes = try await self.centralExecutionClient().memberRoutes(for: workspace)
                try await routes.adopt(JSONEncoder().encode(adoption))
            } catch {
                throw LegacyRemoteChatError(workspace: workspace.name, reason: error.localizedDescription)
            }
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
        let workspace = try await database.libraryConversationExecutionWorkspace(conversationID: conversationID)
        // Files go to a Linux host, which keeps them with the message. Other
        // workspaces take references only.
        guard input.files.isEmpty || workspace?.kind == .linux else {
            throw LibraryAPIError(code: "attachment_unavailable", message: "Save this file to the workspace before referencing it in this remote conversation.")
        }
        try await waitForAgentStop(conversationID: conversationID)
        try dispatchFence.check()
        let client = try centralExecutionClient()
        try await client.refresh(conversationID: conversationID)
        try dispatchFence.check()
        // The owner's live state can be newer than its central publication.
        let active = client.transcripts[conversationID]?.activeRunID
        if requiresIdle && active != nil { throw LocalACPSessionDatabaseError.runAlreadyActive }
        if let expectedRunID, expectedRunID != active { throw LocalACPSessionDatabaseError.runNotFound }
        let message = Self.federatedMessage(input, note: note, linux: workspace?.kind == .linux)
        _ = try await client.send(conversationID: conversationID, text: message.text, expectedRunID: expectedRunID ?? active,
            files: input.files, promptContext: message.promptContext, noteID: workspace?.kind == .linux ? note?.id : nil,
            beforeDispatch: { try dispatchFence.claimDispatch() })
        return true
    }

    /// What a member workspace receives for a message from this Mac. A Linux
    /// host takes the visible notes and pages and the reference blocks as
    /// `promptContext`, exactly as a local harness receives them after the
    /// message, so the transcript shows only what was typed; the note on
    /// screen is also named by `noteID`. Other members take references inline.
    nonisolated static func federatedMessage(_ input: AgentMessageInput, note: WorkspaceNoteRecord?, linux: Bool) -> (text: String, promptContext: String?) {
        let unreferencedNote = note.flatMap { note in input.references.contains(where: { $0.resourceID == note.id }) ? nil : note }
        guard linux else {
            var prompt = input.text
            for reference in input.references {
                prompt += "\n\nReferenced content: \(reference.titleSnapshot)\n\(reference.contentSnapshot)"
            }
            if let note = unreferencedNote { prompt += "\n\nReferenced note: \(note.title)\n\(note.content)" }
            return (prompt, nil)
        }
        var context = [input.promptContext].compactMap { $0 }
        if let note = unreferencedNote { context.append("Referenced note: \(note.title)\n\(note.content)") }
        return (input.text, context.isEmpty ? nil : context.joined(separator: "\n\n"))
    }
}
