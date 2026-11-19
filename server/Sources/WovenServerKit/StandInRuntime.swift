import Foundation
import Synchronization
import WovenProtocol

/// A runtime that calls no provider, for tests. Each turn answers
/// "Turn N: <text>" (N counts the turns its native session has seen), in two
/// pieces of text, then makes one tool call.
public final class StandInRuntime: Runtime {
  public static let kind = RuntimeKind(rawValue: "standIn")
  public var kind: RuntimeKind { Self.kind }

  /// The stand-in's own native storage, which outlives a server the way a
  /// real runtime's session files do.
  public final class NativeStore: Sendable {
    private let sessions = Mutex<[String: Int]>([:])
    private let counts = Mutex<(started: Int, resumed: Int)>((0, 0))

    public init() {}

    /// Native sessions started fresh, and resumed.
    public var started: Int { counts.withLock { $0.started } }
    public var resumed: Int { counts.withLock { $0.resumed } }

    /// Loses a native session, as a runtime does when its files are removed.
    public func forget(_ handle: String) { _ = sessions.withLock { $0.removeValue(forKey: handle) } }
    public func forgetAll() { sessions.withLock { $0.removeAll() } }

    func start() -> String {
      let handle = "stand-in-" + UUID().uuidString.lowercased()
      sessions.withLock { $0[handle] = 0 }
      counts.withLock { $0.started += 1 }
      return handle
    }

    func resume(_ handle: String) -> Bool {
      guard sessions.withLock({ $0[handle] != nil }) else { return false }
      counts.withLock { $0.resumed += 1 }
      return true
    }

    func nextTurn(_ handle: String) -> Int {
      sessions.withLock { sessions in
        let turn = (sessions[handle] ?? 0) + 1
        sessions[handle] = turn
        return turn
      }
    }
  }

  /// Holds each turn after its first piece of text until opened.
  public actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func open() {
      isOpen = true
      for waiter in waiters { waiter.resume() }
      waiters.removeAll()
    }

    func wait() async {
      if isOpen { return }
      await withCheckedContinuation { waiters.append($0) }
    }
  }

  public let store: NativeStore
  public let gate: Gate?

  public init(store: NativeStore = NativeStore(), gate: Gate? = nil) {
    self.store = store
    self.gate = gate
  }

  public func open(_ start: RuntimeStart) async throws -> any RuntimeSession {
    if let handle = start.nativeHandle {
      guard store.resume(handle) else { throw RuntimeError.nativeSessionGone }
      return StandInSession(handle: handle, store: store, gate: gate)
    }
    return StandInSession(handle: store.start(), store: store, gate: gate)
  }
}

private final class StandInSession: RuntimeSession {
  let nativeHandle: String
  let events: AsyncStream<RuntimeEvent>
  private let emit: AsyncStream<RuntimeEvent>.Continuation
  private let store: StandInRuntime.NativeStore
  private let gate: StandInRuntime.Gate?
  private let turn = Mutex<Task<Void, Never>?>(nil)

  init(handle: String, store: StandInRuntime.NativeStore, gate: StandInRuntime.Gate?) {
    nativeHandle = handle
    (events, emit) = AsyncStream<RuntimeEvent>.makeStream()
    self.store = store
    self.gate = gate
  }

  func send(_ text: String) async throws {
    let number = store.nextTurn(nativeHandle)
    let emit = emit
    let gate = gate
    let task = Task {
      emit.yield(.text("Turn \(number): "))
      await gate?.wait()
      if Task.isCancelled { return }
      emit.yield(.text(text))
      emit.yield(.messageFinished)
      emit.yield(.toolStarted(callID: "echo-\(number)", name: "echo", input: "{\"text\":\"\(text)\"}"))
      emit.yield(.toolFinished(callID: "echo-\(number)", output: text, failed: false))
      emit.yield(.turnFinished(failure: nil))
    }
    turn.withLock { $0 = task }
  }

  func answer(promptID: String, with answer: String) async throws {
    emit.yield(.promptResolved(id: promptID))
  }

  func interrupt() async throws {
    turn.withLock { $0?.cancel() }
    emit.yield(.turnFinished(failure: nil))
  }

  func stop() async {
    turn.withLock { $0?.cancel() }
    emit.yield(.exited)
    emit.finish()
  }
}
