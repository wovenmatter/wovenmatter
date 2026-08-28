import Foundation

public struct AgentRunLocation: Codable, Equatable, Sendable {
  public let path: String
  public let line: Int?

  public init(path: String, line: Int? = nil) {
    self.path = path
    self.line = line
  }
}

public struct AgentRunFileChange: Codable, Equatable, Identifiable, Sendable {
  public let path: String
  public let oldText: String?
  public let newText: String
  public let unifiedDiff: String?

  public var id: String { path }

  public init(
    path: String,
    oldText: String? = nil,
    newText: String,
    unifiedDiff: String? = nil
  ) {
    self.path = path
    self.oldText = oldText
    self.newText = newText
    self.unifiedDiff = unifiedDiff
  }

  public var additions: Int {
    changedLineCounts.additions
  }

  public var deletions: Int {
    changedLineCounts.deletions
  }

  private var changedLineCounts: (additions: Int, deletions: Int) {
    if let unifiedDiff, !unifiedDiff.isEmpty {
      var additions = 0
      var deletions = 0
      for line in unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
        if line.hasPrefix("+") { additions += 1 }
        if line.hasPrefix("-") { deletions += 1 }
      }
      return (additions, deletions)
    }
    let oldLines = (oldText ?? "").split(separator: "\n", omittingEmptySubsequences: false)
    let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false)
    var additions = 0
    var deletions = 0
    for difference in newLines.difference(from: oldLines) {
      switch difference {
      case .insert: additions += 1
      case .remove: deletions += 1
      }
    }
    return (additions, deletions)
  }
}

public struct AgentRunPlanEntry: Codable, Equatable, Identifiable, Sendable {
  public let content: String
  public let priority: String?
  public let status: String

  public var id: String { content }

  public init(content: String, priority: String? = nil, status: String) {
    self.content = content
    self.priority = priority
    self.status = status
  }
}

public struct AgentRunActivity: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case thought
    case tool
    case plan
    case fileChange = "file_change"
    case progress
    case activity
  }

  public let id: String
  public let kind: Kind
  public let phase: String?
  public let title: String?
  public let detail: String?
  public let status: String?
  public let toolName: String?
  public let content: String?
  /// `true` when `content` is a stream delta to append to the prior activity
  /// with the same ID; `false` marks an authoritative snapshot.
  public let contentIsDelta: Bool?
  public let locations: [AgentRunLocation]
  public let changes: [AgentRunFileChange]
  public let planEntries: [AgentRunPlanEntry]
  public let rawInputJSON: String?
  public let rawOutputJSON: String?
  public let rawPayloadJSON: String?

  public init(
    id: String,
    kind: Kind,
    phase: String? = nil,
    title: String? = nil,
    detail: String? = nil,
    status: String? = nil,
    toolName: String? = nil,
    content: String? = nil,
    contentIsDelta: Bool? = nil,
    locations: [AgentRunLocation] = [],
    changes: [AgentRunFileChange] = [],
    planEntries: [AgentRunPlanEntry] = [],
    rawInputJSON: String? = nil,
    rawOutputJSON: String? = nil,
    rawPayloadJSON: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.phase = phase
    self.title = title
    self.detail = detail
    self.status = status
    self.toolName = toolName
    self.content = content
    self.contentIsDelta = contentIsDelta
    self.locations = locations
    self.changes = changes
    self.planEntries = planEntries
    self.rawInputJSON = rawInputJSON
    self.rawOutputJSON = rawOutputJSON
    self.rawPayloadJSON = rawPayloadJSON
  }

  public func merging(_ update: Self, appendingContent: Bool = false) -> Self {
    precondition(id == update.id)
    let mergedContent: String?
    if (appendingContent || update.contentIsDelta == true),
       let addition = update.content, !addition.isEmpty {
      mergedContent = (content ?? "") + addition
    } else {
      mergedContent = update.content ?? content
    }
    return Self(
      id: id,
      kind: update.kind,
      phase: update.phase ?? phase,
      title: update.title ?? title,
      detail: update.detail ?? detail,
      status: update.status ?? status,
      toolName: update.toolName ?? toolName,
      content: mergedContent,
      contentIsDelta: update.contentIsDelta ?? contentIsDelta,
      locations: update.locations.isEmpty ? locations : update.locations,
      changes: update.changes.isEmpty ? changes : update.changes,
      planEntries: update.planEntries.isEmpty ? planEntries : update.planEntries,
      rawInputJSON: update.rawInputJSON ?? rawInputJSON,
      rawOutputJSON: update.rawOutputJSON ?? rawOutputJSON,
      rawPayloadJSON: update.rawPayloadJSON ?? rawPayloadJSON
    )
  }
}

public struct WorkspaceRunActivityRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let runID: String
  public let conversationID: String
  public let activity: AgentRunActivity
  public let createdAt: String

  public init(
    id: String,
    runID: String,
    conversationID: String,
    activity: AgentRunActivity,
    createdAt: String
  ) {
    self.id = id
    self.runID = runID
    self.conversationID = conversationID
    self.activity = activity
    self.createdAt = createdAt
  }
}
