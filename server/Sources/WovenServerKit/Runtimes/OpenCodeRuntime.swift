import Foundation
import Synchronization
import WovenProtocol

/// OpenCode, through its HTTP API on an OpenCode server process this Woven
/// server starts and owns. The process serves every open OpenCode session
/// and ends when the last one stops; it never touches the person's own
/// OpenCode background service. Native sessions stay in OpenCode's storage.
///
/// The permission slot holds OpenCode's primary agents (Build, Plan), and the
/// thinking slot the current model's variants.
public final class OpenCodeRuntime: Runtime {
  public var kind: RuntimeKind { .openCode }
  /// One Woven MCP bridge serves the whole OpenCode process, which names the
  /// native session in each tool call.
  public var sharesToolBridge: Bool { true }

  private let folder: URL
  private let explicitExecutable: URL?
  private let host: OpenCodeHost

  /// `dataFolder` is the server's; OpenCode's process keeps its state and log
  /// in a folder of its own inside it.
  public init(dataFolder: URL, executable: URL? = nil) {
    folder = dataFolder.appending(path: "opencode", directoryHint: .isDirectory)
    explicitExecutable = executable
    host = OpenCodeHost(folder: folder)
  }

  public func open(_ start: RuntimeStart) async throws -> any RuntimeSession {
    guard let executable else { throw RuntimeError.failed("OpenCode is not installed.") }
    let (client, generation) = try await host.acquire(executable: executable, tools: start.tools)
    do {
      let handle: String
      if let resumed = start.nativeHandle {
        do {
          try await client.call("GET", "/api/session/" + OpenCodeClient.segment(resumed))
        } catch let error as OpenCodeHTTPError where error.status == 404 || error.status == 400 {
          throw RuntimeError.nativeSessionGone
        }
        handle = resumed
      } else {
        var body: [String: JSONValue] = ["location": .object(["directory": .string(start.directory)])]
        if let agent = start.choices.permission { body["agent"] = .string(agent) }
        if let model = start.choices.model.flatMap({ OpenCodeSession.modelReference($0, variant: start.choices.thinking) }) {
          body["model"] = model
        }
        handle = try await client.call("POST", "/api/session", body: .object(body))["data"]?["id"]?.string ?? ""
        guard !handle.isEmpty else { throw RuntimeError.failed("OpenCode did not create a session.") }
      }
      // Woven's instructions, as one of the session's own instruction entries.
      if let instructions = start.tools?.instructions {
        _ = try? await client.call("PUT", "/api/experimental/session/" + OpenCodeClient.segment(handle) + "/instructions/entries/woven",
                               body: .object(["value": .string(instructions)]))
      }
      let session = OpenCodeSession(handle: handle, directory: start.directory, client: client, host: host,
                                    generation: generation)
      await host.register(session, generation: generation)
      if start.nativeHandle != nil && !start.choices.isEmpty {
        _ = try await session.configure(start.choices)
      } else {
        try await session.reloadConfiguration()
      }
      return session
    } catch {
      await host.release(nil, generation: generation)
      throw error
    }
  }

