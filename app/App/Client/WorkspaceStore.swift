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
    /// What the sessions that are not idle are doing, as each connected
    /// machine's server reports its own.
    @ObservationIgnored private var runStateFollowers: [ObjectIdentifier: RunStateFollower] = [:]

    /// One machine's `SubscribeRunStates`, kept open on its connection.
    private struct RunStateFollower {
        let connection: ServerConnection
        let task: Task<Void, Never>
        var states: [String: SessionRunState] = [:]
    }

    init() {}

    func attach(_ server: ServerConnection, machines: MachinesStore) {
        self.server = server
        self.machines = machines
        for follower in runStateFollowers.values { follower.task.cancel() }
        runStateFollowers = [:]
        followRunStates()
        machines.connections?.whenChanged { [weak self] in self?.followRunStates() }
        followRuntimeNames()
    }

    /// Follows `SubscribeRunStates` on every machine's connection, and drops
    /// a machine's states while its connection is down.
    private func followRunStates() {
        let connections = machines?.connections?.all ?? []
        let current = Set(connections.map(ObjectIdentifier.init))
        for (id, follower) in runStateFollowers where !current.contains(id) {
            follower.task.cancel()
            runStateFollowers[id] = nil
        }
        for connection in connections {
            let id = ObjectIdentifier(connection)
            if !connection.isConnected { runStateFollowers[id]?.states = [:] }
            guard runStateFollowers[id] == nil else { continue }
            let task = Task { [weak self] in
                await connection.follow(SubscribeRunStates(), reply: { [weak self] states in
                    self?.runStateFollowers[id]?.states = Dictionary(states.map { ($0.sessionID, $0) }, uniquingKeysWith: { $1 })
                    self?.applyRunStates()
                }, event: { [weak self] state in
                    self?.runStateFollowers[id]?.states[state.sessionID] = state
                    self?.applyRunStates()
                })
            }
            runStateFollowers[id] = RunStateFollower(connection: connection, task: task)
        }
        applyRunStates()
    }

    private func runState(_ sessionID: String) -> SessionRunState? {
        for follower in runStateFollowers.values { if let state = follower.states[sessionID] { return state } }
        return nil
    }

    /// Names runtimes again when this Mac's server reports its runtimes, which
    /// it may do after the sessions were listed.
    private func followRuntimeNames() {
        withObservationTracking { _ = machines?.machineRuntimes } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if var overview = workspaceOverview {
                    for index in overview.conversations.indices {
                        overview.conversations[index].runtimeName = runtimeName(overview.conversations[index].runtime)
                    }
                    if overview != workspaceOverview { workspaceOverview = overview }
                }
                followRuntimeNames()
            }
        }
    }

    /// Sets each listed session's activity from its owner's run states. A
    /// machine the UI is not connected to shows its sessions idle.
    private func applyRunStates() {
        guard var overview = workspaceOverview else { return }
        for index in overview.conversations.indices {
            overview.conversations[index].activity = Self.activity(runState(overview.conversations[index].id))
        }
        if overview != workspaceOverview { workspaceOverview = overview }
    }

    private static func activity(_ state: SessionRunState?) -> SessionActivity {
        guard let state, state.run == .running else { return .idle }
        return state.awaiting ? .blocked : .working
    }

    /// The server for a command on something `machineID` owns: this Mac's for
    /// its own things and for nil, else the UI's direct connection to the owner.
    func server(for machineID: String?) throws -> ServerConnection {
        guard let server, server.isConnected else { throw ClientError.notConnected }
        guard let machineID, machineID != machines?.thisMachine?.id else { return server }
        guard let owner = machines?.connection(for: machineID) else {
            throw ClientError.machineNotConnected(machines?.machine(id: machineID)?.name ?? "That machine")
        }
        return owner
    }

    /// The connection to the server that owns the session, connected or not;
    /// nil while the session's owner is not known or has no address yet.
    func ownerConnection(ofSession sessionID: String, ownerID: String? = nil) -> ServerConnection? {
        guard let machineID = ownerID ?? conversation(id: sessionID)?.machineID else { return nil }
        return machines?.connections?.connection(for: machineID)
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
            // Bot chats and Forum rooms show only in the bots' own surfaces.
            let sessions = try await server.call(ListSessions(includeArchived: true)).filter { $0.runtime != .bots }
            workspaceOverview = WorkspaceOverview(
                folders: folders.map { folder in
                    WorkspaceFolderRecord(id: folder.id, name: folder.name, icon: nil, position: folder.position,
                                          isPinned: folder.pinned, machineID: folder.machineID, rootPath: folder.path,
                                          managedRoot: folder.managed, referencePaths: folder.references)
                },
                conversations: sessions.map(record),
                notes: (try? await server.call(ListArtifacts()).map(Self.noteRecord)) ?? workspaceOverview?.notes ?? [])
        } catch {
            folderMutationError = error.localizedDescription
        }
    }

    private func record(_ session: Session) -> WorkspaceConversationRecord {
        let kind = AgentRuntimeKind(runtime: session.runtime)
        return WorkspaceConversationRecord(
            id: session.id, machineID: session.machineID,
            agentID: kind.map { WorkspaceAgent.id(machineID: session.machineID, runtime: $0) }, runtimeKind: kind,
            runtime: session.runtime, runtimeName: runtimeName(session.runtime),
            title: session.title, unread: session.unread, lastMessagePreview: session.preview,
            lastMessageAt: session.lastActivityAt, isScheduledTask: false, folderID: session.folderID,
            isPinned: session.pinned, isArchived: session.archived, activity: Self.activity(runState(session.id)))
    }

    /// A runtime's name: the UI's own for the runtimes it offers, else the
    /// name a machine's server gives it (the dev instance's stand-in, say).
    private func runtimeName(_ runtime: RuntimeKind) -> String {
        if let kind = AgentRuntimeKind(runtime: runtime) { return kind.displayName }
        if runtime == .bots { return "Bots" }
        return machines?.machineRuntimes.values.joined().first { $0.runtime == runtime }?.name ?? runtime.rawValue
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

    /// Sessions sync newest-wins, so this Mac's server writes these whichever
    /// machine owns the session; the owner's server takes them in by sync.
    func mutateConversation(id: String, mutation: WorkspaceConversationMutation) async throws {
        let server = try server(for: nil)
        switch mutation {
        case .setPinned(let pinned): _ = try await server.call(UpdateSession(sessionID: id, pinned: pinned))
        case .rename(let title): _ = try await server.call(UpdateSession(sessionID: id, title: title))
        case .moveToTrash: _ = try await server.call(UpdateSession(sessionID: id, archived: true))
        case .restore: _ = try await server.call(UpdateSession(sessionID: id, archived: false))
        case .moveToFolder(let folderID):
            _ = try await server.call(UpdateSession(sessionID: id, folderID: folderID, removeFromFolder: folderID == nil))
        case .delete: _ = try await server.call(DeleteSession(sessionID: id))
        }
        await refresh()
    }

    /// Records that the person has seen everything in the session so far,
    /// when it shows as unread.
    func markConversationRead(id: String) {
        guard let index = workspaceOverview?.conversations.firstIndex(where: { $0.id == id }),
              workspaceOverview?.conversations[index].unread == true, let server = try? server(for: nil) else { return }
        workspaceOverview?.conversations[index].unread = false
        Task {
            do {
                _ = try await server.call(UpdateSession(sessionID: id, read: true))
            } catch {
                await refresh()
            }
        }
    }

    /// The chat as a file staged for saving: its messages as Markdown, or
    /// the session with every saved item as JSON. Items come from this Mac's
    /// library, so a chat whose owner is away exports too.
    func exportConversation(id: String, format: WorkspaceConversationExportFormat) async throws -> URL {
        let server = try server(for: nil)
        guard let session = try await server.call(ListSessions(includeArchived: true)).first(where: { $0.id == id }) else {
            throw ProtocolError(.notFound, "No chat \(id).")
        }
        var items: [SessionItem] = []
        while true {
            let page = try await server.call(SessionItems(sessionID: id, afterSequence: items.last?.sequence ?? 0, limit: 1000))
            items += page
            if page.count < 1000 { break }
        }
        let data: Data
        switch format {
        case .messages:
            let dates = ISO8601DateFormatter()
            var sections = ["# " + session.title]
            for item in items {
                let role: String, text: String, attachments: [Attachment]
                switch item.content {
                case .userMessage(let body, let files): (role, text, attachments) = ("User", body, files)
                case .assistantMessage(let body): (role, text, attachments) = ("Assistant", body, [])
                default: continue
                }
                var section = "## \(role) · \(dates.string(from: item.createdAt))\n\n\(text)"
                for file in attachments {
                    section += "\n\nAttachment: \(file.name) (\(file.mimeType), \(file.size) bytes)"
                }
                sections.append(section)
            }
            data = Data((sections.joined(separator: "\n\n") + "\n").utf8)
        case .fullRun:
            struct FullRun: Encodable {
                let exportedAt: Date
                let session: Session
                let items: [SessionItem]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(FullRun(exportedAt: Date(), session: session, items: items))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("woven-export-\(UUID().uuidString)")
            .appendingPathExtension(format.fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Chats in Trash, most recently trashed first.
    func trashedConversations() async throws -> [WorkspaceTrashedConversation] {
        try await server(for: nil).call(ListSessions(includeArchived: true)).filter { $0.archived && $0.runtime != .bots }.map {
            WorkspaceTrashedConversation(id: $0.id, title: $0.title, trashedAt: $0.archivedAt ?? $0.createdAt)
        }.sorted { ($0.trashedAt, $0.id) > ($1.trashedAt, $1.id) }
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
        }.sorted { ($0.trashedAt, $0.id) > ($1.trashedAt, $1.id) }
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
        await folderMutation(id) { try await $0.call(UpdateFolder(folderID: id, name: name)) }
    }

    /// Pinning and order are the person's, so this Mac's server writes them
    /// whichever machine owns the folder.
    func setFolderPinned(id: String, isPinned: Bool) async -> Bool {
        await folderMutation(id, onOwner: false) { try await $0.call(UpdateFolder(folderID: id, pinned: isPinned)) }
    }

    /// Swaps the folder with its neighbour among its machine's pinned or other
    /// folders, then numbers that machine's folders in the order shown.
    func moveFolder(id: String, direction: WorkspaceFolderMoveDirection) async -> Bool {
        guard let folder = folder(id: id) else { return false }
        let sections = FolderSections(folders: folders(on: folder.machineID))
        var pinned = sections.pinned, unpinned = sections.unpinned
        func swap(_ group: inout [WorkspaceFolderRecord]) -> Bool {
            guard let index = group.firstIndex(where: { $0.id == id }) else { return false }
            let target = direction == .up ? index - 1 : index + 1
            guard group.indices.contains(target) else { return false }
            group.swapAt(index, target)
            return true
        }
        guard folder.isPinned ? swap(&pinned) : swap(&unpinned) else { return false }
        let moves = (pinned + unpinned).enumerated().filter { $1.position != $0 }
        return await folderMutation(id, onOwner: false) { server in
            for (position, folder) in moves {
                _ = try await server.call(UpdateFolder(folderID: folder.id, position: position))
            }
        }
    }

    /// Removes the folder from every library. With `deleteRoot`, its owner's
    /// server also deletes the directory it made for it; a linked directory stays.
    func deleteFolder(id: String, deleteRoot: Bool) async -> Bool {
        await folderMutation(id) { try await $0.call(DeleteFolder(folderID: id, deleteDirectory: deleteRoot)) }
    }

    /// Other directories of the folder's machine its agents may use; the owner's server keeps them.
    func setFolderReferencePaths(id: String, paths: [String]) async -> Bool {
        await folderMutation(id) { try await $0.call(UpdateFolder(folderID: id, references: paths)) }
    }

    /// The directories directly inside `path` on `machineID` (its home when nil),
    /// for linking an existing directory on another machine. Its own server lists them.
    func directories(on machineID: String, path: String?) async throws -> MachineDirectoryListing {
        let listing = try await server(for: machineID).call(ListDirectories(path: path))
        return MachineDirectoryListing(
            path: listing.path, parent: listing.parent,
            directories: listing.directories.map { MachineDirectoryListing.Directory(name: $0.name, path: $0.path) },
            truncated: listing.truncated)
    }

    func clearFolderMutationError() { folderMutationError = nil }

    /// Runs `body` on the folder's owner's server, or this Mac's when `onOwner` is false.
    private func folderMutation<T>(_ id: String, onOwner: Bool = true,
                                   _ body: (ServerConnection) async throws -> T) async -> Bool {
        do {
            _ = try await body(try server(for: onOwner ? folder(id: id)?.machineID : nil))
            folderMutationError = nil
            await refresh()
            return true
        } catch {
            folderMutationError = error.localizedDescription
            return false
        }
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
