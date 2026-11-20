import Foundation
import WovenLibrary
import WovenProtocol

/// This machine's one scheduler. Scheduled tasks, timers and wake-ups are
/// rows of `schedules` that belong to this machine; it alone fires them.
///
/// - When an entry next fires is kept in `schedule_state`, worked out from
///   the entry each time the entry changes: its first occurrence after the
///   last one fired, and never more than a minute in the past, so an entry
///   created or edited with a start already gone does not fire for it.
/// - An occurrence is taken for firing in one write that also moves the
///   entry on to its next occurrence, and only then delivered. A server that
///   stops at any point therefore never fires an occurrence twice.
/// - Missed runs: an entry that came due while the server was off fires once,
///   late, when the server is back, and then carries on from its first
///   occurrence after now. Missed occurrences are not each run.
/// - A timer, wake-up or task whose session is in a turn is tried again a
///   little later. A one-time timer or wake-up is deleted once delivered.
actor Scheduler {
  /// How far into the past a new or edited entry's start still counts.
  static let grace: TimeInterval = 60
  /// How soon an occurrence whose session was busy is tried again.
  static let retry: TimeInterval = 10
  /// The longest the scheduler sleeps without looking again.
  static let longestSleep: TimeInterval = 60

  private let library: Library
  private let sessions: SessionManager
  private let now: @Sendable () -> Date
  private var loop: Task<Void, Never>?
  private var watcher: Task<Void, Never>?
  private var sleeper: Task<Void, Never>?
  private var poked = false

  init(library: Library, sessions: SessionManager, now: @escaping @Sendable () -> Date) {
    self.library = library
    self.sessions = sessions
    self.now = now
  }

  func start() {
    let changes = library.changes()
    watcher = Task { [weak self] in
      for await _ in changes { await self?.poke() }
    }
    loop = Task { [weak self] in
      while !Task.isCancelled, let self {
        let delay = await self.pass()
        await self.sleep(delay)
      }
    }
  }

  func stop() async {
    watcher?.cancel()
    loop?.cancel()
    sleeper?.cancel()
    await loop?.value
  }

  /// Looks again now: an entry changed.
  func poke() {
    poked = true
    sleeper?.cancel()
  }

  private func sleep(_ delay: TimeInterval) async {
    if poked {
      poked = false
      return
    }
    let task = Task { _ = try? await Task.sleep(for: .milliseconds(Int(max(delay, 0.05) * 1000))) }
    sleeper = task
    await task.value
    sleeper = nil
    poked = false
  }

  /// Fires what is due and returns how long until the next entry is.
  private func pass() async -> TimeInterval {
    guard let own = try? await library.ownSchedules() else { return Self.longestSleep }
    let now = now()
    var soonest = Self.longestSleep
    for item in own {
      var next = item.entry.state?.nextFireAt
      if item.stateStamp != item.stamp {
        let floor = now.addingTimeInterval(-Self.grace)
        let after = max(item.entry.state?.lastFiredAt ?? floor, item.firedAt ?? floor, floor)
        next = Self.fires(item.entry) ? item.entry.draft.firstOccurrence(after: after) : nil
        guard (try? await library.setNextFire(item.entry.id, at: next, stamp: item.stamp)) != nil else { continue }
      }
      guard let due = next else { continue }
      if due <= now {
        // Look again at once: what it fired may come due again soon.
        if await fire(item.entry, due: due, at: now) { soonest = 0 }
      } else {
        soonest = min(soonest, due.timeIntervalSince(now))
      }
    }
    return poked ? 0 : soonest
  }

  private static func fires(_ entry: ScheduleEntry) -> Bool {
    entry.draft.enabled && entry.kind != .event
  }

  /// Returns whether it took the occurrence.
  private func fire(_ entry: ScheduleEntry, due: Date, at now: Date) async -> Bool {
    let draft = entry.draft
    let next = draft.recurrence == nil ? nil : draft.firstOccurrence(after: now)
    guard (try? await library.takeFire(entry.id, due: due, next: next, at: now)) == true else { return false }
    do {
      let sessionID = try await deliver(entry)
      try? await library.recordRun(entry.id, sessionID: sessionID, error: nil)
      if entry.kind != .task, draft.recurrence == nil { try? await library.deleteSchedule(entry.id) }
    } catch let error as ProtocolError where error.code == .busy {
      try? await library.retryFire(entry.id, at: now.addingTimeInterval(Self.retry))
    } catch let error as ProtocolError where error.code == .notFound && entry.kind != .task {
      // The session it was for is gone.
      try? await library.deleteSchedule(entry.id)
    } catch {
      try? await library.recordRun(entry.id, sessionID: nil, error: ProtocolError(error).message)
    }
    return true
  }

  /// Sends the entry's prompt where it goes and returns that session.
  private func deliver(_ entry: ScheduleEntry) async throws -> String {
    let draft = entry.draft
    switch entry.kind {
    case .timer, .wakeUp:
      guard let sessionID = draft.sessionID else { throw ProtocolError(.notFound, "This entry has no session.") }
      let source: ItemSource = entry.kind == .timer ? .timer : .wakeUp
      try await sessions.host(for: sessionID).send(draft.prompt, attachments: [],
                                                   author: ItemAuthor(botID: nil, name: draft.title, source: source),
                                                   delivered: Self.delivered(entry))
      return sessionID
    case .task:
      let author = ItemAuthor(botID: nil, name: draft.title, source: .scheduledTask)
      if !draft.newSessionEachRun, let sessionID = draft.sessionID, (try await library.session(sessionID)) != nil {
        try await sessions.host(for: sessionID).send(draft.prompt, attachments: [], author: author, delivered: draft.prompt)
        return sessionID
      }
      guard let runtime = draft.runtime else { throw ProtocolError(.badRequest, "This task has no runtime.") }
      let session = try await sessions.create(runtime: runtime, title: draft.title, folderID: draft.folderID,
                                              directory: draft.directory)
      let host = try await sessions.host(for: session.id)
      let choices = SessionChoices(model: draft.model, thinking: draft.thinking, permission: draft.permission)
      if !choices.isEmpty { _ = try? await host.configure(choices) }
      if !draft.newSessionEachRun { try await library.setScheduleSession(entry.id, session.id) }
      try await host.send(draft.prompt, attachments: [], author: author, delivered: draft.prompt)
      return session.id
    case .event:
      throw ProtocolError(.badRequest, "An event does not fire.")
    }
  }

  /// What the runtime is told when a timer or wake-up reaches it.
  static func delivered(_ entry: ScheduleEntry) -> String {
    switch entry.kind {
    case .wakeUp:
      "You asked to be woken now (\(entry.draft.startsAt.formatted(.iso8601))). Your message to yourself:\n\n\(entry.draft.prompt)"
    default:
      "A timer you set has fired. Its instruction:\n\n\(entry.draft.prompt)"
    }
  }
}

