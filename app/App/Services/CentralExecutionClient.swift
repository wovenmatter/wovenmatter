import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import Security
import LibraryClient
import WovenMatterCore
import WovenMatterDashboardStore

/// The authoritative Mac is also an observer of foreign execution owners.
/// Direct control keeps a separate validated history cache; only an execution
/// owner's publisher can add that history to the authoritative database.
@MainActor @Observable
final class CentralExecutionClient {
    typealias Provision = @MainActor (String) async throws -> ExecutionCredential
    typealias MakeTransport = @MainActor (DirectWorkspaceCredential) throws -> any ExecutionWorkspaceTransport
    /// A transport signed with this Mac's member key, or nil when this Mac has
    /// no member identity yet. It replaces provisioned grants for every member.
    typealias MakeSignedTransport = @MainActor (ExecutionWorkspace) async throws -> (any ExecutionWorkspaceTransport)?
    /// Opens the live stream to a `stream.v1` workspace (one signed socket per
    /// attempt), or nil when this Mac cannot sign for it yet.
    typealias MakeStream = @MainActor (ExecutionWorkspace) async throws -> StreamConnection.Connect?
    private var foreignHistoryJournals: [String: WorkspaceJournal] = [:]
    private let database: WorkspaceDatabase
    private let commandJournal: WorkspaceJournal
    private let provision: Provision
    private let makeTransport: MakeTransport
    private let makeSignedTransport: MakeSignedTransport?
    private let loadCredential: @MainActor (String) throws -> DirectWorkspaceCredential?
    private let saveCredential: @MainActor (DirectWorkspaceCredential) throws -> Void
    private let onChange: @MainActor () async -> Void
    private let makeStream: MakeStream?
    private let streamConfiguration: StreamConnection.Configuration
    /// The member list's revision: a change lets a stream closed with 4401 try again.
    private let memberRevision: (@MainActor () async -> String?)?
    /// Live state pushed by a stream changed for these conversations.
    var onLive: @MainActor (Set<String>) -> Void = { _ in }
    private var live: [String: LiveWorkspace] = [:]
    /// Open chats with a `conversation` subscription, least recently opened first.
    private var watched: [String] = []
    private var lastMemberRevision: String?
    private var changeScheduled = false
    private var wakeMonitor: StreamWakeMonitor?
    private var sessionCache: [String: CachedSession] = [:]
    private var transports: [String: any ExecutionWorkspaceTransport] = [:]
    private var nextBackgroundRefresh: [String: Date] = [:]
    private var backgroundRefreshInProgress = false
    private var transportEndpoints: [String: URL] = [:]
    private var refreshTasks: [String: Task<Void, any Error>] = [:]
    private(set) var transcripts: [String: LibraryTranscript] = [:]
    private(set) var capabilities: [String: HarnessCapabilities] = [:]
    private(set) var pending: [String: [PendingInteraction]] = [:]
    private(set) var onlineWorkspaces: Set<String> = []
    private(set) var errors: [String: String] = [:]

    init(database: WorkspaceDatabase, commandJournalURL: URL, provision: @escaping Provision,
         makeTransport: @escaping MakeTransport = { try HTTPSExecutionWorkspaceTransport(credential: $0) },
         loadCredential: @escaping @MainActor (String) throws -> DirectWorkspaceCredential? = CentralExecutionCredentialVault.load,
         saveCredential: @escaping @MainActor (DirectWorkspaceCredential) throws -> Void = CentralExecutionCredentialVault.save,
         makeSignedTransport: MakeSignedTransport? = nil,
         makeStream: MakeStream? = nil, memberRevision: (@MainActor () async -> String?)? = nil,
         streamConfiguration: StreamConnection.Configuration = .init(),
         onChange: @escaping @MainActor () async -> Void = {}) throws {
        self.makeSignedTransport = makeSignedTransport
        self.database = database; self.commandJournal = try WorkspaceJournal(file: commandJournalURL)
        self.provision = provision; self.makeTransport = makeTransport; self.onChange = onChange
        self.loadCredential = loadCredential; self.saveCredential = saveCredential
        self.makeStream = makeStream; self.memberRevision = memberRevision; self.streamConfiguration = streamConfiguration
        if makeStream != nil { wakeMonitor = StreamWakeMonitor { [weak self] in self?.reconnectStreams() } }
    }

    func workspace(conversationID: String) async throws -> ExecutionWorkspace? {
        var descriptor = try await database.libraryConversationExecutionWorkspace(conversationID: conversationID)
        if descriptor == nil {
            let cached = await commandJournal.snapshot()
            if !cached.deletedConversationIDs.contains(conversationID), let owner = cached.conversationWorkspaceIDs[conversationID] {
                descriptor = try await database.libraryExecutionWorkspaces().first { $0.id == owner && !$0.deleted }
            }
        }
        return descriptor
    }

