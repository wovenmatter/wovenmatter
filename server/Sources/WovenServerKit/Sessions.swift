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
  /// The thinking levels each model offered, since a model's levels are its own.
  private let levels: Mutex<[RuntimeKind: [String: [SessionOption]]]>
  /// Kept on disk, so Settings can offer a runtime's options after a restart.
  private let file: URL?
  private let levelsFile: URL?

  init(file: URL? = nil) {
    self.file = file
    levelsFile = file?.deletingLastPathComponent().appendingPathComponent("runtime-thinking-levels.json")
    known = Mutex(Self.read(file, as: SessionConfiguration.self))
    levels = Mutex(Self.read(levelsFile, as: [String: [SessionOption]].self))
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
    if let all { Self.write(all, to: file) }
    guard let model = configuration.model else { return }
    let allLevels = levels.withLock { levels -> [RuntimeKind: [String: [SessionOption]]]? in
      guard levels[kind]?[model] != configuration.thinkingLevels else { return nil }
      levels[kind, default: [:]][model] = configuration.thinkingLevels
      return levels
    }
    if let allLevels { Self.write(allLevels, to: levelsFile) }
  }

  func configuration(_ kind: RuntimeKind) -> SessionConfiguration? { known.withLock { $0[kind] } }

  /// The thinking levels `model` last offered, if it has been seen.
  func thinkingLevels(_ kind: RuntimeKind, model: String) -> [SessionOption]? {
    levels.withLock { $0[kind]?[model] }
  }

  private static func read<Value: Decodable>(_ file: URL?, as: Value.Type) -> [RuntimeKind: Value] {
    let saved = file.flatMap { try? Data(contentsOf: $0) }
      .flatMap { try? JSONDecoder().decode([String: Value].self, from: $0) } ?? [:]
    return Dictionary(saved.map { (RuntimeKind(rawValue: $0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
  }

  private static func write<Value: Encodable>(_ all: [RuntimeKind: Value], to file: URL?) {
    guard let file else { return }
    let saved = Dictionary(all.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { first, _ in first })
    try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
  }
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
  /// Told when a turn of a runtime that keeps its own history ends.
  nonisolated let historyTurns = HistoryTurnHook()

  init(library: Library, runtimes: [any Runtime], scratch: URL, toolKeys: ToolKeys? = nil) {
    self.toolKeys = toolKeys
    self.library = library
    self.runtimes = Dictionary(runtimes.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
    self.scratch = scratch
    configurations = RuntimeConfigurations(file: scratch.appendingPathComponent("runtime-options.json"))
  }

  func supports(_ kind: RuntimeKind) -> Bool { runtimes[kind] != nil }
  /// That this machine lacks a runtime, and the ones it has, by the names tools take.
  func missing(_ name: String) -> String {
    "This machine has no \(name) runtime. It has \(runtimes.keys.map(\.rawValue).sorted().joined(separator: ", "))."
  }
  var allRuntimes: [any Runtime] { Array(runtimes.values) }
  func runtime(_ kind: RuntimeKind) -> (any Runtime)? { runtimes[kind] }

  /// Says in each chat whose turn was cut short by the last stop that it was,
  /// then watches the library for sessions deleted elsewhere.
  func start() async {
    for sessionID in (try? await library.sessionsStoppedMidTurn()) ?? [] {
      try? await library.setTurnRunning(sessionID, false)
      // A turn's end clears its flag in the same write, so a flag still set
      // is a turn that never ended.
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
  /// directory or a scratch directory of its own, and replies once it and
  /// its default choices are saved. Its runtime starts meanwhile, so it is
  /// ready when the person sends; until then the chat shows the saved
  /// choices and the options the runtime last reported on this machine.
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
    // Started without waiting for it: the session's lane is free while its
    // runtime opens, and whatever needs the runtime meanwhile waits for this
    // same opening. A runtime that cannot start yet still leaves a session
    // to send to later.
    if let host = try? await host(for: id) { Task { _ = try? await host.configure(SessionChoices()) } }
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
                           firstMessages: firstMessages, historyTurns: historyTurns)
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
  /// The runtime while it opens, which everyone who needs it meanwhile
  /// waits for, so it opens once (`openLive`).
  private var opening: Opening?
  private var openings = 0
  /// Its manager has let it go (`stop`, `end`), so its runtime never starts
  /// again: nothing would stop it.
  private var closed = false
  private var generation = 0
  private var run: RunState
  private var inProgress: [LiveItem] = []
  private var assistantItemID: String?
  private var toolItemIDs: [String: String] = [:]
  private var prompts: [Prompt] = []
  /// What the runtime last reported.
  private var configuration = SessionConfiguration()
  /// Choices the runtime takes only as it starts, made during a turn: it
  /// starts again with them when the turn ends.
  private var pending = SessionChoices()
  /// The session's saved choices, which show while its runtime is not running.
  private var saved = SessionChoices()
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
  /// Who stopped the running turn, when another session or a bot did.
  private var stoppedBy: String?
  /// The turn running continues a goal, and whether it has said or done anything.
  private var goalTurn = false
  private var turnActed = false
  /// Stop was asked while the running turn ran, so it ends as stopped.
  private var stopAsked = false
  private var idleGoalTurns = 0
  /// The turn running is one the runtime started by itself; a goal neither
  /// counts it nor continues after it.
  private var runtimeTurn = false
  /// Output of a tool call in progress past `ToolOutput.limit`: its start,
  /// its latest end and how much fell between, by item.
  private var overflow: [String: (head: String, tail: String, omitted: Int)] = [:]
  /// Calls seen starting, which numbers each call's `ToolCallStart.order`.
  /// It need not outlive this host: two calls share a start's `after` only
  /// when nothing was saved between them, and a call saved after it
  /// started raises `after` for every later one, while one this host never
  /// saved is gone with it. So calls compared by `order` are always this
  /// host's.
  private var callsStarted = 0
  /// The sequence of the session's last saved item, read when the runtime
  /// opens and kept by each save, so a call's start needs no read.
  private var lastSequence: Int?
  private let firstMessages: FirstMessageHook?
  private let historyTurns: HistoryTurnHook?

  init(sessionID: String, library: Library, runtime: any Runtime, gone: Bool, board: RunBoard,
       configurations: RuntimeConfigurations, tools: ToolAccess? = nil, firstMessages: FirstMessageHook? = nil,
       historyTurns: HistoryTurnHook? = nil) {
    self.firstMessages = firstMessages
    self.historyTurns = historyTurns
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
    saved = SessionChoices(model: session.model, thinking: session.thinking, permission: session.permission)
    return (SessionSnapshot(session: session, items: items, inProgress: inProgress, run: run, prompts: prompts,
                            configuration: shown), events)
  }

  /// The configuration every view shows: the runtime's, with the person's
  /// pending choices over it. While the runtime is not running, the saved
  /// choices and the options it last reported on this machine stand in, so
  /// the choices can be changed before it starts. While it opens for the
  /// first time on this machine there are none yet, and views are told so.
  private var shown: SessionConfiguration {
    var shown = configuration
    if live == nil {
      shown.model = shown.model ?? saved.model
      shown.thinking = shown.thinking ?? saved.thinking
      shown.permission = shown.permission ?? saved.permission
      if let known = configurations.configuration(runtime.kind) {
        if shown.models.isEmpty { shown.models = known.models }
        if shown.thinkingLevels.isEmpty {
          shown.thinkingLevels = shown.model.flatMap { configurations.thinkingLevels(runtime.kind, model: $0) } ?? known.thinkingLevels
        }
        if shown.permissionModes.isEmpty { shown.permissionModes = known.permissionModes }
        if shown.commands.isEmpty { shown.commands = known.commands }
      } else if opening != nil {
        shown.awaitingOptions = true
      }
    }
    shown.model = pending.model ?? shown.model
    shown.thinking = pending.thinking ?? shown.thinking
    shown.permission = pending.permission ?? shown.permission
    return shown
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
    // Whether the message goes now.
    func goes() throws -> Bool {
      // A stop that came after the goal's next turn was queued holds.
      if continuesGoal && interrupted { return false }
      guard run != .nativeSessionGone else { throw Self.goneError }
      guard run == .idle || steers else { throw ProtocolError(.busy, "A turn is already running.") }
      return true
    }
    guard try goes() else { return }
    // A runtime that is not running can take seconds to open. The lane is
    // free meanwhile (`openLive`), so what was decided is decided again: a
    // turn the runtime started by itself as it opened is steered, say.
    if live == nil, run == .idle {
      _ = try await openLive(lettingGo: true)
      guard try goes() else { return }
      // A goal cleared meanwhile has nothing more to send.
      if continuesGoal, (try await library.session(sessionID)?.goal ?? "").isEmpty { return }
    }
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
    stopAsked = false
    let empty = (try? await library.hasItems(sessionID)) == false
    let first = author == nil && empty
    let live = try await openLive()
    try await finish(.userMessage(text: text, attachments: attachments), id: UUID().uuidString.lowercased(), author: author)
    try? await library.setTurnRunning(sessionID, true)
    setRun(.running)
    do {
      try await live.send(turn)
    } catch {
      await endTurn()
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
  /// turn, nor while a question waits or after the person dismissed one; the
  /// person's next message resumes it.
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

  /// Changes the session's choices, starting or resuming its runtime first,
  /// and replies with what is in effect, or with the runtime's refusal.
  /// The lane is free while the runtime opens (`openLive`), and during a
  /// turn while the runtime answers, as for a steer: the turn's output,
  /// Stop and messages go on meanwhile. With no choices it only starts the
  /// runtime, as for a new session.
  func configure(_ choices: SessionChoices) async throws -> SessionConfiguration {
    await enter()
    defer { leave() }
    guard run != .nativeSessionGone else { throw Self.goneError }
    let live = try await openLive(lettingGo: true)
    guard !choices.isEmpty else {
      await saveChoices()
      return shown
    }
    guard run == .running else {
      try await apply(choices, to: live)
      await saveChoices()
      return shown
    }
    let current = generation
    leave()
    var reported: SessionConfiguration?
    var failure: (any Error)?
    do {
      reported = try await live.configure(choices)
    } catch RuntimeError.takenAtStart {
      // Taken below, by starting the runtime again.
    } catch {
      failure = error
    }
    await enter()
    if let failure { throw failure }
    if let reported, generation == current {
      // A pending choice of the same setting is replaced, also by the value in effect.
      pending = SessionChoices(model: choices.model == nil ? pending.model : nil,
                               thinking: choices.thinking == nil ? pending.thinking : nil,
                               permission: choices.permission == nil ? pending.permission : nil)
      adopt(reported)
      broadcast(.configuration(shown))
    } else {
      // It starts again with them: once the turn ends, or as it next starts.
      pending = pending.merging(choices)
      broadcast(.configuration(shown))
      if run != .running { await applyPending() }
    }
    await saveChoices()
    return shown
  }

  /// Gives the runtime choices while no turn runs. A choice it takes only as
  /// it starts, such as Grok Build's permission mode, starts it again with
  /// the choice saved.
  private func apply(_ choices: SessionChoices, to live: any RuntimeSession) async throws {
    do {
      adopt(try await live.configure(choices))
    } catch RuntimeError.takenAtStart {
      pending = pending.merging(choices)
      await saveChoices()
      await shutDown()
      _ = try await openLive()
    }
  }

  /// Starts the runtime again with the choices it takes only as it starts,
  /// made during the turn. Every view then shows what is in effect.
  private func applyPending() async {
    guard !pending.isEmpty, let live else { return }
    do {
      try await apply(pending, to: live)
      pending = SessionChoices()
    } catch {
      // Kept and saved: the runtime's next start takes them, or says why it cannot.
    }
    await saveChoices()
    broadcast(.configuration(shown))
  }

  func answer(promptID: String, with answer: PromptAnswer) async throws {
    await enter()
    defer { leave() }
    guard let live, prompts.contains(where: { $0.id == promptID }) else {
      throw ProtocolError(.notFound, "Nothing is waiting for that answer.")
    }
    try await live.answer(promptID: promptID, with: answer)
    // A question or approval the person dismissed pauses a goal, as Stop
    // does: the agent must not go on to ask again by itself.
    if case .declined = answer { interrupted = true }
    resolvePrompt(promptID)
  }

  /// Stops the running turn, as Stop does. `stopper`, another session or a
  /// bot, is named in a notice once the turn has ended. Returns whether a
  /// turn was running.
  @discardableResult
  func interrupt(by stopper: String? = nil) async throws -> Bool {
    await enter()
    defer { leave() }
    let running = run == .running
    interrupted = true
    stops += 1
    clearPrompts()
    if running { stopAsked = true }
    if running, let stopper { stoppedBy = stopper }
    try await live?.interrupt()
    return running
  }

  /// Stops the runtime's process; the next turn resumes the native session.
  /// A reply it cuts short is saved as far as it got, with a notice.
  func stop() async {
    await enter()
    defer { leave() }
    closed = true
    await abandonOpening()
    let wasRunning = run == .running
    await shutDown()
    try? await finishOpenItems()
    if wasRunning {
      try? await finish(.notice(Notice(kind: .interrupted, text: "The session was stopped while this reply was being written.")),
                        id: UUID().uuidString.lowercased())
    }
    await endTurn()
  }

  /// The session was deleted: stop the process and end every subscription.
  func end() async {
    await enter()
    defer { leave() }
    closed = true
    await abandonOpening()
    await shutDown()
    dropOpenItems()
    await endTurn()
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
      var call = VisualReplies.withoutVisualReply(reported)
      if call.kind != .thinking { turnActed = true }
      await saving { try await self.finishAssistant() }
      if let id = toolItemIDs[callID] {
        if let item = inProgress.first(where: { $0.id == id }), case .toolCall(let previous) = item.content {
          call = Self.updated(call, from: previous)
        }
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
          // A call seen starting carries where it started; one that arrives
          // already finished has no start.
          if let lastSequence {
            callsStarted += 1
            call.start = ToolCallStart(after: lastSequence, order: callsStarted)
          }
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
    case .turnFinished(let failure):
      await saving { try await self.finishOpenItems() }
      if let failure {
        await saving { try await self.finish(.notice(Notice(kind: .failure, text: failure)), id: UUID().uuidString.lowercased()) }
      }
      if let stopper = stoppedBy {
        stoppedBy = nil
        await saving { try await self.finish(.notice(Notice(kind: .interrupted, text: "Stopped by \(stopper).")),
                                             id: UUID().uuidString.lowercased()) }
      }
      await endTurn()
      // Before anything starts the next turn.
      await applyPending()
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

  private static let closedError = ProtocolError(.failed, "This session's runtime was stopped. Try again.")

  /// The runtime while it opens: what it resumes, and the open itself.
  private struct Opening {
    let number: Int
    let handle: String?
    let task: Task<any RuntimeSession, any Error>
  }

  /// The live native session, opening or resuming it when needed. When the
  /// runtime has lost it, the chat says so; a fresh one is never started
  /// under a chat that has had a turn.
  ///
  /// Only `runtime.open` runs outside the lane, in an opening shared by
  /// everyone who needs the runtime while it opens, so it opens once. Its
  /// result is taken in under the lane (`settle`), and the runtime's events
  /// are handled only from then on, so nothing is saved or announced
  /// between a subscriber's snapshot and its events.
  /// With `lettingGo` the caller lets go of the lane while it waits, which
  /// can be seconds, so the chat can be opened meanwhile; the caller then
  /// decides again what it decided before. Without it the lane stays held,
  /// for a caller in the middle of something that must follow the open.
  private func openLive(lettingGo: Bool = false) async throws -> any RuntimeSession {
    while true {
      if let live { return live }
      let opening = try await currentOpening()
      let result: Result<any RuntimeSession, any Error>
      if lettingGo {
        leave()
        result = await opening.task.result
        await enter()
      } else {
        result = await opening.task.result
      }
      if let opened = try await settle(opening, result) { return opened }
      // Another caller back first took a failed open and said why; this one
      // opens it again, as a caller after a failed open always has.
    }
  }

  /// The opening under way, or a new one. Under the lane, so two never start
  /// together. Its task touches nothing of the host.
  private func currentOpening() async throws -> Opening {
    if let opening { return opening }
    guard !closed else { throw Self.closedError }
    guard let session = try await library.session(sessionID) else { throw ProtocolError(.notFound, "No session \(sessionID).") }
    let native = try await library.nativeSession(for: sessionID)
    lastSequence = try await library.items(sessionID: sessionID, beforeSequence: .max, limit: 1).last?.sequence ?? 0
    var directory = session.directory
    if directory.isEmpty, let folderID = session.folderID { directory = try await library.folder(folderID)?.path ?? "" }
    guard !directory.isEmpty else { throw ProtocolError(.failed, "This session has no directory to work in.") }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let choices = SessionChoices(model: session.model, thinking: session.thinking, permission: session.permission)
    let start = RuntimeStart(sessionID: sessionID, directory: directory, nativeHandle: native?.handle, choices: choices,
                             tools: tools)
    let runtime = runtime, library = library, sessionID = sessionID
    openings += 1
    let opening = Opening(number: openings, handle: native?.handle, task: Task {
      do {
        return try await runtime.open(start)
      } catch RuntimeError.nativeSessionGone {
        // Nothing was ever said in this chat, so a new native session loses nothing.
        guard try await library.hasItems(sessionID) == false else { throw RuntimeError.nativeSessionGone }
        var fresh = start
        fresh.nativeHandle = nil
        return try await runtime.open(fresh)
      }
    })
    self.opening = opening
    // Views that know no options yet hear that they are coming (`shown`).
    if configurations.configuration(runtime.kind) == nil { broadcast(.configuration(shown)) }
    return opening
  }

  /// Takes in what an opening opened, under the lane. The first caller back
  /// takes it: it becomes the live session, or its failure is said as it
  /// always was. A caller back later finds it taken: it gets the live
  /// session, or nil to open again after a failure. After a stop or
  /// deletion (`abandonOpening`) it is refused.
  private func settle(_ opening: Opening, _ result: Result<any RuntimeSession, any Error>) async throws
    -> (any RuntimeSession)? {
    guard self.opening?.number == opening.number else {
      if let live { return live }
      if closed { throw Self.closedError }
      if run == .nativeSessionGone { throw Self.goneError }
      return nil
    }
    self.opening = nil
    let opened: any RuntimeSession
    switch result {
    case .success(let session):
      opened = session
    case .failure(let error):
      broadcast(.configuration(shown))
      if let error = error as? RuntimeError, case .nativeSessionGone = error {
        try await nativeSessionGone()
        throw Self.goneError
      }
      throw ProtocolError(.failed, "\(runtime.kind.rawValue) could not start: \(error)")
    }
    // A session deleted while its runtime opened is not written to; the
    // deletion ends this host once it reaches it.
    do {
      guard try await library.session(sessionID) != nil else { throw ProtocolError(.notFound, "No session \(sessionID).") }
      if opening.handle != opened.nativeHandle {
        try await library.setNativeSession(sessionID, runtime: runtime.kind, handle: opened.nativeHandle)
      }
    } catch {
      await opened.stop()
      broadcast(.configuration(shown))
      throw error
    }
    generation += 1
    let current = generation
    live = opened
    // It started with the saved choices, pending ones included. Whatever it
    // did not take is what is saved and shown now.
    pending = SessionChoices()
    adopt(await opened.configuration)
    await saveChoices()
    broadcast(.configuration(shown))
    Task { [weak self] in
      for await event in opened.events { await self?.handle(event, generation: current) }
    }
    return opened
  }

  /// A stop or deletion that comes while the runtime opens waits for it,
  /// then stops it, so no runtime process outlives its host and nothing is
  /// written for it; whoever else waits for that opening is refused. The
  /// lane stays held meanwhile, as it was while an open held it.
  private func abandonOpening() async {
    guard let opening else { return }
    self.opening = nil
    if case .success(let opened) = await opening.task.result { await opened.stop() }
    broadcast(.configuration(shown))
  }

  private func shutDown() async {
    guard let live else { return }
    generation += 1
    self.live = nil
    await live.stop()
  }

  /// Output with no turn running is a turn the runtime started by itself.
  /// It runs like any other: it shows as running, Stop interrupts it, its
  /// items are saved as they finish, and it ends with `turnFinished`.
  private func runtimeStarted() async {
    runtimeTurn = true
    goalTurn = false
    turnActed = false
    stopAsked = false
    try? await library.setTurnRunning(sessionID, true)
    setRun(.running)
  }

  /// Whatever ends a turn ends its run state, marker and prompts, even when
  /// a write failed. Its caller saves what the turn left open first.
  private func endTurn() async {
    clearPrompts()
    if run == .running { await leaveRun(to: .idle) }
  }

  /// The one way out of a running turn. When it ended is saved before views
  /// hear it ended, so a view that watched it and one that opens the chat
  /// later time it the same, with "stopped" when Stop was asked while it
  /// ran, and the running flag clears in the same write.
  private func leaveRun(to state: RunState) async {
    if run == .running {
      turnEnded()
      do {
        try await finish(.notice(Notice(kind: .turnEnded, text: stopAsked ? "stopped" : "")), id: UUID().uuidString.lowercased(),
                         endingTurn: true)
      } catch {
        try? await library.setTurnRunning(sessionID, false)
      }
      setRun(state)
    } else if run != state {
      setRun(state)
    }
  }

  /// A running turn ended, however: a harness with its own history is told
  /// to have its usage read soon (`UsageScanner`).
  private func turnEnded() {
    if runtime.kind.usageFromHistory { historyTurns?.tell() }
  }

  /// Tells every open view the session's goal now.
  func goalChanged(_ goal: String?) {
    guard goal != configuration.goal else { return }
    configuration.goal = goal
    broadcast(.configuration(shown))
  }

  private func adopt(_ configuration: SessionConfiguration) {
    var configuration = configuration
    configuration.goal = self.configuration.goal
    // A pending choice the runtime has now taken is no longer pending.
    pending = pending.removing(SessionChoices(model: configuration.model, thinking: configuration.thinking,
                                              permission: configuration.permission))
    guard configuration != self.configuration else { return }
    self.configuration = configuration
    configurations.set(runtime.kind, configuration)
    broadcast(.configuration(shown))
  }

  /// Saves the choices shown, pending ones included, so a restart keeps them.
  private func saveChoices() async {
    let shown = shown
    saved = SessionChoices(model: shown.model ?? saved.model, thinking: shown.thinking ?? saved.thinking,
                           permission: shown.permission ?? saved.permission)
    try? await library.setSessionChoices(sessionID, model: shown.model, thinking: shown.thinking, permission: shown.permission)
  }

  private func nativeSessionGone() async throws {
    clearPrompts()
    try await library.markNativeSessionGone(sessionID)
    await leaveRun(to: .nativeSessionGone)
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
      await endTurn()
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
  /// A call in progress as a runtime's update leaves it: it keeps where it
  /// started, and a thought keeps the last title that says something, so a
  /// later update titled only "Thinking" does not take it back, for every
  /// view and in the saved item.
  static func updated(_ call: ToolCall, from previous: ToolCall) -> ToolCall {
    var call = call
    call.start = previous.start
    func says(_ title: String?) -> Bool {
      guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return false }
      return !["thinking", "thought", "reasoning"].contains(title.lowercased())
    }
    if call.kind == .thinking, previous.kind == .thinking, !says(call.title), says(previous.title) {
      call.title = previous.title
    }
    return call
  }

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
  private func finish(_ content: ItemContent, id: String, author: ItemAuthor? = nil, endingTurn: Bool = false) async throws {
    var content = content
    if case .toolCall(let call) = content { content = .toolCall(ToolOutput.capped(call)) }
    overflow[id] = nil
    do {
      let item = try await library.appendItem(sessionID: sessionID, id: id, content: content, author: author,
                                              endingTurn: endingTurn)
      lastSequence = item.sequence
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
