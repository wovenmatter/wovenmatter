import Foundation

public enum AgentMessageAttachmentKind: String, Codable, Equatable, Sendable {
  case image
  case file
  case note
  case conversation
}

public struct AgentFileAttachmentDraft: Equatable, Identifiable, Sendable {
  public let id: String
  public let kind: AgentMessageAttachmentKind
  public let fileName: String
  public let mimeType: String
  public let sizeBytes: Int64
  public let contentHash: String
  public let localURL: URL

  public init(
    id: String = UUID().uuidString.lowercased(),
    kind: AgentMessageAttachmentKind,
    fileName: String,
    mimeType: String,
    sizeBytes: Int64,
    contentHash: String,
    localURL: URL
  ) {
    precondition(kind == .image || kind == .file)
    self.id = id
    self.kind = kind
    self.fileName = fileName
    self.mimeType = mimeType
    self.sizeBytes = sizeBytes
    self.contentHash = contentHash
    self.localURL = localURL
  }
}

public struct AgentMessageReferenceDraft: Equatable, Identifiable, Sendable {
  public let id: String
  public let kind: AgentMessageAttachmentKind
  public let resourceID: String
  public let titleSnapshot: String
  public let contentSnapshot: String
  public let revisionSnapshot: String
  public let folderIDSnapshot: String?
  public let folderTitleSnapshot: String?
  public let agentCodenameSnapshot: String?

  public init(
    id: String = UUID().uuidString.lowercased(),
    kind: AgentMessageAttachmentKind,
    resourceID: String,
    titleSnapshot: String,
    contentSnapshot: String,
    revisionSnapshot: String,
    folderIDSnapshot: String? = nil,
    folderTitleSnapshot: String? = nil,
    agentCodenameSnapshot: String? = nil
  ) {
    precondition(kind == .note || kind == .conversation)
    self.id = id
    self.kind = kind
    self.resourceID = resourceID
    self.titleSnapshot = titleSnapshot
    self.contentSnapshot = contentSnapshot
    self.revisionSnapshot = revisionSnapshot
    self.folderIDSnapshot = folderIDSnapshot
    self.folderTitleSnapshot = folderTitleSnapshot
    self.agentCodenameSnapshot = agentCodenameSnapshot
  }
}

public enum AgentMessageAttachmentDraft: Equatable, Identifiable, Sendable {
  case file(AgentFileAttachmentDraft)
  case reference(AgentMessageReferenceDraft)

  public var id: String {
    switch self {
    case .file(let value): value.id
    case .reference(let value): value.id
    }
  }

  public var kind: AgentMessageAttachmentKind {
    switch self {
    case .file(let value): value.kind
    case .reference(let value): value.kind
    }
  }

  public var displayName: String {
    switch self {
    case .file(let value): value.fileName
    case .reference(let value): value.titleSnapshot
    }
  }
}

public struct AgentMessageInput: Equatable, Sendable {
  public let text: String
  public let attachments: [AgentMessageAttachmentDraft]

  public init(text: String, attachments: [AgentMessageAttachmentDraft] = []) {
    self.text = text
    self.attachments = attachments
  }

  public var hasContent: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
  }

  public var files: [AgentFileAttachmentDraft] {
    attachments.compactMap {
      guard case .file(let value) = $0 else { return nil }
      return value
    }
  }

  public var references: [AgentMessageReferenceDraft] {
    attachments.compactMap {
      guard case .reference(let value) = $0 else { return nil }
      return value
    }
  }

  /// References are immutable snapshots and are materialized for transports
  /// that do not have a first-class reference primitive. File bytes remain
  /// separate so a transport cannot silently degrade them into prompt text.
  public var textWithReferenceContext: String {
    transportText()
  }

  public func transportText(deliveryText: String? = nil) -> String {
    let baseText = deliveryText ?? text
    let references = references
    guard !references.isEmpty else { return baseText }
    var sections: [String] = []
    let trimmed = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { sections.append(trimmed) }
    for reference in references {
      let label = reference.kind == .note ? "Note" : "Conversation"
      sections.append("""
        <wovenmatter-reference type="\(label.lowercased())" id="\(reference.resourceID)" title="\(reference.titleSnapshot)">
        \(reference.contentSnapshot)
        </wovenmatter-reference>
        """)
    }
    return sections.joined(separator: "\n\n")
  }

  public var previewText: String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty else { return trimmed }
    if attachments.count == 1, let first = attachments.first {
      return "Attached \(first.displayName)"
    }
    return "Attached \(attachments.count) items"
  }
}

public struct WorkspaceMessageAttachmentRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let conversationID: String
  public let messageID: String
  public let kind: AgentMessageAttachmentKind
  public let fileName: String
  public let mimeType: String
  public let sizeBytes: Int64
  public let contentHash: String?
  public let gatewayMediaRef: String?
  public let createdAt: String

  enum CodingKeys: String, CodingKey {
    case id, kind
    case conversationID = "conversation_id"
    case messageID = "message_id"
    case fileName = "file_name"
    case mimeType = "mime_type"
    case sizeBytes = "size_bytes"
    case contentHash = "content_hash"
    case gatewayMediaRef = "gateway_media_ref"
    case createdAt = "created_at"
  }
}

public struct WorkspaceMessageReferenceRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let conversationID: String
  public let messageID: String
  public let kind: AgentMessageAttachmentKind
  public let resourceID: String
  public let titleSnapshot: String
  public let contentSnapshot: String
  public let revisionSnapshot: String
  public let folderIDSnapshot: String?
  public let folderTitleSnapshot: String?
  public let agentCodenameSnapshot: String?
  public let createdAt: String

  enum CodingKeys: String, CodingKey {
    case id
    case conversationID = "conversation_id"
    case messageID = "message_id"
    case kind = "resource_type"
    case resourceID = "resource_id"
    case titleSnapshot = "title_snapshot"
    case contentSnapshot = "content_snapshot"
    case revisionSnapshot = "revision_snapshot"
    case folderIDSnapshot = "folder_id_snapshot"
    case folderTitleSnapshot = "folder_title_snapshot"
    case agentCodenameSnapshot = "agent_codename_snapshot"
    case createdAt = "created_at"
  }
}

public enum AgentMessageAttachmentError: LocalizedError, Equatable, Sendable {
  case tooManyFiles(maximum: Int)
  case fileTooLarge(name: String, maximumBytes: Int64)
  case totalTooLarge(maximumBytes: Int64)
  case unreadableFile(String)
  case unsupportedForAgent(String)

  public var errorDescription: String? {
    switch self {
    case .tooManyFiles(let maximum):
      "Attach up to \(maximum) files to one message."
    case .fileTooLarge(let name, let maximumBytes):
      "\(name) is larger than the \(ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file)) attachment limit."
    case .totalTooLarge(let maximumBytes):
      "The attachments exceed the \(ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file)) message limit."
    case .unreadableFile(let name):
      "Woven Matter could not read \(name)."
    case .unsupportedForAgent(let detail):
      detail
    }
  }
}

public enum AgentMessageAttachmentLimits {
  public static let maximumCount = 8
  public static let maximumFileBytes: Int64 = 25 * 1_024 * 1_024
  public static let maximumTotalBytes: Int64 = 50 * 1_024 * 1_024
  public static let maximumReferenceCharacters = 200_000
}
