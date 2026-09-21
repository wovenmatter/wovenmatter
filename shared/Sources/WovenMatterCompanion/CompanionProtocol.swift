import Foundation

/// Only the paired Mac owns execution. A disconnected client never queues agent commands.
public enum CompanionProtocol {
  // Version 2 permits native pending interactions before a canonical run exists.
  public static let version = 2
  public static let maximumNoteBytes = 4 * 1_024 * 1_024
  public static let maximumChangePage = 200
  public static let maximumReplayChanges = 10_000
}

public struct CompanionFolder: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var revision: Int64
  public var updatedAt: String
  public init(id: String, name: String, revision: Int64 = 1, updatedAt: String = "") {
    self.id = id; self.name = name; self.revision = revision; self.updatedAt = updatedAt
  }
}

public struct CompanionNote: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var folderID: String?
  public var title: String
  /// The canonical encoded document, byte-for-byte. Never flatten unknown formats.
  public var content: String
  public var contentIncluded: Bool
  public var contentByteCount: Int
  public var kind: NoteArtifactKind?
  public var revision: Int64
  public var updatedAt: String
  public init(id: String, folderID: String? = nil, title: String, content: String, revision: Int64 = 1, updatedAt: String = "", contentIncluded: Bool = true, contentByteCount: Int? = nil, kind: NoteArtifactKind? = nil) {
    self.id = id; self.folderID = folderID; self.title = title; self.content = content
    self.revision = revision; self.updatedAt = updatedAt
    self.contentIncluded = contentIncluded; self.contentByteCount = contentByteCount ?? content.utf8.count
    self.kind = kind
  }
}

public struct CompanionConversation: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var folderID: String?
  public var providerID: String?
  public var routeID: String?
  public var runtimeKind: String?
  public var activeRunID: String?
  public var preview: String
  public var updatedAt: String
  public init(id: String, title: String, folderID: String? = nil, providerID: String? = nil, routeID: String? = nil, runtimeKind: String? = nil, activeRunID: String? = nil, preview: String = "", updatedAt: String = "") {
    self.id = id; self.title = title; self.folderID = folderID; self.providerID = providerID; self.routeID = routeID
    self.runtimeKind = runtimeKind; self.activeRunID = activeRunID; self.preview = preview; self.updatedAt = updatedAt
  }
}

public struct CompanionMessage: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var conversationID: String
  public var runID: String?
  public var role: String
  public var content: String
  public var status: String?
  public var createdAt: String
  public init(id: String, conversationID: String, runID: String? = nil, role: String, content: String, status: String? = nil, createdAt: String = "") {
    self.id = id; self.conversationID = conversationID; self.runID = runID; self.role = role
    self.content = content; self.status = status; self.createdAt = createdAt
  }
}

public struct CompanionActivity: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var runID: String
  public var title: String
  public var detail: String?
  public var status: String
  public init(id: String, runID: String, title: String, detail: String? = nil, status: String) {
    self.id = id; self.runID = runID; self.title = title; self.detail = detail; self.status = status
  }
}

public struct CompanionTranscript: Codable, Equatable, Sendable {
  public var conversationID: String
  public var messages: [CompanionMessage]
  public var activities: [CompanionActivity]
  public var activeRunID: String?
  /// Opaque pagination cursor. Send it back as `before`; never interpret on the client.
  public var olderCursor: String?
  public init(conversationID: String, messages: [CompanionMessage] = [], activities: [CompanionActivity] = [], activeRunID: String? = nil, olderCursor: String? = nil) {
    self.conversationID = conversationID; self.messages = messages; self.activities = activities
    self.activeRunID = activeRunID; self.olderCursor = olderCursor
  }
}

public struct CompanionProvider: Codable, Equatable, Identifiable, Sendable {
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
  public init(id: String, runtimeKind: String, displayName: String, routeName: String = "This Mac", available: Bool, canStart: Bool = true, canResume: Bool = true, canSteer: Bool = false, canStop: Bool = true, supportsApprovals: Bool = true, supportsQuestions: Bool = true, activeInputMode: String = "notNegotiated", unavailableReason: String? = nil) {
    self.id = id; self.runtimeKind = runtimeKind; self.displayName = displayName; self.routeName = routeName
    self.available = available; self.canStart = canStart; self.canResume = canResume; self.canSteer = canSteer
    self.canStop = canStop; self.supportsApprovals = supportsApprovals; self.supportsQuestions = supportsQuestions
    self.activeInputMode = activeInputMode; self.unavailableReason = unavailableReason
  }
}

public struct CompanionInteractionOption: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var label: String
  public var detail: String?
  public init(id: String, label: String, detail: String? = nil) { self.id = id; self.label = label; self.detail = detail }
}
public struct CompanionQuestion: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var prompt: String
  public var options: [CompanionInteractionOption]
  public var allowsMultiple: Bool
  public var allowsFreeText: Bool
  public init(id: String, prompt: String, options: [CompanionInteractionOption] = [], allowsMultiple: Bool = false, allowsFreeText: Bool = true) {
    self.id = id; self.prompt = prompt; self.options = options; self.allowsMultiple = allowsMultiple; self.allowsFreeText = allowsFreeText
  }
}
public struct CompanionPendingInteraction: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case approval, question }
  public var id: String
  public var conversationID: String
  public var runID: String?
  public var kind: Kind
  public var title: String
  public var detail: String?
  public var options: [CompanionInteractionOption]
  public var questions: [CompanionQuestion]
  public init(id: String, conversationID: String, runID: String?, kind: Kind, title: String, detail: String? = nil, options: [CompanionInteractionOption] = [], questions: [CompanionQuestion] = []) {
    self.id = id; self.conversationID = conversationID; self.runID = runID; self.kind = kind
    self.title = title; self.detail = detail; self.options = options; self.questions = questions
  }
}
public struct CompanionInteractionResponse: Codable, Equatable, Sendable {
  public var optionID: String?
  public var answers: [String: [String]]
  public var cancelled: Bool
  public init(optionID: String? = nil, answers: [String: [String]] = [:], cancelled: Bool = false) {
    self.optionID = optionID; self.answers = answers; self.cancelled = cancelled
  }
}

