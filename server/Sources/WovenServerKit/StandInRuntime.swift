import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Synchronization
import WovenProtocol

/// A runtime that calls no provider, for tests. Each turn answers
/// "Turn N: <text>" (N counts the turns its native session has seen), in two
/// pieces of text, then makes one tool call. A turn `woven NAME {arguments}`
/// instead calls that Woven tool through the session's tool socket, as a
/// runtime's MCP client would, and reports its result.
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

  public func status() async -> RuntimeStatus {
    RuntimeStatus(runtime: kind, name: "Stand-in", installed: true)
  }

  public func open(_ start: RuntimeStart) async throws -> any RuntimeSession {
    if let handle = start.nativeHandle {
      guard store.resume(handle) else { throw RuntimeError.nativeSessionGone }
      return StandInSession(handle: handle, store: store, gate: gate, tools: start.tools)
    }
    return StandInSession(handle: store.start(), store: store, gate: gate, tools: start.tools)
  }
}

private final class StandInSession: RuntimeSession {
  let nativeHandle: String
  let events: AsyncStream<RuntimeEvent>
  private let emit: AsyncStream<RuntimeEvent>.Continuation
  private let store: StandInRuntime.NativeStore
  private let gate: StandInRuntime.Gate?
  private let turn = Mutex<Task<Void, Never>?>(nil)
  private let tools: ToolAccess?

  init(handle: String, store: StandInRuntime.NativeStore, gate: StandInRuntime.Gate?, tools: ToolAccess?) {
    self.tools = tools
    nativeHandle = handle
    (events, emit) = AsyncStream<RuntimeEvent>.makeStream()
    self.store = store
    self.gate = gate
  }

  var configuration: SessionConfiguration {
    SessionConfiguration(model: "stand-in", models: [SessionOption(id: "stand-in", name: "Stand-in")])
  }

  func configure(_ choices: SessionChoices) async throws -> SessionConfiguration { configuration }

  func send(_ input: Turn) async throws {
    let text = input.text
    let number = store.nextTurn(nativeHandle)
    let emit = emit
    let gate = gate
    if text.hasPrefix("woven ") {
      let tools = tools
      turn.withLock { $0 = Task {
        let parts = text.dropFirst(6).split(separator: " ", maxSplits: 1)
        let name = String(parts.first ?? "")
        let arguments = parts.count > 1 ? String(parts[1]) : "{}"
        let result = await Self.callTool(name, arguments: arguments, tools: tools)
        emit.yield(.tool(callID: "woven-\(number)", call: ToolCall(name: name, input: arguments, output: result.text,
                                                                  failed: result.failed), finished: true))
        emit.yield(.turnFinished(failure: nil, usage: nil))
      } }
      return
    }
    let task = Task {
      emit.yield(.text("Turn \(number): "))
      await gate?.wait()
      if Task.isCancelled { return }
      emit.yield(.text(text))
      emit.yield(.messageFinished)
      emit.yield(.tool(callID: "echo-\(number)", call: ToolCall(name: "echo", input: "{\"text\":\"\(text)\"}"), finished: false))
      emit.yield(.tool(callID: "echo-\(number)", call: ToolCall(name: "echo", input: "{\"text\":\"\(text)\"}", output: text),
                       finished: true))
      emit.yield(.turnFinished(failure: nil, usage: TokenUsage(model: "stand-in", input: 10, output: 5)))
    }
    turn.withLock { $0 = task }
  }

  func answer(promptID: String, with answer: PromptAnswer) async throws {
    emit.yield(.promptResolved(id: promptID))
  }

  /// One MCP `tools/call` over the tool socket: the key, then the request.
  private static func callTool(_ name: String, arguments: String, tools: ToolAccess?) async -> (text: String, failed: Bool) {
    guard let tools, let socketPath = tools.arguments.last, let key = tools.environment["WOVEN_MCP_KEY"] else {
      return ("No Woven tools.", true)
    }
    return await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        continuation.resume(returning: mcpCall(socketPath: socketPath, key: key, name: name, arguments: arguments))
      }
    }
  }

  private static func mcpCall(socketPath: String, key: String, name: String, arguments: String) -> (text: String, failed: Bool) {
    #if canImport(Darwin)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in bytes.prefix(buffer.count - 1).enumerated() { buffer[index] = byte }
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return ("The tool socket is not there.", true) }
    let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
    let lines = Array((#"{"key":"\#(key)"}"# + "\n" + request + "\n").utf8)
    _ = lines.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var received = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while !received.contains(10) {
      let count = read(fd, &chunk, chunk.count)
      if count <= 0 { break }
      received.append(contentsOf: chunk[0..<count])
    }
    guard let reply = try? JSONDecoder().decode(JSONValue.self, from: received.prefix { $0 != 10 }),
          let result = reply["result"] else { return ("No answer.", true) }
    let text = (result["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
    return (text, result["isError"]?.bool ?? false)
  }

  func interrupt() async throws {
    turn.withLock { $0?.cancel() }
    emit.yield(.turnFinished(failure: nil, usage: nil))
  }

  func stop() async {
    turn.withLock { $0?.cancel() }
    emit.yield(.exited)
    emit.finish()
  }
}
