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
    private let decode: (String) -> NoteDocument

    init(decode: @escaping (String) -> NoteDocument = NoteDocument.decode) {
        self.decode = decode
    }

    func value(noteID: String, source: String) -> NoteDocument {
        if self.noteID == noteID, self.source == source, let document {
            return document
        }
        let document = decode(source)
        self.noteID = noteID
        self.source = source
        self.document = document
        return document
    }

    func encode(_ document: NoteDocument, noteID: String) throws -> String {
        let normalized = document.normalized()
        let source = try normalized.encoded()
        self.noteID = noteID
        self.source = source
        self.document = normalized
        return source
    }
}