    /// Background observer refresh does not depend on a selected conversation.
    /// Only enrolled endpoints participate; this never launches a workspace or
    /// publishes another execution owner's history.
    func refreshRegisteredWorkspaces() async {
        guard !backgroundRefreshInProgress else { return }
        backgroundRefreshInProgress = true
        defer { backgroundRefreshInProgress = false }
        guard let workspaces = try? await database.libraryExecutionWorkspaces() else { return }
        await applyMemberRevision()
        var streamed: Set<String> = []
        for workspace in workspaces where !workspace.deleted && workspace.endpoint != nil && workspace.retainedHistory != true {
            guard !Task.isCancelled else { return }
            // A `stream.v1` workspace pushes its journal, questions and approvals:
            // nothing here polls it, connected or not.
            if await ensureStream(workspace) != nil { streamed.insert(workspace.id); continue }
            guard !workspace.capabilities.contains("history.central.v1") else { continue }
            guard nextBackgroundRefresh[workspace.id].map({ $0 <= Date() }) ?? true else { continue }
            do {
                if let pending = refreshTasks[workspace.id] { try await pending.value }
                else {
                    let task = Task { try await self.replay(workspace: workspace) }
                    refreshTasks[workspace.id] = task
                    do { try await task.value; refreshTasks.removeValue(forKey: workspace.id) }
                    catch { refreshTasks.removeValue(forKey: workspace.id); throw error }
                }
                pending[workspace.id] = try await transport(for: workspace).pending()
                onlineWorkspaces.insert(workspace.id); errors.removeValue(forKey: workspace.id)
                nextBackgroundRefresh[workspace.id] = Date().addingTimeInterval(10)
            } catch {
                if case MobileConnectionError.revoked = error { transports.removeValue(forKey: workspace.id) }
                onlineWorkspaces.remove(workspace.id); errors[workspace.id] = error.localizedDescription
                nextBackgroundRefresh[workspace.id] = Date().addingTimeInterval(45)
            }
        }
        for id in Array(live.keys) where !streamed.contains(id) { await closeStream(id) }
    }

    func refresh(conversationID: String) async throws {
        guard let descriptor = try await workspace(conversationID: conversationID) else { return }
        if let stream = await ensureStream(descriptor) {
            // Live: the open chat is subscribed and its state is pushed. This
            // returns what the stream holds, waiting briefly for a first snapshot.
            await watch(conversationID, on: stream)
            await stream.synchronized(conversationID, within: .seconds(5))
            if onlineWorkspaces.contains(descriptor.id), transcripts[conversationID] != nil { return }
            await restoreSaved(conversationID: conversationID, descriptor: descriptor)
            throw LibraryAPIError(code: "workspace_unavailable", message: errors[descriptor.id] ?? "\(descriptor.name) is not connected yet.")
        }
        do {
            if let task = refreshTasks[descriptor.id] { try await task.value }
            else {
                let task = Task { try await self.replay(workspace: descriptor) }
                refreshTasks[descriptor.id] = task
                do { try await task.value; refreshTasks.removeValue(forKey: descriptor.id) }
                catch { refreshTasks.removeValue(forKey: descriptor.id); throw error }
            }
            let transport = try await transport(for: descriptor)
            // Live streaming state is a projection only. Durable history arrives
            // through replay, where origin identity and sequence are validated.
            let transcript = try await transport.transcript(conversationID)
            guard transcript.conversationID == conversationID else { throw MobileConnectionError.invalidResponse }
            transcripts[conversationID] = Self.markCursor(transcript, origin: "owner")
            capabilities[conversationID] = try await transport.capabilities(conversationID)
            pending[descriptor.id] = try await transport.pending()
            onlineWorkspaces.insert(descriptor.id); errors.removeValue(forKey: descriptor.id)
        } catch {
            if case MobileConnectionError.revoked = error { transports.removeValue(forKey: descriptor.id) }
            onlineWorkspaces.remove(descriptor.id); errors[descriptor.id] = error.localizedDescription
            await restoreSaved(conversationID: conversationID, descriptor: descriptor)
            throw error
        }
    }

    /// An observer may be ahead of the owner's last central publication.
    /// Prefer that durable cache only while its origin cursor is newer.
    private func restoreSaved(conversationID: String, descriptor: ExecutionWorkspace) async {
        let cached = await (foreignHistoryJournals[descriptor.libraryID] ?? commandJournal).snapshot()
        let publishedCursor = (try? await database.libraryExecutionOriginCursor(workspaceID: descriptor.id)) ?? 0
        if (cached.directCursors[descriptor.id] ?? 0) > publishedCursor, let saved = cached.transcripts[conversationID] {
            transcripts[conversationID] = Self.markCursor(saved, origin: "owner")
        } else if let saved = try? await database.libraryFederatedTranscript(conversationID: conversationID) {
            transcripts[conversationID] = Self.markCursor(saved, origin: "library")
        } else if let saved = cached.transcripts[conversationID] {
            transcripts[conversationID] = Self.markCursor(saved, origin: "owner")
        }
    }


