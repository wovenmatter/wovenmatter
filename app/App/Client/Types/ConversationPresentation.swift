import Foundation

// What one open chat shows: its messages and runs as the owning machine's
// server reports them, and the presentations the transcript draws from them.

enum MessageRole: String, Hashable, Sendable {
    case user
    case assistant
    case system
}

enum MessageStatus: Hashable, Sendable {
    case complete
    /// The item in progress: its text is still arriving.
    case streaming
    case failed
}

/// A file sent with a message. The bytes are fetched by `contentHash` when opened.
struct SessionMessageAttachment: Identifiable, Hashable, Sendable {
    let id: String
    let kind: AgentMessageAttachmentKind
    let fileName: String
    let mimeType: String
    let sizeBytes: Int64
    let contentHash: String?
}

/// A note or chat attached to a message.
struct SessionMessageReference: Identifiable, Hashable, Sendable {
    let id: String
    let kind: AgentMessageAttachmentKind
    let title: String
}

/// One message of a session.
struct WorkspaceMessageRecord: Identifiable, Hashable, Sendable {
    let id: String
    let conversationID: String
    var role: MessageRole
    var content: String
    var status: MessageStatus
    var createdAt: Date
    var attachments: [SessionMessageAttachment] = []
    var references: [SessionMessageReference] = []
    /// Set when another session, a timer or a goal sent this message.
    var senderKind: WorkspaceSessionDeliveryKind?
    var senderSessionID: String?
    var senderSessionTitle: String?
    /// The runtime of the sending session, as `AgentRuntimeKind` raw value.
    var senderAgent: String?
}

enum RunStatus: Hashable, Sendable {
    /// Accepted by the owner, not started yet. Not shown.
    case queued
    case running
    case completed
    case failed
    case cancelled

    var isRunning: Bool { self == .running }
}

/// One turn: the user message it answers, the assistant message it writes, and its timing.
struct WorkspaceRunRecord: Identifiable, Hashable, Sendable {
    let id: String
    let conversationID: String
    var status: RunStatus
    var error: String?
    var userMessageID: String?
    var assistantMessageID: String?
    var startedAt: Date?
    var completedAt: Date?
}

/// One message as the transcript draws it.
struct MessagePresentation: Sendable {
    let source: String
    let displayedBody: String
    let status: MessageStatus
    let isStreaming: Bool
    let createdAt: Date
    let document: ConversationMarkdownDocument?
    let activities: [WorkspaceRunActivityRecord]
    let commentaryIDs: Set<String>
    let workTimeline: ConversationWorkTimeline
}

/// One run as the transcript draws it.
struct RunPresentation: Sendable {
    let source: WorkspaceRunRecord
    let startedAt: Date?
    let completedDuration: String?
}

// MARK: - Goals

/// The goal a session works against until it is met or cleared. While it is
/// set, the owning server continues the session after each turn.
struct WorkspaceGoal: Identifiable, Hashable, Sendable {
    let id: String
    var objective: String

    static func supports(_ runtime: AgentRuntimeKind?) -> Bool { runtime != nil }
}

enum WorkspaceGoalMutation: Hashable, Sendable {
    case clear(id: String)
}
