import Foundation
import JavaScriptCore
import Security

/// Pi Durable on this device: the bundled SDK in JavaScriptCore, one conversation per session.
/// Each conversation keeps the SDK's own JSONL log in `directory/<conversation id>`, and
/// opening it again continues it. Inference and tools are the host's; credentials never
/// enter JavaScript or the log.
public struct PiDurableRuntime: Sendable {
  /// Takes a pi-ai request (`{model, context, options, scope}` JSON) and emits pi-ai
  /// `AssistantMessageEvent` JSON, ending with `done` or `error`. `MobileInferenceService.stream` is one.
  public typealias Inference = @Sendable (_ request: String, _ emit: @escaping @Sendable (_ event: String) -> Void) async throws -> Void
  /// Runs a host tool. Must honour task cancellation: an interrupt cancels it.
  public typealias ToolExecutor = @Sendable (PiToolRequest) async throws -> PiToolResult

  public let directory: URL
  let inference: Inference
  let tools: ToolExecutor

  public init(directory: URL, inference: @escaping Inference, tools: @escaping ToolExecutor) {
    self.directory = directory
    self.inference = inference
    self.tools = tools
  }

  /// Where a conversation keeps its log.
  public func directory(for conversationID: String) throws -> URL {
    guard !conversationID.isEmpty, conversationID.count <= 128, !conversationID.hasPrefix("."),
          conversationID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
      throw PiDurableError.failed("A conversation ID is letters, digits, - and _.")
    }
    return directory.appendingPathComponent(conversationID, isDirectory: true)
  }

  /// Opens a conversation. Work a relaunch cut short continues at once.
  @MainActor
  public func open(_ start: PiDurableStart) async throws -> PiDurableSession {
    let folder = try directory(for: start.conversationID)
    let exists = FileManager.default.fileExists(atPath: folder.appendingPathComponent(DurableFileSystem.log).path)
    if start.resume && !exists { throw PiDurableError.conversationGone }
    if !start.resume && exists { throw PiDurableError.failed("A conversation with this ID is already on this device.") }
    let session = try PiDurableSession(conversationID: start.conversationID, filesystem: DurableFileSystem(directory: folder),
                                       inference: inference, tools: tools)
    try await session.open(start)
    return session
  }
}

/// One open conversation. All JavaScript runs on the main actor; inference and tools do their
/// own work off it.
@MainActor
public final class PiDurableSession {
  public let conversationID: String
  /// Every event while the conversation is open, in order. Ends when it closes.
  public let events: AsyncStream<PiDurableEvent>

  private let emit: AsyncStream<PiDurableEvent>.Continuation
  private let filesystem: DurableFileSystem
  private let inference: PiDurableRuntime.Inference
  private let tools: PiDurableRuntime.ToolExecutor
  private var context: JSContext?
  private var replies: [String: CheckedContinuation<String, any Error>] = [:]
  private var operations: [String: Task<Void, Never>] = [:]
  private var questions: [String: CheckedContinuation<String?, any Error>] = [:]
  private var timers: [Int: Task<Void, Never>] = [:]
  private var lastException: String?
  private var closed = false

  init(conversationID: String, filesystem: DurableFileSystem, inference: @escaping PiDurableRuntime.Inference,
       tools: @escaping PiDurableRuntime.ToolExecutor) {
    self.conversationID = conversationID
    self.filesystem = filesystem
    self.inference = inference
    self.tools = tools
    (events, emit) = AsyncStream.makeStream(of: PiDurableEvent.self)
  }

  /// Starts a turn with the person's message. Returns once the runtime has taken it; the
  /// turn's `userMessage` comes first on `events`.
  public func send(_ text: String) async throws { _ = try await invoke("send", ["text": text]) }

  /// Hands the running turn a message through the SDK's own mid-turn input. Returns false,
  /// having taken nothing, when no turn is running; true once the turn has it, after its
  /// `userMessage` is on `events`. The turn still ends once.
  public func steer(_ text: String) async throws -> Bool { try await invoke("steer", ["text": text]) == "true" }

  /// Stops the running turn. It ends once, with what was said so far, and no failure.
  public func interrupt() async throws { _ = try await invoke("interrupt") }

  /// Changes the model (a pi-ai descriptor) or thinking level between turns.
  public func configure(modelJSON: String? = nil, thinkingLevel: String? = nil) async throws {
    var change: [String: Any] = [:]
    if let modelJSON { change["modelJSON"] = modelJSON }
    if let thinkingLevel { change["thinkingLevel"] = thinkingLevel }
    _ = try await invoke("configure", change)
  }

  /// Answers an `ask_user` prompt; nil declines it.
  public func answer(promptID: String, text: String?) throws {
    guard let question = questions.removeValue(forKey: promptID) else { throw PiDurableError.failed("Nothing is waiting for that answer.") }
    question.resume(returning: text)
    emit.yield(.promptResolved(id: promptID))
  }

