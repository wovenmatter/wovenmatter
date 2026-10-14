import Foundation

public enum WorkspaceToolGroup: String, CaseIterable, Codable, Identifiable, Sendable {
  case notes, history, sessions, timers, usage, calendar, library, executor, browser, computer
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .notes: "Notes"
    case .history: "Conversation history"
    case .sessions: "Session management"
    case .timers: "Timers"
    case .usage: "Usage data"
    case .calendar: "Calendar"
    case .library: "Library"
    case .executor: "Executor"
    case .browser: "Browser Use"
    case .computer: "Computer Use"
    }
  }
}

public enum WorkspaceToolError: Error, LocalizedError, Equatable, Sendable {
  case disabled(WorkspaceToolGroup)
  case accessRequired(String)
  case coordinationConflict(String)
  case managedLimit(Int)
  case atCapacity(Int)
  case notFound(String)
  case revisionRequired(String)
  case revisionConflict(String)
  case timerPauseConfirmation
  case invalid(String)

  public var errorDescription: String? {
    switch self {
    case .disabled(let group): "\(group.title) is disabled for this session."
    case .accessRequired(let id): "Attach session \(id) or approve access in Woven Matter."
    case .coordinationConflict(let id): "This session is already coordinated by session \(id)."
    case .managedLimit(let limit): "This coordinator already manages the maximum of \(limit) sessions."
    case .atCapacity(let limit): "The maximum of \(limit) sessions are already running."
    case .notFound(let message): message
    case .revisionRequired(let message): message
    case .revisionConflict(let message): message
    case .timerPauseConfirmation: "Disabling timers will pause this session’s active timers."
    case .invalid(let message): message
    }
  }
}