public struct CompanionSnapshot: Codable, Equatable, Sendable {
  public var workspaceID: String
  public var cursor: Int64
  public var folders: [CompanionFolder]
  public var notes: [CompanionNote]
  public var conversations: [CompanionConversation]
  public init(workspaceID: String, cursor: Int64, folders: [CompanionFolder] = [], notes: [CompanionNote] = [], conversations: [CompanionConversation] = []) {
    self.workspaceID = workspaceID; self.cursor = cursor; self.folders = folders; self.notes = notes; self.conversations = conversations
  }
}

public struct CompanionMutation: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case createFolder, renameFolder, deleteFolder, createNote, updateNote, deleteNote }
  public var operationID: String
  public var deviceID: String
  public var kind: Kind
  public var resourceID: String
  public var expectedRevision: Int64?
  public var folderID: String?
  public var title: String?
  public var content: String?
  public init(operationID: String = UUID().uuidString.lowercased(), deviceID: String, kind: Kind, resourceID: String, expectedRevision: Int64? = nil, folderID: String? = nil, title: String? = nil, content: String? = nil) {
    self.operationID = operationID; self.deviceID = deviceID; self.kind = kind; self.resourceID = resourceID
    self.expectedRevision = expectedRevision; self.folderID = folderID; self.title = title; self.content = content
  }
}
public struct CompanionMutationResult: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable { case accepted, conflict, notFound, invalid }
  public var operationID: String
  public var status: Status
  public var folder: CompanionFolder?
  public var note: CompanionNote?
  public var message: String?
  public init(operationID: String, status: Status, folder: CompanionFolder? = nil, note: CompanionNote? = nil, message: String? = nil) {
    self.operationID = operationID; self.status = status; self.folder = folder; self.note = note; self.message = message
  }
}
public struct CompanionChange: Codable, Equatable, Identifiable, Sendable {
  public enum ResourceKind: String, Codable, Sendable { case folder, note, conversation, transcript, providers }
  public enum Operation: String, Codable, Sendable { case upsert, delete }
  public var id: Int64 { cursor }
  public var cursor: Int64
  public var resourceKind: ResourceKind
  public var resourceID: String
  public var operation: Operation
  public var revision: Int64
  public var folder: CompanionFolder?
  public var note: CompanionNote?
  public var conversation: CompanionConversation?
  public init(cursor: Int64, resourceKind: ResourceKind, resourceID: String, operation: Operation, revision: Int64, folder: CompanionFolder? = nil, note: CompanionNote? = nil, conversation: CompanionConversation? = nil) {
    self.cursor = cursor; self.resourceKind = resourceKind; self.resourceID = resourceID; self.operation = operation
    self.revision = revision; self.folder = folder; self.note = note; self.conversation = conversation
  }
}
public struct CompanionChangePage: Codable, Equatable, Sendable {
  public var workspaceID: String
  public var cursor: Int64
  public var changes: [CompanionChange]
  public var hasMore: Bool
  public var resetRequired: Bool
  public init(workspaceID: String, cursor: Int64, changes: [CompanionChange] = [], hasMore: Bool = false, resetRequired: Bool = false) {
    self.workspaceID = workspaceID; self.cursor = cursor; self.changes = changes; self.hasMore = hasMore; self.resetRequired = resetRequired
  }
}
public struct CompanionCommand: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case createSession, send, steer, stop, respond }
  public var commandID: String
  public var deviceID: String
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
  public var response: CompanionInteractionResponse?
  public init(commandID: String = UUID().uuidString.lowercased(), deviceID: String, kind: Kind, conversationID: String? = nil, runID: String? = nil, providerID: String? = nil, routeID: String? = nil, runtimeKind: String? = nil, folderID: String? = nil, text: String? = nil, noteID: String? = nil, noteRevision: Int64? = nil, interactionID: String? = nil, response: CompanionInteractionResponse? = nil) {
    self.commandID = commandID; self.deviceID = deviceID; self.kind = kind; self.conversationID = conversationID
    self.runID = runID; self.providerID = providerID; self.routeID = routeID; self.runtimeKind = runtimeKind; self.folderID = folderID
    self.text = text; self.noteID = noteID; self.noteRevision = noteRevision; self.interactionID = interactionID; self.response = response
  }
}
public struct CompanionCommandReceipt: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable { case accepted, completed, rejected, outcomeUnknown }
  public var commandID: String
  public var deviceID: String
  public var status: Status
  public var conversationID: String?
  public var runID: String?
  public var message: String?
  public init(commandID: String, deviceID: String, status: Status, conversationID: String? = nil, runID: String? = nil, message: String? = nil) {
    self.commandID = commandID; self.deviceID = deviceID; self.status = status
    self.conversationID = conversationID; self.runID = runID; self.message = message
  }
}
public struct CompanionCommandReservation: Equatable, Sendable {
  public var receipt: CompanionCommandReceipt
  public var isNew: Bool
  public init(receipt: CompanionCommandReceipt, isNew: Bool) { self.receipt = receipt; self.isNew = isNew }
}
