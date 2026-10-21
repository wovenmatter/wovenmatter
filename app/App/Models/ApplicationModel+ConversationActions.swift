import Foundation
import WovenMatterCore

extension ApplicationModel {
    func mutateConversation(id: String, mutation: WorkspaceConversationMutation) async throws {
        if let client = liveLibraryClient, client.isForeignConversation(id) {
            let action: String
            var title: String?
            switch mutation {
            case .rename(let value): action = "rename"; title = value
            case .setPinned(let value): action = value ? "pin" : "unpin"
            case .moveToTrash: action = "trash"
            case .restore: action = "restore"
            }
            guard await client.perform(.conversation(id: id, action: action, title: title, folderID: nil)) else {
                throw WorkspaceToolError.invalid(client.errorMessage ?? "The library could not save this change.")
            }
        } else if isBackendFrontend {
            _ = try await sendBackendCommand(.workspaceMutation(.conversation(id: id, mutation: mutation)))
        } else {
            guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
            let trashing: Bool = if case .moveToTrash = mutation { true } else { false }
            if trashing { try beginConversationTrash(id: id) }
            defer { if trashing { finishConversationTrash(id: id) } }
            try await dashboardStore.mutateConversation(id: id, mutation: mutation)
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
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        return try await dashboardStore.trashedConversations()
    }

    func exportConversation(id: String, format: WorkspaceConversationExportFormat) async throws -> URL {
        if let client = liveLibraryClient, client.isForeignConversation(id) {
            return try await client.exportFile(.exportConversation(id: id, format: format.rawValue))
        }
        if isBackendFrontend {
            guard let url = try await sendBackendCommand(.exportConversation(id: id, format: format)).exportURL else {
                throw WorkspaceConversationActionError.unavailable
            }
            return url
        }
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        return try await dashboardStore.exportConversation(id: id, format: format)
    }
}
