import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol

/// A subscriber fell too far behind; its subscription ends so it can subscribe again.
struct SubscriberTooSlow: Error, CustomStringConvertible {
  var description: String { "This subscriber fell too far behind. Subscribe again." }
}

/// What this machine's sessions are doing, for lists: every session that is
/// not idle, and the subscribers that hear each change.
final class RunBoard: Sendable {
  private struct State {
    var states: [String: SessionRunState] = [:]
    var subscribers: [UUID: AsyncStream<SessionRunState>.Continuation] = [:]
  }

  private let state = Mutex(State())

  func set(_ value: SessionRunState) {
    let subscribers = state.withLock { state -> [AsyncStream<SessionRunState>.Continuation] in
      let idle = value.run == .idle && !value.awaiting
      guard state.states[value.sessionID] != value, !(idle && state.states[value.sessionID] == nil) else { return [] }
      state.states[value.sessionID] = idle ? nil : value
      return Array(state.subscribers.values)
    }
    for subscriber in subscribers { subscriber.yield(value) }
  }

  func subscribe() -> ([SessionRunState], AsyncStream<SessionRunState>) {
    let (stream, continuation) = AsyncStream<SessionRunState>.makeStream(bufferingPolicy: .bufferingNewest(4096))
    let id = UUID()
    let current = state.withLock { state in
      state.subscribers[id] = continuation
      return Array(state.states.values)
    }
    continuation.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) } }
    return (current, stream)
  }
}

/// The configuration each runtime last reported on this machine: what a new
/// session with it can choose from before its process has started.
final class RuntimeConfigurations: Sendable {
  private let known = Mutex<[RuntimeKind: SessionConfiguration]>([:])

  func set(_ kind: RuntimeKind, _ configuration: SessionConfiguration) {
    guard !configuration.models.isEmpty || !configuration.permissionModes.isEmpty else { return }
    known.withLock { $0[kind] = configuration }
  }

  func configuration(_ kind: RuntimeKind) -> SessionConfiguration? { known.withLock { $0[kind] } }
}

