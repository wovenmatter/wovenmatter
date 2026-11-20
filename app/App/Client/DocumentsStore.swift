import Foundation
import Observation
import WovenProtocol

/// Open notes, pages, sheets and apps: their documents, edits, version history, app state
/// and linked database rows. Every machine edits a document through its own
/// server; when two writers edit apart, the newer write wins and the other is
/// kept in the document's version history.
@MainActor
@Observable
final class DocumentsStore {
    /// Documents open in a pane, by note identifier.
    private(set) var notes: [String: OpenNote] = [:]
    /// App views whose inputs have edits not yet saved, by view generation.
    private var unsavedAppInputs: Set<String> = []
    /// An open App has input edits not saved yet, so quitting would lose them.
    var hasUnsavedAppInputs: Bool { !unsavedAppInputs.isEmpty }

    /// The stamp of the server's version each open document's edits are based on.
    @ObservationIgnored private var bases: [String: String] = [:]
    /// Edits made here and not yet sent, by note.
    @ObservationIgnored private var pending: [String: (title: String?, body: String?)] = [:]
    /// Notes with a write on its way to the server.
    @ObservationIgnored private var writing: Set<String> = []
    /// App state as the server last reported it, so a code edit never rewinds saved input.
    @ObservationIgnored private var serverAppState: [String: [String: ArtifactStateEntry]] = [:]
    @ObservationIgnored private var flushes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private weak var server: ServerConnection?
    @ObservationIgnored private weak var machines: MachinesStore?
    @ObservationIgnored private weak var databases: DatabasesStore?

    /// How long typing pauses before an edit is sent.
    private static let writeDelay = Duration.milliseconds(400)

    init() {}

    func attach(_ server: ServerConnection, machines: MachinesStore, databases: DatabasesStore) {
        self.server = server
        self.machines = machines
        self.databases = databases
    }

    private func connected() throws -> ServerConnection {
        guard let server, server.isConnected else { throw ClientError.notConnected }
        return server
    }

    // MARK: Reading

    /// Starts following a note's document.
    func open(_ note: WorkspaceNoteRecord) {
        guard notes[note.id] == nil else { return }
        notes[note.id] = OpenNote(title: note.title, content: Self.emptyContent(note.kind))
        Task { await load(note.id) }
    }

    func title(of note: WorkspaceNoteRecord) -> String {
        notes[note.id]?.title ?? note.title
    }

    /// The document JSON for `note`, or an empty document of its kind before it has loaded.
    func content(of note: WorkspaceNoteRecord) -> String {
        notes[note.id]?.content ?? Self.emptyContent(note.kind)
    }

    /// An App's saved state, as its document holds it.
    func appState(noteID: String) -> [String: ArtifactStateEntry] {
        guard let content = notes[noteID]?.content else { return [:] }
        return (try? NoteDocument.editableDocument(from: content))?.artifactState ?? [:]
    }

    /// Reads every open document again after the library changed, and shows
    /// the server's version of each one with no edit of this Mac's waiting.
    func reload() async {
        for id in notes.keys { await load(id) }
    }

    private func load(_ id: String) async {
        guard let server = try? connected(), let document = try? await server.call(ReadArtifact(artifactID: id)) else { return }
        // Before the first read, what is shown is a placeholder; the server's document replaces it.
        if bases[id] != nil { guard pending[id] == nil, !writing.contains(id) else { return } }
        pending[id] = nil
        adopt(document)
    }

    /// Shows the server's version of a document and bases later edits on it.
    private func adopt(_ document: ArtifactDocument) {
        let id = document.artifact.id
        bases[id] = document.artifact.stamp
        serverAppState[id] = (try? NoteDocument.editableDocument(from: document.body))?.artifactState
        let open = OpenNote(title: document.artifact.title, content: document.body)
        if notes[id] != open { notes[id] = open }
    }

    private static func emptyContent(_ kind: NoteArtifactKind) -> String {
        (try? NoteDocument(kind: kind).encoded()) ?? ""
    }

    // MARK: Editing

    /// Renames a note. The edit shows at once and goes to this Mac's server.
    func updateNote(id: String, title: String) {
        notes[id, default: OpenNote(title: "", content: "")].title = title
        pending[id, default: (nil, nil)].title = title
        scheduleWrite(id)
    }

    /// Replaces a note's document. The edit shows at once and goes to this Mac's server.
    func updateNote(id: String, content: String) {
        notes[id, default: OpenNote(title: "", content: "")].content = content
        pending[id, default: (nil, nil)].body = content
        scheduleWrite(id)
    }