  public func status() async -> RuntimeStatus {
    guard let executable else {
      return RuntimeStatus(runtime: kind, name: "OpenCode", installed: false, detail: "OpenCode is not installed.")
    }
    let version = (try? await Self.run(executable, ["--version"]))
      .map { String(decoding: $0.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
      .map { $0.replacingOccurrences(of: "opencode ", with: "") }
      .map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
    // A private server answers, so the person's background service is not started.
    var signedIn: Bool?
    var accounts: [RuntimeAccount] = []
    if let listed = try? await Self.run(executable, ["auth", "list", "--standalone", "--format", "json"], environment: host.environment()),
       listed.status == 0, case .array(let integrations)? = try? OpenCodeSSEParser.decode(listed.output) {
      signedIn = integrations.contains { !($0["connections"]?.array ?? []).isEmpty }
      // Each saved account, removable one at a time by its integration and credential ids.
      for integration in integrations {
        guard let integrationID = integration["id"]?.string else { continue }
        let integrationName = integration["name"]?.string ?? integrationID
        for connection in integration["connections"]?.array ?? [] {
          let label = connection["label"]?.string
          let method = connection["method"]?.string == "oauth" ? "OAuth" : connection["method"]?.string == "key" ? "API key" : "Saved credential"
          accounts.append(RuntimeAccount(method: method,
                                         name: label == nil || label == integrationName ? integrationName : "\(integrationName) · \(label!)",
                                         credential: connection["id"]?.string.map { "\(integrationID) \($0)" }))
        }
      }
    }
    return RuntimeStatus(runtime: kind, name: "OpenCode", installed: true, version: version, signedIn: signedIn, accounts: accounts)
  }

  public func install() async throws {
    let result: (status: Int32, output: Data)
    if let executable {
      result = try await Self.run(executable, ["upgrade"], mergeErrors: true, timeout: .seconds(600))
    } else {
      result = try await Self.run(URL(fileURLWithPath: "/bin/bash"), ["-c", "curl -fsSL https://opencode.ai/v2/install | bash"],
                                  mergeErrors: true, timeout: .seconds(600))
    }
    guard result.status == 0 else {
      let tail = String(decoding: result.output.suffix(2_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw RuntimeError.failed(tail.isEmpty ? "OpenCode's installer failed." : tail)
    }
  }

  /// The explicit path, OpenCode's own install folder, or `opencode` on the PATH.
  private var executable: URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
      .map { URL(fileURLWithPath: String($0)).appending(path: "opencode") }
    let candidates = [explicitExecutable].compactMap { $0 } + [home.appending(path: ".opencode/bin/opencode")] + path
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  /// Runs a command to its end and returns its exit status and output.
  static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:], mergeErrors: Bool = false,
                  timeout: Duration = .seconds(30)) async throws -> (status: Int32, output: Data) {
    let result = await ChildProcess.run(executable.path, arguments, environment: environment, mergeErrors: mergeErrors,
                                        timeout: timeout)
    return (result.status, Data(result.output.utf8))
  }
}

// MARK: The server process

/// The one OpenCode server process this runtime owns, and the routing of its
/// event stream to the sessions open on it.
actor OpenCodeHost {
  private struct Server {
    let process: Process
    let input: Pipe
    let client: OpenCodeClient
    let generation: Int
  }

  private let folder: URL
  private var server: Server?
  /// The Woven MCP, given to the process in its configuration when it starts.
  private var tools: ToolAccess?
  private var starting: Task<Server, any Error>?
  private var generation = 0
  private var users = 0
  private var connected = false
  private var eventTask: Task<Void, Never>?
  private var sessions: [String: OpenCodeSession] = [:]
  /// Child sessions (subagents) by the open session they belong to.
  private var parents: [String: String] = [:]

  init(folder: URL) {
    self.folder = folder
  }

  /// The environment OpenCode runs with: its state (service registration,
  /// locks, recent models) in this runtime's own folder.
  nonisolated func environment(password: String? = nil) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["XDG_STATE_HOME"] = folder.appending(path: "state").path
    if let password { environment["OPENCODE_SERVER_PASSWORD"] = password }
    return environment
  }

  /// The running server, started if there is none; the caller is one more
  /// user until it calls `release`.
  func acquire(executable: URL, tools: ToolAccess? = nil) async throws -> (OpenCodeClient, Int) {
    if let tools { self.tools = tools }
    if let server, starting == nil {
      users += 1
      return (server.client, server.generation)
    }
    let task = starting ?? Task { try await start(executable: executable) }
    starting = task
    defer { starting = nil }
    let started = try await task.value
    users += 1
    return (started.client, started.generation)
  }

  func register(_ session: OpenCodeSession, generation: Int) {
    guard generation == server?.generation else {
      session.processExited()
      return
    }
    sessions[session.nativeHandle] = session
  }

  /// One user is done; the process ends when none is left.
  func release(_ handle: String?, generation: Int) {
    guard generation == server?.generation else { return }
    if let handle {
      sessions[handle] = nil
      parents = parents.filter { $0.value != handle }
    }
    users -= 1
    if users <= 0 { shutDown() }
  }

  private func shutDown() {
    guard let server else { return }
    self.server = nil
    users = 0
    eventTask?.cancel()
    eventTask = nil
    // OpenCode's `serve --stdio` ends when its input closes.
    try? server.input.fileHandleForWriting.close()
    let process = server.process
    Task.detached {
      try? await Task.sleep(for: .seconds(5))
      if process.isRunning { process.terminate() }
    }
  }

  private func start(executable: URL) async throws -> Server {
    try FileManager.default.createDirectory(at: folder.appending(path: "state"), withIntermediateDirectories: true)
    let log = folder.appending(path: "server.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let password = UUID().uuidString + UUID().uuidString
    generation += 1
    let current = generation

    let process = Process()
    process.executableURL = executable
    process.arguments = ["serve", "--stdio", "--hostname", "127.0.0.1", "--port", "0"]
    process.currentDirectoryURL = folder
    var environment = environment(password: password)
    if let tools {
      let config: JSONValue = .object(["mcp": .object(["woven": .object([
        "type": .string("local"), "command": .array(([tools.command] + tools.arguments).map(JSONValue.string)),
        "environment": .object(tools.environment.mapValues(JSONValue.string)),
      ])])])
      environment["OPENCODE_CONFIG_CONTENT"] = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
    }
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    let errors = try FileHandle(forWritingTo: log)
    process.standardError = errors
    process.terminationHandler = { [weak self] _ in
      Task { await self?.exited(generation: current) }
    }
    defer { try? errors.close() }
    try process.run()

    let address: URL
    do {
      let line = try await Self.firstLine(of: output, process: process)
      guard let url = (try? OpenCodeSSEParser.decode(line))?["url"]?.string.flatMap(URL.init(string:)) else {
        throw RuntimeError.failed("OpenCode's server did not say where it listens.")
      }
      address = url
    } catch {
      try? input.fileHandleForWriting.close()
      process.terminate()
      throw error
    }

    let server = Server(process: process, input: input, client: OpenCodeClient(base: address, password: password),
                        generation: current)
    self.server = server
    connected = false
    eventTask = Task { await self.follow(server.client, generation: current) }
    for _ in 0..<200 where !connected { try await Task.sleep(for: .milliseconds(50)) }
    guard connected else {
      shutDown()
      throw RuntimeError.failed("OpenCode's event stream did not connect.")
    }
    return server
  }

  /// Reads the line OpenCode prints when it listens, then keeps draining its output.
  private static func firstLine(of pipe: Pipe, process: Process) async throws -> Data {
    let reader = pipe.fileHandleForReading
    let timeout = Task.detached {
      try await Task.sleep(for: .seconds(30))
      if process.isRunning { process.terminate() }
    }
    defer { timeout.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        var buffer = Data()
        while true {
          let chunk = reader.availableData
          if chunk.isEmpty {
            continuation.resume(throwing: RuntimeError.failed("OpenCode's server stopped while starting."))
            return
          }
          buffer.append(chunk)
          if let end = buffer.firstIndex(of: 10) {
            continuation.resume(returning: buffer[..<end])
            break
          }
        }
        while !reader.availableData.isEmpty {}
      }
    }
  }

  /// Follows OpenCode's event stream for the life of the process,
  /// reconnecting when it drops.
  private func follow(_ client: OpenCodeClient, generation: Int) async {
    while !Task.isCancelled, server?.generation == generation {
      do {
        for try await event in try client.events("/api/event") {
          route(event)
        }
      } catch {}
      try? await Task.sleep(for: .milliseconds(250))
    }
  }

  private func route(_ event: JSONValue) {
    let data = event["data"] ?? .null
    let type = event["type"]?.string ?? ""
    if type == "server.connected" {
      connected = true
      return
    }
    // OpenCode loads a folder's models, agents and commands after the first
    // request for it, and says so once they are there.
    if ["model.updated", "agent.updated", "command.updated"].contains(type) {
      for session in sessions.values { session.reloadSoon() }
      return
    }
    guard let id = data["sessionID"]?.string ?? data["form"]?["sessionID"]?.string else { return }
    if type == "session.created", let parent = data["parentID"]?.string, let owner = sessions[parent] != nil ? parent : parents[parent] {
      parents[id] = owner
    }
    if let session = sessions[id] {
      session.receive(event, from: id)
    } else if let owner = parents[id], let session = sessions[owner] {
      session.receive(event, from: id)
    }
  }

  private func exited(generation: Int) {
    guard generation == server?.generation else { return }
    server = nil
    users = 0
    eventTask?.cancel()
    eventTask = nil
    let ended = sessions.values
    sessions.removeAll()
    parents.removeAll()
    for session in ended { session.processExited() }
  }
}

// MARK: One session

final class OpenCodeSession: RuntimeSession {
  private struct Pending {
    /// The OpenCode session that asked: this one or one of its subagents.
    var sessionID: String
    /// The form, for a question; nil for a permission request.
    var form: JSONValue?
  }

