import Foundation

public enum AgentMessageAttachmentKind: String, Hashable, Sendable {
  case image
  case file
  case note
  case conversation
}

/// A file queued in the composer, staged on this Mac until the message is sent.
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

/// A note or chat queued in the composer. The server reads it when the message is sent.
public struct AgentMessageReferenceDraft: Equatable, Identifiable, Sendable {
  public let id: String
  public let kind: AgentMessageAttachmentKind
  public let resourceID: String
  public let titleSnapshot: String

  public init(id: String = UUID().uuidString.lowercased(), kind: AgentMessageAttachmentKind,
              resourceID: String, titleSnapshot: String) {
    precondition(kind == .note || kind == .conversation)
    self.id = id
    self.kind = kind
    self.resourceID = resourceID
    self.titleSnapshot = titleSnapshot
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

/// What the person sends: the text, the queued attachments and the artifacts and browser tabs open beside the chat.
public struct AgentMessageInput: Equatable, Sendable {
  public let text: String
  public let attachments: [AgentMessageAttachmentDraft]
  public let visibleWorkspace: WorkspaceVisibleContext?

  public init(text: String, attachments: [AgentMessageAttachmentDraft] = [], visibleWorkspace: WorkspaceVisibleContext? = nil) {
    self.text = text
    self.attachments = attachments
    self.visibleWorkspace = visibleWorkspace
  }

  public var hasContent: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
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
