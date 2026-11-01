import Foundation
import Observation
import Security
import CompanionClient
import WovenMatterCore
import WovenMatterDashboardStore

/// The authoritative Mac is also an observer of foreign execution owners.
/// Direct control keeps a separate validated history cache; only an execution
/// owner's publisher can add that history to the authoritative database.
@MainActor @Observable
final class CentralExecutionClient {
    typealias Provision = @MainActor (String) async throws -> CompanionExecutionCredential
    typealias MakeTransport = @MainActor (DirectWorkspaceCredential) throws -> any ExecutionWorkspaceTransport
    private let database: WorkspaceDatabase
    private let commandJournal: WorkspaceJournal
    private let provision: Provision
    private let makeTransport: MakeTransport
    private let loadCredential: @MainActor (String) throws -> DirectWorkspaceCredential?
    private let saveCredential: @MainActor (DirectWorkspaceCredential) throws -> Void
    private let onChange: @MainActor () async -> Void
    private var transports: [String: any ExecutionWorkspaceTransport] = [:]
    private var nextBackgroundRefresh: [String: Date] = [:]
    private var backgroundRefreshInProgress = false
    private var transportEndpoints: [String: URL] = [:]
    private var refreshTasks: [String: Task<Void, any Error>] = [:]
    private(set) var workspaceByConversation: [String: CompanionExecutionWorkspace] = [:]
    private(set) var transcripts: [String: CompanionTranscript] = [:]
    private(set) var workspaceProviders: [String: [CompanionProvider]] = [:]
    private var providerRefreshAfter: [String: Date] = [:]
    private(set) var capabilities: [String: CompanionProvider] = [:]
    private(set) var pending: [String: [CompanionPendingInteraction]] = [:]
    private(set) var onlineWorkspaces: Set<String> = []
    private(set) var errors: [String: String] = [:]

    init(database: WorkspaceDatabase, commandJournalURL: URL, provision: @escaping Provision,
         makeTransport: @escaping MakeTransport = { try HTTPSExecutionWorkspaceTransport(credential: $0) },
         loadCredential: @escaping @MainActor (String) throws -> DirectWorkspaceCredential? = CentralExecutionCredentialVault.load,
         saveCredential: @escaping @MainActor (DirectWorkspaceCredential) throws -> Void = CentralExecutionCredentialVault.save,
         onChange: @escaping @MainActor () async -> Void = {}) throws {
        self.database = database; self.commandJournal = try WorkspaceJournal(file: commandJournalURL)
        self.provision = provision; self.makeTransport = makeTransport; self.onChange = onChange
        self.loadCredential = loadCredential; self.saveCredential = saveCredential
    }

    func workspace(conversationID: String) async throws -> CompanionExecutionWorkspace? {
        var descriptor = try await database.companionConversationExecutionWorkspace(conversationID: conversationID)
        if descriptor == nil {
            let cached = await commandJournal.snapshot()
            if !cached.deletedConversationIDs.contains(conversationID), let owner = cached.conversationWorkspaceIDs[conversationID] {
                descriptor = try await database.companionExecutionWorkspaces().first { $0.id == owner && !$0.deleted }
            }
        }
        if let descriptor { workspaceByConversation[conversationID] = descriptor }
        else { workspaceByConversation.removeValue(forKey: conversationID) }
        return descriptor
    }

