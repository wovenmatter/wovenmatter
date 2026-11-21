import Foundation
import MobileInference
import PiDurableRuntime
import Synchronization
import WovenLibrary
import WovenProtocol
import WovenServerCore

/// Quick Chat: Pi Durable run in the app through the one adapter interface.
/// Each session is one SDK conversation whose log is in
/// `<data folder>/pi-durable/<session id>/`, its native handle; inference uses
/// the device's own sign-ins. It offers what a machine's Pi Durable offers,
/// from the same synced settings read for this device's id.
final class QuickChatRuntime: Runtime {
  var kind: RuntimeKind { .piDurable }

  let directory: URL
  let library: Library
  let providers: Providers

  init(directory: URL, library: Library, providers: Providers) {
    self.directory = directory
    self.library = library
    self.providers = providers
  }

  func status() async -> RuntimeStatus {
    let connected = await providers.connected()
    let servers = await providers.servers.list()
    let signedIn = !connected.isEmpty || !servers.isEmpty
    return RuntimeStatus(runtime: kind, name: "Quick Chat", installed: true, version: ProviderModelCatalog.piVersion,
                         signedIn: signedIn, detail: signedIn ? nil : signInFirst)
  }

  var settings: [String: JSONValue] {
    get async { await library.piDurableSettings() ?? [:] }
  }

  func open(_ start: RuntimeStart) async throws -> any RuntimeSession {
    let settings = await settings
    let offered = await providers.offered(settings: settings)
    guard !offered.isEmpty else { throw RuntimeError.failed(signInFirst) }
    let model = offered.first { $0.reference == start.choices.model }
      ?? offered.first { $0.reference == settings["defaultModel"]?.string } ?? offered[0]
    let platform = (try? await library.machine(library.machineID))?.platform ?? .iPhone
    let session = QuickChatSession(
      conversationID: start.nativeHandle ?? start.sessionID, runtime: self, tools: start.sessionTools,
      instructions: QuickChatTools.instructions(device: platform, woven: nil),
      model: model, thinking: Self.thinking(start.choices.thinking, for: model), offered: offered)
    do {
      try await session.open(resume: start.nativeHandle != nil)
    } catch PiDurableError.conversationGone {
      throw RuntimeError.nativeSessionGone
    }
    return session
  }

  /// The models offered now, for a change of model.
  func offered() async -> [InferenceModel] {
    await providers.offered(settings: await settings)
  }

  /// The level asked for when the model has it, else medium, else its first.
  static func thinking(_ asked: String?, for model: InferenceModel) -> String {
    let levels = model.supportedThinkingLevels
    if let asked, levels.contains(asked) { return asked }
    return levels.contains("medium") ? "medium" : levels.first ?? "off"
  }

  /// The composer's options, in the shape a machine's Pi Durable reports:
  /// the offered models with the current one, its thinking levels when it has
  /// more than one, and Full access as the only permission.
  static func configuration(model: InferenceModel, thinking: String, offered: [InferenceModel]) -> SessionConfiguration {
    var models = offered.map { SessionOption(id: $0.reference, name: $0.name, detail: Providers.name(of: $0.provider)) }
    if !offered.contains(where: { $0.reference == model.reference }) {
      models.insert(SessionOption(id: model.reference, name: model.name), at: 0)
    }
    let levels = model.supportedThinkingLevels
    return SessionConfiguration(
      model: model.reference, thinking: levels.count > 1 ? thinking : nil, permission: fullAccess, models: models,
      thinkingLevels: levels.count > 1 ? levels.map { SessionOption(id: $0, name: $0.prefix(1).uppercased() + $0.dropFirst()) } : [],
      permissionModes: [SessionOption(id: fullAccess, name: "Full access")])
  }

  static let fullAccess = "full"
}

/// One open Quick Chat conversation. The SDK takes its tools when a
/// conversation opens, so when the Woven tools the session may use change
/// between turns, the conversation is opened again on its own log before
/// the next turn: nothing it holds is lost.
final class QuickChatSession: RuntimeSession {
  let nativeHandle: String
  let events: AsyncStream<RuntimeEvent>
  private let emit: AsyncStream<RuntimeEvent>.Continuation
  private let runtime: QuickChatRuntime
  private let woven: SessionTools?
  private let instructions: String

  private struct State {
    var model: InferenceModel
    var thinking: String
    var offered: [InferenceModel]
    var tools: [PiToolDefinition] = []
    var open: PiDurableSession?
    /// Which open conversation's events are this session's.
    var generation = 0
  }

  private let state: Mutex<State>

