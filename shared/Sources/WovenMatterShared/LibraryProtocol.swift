import Foundation

/// The library API version every member serves. Execution features are negotiated through workspace capabilities.
public enum LibraryProtocol {
  // Version 3 adds workspace management, Library, Calendar and session settings.
  public static let version = 3
  public static let maximumNoteBytes = 4 * 1_024 * 1_024
  public static let maximumChangePage = 200
  public static let maximumReplayChanges = 10_000
}

public struct LibraryFolderExecution: Codable, Equatable, Sendable {
  public var workspaceID: String
  public var rootPath: String
  public init(workspaceID: String, rootPath: String) {
    self.workspaceID = workspaceID; self.rootPath = rootPath
  }
}

public struct LibraryFolder: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var revision: Int64
  public var updatedAt: String
  public var execution: LibraryFolderExecution?
  public init(id: String, name: String, revision: Int64 = 1, updatedAt: String = "", execution: LibraryFolderExecution? = nil) {
    self.id = id; self.name = name; self.revision = revision; self.updatedAt = updatedAt; self.execution = execution
  }
}

public struct LibraryNote: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var folderID: String?
  public var title: String
  /// The canonical encoded document, byte-for-byte. Never flatten unknown formats.
  public var content: String
  public var contentIncluded: Bool
  public var contentByteCount: Int
  public var kind: NoteArtifactKind?
  public var revision: Int64
  public var isPinned: Bool?
  public var updatedAt: String
  public init(id: String, folderID: String? = nil, title: String, content: String, revision: Int64 = 1, updatedAt: String = "", contentIncluded: Bool = true, contentByteCount: Int? = nil, kind: NoteArtifactKind? = nil, isPinned: Bool? = nil) {
    self.isPinned = isPinned
    self.id = id; self.folderID = folderID; self.title = title; self.content = content
    self.revision = revision; self.updatedAt = updatedAt
    self.contentIncluded = contentIncluded; self.contentByteCount = contentByteCount ?? content.utf8.count
    self.kind = kind
  }
}

public struct LibraryConversation: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var libraryID: String?
  public var workspaceID: String?
  public var title: String
  public var folderID: String?
  public var providerID: String?
  public var routeID: String?
  public var runtimeKind: String?
  public var activeRunID: String?
  public var preview: String
  public var isPinned: Bool?
  public var updatedAt: String
  public init(id: String, title: String, folderID: String? = nil, providerID: String? = nil, routeID: String? = nil, runtimeKind: String? = nil, activeRunID: String? = nil, preview: String = "", updatedAt: String = "", isPinned: Bool? = nil, libraryID: String? = nil, workspaceID: String? = nil) {
    self.libraryID = libraryID; self.workspaceID = workspaceID
    self.isPinned = isPinned
    self.id = id; self.title = title; self.folderID = folderID; self.providerID = providerID; self.routeID = routeID
    self.runtimeKind = runtimeKind; self.activeRunID = activeRunID; self.preview = preview; self.updatedAt = updatedAt
  }
}

public struct LibraryMessage: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var conversationID: String
  public var runID: String?
  public var role: String
  public var content: String
  public var status: String?
  public var createdAt: String
  public var sequence: Int64?
  /// Presentation provenance from the execution owner; never an authorization grant.
  public var agentSourceID: String?
  public var isAgentAuthored: Bool?
  public var senderSessionTitle: String?
  public var senderHarness: String?
  public var senderKind: String?
  /// A message's attached files, as an execution workspace received them.
  public var attachments: [LibraryAttachmentReference]?
  public init(id: String, conversationID: String, runID: String? = nil, role: String, content: String, status: String? = nil, createdAt: String = "", sequence: Int64? = nil,
              agentSourceID: String? = nil, isAgentAuthored: Bool? = nil, senderSessionTitle: String? = nil, senderHarness: String? = nil, senderKind: String? = nil,
              attachments: [LibraryAttachmentReference]? = nil) {
    self.sequence = sequence; self.attachments = attachments
    self.agentSourceID = agentSourceID; self.isAgentAuthored = isAgentAuthored
    self.senderSessionTitle = senderSessionTitle; self.senderHarness = senderHarness; self.senderKind = senderKind
    self.id = id; self.conversationID = conversationID; self.runID = runID; self.role = role
    self.content = content; self.status = status; self.createdAt = createdAt
  }
}

