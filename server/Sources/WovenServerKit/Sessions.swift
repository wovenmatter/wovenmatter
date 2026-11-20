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

  /// Every session that is not idle now.
  var current: [SessionRunState] { state.withLock { Array($0.states.values) } }

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
  private let known: Mutex<[RuntimeKind: SessionConfiguration]>
  /// Kept on disk, so Settings can offer a runtime's options after a restart.
  private let file: URL?

  init(file: URL? = nil) {
    self.file = file
    let saved = file.flatMap { try? Data(contentsOf: $0) }
      .flatMap { try? JSONDecoder().decode([String: SessionConfiguration].self, from: $0) } ?? [:]
    known = Mutex(Dictionary(saved.map { (RuntimeKind(rawValue: $0.key), $0.value) }, uniquingKeysWith: { first, _ in first }))
  }

  func set(_ kind: RuntimeKind, _ configuration: SessionConfiguration) {
    guard !configuration.models.isEmpty || !configuration.permissionModes.isEmpty else { return }
    var configuration = configuration
    configuration.goal = nil
    let all = known.withLock { known -> [RuntimeKind: SessionConfiguration]? in
      guard known[kind] != configuration else { return nil }
      known[kind] = configuration
      return known
    }
    guard let all, let file else { return }
    let saved = Dictionary(all.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { first, _ in first })
    try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
  }

  func configuration(_ kind: RuntimeKind) -> SessionConfiguration? { known.withLock { $0[kind] } }
}

