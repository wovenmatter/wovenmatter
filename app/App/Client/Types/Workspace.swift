import Foundation

/// A name plus a directory on one machine. It belongs to that machine.
struct WorkspaceFolderRecord: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var icon: String?
    var position: Int
    var isPinned: Bool
    /// The machine that owns the folder and runs its sessions.
    let machineID: String
    var rootPath: String?
    /// Woven made the directory, so deleting the folder may delete it too.
    var managedRoot: Bool
    /// Extra directories the folder's sessions may read.
    var referencePaths: [String]
}

enum WorkspaceFolderMoveDirection: Sendable {
    case up
    case down
}

/// What a session is doing, as the sidebar and activity rows show it.
enum SessionActivity: Hashable, Sendable {
    case idle
    case working
    /// The turn waits on the person: a question, an approval, a form.
    case blocked
    case failed(String)
}

/// A session as the sidebar lists it. The transcript lives in its `SessionStore`.
struct WorkspaceConversationRecord: Identifiable, Hashable, Sendable {
    let id: String
    /// The machine that owns the session for its whole life.
    let machineID: String
    var agentID: String?
    var runtimeKind: AgentRuntimeKind?
    var title: String
    var unread: Bool
    var lastMessagePreview: String?
    var lastMessageAt: Date?
    var isScheduledTask: Bool
    var folderID: String?
    var isPinned: Bool
    var isArchived: Bool
    var activity: SessionActivity
}

/// A note, page or app as the sidebar lists it. The document itself is opened
/// through the documents store.
struct WorkspaceNoteRecord: Identifiable, Hashable, Sendable {
    let id: String
    var folderID: String?
    var title: String
    var kind: NoteArtifactKind
    var isPinned: Bool
    var createdAt: Date?
    var updatedAt: Date?
    /// One line the sidebar shows under the title: the start of a note's text,
    /// a sheet's size, a page's component count. The server derives it.
    var preview: String = ""
}

/// Everything the sidebar lists, across every machine.
struct WorkspaceOverview: Equatable, Sendable {
    var folders: [WorkspaceFolderRecord]
    var conversations: [WorkspaceConversationRecord]
    var notes: [WorkspaceNoteRecord]

    static let empty = WorkspaceOverview(folders: [], conversations: [], notes: [])
}

struct WorkspaceTrashedConversation: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var trashedAt: Date
}

struct WorkspaceTrashedNote: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var kind: NoteArtifactKind
    var trashedAt: Date
}
