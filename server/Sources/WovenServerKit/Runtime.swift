import Foundation
import WovenProtocol

// The one adapter interface. Codex, Claude Code, Grok Build, OpenCode, Pi
// Durable and bots each implement it and are treated alike.

/// What the server tells a runtime when it opens a session.
public struct RuntimeStart: Sendable {
  /// The Woven session this native session serves.
  public var sessionID: String
  /// The folder's directory, when the session is in a folder.
  public var directory: String?
  /// The native session to resume, or nil to start a new one.
  public var nativeHandle: String?

  public init(sessionID: String, directory: String?, nativeHandle: String?) {
    self.sessionID = sessionID
    self.directory = directory
    self.nativeHandle = nativeHandle
  }
}

/// What a runtime reports while its process runs. Events come in order on
/// one stream for the life of the process, across turns.
public enum RuntimeEvent: Sendable {
  /// More text of the assistant message in progress (one is started if none is).
  case text(String)
  /// The assistant message in progress is complete.
  case messageFinished
  case toolStarted(callID: String, name: String, input: String)
  case toolFinished(callID: String, output: String, failed: Bool)
  /// The runtime waits for an answer to a question or approval.
  case prompt(Prompt)
  /// A prompt was answered or withdrawn.
  case promptResolved(id: String)
  /// The turn ended; `failure` says why when it failed.
  case turnFinished(failure: String?)
  /// The runtime lost the native session behind this chat.
  case nativeSessionGone
  /// The process ended. The next turn opens the session again.
  case exited
}

public enum RuntimeError: Error, Sendable {
  /// The native session asked for no longer exists. A runtime never starts a
  /// fresh one in its place.
  case nativeSessionGone
  case failed(String)
}

public protocol Runtime: Sendable {
  var kind: RuntimeKind { get }
  /// Starts a native session, or resumes `start.nativeHandle`. Throws
  /// `RuntimeError.nativeSessionGone` when that one is gone.
  func open(_ start: RuntimeStart) async throws -> any RuntimeSession
}

/// One native session with its process, kept alive between turns.
public protocol RuntimeSession: Sendable {
  /// The runtime's own identifier for the native session, for resuming it.
  var nativeHandle: String { get }
  /// Every event of the process's life, across turns.
  var events: AsyncStream<RuntimeEvent> { get }
  /// Starts a turn. Returns once the runtime has taken it, not when it ends.
  func send(_ text: String) async throws
  func answer(promptID: String, with answer: String) async throws
  func interrupt() async throws
  /// Ends the process. The native session stays for a later resume.
  func stop() async
}
