import Foundation
import JavaScriptCore
import Security
import CryptoKit

public struct PiDurableConfiguration: Codable, Sendable {
  public var conversationID: String
  public var modelJSON: String
  public var toolsJSON: String
  public var instructions: String

  public init(conversationID: String, modelJSON: String, toolsJSON: String = "[]", instructions: String = "") {
    self.conversationID = conversationID
    self.modelJSON = modelJSON
    self.toolsJSON = toolsJSON
    self.instructions = instructions
  }
}

public enum PiDurableRuntimeError: Error, LocalizedError, Sendable {
  case unavailable(String)
  case javascript(String)
  case closed
  case storageInUse

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message), .javascript(let message): return message
    case .closed: return "This on-device agent has been suspended. Reopen it to continue."
    case .storageInUse: return "This on-device conversation is already open in another runtime."
    }
  }
}

/// Hosts the actual Pi Durable SDK in JavaScriptCore. The SDK owns the agent loop and durable
/// task transitions; the host supplies capabilities and never interprets model tool decisions.
/// All JS access is serialized on MainActor. Inference and tool implementations do their own
/// asynchronous work and must respect Swift task cancellation.
@MainActor
public final class PiDurableRuntime {
  public typealias Inference = @Sendable (String, @escaping @Sendable (String) -> Void) async throws -> Void
  public typealias Tool = @Sendable (String) async throws -> String
  public typealias Events = @MainActor (String) -> Void

  private let configuration: PiDurableConfiguration
  private let filesystem: DurableFileSystem
  private let inference: Inference
  private let tool: Tool
  private let onEvents: Events
  private var context: JSContext?
  private var continuations: [String: CheckedContinuation<String, any Error>] = [:]
  private var operations: [String: Task<Void, Never>] = [:]
  private var timers: [Int: Task<Void, Never>] = [:]
  private var lastException: String?
  private var opened = false
  private var stopped = false

  public init(storageDirectory: URL, configuration: PiDurableConfiguration,
              inference: @escaping Inference, tool: @escaping Tool,
              onEvents: @escaping Events = { _ in }) throws {
    self.configuration = configuration
    self.filesystem = try DurableFileSystem(directory: storageDirectory)
    self.inference = inference
    self.tool = tool
    self.onEvents = onEvents
  }

  /// Opens persisted state without scheduling pending work. Resume is an explicit decision.
  @discardableResult
  public func open() async throws -> String {
    guard !stopped else { throw PiDurableRuntimeError.closed }
    guard !opened else { return try await snapshot() }
    try filesystem.acquire()
    do {
      try makeContext()
      let data = try JSONEncoder().encode(configuration)
      let result = try await invoke("open", json: String(decoding: data, as: UTF8.self))
      opened = true
      return result
    } catch {
      tearDown()
      throw error
    }
  }

  /// Returns the durable acceptance receipt, without waiting for model or tool execution.
  public func submit(text: String, requestID: String) async throws -> String {
    try await invoke("submit", value: ["text": text, "requestID": requestID])
  }
  /// Read-only recovery of a lost acceptance receipt. Never submits or starts execution.
  public func submission(requestID: String) async throws -> String? {
    let receipt = try await invoke("submission", value: ["requestID": requestID])
    return receipt == "null" ? nil : receipt
  }
  /// Complete immutable history, including entries before resets/compaction. `next` in the
  /// returned page can be JSON-encoded and supplied as cursorJSON. Entries are newest first.
  public func history(nativeConversationID: Int? = nil, cursorJSON: String? = nil, limit: Int = 200) async throws -> String {
    var value: [String: Any] = ["limit": limit]
    if let nativeConversationID { value["nativeConversationID"] = nativeConversationID }
    if let cursorJSON { value["cursorJSON"] = cursorJSON }
    return try await invoke("history", value: value)
  }
  public func conversations(cursorJSON: String? = nil, limit: Int = 200) async throws -> String {
    var value: [String: Any] = ["limit": limit]
    if let cursorJSON { value["cursorJSON"] = cursorJSON }
    return try await invoke("conversations", value: value)
  }
  public func wait(submissionID: Int) async throws -> String {
    try await invoke("wait", value: ["submissionID": submissionID])
  }
  public func snapshot() async throws -> String { try await invoke("snapshot") }
  public func resume() async throws { _ = try await invoke("resume") }
  public func abort() async throws { _ = try await invoke("abort") }
  public func compact(instructions: String = "") async throws { _ = try await invoke("compact", value: ["instructions": instructions]) }
  public func configure(modelJSON: String, instructions: String? = nil) async throws {
    var value = ["modelJSON": modelJSON]
    if let instructions { value["instructions"] = instructions }
    _ = try await invoke("configure", value: value)
  }

