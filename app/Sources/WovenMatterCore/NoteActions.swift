import Foundation

public enum WorkspaceNoteMutation: Codable, Sendable {
  case setPinned(Bool)
  case rename(String)
  case moveToFolder(String?)
  case moveToTrash
  case restore
}

public struct WorkspaceTrashedNote: Codable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let deletedAt: String
  public let isPinned: Bool

  public init(id: String, title: String, deletedAt: String, isPinned: Bool) {
    self.id = id; self.title = title; self.deletedAt = deletedAt; self.isPinned = isPinned
  }
}

public enum WorkspaceNoteExportFormat: String, Codable, Sendable {
  case standard
  case document
}

/// Only this small descriptor crosses the private backend transport.
public struct WorkspaceNoteExport: Codable, Sendable {
  public let url: URL
  public let suggestedFilename: String
  public let fileExtension: String

  public init(url: URL, suggestedFilename: String, fileExtension: String) {
    self.url = url; self.suggestedFilename = suggestedFilename; self.fileExtension = fileExtension
  }
}

/// Produced on a database reader, then staged off the cooperative executor.
public struct WorkspaceNoteExportContent: Sendable {
  public let data: Data
  public let suggestedFilename: String
  public let fileExtension: String

  public init(data: Data, suggestedFilename: String, fileExtension: String) {
    self.data = data; self.suggestedFilename = suggestedFilename; self.fileExtension = fileExtension
  }
}

public enum WorkspaceNoteActionError: LocalizedError, Equatable, Sendable {
  case emptyTitle
  case invalidTitle
  case busy

  public var errorDescription: String? {
    switch self {
    case .emptyTitle: "Enter a name for this note."
    case .invalidTitle: "This name contains unsupported characters or is too long."
    case .busy: "Finish the current note action before trying again."
    }
  }
}