  init(conversationID: String, runtime: QuickChatRuntime, tools: SessionTools?, instructions: String,
       model: InferenceModel, thinking: String, offered: [InferenceModel]) {
    nativeHandle = conversationID
    self.runtime = runtime
    woven = tools
    self.instructions = instructions
    state = Mutex(State(model: model, thinking: thinking, offered: offered))
    (events, emit) = AsyncStream<RuntimeEvent>.makeStream()
  }

  var configuration: SessionConfiguration {
    get async {
      let (model, thinking, offered) = state.withLock { ($0.model, $0.thinking, $0.offered) }
      return QuickChatRuntime.configuration(model: model, thinking: thinking, offered: offered)
    }
  }

  // MARK: Opening

  /// Quick Chat's own tools and the Woven tools the session may use now.
  /// Session management stays out: from a device it reaches only the
  /// device's own chats, which is not what Quick Chat is for.
  private func currentTools() async -> [PiToolDefinition] {
    let offered = await woven?.definitions() ?? []
    return QuickChatTools.definitions + offered.filter { !QuickChatTools.leftOut.contains($0.name) }.map {
      PiToolDefinition(name: $0.name, description: $0.description,
                       parameters: String(decoding: (try? JSONEncoder().encode($0.input)) ?? Data("{}".utf8), as: UTF8.self),
                       replaySafe: $0.readOnly)
    }
  }

  /// Opens the conversation, or opens it again on its log with the tools
  /// the session may use now. Only between turns.
  func open(resume: Bool) async throws {
    let tools = await currentTools()
    let (previous, model, thinking) = state.withLock { state in
      state.generation += 1
      defer { state.open = nil }
      return (state.open, state.model, state.thinking)
    }
    await previous?.close()
    let providers = runtime.providers
    let woven = woven
    let runtime = runtime
    let pi = PiDurableRuntime(
      directory: runtime.directory,
      inference: { [weak self] request, emit in
        guard let self else { throw PiDurableError.closed }
        let model = state.withLock { state in Self.model(in: request, from: state.offered + [state.model]) ?? state.model }
        try await providers.stream(model, request: request, emit: emit)
      },
      tools: { request in
        try await Self.run(request, woven: woven, providers: providers,
                           searchProvider: await runtime.settings["searchProvider"]?.string)
      })
    let session = try await pi.open(PiDurableStart(conversationID: nativeHandle, resume: resume,
                                                   modelJSON: try model.descriptorJSON(), thinkingLevel: thinking,
                                                   instructions: instructions, tools: tools))
    let generation = state.withLock { state in
      state.open = session
      state.tools = tools
      return state.generation
    }
    let source = await session.events
    let emit = emit
    Task { [weak self] in
      var mapping = EventMapping()
      for await event in source {
        guard self?.isCurrent(generation) == true else { continue }
        for mapped in mapping.map(event) { emit.yield(mapped) }
      }
      // A conversation opened again in its place goes on; one that ended does not.
      guard self?.isCurrent(generation) != false else { return }
      emit.yield(.exited)
      emit.finish()
    }
  }

  private func isCurrent(_ generation: Int) -> Bool { state.withLock { $0.generation == generation } }

  private var current: PiDurableSession {
    get throws {
      guard let open = state.withLock({ $0.open }) else { throw RuntimeError.failed("This Quick Chat is not open.") }
      return open
    }
  }

  // MARK: Turns

  func send(_ turn: Turn) async throws {
    if await currentTools() != state.withLock({ $0.tools }) { try await open(resume: true) }
    try await current.send(Self.text(of: turn))
  }

  func steer(_ turn: Turn) async throws -> Bool {
    try await current.steer(Self.text(of: turn))
  }

  func configure(_ choices: SessionChoices) async throws -> SessionConfiguration {
    if let permission = choices.permission, permission != QuickChatRuntime.fullAccess {
      throw RuntimeError.failed("Quick Chat runs with Full access only.")
    }
    var (model, thinking, offered) = state.withLock { ($0.model, $0.thinking, $0.offered) }
    if let asked = choices.model, asked != model.reference {
      offered = await runtime.offered()
      guard let chosen = offered.first(where: { $0.reference == asked }) else {
        throw RuntimeError.failed("That model is not available on this device.")
      }
      model = chosen
      thinking = QuickChatRuntime.thinking(choices.thinking ?? thinking, for: chosen)
      try await current.configure(modelJSON: try chosen.descriptorJSON(), thinkingLevel: thinking)
    } else if let asked = choices.thinking, asked != thinking {
      guard model.supportedThinkingLevels.contains(asked) else {
        throw RuntimeError.failed("That thinking level is not available for this model.")
      }
      thinking = asked
      try await current.configure(thinkingLevel: asked)
    }
    state.withLock { state in
      state.model = model
      state.thinking = thinking
      state.offered = offered
    }
    return await configuration
  }

