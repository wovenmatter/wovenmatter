import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

enum BackendWorkspaceMutation: Codable, Sendable {
    case saveSurfaceProfile(SurfaceProfile)
    case markConversationRead(id: String)
    case createFolder(name: String, workspaceID: UUID?, externalRoot: URL?)
    case renameFolder(id: String, name: String)
    case pinFolder(id: String, isPinned: Bool)
    case moveFolder(id: String, up: Bool)
    case deleteFolder(id: String, deleteRoot: Bool)
    case folderReferences(id: String, paths: [String])
    case conversation(id: String, mutation: WorkspaceConversationMutation)
    case note(id: String, mutation: WorkspaceNoteMutation, expectedRevision: String)
    case moveConversation(id: String, folderID: String?)
    case createNote(folderID: String?, kind: NoteArtifactKind)
    case persistNoteDraft(DashboardNoteJournalEntry)
    case checkpointNote(id: String)
    case restoreNote(id: String, versionID: String, expectedRevision: String)
}

extension BackendApplicationService {
    func executeWorkspaceMutation(_ mutation: BackendWorkspaceMutation) async throws -> BackendApplicationResult {
        guard let store = model.dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        var result = BackendApplicationResult()
        switch mutation {
        case .saveSurfaceProfile(let profile):
            result.surfaceProfile = try await model.saveAuthoritativeSurfaceProfile(profile)
            await invalidations.publish(scopes: [.settings])
            return result
        case let .markConversationRead(id):
            result.accepted = try await store.markConversationRead(id: id)
        case let .createFolder(name, workspaceID, externalRoot):
            result.entityID = await model.createFolder(name: name, workspaceID: workspaceID, externalRoot: externalRoot)
            if result.entityID == nil { throw BackendRPCError.remote(model.folderMutationError ?? "Folder creation failed.") }
        case let .renameFolder(id, name):
            try await store.renameFolder(id: id, name: name)
        case let .pinFolder(id, pinned):
            try await store.setFolderPinned(id: id, isPinned: pinned)
        case let .moveFolder(id, up):
            result.accepted = try await store.moveFolder(id: id, direction: up ? .up : .down)
        case let .deleteFolder(id, deleteRoot):
            result.accepted = await model.deleteFolder(id: id, deleteRoot: deleteRoot)
            if !result.accepted { throw BackendRPCError.remote(model.folderMutationError ?? "Folder deletion failed.") }
        case let .folderReferences(id, paths):
            result.accepted = await model.setFolderReferencePaths(id: id, paths: paths)
        case let .conversation(id, mutation):
            try await model.mutateConversation(id: id, mutation: mutation)
        case let .note(id, mutation, revision):
            try await store.mutateNote(id: id, mutation: mutation, expectedRevision: revision)
        case let .moveConversation(id, folder):
            result.accepted = await model.moveConversation(id: id, toFolderID: folder)
            if !result.accepted { throw BackendRPCError.remote(model.folderMutationError ?? "The draft folder could not be changed.") }
        case let .createNote(folder, kind):
            result.entityID = try await store.createNote(folderID: folder, kind: kind)
        case let .checkpointNote(id):
            try await store.database.checkpointNote(id: id)
        case let .restoreNote(id, version, revision):
            result.noteResponse = try await store.database.restoreNoteAssetVersion(noteID: id, versionID: version, expectedRevision: revision)
        case let .persistNoteDraft(entry):
            try await store.database.persistNoteDraft(id: entry.noteID, title: entry.title, content: entry.content,
                                                folderID: entry.folderID, createdAt: entry.createdAt)
        }
        await model.refreshWorkspace()
        return result
    }
}
