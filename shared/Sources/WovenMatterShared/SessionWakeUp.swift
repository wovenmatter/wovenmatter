import Foundation

/// Agent-to-agent waiting (docs/architecture/WOVEN_EVERYWHERE.md, "Streaming",
/// "Agent to agent"). The Linux server (`remote/src/session-watch.mjs`) and the
/// Mac implement the same behaviour; `SessionWakeUpFixtures.json` checks that
/// both build the same text.
///
/// **States** are exactly `woven_sessions_status`'s `state`: `needsInput`
/// while the session has any pending question or approval, else `running`
/// while it has an active run, else `idle`.
///
/// **`woven_sessions_wait {id, workspace?, until, timeoutSeconds}`.** `until`
/// is `idle`, `needsInput` or `either` (idle or needsInput); `timeoutSeconds`
/// is 1…`StreamProtocol.maximumWaitSeconds`. It reads the status first and
/// returns at once when the state is already there. Otherwise it waits for a
/// change of that session on the stream (the destination's `workspace`
/// stream, or this server's own execution changes for its own workspace) and
/// reads the status again to confirm; nothing polls. At the timeout it reads
/// the status once more. The reply is the `woven_sessions_status` body plus
/// `state` and `timedOut`, which is true exactly when the returned state does
/// not reach `until`. It needs the same access as `woven_sessions_status`.
///
/// **Wake-ups.** Only for sessions the caller created with
/// `woven_sessions_create` and the server remembers (`member_sessions` on
/// Linux, `member_tool_sessions` on a Mac); sessions coordinated on the
/// caller's own workspace get coordination notifications instead.
/// - A session is *watched* once the caller makes it run (create, send, steer,
///   respond) or reads it running or waiting for input (status, wait). The
///   server keeps one stream per destination while it watches a session there.
/// - A watched session that becomes `idle` produces a *finished* wake-up and is
///   no longer watched; one that becomes `needsInput` with a new set of pending
///   interactions produces a *waiting* wake-up.
/// - One pending wake-up per session: a newer state replaces it, the session
///   running again drops it, and the caller reading that same state through
///   `woven_sessions_status` or `woven_sessions_wait` drops it. Stopping the
///   session with `woven_sessions_stop` ends watching without a wake-up.
/// - A wake-up reaches a calling conversation only while it has no active run,
///   as an ordinary send (never a steer) that starts a turn. Its provenance is
///   the woken-about session (`agentSourceID`, `senderKind: notification`), and
///   it is a coordination notification, so the woken turn does not notify the
///   caller's own coordinator.
/// - At most `StreamProtocol.maximumWakeUpsPerRun` per calling run: the count
///   belongs to the caller's latest run that a wake-up did not start, and runs
///   that wake-ups start add to it. A run started any other way (a user message,
///   a timer, a goal, another agent) starts a new count. The last allowed
///   wake-up says so (`last`); later ones are dropped.
/// - Bots have no runs the server can see: a bot's wake-up goes to the bots
///   runtime at once (which queues it as a follow-up while the bot is busy),
///   and its count starts again whenever the bot creates a session.
/// - The command (or bot delivery) ID derives from the caller, the session and
///   the state (`finished:<the run last seen running>` or
///   `needsInput:<sorted interaction IDs>`), so a wake-up is delivered once.
/// - Watched sessions and pending wake-ups are stored, so they survive a
///   restart: the server subscribes again and compares the snapshot with the
///   stored state.
public enum SessionWakeUp {
  public enum Kind: String, Codable, Sendable { case finished, needsInput }

  public static let maximumTitleCharacters = 200
  public static let maximumQuestionCharacters = 300

  /// The message delivered into the calling session. `title` and `question`
  /// are collapsed to single spaces and clipped (in Unicode scalars); the
  /// question gets a full stop unless it ends with `.`, `?`, `!` or `…`.
  public static func text(kind: Kind, sessionID: String, title: String?, workspaceName: String,
                          question: String? = nil, last: Bool = false) -> String {
    let name = clean(title, maximumTitleCharacters).map { "\"\($0)\" (\(sessionID))" } ?? sessionID
    var text: String
    switch kind {
    case .finished:
      text = "Your session \(name) on \(workspaceName) finished. Read it with woven_sessions_status."
    case .needsInput:
      let asked = clean(question, maximumQuestionCharacters) ?? "a question"
      let stop = [".", "?", "!", "…"].contains { asked.hasSuffix($0) } ? "" : "."
      text = "Your session \(name) on \(workspaceName) is waiting for your answer: \(asked)\(stop) Read it with woven_sessions_status and answer with woven_sessions_respond."
    }
    if last {
      text += " This is your last wake-up until something else starts you: wait with woven_sessions_wait or check woven_sessions_status yourself."
    }
    return text
  }

  private static func clean(_ value: String?, _ limit: Int) -> String? {
    guard let value else { return nil }
    let words = value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    guard !words.isEmpty else { return nil }
    let scalars = words.unicodeScalars
    guard scalars.count > limit else { return words }
    return String(String.UnicodeScalarView(scalars.prefix(limit))) + "…"
  }
}