    /// Background observer refresh does not depend on a selected conversation.
    /// Only enrolled endpoints participate; this never launches a workspace or
    /// publishes another execution owner's history.
    func refreshRegisteredWorkspaces() async {
        guard !backgroundRefreshInProgress else { return }
        backgroundRefreshInProgress = true
        defer { backgroundRefreshInProgress = false }
        guard let workspaces = try? await database.companionExecutionWorkspaces() else { return }
        for workspace in workspaces where !workspace.deleted && workspace.endpoint != nil &&
            !workspace.capabilities.contains("history.central.v1") {
            guard !Task.isCancelled else { return }
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
    }

    func refresh(conversationID: String) async throws {
        guard let descriptor = try await workspace(conversationID: conversationID) else { return }
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
            // An observer may be ahead of the owner's last central publication.
            // Prefer that durable cache only while its origin cursor is newer.
            let cached = await commandJournal.snapshot()
            let publishedCursor = (try? await database.companionExecutionOriginCursor(workspaceID: descriptor.id)) ?? 0
            if (cached.directCursors[descriptor.id] ?? 0) > publishedCursor, let saved = cached.transcripts[conversationID] {
                transcripts[conversationID] = Self.markCursor(saved, origin: "owner")
            } else if let saved = try? await database.companionFederatedTranscript(conversationID: conversationID) {
                transcripts[conversationID] = Self.markCursor(saved, origin: "library")
            } else if let saved = cached.transcripts[conversationID] {
                transcripts[conversationID] = Self.markCursor(saved, origin: "owner")
            }
            throw error
        }
    }

    func providerCatalog(for workspaces: [CompanionExecutionWorkspace]) async -> [String: [CompanionProvider]] {
        for workspace in workspaces where workspace.kind == .mac && workspace.isVisibleInConnections && workspace.endpoint != nil && !workspace.capabilities.contains("history.central.v1") {
            guard !Task.isCancelled else { break }
            guard providerRefreshAfter[workspace.id].map({ $0 <= Date() }) ?? true else { continue }
            providerRefreshAfter[workspace.id] = Date().addingTimeInterval(30)
            if let providers = try? await transport(for: workspace).providers() { workspaceProviders[workspace.id] = providers }
        }
        let known = Set(workspaces.filter { !$0.deleted && $0.retainedHistory != true }.map(\.id))
        workspaceProviders = workspaceProviders.filter { known.contains($0.key) }
        return workspaceProviders
    }

    private func transport(for workspace: CompanionExecutionWorkspace) async throws -> any ExecutionWorkspaceTransport {
        if let transport = transports[workspace.id], transportEndpoints[workspace.id] == workspace.endpoint { return transport }
        transports.removeValue(forKey: workspace.id)
        guard !workspace.deleted, workspace.kind != .ios || workspace.endpoint != nil else {
            throw CompanionAPIError(code: "workspace_unavailable", message: "Open Woven Matter on the device that owns this conversation to continue its on-device agent.")
        }
        let identity = try await database.companionLibraryIdentity()
        let account = CentralExecutionCredentialVault.account(libraryID: identity.libraryID, workspaceID: workspace.id, deviceID: identity.hostDeviceID)
        if let saved = try loadCredential(account), saved.libraryID == identity.libraryID,
           saved.workspaceID == workspace.id, saved.deviceID == identity.hostDeviceID,
           saved.endpoint == workspace.endpoint {
            let transport = try makeTransport(saved)
            do {
                let remote = try await transport.identity()
                guard remote.id == workspace.id, remote.libraryID == identity.libraryID else { throw MobileStore.Failure.wrongWorkspace }
                transports[workspace.id] = transport; transportEndpoints[workspace.id] = remote.endpoint
                return transport
            } catch MobileConnectionError.revoked {
                // Explicit revocation may be renewed by the authoritative host.
            } catch let error as CompanionAPIError where ["unauthorized", "revoked", "invalid_token"].contains(error.code) {
                // Only a definitive authorization rejection renews the grant.
                // A network failure retains the existing scoped credential.
            }
        }
        let issued = try await provision(workspace.id)
        guard issued.workspace.id == workspace.id, issued.workspace.libraryID == identity.libraryID,
              issued.deviceID == identity.hostDeviceID, let endpoint = issued.workspace.endpoint else { throw MobileConnectionError.invalidResponse }
        let credential = DirectWorkspaceCredential(endpoint: endpoint, libraryID: identity.libraryID,
            workspaceID: workspace.id, deviceID: identity.hostDeviceID, token: issued.token)
        let transport = try makeTransport(credential)
        // Provisioning has acknowledged this scoped grant. Preserve it before
        // probing reachability so a lost probe does not rotate it on reconnect.
        try saveCredential(credential)
        let remote = try await transport.identity()
        guard remote.id == workspace.id, remote.libraryID == identity.libraryID else { throw MobileStore.Failure.wrongWorkspace }
        transports[workspace.id] = transport; transportEndpoints[workspace.id] = remote.endpoint
        return transport
    }

