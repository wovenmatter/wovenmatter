import CryptoKit
import Foundation
import WovenMatterCore
import LibraryClient
import WovenMatterLibraryStore

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
}

extension ApplicationModel {
    /// Signed execution between members. In a Dev snapshot it reaches only the
    /// workspaces the snapshot itself knows live (its own, paired members',
    /// Linux hosts it added): `MemberExecutionClient` refuses every copied
    /// owner (`retainedHistory`), whose chats stay read-only history.
    func memberExecutionClient() throws -> MemberExecutionClient {
        guard !isBackendFrontend, let libraryStore else { throw ApplicationModelError.libraryStoreUnavailable }
        if let federatedExecutionClient { return titled(federatedExecutionClient) }
        // The command journal lives beside the library it addresses, never in a
        // global directory a fixture or another instance could share.
        let directory = libraryStore.database.supportDirectory
        let client = try MemberExecutionClient(database: libraryStore.database,
            commandJournalURL: directory.appending(path: MemberExecutionClient.commandJournalName),
            makeSignedTransport: { [weak self] workspace in
                // The iPhone is never an execution destination for signed calls.
                // A workspace whose serving member is unknown cannot be addressed.
                guard let self, workspace.kind != .ios, let directory = try? await self.libraryHost.peerSync.members(),
                      let audience = await directory.audience(for: workspace) else { return nil }
                return try SignedExecutionWorkspaceTransport(workspace: workspace, signer: directory.identity.signer, audience: audience)
            },
            makeStream: { [weak self] workspace in
                // The live stream lives where the member key and the command
                // journal are: this process, never a frontend window.
                guard let self, workspace.kind != .ios, let endpoint = workspace.endpoint,
                      let directory = try? await self.libraryHost.peerSync.members(),
                      let audience = await directory.audience(for: workspace) else { return nil }
                return try WebSocketStreamTransport.connector(endpoint: endpoint, signer: directory.identity.signer, audience: audience, headers: [
                    "X-Woven-Library": workspace.libraryID,
                    "X-Woven-Workspace": workspace.id, "X-Woven-Device": directory.identity.deviceID
                ])
            },
            memberRevision: { [weak self] in try? await self?.libraryHost.peerSync.members().list().revision })
        client.onLive = { [weak self] ids in self?.federatedLiveChanged(ids) }
        federatedExecutionClient = client
        return titled(client)
    }

    /// The client's messages name a workspace as the desktop titles it.
    private func titled(_ client: MemberExecutionClient) -> MemberExecutionClient {
        client.workspaceTitle = { [weak self] workspace in self?.workspaceDisplayName(workspace) ?? workspace.name }
        return client
    }

    /// The signed member routes of a Linux host this Mac added, by its
    /// configuration ID (which is its registry ID).
    func linuxMemberRoutes(_ id: UUID) async throws -> any MemberExecutionRoutes {
        guard let database = libraryStore?.database,
              let workspace = try await database.libraryExecutionWorkspaces().first(where: { $0.id == id.uuidString.lowercased() && !$0.deleted }) else {
            throw LibraryAPIError(code: "unknown_workspace", message: "This Linux workspace is not in this library's workspaces yet. Reconnect it in Settings → Workspaces.")
        }
        return try await memberExecutionClient().memberRoutes(for: workspace)
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
        // A process that renders its own chats, with no background server
        // between, takes the pushed state here.
        guard backendWindowSource == nil, !isBackendFrontend, LocalExecutionRole.current != .backend else { return }
        for id in ids where conversationStatesByID[id] != nil {
            Task { await refreshFederatedConversation(id, reloadingConversation: false) }
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
        let client = try memberExecutionClient()
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
        let session = client.sessionSettings(conversationID: id, workspace: workspace)
        let snapshot = federatedSnapshot(id, workspace: workspace, client: client, transcript: earlier ?? client.transcripts[id], session: session)
        // An older page is the caller's; the chat's own snapshot stays its live window.
        if earlier == nil { federatedExecutionSnapshots[id] = snapshot; renderRemoteConversation(id) }
        // An action's effect reaches the windows that follow this chat.
        if !refreshing { windowStreamRelayChanged([id]) }
        return snapshot
    }

    /// What this process still holds for a chat whose live read failed: its
    /// workspace and saved transcript, shown offline.
    func federatedSnapshotAfterFailure(_ id: String) async -> FederatedExecutionSnapshot? {
        guard let client = federatedExecutionClient,
              let workspace = try? await client.workspace(conversationID: id) else { return nil }
        return federatedSnapshot(id, workspace: workspace, client: client, transcript: client.transcripts[id], session: nil)
    }

    private func federatedSnapshot(_ id: String, workspace: ExecutionWorkspace, client: MemberExecutionClient,
                                   transcript: LibraryTranscript?, session: SessionSettings?) -> FederatedExecutionSnapshot {
        // A chat whose live view its owner ended shows its saved history with
        // why, as a machine that is not connected does.
        let problem = client.endedLiveView(id)
        return FederatedExecutionSnapshot(workspace: workspace, transcript: transcript,
            capability: client.capabilities[id], interactions: client.pending[workspace.id]?.filter { $0.conversationID == id } ?? [],
            session: session, online: problem == nil && client.onlineWorkspaces.contains(workspace.id),
            error: problem ?? client.errors[workspace.id])
    }

    /// A snapshot's copied history has no connection or credential to its former owner.
    func savedDevelopmentExecution(_ action: FederatedExecutionAction) async throws -> FederatedExecutionSnapshot {
        guard let database = libraryStore?.database else { throw ApplicationModelError.libraryStoreUnavailable }
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

    /// Called before any native runtime selection or preparation. Imported
    /// execution ownership is looked up live as well as cached for presentation.
    func dispatchFederatedMessage(conversationID: String, input: AgentMessageInput, note: WorkspaceNoteRecord?,
                                  expectedRunID: String?, requiresIdle: Bool, dispatchFence: AgentDispatchFence) async throws -> Bool {
        guard let database = libraryStore?.database else { return false }
        if let id = input.historyDeliveryID, try await database.toolDelivery(id: id)?.kind == .goal {
            // A primary-owner reservation can never become a foreign-owner send.
            try await database.validateClaimedToolDelivery(id: id)
            guard try await database.libraryExecutionOwner(conversationID: conversationID) == nil else {
                throw WorkspaceToolError.invalid("This goal continuation belongs to the previous execution owner.")
            }
            return false
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
        let client = try memberExecutionClient()
        try await client.refresh(conversationID: conversationID)
        try dispatchFence.check()
        // The owner's live state can be newer than the history library sync brought.
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