    private func transport(for workspace: ExecutionWorkspace) async throws -> any ExecutionWorkspaceTransport {
        if let transport = transports[workspace.id], transportEndpoints[workspace.id] == workspace.endpoint { return transport }
        transports.removeValue(forKey: workspace.id)
        // A copied owner (a Dev snapshot's, or a Mac unpaired from this one) is
        // history only: it is never signed for, granted or provisioned.
        guard workspace.retainedHistory != true else {
            throw LibraryAPIError(code: "workspace_unavailable", message: "\(workspace.name) is retained history here. Its chats stay readable; start a new session to run work.")
        }
        guard !workspace.deleted, workspace.kind != .ios || workspace.endpoint != nil else {
            throw LibraryAPIError(code: "workspace_unavailable", message: "Open Woven Matter on the device that owns this conversation to continue its on-device agent.")
        }
        // Members sign every request; nothing is provisioned, so the Mac that
        // added the workspace does not need to be online.
        if workspace.endpoint != nil, let signed = try await makeSignedTransport?(workspace) {
            do {
                let remote = try await signed.identity()
                guard remote.id == workspace.id, remote.libraryID == workspace.libraryID else { throw MobileStore.Failure.wrongWorkspace }
                transports[workspace.id] = signed; transportEndpoints[workspace.id] = workspace.endpoint
                return signed
            } catch MobileConnectionError.revoked {
                // No grant stands in for a member: the peer has not synchronized
                // this Mac's membership yet, or it removed this Mac.
                throw LibraryAPIError(code: "unauthorized", message: "\(workspace.name) does not recognize this Mac yet. It does once the two devices synchronize their member list.")
            }
        }
        let identity = try await database.libraryIdentity()
        let account = CentralExecutionCredentialVault.account(libraryID: workspace.libraryID, workspaceID: workspace.id, deviceID: identity.hostDeviceID)
        if let saved = try loadCredential(account), saved.libraryID == workspace.libraryID,
           saved.workspaceID == workspace.id, saved.deviceID == identity.hostDeviceID,
           saved.endpoint == workspace.endpoint {
            let transport = try makeTransport(saved)
            do {
                let remote = try await transport.identity()
                guard remote.id == workspace.id, remote.libraryID == workspace.libraryID else { throw MobileStore.Failure.wrongWorkspace }
                transports[workspace.id] = transport; transportEndpoints[workspace.id] = remote.endpoint
                return transport
            } catch MobileConnectionError.revoked {
                // Explicit revocation may be renewed by the authoritative host.
            } catch let error as LibraryAPIError where ["unauthorized", "revoked", "invalid_token"].contains(error.code) {
                // Only a definitive authorization rejection renews the grant.
                // A network failure retains the existing scoped credential.
            }
        }
        let issued: ExecutionCredential
        do { issued = try await provision(workspace.id) }
        catch where makeSignedTransport != nil {
            throw LibraryAPIError(code: "unauthorized", message: "\(workspace.name) does not recognize this Mac yet. It does once the two devices synchronize their member list.")
        }
        guard issued.workspace.id == workspace.id, issued.workspace.libraryID == workspace.libraryID,
              issued.deviceID == identity.hostDeviceID, let endpoint = issued.workspace.endpoint else { throw MobileConnectionError.invalidResponse }
        let credential = DirectWorkspaceCredential(endpoint: endpoint, libraryID: workspace.libraryID,
            workspaceID: workspace.id, deviceID: identity.hostDeviceID, token: issued.token)
        let transport = try makeTransport(credential)
        // Provisioning has acknowledged this scoped grant. Preserve it before
        // probing reachability so a lost probe does not rotate it on reconnect.
        try saveCredential(credential)
        let remote = try await transport.identity()
        guard remote.id == workspace.id, remote.libraryID == workspace.libraryID else { throw MobileStore.Failure.wrongWorkspace }
        transports[workspace.id] = transport; transportEndpoints[workspace.id] = remote.endpoint
        return transport
    }

    /// Where a workspace's replayed history is cached: the command journal for
    /// this library, a separate journal per foreign library.
    private func historyJournal(for workspace: ExecutionWorkspace) async throws -> WorkspaceJournal {
        let identity = try await database.libraryIdentity()
        if workspace.libraryID == identity.libraryID { return commandJournal }
        if let existing = foreignHistoryJournals[workspace.libraryID] { return existing }
        let journal = try WorkspaceJournal(file: database.supportDirectory.appending(path: "Peer History/" + workspace.libraryID + ".json"))
        foreignHistoryJournals[workspace.libraryID] = journal
        return journal
    }

    private func replay(workspace: ExecutionWorkspace) async throws {
        if workspace.capabilities.contains("history.central.v1") { return }
        let journal = try await historyJournal(for: workspace)
        let transport = try await transport(for: workspace)
        try await journal.upsertWorkspace(workspace, pending: false)
        var changed = false
        for _ in 0..<100 {
            let cursor = await journal.snapshot().directCursors[workspace.id] ?? 0
            let page = try await transport.events(after: cursor)
            // Validates library, contiguous workspace sequence, immutable event
            // identities and projection ownership in one durable transaction.
            // Omitting localDeviceID keeps every received event cache-only.
            try await journal.receiveWorkspace(page, workspaceID: workspace.id)
            try await database.retainDirectPairedHistory(page, workspace: workspace)
            changed = changed || !page.entries.isEmpty
            if !page.hasMore { break }
        }
        let cached = await journal.snapshot()
        for (id, owner) in cached.conversationWorkspaceIDs where owner == workspace.id {
            if cached.deletedConversationIDs.contains(id) {
                transcripts.removeValue(forKey: id)
            } else if let transcript = cached.transcripts[id] {
                transcripts[id] = Self.markCursor(transcript, origin: "owner")
            }
        }
        if changed { await onChange() }
    }

    /// Creates a session on `workspace` with the caller's choices. A locked Pi
    /// Durable vault, reported by the provider list or the receipt, is
    /// unlocked with this Mac's key (`unlockDefaultAgent`) and the creation
    /// retried once under a new command ID.
    func createSession(workspace: ExecutionWorkspace, runtimeKind: AgentRuntimeKind,
                       conversationID: String, folderID: String?, title: String? = nil,
                       sessionOptions: LibrarySessionOptions? = nil) async throws -> LibraryCommandReceipt {
        let identity = try await database.libraryIdentity()
        var unlocked = false
        func provider() async throws -> HarnessCapabilities {
            let providers = try await transport(for: workspace).providers()
            if !unlocked, providers.contains(where: { $0.runtimeKind == runtimeKind.rawValue && $0.locked == true }) {
                try await unlockDefaultAgent(on: workspace); unlocked = true
                return try await provider()
            }
            guard let provider = providers.first(where: { $0.runtimeKind == runtimeKind.rawValue && $0.available && $0.canStart }) else {
                throw LibraryAPIError(code: "unavailable", message: "Set up this agent on its workspace before starting a chat.")
            }
            return provider
        }
        func command(_ id: String, provider: HarnessCapabilities) -> LibraryCommand {
            .init(commandID: id, deviceID: identity.hostDeviceID, kind: .createSession,
                  conversationID: conversationID, providerID: provider.id, runtimeKind: runtimeKind.rawValue, folderID: folderID,
                  libraryID: workspace.libraryID, workspaceID: workspace.id, title: title, sessionOptions: sessionOptions)
        }
        do { return try await submit(command(conversationID, provider: provider()), workspace: workspace) }
        catch let error as LibraryAPIError where error.code == Self.defaultAgentLocked && !unlocked {
            try await unlockDefaultAgent(on: workspace); unlocked = true
            return try await submit(command(UUID().uuidString.lowercased(), provider: provider()), workspace: workspace)
        }
    }