public struct LibraryActivity: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var runID: String
  public var title: String
  public var detail: String?
  public var status: String
  /// Canonical AgentRunActivity projection; native records remain in the execution journal.
  public var projectionJSON: String?
  public var detailsRecordID: String?
  public var isTransient: Bool?
  public var sequence: Int64?
  public var createdAt: String?
  public var completedAt: String?
  public init(id: String, runID: String, title: String, detail: String? = nil, status: String,
              projectionJSON: String? = nil, detailsRecordID: String? = nil, isTransient: Bool? = nil, sequence: Int64? = nil, createdAt: String? = nil, completedAt: String? = nil) {
    self.projectionJSON = projectionJSON; self.detailsRecordID = detailsRecordID; self.isTransient = isTransient; self.sequence = sequence
    self.createdAt = createdAt; self.completedAt = completedAt
    self.id = id; self.runID = runID; self.title = title; self.detail = detail; self.status = status
  }
}

public struct LibraryTranscriptRun: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var status: String
  public var startedAt: String?
  public var completedAt: String?
  /// The prompt that started the run and the reply its work belongs to.
  public var userMessageID: String?
  public var assistantMessageID: String?
  public init(id: String, status: String, startedAt: String? = nil, completedAt: String? = nil,
              userMessageID: String? = nil, assistantMessageID: String? = nil) {
    self.id = id; self.status = status; self.startedAt = startedAt; self.completedAt = completedAt
    self.userMessageID = userMessageID; self.assistantMessageID = assistantMessageID
  }
}

public struct LibraryTranscript: Codable, Equatable, Sendable {
  public var conversationID: String
  public var messages: [LibraryMessage]
  public var activities: [LibraryActivity]
  public var activeRunID: String?
  /// Opaque pagination cursor. Send it back as `before`; never interpret on the client.
  public var olderCursor: String?
  public var runs: [LibraryTranscriptRun]?
  /// Exact legacy tool-message IDs superseded by structured activities. Never user messages.
  public var removedMessageIDs: [String]?
  public init(conversationID: String, messages: [LibraryMessage] = [], activities: [LibraryActivity] = [], activeRunID: String? = nil, olderCursor: String? = nil, runs: [LibraryTranscriptRun]? = nil, removedMessageIDs: [String]? = nil) {
    self.runs = runs; self.removedMessageIDs = removedMessageIDs
    self.conversationID = conversationID; self.messages = messages; self.activities = activities
    self.activeRunID = activeRunID; self.olderCursor = olderCursor
  }
}

public struct HarnessCapabilities: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var runtimeKind: String
  public var displayName: String
  public var routeName: String
  public var available: Bool
  public var canStart: Bool
  public var canResume: Bool
  public var canSteer: Bool
  public var canStop: Bool
  public var supportsApprovals: Bool
  public var supportsQuestions: Bool
  public var activeInputMode: String
  public var unavailableReason: String?
  /// A Linux host's Pi Durable vault is locked: a Mac that holds its key
  /// unlocks it (`POST v1/default-agent/unlock`) before starting a session.
  public var locked: Bool?
  public init(id: String, runtimeKind: String, displayName: String, routeName: String = "This Mac", available: Bool, canStart: Bool = true, canResume: Bool = true, canSteer: Bool = false, canStop: Bool = true, supportsApprovals: Bool = true, supportsQuestions: Bool = true, activeInputMode: String = "notNegotiated", unavailableReason: String? = nil, locked: Bool? = nil) {
    self.locked = locked
    self.id = id; self.runtimeKind = runtimeKind; self.displayName = displayName; self.routeName = routeName
    self.available = available; self.canStart = canStart; self.canResume = canResume; self.canSteer = canSteer
    self.canStop = canStop; self.supportsApprovals = supportsApprovals; self.supportsQuestions = supportsQuestions
    self.activeInputMode = activeInputMode; self.unavailableReason = unavailableReason
  }
}

public struct InteractionOption: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var label: String
  public var detail: String?
  public init(id: String, label: String, detail: String? = nil) { self.id = id; self.label = label; self.detail = detail }
}
public struct AgentQuestion: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var prompt: String
  public var options: [InteractionOption]
  public var allowsMultiple: Bool
  public var allowsFreeText: Bool
  public var required: Bool?
  public var isRequired: Bool { required ?? true }
  public init(id: String, prompt: String, options: [InteractionOption] = [], allowsMultiple: Bool = false, allowsFreeText: Bool = true, required: Bool? = nil) {
    self.id = id; self.prompt = prompt; self.options = options; self.allowsMultiple = allowsMultiple; self.allowsFreeText = allowsFreeText
    self.required = required
  }
}
public struct PendingInteraction: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case approval, question }
  public var id: String
  public var conversationID: String
  public var runID: String?
  public var kind: Kind
  public var title: String
  public var detail: String?
  public var options: [InteractionOption]
  public var questions: [AgentQuestion]
  public init(id: String, conversationID: String, runID: String?, kind: Kind, title: String, detail: String? = nil, options: [InteractionOption] = [], questions: [AgentQuestion] = []) {
    self.id = id; self.conversationID = conversationID; self.runID = runID; self.kind = kind
    self.title = title; self.detail = detail; self.options = options; self.questions = questions
  }
}
public struct InteractionResponse: Codable, Equatable, Sendable {
  public var optionID: String?
  public var answers: [String: [String]]
  public var cancelled: Bool
  public init(optionID: String? = nil, answers: [String: [String]] = [:], cancelled: Bool = false) {
    self.optionID = optionID; self.answers = answers; self.cancelled = cancelled
  }
}

