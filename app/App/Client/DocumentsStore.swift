import Foundation
import Observation

/// Open notes, pages and apps: their documents, edits, version history, app state
/// and linked database rows. Every machine edits a document through its own
/// server ("update note"); when two machines edit apart, the newer write wins and
/// the other is kept in the document's version history.
@MainActor
@Observable
final class DocumentsStore {
    /// Documents open in a pane, by note identifier.
    private(set) var notes: [String: OpenNote] = [:]
    /// App views whose inputs have edits not yet saved, by view generation.
    private var unsavedAppInputs: Set<String> = []
    /// An open App has input edits not saved yet, so quitting would lose them.
    var hasUnsavedAppInputs: Bool { !unsavedAppInputs.isEmpty }

    init() {}

    // MARK: Reading

    /// Starts following a note's document.
    func open(_ note: WorkspaceNoteRecord) {
        guard notes[note.id] == nil else { return }
        notes[note.id] = OpenNote(title: note.title, content: Self.emptyContent(note.kind))
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

    private static func emptyContent(_ kind: NoteArtifactKind) -> String {
        (try? NoteDocument(kind: kind).encoded()) ?? ""
    }

    // MARK: Editing

    /// Renames a note. The edit shows at once and goes to this Mac's server.
    func updateNote(id: String, title: String) {
        notes[id, default: OpenNote(title: "", content: "")].title = title
    }

    /// Replaces a note's document. The edit shows at once and goes to this Mac's server.
    func updateNote(id: String, content: String) {
        notes[id, default: OpenNote(title: "", content: "")].content = content
    }

    // MARK: Version history

    /// Saves the current document as a version, then lists the retained versions, newest first.
    func versions(noteID: String) async throws -> [NoteVersion] {
        throw ClientError.notConnected
    }

    /// Makes a retained version current. The current document is kept as a version first.
    func restoreVersion(noteID: String, versionID: String) async throws {
        throw ClientError.notConnected
    }

    // MARK: Apps

    /// Writes one App state edit, after the previous write from the same view.
    func enqueueArtifactInput(noteID: String, edit: ArtifactStateEdit,
                              after previous: Task<ArtifactStateWriteResult, any Error>? = nil)
        -> Task<ArtifactStateWriteResult, any Error> {
        Task {
            if let previous { _ = try? await previous.value }
            throw ClientError.notConnected
        }
    }

    func setArtifactInputsUnsaved(generation: String, _ unsaved: Bool) {
        if unsaved { unsavedAppInputs.insert(generation) } else { unsavedAppInputs.remove(generation) }
    }

    // MARK: Linked data

    /// Reads the rows a database link asks for, from the owner or its latest published copy.
    func linkedData(for link: DatabaseArtifactLink) async throws -> DatabaseTabularData {
        throw ClientError.notConnected
    }

    // MARK: Page tasks

    /// Asks the server to carry out what a Page task's assignees now say: start
    /// the chat or bot thread of each one being sent, and stop each one being
    /// stopped. The Page records the task and the session that runs it.
    func dispatchPageTask(noteID: String, taskID: String) {}
}
