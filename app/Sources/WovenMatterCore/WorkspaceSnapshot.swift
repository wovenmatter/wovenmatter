import Foundation

func dashboardDate(from value: String) -> Date? {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

public struct WorkspaceFolderRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let icon: String?
  public let position: Int
  public let isPinned: Bool

  enum CodingKeys: String, CodingKey {
    case id, name, icon, position
    case isPinned = "is_pinned"
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    icon = try values.decodeIfPresent(String.self, forKey: .icon)
    position = try values.decode(Int.self, forKey: .position)
    isPinned = try values.sqliteBool(forKey: .isPinned)
  }
}

public enum WorkspaceFolderMoveDirection: Sendable {
  case up
  case down
}

public struct WorkspaceConversationRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let agentID: String?
  public let agentCodename: String?
  public let governingPlane: AgentGoverningPlane?
  public let authorityDeviceID: UUID?
  public let localRuntimeKind: AgentRuntimeKind?
  public let remoteWorkspaceID: UUID?
  public let title: String
  public let unread: Bool
  public let lastMessagePreview: String?
  public let openClawSessionKey: String?
  public let lastMessageAt: String?
  public let folderID: String?
  public let isMain: Bool
  public let isPinned: Bool
  public let isArchived: Bool

  enum CodingKeys: String, CodingKey {
    case id, title, unread
    case agentID = "agent_id"
    case agentCodename = "agent_codename"
    case governingPlane = "governing_plane"
    case authorityDeviceID = "authority_device_id"
    case localRuntimeKind = "local_runtime_kind"
    case remoteWorkspaceID = "remote_workspace_id"
    case lastMessagePreview = "last_message_preview"
    case openClawSessionKey = "openclaw_session_key"
    case lastMessageAt = "last_message_at"
    case folderID = "folder_id"
    case isMain = "is_main"
    case isPinned = "is_pinned"
    case isArchived = "is_archived"
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    agentID = try values.decodeIfPresent(String.self, forKey: .agentID)
    agentCodename = try values.decodeIfPresent(String.self, forKey: .agentCodename)
    governingPlane = try values.decodeIfPresent(
      AgentGoverningPlane.self,
      forKey: .governingPlane
    )
    authorityDeviceID = try values.decodeIfPresent(UUID.self, forKey: .authorityDeviceID)
    localRuntimeKind = try values.decodeIfPresent(
      AgentRuntimeKind.self,
      forKey: .localRuntimeKind
    )
    remoteWorkspaceID = try values.decodeIfPresent(
      UUID.self,
      forKey: .remoteWorkspaceID
    )
    title = try values.decode(String.self, forKey: .title)
    unread = try values.sqliteBool(forKey: .unread)
    lastMessagePreview = try values.decodeIfPresent(String.self, forKey: .lastMessagePreview)
    openClawSessionKey = try values.decodeIfPresent(String.self, forKey: .openClawSessionKey)
    lastMessageAt = try values.decodeIfPresent(String.self, forKey: .lastMessageAt)
    folderID = try values.decodeIfPresent(String.self, forKey: .folderID)
    isMain = try values.sqliteBoolIfPresent(forKey: .isMain) ?? false
    isPinned = try values.sqliteBool(forKey: .isPinned)
    isArchived = try values.sqliteBool(forKey: .isArchived)
  }
}

public struct WorkspaceMessageRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let conversationID: String
  public let clientMessageID: String?
  public let runID: String?
  public let governingPlane: AgentGoverningPlane?
  public let authorityDeviceID: UUID?
  public let role: String
  public let content: String
  public let status: String?
  public let createdAt: String
  public let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, role, content, status
    case conversationID = "conversation_id"
    case clientMessageID = "client_message_id"
    case runID = "run_id"
    case governingPlane = "governing_plane"
    case authorityDeviceID = "authority_device_id"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

public struct WorkspaceNoteRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let folderID: String?
  public let title: String
  public let content: String
  public let createdAt: String?
  public let updatedAt: String?
  public let isPinned: Bool

  enum CodingKeys: String, CodingKey {
    case id, title, content
    case folderID = "folder_id"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case isPinned = "is_pinned"
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    folderID = try values.decodeIfPresent(String.self, forKey: .folderID)
    title = try values.decode(String.self, forKey: .title)
    content = try values.decode(String.self, forKey: .content)
    createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
    updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
    isPinned = try values.sqliteBoolIfPresent(forKey: .isPinned) ?? false
  }
}

public struct WorkspaceCalendarItemRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let userID: String
  public let kind: String
  public let title: String
  public let details: String?
  public let startsAt: String
  public let endsAt: String?
  public let allDay: Bool
  public let status: String
  public let source: String
  public let createdAt: String
  public let updatedAt: String

  public var startDate: Date? { dashboardDate(from: startsAt) }
  public var endDate: Date? { endsAt.flatMap(dashboardDate(from:)) }

  enum CodingKeys: String, CodingKey {
    case id, kind, title, status, source
    case userID = "user_id"
    case details = "description"
    case startsAt = "starts_at"
    case endsAt = "ends_at"
    case allDay = "all_day"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  public init(
    id: String,
    userID: String,
    kind: String,
    title: String,
    details: String?,
    startsAt: String,
    endsAt: String?,
    allDay: Bool,
    status: String,
    source: String,
    createdAt: String,
    updatedAt: String
  ) {
    self.id = id
    self.userID = userID
    self.kind = kind
    self.title = title
    self.details = details
    self.startsAt = startsAt
    self.endsAt = endsAt
    self.allDay = allDay
    self.status = status
    self.source = source
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    userID = try values.decode(String.self, forKey: .userID)
    kind = try values.decode(String.self, forKey: .kind)
    title = try values.decode(String.self, forKey: .title)
    details = try values.decodeIfPresent(String.self, forKey: .details)
    startsAt = try values.decode(String.self, forKey: .startsAt)
    endsAt = try values.decodeIfPresent(String.self, forKey: .endsAt)
    allDay = try values.sqliteBool(forKey: .allDay)
    status = try values.decode(String.self, forKey: .status)
    source = try values.decode(String.self, forKey: .source)
    createdAt = try values.decode(String.self, forKey: .createdAt)
    updatedAt = try values.decode(String.self, forKey: .updatedAt)
  }
}

public struct WorkspaceRunRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let conversationID: String
  public let agentID: String?
  public let governingPlane: AgentGoverningPlane?
  public let authorityDeviceID: UUID?
  public let userMessageID: String?
  public let assistantMessageID: String?
  public let status: String
  public let error: String?
  public let startedAt: String?
  public let completedAt: String?
  public let createdAt: String?
  public let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, status, error
    case conversationID = "conversation_id"
    case agentID = "agent_id"
    case governingPlane = "governing_plane"
    case authorityDeviceID = "authority_device_id"
    case userMessageID = "user_message_id"
    case assistantMessageID = "assistant_message_id"
    case startedAt = "started_at"
    case completedAt = "completed_at"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
  public let revision: Int64
  public let folders: [WorkspaceFolderRecord]
  public let conversations: [WorkspaceConversationRecord]
  public let messages: [WorkspaceMessageRecord]
  public let notes: [WorkspaceNoteRecord]
  public let runs: [WorkspaceRunRecord]

  public init(
    revision: Int64,
    folders: [WorkspaceFolderRecord],
    conversations: [WorkspaceConversationRecord],
    messages: [WorkspaceMessageRecord],
    notes: [WorkspaceNoteRecord],
    runs: [WorkspaceRunRecord]
  ) {
    self.revision = revision
    self.folders = folders
    self.conversations = conversations
    self.messages = messages
    self.notes = notes
    self.runs = runs
  }
}

public struct WorkspaceConversationContent: Codable, Equatable, Sendable {
  public let conversationID: String
  public let messages: [WorkspaceMessageRecord]
  public let runs: [WorkspaceRunRecord]
  public let attachments: [WorkspaceMessageAttachmentRecord]
  public let references: [WorkspaceMessageReferenceRecord]

  private enum CodingKeys: String, CodingKey {
    case conversationID, messages, runs, attachments, references
  }

  public init(
    conversationID: String,
    messages: [WorkspaceMessageRecord],
    runs: [WorkspaceRunRecord],
    attachments: [WorkspaceMessageAttachmentRecord] = [],
    references: [WorkspaceMessageReferenceRecord] = []
  ) {
    self.conversationID = conversationID
    self.messages = messages
    self.runs = runs
    self.attachments = attachments
    self.references = references
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    conversationID = try values.decode(String.self, forKey: .conversationID)
    messages = try values.decode([WorkspaceMessageRecord].self, forKey: .messages)
    runs = try values.decode([WorkspaceRunRecord].self, forKey: .runs)
    attachments = try values.decodeIfPresent(
      [WorkspaceMessageAttachmentRecord].self,
      forKey: .attachments
    ) ?? []
    references = try values.decodeIfPresent(
      [WorkspaceMessageReferenceRecord].self,
      forKey: .references
    ) ?? []
  }
}

private extension KeyedDecodingContainer {
  func sqliteBoolIfPresent(forKey key: Key) throws -> Bool? {
    guard contains(key), try !decodeNil(forKey: key) else { return nil }
    return try sqliteBool(forKey: key)
  }

  func sqliteBool(forKey key: Key) throws -> Bool {
    if let value = try? decode(Bool.self, forKey: key) { return value }
    let value = try decode(Int.self, forKey: key)
    guard value == 0 || value == 1 else {
      throw DecodingError.dataCorruptedError(
        forKey: key,
        in: self,
        debugDescription: "Expected a boolean or SQLite boolean integer"
      )
    }
    return value == 1
  }
}