// MARK: Entries, for the routes and the Woven tools alike

enum ScheduleBook {
  /// Checks a draft and saves it on this machine, which must run it. `by` is
  /// the session writing it, or nil for the person.
  static func save(_ id: String?, _ draft: ScheduleDraft, by sessionID: String? = nil, library: Library,
                   sessions: SessionManager) async throws -> ScheduleEntry {
    var draft = draft
    let here = library.machineID
    guard draft.machineID == here else {
      throw ProtocolError(.notOwner, "Another machine runs this entry; ask its server.", machineID: draft.machineID)
    }
    if let id, let existing = try await library.schedule(id) {
      guard existing.machineID == here else {
        throw ProtocolError(.notOwner, "Another machine runs this entry; ask its server.", machineID: existing.machineID)
      }
      guard existing.kind == draft.kind else { throw ProtocolError(.badRequest, "An entry keeps its kind.") }
    }
    draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    draft.prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard TimeZone(identifier: draft.timeZone) != nil else { throw ProtocolError(.badRequest, "Unknown time zone \(draft.timeZone).") }
    if let recurrence = draft.recurrence, !(1...10_000).contains(recurrence.interval) {
      throw ProtocolError(.badRequest, "A repeat interval is 1 to 10,000.")
    }
    switch draft.kind {
    case .event:
      guard !draft.title.isEmpty else { throw ProtocolError(.badRequest, "An event needs a title.") }
    case .task:
      guard !draft.title.isEmpty, !draft.prompt.isEmpty else { throw ProtocolError(.badRequest, "A task needs a title and a prompt.") }
      if let sessionID = draft.sessionID, let session = try await library.session(sessionID) {
        guard session.machineID == here else {
          throw ProtocolError(.notOwner, "That session runs on another machine.", machineID: session.machineID)
        }
        draft.runtime = draft.runtime ?? session.runtime
      }
      guard let runtime = draft.runtime, await sessions.supports(runtime) else {
        throw ProtocolError(.badRequest, "This machine has no \(draft.runtime?.rawValue ?? "chosen") runtime.")
      }
      if let folderID = draft.folderID {
        guard let folder = try await library.folder(folderID) else { throw ProtocolError(.notFound, "No folder \(folderID).") }
        guard folder.machineID == here else { throw ProtocolError(.badRequest, "That folder is on another machine.") }
      }
      if let directory = draft.directory, directory.isEmpty || !directory.hasPrefix("/") {
        guard directory.isEmpty else { throw ProtocolError(.badRequest, "A working directory is an absolute path.") }
        draft.directory = nil
      }
    case .timer, .wakeUp:
      guard !draft.prompt.isEmpty else { throw ProtocolError(.badRequest, "Say what the session should be told.") }
      guard let sessionID = draft.sessionID, let session = try await library.session(sessionID) else {
        throw ProtocolError(.notFound, "A timer or wake-up needs the session it is for.")
      }
      guard session.machineID == here else {
        throw ProtocolError(.notOwner, "That session runs on another machine.", machineID: session.machineID)
      }
      if draft.title.isEmpty { draft.title = draft.kind == .timer ? "Timer" : "Wake-up" }
    }
    return try await library.saveSchedule(id: id, draft, by: sessionID)
  }

  /// Deletes an entry this machine runs, or one occurrence of a series.
  static func delete(_ id: String, occurrence: Int?, library: Library) async throws {
    guard let entry = try await library.schedule(id) else { return }
    guard entry.machineID == library.machineID else {
      throw ProtocolError(.notOwner, "Another machine runs this entry; ask its server.", machineID: entry.machineID)
    }
    if let occurrence, entry.draft.recurrence != nil {
      try await library.excludeOccurrence(id, occurrence)
    } else {
      try await library.deleteSchedule(id)
    }
  }
}

func registerSchedules(_ router: inout Router, library: Library, sessions: SessionManager) {
  router.on(ListSchedules.self) { _, _ in
    try await library.schedules()
  }
  router.on(SaveSchedule.self) { request, _ in
    try await ScheduleBook.save(request.id, request.draft, library: library, sessions: sessions)
  }
  router.on(DeleteSchedule.self) { request, _ in
    try await ScheduleBook.delete(request.id, occurrence: request.occurrence, library: library)
    return Done()
  }
}
