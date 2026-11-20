import Foundation
import Observation
import WovenProtocol

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
    var agents: [WorkspaceAgent] { machines?.agents ?? [] }
    private(set) var folderMutationError: String?
    private(set) var noteMutationError: String?
    /// Notes with a rename, move, export or trash in flight.
    private(set) var noteActionIDs: Set<String> = []

    @ObservationIgnored private weak var server: ServerConnection?
    @ObservationIgnored private weak var machines: MachinesStore?

    init() {}

    func attach(_ server: ServerConnection, machines: MachinesStore) {
        self.server = server
        self.machines = machines
    }

    /// This Mac's server, for a command on something `machineID` owns. Only
    /// this Mac's server is connected so far; another machine's things wait
    /// for a direct connection to it.
    private func server(for machineID: String?) throws -> ServerConnection {
        guard let server, server.isConnected else { throw ClientError.notConnected }
        if let machineID, machineID != machines?.thisMachine?.id {
            throw ClientError.machineNotConnected(machines?.machine(id: machineID)?.name ?? "That machine")
        }
        return server
    }

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
    func refresh() async {
        guard let server else { return }
        do {
            let folders = try await server.call(ListFolders())
            let sessions = try await server.call(ListSessions(includeArchived: true))
            let positions = Dictionary(uniqueKeysWithValues: folders.enumerated().map { ($1.id, $0) })
            workspaceOverview = WorkspaceOverview(
                folders: folders.map { folder in
                    WorkspaceFolderRecord(id: folder.id, name: folder.name, icon: nil, position: positions[folder.id] ?? 0,
                                          isPinned: false, machineID: folder.machineID, rootPath: folder.path,
                                          managedRoot: false, referencePaths: [])
                },
                conversations: sessions.map(Self.record),
                notes: (try? await server.call(ListArtifacts()).map(Self.noteRecord)) ?? workspaceOverview?.notes ?? [])
        } catch {
            folderMutationError = error.localizedDescription
        }
    }

    private static func record(_ session: Session) -> WorkspaceConversationRecord {
        let kind = AgentRuntimeKind(runtime: session.runtime)
        return WorkspaceConversationRecord(
            id: session.id, machineID: session.machineID,
            agentID: kind.map { WorkspaceAgent.id(machineID: session.machineID, runtime: $0) }, runtimeKind: kind,
            title: session.title, unread: false, lastMessagePreview: nil, lastMessageAt: session.createdAt,
            isScheduledTask: false, folderID: session.folderID, isPinned: false, isArchived: session.archived,
            activity: .idle)
    }

    // MARK: Sessions

    /// Starts a session with `agent` on the machine that runs it, in `folderID`
    /// (which must belong to that machine), and returns the new session's id.
    func startSession(agent: WorkspaceAgent, folderID: String?) async throws -> String {
        try await startSession(runtime: agent.runtimeKind.runtime, on: agent.machineID, folderID: folderID)
    }

    /// Starts a session with any runtime the machine's server offers.
    func startSession(runtime: RuntimeKind, on machineID: String, folderID: String?) async throws -> String {
        let session = try await server(for: machineID).call(CreateSession(runtime: runtime, title: "New Chat", folderID: folderID))
        await refresh()
        return session.id
    }

    func mutateConversation(id: String, mutation: WorkspaceConversationMutation) async throws {
        let server = try server(for: conversation(id: id)?.machineID)
        switch mutation {
        case .setPinned: throw ClientError.notOffered("Pinning chats")
        case .rename(let title): _ = try await server.call(UpdateSession(sessionID: id, title: title))
        case .moveToTrash: _ = try await server.call(UpdateSession(sessionID: id, archived: true))
        case .restore: _ = try await server.call(UpdateSession(sessionID: id, archived: false))
        case .moveToFolder(let folderID):
            _ = try await server.call(UpdateSession(sessionID: id, folderID: folderID, removeFromFolder: folderID == nil))
        case .delete: _ = try await server.call(DeleteSession(sessionID: id))
        }
        await refresh()
    }

    func markConversationRead(id: String) {}

    func exportConversation(id: String, format: WorkspaceConversationExportFormat) async throws -> URL {
        throw ClientError.notConnected
    }

    /// Archived chats.
    func trashedConversations() async throws -> [WorkspaceTrashedConversation] {
        try await server(for: nil).call(ListSessions(includeArchived: true)).filter(\.archived).map {
            WorkspaceTrashedConversation(id: $0.id, title: $0.title, trashedAt: $0.createdAt)
        }
    }

    // MARK: Notes

    /// Creates a note, page, sheet or app and returns its id; nil sets `noteMutationError`.
    func createNote(folderID: String?, kind: NoteArtifactKind) async -> String? {
        do {
            let created = try await server(for: nil).call(CreateArtifact(kind: kind, folderID: folderID))
            noteMutationError = nil
            await refresh()
            return created.artifact.id
        } catch {
            noteMutationError = error.localizedDescription
            return nil
        }
    }

    func mutateNote(id: String, mutation: WorkspaceNoteMutation) async throws {
        let server = try server(for: nil)
        noteActionIDs.insert(id)
        defer { noteActionIDs.remove(id) }
        switch mutation {
        case .setPinned(let pinned): _ = try await server.call(UpdateArtifact(artifactID: id, pinned: pinned))
        case .rename(let title): _ = try await server.call(UpdateArtifact(artifactID: id, title: title))
        case .moveToFolder(let folderID):
            _ = try await server.call(UpdateArtifact(artifactID: id, folderID: folderID, removeFromFolder: folderID == nil))
        case .moveToTrash: _ = try await server.call(UpdateArtifact(artifactID: id, trashed: true))
        case .restore: _ = try await server.call(UpdateArtifact(artifactID: id, trashed: false))
        case .delete: _ = try await server.call(DeleteArtifact(artifactID: id))
        }
        await refresh()
    }

    /// The artifact as a file: a note as Markdown, a sheet as CSV, an app as
    /// HTML, a page as its document; `.document` is always the document.
    func exportNote(id: String, format: WorkspaceNoteExportFormat = .standard) async throws -> WorkspaceNoteExport {
        let artifact = try await server(for: nil).call(ReadArtifact(artifactID: id))
        let (data, fileExtension) = try NoteExportFile.contents(of: NoteDocument.decode(artifact.body),
                                                                title: artifact.artifact.title, format: format)
        let name = NoteExportFile.basename(artifact.artifact.title)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("woven-export-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return WorkspaceNoteExport(url: url, suggestedFilename: name + "." + fileExtension, fileExtension: fileExtension)
    }

    func trashedNotes() async throws -> [WorkspaceTrashedNote] {
        try await server(for: nil).call(ListArtifacts(includeTrashed: true)).filter(\.trashed).map {
            WorkspaceTrashedNote(id: $0.id, title: $0.title, kind: $0.kind, trashedAt: $0.updatedAt)
        }
    }

    private static func noteRecord(_ artifact: Artifact) -> WorkspaceNoteRecord {
        WorkspaceNoteRecord(id: artifact.id, folderID: artifact.folderID, title: artifact.title, kind: artifact.kind,
                            isPinned: artifact.pinned, createdAt: artifact.createdAt, updatedAt: artifact.updatedAt,
                            preview: artifact.preview)
    }

    func clearNoteMutationError() { noteMutationError = nil }

    // MARK: Folders

    /// Asks `machineID`'s server to create the folder on its own disk: a new
    /// directory, or `externalRoot` when linking an existing one. Returns its id;
    /// nil sets `folderMutationError`.
    func createFolder(name: String, machineID: String, externalRoot: URL?) async -> String? {
        do {
            let folder = try await server(for: machineID).call(CreateFolder(name: name, path: externalRoot?.path))
            folderMutationError = nil
            await refresh()
            return folder.id
        } catch {
            folderMutationError = error.localizedDescription
            return nil
        }
    }

    func renameFolder(id: String, name: String) async -> Bool {
        await folderMutation(id) { try await $0.call(RenameFolder(folderID: id, name: name)) }
    }

    func setFolderPinned(id: String, isPinned: Bool) async -> Bool { failFolderMutation(.notOffered("Pinning folders")) }

    func moveFolder(id: String, direction: WorkspaceFolderMoveDirection) async -> Bool {
        failFolderMutation(.notOffered("Ordering folders"))
    }

    /// Removes the folder from every library. Its directory stays on disk.
    func deleteFolder(id: String, deleteRoot: Bool) async -> Bool {
        await folderMutation(id) { try await $0.call(DeleteFolder(folderID: id)) }
    }

    func setFolderReferencePaths(id: String, paths: [String]) async -> Bool {
        failFolderMutation(.notOffered("Reference directories"))
    }

    /// The directories directly inside `path` on `machineID` (its home when nil),
    /// for linking an existing directory on another machine.
    func directories(on machineID: String, path: String?) async throws -> MachineDirectoryListing {
        throw ClientError.notOffered("Browsing another machine's directories")
    }

    func clearFolderMutationError() { folderMutationError = nil }

    private func folderMutation<T>(_ id: String, _ body: (ServerConnection) async throws -> T) async -> Bool {
        do {
            _ = try await body(try server(for: folder(id: id)?.machineID))
            folderMutationError = nil
            await refresh()
            return true
        } catch {
            folderMutationError = error.localizedDescription
            return false
        }
    }

    private func failFolderMutation(_ error: ClientError) -> Bool {
        folderMutationError = error.localizedDescription
        return false
    }
}

enum WorkspaceConversationMutation: Sendable {
    case setPinned(Bool)
    case rename(String)
    case moveToTrash
    case restore
    /// Into a folder of the session's machine, or out of its folder with nil.
    case moveToFolder(String?)
    /// Deletes the session and its transcript from every library.
    case delete
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
    /// Deletes it and its history for good, in every library.
    case delete
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