  /// Suspends execution through the SDK without marking the user's run cancelled.
  /// Native writes already flushed each commit. The next instance can reopen and resume it.
  public func close() async throws {
    guard !stopped else { return }
    defer { tearDown() }
    if context != nil { _ = try await invoke("close") }
  }

  private func makeContext() throws {
    guard let context = JSContext() else { throw PiDurableRuntimeError.unavailable("JavaScriptCore could not start.") }
    self.context = context
    context.exceptionHandler = { [weak self] _, exception in
      self?.lastException = exception?.toString() ?? "Unknown JavaScript exception"
    }
    let sync: @convention(block) (String, String) -> String = { [weak self] operation, json in
      guard let self else { return Self.failure("Runtime closed") }
      do {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        return try Self.success(self.synchronous(operation, value: value))
      } catch {
        let native = error as NSError
        let missing = (native.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(native.code)) || (native.domain == NSPOSIXErrorDomain && native.code == 2)
        return Self.failure(error.localizedDescription, code: missing ? "not_found" : "unknown")
      }
    }
    let async: @convention(block) (String, String, String) -> Void = { [weak self] kind, id, json in
      self?.startOperation(kind: kind, id: id, json: json)
    }
    let cancel: @convention(block) (String) -> Void = { [weak self] id in self?.operations[id]?.cancel() }
    let reply: @convention(block) (String, String) -> Void = { [weak self] id, json in
      guard let continuation = self?.continuations.removeValue(forKey: id) else { return }
      do {
        let result = try Self.decodeEnvelope(json)
        continuation.resume(returning: result)
      } catch { continuation.resume(throwing: error) }
    }
    let events: @convention(block) (String) -> Void = { [weak self] json in self?.onEvents(json) }
    let schedule: @convention(block) (Int, Double) -> Void = { [weak self] id, delay in
      guard let self else { return }
      self.timers[id] = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(min(delay, Double(Int32.max)))) }
        catch { return }
        guard let self, !self.stopped else { return }
        self.timers.removeValue(forKey: id)
        self.context?.objectForKeyedSubscript("__wmTimerFired")?.call(withArguments: [id])
      }
    }
    let cancelTimer: @convention(block) (Int) -> Void = { [weak self] id in
      self?.timers.removeValue(forKey: id)?.cancel()
    }
    for (name, block) in [
      "__wmNativeSync": sync as Any, "__wmAsync": async as Any, "__wmCancel": cancel as Any,
      "__wmReply": reply as Any, "__wmEvents": events as Any,
      "__wmScheduleTimer": schedule as Any, "__wmCancelTimer": cancelTimer as Any,
    ] { context.setObject(block, forKeyedSubscript: name as NSString) }
    guard let url = Bundle.module.url(forResource: "pi-durable", withExtension: "js") else {
      throw PiDurableRuntimeError.unavailable("The bundled Pi Durable runtime is missing.")
    }
    context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
    if let lastException { throw PiDurableRuntimeError.javascript(lastException) }
  }

  private func synchronous(_ operation: String, value: Any) throws -> Any {
    switch operation {
    case "sha256": return SHA256.hash(data: Data((value as? String ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
    case "url":
      guard let value = value as? [String: Any], let input = value["input"] as? String else {
        throw PiDurableRuntimeError.unavailable("Invalid URL request")
      }
      let base = (value["base"] as? String).flatMap(URL.init(string:))
      guard let url = URL(string: input, relativeTo: base)?.absoluteURL.standardized,
            let scheme = url.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
        throw PiDurableRuntimeError.unavailable("Invalid URL")
      }
      let host = url.host ?? ""
      let port = url.port.map { ":\($0)" } ?? ""
      return ["href": url.absoluteString, "protocol": scheme + ":", "hostname": host,
              "host": host + port, "pathname": components.percentEncodedPath,
              "search": components.percentEncodedQuery.map { "?" + $0 } ?? "",
              "hash": components.percentEncodedFragment.map { "#" + $0 } ?? "",
              "origin": host.isEmpty ? "null" : scheme + "://" + host + port]
    case "uuid": return UUID().uuidString.lowercased()
    case "random":
      guard let count = value as? Int, (0...65_536).contains(count) else {
        throw PiDurableRuntimeError.unavailable("Invalid random request")
      }
      var bytes = [UInt8](repeating: 0, count: count)
      guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        throw PiDurableRuntimeError.unavailable("Secure random generation failed")
      }
      return bytes
    case "encode": return Array((value as? String ?? "").utf8)
    case "decode":
      guard let value = value as? [String: Any], let bytes = value["bytes"] as? [UInt8] else {
        throw PiDurableRuntimeError.unavailable("Invalid UTF-8 request")
      }
      if value["fatal"] as? Bool == true {
        guard let decoded = String(data: Data(bytes), encoding: .utf8) else {
          throw PiDurableRuntimeError.unavailable("Invalid UTF-8 in durable storage")
        }
        return decoded
      }
      return String(decoding: bytes, as: UTF8.self)
    case "filesystem":
      guard let value = value as? [String: Any], let operation = value["operation"] as? String,
            let args = value["args"] as? [Any] else {
        throw PiDurableRuntimeError.unavailable("Invalid filesystem request")
      }
      return try filesystem.perform(operation, arguments: args)
    default: throw PiDurableRuntimeError.unavailable("Unknown host capability")
    }
  }

  private func startOperation(kind: String, id: String, json: String) {
    let inference = self.inference, tool = self.tool
    operations[id] = Task { [weak self] in
      let envelope: String
      do {
        switch kind {
        case "inference":
          let mailbox = RuntimeEventMailbox()
          do {
            try await inference(json) { [weak self] event in
              mailbox.append(event)
              Task { @MainActor [weak self] in self?.drain(mailbox, id: id) }
            }
          } catch {
            self?.drain(mailbox, id: id)
            throw error
          }
          // A synchronous mailbox preserves emission order even if MainActor jobs are scheduled
          // out of order. Always drain terminal events before settling the native request.
          self?.drain(mailbox, id: id)
          envelope = try Self.success(NSNull())
        case "codemode":
          guard let self else { throw CancellationError() }
          let executor = PiCodeModeExecutor()
          guard let request = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                let invocationID = request["invocationID"] as? String else {
            throw PiDurableRuntimeError.unavailable("Invalid code invocation")
          }
          let result = try await executor.run(requestJSON: json) { [weak self] name, arguments in
            guard let self else { throw CancellationError() }
            let args = try JSONSerialization.jsonObject(with: Data(arguments.utf8))
            return try await self.invoke("nestedTool", value: ["invocationID":invocationID,"name":name,"arguments":args])
          }
          envelope = try Self.success(JSONSerialization.jsonObject(with: Data(result.utf8)))
        case "tool":
          let result = try await tool(json)
          let value = try JSONSerialization.jsonObject(with: Data(result.utf8), options: [.fragmentsAllowed])
          envelope = try Self.success(value)
        default: throw PiDurableRuntimeError.unavailable("Unknown native operation")
        }
      } catch { envelope = Self.failure(error.localizedDescription) }
      guard let self, !self.stopped else { return }
      self.operations.removeValue(forKey: id)
      self.context?.objectForKeyedSubscript("__wmComplete")?.call(withArguments: [id, envelope])
    }
  }

  private func drain(_ mailbox: RuntimeEventMailbox, id: String) {
    guard !stopped else { return }
    for event in mailbox.take() {
      context?.objectForKeyedSubscript("__wmStreamEvent")?.call(withArguments: [id, event])
    }
  }

  private func invoke(_ method: String, value: [String: Any] = [:]) async throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return try await invoke(method, json: String(decoding: data, as: UTF8.self))
  }
  private func invoke(_ method: String, json: String) async throws -> String {
    guard let context, !stopped else { throw PiDurableRuntimeError.closed }
    let id = UUID().uuidString
    return try await withCheckedThrowingContinuation { continuation in
      continuations[id] = continuation
      lastException = nil
      context.objectForKeyedSubscript("__wmDispatch")?.call(withArguments: [id, method, json])
      if let lastException, let continuation = continuations.removeValue(forKey: id) {
        continuation.resume(throwing: PiDurableRuntimeError.javascript(lastException))
      }
    }
  }
  private func tearDown() {
    stopped = true; opened = false
    for task in operations.values { task.cancel() }
    operations.removeAll()
    for task in timers.values { task.cancel() }
    timers.removeAll()
    for continuation in continuations.values { continuation.resume(throwing: PiDurableRuntimeError.closed) }
    continuations.removeAll()
    context = nil
    filesystem.release()
  }
  private static func success(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "value": value], options: [.fragmentsAllowed]), as: UTF8.self)
  }
  private static func failure(_ message: String, code: String = "unknown") -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["ok": false, "error": message, "errorCode": code])
    return String(decoding: data, as: UTF8.self)
  }
  private static func decodeEnvelope(_ json: String) throws -> String {
    let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    guard value?["ok"] as? Bool == true else {
      throw PiDurableRuntimeError.javascript(value?["error"] as? String ?? "Invalid runtime response")
    }
    return String(decoding: try JSONSerialization.data(withJSONObject: value?["value"] ?? NSNull(), options: [.fragmentsAllowed]), as: UTF8.self)
  }
}

// Only immutable JSON strings cross the inference executor boundary.
private final class RuntimeEventMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
  func take() -> [String] { lock.lock(); defer { lock.unlock() }; let result = values; values.removeAll(); return result }
}