  /// Suspends the conversation. A turn still running ends with a failure; the next open continues its work.
  public func close() async {
    guard !closed else { return }
    if context != nil { _ = try? await invoke("close") }
    tearDown()
  }

  func open(_ start: PiDurableStart) async throws {
    do {
      try filesystem.acquire()
      try makeContext()
      _ = try await invoke("open", ["conversationID": conversationID, "modelJSON": start.modelJSON,
                                     "thinkingLevel": start.thinkingLevel, "instructions": start.instructions,
                                     "tools": try start.tools.map { try $0.descriptor() }])
    } catch {
      tearDown()
      throw error
    }
  }

  // MARK: JavaScript

  private func makeContext() throws {
    guard let context = JSContext() else { throw PiDurableError.failed("JavaScriptCore could not start.") }
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
        let missing = (native.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(native.code))
          || (native.domain == NSPOSIXErrorDomain && native.code == 2)
        return Self.failure(error.localizedDescription, code: missing ? "not_found" : "unknown")
      }
    }
    let async: @convention(block) (String, String, String) -> Void = { [weak self] kind, id, json in
      self?.start(kind: kind, id: id, json: json)
    }
    let cancel: @convention(block) (String) -> Void = { [weak self] id in self?.operations[id]?.cancel() }
    let reply: @convention(block) (String, String) -> Void = { [weak self] id, json in
      guard let continuation = self?.replies.removeValue(forKey: id) else { return }
      do { continuation.resume(returning: try Self.decodeEnvelope(json)) } catch { continuation.resume(throwing: error) }
    }
    let event: @convention(block) (String) -> Void = { [weak self] json in
      guard let self, let event = Self.event(json) else { return }
      self.emit.yield(event)
    }
    let log: @convention(block) (String) -> Void = { message in NSLog("Pi Durable: %@", message) }
    let schedule: @convention(block) (Int, Double) -> Void = { [weak self] id, delay in
      guard let self else { return }
      self.timers[id] = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(min(delay, Double(Int32.max)))) } catch { return }
        guard let self, !self.closed else { return }
        self.timers.removeValue(forKey: id)
        self.context?.objectForKeyedSubscript("__wmTimerFired")?.call(withArguments: [id])
      }
    }
    let cancelTimer: @convention(block) (Int) -> Void = { [weak self] id in self?.timers.removeValue(forKey: id)?.cancel() }
    for (name, block) in [
      "__wmNativeSync": sync as Any, "__wmAsync": async as Any, "__wmCancel": cancel as Any, "__wmReply": reply as Any,
      "__wmEvent": event as Any, "__wmLog": log as Any, "__wmScheduleTimer": schedule as Any, "__wmCancelTimer": cancelTimer as Any,
    ] { context.setObject(block, forKeyedSubscript: name as NSString) }
    guard let url = Bundle.module.url(forResource: "pi-durable", withExtension: "js") else {
      throw PiDurableError.failed("The bundled Pi Durable runtime is missing.")
    }
    context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
    if let lastException { throw PiDurableError.failed(lastException) }
  }

  private func synchronous(_ operation: String, value: Any) throws -> Any {
    switch operation {
    case "monotonicTime": return ProcessInfo.processInfo.systemUptime * 1_000
    case "url":
      guard let value = value as? [String: Any], let input = value["input"] as? String else { throw PiDurableError.failed("Invalid URL request") }
      let base = (value["base"] as? String).flatMap(URL.init(string:))
      guard let url = URL(string: input, relativeTo: base)?.absoluteURL.standardized,
            let scheme = url.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
        throw PiDurableError.failed("Invalid URL")
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
      guard let count = value as? Int, (0...65_536).contains(count) else { throw PiDurableError.failed("Invalid random request") }
      var bytes = [UInt8](repeating: 0, count: count)
      guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw PiDurableError.failed("Secure random generation failed") }
      return bytes
    case "encode": return Array((value as? String ?? "").utf8)
    case "decode":
      guard let value = value as? [String: Any], let bytes = value["bytes"] as? [UInt8] else { throw PiDurableError.failed("Invalid UTF-8 request") }
      if value["fatal"] as? Bool == true {
        guard let decoded = String(data: Data(bytes), encoding: .utf8) else { throw PiDurableError.failed("Invalid UTF-8 in durable storage") }
        return decoded
      }
      return String(decoding: bytes, as: UTF8.self)
    case "filesystem":
      guard let value = value as? [String: Any], let operation = value["operation"] as? String, let args = value["args"] as? [Any] else {
        throw PiDurableError.failed("Invalid filesystem request")
      }
      return try filesystem.perform(operation, arguments: args)
    default: throw PiDurableError.failed("Unknown host capability")
    }
  }

  /// Inference, a host tool or a question, for JavaScript to await.
  private func start(kind: String, id: String, json: String) {
    let inference = self.inference, tools = self.tools
    operations[id] = Task { [weak self] in
      let envelope: String
      do {
        let request = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        switch kind {
        case "inference":
          let mailbox = EventMailbox()
          do {
            try await inference(json) { [weak self] event in
              mailbox.append(event)
              Task { @MainActor [weak self] in self?.drain(mailbox, id: id) }
            }
          } catch {
            self?.drain(mailbox, id: id)
            throw error
          }
          // The mailbox keeps emission order; terminal events go before the request settles.
          self?.drain(mailbox, id: id)
          envelope = try Self.success(NSNull())
        case "tool":
          let arguments = try JSONSerialization.data(withJSONObject: request["arguments"] ?? [:], options: [.sortedKeys])
          let result = try await tools(PiToolRequest(callID: request["callID"] as? String ?? id, name: request["name"] as? String ?? "",
                                                     arguments: String(decoding: arguments, as: UTF8.self)))
          envelope = try Self.success(["output": result.output, "isError": result.isError])
        case "question":
          guard let self else { throw CancellationError() }
          let answer = try await self.ask(id: request["id"] as? String ?? id, question: request["question"] as? String ?? "")
          envelope = try Self.success(answer ?? NSNull())
        default: throw PiDurableError.failed("Unknown native operation")
        }
      } catch { envelope = Self.failure(error.localizedDescription) }
      guard let self, !self.closed else { return }
      self.operations.removeValue(forKey: id)
      self.context?.objectForKeyedSubscript("__wmComplete")?.call(withArguments: [id, envelope])
    }
  }

  private func ask(id: String, question: String) async throws -> String? {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        questions[id] = continuation
        emit.yield(.prompt(id: id, question: question))
        if Task.isCancelled { withdraw(id) }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.withdraw(id) }
    }
  }

  private func withdraw(_ id: String) {
    guard let question = questions.removeValue(forKey: id) else { return }
    question.resume(throwing: CancellationError())
    emit.yield(.promptResolved(id: id))
  }

  private func drain(_ mailbox: EventMailbox, id: String) {
    guard !closed else { return }
    for event in mailbox.take() { context?.objectForKeyedSubscript("__wmStreamEvent")?.call(withArguments: [id, event]) }
  }

  private func invoke(_ method: String, _ value: [String: Any] = [:]) async throws -> String {
    guard let context, !closed else { throw PiDurableError.closed }
    let json = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    let id = UUID().uuidString
    return try await withCheckedThrowingContinuation { continuation in
      replies[id] = continuation
      lastException = nil
      context.objectForKeyedSubscript("__wmDispatch")?.call(withArguments: [id, method, json])
      if let lastException, let continuation = replies.removeValue(forKey: id) {
        continuation.resume(throwing: PiDurableError.failed(lastException))
      }
    }
  }

  private func tearDown() {
    closed = true
    for task in operations.values { task.cancel() }
    operations.removeAll()
    for task in timers.values { task.cancel() }
    timers.removeAll()
    for continuation in replies.values { continuation.resume(throwing: PiDurableError.closed) }
    replies.removeAll()
    for (id, question) in questions {
      question.resume(throwing: PiDurableError.closed)
      emit.yield(.promptResolved(id: id))
    }
    questions.removeAll()
    context = nil
    filesystem.release()
    emit.finish()
  }

  // MARK: Shapes

  private static func event(_ json: String) -> PiDurableEvent? {
    guard let value = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
          let type = value["type"] as? String else { return nil }
    func string(_ key: String) -> String { value[key] as? String ?? "" }
    switch type {
    case "userMessage": return .userMessage(text: string("text"))
    case "text": return .text(string("delta"))
    case "messageFinished": return .messageFinished(text: string("text"))
    case "thinking": return .thinking(id: string("id"), delta: string("delta"))
    case "thinkingFinished": return .thinkingFinished(id: string("id"), text: string("text"))
    case "toolStarted": return .toolStarted(callID: string("callID"), name: string("name"), input: string("input"))
    case "toolFinished":
      return .toolFinished(callID: string("callID"), name: string("name"), input: string("input"), output: string("output"),
                           failed: value["failed"] as? Bool ?? false)
    case "turnFinished":
      let usage = (value["usage"] as? [String: Any]).map { usage in
        func count(_ key: String) -> Int64 { Int64((usage[key] as? NSNumber)?.doubleValue ?? 0) }
        return PiTokenUsage(model: usage["model"] as? String, input: count("input"), output: count("output"),
                            cacheRead: count("cacheRead"), cacheWrite: count("cacheWrite"))
      }
      return .turnFinished(failure: value["failure"] as? String, usage: usage)
    default: return nil
    }
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
    guard value?["ok"] as? Bool == true else { throw PiDurableError.failed(value?["error"] as? String ?? "Invalid runtime response") }
    return String(decoding: try JSONSerialization.data(withJSONObject: value?["value"] ?? NSNull(), options: [.fragmentsAllowed]), as: UTF8.self)
  }
}

// Only immutable JSON strings cross the inference executor boundary.
private final class EventMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func append(_ value: String) { lock.withLock { values.append(value) } }
  func take() -> [String] { lock.withLock { defer { values.removeAll() }; return values } }
}