    nonisolated static let defaultAgentLocked = "default_agent_locked"

    /// Unlocks a host's Pi Durable vault with this Mac's key for it. Set by
    /// the application model, which holds the Keychain.
    var unlockDefaultAgentHandler: (@MainActor (ExecutionWorkspace, any MemberExecutionRoutes) async throws -> Void)?

    func unlockDefaultAgent(on workspace: ExecutionWorkspace) async throws {
        guard let unlockDefaultAgentHandler else {
            throw LibraryAPIError(code: Self.defaultAgentLocked, message: "Pi Durable is locked on \(workspace.name). Open Woven Matter on the Mac that set it up.")
        }
        try await unlockDefaultAgentHandler(workspace, memberRoutes(for: workspace))
    }

    /// The Linux server's member routes for `workspace`, signed by this Mac.
    func memberRoutes(for workspace: ExecutionWorkspace) async throws -> any MemberExecutionRoutes {
        guard let routes = try await transport(for: workspace) as? any MemberExecutionRoutes else {
            throw LibraryAPIError(code: "workspace_unavailable", message: "\(workspace.name) does not recognize this Mac yet. It does once the two devices synchronize their member list.")
        }
        return routes
    }

    /// A harness's model, thinking and permission choices on `workspace`
    /// before a session exists (`GET v1/execution/providers/<id>/options`).
    func sessionOptions(workspace: ExecutionWorkspace, runtimeKind: AgentRuntimeKind,
                        workingDirectory: String?, model: String?) async throws -> SessionSettings {
        let providers = try await transport(for: workspace).providers()
        guard let provider = providers.first(where: { $0.runtimeKind == runtimeKind.rawValue }) else {
            throw LibraryAPIError(code: "unavailable", message: "\(runtimeKind.displayName) is not set up on \(workspace.name).")
        }
        let routes = try await memberRoutes(for: workspace)
        if provider.locked == true { try await unlockDefaultAgent(on: workspace) }
        return try await routes.sessionOptions(providerID: provider.id, workingDirectory: workingDirectory, model: model)
    }

    /// Uploads a message's files to `workspace` by their SHA-256, then
    /// returns the references a `send` or `steer` names.
    func uploadAttachments(_ files: [AgentFileAttachmentDraft], to workspace: ExecutionWorkspace) async throws -> [LibraryAttachmentReference] {
        guard !files.isEmpty else { return [] }
        try MemberAttachmentLimits.check(files)
        let routes = try await memberRoutes(for: workspace)
        var references: [LibraryAttachmentReference] = []
        for file in files {
            let data = try Data(contentsOf: file.localURL, options: .mappedIfSafe)
            try MemberAttachmentLimits.check([AgentFileAttachmentDraft(kind: file.kind, fileName: file.fileName, mimeType: file.mimeType,
                sizeBytes: Int64(data.count), contentHash: file.contentHash, localURL: file.localURL)])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let mimeType = file.mimeType.isEmpty ? "application/octet-stream" : file.mimeType
            let uploaded = try await routes.uploadAttachment(data, sha256: digest, name: file.fileName, mimeType: mimeType)
            guard uploaded.id == digest else { throw MobileConnectionError.invalidResponse }
            references.append(uploaded)
        }
        return references
    }

    /// The destination's agent routes, for choosing a harness on another member.
    func providers(workspace: ExecutionWorkspace) async throws -> [HarnessCapabilities] {
        try await transport(for: workspace).providers()
    }

    // Direct reads of another member's workspace, for agents that manage the
    // sessions they started there (`woven_sessions_status`, `_list`, `_respond`).
    func conversations(workspace: ExecutionWorkspace) async throws -> [LibraryConversation] {
        try await transport(for: workspace).conversations()
    }
    func transcript(workspace: ExecutionWorkspace, conversationID: String, before: String?) async throws -> LibraryTranscript {
        let transport = try await transport(for: workspace)
        if let before { return try await transport.transcript(conversationID, before: before) }
        return try await transport.transcript(conversationID)
    }
    func pendingInteractions(workspace: ExecutionWorkspace) async throws -> [PendingInteraction] {
        try await transport(for: workspace).pending()
    }
    func capabilities(workspace: ExecutionWorkspace, conversationID: String) async throws -> HarnessCapabilities {
        try await transport(for: workspace).capabilities(conversationID)
    }

    @discardableResult
    func send(conversationID: String, text: String, expectedRunID: String? = nil, files: [AgentFileAttachmentDraft] = [],
              promptContext: String? = nil, noteID: String? = nil,
              beforeDispatch: @escaping @MainActor () throws -> Void = {}) async throws -> LibraryCommandReceipt {
        try await send(to: requiredWorkspace(conversationID), conversationID: conversationID, text: text,
            expectedRunID: expectedRunID, files: files, promptContext: promptContext, noteID: noteID, beforeDispatch: beforeDispatch)
    }

