import Foundation
import WovenProtocol

/// A group of Woven tools a session may use, as the server defines them.
typealias WorkspaceToolGroup = ToolGroup

enum WorkspaceToolError: Error, LocalizedError, Equatable, Sendable {
  case notFound(String)
  case timerPauseConfirmation
  case invalid(String)

  var errorDescription: String? {
    switch self {
    case .notFound(let message): message
    case .timerPauseConfirmation: "Disabling timers will pause this session’s active timers."
    case .invalid(let message): message
    }
  }
}