/// The sessions this machine owns, each with its host while it is in use.
actor SessionManager {
  private let library: Library
  private let runtimes: [RuntimeKind: any Runtime]
  private let scratch: URL
  private let toolKeys: ToolKeys?
  private var hosts: [String: SessionHost] = [:]
  private var watcher: Task<Void, Never>?
  nonisolated let board = RunBoard()
  nonisolated let configurations: RuntimeConfigurations
  /// Told of the person's first message in each session, for its title.
  nonisolated let firstMessages = FirstMessageHook()

  init(library: Library, runtimes: [any Runtime], scratch: URL, toolKeys: ToolKeys? = nil) {
    self.toolKeys = toolKeys
    self.library = library
    self.runtimes = Dictionary(runtimes.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
    self.scratch = scratch
    configurations = RuntimeConfigurations(file: scratch.appendingPathComponent("runtime-options.json"))
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

  /// Creates a session on this machine, in `directory`, its folder's
  /// directory or a scratch directory of its own, and opens its runtime so
  /// the composer has the runtime's options.
  func create(runtime kind: RuntimeKind, title: String, folderID: String?, directory chosen: String? = nil) async throws -> Session {
    guard runtimes[kind] != nil else { throw ProtocolError(.badRequest, "This machine has no \(kind.rawValue) runtime.") }
    let id = UUID().uuidString.lowercased()
    let directory: String
    if let folderID, let folder = try await library.folder(folderID), folder.machineID != library.machineID {
      throw ProtocolError(.notOwner, "That folder is on another machine.", machineID: folder.machineID)
    }
    if let chosen, !chosen.isEmpty {
      directory = chosen
    } else if let folderID {
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
                           configurations: configurations,
                           tools: toolKeys?.access(runtime.sharesToolBridge ? .runtime(runtime.kind) : .session(sessionID)),
                           firstMessages: firstMessages)
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
  /// The most finished items a snapshot carries; older ones are paged in.
  static let snapshotItems = 200
  /// Goal turns in a row that do nothing before the goal stops continuing.
  static let idleGoalTurnLimit = 3

  private let sessionID: String
  private let library: Library
  private let runtime: any Runtime
  private let board: RunBoard
  private let configurations: RuntimeConfigurations
  private let tools: ToolAccess?
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
  /// The lane sends take, before the session's own one.
  private var sending = false
  private var sendsWaiting: [CheckedContinuation<Void, Never>] = []
  /// The last turn was interrupted, so a goal does not continue it. Only the
  /// person's own message clears it.
  private var interrupted = false
  /// Stops so far, so a steer can tell one came while the runtime answered.
  private var stops = 0
  /// The turn running continues a goal, and whether it has said or done anything.
  private var goalTurn = false
  private var turnActed = false
  private var idleGoalTurns = 0
  /// The turn running is one the runtime started by itself; a goal neither
  /// counts it nor continues after it.
  private var runtimeTurn = false
  /// Output of a tool call in progress past `ToolOutput.limit`: its start,
  /// its latest end and how much fell between, by item.
  private var overflow: [String: (head: String, tail: String, omitted: Int)] = [:]
  private let firstMessages: FirstMessageHook?

  init(sessionID: String, library: Library, runtime: any Runtime, gone: Bool, board: RunBoard,
       configurations: RuntimeConfigurations, tools: ToolAccess? = nil, firstMessages: FirstMessageHook? = nil) {
    self.firstMessages = firstMessages
    self.tools = tools
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
    let items = try await library.items(sessionID: sessionID, beforeSequence: .max, limit: Self.snapshotItems)
    let (events, continuation) = AsyncThrowingStream<SessionEvent, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(Self.subscriberBuffer))
    let id = UUID()
    subscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
    configuration.goal = session.goal
    var shown = configuration
    if live == nil {
      shown.model = shown.model ?? session.model
      shown.thinking = shown.thinking ?? session.thinking
      shown.permission = shown.permission ?? session.permission
    }
    return (SessionSnapshot(session: session, items: items, inProgress: inProgress, run: run, prompts: prompts,
                            configuration: shown), events)
  }

  /// `author` marks a message another session or a bot sent through the
  /// Woven MCP; the runtime is told who it is from. `delivered`, when set,
  /// is what the runtime is sent in place of `text`, which is what is saved.
  /// A message sent while a turn runs steers that turn; with `steers` false
  /// it is refused as busy instead.
  func send(_ text: String, attachments: [Attachment], author: ItemAuthor? = nil, delivered override: String? = nil,
            steers: Bool = true) async throws {
    // Sends go one at a time, through their saves, while a steer frees the
    // lane for the runtime's reply.
    await enterSending()
    defer { leaveSending() }
    await enter()
    defer { leave() }
    let continuesGoal = author?.source == .goal
    // A stop that came after the goal's next turn was queued holds.
    if continuesGoal && interrupted { return }
    guard run != .nativeSessionGone else { throw Self.goneError }
    guard run == .idle || steers else { throw ProtocolError(.busy, "A turn is already running.") }
    var files: [TurnAttachment] = []
    for attachment in attachments {
      guard let file = try await library.contentFile(attachment.digest) else {
        throw ProtocolError(.notFound, "\(attachment.name) is not on this machine. Put its content here first.")
      }
      files.append(TurnAttachment(name: attachment.name, mimeType: attachment.mimeType, size: attachment.size, file: file))
    }
    let delivered = override ?? author.map { author in
      let from = if let sessionID = author.sessionID {
        "the agent session “\(author.name)” (\(sessionID))"
      } else if let botID = author.botID {
        "the bot \(author.name) (\(botID), whom `message_bot` reaches)"
      } else {
        "an agent outside Woven Matter"
      }
      return "This message is from \(from), not the person.\n\n" + text
    } ?? text
    let turn = Turn(text: delivered, attachments: files)
    if run == .running {
      if try await steer(turn, saving: text, attachments: attachments, author: author) { return }
      // The runtime's turn ended as the message came. Once that end is
      // through, the message starts the next turn.
      for _ in 0..<200 where run == .running {
        leave()
        try? await Task.sleep(for: .milliseconds(25))
        await enter()
      }
      if run == .nativeSessionGone { throw Self.goneError }
      guard run == .idle else { throw ProtocolError(.failed, "The runtime did not finish its turn.") }
    }
    if author == nil {
      interrupted = false
      idleGoalTurns = 0
    }
    goalTurn = continuesGoal
    runtimeTurn = false
    turnActed = false
    let empty = (try? await library.hasItems(sessionID)) == false
    let first = author == nil && empty
    let live = try await openLive()
    try await finish(.userMessage(text: text, attachments: attachments), id: UUID().uuidString.lowercased(), author: author)
    try? await library.setTurnRunning(sessionID, true)
    setRun(.running)
    do {
      try await live.send(turn)
    } catch {
      try? await library.setTurnRunning(sessionID, false)
      setRun(.idle)
      throw ProtocolError(.failed, "The runtime did not take the turn: \(error)")
    }
    if first { firstMessages?.tell(sessionID, text) }
  }

  /// Hands the running turn a message, then saves it where it came: after
  /// the reply so far, which is finished as its own item, and before what
  /// the turn says next. Nothing is saved unless the runtime took it.
  /// Returns false when the runtime's turn had already ended.
  /// The lane is free while the runtime answers: the turn may meanwhile
  /// need it for a Woven tool (`publish`, `goalMet`), Stop needs it, and its
  /// output so far comes through and is saved first.
  private func steer(_ turn: Turn, saving text: String, attachments: [Attachment], author: ItemAuthor?) async throws -> Bool {
    guard let live else { return false }
    let stopsBefore = stops
    leave()
    let reply: Result<Bool, any Error>
    do {
      reply = .success(try await live.steer(turn))
    } catch {
      reply = .failure(error)
    }
    await enter()
    switch reply {
    case .success(true): break
    case .success(false): return false
    case .failure(let error): throw ProtocolError(.failed, "The runtime did not take the message: \(error)")
    }
    // A stop that came while the runtime answered holds.
    if author == nil && stops == stopsBefore {
      // The person's message makes the turn theirs, and a paused goal resumes.
      interrupted = false
      idleGoalTurns = 0
      goalTurn = false
    }
    await saving { try await self.finishAssistant() }
    try await finish(.userMessage(text: text, attachments: attachments), id: UUID().uuidString.lowercased(), author: author)
    return true
  }

  /// The agent said the goal is met: it is cleared, and the chat says so.
  func goalMet(_ evidence: String) async throws {
    await enter()
    defer { leave() }
    guard let goal = try await library.session(sessionID)?.goal else { throw ProtocolError(.notFound, "This session has no goal.") }
    _ = try await library.updateSession(sessionID, goal: .some(nil))
    goalChanged(nil)
    let account = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
    try await finish(.notice(Notice(kind: .goalMet, text: "Goal met: \(goal)" + (account.isEmpty ? "" : "\n\n" + account))),
                     id: UUID().uuidString.lowercased())
  }

  /// Saves a visual reply the agent published (`render_html`) where it came:
  /// after the text so far, which is finished as its own item, and before what
  /// the turn says next. Its content is already in the content store.
  func publish(_ reply: VisualReply) async throws {
    await enter()
    defer { leave() }
    turnActed = true
    await saving { try await self.finishAssistant() }
    try await finish(.visualReply(reply), id: UUID().uuidString.lowercased())
  }

  /// When a turn ends and the session still has a goal, the next turn asks
  /// the runtime to continue toward it. Not after an interruption or a failed
  /// turn, nor while a question waits; the person's next message resumes it.
  /// It never steers: a turn the person started meanwhile continues the goal
  /// when it ends.
  private func continueGoal() async {
    guard run == .idle, prompts.isEmpty, !interrupted,
          let goal = try? await library.session(sessionID)?.goal, !goal.isEmpty else { return }
    Task { [weak self] in
      try? await self?.send(Goals.continuedText, attachments: [], author: Goals.author, delivered: Goals.continuation(goal),
                            steers: false)
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
    interrupted = true
    stops += 1
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
    case .text, .tool, .toolOutput, .prompt:
      if run == .idle { await runtimeStarted() }
    default: break
    }
    switch event {
    case .text(let delta):
      turnActed = true
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
    case .tool(let callID, let reported, let finished):
      let call = VisualReplies.withoutVisualReply(reported)
      if call.kind != .thinking { turnActed = true }
      await saving { try await self.finishAssistant() }
      if let id = toolItemIDs[callID] {
        let whole = withOutput(call, of: id)
        if finished {
          toolItemIDs[callID] = nil
          await saving { try await self.finish(.toolCall(whole), id: id) }
        } else if let index = inProgress.firstIndex(where: { $0.id == id }) {
          inProgress[index].content = .toolCall(whole)
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
    case .toolOutput(let callID, let delta):
      guard let id = toolItemIDs[callID] else { return }
      appendOutput(delta, to: id)
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
      // A harness with its own history is counted from there (`UsageScanner`).
      if let usage, !runtime.kind.usageFromHistory {
        try? await library.recordUsage(sessionID: sessionID, runtime: runtime.kind, model: usage.model ?? configuration.model ?? "",
                                       input: usage.input, output: usage.output, cacheRead: usage.cacheRead,
                                       cacheWrite: usage.cacheWrite)
      }
      await endTurn()
      if runtimeTurn {
        runtimeTurn = false
        return
      }
      guard failure == nil else { return }
      idleGoalTurns = goalTurn && !turnActed ? idleGoalTurns + 1 : 0
      if idleGoalTurns >= Self.idleGoalTurnLimit {
        idleGoalTurns = 0
        interrupted = true
        await saving { try await self.finish(.notice(Notice(kind: .interrupted, text: Self.idleGoalText)),
                                             id: UUID().uuidString.lowercased()) }
      } else {
        await continueGoal()
      }
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

  private static let idleGoalText =
    "Stopped working toward the goal: the last three turns did nothing. Send a message to resume."

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
                                                   choices: choices, tools: tools))
    } catch RuntimeError.nativeSessionGone {
      // Nothing was ever said in this chat, so a new native session loses nothing.
      if try await library.hasItems(sessionID) == false {
        opened = try await runtime.open(RuntimeStart(sessionID: sessionID, directory: directory, nativeHandle: nil, choices: choices,
                                                     tools: tools))
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

  /// Output with no turn running is a turn the runtime started by itself.
  /// It runs like any other: it shows as running, Stop interrupts it, its
  /// items are saved as they finish, and it ends with `turnFinished`.
  private func runtimeStarted() async {
    runtimeTurn = true
    goalTurn = false
    turnActed = false
    try? await library.setTurnRunning(sessionID, true)
    setRun(.running)
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

  /// Tells every open view the session's goal now.
  func goalChanged(_ goal: String?) {
    guard goal != configuration.goal else { return }
    configuration.goal = goal
    broadcast(.configuration(configuration))
  }

  private func adopt(_ configuration: SessionConfiguration) {
    var configuration = configuration
    configuration.goal = self.configuration.goal
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

  /// Adds streamed output to a tool call in progress and passes it on.
  /// Past the limit only its start and latest end are kept, and nothing more
  /// is passed on until the call finishes.
  private func appendOutput(_ delta: String, to id: String) {
    let keep = ToolOutput.limit / 2
    if var kept = overflow[id] {
      let tail = (kept.tail + delta).unicodeScalars
      if tail.count > keep { kept.omitted += tail.count - keep }
      kept.tail = String(tail.suffix(keep))
      overflow[id] = kept
      return
    }
    guard let index = inProgress.firstIndex(where: { $0.id == id }), case .toolCall(var call) = inProgress[index].content else { return }
    let output = (call.output ?? "") + delta
    let scalars = output.unicodeScalars
    if output.utf8.count > ToolOutput.limit, scalars.count > ToolOutput.limit {
      overflow[id] = (String(scalars.prefix(keep)), String(scalars.suffix(keep)), scalars.count - 2 * keep)
      return
    }
    call.output = output
    inProgress[index].content = .toolCall(call)
    broadcast(.toolOutput(itemID: id, delta: delta))
  }

  /// A tool call's latest state with the output streamed so far, unless the
  /// call brings output of its own.
  private func withOutput(_ call: ToolCall, of id: String) -> ToolCall {
    var call = call
    if call.output?.isEmpty ?? true {
      if let kept = overflow[id] {
        call.output = ToolOutput.joined(head: kept.head, tail: kept.tail, omitted: kept.omitted)
      } else if let item = inProgress.first(where: { $0.id == id }), case .toolCall(let previous) = item.content,
                previous.output?.isEmpty == false {
        call.output = previous.output
      }
    } else {
      overflow[id] = nil
    }
    return call
  }

  /// Writes a finished item to the library, then announces it. A tool
  /// call's input and output are capped first.
  private func finish(_ content: ItemContent, id: String, author: ItemAuthor? = nil) async throws {
    var content = content
    if case .toolCall(let call) = content { content = .toolCall(ToolOutput.capped(call)) }
    overflow[id] = nil
    do {
      let item = try await library.appendItem(sessionID: sessionID, id: id, content: content, author: author)
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
      guard let item = inProgress.first(where: { $0.id == id }), case .toolCall(let open) = item.content else { continue }
      var call = open
      if let kept = overflow[id] { call.output = ToolOutput.joined(head: kept.head, tail: kept.tail, omitted: kept.omitted) }
      if call.output == nil && call.kind != .plan { call.failed = true }
      try await finish(.toolCall(call), id: id)
    }
  }

  private func dropOpenItems() {
    assistantItemID = nil
    toolItemIDs.removeAll()
    overflow.removeAll()
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

  /// Nothing that holds the session's lane waits for this one, so the two never wait on each other.
  private func enterSending() async {
    if !sending {
      sending = true
      return
    }
    await withCheckedContinuation { sendsWaiting.append($0) }
  }

  private func leaveSending() {
    if sendsWaiting.isEmpty { sending = false } else { sendsWaiting.removeFirst().resume() }
  }
}