    /// Sends to a conversation whose workspace is already known, such as one
    /// just created there before its history has reached this library. Files
    /// are uploaded first and named in the command; `promptContext` reaches the
    /// harness after the message and `noteID` is the note shown when sending.
    @discardableResult
    func send(to workspace: ExecutionWorkspace, conversationID: String, text: String, expectedRunID: String? = nil,
              files: [AgentFileAttachmentDraft] = [], promptContext: String? = nil, noteID: String? = nil,
              beforeDispatch: @escaping @MainActor () throws -> Void = {}) async throws -> LibraryCommandReceipt {
        let identity = try await database.libraryIdentity()
        let kind: LibraryCommand.Kind = expectedRunID == nil ? .send : .steer
        let attachments = try await uploadAttachments(files, to: workspace)
        // A Pi Durable run would fail after its send was accepted: unlock first.
        if capabilities[conversationID]?.runtimeKind == AgentRuntimeKind.defaultAgent.rawValue,
           try await transport(for: workspace).providers().contains(where: { $0.runtimeKind == AgentRuntimeKind.defaultAgent.rawValue && $0.locked == true }) {
            try await unlockDefaultAgent(on: workspace)
        }
        let existing = await commandJournal.commandRecords(workspaceID: workspace.id).first {
            ($0.receipt == nil || $0.receipt?.status == .outcomeUnknown) && $0.command.kind == kind &&
            $0.command.conversationID == conversationID && $0.command.text == text && $0.command.runID == expectedRunID &&
            ($0.command.attachments ?? []) == attachments
        }
        func command(_ id: String = UUID().uuidString.lowercased()) -> LibraryCommand {
            LibraryCommand(commandID: id, deviceID: identity.hostDeviceID, kind: kind, conversationID: conversationID, runID: expectedRunID,
                text: text, noteID: noteID, libraryID: workspace.libraryID, workspaceID: workspace.id,
                attachments: attachments.isEmpty ? nil : attachments, promptContext: promptContext)
        }
        do { return try await submit(existing?.command ?? command(), workspace: workspace, beforeDispatch: beforeDispatch) }
        catch let error as LibraryAPIError where error.code == Self.defaultAgentLocked {
            // The refusal is final for its command ID; the retry is a new command.
            try await unlockDefaultAgent(on: workspace)
            return try await submit(command(), workspace: workspace, beforeDispatch: beforeDispatch)
        }
    }

    @discardableResult
    func stop(conversationID: String, runID: String) async throws -> LibraryCommandReceipt {
        let workspace = try await requiredWorkspace(conversationID)
        let identity = try await database.libraryIdentity()
        return try await submit(.init(deviceID: identity.hostDeviceID, kind: .stop, conversationID: conversationID,
            runID: runID, libraryID: workspace.libraryID, workspaceID: workspace.id), workspace: workspace)
    }

    @discardableResult
    func respond(_ interaction: PendingInteraction, response: InteractionResponse) async throws -> LibraryCommandReceipt {
        let workspace = try await requiredWorkspace(interaction.conversationID)
        let identity = try await database.libraryIdentity()
        return try await submit(.init(deviceID: identity.hostDeviceID, kind: .respond, conversationID: interaction.conversationID,
            runID: interaction.runID, interactionID: interaction.id, response: response,
            libraryID: workspace.libraryID, workspaceID: workspace.id), workspace: workspace)
    }

    func readWorkspace(conversationID: String, request: LibraryWorkspaceRead) async throws -> LibraryWorkspaceResult {
        let workspace = try await requiredWorkspace(conversationID)
        return try await transport(for: workspace).readWorkspace(request)
    }
    func earlierTranscript(conversationID: String, before: String) async throws -> LibraryTranscript {
        if before.hasPrefix("library:") {
            guard let saved = try await database.libraryFederatedTranscript(conversationID: conversationID,
                before: String(before.dropFirst("library:".count))) else { throw MobileConnectionError.invalidResponse }
            return Self.markCursor(saved, origin: "library")
        }
        guard before.hasPrefix("owner:") else { throw MobileConnectionError.invalidResponse }
        let workspace = try await requiredWorkspace(conversationID)
        let page = try await transport(for: workspace).transcript(conversationID, before: String(before.dropFirst("owner:".count)))
        return Self.markCursor(page, origin: "owner")
    }
    private static func markCursor(_ transcript: LibraryTranscript, origin: String) -> LibraryTranscript {
        var value = transcript
        value.olderCursor = transcript.olderCursor.map { origin + ":" + $0 }
        return value
    }
    @discardableResult
    func perform(conversationID: String, action: LibraryWorkspaceAction) async throws -> LibraryCommandReceipt {
        let workspace = try await requiredWorkspace(conversationID)
        let identity = try await database.libraryIdentity()
        return try await submit(.init(deviceID: identity.hostDeviceID, kind: .workspace, conversationID: conversationID,
            workspaceAction: action, libraryID: workspace.libraryID, workspaceID: workspace.id), workspace: workspace)
    }
    private func requiredWorkspace(_ id: String) async throws -> ExecutionWorkspace {
        guard let workspace = try await workspace(conversationID: id), !workspace.deleted else {
            throw LibraryAPIError(code: "unknown_workspace", message: "This conversation's execution workspace is unavailable.")
        }
        return workspace
    }
    /// Sends one durable command to `workspace`, replaying its receipt when the
    /// destination already accepted it (command IDs make retries exact).
    func submit(_ requested: LibraryCommand, workspace: ExecutionWorkspace,
                        beforeDispatch: @MainActor () throws -> Void = {}) async throws -> LibraryCommandReceipt {
        let unresolved = await commandJournal.commandRecords(workspaceID: workspace.id).first {
            ($0.receipt == nil || $0.receipt?.status == .outcomeUnknown) &&
            $0.command.kind == requested.kind && $0.command.conversationID == requested.conversationID &&
            $0.command.runID == requested.runID && $0.command.text == requested.text &&
            $0.command.interactionID == requested.interactionID && $0.command.response == requested.response &&
            $0.command.workspaceAction == requested.workspaceAction
        }
        let command = try await commandJournal.rememberCommand(unresolved?.command ?? requested, workspaceID: workspace.id)
        let receipt: LibraryCommandReceipt
        let stream = await ensureStream(workspace)
        if let stream {
            // Over the stream: a lost reply is recorded as outcomeUnknown and
            // resolved with execution.receipt after reconnecting, never resent.
            var routed = command
            routed.libraryID = workspace.libraryID; routed.workspaceID = workspace.id
            do {
                if unresolved != nil, let existing = try await stream.connection.receipt(command.commandID) { receipt = existing }
                else {
                    try beforeDispatch()
                    receipt = try await StreamCommands.send(routed, workspaceID: workspace.id, journal: commandJournal, connection: stream.connection)
                }
            } catch let error as StreamConnectionError where error.outcomeUnknown {
                throw LibraryAPIError(code: "execution_unconfirmed", message: "The execution workspace has not confirmed this command. Its durable identity has been retained.")
            } catch let error as StreamConnectionError {
                if case .remote(let remote) = error { throw LibraryAPIError(code: remote.code, message: remote.message) }
                throw LibraryAPIError(code: "workspace_unavailable", message: errors[workspace.id] ?? error.localizedDescription)
            }
        } else {
            let transport = try await transport(for: workspace)
            if let existing = try await transport.receipt(command.commandID) { receipt = existing }
            else { try beforeDispatch(); receipt = try await transport.command(command) }
        }
        guard receipt.commandID == command.commandID, receipt.deviceID == command.deviceID,
              receipt.workspaceID == nil || receipt.workspaceID == workspace.id else { throw MobileConnectionError.invalidResponse }
        try await commandJournal.rememberReceipt(receipt, workspaceID: workspace.id)
        guard receipt.status == .accepted || receipt.status == .completed else {
            // A coded refusal (`default_agent_locked`, `attachment_unavailable`) is one the caller can act on.
            throw LibraryAPIError(code: receipt.status == .rejected ? receipt.code ?? "execution_unconfirmed" : "execution_unconfirmed",
                message: receipt.message ?? "The execution workspace has not confirmed this command. Its durable identity has been retained.")
        }
        // A failed refresh cannot turn an acknowledged command into a failed send.
        // The UI clears the draft after success and refreshes history independently.
        // A streamed workspace pushes the result instead.
        if stream == nil { try? await refresh(conversationID: command.conversationID ?? "") }
        return receipt
    }
}