  private struct State {
    var projection = OpenCodeProjection()
    var prompts: [String: Pending] = [:]
    var configuration = SessionConfiguration()
    var variants: [String: [String]] = [:]
    var running = false
    var ended = false
    var reloading = false
  }

  let nativeHandle: String
  let events: AsyncStream<RuntimeEvent>
  private let emit: AsyncStream<RuntimeEvent>.Continuation
  private let directory: String
  private let client: OpenCodeClient
  private let host: OpenCodeHost
  private let generation: Int
  private let state = Mutex(State())

  init(handle: String, directory: String, client: OpenCodeClient, host: OpenCodeHost, generation: Int) {
    nativeHandle = handle
    self.directory = directory
    self.client = client
    self.host = host
    self.generation = generation
    (events, emit) = AsyncStream<RuntimeEvent>.makeStream()
  }

  var configuration: SessionConfiguration {
    get async { state.withLock { $0.configuration } }
  }

  private var path: String { "/api/session/" + OpenCodeClient.segment(nativeHandle) }

  func send(_ turn: Turn) async throws {
    state.withLock { $0.running = true }
    do {
      try await post(turn)
    } catch {
      state.withLock { $0.running = false }
      throw RuntimeError.failed("OpenCode did not take the turn: \(error)")
    }
  }

