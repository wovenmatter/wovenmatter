import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import os
import Security
import WovenMatterShared
import LibraryClient
import WovenMatterCore
import WovenMatterDashboardStore

/// This Mac's reach into every other machine's sessions: one member-signed
/// stream per workspace (docs/architecture/WOVEN_EVERYWHERE.md, "Streaming").
/// The live view (open chats' transcripts, questions and approvals,
/// capabilities, session settings) and commands move on the stream; history
/// arrives only by library sync. Nothing here reads a workspace on a timer: a
/// machine that is not connected shows what the library holds, marked offline.
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
    private let database: WorkspaceDatabase
    /// Command identities and receipts, so a retried command is never run twice.
    private let commandJournal: WorkspaceJournal
    private let provision: Provision
    private let makeTransport: MakeTransport
    private let makeSignedTransport: MakeSignedTransport?
    private let loadCredential: @MainActor (String) throws -> DirectWorkspaceCredential?
    private let saveCredential: @MainActor (DirectWorkspaceCredential) throws -> Void
    private let makeStream: MakeStream?
    private let streamConfiguration: StreamConnection.Configuration
    /// The member list's revision: a change lets a stream closed with 4401 try again.
    private let memberRevision: (@MainActor () async -> String?)?
    /// Live state pushed by a stream changed for these conversations.
    var onLive: @MainActor (Set<String>) -> Void = { _ in }
    /// Every `conversations`, `pending` and `synchronized` item of a
    /// workspace's stream, in order, for agent-to-agent waiting (`SessionWakeUps`).
    var onWorkspaceItem: (@MainActor (String, StreamItem.Payload) async -> Void)?
    private var live: [String: LiveWorkspace] = [:]
    /// Chats with a `conversation` subscription, least recently viewed first.
    private var watched: [String] = []
    /// Chats open in a window, with how many windows hold each.
    private var held: [String: Int] = [:]
    private var lastMemberRevision: String?
    private var wakeMonitor: StreamWakeMonitor?
    private var transports: [String: any ExecutionWorkspaceTransport] = [:]
    /// `connectRegisteredWorkspaces` is running; true when asked again meanwhile.
    private var connecting: Bool?
    private var transportEndpoints: [String: URL] = [:]
    private(set) var transcripts: [String: LibraryTranscript] = [:]
    private(set) var capabilities: [String: HarnessCapabilities] = [:]
    /// Session settings a watched chat's `conversation` stream sent.
    private(set) var sessions: [String: SessionSettings] = [:]
    private(set) var pending: [String: [PendingInteraction]] = [:]
    private(set) var onlineWorkspaces: Set<String> = []
    private(set) var errors: [String: String] = [:]

    init(database: WorkspaceDatabase, commandJournalURL: URL, provision: @escaping Provision,
         makeTransport: @escaping MakeTransport = { try HTTPSExecutionWorkspaceTransport(credential: $0) },
         loadCredential: @escaping @MainActor (String) throws -> DirectWorkspaceCredential? = CentralExecutionCredentialVault.load,
         saveCredential: @escaping @MainActor (DirectWorkspaceCredential) throws -> Void = CentralExecutionCredentialVault.save,
         makeSignedTransport: MakeSignedTransport? = nil,
         makeStream: MakeStream? = nil, memberRevision: (@MainActor () async -> String?)? = nil,
         streamConfiguration: StreamConnection.Configuration = .init()) throws {
        self.makeSignedTransport = makeSignedTransport
        self.database = database; self.commandJournal = try WorkspaceJournal(file: commandJournalURL)
        self.provision = provision; self.makeTransport = makeTransport
        self.loadCredential = loadCredential; self.saveCredential = saveCredential
        self.makeStream = makeStream; self.memberRevision = memberRevision; self.streamConfiguration = streamConfiguration
        if makeStream != nil { wakeMonitor = StreamWakeMonitor { [weak self] in self?.reconnectStreams() } }
    }

    /// The workspace that runs the conversation: from the library, or, for a
    /// session this Mac just created there before its history arrived by
    /// library sync, from the creation command this Mac recorded.
    func workspace(conversationID: String) async throws -> ExecutionWorkspace? {
        if let descriptor = try await database.libraryConversationExecutionWorkspace(conversationID: conversationID) { return descriptor }
        let created = await commandJournal.snapshot().commands.values.first {
            $0.command.kind == .createSession && $0.command.conversationID == conversationID && $0.receipt?.status != .rejected
        }
        guard let owner = created?.command.workspaceID else { return nil }
        return try await database.libraryExecutionWorkspaces().first { $0.id == owner && !$0.deleted }
    }

    /// Opens the stream of every registered workspace that has one and closes
    /// the streams of workspaces that left the registry. Run when the registry
    /// or the member list changes (`LibraryHostController.connectExecutionStreams`);
    /// it reads only this library, never a workspace, and each stream then
    /// reconnects by itself.
    func connectRegisteredWorkspaces() async {
        guard connecting == nil else { connecting = true; return }
        repeat {
            connecting = false
            guard let workspaces = try? await database.libraryExecutionWorkspaces() else { break }
            await applyMemberRevision()
            var streamed: Set<String> = []
            for workspace in workspaces where streamEligible(workspace) {
                if await ensureStream(workspace) != nil { streamed.insert(workspace.id) }
            }
            for id in Array(live.keys) where !streamed.contains(id) { await closeStream(id) }
        } while connecting == true
        connecting = nil
    }

    /// The chat's live state. On a stream this subscribes the chat and
    /// returns what the stream holds, waiting briefly for a first snapshot;
    /// while the machine is not connected it shows what the library holds and
    /// throws why. A workspace this Mac holds no stream to (one without
    /// `stream.v1`, or that cannot yet verify this Mac) shows what the library
    /// holds, marked offline with the reason. Nothing is read from the workspace.
    func refresh(conversationID: String) async throws {
        guard let descriptor = try await workspace(conversationID: conversationID) else { return }
        guard let stream = await ensureStream(descriptor) else {
            onlineWorkspaces.remove(descriptor.id)
            if errors[descriptor.id] == nil { errors[descriptor.id] = Self.unstreamedProblem(descriptor) }
            await restoreSaved(conversationID: conversationID)
            return
        }
        // A chat whose subscription the owner ended is read once, from the
        // library, and not subscribed again on this connection: an owner that
        // ended it for good (too large to send, unknown there) is not asked
        // again until it reconnects.
        if let reason = stream.ended[conversationID] {
            await restoreSaved(conversationID: conversationID)
            throw LibraryAPIError(code: Self.liveViewEnded, message: reason)
        }
        await watch(conversationID, on: stream)
        await stream.synchronized(conversationID, within: .seconds(5))
        if let reason = stream.ended[conversationID] {
            await restoreSaved(conversationID: conversationID)
            throw LibraryAPIError(code: Self.liveViewEnded, message: reason)
        }
        if onlineWorkspaces.contains(descriptor.id), transcripts[conversationID] != nil { return }
        await restoreSaved(conversationID: conversationID)
        throw LibraryAPIError(code: "workspace_unavailable", message: errors[descriptor.id] ?? "\(descriptor.name) is not connected yet.")
    }

    /// A chat's live view that its owner ended on this connection.
    nonisolated static let liveViewEnded = "live_view_ended"

    /// Last known state: the history library sync brought, which every device
    /// holds. Without any, the chat keeps what its stream last sent.
    private func restoreSaved(conversationID: String) async {
        guard let saved = try? await database.libraryFederatedTranscript(conversationID: conversationID) else { return }
        transcripts[conversationID] = Self.markCursor(saved, origin: "library")
    }

    /// Why a workspace has no live stream here.
    static func unstreamedProblem(_ workspace: ExecutionWorkspace) -> String {
        if workspace.retainedHistory == true {
            return "\(workspace.name) is retained history here. Its chats stay readable; start a new session to run work."
        }
        if workspace.kind == .ios {
            return "Open Woven Matter on the device that owns this conversation to continue its on-device agent."
        }
        if workspace.deleted { return "\(workspace.name) was removed from this library. Its chats stay readable." }
        if workspace.endpoint == nil { return "\(workspace.name) is not connected. Its chats show their saved history." }
        if !workspace.capabilities.contains(StreamProtocol.capability) {
            return "\(workspace.name) does not stream its sessions. Its chats show their saved history."
        }
        return "\(workspace.name) does not recognize this Mac yet. It does once the two devices synchronize their member list."
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
            // A workspace without `stream.v1` (a client-mode Dev build's own
            // execution) takes one signed request per command.
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
        // The stream pushes the command's effect; history follows by library sync.
        return receipt
    }
}