// MARK: Live stream

/// One `stream.v1` workspace's connection and what it is subscribed to.
@MainActor
final class LiveWorkspace {
    let workspace: ExecutionWorkspace
    let connection: StreamConnection
    /// Where its journal entries are cached; nil for a workspace with central history.
    let journal: WorkspaceJournal?
    var subscription: StreamSubscription?
    var conversations: [String: StreamSubscription] = [:]
    var synchronizedConversations: Set<String> = []
    var state = StreamConnection.State.idle
    /// A journal entry this Mac could not take; the journal replay resumes after this.
    var journalRetryAt: Date?
    var stateTask: Task<Void, Never>?
    private var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]

    init(workspace: ExecutionWorkspace, connection: StreamConnection, journal: WorkspaceJournal?) {
        self.workspace = workspace; self.connection = connection; self.journal = journal
    }

    /// Returns once the open chat's first snapshot arrived, the connection
    /// failed, or `limit` passed.
    func synchronized(_ conversationID: String, within limit: Duration) async {
        guard conversations[conversationID] != nil, !synchronizedConversations.contains(conversationID) else { return }
        switch state {
        case .waiting, .memberRemoved: return
        case .idle, .connecting, .open: break
        }
        let key = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[conversationID, default: [:]][key] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: limit)
                self?.release(conversationID, key: key)
            }
        }
    }

    func release(_ conversationID: String, key: UUID? = nil) {
        if let key { waiters[conversationID]?.removeValue(forKey: key)?.resume(); return }
        for (_, waiter) in waiters.removeValue(forKey: conversationID) ?? [:] { waiter.resume() }
    }

    func releaseAll() { for id in Array(waiters.keys) { release(id) } }
}

private struct CachedSession {
    var runID: String?
    var capabilities: HarnessCapabilities?
    var value: SessionSettings
}

extension CentralExecutionClient {
    /// Whether this workspace's live state is pushed by its stream rather than polled.
    func isStreamed(_ workspaceID: String) -> Bool { live[workspaceID] != nil }

    private func streamEligible(_ workspace: ExecutionWorkspace) -> Bool {
        makeStream != nil && !workspace.deleted && workspace.endpoint != nil && workspace.retainedHistory != true &&
            workspace.kind != .ios && workspace.capabilities.contains(StreamProtocol.capability)
    }

