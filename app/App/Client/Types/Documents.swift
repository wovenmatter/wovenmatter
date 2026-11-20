import Foundation
import WovenProtocol

/// A note, page or app while it is open: its title and its document as the
/// server holds it, with this Mac's edits applied.
struct OpenNote: Equatable, Sendable {
    var title: String
    /// The document, encoded as `NoteDocument` JSON.
    var content: String
}

/// One saved version in a note's history. Conflicting edits keep the version
/// that lost here, so nothing is lost and no copy appears.
struct NoteVersion: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case created
        case checkpoint
        case agentEdit
        case beforeAgentEdit
        case restored
        case beforeRestore
        /// The other side of an edit made apart on another machine.
        case otherMachine(String)

        var displayName: String {
            switch self {
            case .created: "Created"
            case .checkpoint: "Editor checkpoint"
            case .agentEdit: "Agent edit"
            case .beforeAgentEdit: "Before agent edit"
            case .restored: "Restored version"
            case .beforeRestore: "Before restoration"
            case .otherMachine(let name): "Edit from \(name)"
            }
        }
    }

    let id: String
    let title: String
    /// The document, encoded as `NoteDocument` JSON.
    let content: String
    let savedAt: Date
    let source: Source
}

/// An App state write the server refused, with the state it holds now so the
/// App can apply its change again.
struct ArtifactInputFailure: LocalizedError {
    let message: String
    let snapshot: ArtifactStateSnapshot?
    var errorDescription: String? { message }
}
