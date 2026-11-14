import Foundation
import WovenMatterCore

extension ApplicationModel {
    func mutateConversation(id: String, mutation: WorkspaceConversationMutation) async throws {
        if isBackendFrontend {
            _ = try await sendBackendCommand(.workspaceMutation(.conversation(id: id, mutation: mutation)))
        } else if !mutation.isPresentationOnly, try await pairedOwnerWorkspace(conversationID: id) != nil {
            // Trash and restore change another Mac's running work; that Mac
            // validates and applies them itself. Rename and pin stay shared.
            let action: String = if case .moveToTrash = mutation { "trash" } else { "restore" }
            try await performOnOwner(conversationID: id, action: .conversation(id: id, action: action, title: nil, folderID: nil))
        } else {
            guard let libraryStore else { throw ApplicationModelError.libraryStoreUnavailable }
            let trashing: Bool = if case .moveToTrash = mutation { true } else { false }
            if trashing { try beginConversationTrash(id: id) }
            defer { if trashing { finishConversationTrash(id: id) } }
            try await libraryStore.mutateConversation(id: id, mutation: mutation)
        }
        await refreshWorkspace()
        if LocalExecutionRole.current != .backend {
            await analytics.record(.active)
        }
    }

    func trashedConversations() async throws -> [WorkspaceTrashedConversation] {
        if isBackendFrontend {
            guard let conversations = try await sendBackendCommand(.trashedConversations).trashedConversations else {
                throw WorkspaceConversationActionError.unavailable
            }
            return conversations
        }
        guard let libraryStore else { throw ApplicationModelError.libraryStoreUnavailable }
        return try await libraryStore.trashedConversations()
    }

    func exportConversation(id: String, format: WorkspaceConversationExportFormat) async throws -> URL {
        if isBackendFrontend {
            guard let url = try await sendBackendCommand(.exportConversation(id: id, format: format)).exportURL else {
                throw WorkspaceConversationActionError.unavailable
            }
            return url
        }
        guard let libraryStore else { throw ApplicationModelError.libraryStoreUnavailable }
        return try await libraryStore.exportConversation(id: id, format: format)
    }

    /// The execution workspace of the paired Mac that runs this chat, when it
    /// is another Mac. Independent Linux and iOS workspaces are not included.
    func pairedOwnerWorkspace(conversationID id: String) async throws -> ExecutionWorkspace? {
        guard let database = libraryStore?.database,
              let workspace = try await database.libraryConversationExecutionWorkspace(conversationID: id), workspace.kind == .mac,
              try await workspace.ownerDeviceID != database.libraryIdentity().hostDeviceID else { return nil }
        return workspace
    }

    /// Sends a chat action to the Mac that runs it and surfaces its refusal.
    func performOnOwner(conversationID id: String, action: LibraryWorkspaceAction) async throws {
        let receipt = try await memberExecutionClient().perform(conversationID: id, action: action)
        if receipt.status == .rejected {
            throw LibraryAPIError(code: "rejected", message: receipt.message ?? WorkspaceConversationActionError.ownedByAnotherMac.localizedDescription)
        }
    }
}
