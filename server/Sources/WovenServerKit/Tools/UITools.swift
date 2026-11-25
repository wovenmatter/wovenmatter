import Foundation
import Synchronization
import WovenProtocol

/// Hands browser, computer-use and visual-reply preview calls to the UI on this Mac
/// and waits for its answer. macOS ties those permissions to the app, and only
/// the app has the chat's web view, so the server never carries them out
/// itself. The newest connected UI takes each call.
final class UIToolBroker: Sendable {
  /// How long a UI may take to answer.
  static let answerLimit = Duration.seconds(90)

  private struct State {
    var subscribers: [(id: UUID, continuation: AsyncStream<UIToolCall>.Continuation)] = []
    var waiting: [String: CheckedContinuation<ToolResult, Never>] = [:]
  }

  private let state = Mutex(State())

  func subscribe() -> AsyncStream<UIToolCall> {
    let (stream, continuation) = AsyncStream<UIToolCall>.makeStream(bufferingPolicy: .bufferingOldest(64))
    let id = UUID()
    state.withLock { $0.subscribers.append((id, continuation)) }
    continuation.onTermination = { [weak self] _ in
      self?.state.withLock { state in state.subscribers.removeAll { $0.id == id } }
    }
    return stream
  }

  /// Whether a UI on this Mac is connected to take calls.
  var hasUI: Bool { state.withLock { !$0.subscribers.isEmpty } }

  /// Has the app on this Mac update itself with no window or click: opens it
  /// when no UI is connected, then asks it. Returns once the download has
  /// started; throws why it could not.
  func updateApp() async throws {
    if !hasUI {
      guard let bundleID = Bundle.main.bundleIdentifier else {
        throw ProtocolError(.failed, "Woven Matter is not installed as an app on this Mac.")
      }
      let open = Process()
      open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      open.arguments = ["-g", "-b", bundleID]
      try? open.run()
      open.waitUntilExit()
      for _ in 0..<120 where !hasUI { try? await Task.sleep(for: .milliseconds(500)) }
    }
    let result = await carryOut(Self.appUpdateTool, arguments: .object([:]), sessionID: nil,
                                absent: "Woven Matter could not be opened on this Mac to update it.")
    guard result.isError else { return }
    let message = result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ")
    throw ProtocolError(.failed, message)
  }

  /// The UI call that has the app update itself.
  static let appUpdateTool = "app_update"

  func answer(_ id: String, _ result: ToolResult) {
    state.withLock { $0.waiting.removeValue(forKey: id) }?.resume(returning: result)
  }

  /// Asks the newest UI to carry out `tool`; fails at once with none
  /// connected, saying `absent` when given.
  func carryOut(_ tool: String, arguments: JSONValue, sessionID: String?, absent: String? = nil) async -> ToolResult {
    let id = UUID().uuidString.lowercased()
    let call = UIToolCall(id: id, tool: tool, arguments: arguments, sessionID: sessionID)
    let timer = Task { [weak self] in
      try? await Task.sleep(for: Self.answerLimit)
      self?.answer(id, .error("Woven Matter did not finish the \(tool) action in time. Look at the current state before trying again."))
    }
    defer { timer.cancel() }
    return await withCheckedContinuation { continuation in
      let sent = state.withLock { state -> Bool in
        guard let subscriber = state.subscribers.last else { return false }
        state.waiting[id] = continuation
        if case .enqueued = subscriber.continuation.yield(call) { return true }
        state.waiting[id] = nil
        return false
      }
      if !sent {
        continuation.resume(returning: .error(absent ??
          "The \(tool) tool needs the Woven Matter app open on this machine, and it is not. Ask the person to open it, or do without."))
      }
    }
  }
}
