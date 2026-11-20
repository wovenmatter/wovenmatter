import Foundation
import Observation

/// The sidebar's data across every machine: folders, sessions and notes, the
/// agents each machine offers, and Trash. Commands create, rename, move, pin,
/// archive and delete them, and start a session with an agent on a machine in
/// a folder.
@MainActor
@Observable
final class WorkspaceStore {
    /// Folders, sessions and notes of every machine; nil until the server has answered.
    private(set) var workspaceOverview: WorkspaceOverview?
    /// Every machine's agents. Each belongs to the machine that runs it.
    private(set) var agents: [WorkspaceAgent] = []
    private(set) var folderMutationError: String?
    private(set) var noteMutationError: String?
    /// Notes with a rename, move, export or trash in flight.
    private(set) var noteActionIDs: Set<String> = []

    init() {}

    func agents(on machineID: String) -> [WorkspaceAgent] {
        agents.filter { $0.machineID == machineID }
    }

    func agent(id: String?) -> WorkspaceAgent? {
        guard let id else { return nil }
        return agents.first { $0.id == id }
    }

    func folder(id: String?) -> WorkspaceFolderRecord? {
        guard let id else { return nil }
        return workspaceOverview?.folders.first { $0.id == id }
    }

    func folders(on machineID: String) -> [WorkspaceFolderRecord] {
        workspaceOverview?.folders.filter { $0.machineID == machineID } ?? []
    }

    func conversation(id: String?) -> WorkspaceConversationRecord? {
        guard let id else { return nil }
        return workspaceOverview?.conversations.first { $0.id == id }
    }

    /// Sessions with a turn running.
    var runningConversationIDs: Set<String> {
        Set(workspaceOverview?.conversations.filter { $0.activity == .working }.map(\.id) ?? [])
    }

    /// Asks the server for the whole overview again (File > Refresh Workspace).
    func refresh() async {}

    // MARK: Sessions

    /// Starts a session with `agent` on the machine that runs it, in `folderID`
    /// (which must belong to that machine), and returns the new session's id.
    func startSession(agent: WorkspaceAgent, folderID: String?) async throws -> String {
        throw ClientError.notConnected
    }

    func mutateConversation(id: String, mutation: WorkspaceConversationMutation) async throws {
        throw ClientError.notConnected
    }

    func markConversationRead(id: String) {}

    func exportConversation(id: String, format: WorkspaceConversationExportFormat) async throws -> URL {
        throw ClientError.notConnected
    }

    func trashedConversations() async throws -> [WorkspaceTrashedConversation] {
        throw ClientError.notConnected
    }

    // MARK: Notes

    /// Creates a note, page, sheet or app and returns its id; nil sets `noteMutationError`.
    func createNote(folderID: String?, kind: NoteArtifactKind) async -> String? {
        noteMutationError = ClientError.notConnected.localizedDescription
        return nil
    }

    func mutateNote(id: String, mutation: WorkspaceNoteMutation) async throws {
        throw ClientError.notConnected
    }

    func exportNote(id: String, format: WorkspaceNoteExportFormat = .standard) async throws -> WorkspaceNoteExport {
        throw ClientError.notConnected
    }

    func trashedNotes() async throws -> [WorkspaceTrashedNote] {
        throw ClientError.notConnected
    }

    func clearNoteMutationError() { noteMutationError = nil }

    // MARK: Folders

    /// Asks `machineID`'s server to create the folder on its own disk: a new
    /// directory, or `externalRoot` when linking an existing one. Returns its id;
    /// nil sets `folderMutationError`.
    func createFolder(name: String, machineID: String, externalRoot: URL?) async -> String? {
        folderMutationError = ClientError.notConnected.localizedDescription
        return nil
    }

    func renameFolder(id: String, name: String) async -> Bool { failFolderMutation() }

    func setFolderPinned(id: String, isPinned: Bool) async -> Bool { failFolderMutation() }

    func moveFolder(id: String, direction: WorkspaceFolderMoveDirection) async -> Bool { failFolderMutation() }

    func deleteFolder(id: String, deleteRoot: Bool) async -> Bool { failFolderMutation() }

    func setFolderReferencePaths(id: String, paths: [String]) async -> Bool { failFolderMutation() }

    /// The directories directly inside `path` on `machineID` (its home when nil),
    /// for linking an existing directory on another machine.
    func directories(on machineID: String, path: String?) async throws -> MachineDirectoryListing {
        throw ClientError.notConnected
    }

    func clearFolderMutationError() { folderMutationError = nil }

    private func failFolderMutation() -> Bool {
        folderMutationError = ClientError.notConnected.localizedDescription
        return false
    }
}

enum WorkspaceConversationMutation: Sendable {
    case setPinned(Bool)
    case rename(String)
    case moveToTrash
    case restore
}

enum WorkspaceConversationExportFormat: String, Sendable {
    case messages
    case fullRun

    var fileExtension: String { self == .messages ? "md" : "json" }

    func suggestedFilename(title: String) -> String {
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")
            .union(.controlCharacters)).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let basename = String(clean.prefix(100))
        return (basename.isEmpty ? "Chat" : basename)
            + (self == .fullRun ? "-full-run" : "-messages") + "." + fileExtension
    }
}

enum WorkspaceNoteMutation: Sendable {
    case setPinned(Bool)
    case rename(String)
    case moveToFolder(String?)
    case moveToTrash
    case restore
}

enum WorkspaceNoteExportFormat: String, Sendable {
    case standard
    case document
}

/// An exported note staged in a temporary file, ready to save where the person chooses.
struct WorkspaceNoteExport: Sendable {
    let url: URL
    let suggestedFilename: String
    let fileExtension: String
}

/// One directory on a machine and the directories inside it.
struct MachineDirectoryListing: Equatable, Sendable {
    struct Directory: Identifiable, Equatable, Sendable {
        let name: String
        let path: String
        var id: String { path }
    }

    let path: String
    let parent: String?
    let directories: [Directory]
    /// More directories exist than were listed.
    let truncated: Bool
}

enum ConversationSelection {
    /// The newest unarchived session not already open in a panel.
    static func mostRecentAvailableConversationID(
        in conversations: [WorkspaceConversationRecord],
        excluding excludedConversationIDs: Set<String>
    ) -> String? {
        conversations
            .filter { !$0.isArchived && !excludedConversationIDs.contains($0.id) }
            .max { ($0.lastMessageAt ?? .distantPast, $0.id) < ($1.lastMessageAt ?? .distantPast, $1.id) }?
            .id
    }
}
