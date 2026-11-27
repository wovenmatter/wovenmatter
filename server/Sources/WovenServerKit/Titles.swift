import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol

/// Hears the person's first message in each session.
final class FirstMessageHook: Sendable {
  private let action = Mutex<(@Sendable (String, String) -> Void)?>(nil)

  func set(_ value: @escaping @Sendable (_ sessionID: String, _ text: String) -> Void) { action.withLock { $0 = value } }
  func tell(_ sessionID: String, _ text: String) { action.withLock { $0 }?(sessionID, text) }
}

/// Told when a turn of a runtime that keeps its own history ends, so its
/// usage is read soon.
final class HistoryTurnHook: Sendable {
  private let action = Mutex<(@Sendable () -> Void)?>(nil)

  func set(_ value: @escaping @Sendable () -> Void) { action.withLock { $0 = value } }
  func tell() { action.withLock { $0 }?() }
}

/// How the bots' host keeps their usage counted across a purge and a move:
/// it reads their store first, hands over where it read it to, and, on the
/// machine they move to, takes that place over before the store arrives.
final class BotsUsageHook: Sendable {
  struct Actions: Sendable {
    var read: @Sendable () async -> Void
    var place: @Sendable () async -> String?
    var install: @Sendable (String?) async throws -> Void
  }

  private let actions = Mutex<Actions?>(nil)

  func set(_ value: Actions) { actions.withLock { $0 = value } }
  func read() async { await actions.withLock { $0 }?.read() }
  func place() async -> String? { await actions.withLock { $0 }?.place() }
  func install(_ place: String?) async throws { try await actions.withLock { $0 }?.install(place) }
}

/// Names a new chat from the person's first message, the same way for every
/// runtime: when `titles.enabled` is set, a throwaway native session of the
/// title runtime (Codex, with `titles.model` and `titles.thinking`) is asked
/// for a short title, which replaces the chat's own unless it was renamed in
/// the meantime.
final class Titles: Sendable {
  static let enabledKey = "titles.enabled"
  static let modelKey = "titles.model"
  static let thinkingKey = "titles.thinking"
  /// How long the title runtime may take.
  static let limit = Duration.seconds(90)

  private let library: Library
  private let sessions: SessionManager
  private let runtime: RuntimeKind
  private let scratch: URL

  init(library: Library, sessions: SessionManager, runtime: RuntimeKind, scratch: URL) {
    self.library = library
    self.sessions = sessions
    self.runtime = runtime
    self.scratch = scratch
    sessions.firstMessages.set { [weak self] sessionID, text in
      guard let self else { return }
      Task { await self.name(sessionID, from: text) }
    }
  }

  private func name(_ sessionID: String, from text: String) async {
    guard case .bool(true)? = try? await library.setting(Self.enabledKey)?.value,
          let session = try? await library.session(sessionID), session.runtime != .bots,
          let runtime = await sessions.runtime(runtime) else { return }
    let before = session.title
    guard let title = try? await generate(text, with: runtime), !title.isEmpty,
          let current = try? await library.session(sessionID), current.title == before else { return }
    _ = try? await library.updateSession(sessionID, title: title)
  }

  private func generate(_ text: String, with runtime: any Runtime) async throws -> String {
    let directory = scratch.appendingPathComponent("titles/\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func string(_ key: String) async -> String? {
      guard case .string(let value)? = try? await library.setting(key)?.value, !value.isEmpty else { return nil }
      return value
    }
    let choices = SessionChoices(model: await string(Self.modelKey), thinking: await string(Self.thinkingKey))
    let live = try await runtime.open(RuntimeStart(sessionID: "title-" + UUID().uuidString.lowercased(),
                                                   directory: directory.path, nativeHandle: nil, choices: choices))
    let reply = Task { () -> String in
      var reply = ""
      for await event in live.events {
        switch event {
        case .text(let delta): reply += delta
        case .turnFinished, .exited, .nativeSessionGone: return reply
        default: continue
        }
      }
      return reply
    }
    let timeout = Task {
      try? await Task.sleep(for: Self.limit)
      reply.cancel()
      await live.stop()
    }
    defer { timeout.cancel() }
    try await live.send(Turn(text: Self.instructions + "\n\nFirst message:\n" + String(text.prefix(4000))))
    let raw = await reply.value
    await live.stop()
    return Self.sanitize(raw)
  }

  /// The title from the runtime's reply: its JSON `title`, else its first
  /// line, without quotes or a closing full stop, at most 50 characters.
  static func sanitize(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    func title(_ text: Substring) -> String? {
      guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
      return object["title"] as? String
    }
    var candidate = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end,
       let found = title(trimmed[start...end]) {
      candidate = found
    }
    let normalized = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " `\"'“”\n\r\t"))
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard normalized.count > 50 else { return normalized }
    return String(normalized.prefix(47)).trimmingCharacters(in: .whitespaces) + "…"
  }

  static let instructions = """
    Generate a short title that helps the user recognize this conversation later.
    Return only JSON in this form: {"title":"..."}.
    Aim for 3 to 8 words and fewer than 40 characters.
    Name the main topic and requested outcome. Avoid workflow, tool, model or agent names unless they are the subject of the conversation.
    Do not claim completion. Do not include quotation marks within the title or end it with punctuation.
    Do not call tools or modify files.
    """
}