public struct LibrarySnapshot: Codable, Equatable, Sendable {
  public var workspaceID: String
  public var cursor: Int64
  public var folders: [LibraryFolder]
  public var notes: [LibraryNote]
  public var conversations: [LibraryConversation]
  public init(workspaceID: String, cursor: Int64, folders: [LibraryFolder] = [], notes: [LibraryNote] = [], conversations: [LibraryConversation] = []) {
    self.workspaceID = workspaceID; self.cursor = cursor; self.folders = folders; self.notes = notes; self.conversations = conversations
  }
}

public struct LibraryMutation: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case createFolder, renameFolder, deleteFolder, createNote, updateNote, deleteNote }
  public var operationID: String
  public var deviceID: String
  public var kind: Kind
  public var resourceID: String
  public var expectedRevision: Int64?
  public var folderID: String?
  public var title: String?
  public var content: String?
  public var folderExecution: LibraryFolderExecution?
  public init(operationID: String = UUID().uuidString.lowercased(), deviceID: String, kind: Kind, resourceID: String, expectedRevision: Int64? = nil, folderID: String? = nil, title: String? = nil, content: String? = nil, folderExecution: LibraryFolderExecution? = nil) {
    self.operationID = operationID; self.deviceID = deviceID; self.kind = kind; self.resourceID = resourceID
    self.expectedRevision = expectedRevision; self.folderID = folderID; self.title = title; self.content = content; self.folderExecution = folderExecution
  }
}
public struct LibraryMutationResult: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable { case accepted, conflict, notFound, invalid }
  public var operationID: String
  public var status: Status
  public var folder: LibraryFolder?
  public var note: LibraryNote?
  public var message: String?
  /// With `notFound` for a note: it exists on the host only as a deletion,
  /// so a client whose copy was unchanged applies the deletion.
  public var deleted: Bool?
  public init(operationID: String, status: Status, folder: LibraryFolder? = nil, note: LibraryNote? = nil, message: String? = nil,
              deleted: Bool? = nil) {
    self.operationID = operationID; self.status = status; self.folder = folder; self.note = note; self.message = message; self.deleted = deleted
  }
}
public struct LibraryChange: Codable, Equatable, Identifiable, Sendable {
  public enum ResourceKind: String, Codable, Sendable { case folder, note, conversation, transcript, providers }
  public enum Operation: String, Codable, Sendable { case upsert, delete }
  public var id: Int64 { cursor }
  public var cursor: Int64
  public var resourceKind: ResourceKind
  public var resourceID: String
  public var operation: Operation
  public var revision: Int64
  public var folder: LibraryFolder?
  public var note: LibraryNote?
  public var conversation: LibraryConversation?
  public init(cursor: Int64, resourceKind: ResourceKind, resourceID: String, operation: Operation, revision: Int64, folder: LibraryFolder? = nil, note: LibraryNote? = nil, conversation: LibraryConversation? = nil) {
    self.cursor = cursor; self.resourceKind = resourceKind; self.resourceID = resourceID; self.operation = operation
    self.revision = revision; self.folder = folder; self.note = note; self.conversation = conversation
  }
}
public struct LibraryChangePage: Codable, Equatable, Sendable {
  public var workspaceID: String
  public var cursor: Int64
  public var changes: [LibraryChange]
  public var hasMore: Bool
  public var resetRequired: Bool
  public init(workspaceID: String, cursor: Int64, changes: [LibraryChange] = [], hasMore: Bool = false, resetRequired: Bool = false) {
    self.workspaceID = workspaceID; self.cursor = cursor; self.changes = changes; self.hasMore = hasMore; self.resetRequired = resetRequired
  }
}
public struct LibraryCommand: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case createSession, send, steer, stop, respond, workspace }
  public var commandID: String
  public var deviceID: String
  public var libraryID: String?
  public var workspaceID: String?
  public var kind: Kind
  public var conversationID: String?
  public var runID: String?
  public var providerID: String?
  public var routeID: String?
  public var runtimeKind: String?
  public var folderID: String?
  public var text: String?
  public var noteID: String?
  public var noteRevision: Int64?
  public var interactionID: String?
  public var workspaceAction: LibraryWorkspaceAction?
  public var response: InteractionResponse?
  /// `createSession` only: the new session's title, applied as it is created.
  /// Older destinations ignore it, so callers still follow with a rename.
  public var title: String?
  /// `createSession` only: the caller's choices for the new session.
  public var sessionOptions: LibrarySessionOptions?
  /// `send` and `steer`: files uploaded first with
  /// `PUT v1/execution/attachments/<sha256>`. On `send` and `steer`, `noteID`
  /// is the note the sending device shows, which `woven_context` returns.
  public var attachments: [LibraryAttachmentReference]?
  /// `send` and `steer`: text the harness receives after the message (the
  /// device's visible notes and pages, references) and the transcript omits.
  public var promptContext: String?
  public init(commandID: String = UUID().uuidString.lowercased(), deviceID: String, kind: Kind, conversationID: String? = nil, runID: String? = nil, providerID: String? = nil, routeID: String? = nil, runtimeKind: String? = nil, folderID: String? = nil, text: String? = nil, noteID: String? = nil, noteRevision: Int64? = nil, interactionID: String? = nil, response: InteractionResponse? = nil, workspaceAction: LibraryWorkspaceAction? = nil, libraryID: String? = nil, workspaceID: String? = nil, title: String? = nil,
              sessionOptions: LibrarySessionOptions? = nil, attachments: [LibraryAttachmentReference]? = nil, promptContext: String? = nil) {
    self.libraryID = libraryID; self.workspaceID = workspaceID; self.title = title
    self.sessionOptions = sessionOptions; self.attachments = attachments; self.promptContext = promptContext
    self.commandID = commandID; self.deviceID = deviceID; self.kind = kind; self.conversationID = conversationID
    self.runID = runID; self.providerID = providerID; self.routeID = routeID; self.runtimeKind = runtimeKind; self.folderID = folderID
    self.text = text; self.noteID = noteID; self.noteRevision = noteRevision; self.interactionID = interactionID; self.response = response; self.workspaceAction = workspaceAction
  }
}
/// A new session's choices (`LibraryCommand.sessionOptions`). Unset values
/// take the destination's saved defaults. `workingDirectory` must match a
/// folder's bound root when `folderID` names one bound to the destination.
public struct LibrarySessionOptions: Codable, Equatable, Sendable {
  public var workingDirectory: String?
  public var model: String?
  public var thinking: String?
  public var permission: String?
  public var enabledTools: [String]?
  public init(workingDirectory: String? = nil, model: String? = nil, thinking: String? = nil, permission: String? = nil, enabledTools: [String]? = nil) {
    self.workingDirectory = workingDirectory; self.model = model; self.thinking = thinking
    self.permission = permission; self.enabledTools = enabledTools
  }
}