  /// OpenCode's prompt route delivers a message to a running execution as
  /// a steer.
  func steer(_ turn: Turn) async throws -> Bool {
    guard state.withLock({ $0.running }) else { return false }
    try await post(turn)
    return true
  }

  private func post(_ turn: Turn) async throws {
    let files: [JSONValue] = try turn.attachments.map { attachment in
      if attachment.mimeType.hasPrefix("image/") {
        let data = try Data(contentsOf: attachment.file)
        return .object(["uri": .string("data:\(attachment.mimeType);base64," + data.base64EncodedString()), "name": .string(attachment.name)])
      }
      return .object(["uri": .string(attachment.file.absoluteURL.absoluteString), "name": .string(attachment.name)])
    }
    let commands = state.withLock { $0.configuration.commands.map(\.name) }
    if turn.text.hasPrefix("/"), let name = turn.text.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init),
       commands.contains(name) {
      let rest = turn.text.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
      try await client.call("POST", path + "/command", body: .object(["name": .string(name), "text": .string(rest), "files": .array(files),
                                                                       "delivery": .string("steer")]))
    } else {
      try await client.call("POST", path + "/prompt", body: .object(["text": .string(turn.text), "files": .array(files),
                                                                      "delivery": .string("steer")]))
    }
  }

  func configure(_ choices: SessionChoices) async throws -> SessionConfiguration {
    if let agent = choices.permission {
      try await client.call("POST", path + "/agent", body: .object(["agent": .string(agent)]))
    }
    if choices.model != nil || choices.thinking != nil {
      if state.withLock({ $0.variants.isEmpty }) { try await reloadConfiguration() }
      let (current, variants) = state.withLock { ($0.configuration, $0.variants) }
      if let model = choices.model ?? current.model {
        let offered = variants[model] ?? []
        var variant = choices.thinking ?? (model == current.model ? current.thinking : nil)
        if let chosen = variant, !offered.contains(chosen) { variant = nil }
        if let reference = Self.modelReference(model, variant: variant) {
          try await client.call("POST", path + "/model", body: .object(["model": reference]))
        }
      }
    }
    try await reloadConfiguration()
    return await configuration
  }

