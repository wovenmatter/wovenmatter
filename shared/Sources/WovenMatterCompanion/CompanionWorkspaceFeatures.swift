import Foundation

/// Value-only client contracts. File reads resolve a workspace-owned Library
/// identity; credentials never enter ordinary app-data synchronization.
public enum CompanionWorkspaceRead: Codable, Equatable, Sendable {
  case library(search: String, kind: String?, offset: Int)
  case libraryFile(id: String)
  case calendar(from: Date, to: Date)
  case session(id: String)
  case trash
  case exportNote(id: String, format: String, revision: String)
  case exportConversation(id: String, format: String)
}

public enum CompanionWorkspaceAction: Codable, Equatable, Sendable {
  case conversation(id: String, action: String, title: String?, folderID: String?)
  case note(id: String, action: String, revision: String, title: String?, folderID: String?)
  case configureSession(id: String, model: String?, thinking: String?, permission: String?)
  case sessionTools(id: String, enabled: [String], confirmPausingTimers: Bool)
  case saveCalendar(id: String, revision: Int?, draft: CompanionCalendarDraft)
  case deleteCalendar(id: String, revision: Int, occurrence: Int?)
  case retryLibrary(id: String)
}

public struct CompanionFile: Codable, Equatable, Sendable {
  public var name: String
  public var mimeType: String
  public var data: Data
  public init(name: String, mimeType: String, data: Data) {
    self.name = name; self.mimeType = mimeType; self.data = data
  }
}

public struct CompanionLibraryItem: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var conversationID: String
  public var title: String
  public var kind: String
  public var sender: String
  public var workspace: String
  public var agent: String
  public var sentAt: String
  public var sizeBytes: Int64?
  public var webURL: URL?
  public var available: Bool
  public var error: String?
  public init(id: String, conversationID: String, title: String, kind: String, sender: String,
              workspace: String, agent: String, sentAt: String, sizeBytes: Int64?, webURL: URL?,
              available: Bool, error: String?) {
    self.id = id; self.conversationID = conversationID; self.title = title; self.kind = kind
    self.sender = sender; self.workspace = workspace; self.agent = agent; self.sentAt = sentAt
    self.sizeBytes = sizeBytes; self.webURL = webURL; self.available = available; self.error = error
  }
}

public struct CompanionSelection: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var label: String
  public init(id: String, label: String) { self.id = id; self.label = label }
}

public struct CompanionSessionSettings: Codable, Equatable, Sendable {
  public var conversationID: String
  public var model: String?
  public var thinking: String?
  public var permission: String?
  public var models: [CompanionSelection]
  public var thinkingLevels: [CompanionSelection]
  public var permissions: [CompanionSelection]
  public var availableTools: [CompanionSelection]
  public var enabledTools: [String]
  public var canConfigure: Bool
  public init(conversationID: String, model: String?, thinking: String?, permission: String?,
              models: [CompanionSelection], thinkingLevels: [CompanionSelection], permissions: [CompanionSelection],
              availableTools: [CompanionSelection], enabledTools: [String], canConfigure: Bool) {
    self.conversationID = conversationID; self.model = model; self.thinking = thinking; self.permission = permission
    self.models = models; self.thinkingLevels = thinkingLevels; self.permissions = permissions
    self.availableTools = availableTools; self.enabledTools = enabledTools; self.canConfigure = canConfigure
  }
}

public struct CompanionCalendarDraft: Codable, Equatable, Sendable {
  public var title: String
  public var details: String
  public var startsAt: Date
  public var endsAt: Date?
  public var allDay: Bool
  public var timeZoneID: String
  public var recurrenceUnit: String?
  public var recurrenceInterval: Int
  public var task: CompanionScheduledTask?
  public init(title: String = "", details: String = "", startsAt: Date = Date(), endsAt: Date? = nil,
              allDay: Bool = false, timeZoneID: String = TimeZone.current.identifier,
              recurrenceUnit: String? = nil, recurrenceInterval: Int = 1, task: CompanionScheduledTask? = nil) {
    self.title = title; self.details = details; self.startsAt = startsAt; self.endsAt = endsAt
    self.allDay = allDay; self.timeZoneID = timeZoneID; self.recurrenceUnit = recurrenceUnit
    self.recurrenceInterval = recurrenceInterval; self.task = task
  }
}

public struct CompanionScheduledTask: Codable, Equatable, Sendable {
  public var prompt: String
  public var runtime: String
  public var workspaceID: String?
  public var model: String?
  public var thinking: String?
  public var permission: String?
  public var folderID: String?
  public var newSessionEachTime: Bool
  public init(prompt: String = "", runtime: String = "default_agent", workspaceID: String? = nil,
              model: String? = nil, thinking: String? = nil, permission: String? = nil,
              folderID: String? = nil, newSessionEachTime: Bool = false) {
    self.prompt = prompt; self.runtime = runtime; self.workspaceID = workspaceID
    self.model = model; self.thinking = thinking; self.permission = permission
    self.folderID = folderID; self.newSessionEachTime = newSessionEachTime
  }
}

public struct CompanionCalendarEvent: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var revision: Int
  public var draft: CompanionCalendarDraft
  public var occurrence: Int
  public var startsAt: Date
  public var status: String?
  public var sessionID: String?
  public var occurrenceID: String { "\(id):\(occurrence)" }
  public init(id: String, revision: Int, draft: CompanionCalendarDraft, occurrence: Int = 0, startsAt: Date? = nil,
              status: String? = nil, sessionID: String? = nil) {
    self.id = id; self.revision = revision; self.draft = draft; self.occurrence = occurrence; self.startsAt = startsAt ?? draft.startsAt
    self.status = status; self.sessionID = sessionID
  }
}

public struct CompanionTrashedItem: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var kind: String
  public var revision: String?
  public init(id: String, title: String, kind: String, revision: String? = nil) {
    self.id = id; self.title = title; self.kind = kind; self.revision = revision
  }
}

public enum CompanionWorkspaceResult: Codable, Equatable, Sendable {
  case library(items: [CompanionLibraryItem], hasMore: Bool)
  case file(CompanionFile)
  case calendar([CompanionCalendarEvent])
  case session(CompanionSessionSettings)
  case trash([CompanionTrashedItem])
}