/// A message file on an execution workspace: `id` is its SHA-256 (hex).
public struct LibraryAttachmentReference: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var mimeType: String
  public var byteCount: Int64?
  public init(id: String, name: String, mimeType: String, byteCount: Int64? = nil) {
    self.id = id; self.name = name; self.mimeType = mimeType; self.byteCount = byteCount
  }
  /// A message file is at most 25 MiB, read as it was uploaded.
  public static let maximumBytes = 25 * 1_024 * 1_024
  /// Whether `id` is a SHA-256 digest (64 lowercase hex characters), so the
  /// file can be read from the workspace that holds it.
  public var isReadable: Bool { Self.isDigest(id) }
  public static func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  /// `GET <workspace endpoint>/v1/execution/attachments/<sha256>?name=`: the
  /// file's bytes, from the workspace that runs its session, with the same
  /// authorization as the other execution reads.
  public var readPath: String { "v1/execution/attachments/" + id }
}

public struct LibraryCommandReceipt: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable { case accepted, completed, rejected, outcomeUnknown }
  public var commandID: String
  public var deviceID: String
  public var libraryID: String?
  public var workspaceID: String?
  public var status: Status
  public var conversationID: String?
  public var runID: String?
  public var message: String?
  /// A rejection the caller can act on: `default_agent_locked` (a Mac
  /// unlocks Pi Durable, then the caller retries) or `attachment_unavailable`.
  public var code: String?
  public init(commandID: String, deviceID: String, status: Status, conversationID: String? = nil, runID: String? = nil, message: String? = nil, libraryID: String? = nil, workspaceID: String? = nil, code: String? = nil) {
    self.libraryID = libraryID; self.workspaceID = workspaceID; self.code = code
    self.commandID = commandID; self.deviceID = deviceID; self.status = status
    self.conversationID = conversationID; self.runID = runID; self.message = message
  }
}
public struct LibraryCommandReservation: Equatable, Sendable {
  public var receipt: LibraryCommandReceipt
  public var isNew: Bool
  public init(receipt: LibraryCommandReceipt, isNew: Bool) { self.receipt = receipt; self.isNew = isNew }
}