/// The sessions this machine owns, each with its host while it is in use.
actor SessionManager {
  private let library: Library
  private let runtimes: [RuntimeKind: any Runtime]
  private let scratch: URL
  private var hosts: [String: SessionHost] = [:]
  private var watcher: Task<Void, Never>?
  nonisolated let board = RunBoard()
  nonisolated let configurations = RuntimeConfigurations()

  init(library: Library, runtimes: [any Runtime], scratch: URL) {
    self.library = library
    self.runtimes = Dictionary(runtimes.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
    self.scratch = scratch
  }

  func supports(_ kind: RuntimeKind) -> Bool { runtimes[kind] != nil }
  var allRuntimes: [any Runtime] { Array(runtimes.values) }
  func runtime(_ kind: RuntimeKind) -> (any Runtime)? { runtimes[kind] }

  /// Says in each chat whose turn was cut short by the last stop that it was,
  /// then watches the library for sessions deleted elsewhere.
  func start() async {
    for sessionID in (try? await library.sessionsStoppedMidTurn()) ?? [] {
      try? await library.setTurnRunning(sessionID, false)
      guard (try? await library.session(sessionID)) != nil else { continue }
      _ = try? await library.appendItem(sessionID: sessionID, content: .notice(Notice(
        kind: .interrupted, text: "The server stopped while this reply was being written, so it may be cut short.")))
    }
    let changes = library.changes()
    watcher = Task { [weak self] in
      for await _ in changes { await self?.closeDeleted() }
    }
  }

  /// Creates a session on this machine, in its folder's directory or a
  /// scratch directory of its own, and opens its runtime so the composer
  /// has the runtime's options.
  func create(runtime kind: RuntimeKind, title: String, folderID: String?) async throws -> Session {
    guard runtimes[kind] != nil else { throw ProtocolError(.badRequest, "This machine has no \(kind.rawValue) runtime.") }
    let id = UUID().uuidString.lowercased()
    let directory: String
    if let folderID {
      guard let folder = try await library.folder(folderID) else { throw ProtocolError(.notFound, "No folder \(folderID).") }
      guard folder.machineID == library.machineID else {
        throw ProtocolError(.notOwner, "That folder is on another machine.", machineID: folder.machineID)
      }
      directory = folder.path
    } else {
      let url = scratch.appendingPathComponent(id, isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      directory = url.path
    }
    let session = try await library.createSession(id: id, runtime: kind, title: title, folderID: folderID, directory: directory)
    // The defaults for this runtime on this machine, else for every machine.
    let own = try? await library.setting("agentDefaults.\(kind.rawValue).\(library.machineID)")
    let shared = try? await library.setting("agentDefaults.\(kind.rawValue)")
    if let defaults = (own ?? shared)?.value {
      try? await library.setSessionChoices(id, model: defaults["model"]?.string, thinking: defaults["thinking"]?.string,
                                           permission: defaults["permission"]?.string)
    }
    // A runtime that cannot start yet still leaves a session to send to later.
    _ = try? await host(for: id).configure(SessionChoices())
    return try await library.session(id) ?? session
  }

  /// The host of a session this machine owns. A session another machine
  /// owns is refused with `notOwner`: its live view is on that machine.
  func host(for sessionID: String) async throws -> SessionHost {
    if let host = hosts[sessionID] { return host }
    guard let session = try await library.session(sessionID) else {
      throw ProtocolError(.notFound, "No session \(sessionID).")
    }
    guard session.machineID == library.machineID else {
      throw ProtocolError(.notOwner, "This session runs on another machine.", machineID: session.machineID)
    }
    guard let runtime = runtimes[session.runtime] else {
      throw ProtocolError(.failed, "This machine has no \(session.runtime.rawValue) runtime.")
    }
    let gone = try await library.nativeSession(for: sessionID)?.gone == true
    if let host = hosts[sessionID] { return host }
    let host = SessionHost(sessionID: sessionID, library: library, runtime: runtime, gone: gone, board: board,
                           configurations: configurations)
    hosts[sessionID] = host
    return host
  }

  /// Stops a session's process and forgets its host.
  func close(_ sessionID: String) async {
    await hosts.removeValue(forKey: sessionID)?.stop()
  }

  func closeAll() async {
    watcher?.cancel()
    let all = hosts.values
    hosts.removeAll()
    for host in all { await host.stop() }
  }

  private func closeDeleted() async {
    for sessionID in hosts.keys {
      if (try? await library.session(sessionID)) == nil {
        await hosts.removeValue(forKey: sessionID)?.end()
      }
    }
  }
}

/// One session on its owning server: keeps the runtime's process between
/// turns, streams what it reports to subscribers, and writes each finished
/// item once, in the same step that announces it. Every entry point runs one
/// at a time, in order, so a subscriber's snapshot and the events after it
/// never overlap or leave a gap.
actor SessionHost {
  /// Events a subscriber may fall behind by before its subscription ends.
  static let subscriberBuffer = 4096

  private let sessionID: String
  private let library: Library
  private let runtime: any Runtime
  private let board: RunBoard
  private let configurations: RuntimeConfigurations
  private var live: (any RuntimeSession)?
  private var generation = 0
  private var run: RunState
  private var inProgress: [LiveItem] = []
  private var assistantItemID: String?
  private var toolItemIDs: [String: String] = [:]
  private var prompts: [Prompt] = []
  private var configuration = SessionConfiguration()
  private var subscribers: [UUID: AsyncThrowingStream<SessionEvent, any Error>.Continuation] = [:]
  private var busy = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(sessionID: String, library: Library, runtime: any Runtime, gone: Bool, board: RunBoard,
       configurations: RuntimeConfigurations) {
    self.sessionID = sessionID
    self.library = library
    self.runtime = runtime
    self.board = board
    self.configurations = configurations
    run = gone ? .nativeSessionGone : .idle
  }

  // MARK: Entry points

  func subscribe() async throws -> (SessionSnapshot, AsyncThrowingStream<SessionEvent, any Error>) {
    await enter()
    defer { leave() }
    guard let session = try await library.session(sessionID) else { throw ProtocolError(.notFound, "No session \(sessionID).") }
    let items = try await library.items(sessionID: sessionID)
    let (events, continuation) = AsyncThrowingStream<SessionEvent, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(Self.subscriberBuffer))
    let id = UUID()
    subscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
    var shown = configuration
    if live == nil {
      shown.model = shown.model ?? session.model
      shown.thinking = shown.thinking ?? session.thinking
      shown.permission = shown.permission ?? session.permission
    }
    return (SessionSnapshot(session: session, items: items, inProgress: inProgress, run: run, prompts: prompts,
                            configuration: shown), events)
  }

  func send(_ text: String, attachments: [Attachment]) async throws {
    await enter()
    defer { leave() }
    switch run {
    case .nativeSessionGone: throw Self.goneError
    case .running: throw ProtocolError(.busy, "A turn is already running.")
    case .idle: break
    }
    var files: [TurnAttachment] = []
    for attachment in attachments {
      guard let file = try await library.contentFile(attachment.digest) else {
        throw ProtocolError(.notFound, "\(attachment.name) is not on this machine. Put its content here first.")
      }
      files.append(TurnAttachment(name: attachment.name, mimeType: attachment.mimeType, size: attachment.size, file: file))
    }
    let live = try await openLive()
    try await finish(.userMessage(text: text, attachments: attachments), id: UUID().uuidString.lowercased())
    try? await library.setTurnRunning(sessionID, true)
    setRun(.running)
    do {
      try await live.send(Turn(text: text, attachments: files))
    } catch {
      try? await library.setTurnRunning(sessionID, false)
      setRun(.idle)
      throw ProtocolError(.failed, "The runtime did not take the turn: \(error)")
    }
  }

  func configure(_ choices: SessionChoices) async throws -> SessionConfiguration {
    await enter()
    defer { leave() }
    guard run != .nativeSessionGone else { throw Self.goneError }
    let live = try await openLive()
    if !choices.isEmpty { adopt(try await live.configure(choices)) }
    await saveChoices()
    return configuration
  }

  func answer(promptID: String, with answer: PromptAnswer) async throws {
    await enter()
    defer { leave() }
    guard let live, prompts.contains(where: { $0.id == promptID }) else {
      throw ProtocolError(.notFound, "Nothing is waiting for that answer.")
    }
    try await live.answer(promptID: promptID, with: answer)
    resolvePrompt(promptID)
  }

  func interrupt() async throws {
    await enter()
    defer { leave() }
    clearPrompts()
    try await live?.interrupt()
  }

  /// Stops the runtime's process; the next turn resumes the native session.
  /// A reply it cuts short is saved as far as it got, with a notice.
  func stop() async {
    await enter()
    defer { leave() }
    let wasRunning = run == .running
    await shutDown()
    try? await finishOpenItems()
    if wasRunning {
      try? await finish(.notice(Notice(kind: .interrupted, text: "The session was stopped while this reply was being written.")),
                        id: UUID().uuidString.lowercased())
    }
  }

  /// The session was deleted: stop the process and end every subscription.
  func end() async {
    await enter()
    defer { leave() }
    await shutDown()
    dropOpenItems()
    board.set(SessionRunState(sessionID: sessionID, run: .idle))
    for continuation in subscribers.values { continuation.finish() }
    subscribers.removeAll()
  }

  // MARK: Runtime events

  private func handle(_ event: RuntimeEvent, generation: Int) async {
    await enter()
    defer { leave() }
    guard generation == self.generation else { return }
    switch event {
    case .text(let delta):
      let id: String
      if let current = assistantItemID {
        id = current
      } else {
        id = UUID().uuidString.lowercased()
        assistantItemID = id
        let item = LiveItem(id: id, content: .assistantMessage(text: ""))
        inProgress.append(item)
        broadcast(.itemStarted(item))
      }
      if let index = inProgress.firstIndex(where: { $0.id == id }), case .assistantMessage(let text) = inProgress[index].content {
        inProgress[index].content = .assistantMessage(text: text + delta)
      }
      broadcast(.text(itemID: id, delta: delta))
    case .messageFinished:
      await saving { try await self.finishAssistant() }
    case .tool(let callID, let call, let finished):
      await saving { try await self.finishAssistant() }
      if let id = toolItemIDs[callID] {
        if finished {
          toolItemIDs[callID] = nil
          await saving { try await self.finish(.toolCall(call), id: id) }
        } else if let index = inProgress.firstIndex(where: { $0.id == id }) {
          inProgress[index].content = .toolCall(call)
          broadcast(.toolActivity(itemID: id, call: call))
        }
      } else {
        let id = UUID().uuidString.lowercased()
        if finished {
          await saving { try await self.finish(.toolCall(call), id: id) }
        } else {
          let item = LiveItem(id: id, content: .toolCall(call))
          toolItemIDs[callID] = id
          inProgress.append(item)
          broadcast(.itemStarted(item))
        }
      }
    case .prompt(let prompt):
      prompts.append(prompt)
      broadcast(.awaiting(prompt))
      post()
    case .promptResolved(let id):
      resolvePrompt(id)
    case .configuration(let configuration):
      adopt(configuration)
      await saveChoices()
    case .turnFinished(let failure, let usage):
      await saving { try await self.finishOpenItems() }
      if let failure {
        await saving { try await self.finish(.notice(Notice(kind: .failure, text: failure)), id: UUID().uuidString.lowercased()) }
      }
      if let usage {
        try? await library.recordUsage(sessionID: sessionID, runtime: runtime.kind, model: usage.model ?? configuration.model ?? "",
                                       input: usage.input, output: usage.output, cacheRead: usage.cacheRead,
                                       cacheWrite: usage.cacheWrite, cost: usage.cost ?? 0)
      }
      await endTurn()
    case .nativeSessionGone:
      await saving { try await self.finishOpenItems() }
      let gone = live
      self.generation += 1
      live = nil
      await gone?.stop()
      await saving { try await self.nativeSessionGone() }
      if run != .nativeSessionGone { setRun(.nativeSessionGone) }
    case .exited:
      await saving { try await self.finishOpenItems() }
      self.generation += 1
      live = nil
      await endTurn()
    }
  }

  // MARK: Helpers

  private static let goneError = ProtocolError(
    .nativeSessionGone, "The runtime no longer has this chat's session. Start a new session to continue.")

  /// The live native session, opening or resuming it when needed. When the
  /// runtime has lost it, the chat says so; a fresh one is never started
  /// under a chat that has had a turn.
  private func openLive() async throws -> any RuntimeSession {
    if let live { return live }
    guard let session = try await library.session(sessionID) else { throw ProtocolError(.notFound, "No session \(sessionID).") }
    let native = try await library.nativeSession(for: sessionID)
    var directory = session.directory
    if directory.isEmpty, let folderID = session.folderID { directory = try await library.folder(folderID)?.path ?? "" }
    guard !directory.isEmpty else { throw ProtocolError(.failed, "This session has no directory to work in.") }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let choices = SessionChoices(model: session.model, thinking: session.thinking, permission: session.permission)
    let opened: any RuntimeSession
    do {
      opened = try await runtime.open(RuntimeStart(sessionID: sessionID, directory: directory, nativeHandle: native?.handle,
                                                   choices: choices))
    } catch RuntimeError.nativeSessionGone {
      // Nothing was ever said in this chat, so a new native session loses nothing.
      if try await library.hasItems(sessionID) == false {
        opened = try await runtime.open(RuntimeStart(sessionID: sessionID, directory: directory, nativeHandle: nil, choices: choices))
      } else {
        try await nativeSessionGone()
        throw Self.goneError
      }
    } catch {
      throw ProtocolError(.failed, "\(runtime.kind.rawValue) could not start: \(error)")
    }
    if native?.handle != opened.nativeHandle {
      try await library.setNativeSession(sessionID, runtime: runtime.kind, handle: opened.nativeHandle)
    }
    generation += 1
    let current = generation
    live = opened
    adopt(await opened.configuration)
    Task { [weak self] in
      for await event in opened.events { await self?.handle(event, generation: current) }
    }
    return opened
  }

  private func shutDown() async {
    guard let live else { return }
    generation += 1
    self.live = nil
    await live.stop()
    await endTurn()
  }

  /// Whatever ends a turn ends its run state, marker and prompts, even when
  /// a write failed.
  private func endTurn() async {
    clearPrompts()
    if run == .running {
      setRun(.idle)
      try? await library.setTurnRunning(sessionID, false)
    }
  }

  private func adopt(_ configuration: SessionConfiguration) {
    guard configuration != self.configuration else { return }
    self.configuration = configuration
    configurations.set(runtime.kind, configuration)
    broadcast(.configuration(configuration))
  }

  private func saveChoices() async {
    try? await library.setSessionChoices(sessionID, model: configuration.model, thinking: configuration.thinking,
                                         permission: configuration.permission)
  }

  private func nativeSessionGone() async throws {
    clearPrompts()
    try? await library.setTurnRunning(sessionID, false)
    try await library.markNativeSessionGone(sessionID)
    setRun(.nativeSessionGone)
    try await finish(.notice(Notice(kind: .nativeSessionGone, text: Self.goneError.message)), id: UUID().uuidString.lowercased())
  }

  /// Runs a write. When it fails the items in progress are dropped (the
  /// runtime's native log still has them) and the process is stopped, so the
  /// session is never left stuck.
  private func saving(_ body: () async throws -> Void) async {
    do {
      try await body()
    } catch {
      dropOpenItems()
      await shutDown()
    }
  }

  /// Writes a finished item to the library, then announces it.
  private func finish(_ content: ItemContent, id: String) async throws {
    do {
      let item = try await library.appendItem(sessionID: sessionID, id: id, content: content)
      inProgress.removeAll { $0.id == id }
      broadcast(.itemFinished(item))
    } catch {
      if inProgress.contains(where: { $0.id == id }) {
        inProgress.removeAll { $0.id == id }
        broadcast(.itemDropped(itemID: id))
      }
      throw error
    }
  }

  private func finishAssistant() async throws {
    guard let id = assistantItemID else { return }
    assistantItemID = nil
    guard let item = inProgress.first(where: { $0.id == id }) else { return }
    try await finish(item.content, id: id)
  }

  /// Ends whatever a turn left open: its text so far is its message, and a
  /// tool call without a result failed.
  private func finishOpenItems() async throws {
    try await finishAssistant()
    let open = toolItemIDs
    toolItemIDs.removeAll()
    for (_, id) in open {
      guard let item = inProgress.first(where: { $0.id == id }), case .toolCall(var call) = item.content else { continue }
      if call.output == nil && call.kind != .plan { call.failed = true }
      try await finish(.toolCall(call), id: id)
    }
  }

  private func dropOpenItems() {
    assistantItemID = nil
    toolItemIDs.removeAll()
    for item in inProgress { broadcast(.itemDropped(itemID: item.id)) }
    inProgress.removeAll()
  }

  private func resolvePrompt(_ id: String) {
    guard prompts.contains(where: { $0.id == id }) else { return }
    prompts.removeAll { $0.id == id }
    broadcast(.answered(promptID: id))
    post()
  }

  private func clearPrompts() {
    for prompt in prompts { broadcast(.answered(promptID: prompt.id)) }
    prompts.removeAll()
    post()
  }

  private func setRun(_ state: RunState) {
    run = state
    broadcast(.runState(state))
    post()
  }

  /// Tells the lists what this session is doing now.
  private func post() {
    board.set(SessionRunState(sessionID: sessionID, run: run, awaiting: !prompts.isEmpty))
  }

  /// Hands an event to every subscriber without waiting. One that has fallen
  /// too far behind is ended with an error instead of growing without bound.
  private func broadcast(_ event: SessionEvent) {
    for (id, continuation) in subscribers {
      if case .dropped = continuation.yield(event) {
        subscribers[id] = nil
        continuation.finish(throwing: SubscriberTooSlow())
      }
    }
  }

  private func unsubscribe(_ id: UUID) {
    subscribers[id] = nil
  }

  private func enter() async {
    if !busy {
      busy = true
      return
    }
    await withCheckedContinuation { waiting.append($0) }
  }

  private func leave() {
    if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
  }
}
