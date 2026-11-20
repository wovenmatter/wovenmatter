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

enum WorkspaceGoalStatus: String, Hashable, Sendable {
    case active, paused, blocked, complete
    case budgetLimited

    var title: String {
        switch self {
        case .active: "Pursuing goal"
        case .paused: "Paused goal"
        case .blocked: "Goal stalled"
        case .complete: "Goal achieved"
        case .budgetLimited: "Goal budget reached"
        }
    }
}

/// The goal a session works against until it is met or cleared.
struct WorkspaceGoal: Identifiable, Hashable, Sendable {
    let id: String
    var objective: String
    var status: WorkspaceGoalStatus
    /// Time spent pursuing it before `activeSince`.
    var activeSeconds: TimeInterval
    var activeSince: Date?
    var evidence: String?

    func elapsedPursuitText(at now: Date) -> String {
        let elapsed = activeSeconds + (status == .active ? activeSince.map { max(0, now.timeIntervalSince($0)) } ?? 0 : 0)
        guard elapsed.isFinite, elapsed >= 0, elapsed < Double(Int.max) else { return "Elapsed unavailable" }
        let seconds = Int(elapsed)
        let duration = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return "\(duration) elapsed"
    }

    static func supports(_ runtime: AgentRuntimeKind?) -> Bool { runtime != nil }
}

enum WorkspaceGoalMutation: Hashable, Sendable {
    case pause(id: String), resume(id: String), clear(id: String)
}

// MARK: - Subagent history

/// A page of a Pi Durable subagent's archived native records.
struct SubagentArchiveRequest: Hashable, Sendable {
    let conversationID: String
    let sourceID: String
    let nativeSessionID: String
    let nativeConversationID: String
    var after: Int64
    var eventID: String?
    /// Byte offset into one record's payload.
    var offset = 0
}

struct SubagentArchiveRecord: Identifiable, Hashable, Sendable {
    let id: String
    let kind: String?
    let text: String?
    let payload: String?
    let payloadHasMore: Bool
}

struct SubagentArchivePage: Hashable, Sendable {
    let records: [SubagentArchiveRecord]
    let hasMore: Bool
    let nextCursor: Int64
}
