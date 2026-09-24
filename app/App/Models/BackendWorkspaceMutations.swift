import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

enum BackendWorkspaceMutation: Codable, Sendable {
    case saveSurfaceProfile(SurfaceProfile)
    case markConversationRead(id: String)
    case createFolder(name: String)
    case renameFolder(id: String, name: String)
    case pinFolder(id: String, isPinned: Bool)
    case moveFolder(id: String, up: Bool)
    case deleteFolder(id: String)
    case moveConversation(id: String, folderID: String?)
    case createNote(folderID: String?, kind: NoteArtifactKind)
    case persistNoteDraft(DashboardNoteJournalEntry)
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
        case let .createFolder(name):
            result.entityID = try await store.createFolder(name: name)
        case let .renameFolder(id, name):
            try await store.renameFolder(id: id, name: name)
        case let .pinFolder(id, pinned):
            try await store.setFolderPinned(id: id, isPinned: pinned)
        case let .moveFolder(id, up):
            result.accepted = try await store.moveFolder(id: id, direction: up ? .up : .down)
        case let .deleteFolder(id):
            try await store.deleteFolder(id: id)
        case let .moveConversation(id, folder):
            result.accepted = try await store.moveConversation(id: id, toFolderID: folder)
        case let .createNote(folder, kind):
            result.entityID = try await store.createNote(folderID: folder, kind: kind)
        case let .persistNoteDraft(entry):
            try store.database.persistNoteDraft(id: entry.noteID, title: entry.title, content: entry.content,
                                                folderID: entry.folderID, createdAt: entry.createdAt)
        }
        await model.refreshWorkspace()
        return result
    }
}
