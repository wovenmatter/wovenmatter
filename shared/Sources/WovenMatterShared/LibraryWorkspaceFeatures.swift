import Foundation

/// Value-only client contracts. File reads resolve a workspace-owned Library
/// identity; credentials never enter ordinary app-data synchronization.
public enum LibraryWorkspaceRead: Codable, Equatable, Sendable {
  case library(search: String, kind: String?, offset: Int)
  case libraryFile(id: String)
  case calendar(from: Date, to: Date)
  case scheduledTasks
  case databases
  case usage(from: Date, to: Date, offset: Int)
  case session(id: String)
  case trash
  case exportNote(id: String, format: String, revision: String)
  case exportConversation(id: String, format: String)
}

public enum LibraryWorkspaceAction: Codable, Equatable, Sendable {
  case conversation(id: String, action: String, title: String?, folderID: String?)
  case note(id: String, action: String, revision: String, title: String?, folderID: String?)
  case goal(id: String, mutation: WorkspaceGoalMutation)
  case configureSession(id: String, model: String?, thinking: String?, permission: String?)
  case sessionTools(id: String, enabled: [String], confirmPausingTimers: Bool)
  case saveCalendar(id: String, revision: Int?, draft: LibraryCalendarDraft)
  case deleteCalendar(id: String, revision: Int, occurrence: Int?)
  case retryLibrary(id: String)
}

public struct FileContents: Codable, Equatable, Sendable {
  public var name: String
  public var mimeType: String
  public var data: Data
  public init(name: String, mimeType: String, data: Data) {
    self.name = name; self.mimeType = mimeType; self.data = data
  }
}

public struct LibraryListItem: Codable, Equatable, Identifiable, Sendable {
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

public struct SessionSettingOption: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var label: String
  /// What the choice does, when the harness or Woven describes it.
  public var description: String?
  public init(id: String, label: String, description: String? = nil) { self.id = id; self.label = label; self.description = description }
}

public struct SessionSettings: Codable, Equatable, Sendable {
  public var conversationID: String
  public var model: String?
  public var thinking: String?
  public var permission: String?
  public var models: [SessionSettingOption]
  public var thinkingLevels: [SessionSettingOption]
  public var permissions: [SessionSettingOption]
  public var availableTools: [SessionSettingOption]
  public var enabledTools: [String]
  public var goal: WorkspaceGoal?
  public var canConfigure: Bool
  /// The harness's slash commands (ACP `available_commands_update`), for the composer's palette.
  public var commands: [SessionCommand]?
  public init(conversationID: String, model: String?, thinking: String?, permission: String?,
              models: [SessionSettingOption], thinkingLevels: [SessionSettingOption], permissions: [SessionSettingOption],
              availableTools: [SessionSettingOption], enabledTools: [String], canConfigure: Bool, goal: WorkspaceGoal? = nil,
              commands: [SessionCommand]? = nil) {
    self.conversationID = conversationID; self.model = model; self.thinking = thinking; self.permission = permission
    self.models = models; self.thinkingLevels = thinkingLevels; self.permissions = permissions
    self.availableTools = availableTools; self.enabledTools = enabledTools; self.canConfigure = canConfigure; self.goal = goal
    self.commands = commands
  }
}

/// One slash command a session's harness offers.
public struct SessionCommand: Codable, Equatable, Sendable {
  public var name: String
  public var detail: String?
  public var argumentHint: String?
  public init(name: String, detail: String? = nil, argumentHint: String? = nil) {
    self.name = name; self.detail = detail; self.argumentHint = argumentHint
  }
}

public struct LibraryCalendarDraft: Codable, Equatable, Sendable {
  public var title: String
  public var details: String
  public var startsAt: Date
  public var endsAt: Date?
  public var allDay: Bool
  public var timeZoneID: String
  public var recurrenceUnit: String?
  public var recurrenceInterval: Int
  public var task: ScheduledTask?
  /// Nil reads as shown on the calendar, except that an edit to an existing task keeps the
  /// task’s current visibility.
  public var showsOnCalendar: Bool?
  public init(title: String = "", details: String = "", startsAt: Date = Date(), endsAt: Date? = nil,
              allDay: Bool = false, timeZoneID: String = TimeZone.current.identifier,
              recurrenceUnit: String? = nil, recurrenceInterval: Int = 1, task: ScheduledTask? = nil, showsOnCalendar: Bool? = nil) {
    self.title = title; self.details = details; self.startsAt = startsAt; self.endsAt = endsAt
    self.allDay = allDay; self.timeZoneID = timeZoneID; self.recurrenceUnit = recurrenceUnit
    self.recurrenceInterval = recurrenceInterval; self.task = task; self.showsOnCalendar = showsOnCalendar
  }
}

public struct ScheduledTask: Codable, Equatable, Sendable {
  public var prompt: String
  public var runtime: String
  public var workspaceID: String?
  public var model: String?
  public var thinking: String?
  public var permission: String?
  public var folderID: String?
  public var newSessionEachTime: Bool
  public var enabledTools: [String]?
  public init(prompt: String = "", runtime: String = "default_agent", workspaceID: String? = nil,
              model: String? = nil, thinking: String? = nil, permission: String? = nil,
              folderID: String? = nil, newSessionEachTime: Bool = false, enabledTools: [String]? = nil) {
    self.prompt = prompt; self.runtime = runtime; self.workspaceID = workspaceID
    self.model = model; self.thinking = thinking; self.permission = permission
    self.folderID = folderID; self.newSessionEachTime = newSessionEachTime; self.enabledTools = enabledTools
  }
}

public struct LibraryCalendarEvent: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var revision: Int
  public var draft: LibraryCalendarDraft
  public var occurrence: Int
  public var startsAt: Date
  public var status: String?
  public var sessionID: String?
  public var occurrenceID: String { "\(id):\(occurrence)" }
  public init(id: String, revision: Int, draft: LibraryCalendarDraft, occurrence: Int = 0, startsAt: Date? = nil,
              status: String? = nil, sessionID: String? = nil) {
    self.id = id; self.revision = revision; self.draft = draft; self.occurrence = occurrence; self.startsAt = startsAt ?? draft.startsAt
    self.status = status; self.sessionID = sessionID
  }
}

public struct TrashedItem: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var kind: String
  public var revision: String?
  public init(id: String, title: String, kind: String, revision: String? = nil) {
    self.id = id; self.title = title; self.kind = kind; self.revision = revision
  }
}

public enum LibraryWorkspaceResult: Codable, Equatable, Sendable {
  case library(items: [LibraryListItem], hasMore: Bool)
  case file(FileContents)
  case calendar([LibraryCalendarEvent])
  case scheduledTasks([ScheduledTaskItem])
  case databases([LibraryDatabaseSource])
  case usage(samples: [LibraryUsageSample], hasMore: Bool)
  case session(SessionSettings)
  case trash([TrashedItem])
}
