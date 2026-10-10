import Foundation
import Observation
import Security
import CompanionClient
import WovenMatterCore
import WovenMatterDashboardStore

/// The authoritative Mac is also a client of foreign execution owners. It imports
/// immutable history into its existing database and never starts a local runtime
/// merely because an imported conversation has the same harness name.
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
    private var transportEndpoints: [String: URL] = [:]
    private var refreshTasks: [String: Task<Void, any Error>] = [:]
    private(set) var workspaceByConversation: [String: CompanionExecutionWorkspace] = [:]
    private(set) var transcripts: [String: CompanionTranscript] = [:]
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
        let descriptor = try await database.companionConversationExecutionWorkspace(conversationID: conversationID)
        if let descriptor { workspaceByConversation[conversationID] = descriptor }
        else { workspaceByConversation.removeValue(forKey: conversationID) }
        return descriptor
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
            transcripts[conversationID] = transcript
            capabilities[conversationID] = try await transport.capabilities(conversationID)
            pending[descriptor.id] = try await transport.pending()
            onlineWorkspaces.insert(descriptor.id); errors.removeValue(forKey: descriptor.id)
        } catch {
            if case MobileConnectionError.revoked = error { transports.removeValue(forKey: descriptor.id) }
            onlineWorkspaces.remove(descriptor.id); errors[descriptor.id] = error.localizedDescription
            // Keep the last projection visible when its execution owner is offline.
            if transcripts[conversationID] == nil { transcripts[conversationID] = try? await database.companionFederatedTranscript(conversationID: conversationID) }
            throw error
        }
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
        let remote = try await transport.identity()
        guard remote.id == workspace.id, remote.libraryID == identity.libraryID else { throw MobileStore.Failure.wrongWorkspace }
        try saveCredential(credential)
        transports[workspace.id] = transport; transportEndpoints[workspace.id] = remote.endpoint
        return transport
    }

    private func replay(workspace: CompanionExecutionWorkspace) async throws {
        let identity = try await database.companionLibraryIdentity()
        let transport = try await transport(for: workspace)
        for _ in 0..<100 {
            let cursor = try await database.companionExecutionOriginCursor(workspaceID: workspace.id)
            let page = try await transport.events(after: cursor)
            guard page.libraryID == identity.libraryID, page.cursor == cursor + Int64(page.entries.count),
                  !page.hasMore || !page.entries.isEmpty else { throw WorkspaceJournal.Failure.replayGap }
            for (index, entry) in page.entries.enumerated() {
                guard entry.workspaceID == workspace.id, entry.originSequence == cursor + Int64(index) + 1 else { throw WorkspaceJournal.Failure.replayGap }
            }
            // A concurrent phone relay may already have inserted these events.
            // Central ingestion compares their identities and bytes atomically.
            var offset = 0
            while offset < page.entries.count {
                var batch: [CompanionJournalEntry] = [], bytes = 0
                for entry in page.entries.dropFirst(offset).prefix(CompanionFederationProtocol.maximumBatchEntries) {
                    let size = try JSONEncoder().encode(entry).count
                    if !batch.isEmpty && bytes + size > 7 * 1_024 * 1_024 { break }
                    batch.append(entry); bytes += size
                }
                _ = try await database.ingestCompanionJournal(.init(libraryID: identity.libraryID, entries: batch), deviceID: identity.hostDeviceID)
                offset += batch.count
            }
            if !page.hasMore { break }
        }
        await onChange()
    }

    @discardableResult
    func send(conversationID: String, text: String, expectedRunID: String? = nil) async throws -> CompanionCommandReceipt {
        let workspace = try await requiredWorkspace(conversationID)
        let identity = try await database.companionLibraryIdentity()
        let kind: CompanionCommand.Kind = expectedRunID == nil ? .send : .steer
        let existing = await commandJournal.commandRecords(workspaceID: workspace.id).first {
            ($0.receipt == nil || $0.receipt?.status == .outcomeUnknown) && $0.command.kind == kind &&
            $0.command.conversationID == conversationID && $0.command.text == text && $0.command.runID == expectedRunID
        }
        let command = existing?.command ?? CompanionCommand(deviceID: identity.hostDeviceID, kind: kind,
            conversationID: conversationID, runID: expectedRunID, text: text, libraryID: identity.libraryID, workspaceID: workspace.id)
        return try await submit(command, workspace: workspace)
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
        let workspace = try await requiredWorkspace(conversationID)
        return try await transport(for: workspace).transcript(conversationID, before: before)
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
    private func submit(_ requested: CompanionCommand, workspace: CompanionExecutionWorkspace) async throws -> CompanionCommandReceipt {
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
        else { receipt = try await transport.command(command) }
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