    private func replay(workspace: CompanionExecutionWorkspace) async throws {
        let identity = try await database.companionLibraryIdentity()
        guard workspace.libraryID == identity.libraryID else { throw WorkspaceJournal.Failure.wrongLibrary }
        let transport = try await transport(for: workspace)
        try await commandJournal.upsertWorkspace(workspace, pending: false)
        var changed = false
        for _ in 0..<100 {
            let cursor = await commandJournal.snapshot().directCursors[workspace.id] ?? 0
            let page = try await transport.events(after: cursor)
            // Validates library, contiguous workspace sequence, immutable event
            // identities and projection ownership in one durable transaction.
            // Omitting localDeviceID keeps every received event cache-only.
            try await commandJournal.receiveWorkspace(page, workspaceID: workspace.id)
            changed = changed || !page.entries.isEmpty
            if !page.hasMore { break }
        }
        let cached = await commandJournal.snapshot()
        for (id, owner) in cached.conversationWorkspaceIDs where owner == workspace.id {
            if cached.deletedConversationIDs.contains(id) {
                workspaceByConversation.removeValue(forKey: id); transcripts.removeValue(forKey: id)
            } else {
                workspaceByConversation[id] = workspace
                if let transcript = cached.transcripts[id] { transcripts[id] = Self.markCursor(transcript, origin: "owner") }
            }
        }
        if changed { await onChange() }
    }

    @discardableResult
    func send(conversationID: String, text: String, expectedRunID: String? = nil,
              beforeDispatch: @escaping @MainActor () throws -> Void = {}) async throws -> CompanionCommandReceipt {
        let workspace = try await requiredWorkspace(conversationID)
        let identity = try await database.companionLibraryIdentity()
        let kind: CompanionCommand.Kind = expectedRunID == nil ? .send : .steer
        let existing = await commandJournal.commandRecords(workspaceID: workspace.id).first {
            ($0.receipt == nil || $0.receipt?.status == .outcomeUnknown) && $0.command.kind == kind &&
            $0.command.conversationID == conversationID && $0.command.text == text && $0.command.runID == expectedRunID
        }
        let command = existing?.command ?? CompanionCommand(deviceID: identity.hostDeviceID, kind: kind,
            conversationID: conversationID, runID: expectedRunID, text: text, libraryID: identity.libraryID, workspaceID: workspace.id)
        return try await submit(command, workspace: workspace, beforeDispatch: beforeDispatch)
    }

    @discardableResult
    func stop(conversationID: String, runID: String) async throws -> CompanionCommandReceipt {
        let workspace = try await requiredWorkspace(conversationID)
        let identity = try await database.companionLibraryIdentity()
        return try await submit(.init(deviceID: identity.hostDeviceID, kind: .stop, conversationID: conversationID,
            runID: runID, libraryID: identity.libraryID, workspaceID: workspace.id), workspace: workspace)
    }

    @discardableResult
    func respond(_ interaction: CompanionPendingInteraction, response: CompanionInteractionResponse) async throws -> CompanionCommandReceipt {
        let workspace = try await requiredWorkspace(interaction.conversationID)
        let identity = try await database.companionLibraryIdentity()
        return try await submit(.init(deviceID: identity.hostDeviceID, kind: .respond, conversationID: interaction.conversationID,
            runID: interaction.runID, interactionID: interaction.id, response: response,
            libraryID: identity.libraryID, workspaceID: workspace.id), workspace: workspace)
    }

