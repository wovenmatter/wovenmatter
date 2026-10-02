import Foundation
import WovenMatterCore

/// A pane owns one decoded document. Repeated binding reads (including each
/// spreadsheet cell) reuse it until the actual persisted/draft source changes.
/// Keeping the source as the key also handles external edits and failed saves;
/// neither timestamps nor save-state transitions can hide fresh content.
@MainActor
final class DashboardNoteDocumentCache {
    private var noteID: String?
    private var source: String?
    private var document: NoteDocument?
    private var editable = false
    private let validateEditable: (String) -> Bool
    private let decode: (String) -> NoteDocument

    init(
        validateEditable: @escaping (String) -> Bool = {
            (try? NoteDocument.editableDocument(from: $0)) != nil
        },
        decode: @escaping (String) -> NoteDocument = NoteDocument.decode
    ) {
        self.validateEditable = validateEditable
        self.decode = decode
    }

    func value(noteID: String, source: String) -> NoteDocument {
        if self.noteID == noteID, self.source == source, let document {
            return document
        }
        // Validate before the forgiving decoder can normalize an unsupported
        // or oversized structure. The pane displays the untouched raw source.
        let editable = validateEditable(source)
        let document = editable ? decode(source) : NoteDocument()
        self.noteID = noteID
        self.source = source
        self.document = document
        self.editable = editable
        return document
    }

    func isEditable(noteID: String, source: String) -> Bool {
        _ = value(noteID: noteID, source: source)
        return editable
    }

    func encode(_ document: NoteDocument, noteID: String) throws -> String {
        try document.validateEditableShape()
        let normalized = document.normalized()
        let source = try normalized.encoded()
        guard source.utf8.count <= CompanionProtocol.maximumNoteBytes else {
            throw NoteDocumentSafetyError.tooLarge
        }
        self.noteID = noteID
        self.source = source
        self.document = normalized
        self.editable = true
        return source
    }
}