    /// The workspace's stream, opened on first use: one connection per
    /// workspace, its `workspace` subscription replaying the journal after this
    /// Mac's cursor. Nil when the workspace has no stream or this Mac cannot sign for it.
    fileprivate func ensureStream(_ workspace: ExecutionWorkspace) async -> LiveWorkspace? {
        if let existing = live[workspace.id] {
            if existing.workspace.endpoint == workspace.endpoint, streamEligible(workspace) {
                await resumeJournalIfDue(existing)
                return existing
            }
            await closeStream(workspace.id)
        }
        guard streamEligible(workspace), let makeStream else { return nil }
        let connect: StreamConnection.Connect
        do {
            guard let value = try await makeStream(workspace) else { return nil }
            connect = value
        } catch { errors[workspace.id] = error.localizedDescription; return nil }
        if let existing = live[workspace.id] { return existing }
        var journal: WorkspaceJournal?
        if !workspace.capabilities.contains("history.central.v1") {
            do {
                let value = try await historyJournal(for: workspace)
                try await value.upsertWorkspace(workspace, pending: false)
                journal = value
            } catch { errors[workspace.id] = error.localizedDescription; return nil }
        }
        if let existing = live[workspace.id] { return existing }
        let connection = StreamConnection(configuration: streamConfiguration, connect: connect)
        let stream = LiveWorkspace(workspace: workspace, connection: connection, journal: journal)
        live[workspace.id] = stream
        let id = workspace.id
        stream.stateTask = Task { [weak self] in
            for await state in connection.states { self?.streamState(state, workspaceID: id) }
        }
        let after: Int64? = journal == nil ? nil : await journal?.snapshot().directCursors[id] ?? 0
        stream.subscription = await connection.subscribe(.workspace, params: .init(after: after)) { [weak self] event in
            await self?.workspaceEvent(event, workspaceID: id) ?? .accepted
        }
        stream.state = .connecting
        await connection.start()
        return stream
    }

    fileprivate func closeStream(_ id: String) async {
        guard let stream = live.removeValue(forKey: id) else { return }
        stream.stateTask?.cancel()
        stream.releaseAll()
        watched.removeAll { stream.conversations[$0] != nil }
        onlineWorkspaces.remove(id)
        await stream.connection.stop()
    }

    /// Wake or a network path change: every stream tries at once.
    func reconnectStreams() {
        for stream in live.values { Task { await stream.connection.connectNow() } }
    }

    fileprivate func applyMemberRevision() async {
        guard let memberRevision, let revision = await memberRevision() else { return }
        defer { lastMemberRevision = revision }
        guard let last = lastMemberRevision, last != revision else { return }
        for stream in live.values { await stream.connection.membersChanged() }
    }

    /// Subscribes the open chat to its `conversation` stream. At most four
    /// chats stay subscribed; the least recently opened is closed first.
    fileprivate func watch(_ conversationID: String, on stream: LiveWorkspace) async {
        watched.removeAll { $0 == conversationID }
        watched.append(conversationID)
        if stream.conversations[conversationID] == nil {
            let workspaceID = stream.workspace.id
            let subscription = await stream.connection.subscribe(.conversation, params: .init(conversationID: conversationID)) { [weak self] event in
                await self?.conversationEvent(event, workspaceID: workspaceID, conversationID: conversationID) ?? .accepted
            }
            if stream.conversations[conversationID] == nil { stream.conversations[conversationID] = subscription }
            else { await stream.connection.unsubscribe(subscription) }
        }
        while watched.count > 4 { await unwatch(watched[0]) }
    }

    /// The chat closed: its `conversation` subscription ends.
    func unwatch(_ conversationID: String) async {
        watched.removeAll { $0 == conversationID }
        for stream in live.values {
            guard let subscription = stream.conversations.removeValue(forKey: conversationID) else { continue }
            stream.synchronizedConversations.remove(conversationID)
            stream.release(conversationID)
            await stream.connection.unsubscribe(subscription)
        }
    }

    private func resumeJournalIfDue(_ stream: LiveWorkspace) async {
        guard let retry = stream.journalRetryAt, retry <= Date(), let journal = stream.journal, let subscription = stream.subscription else { return }
        stream.journalRetryAt = nil
        let cursor = await journal.snapshot().directCursors[stream.workspace.id] ?? 0
        await stream.connection.resubscribe(subscription, params: .init(after: cursor))
    }

    private func streamState(_ state: StreamConnection.State, workspaceID id: String) {
        guard let stream = live[id] else { return }
        stream.state = state
        switch state {
        case .open(let hello):
            // The server must answer for the registered workspace, as `identity()` does over HTTP.
            guard hello.workspaceID == id, hello.libraryID == stream.workspace.libraryID else {
                onlineWorkspaces.remove(id); errors[id] = "\(stream.workspace.name) answered as another workspace."
                Task { await stream.connection.stop() }
                return
            }
            onlineWorkspaces.insert(id); errors.removeValue(forKey: id)
            // Commands whose reply was lost are resolved, never resent.
            let connection = stream.connection, journal = commandJournal
            Task { _ = try? await StreamCommands.resolveUnknown(workspaceID: id, journal: journal, connection: connection) }
        case .waiting(let error):
            onlineWorkspaces.remove(id); errors[id] = Self.streamProblem(error, workspace: stream.workspace)
            stream.synchronizedConversations = []; stream.releaseAll()
        case .memberRemoved:
            onlineWorkspaces.remove(id); errors[id] = Self.streamProblem(.memberRemoved, workspace: stream.workspace)
            stream.synchronizedConversations = []; stream.releaseAll()
        case .idle:
            onlineWorkspaces.remove(id); stream.synchronizedConversations = []; stream.releaseAll()
        case .connecting: break
        }
        onLive(Set(stream.conversations.keys))
    }

    static func streamProblem(_ error: StreamConnectionError?, workspace: ExecutionWorkspace) -> String {
        switch error {
        case .memberTimeStale: "This Mac's clock is wrong. Set the date and time automatically in System Settings, then try again."
        case .unauthorized: "\(workspace.name) does not recognize this Mac yet. It does once the two devices synchronize their member list."
        case .memberRemoved: "\(workspace.name) no longer lists this Mac as a member. It reconnects once the member lists change."
        case .protocolUnsupported: "Update Woven Matter on \(workspace.name) and on this Mac."
        case nil, .disconnected, .timedOut, .notConnected: "\(workspace.name) is not connected. Woven Matter reconnects automatically."
        case let error?: error.localizedDescription
        }
    }