// MARK: Live stream

/// One `stream.v1` workspace's connection and what it is subscribed to.
@MainActor
final class LiveWorkspace {
    let workspace: ExecutionWorkspace
    let connection: StreamConnection
    var subscription: StreamSubscription?
    var conversations: [String: StreamSubscription] = [:]
    /// Chats whose `conversation` subscription is being sent: their items
    /// count before `subscribe` returns, so a fast first snapshot is kept.
    var opening: Set<String> = []
    /// Chats whose subscription the owner ended on this connection, with why.
    /// They are not subscribed again until the next `hello`.
    var ended: [String: String] = [:]
    /// The `workspace` subscription is being sent.
    var subscribingWorkspace = false
    /// Terminal ends of the `workspace` subscription so far.
    var workspaceEnds = 0
    var synchronizedConversations: Set<String> = []
    var state = StreamConnection.State.idle
    var stateTask: Task<Void, Never>?
    private var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]

    init(workspace: ExecutionWorkspace, connection: StreamConnection) {
        self.workspace = workspace; self.connection = connection
    }

    /// Returns once the open chat's first snapshot arrived, the connection
    /// failed, or `limit` passed.
    func synchronized(_ conversationID: String, within limit: Duration) async {
        // A chat still being subscribed waits too: its snapshot may be on the way.
        guard conversations[conversationID] != nil || opening.contains(conversationID), ended[conversationID] == nil,
              !synchronizedConversations.contains(conversationID) else { return }
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

extension CentralExecutionClient {
    /// Whether this Mac holds a stream to the workspace.
    func isStreamed(_ workspaceID: String) -> Bool { live[workspaceID] != nil }

    /// Opens the workspace's stream now (a wait on one of its sessions), if it has one.
    @discardableResult
    func openStream(_ workspace: ExecutionWorkspace) async -> Bool { await ensureStream(workspace) != nil }

    private func streamEligible(_ workspace: ExecutionWorkspace) -> Bool {
        makeStream != nil && !workspace.deleted && workspace.endpoint != nil && workspace.retainedHistory != true &&
            workspace.kind != .ios && workspace.capabilities.contains(StreamProtocol.capability)
    }

    /// The workspace's stream, opened on first use: one connection per
    /// workspace and its `workspace` subscription (conversations, questions
    /// and approvals; no journal, since history arrives by library sync). Nil
    /// when the workspace has no stream or this Mac cannot sign for it.
    fileprivate func ensureStream(_ workspace: ExecutionWorkspace) async -> LiveWorkspace? {
        if let existing = live[workspace.id] {
            if existing.workspace.endpoint == workspace.endpoint, streamEligible(workspace) { return existing }
            await closeStream(workspace.id)
        }
        guard streamEligible(workspace), let makeStream else { return nil }
        let connect: StreamConnection.Connect
        do {
            guard let value = try await makeStream(workspace) else { return nil }
            connect = value
        } catch { errors[workspace.id] = error.localizedDescription; return nil }
        if let existing = live[workspace.id] { return existing }
        // Nothing the socket sends counts until its `hello` names the workspace
        // this Mac meant to reach, as `identity()` checks over HTTP.
        let checked: StreamConnection.Connect = { [id = workspace.id, libraryID = workspace.libraryID, name = workspace.name] in
            HelloCheckedStreamTransport(try await connect(), workspaceID: id, libraryID: libraryID, name: name)
        }
        let connection = StreamConnection(configuration: streamConfiguration, connect: checked)
        let stream = LiveWorkspace(workspace: workspace, connection: connection)
        live[workspace.id] = stream
        let id = workspace.id
        stream.stateTask = Task { [weak self] in
            for await state in connection.states { self?.streamState(state, workspaceID: id) }
        }
        await subscribeWorkspace(stream)
        stream.state = .connecting
        await connection.start()
        return stream
    }

    /// Subscribes the workspace's `workspace` stream unless it is subscribed
    /// or being subscribed. Called when the stream is made, and on each new
    /// connection after the server ended the subscription for good.
    fileprivate func subscribeWorkspace(_ stream: LiveWorkspace) async {
        guard stream.subscription == nil, !stream.subscribingWorkspace else { return }
        stream.subscribingWorkspace = true
        defer { stream.subscribingWorkspace = false }
        let id = stream.workspace.id, ends = stream.workspaceEnds
        let subscription = await stream.connection.subscribe(.workspace, params: .init()) { [weak self] event in
            await self?.workspaceEvent(event, workspaceID: id) ?? .accepted
        }
        // Ended while it was being sent: already dropped; the next connection asks again.
        guard stream.workspaceEnds == ends else { return }
        if live[id] === stream { stream.subscription = subscription }
        else { await stream.connection.unsubscribe(subscription) }
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

    /// Subscribes the chat to its `conversation` stream. A chat open in any
    /// window (`hold`) stays subscribed until it closes. Chats read for other
    /// reasons (a send, an agent's status) stay subscribed too, at most
    /// `maximumUnheldWatches` of them: the least recently viewed is closed
    /// first, and viewing it again subscribes it again.
    fileprivate func watch(_ conversationID: String, on stream: LiveWorkspace) async {
        watched.removeAll { $0 == conversationID }
        watched.append(conversationID)
        if stream.conversations[conversationID] == nil, !stream.opening.contains(conversationID), stream.ended[conversationID] == nil {
            let workspaceID = stream.workspace.id
            // Items can arrive while `subscribe` is still sending: they count.
            stream.opening.insert(conversationID)
            let subscription = await stream.connection.subscribe(.conversation, params: .init(conversationID: conversationID)) { [weak self] event in
                await self?.conversationEvent(event, workspaceID: workspaceID, conversationID: conversationID) ?? .accepted
            }
            let opened = stream.opening.remove(conversationID) != nil
            if !opened || live[workspaceID] !== stream || stream.ended[conversationID] != nil || stream.conversations[conversationID] != nil {
                // The chat closed or its stream closed meanwhile, or the owner already ended it.
                await stream.connection.unsubscribe(subscription)
            } else {
                stream.conversations[conversationID] = subscription
            }
        }
        while let evicted = watched.first(where: { held[$0] == nil }),
              watched.count(where: { held[$0] == nil }) > Self.maximumUnheldWatches {
            Self.log.notice("Closing the least recently viewed chat's live subscription: \(evicted, privacy: .public)")
            await unwatch(evicted)
        }
    }

    /// Chats read but not open in any window that stay subscribed.
    static let maximumUnheldWatches = 8
    private static let log = Logger(subsystem: "com.wovenmatter.wovenmatter", category: "execution-stream")

    /// The chats with a live `conversation` subscription, least recently viewed first.
    var watchedConversationIDs: [String] { watched }

    /// A window opened the chat: it stays live until every window that holds it releases it.
    func hold(_ conversationID: String) { held[conversationID, default: 0] += 1 }

    /// A window closed the chat. Its subscription ends with the `close` that follows.
    func release(_ conversationID: String) {
        guard let count = held[conversationID] else { return }
        if count <= 1 { held.removeValue(forKey: conversationID) } else { held[conversationID] = count - 1 }
    }

    /// One activity's complete projection, from the workspace that runs it.
    func activityDetails(conversationID: String, runID: String, activityID: String) async throws -> LibraryActivity {
        let workspace = try await requiredWorkspace(conversationID)
        // Members sign the read; a provisioned grant's transport has no details route.
        guard let reader = try await transport(for: workspace) as? any ExecutionActivityDetailsReading else {
            throw LibraryAPIError(code: "unavailable", message: "Activity details are unavailable for this workspace.")
        }
        return try await reader.activityDetails(conversationID, runID: runID, activityID: activityID)
    }

    /// A message file of a session another machine runs, from that machine
    /// (`GET v1/execution/attachments/<sha256>`), checked against its digest.
    func attachment(conversationID: String, reference: LibraryAttachmentReference) async throws -> Data {
        try await transport(for: requiredWorkspace(conversationID)).attachment(reference)
    }

    /// The chat closed: its `conversation` subscription ends.
    func unwatch(_ conversationID: String) async {
        watched.removeAll { $0 == conversationID }
        // No longer pushed: the next subscription sends it again.
        sessions.removeValue(forKey: conversationID)
        for stream in live.values {
            stream.opening.remove(conversationID)
            guard let subscription = stream.conversations.removeValue(forKey: conversationID) else { continue }
            stream.synchronizedConversations.remove(conversationID)
            stream.release(conversationID)
            await stream.connection.unsubscribe(subscription)
        }
    }

    /// Why the chat's owner ended its live view on this connection, if it did.
    func endedLiveView(_ conversationID: String) -> String? {
        live.values.lazy.compactMap { $0.ended[conversationID] }.first
    }

    /// The owner may stream this chat again (it runs it now): its next read subscribes it.
    func resumeLiveView(_ conversationID: String) {
        for stream in live.values { stream.ended.removeValue(forKey: conversationID) }
    }

    private func streamState(_ state: StreamConnection.State, workspaceID id: String) {
        guard let stream = live[id] else { return }
        stream.state = state
        var changed = Set(stream.conversations.keys)
        switch state {
        case .open:
            // `HelloCheckedStreamTransport` already refused a `hello` naming another workspace.
            onlineWorkspaces.insert(id); errors.removeValue(forKey: id)
            // A new connection: chats the owner ended on the last one are read again, once.
            changed.formUnion(stream.ended.keys); stream.ended = [:]
            // So is the workspace subscription, if the server ended it for good.
            if stream.subscription == nil { Task { await self.subscribeWorkspace(stream) } }
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
        onLive(changed)
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
            if case .ended(let error) = event {
                // For good on this connection: the next one subscribes again.
                stream.subscription = nil; stream.workspaceEnds += 1
                errors[id] = error?.message ?? Self.streamProblem(nil, workspace: stream.workspace)
            }
            return .accepted
        }
        switch item.payload {
        case .conversations, .pending, .synchronized: await onWorkspaceItem?(id, item.payload)
        default: break
        }
        switch item.payload {
        case .pending(let value):
            let previous = Set((pending[id] ?? []).map(\.conversationID))
            pending[id] = value.interactions
            onLive(previous.union(value.interactions.map(\.conversationID)))
        // `journal` items come only to a subscriber that asks with `after`;
        // this Mac takes history from library sync and never asks.
        case .journal, .conversations, .transcript, .capabilities, .session, .owner, .library, .synchronized, .serverState, .unknown:
            break
        }
        return .accepted
    }

    private func conversationEvent(_ event: StreamSubscriptionEvent, workspaceID: String, conversationID: String) async -> StreamItemDisposition {
        guard let stream = live[workspaceID],
              stream.conversations[conversationID] != nil || stream.opening.contains(conversationID) else { return .accepted }
        switch event {
        case .ended(let error):
            // For good: the owner does not send this chat now (too large to
            // send, unknown there). It is not subscribed again on this
            // connection; the read that follows shows its library history.
            stream.conversations.removeValue(forKey: conversationID)
            let reason = error?.message.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            stream.ended[conversationID] = reason.isEmpty
                ? "\(stream.workspace.name) stopped sending this chat's live view. It shows its saved history until \(stream.workspace.name) reconnects."
                : reason
            watched.removeAll { $0 == conversationID }
            sessions.removeValue(forKey: conversationID)
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
            case .session(let value):
                guard value.settings.conversationID == conversationID else { return .accepted }
                sessions[conversationID] = value.settings
            case .synchronized:
                stream.synchronizedConversations.insert(conversationID)
                stream.release(conversationID)
            case .conversations, .pending, .journal, .owner, .library, .serverState, .unknown:
                return .accepted
            }
        }
        onLive([conversationID])
        return .accepted
    }

    /// The chat's model, thinking and permission settings, as its
    /// `conversation` stream last sent them (on subscribe and whenever they
    /// change). Nothing reads them: nil while the chat is not connected.
    func sessionSettings(conversationID: String, workspace: ExecutionWorkspace) -> SessionSettings? {
        guard onlineWorkspaces.contains(workspace.id), live[workspace.id]?.conversations[conversationID] != nil else { return nil }
        return sessions[conversationID]
    }
}

/// One member-signed socket whose first frame must be a `hello` naming the
/// workspace this Mac meant to reach. Any other `hello` fails the attempt
/// before an item is read, and the connection retries with its backoff.
actor HelloCheckedStreamTransport: StreamTransport {
    private let base: any StreamTransport
    private let workspaceID: String, libraryID: String, name: String
    private var greeted = false

    init(_ base: any StreamTransport, workspaceID: String, libraryID: String, name: String) {
        self.base = base; self.workspaceID = workspaceID; self.libraryID = libraryID; self.name = name
    }

    func receive() async throws -> StreamFrame {
        let frame = try await base.receive()
        guard !greeted, case .hello(let hello) = frame else { return frame }
        guard hello.workspaceID == workspaceID, hello.libraryID == libraryID else {
            throw StreamConnectionError.refused(status: 101, code: "wrong_workspace", message: "\(name) answered as another workspace.")
        }
        greeted = true
        return frame
    }
    func send(_ frame: StreamFrame) async throws { try await base.send(frame) }
    func ping() async throws { try await base.ping() }
    func close(_ code: WovenMatterShared.StreamProtocol.CloseCode) async { await base.close(code) }
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