  func answer(promptID: String, with answer: PromptAnswer) async throws {
    let text: String? = switch answer {
    case .text(let text), .option(let text): text
    case .values(let values): String(decoding: (try? JSONEncoder().encode(values)) ?? Data(), as: UTF8.self)
    case .declined: nil
    }
    try await current.answer(promptID: promptID, text: text)
  }

  func interrupt() async throws {
    try await current.interrupt()
  }

  func stop() async {
    await (try? current)?.close()
  }

  // MARK: Helpers

  /// Runs a tool call: Quick Chat's own on the device, any other through
  /// the core, as this session.
  private static func run(_ request: PiToolRequest, woven: SessionTools?, providers: Providers,
                          searchProvider: String?) async throws -> PiToolResult {
    if let result = try await QuickChatTools.run(request, credentials: providers.credentials, searchProvider: searchProvider,
                                                 transport: providers.transport) {
      return result
    }
    guard let woven else { return PiToolResult(output: "Quick Chat has no tool \(request.name).", isError: true) }
    let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(request.arguments.utf8))) ?? .object([:])
    let result = await woven.call(request.name, arguments: arguments)
    let text = result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    return PiToolResult(output: text, isError: result.isError)
  }

  /// The model a pi-ai request names, among `models`.
  private static func model(in request: String, from models: [InferenceModel]) -> InferenceModel? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any],
          let named = object["model"] as? [String: Any] else { return nil }
    return models.first { $0.id == named["id"] as? String && $0.provider == named["provider"] as? String }
  }

  /// What the model is sent for a turn: its text, with each attached text
  /// file's contents. Quick Chat has no files to point it at.
  static func text(of turn: Turn) -> String {
    var parts = [turn.text]
    for attachment in turn.attachments {
      if attachment.mimeType.hasPrefix("text/") || attachment.mimeType == "application/json", attachment.size <= 256 << 10,
         let data = try? Data(contentsOf: attachment.file) {
        parts.append("<file name=\"\(attachment.name)\">\n\(String(decoding: data, as: UTF8.self))\n</file>")
      } else {
        parts.append("Attached file: \(attachment.name) (\(attachment.mimeType), \(attachment.size) bytes), which Quick Chat cannot open.")
      }
    }
    return parts.joined(separator: "\n\n")
  }
}

/// Pi Durable's events as the session host takes them, the way a machine's
/// Pi Durable surfaces them: reasoning is a tool call of kind thinking with
/// its text streamed as output, and the person's own messages are not
/// reported, since the host saves them itself.
struct EventMapping {
  private var thinking: Set<String> = []

  mutating func map(_ event: PiDurableEvent) -> [RuntimeEvent] {
    switch event {
    case .userMessage:
      return []
    case .text(let delta):
      return [.text(delta)]
    case .messageFinished:
      return [.messageFinished]
    case .thinking(let id, let delta):
      guard thinking.insert(id).inserted else { return [.toolOutput(callID: id, delta: delta)] }
      return [.messageFinished, .tool(callID: id, call: Self.thought(""), finished: false),
              .toolOutput(callID: id, delta: delta)]
    case .thinkingFinished(let id, let text):
      thinking.remove(id)
      return [.tool(callID: id, call: Self.thought(text), finished: true)]
    case .toolStarted(let callID, let name, let input):
      return [.tool(callID: callID, call: ToolCall(name: name, input: input, kind: QuickChatTools.kind(name)), finished: false)]
    case .toolFinished(let callID, let name, let input, let output, let failed):
      return [.tool(callID: callID, call: ToolCall(name: name, input: input, output: output, failed: failed,
                                                   kind: QuickChatTools.kind(name)), finished: true)]
    case .prompt(let id, let question):
      return [.prompt(Prompt(id: id, kind: .question, text: question))]
    case .promptResolved(let id):
      return [.promptResolved(id: id)]
    case .turnFinished(let failure, let usage):
      return [.turnFinished(failure: failure, usage: usage.map {
        TokenUsage(model: $0.model, input: $0.input, output: $0.output, cacheRead: $0.cacheRead, cacheWrite: $0.cacheWrite)
      })]
    }
  }

  private static func thought(_ text: String) -> ToolCall {
    ToolCall(name: "thinking", input: "", output: text, title: "Thinking", kind: .thinking)
  }
}
