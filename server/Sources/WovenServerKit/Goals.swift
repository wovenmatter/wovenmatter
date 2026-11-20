import Foundation
import WovenLibrary
import WovenProtocol

// A goal is a prompt that belongs to its session (`sessions.goal`). The
// owning server works the session against it the same way on every runtime:
//
// - Setting a goal while the session is idle starts a turn toward it.
// - Each time a turn ends with the goal still set, the server sends the next
//   turn, asking the runtime to continue toward it.
// - The agent says the goal is met with the Woven tool `goal_met`, which
//   clears it; the person can clear it at any time.
// - It does not continue after an interrupted or failed turn, nor while a
//   question or approval waits. The person's next message resumes it.

enum Goals {
  static let author = ItemAuthor(botID: nil, name: "Goal", source: .goal)

  /// What the chat shows for a turn that continues toward the goal.
  static let continuedText = "Continue toward the goal."

  static func start(_ goal: String) -> String {
    """
    Work toward this goal until it is met:

    \(goal)

    When it is met, call the Woven tool `goal_met` with a short account of what shows it is met. \
    Until then, each time you stop you will be asked to continue.
    """
  }

  static func continuation(_ goal: String) -> String {
    """
    Continue working toward the goal:

    \(goal)

    When it is met, call the Woven tool `goal_met` with what shows it is met.
    """
  }

  /// Sets or clears a session's goal on its owner; a goal set while the
  /// session is idle starts a turn toward it.
  static func set(_ sessionID: String, goal: String?, sessions: SessionManager, library: Library) async throws -> Session {
    let host = try await sessions.host(for: sessionID)
    let goal = goal?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = goal?.isEmpty == false ? goal : nil
    _ = try await library.updateSession(sessionID, goal: .some(value))
    if let value {
      // A turn already running continues toward it when it ends.
      do {
        try await host.send(value, attachments: [], delivered: start(value))
      } catch let error as ProtocolError where error.code == .busy {}
    }
    guard let session = try await library.session(sessionID) else { throw ProtocolError(.notFound, "No session \(sessionID).") }
    return session
  }
}

func registerGoals(_ router: inout Router, library: Library, sessions: SessionManager) {
  router.on(SetGoal.self) { request, _ in
    try await Goals.set(request.sessionID, goal: request.goal, sessions: sessions, library: library)
  }
}