  func answer(promptID: String, with answer: PromptAnswer) async throws {
    guard let pending = state.withLock({ $0.prompts[promptID] }) else { return }
    let asker = "/api/session/" + OpenCodeClient.segment(pending.sessionID)
    if let form = pending.form {
      if answer == .declined {
        try await client.call("POST", asker + "/form/" + OpenCodeClient.segment(promptID))
      } else {
        try await client.call("POST", asker + "/form/" + OpenCodeClient.segment(promptID) + "/reply",
                              body: try OpenCodeProjection.formReply(form, answer: answer))
      }
    } else {
      try await client.call("POST", asker + "/permission/" + OpenCodeClient.segment(promptID) + "/reply",
                            body: OpenCodeProjection.permissionReply(answer))
    }
    resolve(promptID)
  }

  func interrupt() async throws {
    try await client.call("POST", path + "/interrupt")
  }

  func stop() async {
    // The process may serve other sessions, so a running turn is stopped first.
    if state.withLock({ $0.running }) { try? await interrupt() }
    guard end() else { return }
    await host.release(nativeHandle, generation: generation)
    emit.yield(.exited)
    emit.finish()
  }

  // MARK: From the host

  /// One event of this session, or of one of its subagents (`sessionID`).
  func receive(_ event: JSONValue, from sessionID: String) {
    let data = event["data"] ?? .null
    switch event["type"]?.string {
    case "permission.asked":
      ask(OpenCodeProjection.permissionPrompt(data), Pending(sessionID: sessionID))
    case "form.created":
      let form = data["form"] ?? .null
      ask(OpenCodeProjection.formPrompt(form), Pending(sessionID: sessionID, form: form))
    case "permission.replied":
      resolve(data["requestID"]?.string ?? "")
    case "form.replied", "form.cancelled":
      resolve(data["id"]?.string ?? "")
    default:
      guard sessionID == nativeHandle else { return }
      switch event["type"]?.string {
      case "session.deleted":
        emit.yield(.nativeSessionGone)
      case "session.model.selected", "session.agent.selected":
        reloadSoon()
      default:
        let events = state.withLock { state in
          var events = state.projection.receive(event)
          if let end = events.firstIndex(where: { if case .turnFinished = $0 { true } else { false } }) {
            // Whatever the turn still asked is withdrawn with it.
            events.insert(contentsOf: state.prompts.keys.sorted().map { RuntimeEvent.promptResolved(id: $0) }, at: end)
            state.prompts.removeAll()
            state.running = false
          }
          return events
        }
        for event in events { emit.yield(event) }
      }
    }
  }

  /// The process died: close what is open and end the stream.
  func processExited() {
    let events = state.withLock { state -> [RuntimeEvent] in
      guard state.running else { return [] }
      state.running = false
      return state.projection.finishTurn(failure: "OpenCode's server stopped.", interrupted: true)
    }
    guard end() else { return }
    for event in events { emit.yield(event) }
    emit.yield(.exited)
    emit.finish()
  }