    func readWorkspace(conversationID: String, request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult {
        let workspace = try await requiredWorkspace(conversationID)
        return try await transport(for: workspace).readWorkspace(request)
    }
    func earlierTranscript(conversationID: String, before: String) async throws -> CompanionTranscript {
        if before.hasPrefix("library:") {
            guard let saved = try await database.companionFederatedTranscript(conversationID: conversationID,
                before: String(before.dropFirst("library:".count))) else { throw MobileConnectionError.invalidResponse }
            return Self.markCursor(saved, origin: "library")
        }
        guard before.hasPrefix("owner:") else { throw MobileConnectionError.invalidResponse }
        let workspace = try await requiredWorkspace(conversationID)
        let page = try await transport(for: workspace).transcript(conversationID, before: String(before.dropFirst("owner:".count)))
        return Self.markCursor(page, origin: "owner")
    }
    private static func markCursor(_ transcript: CompanionTranscript, origin: String) -> CompanionTranscript {
        var value = transcript
        value.olderCursor = transcript.olderCursor.map { origin + ":" + $0 }
        return value
    }
    @discardableResult
    func perform(conversationID: String, action: CompanionWorkspaceAction) async throws -> CompanionCommandReceipt {
        let workspace = try await requiredWorkspace(conversationID)
        let identity = try await database.companionLibraryIdentity()
        return try await submit(.init(deviceID: identity.hostDeviceID, kind: .workspace, conversationID: conversationID,
            workspaceAction: action, libraryID: identity.libraryID, workspaceID: workspace.id), workspace: workspace)
    }
    private func requiredWorkspace(_ id: String) async throws -> CompanionExecutionWorkspace {
        guard let workspace = try await workspace(conversationID: id), !workspace.deleted else {
            throw CompanionAPIError(code: "unknown_workspace", message: "This conversation's execution workspace is unavailable.")
        }
        return workspace
    }
    private func submit(_ requested: CompanionCommand, workspace: CompanionExecutionWorkspace,
                        beforeDispatch: @MainActor () throws -> Void = {}) async throws -> CompanionCommandReceipt {
        guard workspace.kind != .ios else {
            throw CompanionAPIError(code: "read_only_history", message: "Quick Chat runs only on its iPhone or iPad. Synced history is read-only here.")
        }
        let unresolved = await commandJournal.commandRecords(workspaceID: workspace.id).first {
            ($0.receipt == nil || $0.receipt?.status == .outcomeUnknown) &&
            $0.command.kind == requested.kind && $0.command.conversationID == requested.conversationID &&
            $0.command.runID == requested.runID && $0.command.text == requested.text &&
            $0.command.interactionID == requested.interactionID && $0.command.response == requested.response &&
            $0.command.workspaceAction == requested.workspaceAction
        }
        let command = try await commandJournal.rememberCommand(unresolved?.command ?? requested, workspaceID: workspace.id)
        let transport = try await transport(for: workspace)
        let receipt: CompanionCommandReceipt
        if let existing = try await transport.receipt(command.commandID) { receipt = existing }
        else { try beforeDispatch(); receipt = try await transport.command(command) }
        guard receipt.commandID == command.commandID, receipt.deviceID == command.deviceID,
              receipt.workspaceID == nil || receipt.workspaceID == workspace.id else { throw MobileConnectionError.invalidResponse }
        try await commandJournal.rememberReceipt(receipt, workspaceID: workspace.id)
        guard receipt.status == .accepted || receipt.status == .completed else {
            throw CompanionAPIError(code: "execution_unconfirmed", message: receipt.message ?? "The execution workspace has not confirmed this command. Its durable identity has been retained.")
        }
        // A failed refresh cannot turn an acknowledged command into a failed send.
        // The UI clears the draft after success and refreshes history independently.
        try? await refresh(conversationID: command.conversationID ?? "")
        return receipt
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