    private func scheduleWrite(_ id: String) {
        flushes[id]?.cancel()
        flushes[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.writeDelay)
            guard !Task.isCancelled else { return }
            await self?.flush(id)
        }
    }

    /// Sends the note's waiting edits, one write at a time, each based on the
    /// version the previous write returned.
    func flush(_ id: String) async {
        flushes[id]?.cancel()
        flushes[id] = nil
        guard !writing.contains(id) else { return }
        writing.insert(id)
        defer { writing.remove(id) }
        while let edit = pending.removeValue(forKey: id) {
            guard let server = try? connected(), let base = bases[id] else {
                pending[id] = edit
                return
            }
            var body = edit.body
            // An App's saved input is written key by key; a whole-document edit keeps what the server has.
            if let text = body, let state = serverAppState[id], var document = try? NoteDocument.editableDocument(from: text),
               document.kind == .html, document.artifactState != state {
                document.artifactState = state
                body = (try? document.encoded()) ?? text
            }
            do {
                let written = try await server.call(WriteArtifact(artifactID: id, basedOn: base, title: edit.title, body: body))
                bases[id] = written.document.artifact.stamp
                serverAppState[id] = (try? NoteDocument.editableDocument(from: written.document.body))?.artifactState
                if pending[id] == nil { adopt(written.document) }
            } catch {
                // Kept for the next edit or reload rather than lost.
                if pending[id] == nil { pending[id] = edit } else {
                    pending[id] = (pending[id]?.title ?? edit.title, pending[id]?.body ?? edit.body)
                }
                flushes[id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    await self?.flush(id)
                }
                return
            }
        }
    }

    // MARK: Version history

    /// The retained versions, newest first.
    func versions(noteID: String) async throws -> [NoteVersion] {
        await flush(noteID)
        let server = try connected()
        var versions: [NoteVersion] = []
        for version in try await server.call(ListArtifactVersions(artifactID: noteID)) {
            let saved = try await server.call(ReadArtifactVersion(versionID: version.id))
            let source: NoteVersion.Source = switch version.reason {
            case .checkpoint: .checkpoint
            case .restore: .beforeRestore
            case .conflict: .otherMachine(machines?.machine(id: version.machineID)?.name ?? "another writer")
            }
            versions.append(NoteVersion(id: version.id, title: version.title, content: saved.body, savedAt: version.savedAt,
                                        source: source))
        }
        return versions
    }

    /// Makes a retained version current. The current document is kept as a version first.
    func restoreVersion(noteID: String, versionID: String) async throws {
        await flush(noteID)
        let restored = try await connected().call(RestoreArtifactVersion(artifactID: noteID, versionID: versionID))
        adopt(restored)
    }

    // MARK: Apps

    /// Writes one App state edit, after the previous write from the same view.
    func enqueueArtifactInput(noteID: String, edit: ArtifactStateEdit,
                              after previous: Task<ArtifactStateWriteResult, any Error>? = nil)
        -> Task<ArtifactStateWriteResult, any Error> {
        Task {
            if let previous { _ = try? await previous.value }
            let server = try connected()
            do {
                let result = try await server.call(EditAppState(artifactID: noteID, edits: [edit]))
                await load(noteID)
                return result
            } catch let error as ProtocolError where error.code == .conflict {
                let current = try? await server.call(ReadArtifact(artifactID: noteID))
                if let current, pending[noteID] == nil, !writing.contains(noteID) { adopt(current) }
                throw ArtifactInputFailure(
                    message: error.message,
                    snapshot: current.flatMap { try? NoteDocument.editableDocument(from: $0.body) }?.artifactStateSnapshot)
            } catch let error as ProtocolError {
                throw ArtifactInputFailure(message: error.message, snapshot: nil)
            }
        }
    }

    func setArtifactInputsUnsaved(generation: String, _ unsaved: Bool) {
        if unsaved { unsavedAppInputs.insert(generation) } else { unsavedAppInputs.remove(generation) }
    }

    // MARK: Linked data

    /// Reads the rows a database link asks for, from the owner or its latest published copy.
    func linkedData(for link: DatabaseArtifactLink) async throws -> DatabaseTabularData {
        guard let databases else { throw ClientError.notConnected }
        return try await databases.rows(for: link)
    }

    // MARK: Page tasks

    /// Asks the server to carry out what a Page task's assignees now say: start
    /// the session of each one being sent, and stop each one being stopped.
    /// The Page records the task and the session that runs it.
    func dispatchPageTask(noteID: String, taskID: String) {
        Task {
            await flush(noteID)
            guard let server = try? connected() else { return }
            _ = try? await server.call(DispatchPageTask(artifactID: noteID, taskID: taskID))
            await load(noteID)
        }
    }
}