  private func end() -> Bool {
    state.withLock { state in
      defer { state.ended = true }
      return !state.ended
    }
  }

  private func ask(_ prompt: Prompt, _ pending: Pending) {
    state.withLock { $0.prompts[prompt.id] = pending }
    emit.yield(.prompt(prompt))
  }

  private func resolve(_ id: String) {
    guard state.withLock({ $0.prompts.removeValue(forKey: id) }) != nil else { return }
    emit.yield(.promptResolved(id: id))
  }

  // MARK: Configuration

  /// Reads the configuration again shortly, once for a burst of changes, and
  /// reports it when it changed.
  func reloadSoon() {
    guard state.withLock({ state in
      defer { state.reloading = true }
      return !state.reloading
    }) else { return }
    Task {
      try? await Task.sleep(for: .milliseconds(200))
      let before = await configuration
      state.withLock { $0.reloading = false }
      try? await reloadConfiguration()
      let after = await configuration
      if after != before, !state.withLock({ $0.ended }) { emit.yield(.configuration(after)) }
    }
  }

  /// Reads the session's model, variant and agent, and what each can be.
  func reloadConfiguration() async throws {
    let location = ["location[directory]": directory]
    async let info = client.call("GET", path)
    async let models = client.call("GET", "/api/model", query: location)
    async let agents = client.call("GET", "/api/agent", query: location)
    async let commands = client.call("GET", "/api/command", query: location)
    let session = (try await info)["data"] ?? .null
    var model = session["model"] ?? .null
    if model == .null { model = try await client.call("GET", "/api/model/default", query: location)["data"] ?? .null }
    let available = ((try await models)["data"]?.array ?? []).filter { $0["enabled"]?.bool != false }
    let primary = ((try await agents)["data"]?.array ?? []).filter {
      $0["mode"]?.string != "subagent" && $0["hidden"]?.bool != true
    }
    let offered = (try await commands)["data"]?.array ?? []

    func reference(_ entry: JSONValue) -> String {
      (entry["providerID"]?.string ?? "") + "/" + (entry["id"]?.string ?? "")
    }
    let current = model["id"]?.string.map { _ in reference(model) }
    var variants: [String: [String]] = [:]
    for entry in available {
      variants[reference(entry)] = (entry["variants"]?.array ?? []).map { $0["id"]?.string ?? "" }
    }
    let agent = session["agent"]?.string ?? primary.first(where: { $0["id"]?.string == "build" })?["id"]?.string
      ?? primary.first?["id"]?.string
    let configuration = SessionConfiguration(
      model: current,
      thinking: session["model"]?["variant"]?.string,
      permission: agent,
      models: available.map { entry in
        SessionOption(id: reference(entry), name: entry["name"]?.string ?? "", detail: entry["providerID"]?.string)
      },
      thinkingLevels: (current.flatMap { variants[$0] } ?? []).map { SessionOption(id: $0, name: $0.capitalized) },
      permissionModes: primary.map {
        SessionOption(id: $0["id"]?.string ?? "", name: $0["name"]?.string ?? "", detail: $0["description"]?.string)
      },
      commands: offered.map { SessionCommand(name: $0["name"]?.string ?? "", detail: $0["description"]?.string) })
    state.withLock {
      $0.configuration = configuration
      $0.variants = variants
    }
  }

  /// OpenCode's model reference for "provider/model".
  static func modelReference(_ model: String, variant: String?) -> JSONValue? {
    guard let slash = model.firstIndex(of: "/") else { return nil }
    var reference: [String: JSONValue] = [
      "providerID": .string(String(model[..<slash])), "id": .string(String(model[model.index(after: slash)...])),
    ]
    if let variant { reference["variant"] = .string(variant) }
    return .object(reference)
  }
}
