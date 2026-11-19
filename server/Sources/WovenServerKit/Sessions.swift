import Foundation
import WovenLibrary
import WovenProtocol

/// The sessions this machine owns, each with its host while it is in use.
actor SessionManager {
  private let library: Library
  private let runtimes: [RuntimeKind: any Runtime]
  private var hosts: [String: SessionHost] = [:]

  init(library: Library, runtimes: [any Runtime]) {
    self.library = library
    self.runtimes = Dictionary(runtimes.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
  }

  func supports(_ kind: RuntimeKind) -> Bool { runtimes[kind] != nil }

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
    let host = SessionHost(sessionID: sessionID, library: library, runtime: runtime, gone: gone)
    hosts[sessionID] = host
    return host
  }

  /// Stops a session's process and forgets its host.
  func close(_ sessionID: String) async {
    await hosts.removeValue(forKey: sessionID)?.stop()
  }

  func closeAll() async {
    let all = hosts.values
    hosts.removeAll()
    for host in all { await host.stop() }
  }
}

/// One session on its owning server: keeps the runtime's process between
/// turns, streams what it reports to subscribers, and writes each finished
/// item once, in the same step that announces it. Every entry point runs one
/// at a time, in order, so a subscriber's snapshot and the events after it
/// never overlap or leave a gap.
actor SessionHost {
  private let sessionID: String
  private let library: Library
  private let runtime: any Runtime
  private var live: (any RuntimeSession)?
  private var generation = 0
  private var run: RunState
  private var inProgress: [LiveItem] = []
  private var assistantItemID: String?
  private var toolItemIDs: [String: String] = [:]
  private var prompts: [Prompt] = []
  private var subscribers: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]
  private var busy = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(sessionID: String, library: Library, runtime: any Runtime, gone: Bool) {
    self.sessionID = sessionID
    self.library = library
    self.runtime = runtime
    run = gone ? .nativeSessionGone : .idle
  }

  // MARK: Entry points

  func subscribe() async throws -> (SessionSnapshot, AsyncStream<SessionEvent>) {
    await enter()
    defer { leave() }
    guard let session = try await library.session(sessionID) else { throw ProtocolError(.notFound, "No session \(sessionID).") }
    let items = try await library.items(sessionID: sessionID)
    let (events, continuation) = AsyncStream<SessionEvent>.makeStream()
    let id = UUID()
    subscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
    return (SessionSnapshot(session: session, items: items, inProgress: inProgress, run: run, prompts: prompts), events)
  }

  func send(_ text: String) async throws {
    await enter()
    defer { leave() }
    switch run {
    case .nativeSessionGone: throw Self.goneError
    case .running: throw ProtocolError(.busy, "A turn is already running.")
    case .idle: break
    }
    let live = try await openLive()
    try await finish(ItemContent.userMessage(text: text), id: UUID().uuidString.lowercased())
    setRun(.running)
    do {
      try await live.send(text)
    } catch {
      setRun(.idle)
      throw error
    }
  }

  func answer(promptID: String, with answer: String) async throws {
    await enter()
    defer { leave() }
    guard let live, prompts.contains(where: { $0.id == promptID }) else {
      throw ProtocolError(.notFound, "Nothing is waiting for that answer.")
    }
    try await live.answer(promptID: promptID, with: answer)
  }

  func interrupt() async throws {
    await enter()
    defer { leave() }
    try await live?.interrupt()
  }

  func stop() async {
    await enter()
    defer { leave() }
    guard let live else { return }
    generation += 1
    self.live = nil
    await live.stop()
    try? await finishOpenItems()
    if run == .running { setRun(.idle) }
  }

  // MARK: Runtime events

  private func handle(_ event: RuntimeEvent, generation: Int) async {
    await enter()
    defer { leave() }
    guard generation == self.generation else { return }
    do {
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
        try await finishAssistant()
      case .toolStarted(let callID, let name, let input):
        try await finishAssistant()
        let item = LiveItem(id: UUID().uuidString.lowercased(), content: .toolCall(ToolCall(name: name, input: input)))
        toolItemIDs[callID] = item.id
        inProgress.append(item)
        broadcast(.itemStarted(item))
      case .toolFinished(let callID, let output, let failed):
        guard let id = toolItemIDs.removeValue(forKey: callID),
              let item = inProgress.first(where: { $0.id == id }), case .toolCall(var call) = item.content else { return }
        call.output = output
        call.failed = failed
        try await finish(.toolCall(call), id: id)
      case .prompt(let prompt):
        prompts.append(prompt)
        broadcast(.awaiting(prompt))
      case .promptResolved(let id):
        prompts.removeAll { $0.id == id }
        broadcast(.answered(promptID: id))
      case .turnFinished(let failure):
        try await finishOpenItems()
        if let failure { try await finish(.notice(Notice(kind: .failure, text: failure)), id: UUID().uuidString.lowercased()) }
        if run == .running { setRun(.idle) }
      case .nativeSessionGone:
        try await finishOpenItems()
        self.generation += 1
        live = nil
        try await nativeSessionGone()
      case .exited:
        try await finishOpenItems()
        self.generation += 1
        live = nil
        if run == .running { setRun(.idle) }
      }
    } catch {
      // The item stays in progress; the runtime's native log still has it.
    }
  }

  // MARK: Helpers

  private static let goneError = ProtocolError(
    .nativeSessionGone, "The runtime no longer has this chat's session. Start a new session to continue.")

  /// The live native session, opening or resuming it when needed. When the
  /// runtime has lost it, the chat says so; a fresh one is never started.
  private func openLive() async throws -> any RuntimeSession {
    if let live { return live }
    let native = try await library.nativeSession(for: sessionID)
    let session = try await library.session(sessionID)
    let directory: String? = if let folderID = session?.folderID { try await library.folder(folderID)?.path } else { nil }
    let opened: any RuntimeSession
    do {
      opened = try await runtime.open(RuntimeStart(sessionID: sessionID, directory: directory, nativeHandle: native?.handle))
    } catch RuntimeError.nativeSessionGone {
      try await nativeSessionGone()
      throw Self.goneError
    }
    if native?.handle != opened.nativeHandle {
      try await library.setNativeSession(sessionID, runtime: runtime.kind, handle: opened.nativeHandle)
    }
    generation += 1
    let current = generation
    live = opened
    Task { [weak self] in
      for await event in opened.events { await self?.handle(event, generation: current) }
    }
    return opened
  }

  private func nativeSessionGone() async throws {
    try await library.markNativeSessionGone(sessionID)
    prompts.removeAll()
    try await finish(.notice(Notice(kind: .nativeSessionGone, text: Self.goneError.message)), id: UUID().uuidString.lowercased())
    setRun(.nativeSessionGone)
  }

  /// Writes a finished item to the library, then announces it.
  private func finish(_ content: ItemContent, id: String) async throws {
    let item = try await library.appendItem(sessionID: sessionID, id: id, content: content)
    inProgress.removeAll { $0.id == id }
    broadcast(.itemFinished(item))
  }

  private func finishAssistant() async throws {
    guard let id = assistantItemID, let item = inProgress.first(where: { $0.id == id }) else { return }
    assistantItemID = nil
    try await finish(item.content, id: id)
  }

  /// Ends whatever a turn left open: its text so far is its message, and a
  /// tool call without a result failed.
  private func finishOpenItems() async throws {
    try await finishAssistant()
    for (_, id) in toolItemIDs {
      guard let item = inProgress.first(where: { $0.id == id }), case .toolCall(var call) = item.content else { continue }
      call.failed = true
      try await finish(.toolCall(call), id: id)
    }
    toolItemIDs.removeAll()
  }

  private func setRun(_ state: RunState) {
    run = state
    broadcast(.runState(state))
  }

  private func broadcast(_ event: SessionEvent) {
    for continuation in subscribers.values { continuation.yield(event) }
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