    private func workspaceEvent(_ event: StreamSubscriptionEvent, workspaceID id: String) async -> StreamItemDisposition {
        guard let stream = live[id] else { return .accepted }
        guard case .item(let item) = event else {
            if case .ended(let error) = event { errors[id] = error?.message ?? Self.streamProblem(nil, workspace: stream.workspace) }
            return .accepted
        }
        switch item.payload {
        case .journal(let value):
            guard let journal = stream.journal else { return .accepted }
            let workspace = stream.workspace
            let cursor = await journal.snapshot().directCursors[id] ?? 0
            let entry = value.entry
            guard entry.originSequence > cursor else { return .accepted }
            // One entry is one page: the journal validates library, contiguous
            // sequence and identities exactly as for an HTTP replay page.
            let page = ExecutionJournalPage(libraryID: workspace.libraryID, cursor: entry.originSequence, entries: [entry])
            do { try await journal.receiveWorkspace(page, workspaceID: id) }
            catch WorkspaceJournal.Failure.replayGap { return .resubscribe(.init(after: cursor)) }
            catch {
                // Keep questions and approvals live; try the journal again later.
                errors[id] = error.localizedDescription
                stream.journalRetryAt = Date().addingTimeInterval(45)
                return .resubscribe(.init())
            }
            do { try await database.retainDirectPairedHistory(page, workspace: workspace) }
            catch { errors[id] = error.localizedDescription }
            let cached = await journal.snapshot()
            let conversationID = entry.conversationID
            if cached.deletedConversationIDs.contains(conversationID) { transcripts.removeValue(forKey: conversationID) }
            else if stream.conversations[conversationID] == nil, let transcript = cached.transcripts[conversationID] {
                transcripts[conversationID] = Self.markCursor(transcript, origin: "owner")
            }
            scheduleChange()
            onLive([conversationID])
        case .pending(let value):
            let previous = Set((pending[id] ?? []).map(\.conversationID))
            pending[id] = value.interactions
            onLive(previous.union(value.interactions.map(\.conversationID)))
        case .conversations, .transcript, .capabilities, .session, .synchronized, .serverState, .unknown:
            break
        }
        return .accepted
    }

    private func conversationEvent(_ event: StreamSubscriptionEvent, workspaceID: String, conversationID: String) async -> StreamItemDisposition {
        guard let stream = live[workspaceID], stream.conversations[conversationID] != nil else { return .accepted }
        switch event {
        case .ended:
            stream.conversations.removeValue(forKey: conversationID)
            stream.synchronizedConversations.remove(conversationID)
            stream.release(conversationID)
        case .item(let item):
            switch item.payload {
            case .transcript(var value):
                guard value.transcript.conversationID == conversationID else { return .accepted }
                value.transcript = Self.markCursor(value.transcript, origin: "owner")
                transcripts[conversationID] = (transcripts[conversationID] ?? .init(conversationID: conversationID)).applying(value)
            case .capabilities(let value):
                capabilities[conversationID] = value.capabilities
            case .synchronized:
                stream.synchronizedConversations.insert(conversationID)
                stream.release(conversationID)
            case .conversations, .pending, .journal, .session, .serverState, .unknown:
                return .accepted
            }
        }
        onLive([conversationID])
        return .accepted
    }

    /// Journal changes reach the library views at most every 250 ms.
    private func scheduleChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.changeScheduled = false
            await self.onChange()
        }
    }

    /// The chat's model, thinking and permission settings. A streamed chat
    /// reads them again only when its run or capabilities change, or after an action.
    func sessionSettings(conversationID: String, workspace: ExecutionWorkspace, force: Bool) async -> SessionSettings? {
        guard onlineWorkspaces.contains(workspace.id) else { return nil }
        let runID = transcripts[conversationID]?.activeRunID, current = capabilities[conversationID]
        if !force, isStreamed(workspace.id), let cached = sessionCache[conversationID], cached.runID == runID, cached.capabilities == current {
            return cached.value
        }
        guard case .session(let value) = try? await readWorkspace(conversationID: conversationID, request: .session(id: conversationID)) else { return nil }
        sessionCache[conversationID] = .init(runID: runID, capabilities: current, value: value)
        return value
    }
}

/// Wake and network path changes: every stream tries at once instead of
/// waiting out its backoff.
@MainActor
final class StreamWakeMonitor {
    private let path = NWPathMonitor()
    private var observer: (any NSObjectProtocol)?

    init(_ changed: @escaping @MainActor @Sendable () -> Void) {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { changed() }
        }
        path.pathUpdateHandler = { update in
            guard update.status == .satisfied else { return }
            Task { @MainActor in changed() }
        }
        path.start(queue: DispatchQueue(label: "com.wovenmatter.stream-path"))
    }

    isolated deinit {
        path.cancel()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

/// Separate from phone/client grants: an execution owner's authority must never
/// overwrite a paired user's bearer for the same workspace on this Mac.
enum CentralExecutionCredentialVault {
    static let service = "com.wovenmatter.central-execution"
    static func account(libraryID: String, workspaceID: String, deviceID: String) -> String {
        [libraryID, workspaceID, deviceID].joined(separator: ":")
    }
    static func load(_ account: String) throws -> DirectWorkspaceCredential? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return try JSONDecoder().decode(DirectWorkspaceCredential.self, from: data)
    }
    static func save(_ credential: DirectWorkspaceCredential) throws {
        let key = account(libraryID: credential.libraryID, workspaceID: credential.workspaceID, deviceID: credential.deviceID)
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
        let values: [CFString: Any] = [kSecValueData: try JSONEncoder().encode(credential), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let inserted = SecItemAdd(query.merging(values) { _, value in value } as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(inserted)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
