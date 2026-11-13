import Foundation
import WovenMatterCore
import WovenMatterShared

/// Agent-to-agent waiting on a Mac (docs/architecture/WOVEN_EVERYWHERE.md,
/// "Streaming", "Agent to agent"). The behaviour is `SessionWakeUp`'s, the same
/// as the Linux server's `remote/src/session-watch.mjs`: `woven_sessions_wait`
/// resolves from live changes instead of polling, and a session an agent here
/// created on another workspace (`member_tool_sessions`) wakes that agent when
/// it finishes or asks a question while the agent is idle.
///
/// Changes come from `CentralExecutionClient`'s `workspace` stream of each
/// destination (`remoteItem`, filtered here to the sessions this Mac watches or
/// waits on) and, for this Mac's own sessions, from its in-process changes
/// (`localChanged`). Watched sessions and pending wake-ups are stored
/// (`member_session_watch`, `member_session_wakeups`), so both survive a restart.
@MainActor public final class SessionWakeUps {
  /// What a source says about one session.
  public struct Snapshot: Equatable, Sendable {
    /// `running`, `idle`, `needsInput`, or `missing` (removed there).
    public var state: String
    public var title: String?
    public var runID: String?
    public var pending: [PendingInteraction]
    public init(state: String, title: String? = nil, runID: String? = nil, pending: [PendingInteraction] = []) {
      self.state = state; self.title = title; self.runID = runID; self.pending = pending
    }
    public init(conversation: LibraryConversation, pending: [PendingInteraction]) {
      self.init(state: SessionWakeUps.state(activeRunID: conversation.activeRunID, pending: pending),
                title: conversation.title.isEmpty ? nil : conversation.title, runID: conversation.activeRunID, pending: pending)
    }
    public static let missing = Snapshot(state: "missing")
  }

  public enum Caller: Sendable {
    /// `wokenRunsInARow`: how many of its latest runs, in a row, a wake-up started.
    case conversation(idle: Bool, wokenRunsInARow: Int)
    case bot
    case gone
  }

  /// One wake-up to send. `id` is stable for this caller, session, state and attempt.
  public struct Delivery: Equatable, Sendable {
    public let id: String
    public let callerID: String
    public let sessionID: String
    public let title: String?
    public let harness: String?
    public let text: String
    public let key: String
  }

  public struct Hooks {
    /// The calling conversation's state, a bot, or gone.
    public var caller: @MainActor (String) async -> Caller
    /// Sends into an idle conversation without steering; true when it was accepted.
    public var deliverToConversation: @MainActor (Delivery) async -> Bool
    /// Hands a bot's wake-up to the bots runtime.
    public var deliverToBot: @MainActor (Delivery) async throws -> Void
    /// The current conversations and pending interactions of a workspace,
    /// read once after a restart, before its stream says anything.
    public var reconcile: @MainActor (String) async -> (conversations: [LibraryConversation], pending: [PendingInteraction])?
    public var log: @MainActor (String) -> Void
    public init(caller: @escaping @MainActor (String) async -> Caller,
                deliverToConversation: @escaping @MainActor (Delivery) async -> Bool,
                deliverToBot: @escaping @MainActor (Delivery) async throws -> Void,
                reconcile: @escaping @MainActor (String) async -> (conversations: [LibraryConversation], pending: [PendingInteraction])? = { _ in nil },
                log: @escaping @MainActor (String) -> Void = { _ in }) {
      self.caller = caller; self.deliverToConversation = deliverToConversation; self.deliverToBot = deliverToBot
      self.reconcile = reconcile; self.log = log
    }
  }

  /// Exactly `woven_sessions_status`'s state.
  public nonisolated static func state(activeRunID: String?, pending: [PendingInteraction]) -> String {
    !pending.isEmpty ? "needsInput" : activeRunID != nil ? "running" : "idle"
  }

  /// Whether `state` is what `woven_sessions_wait`'s `until` asks for.
  public nonisolated static func reaches(_ state: String, _ until: String) -> Bool {
    until == "either" ? state == "idle" || state == "needsInput" : state == until
  }

  public nonisolated static func pendingKey(_ ids: [String]) -> String { Set(ids).sorted().joined(separator: ",") }

  public let database: WorkspaceDatabase
  public var hooks: Hooks
  public let maximumWakeUps: Int
  public let retryInterval: Duration
  private var watches: [String: SessionWatchRecord] = [:]
  private var wakeUps: [String: SessionWakeUpRecord] = [:]
  private var projections: [String: SessionStreamProjection] = [:]
  private var waiters: [UUID: Waiter] = [:]
  private var tracked: [String: [String: Int]] = [:]
  private var waiting: [String: Int] = [:]
  private var chains: [String: Task<Void, Never>] = [:]
  private var retryAt: [String: ContinuousClock.Instant] = [:]
  private var botFailures: [String: Int] = [:]
  private var started = false

  @MainActor private final class Waiter {
    let workspaceID: String, id: String, until: String
    var hinted = false
    var continuation: CheckedContinuation<Void, Never>?
    init(workspaceID: String, id: String, until: String) { self.workspaceID = workspaceID; self.id = id; self.until = until }
    func wake() { hinted = true; continuation?.resume(); continuation = nil }
  }

  public init(database: WorkspaceDatabase, hooks: Hooks, maximumWakeUps: Int = StreamProtocol.maximumWakeUpsPerRun,
              retryInterval: Duration = .seconds(30)) {
    self.database = database; self.hooks = hooks; self.maximumWakeUps = maximumWakeUps; self.retryInterval = retryInterval
  }

  /// Loads what was watched or pending before a restart, compares each
  /// watched workspace with its current state, and delivers what is due.
  public func start() async {
    guard !started else { return }
    started = true
    do {
      for record in try await database.sessionWatches() { watches[record.id] = record }
      for record in try await database.sessionWakeUps() { wakeUps[record.id] = record }
    } catch { hooks.log("Watched sessions could not be read: \(error.localizedDescription)") }
    for workspaceID in Set(watches.values.map(\.workspaceID)) {
      guard let current = await hooks.reconcile(workspaceID) else { continue }
      let byID = Dictionary(current.conversations.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
      for record in watches.values where record.workspaceID == workspaceID {
        let pending = current.pending.filter { $0.conversationID.lowercased() == record.id }
        await changed(workspaceID: workspaceID, id: record.id, byID[record.id].map { Snapshot(conversation: $0, pending: pending) } ?? .missing)
      }
    }
    await deliverPending()
  }

  public var watched: [SessionWatchRecord] { watches.values.sorted { $0.id < $1.id } }
  /// Whether a wait is following a session of `workspaceID`.
  public func isTracking(workspaceID: String) -> Bool { !(tracked[workspaceID]?.isEmpty ?? true) }
  public func pending(callerID: String) -> [SessionWakeUpRecord] {
    wakeUps.values.filter { $0.callerID == callerID }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
  }

  // MARK: Changes

  /// The IDs a workspace's stream should keep: watched sessions and waits.
  private func kept(_ workspaceID: String) -> Set<String> {
    Set(watches.values.filter { $0.workspaceID == workspaceID }.map(\.id)).union(tracked[workspaceID].map { Array($0.keys) } ?? [])
  }

  /// One item of a destination's `workspace` stream (conversations, pending, synchronized).
  public func remoteItem(workspaceID: String, _ payload: StreamItem.Payload) async {
    var projection = projections[workspaceID] ?? .init()
    let changes = projection.receive(payload, keep: kept(workspaceID))
    projections[workspaceID] = projection
    for (id, snapshot) in changes { await changed(workspaceID: workspaceID, id: id, snapshot) }
  }

  /// This Mac's own sessions changed: `read` gives each one's current snapshot.
  public func localChanged(workspaceID: String, conversationIDs: Set<String>, read: @MainActor (String) async -> Snapshot?) async {
    let keep = kept(workspaceID)
    let ids = conversationIDs.isEmpty ? keep : keep.intersection(conversationIDs.map { $0.lowercased() })
    for id in ids { await changed(workspaceID: workspaceID, id: id, await read(id) ?? .missing) }
  }

  /// What a source says about session `id` on `workspaceID`.
  public func changed(workspaceID: String, id: String, _ snapshot: Snapshot) async {
    // Waits read again once the wake-up this change makes exists, so their reading drops it.
    defer {
      for waiter in waiters.values where waiter.workspaceID == workspaceID && waiter.id == id
        && (Self.reaches(snapshot.state, waiter.until) || snapshot.state == "missing") { waiter.wake() }
    }
    guard var current = watches[id], current.workspaceID == workspaceID else { return }
    if snapshot.state == "missing" {
      await unwatch(id); await dropWakeUp(id)
      return
    }
    if let title = snapshot.title { current.title = title }
    switch snapshot.state {
    case "running":
      guard current.state != "running" || current.runID != snapshot.runID else { return }
      current.state = "running"; current.runID = snapshot.runID; current.questions = nil
      await save(current)
      // Running again: whatever it said before no longer holds.
      await dropWakeUp(id)
    case "needsInput":
      let questions = Self.pendingKey(snapshot.pending.map(\.id))
      guard current.state != "needsInput" || current.questions != questions else { return }
      current.state = "needsInput"; current.runID = snapshot.runID ?? current.runID; current.questions = questions
      await save(current)
      var question: String?
      if let first = snapshot.pending.first { question = !first.title.isEmpty ? first.title : first.kind == .approval ? "an approval" : nil }
      await addWakeUp(current, kind: .needsInput, key: "needsInput:" + questions, question: question)
    default:
      // Idle: it finished, and nothing more is watched until its caller makes it run again.
      await unwatch(id)
      await addWakeUp(current, kind: .finished, key: "finished:" + (current.runID ?? "unknown"))
    }
  }

  /// What a caller just did to, or read from, a session it created: `running`
  /// after a create, send, steer or respond, `idle` after a stop, or a
  /// status read. Each replaces a pending wake-up for that session, which the
  /// caller has now seen or made stale.
  public func observe(callerID: String, workspaceID: String, workspaceName: String?, id rawID: String, title: String? = nil,
                      harness: String? = nil, state: String, runID: String? = nil, pendingIDs: [String] = [], created: Bool = false) async {
    let id = rawID.lowercased()
    // A session watched or pending for this caller was checked when it was first watched.
    let known = watches[id]?.callerID == callerID || wakeUps[id]?.callerID == callerID
    if !known { guard (try? await database.memberToolSession(id: id))?.callerID == callerID else { return } }
    if created, WovenMCPCaller.parseBot(callerID) != nil { try? await database.setBotWakeUpCount(callerID: callerID, count: nil) }
    await dropWakeUp(id)
    if state == "idle" { await unwatch(id); return }
    let previous = watches[id]
    let record = SessionWatchRecord(id: id, callerID: callerID, workspaceID: workspaceID, workspaceName: workspaceName ?? previous?.workspaceName,
                                    title: title ?? previous?.title, harness: harness ?? previous?.harness, state: state,
                                    runID: runID ?? previous?.runID, questions: state == "needsInput" ? Self.pendingKey(pendingIDs) : nil)
    await save(record)
    // Its stream may already have said more, in items not kept for it (it
    // was not watched yet) or before what the caller saw: that counts too.
    if let snapshot = projections[workspaceID]?.after(id, runID: record.runID, observed: state) {
      await changed(workspaceID: workspaceID, id: id, snapshot)
    }
  }

  private func save(_ record: SessionWatchRecord) async {
    watches[record.id] = record
    do { try await database.saveSessionWatch(record) } catch { hooks.log("A watched session could not be saved: \(error.localizedDescription)") }
  }
  private func unwatch(_ id: String) async {
    guard watches.removeValue(forKey: id) != nil else { return }
    try? await database.removeSessionWatch(id: id)
  }
  private func dropWakeUp(_ id: String, key: String? = nil) async {
    guard let current = wakeUps[id], key == nil || current.key == key else { return }
    wakeUps.removeValue(forKey: id); retryAt.removeValue(forKey: id); botFailures.removeValue(forKey: id)
    try? await database.removeSessionWakeUp(id: id, key: key)
  }
  private func addWakeUp(_ watch: SessionWatchRecord, kind: SessionWakeUp.Kind, key: String, question: String? = nil) async {
    let record = SessionWakeUpRecord(id: watch.id, callerID: watch.callerID, workspaceID: watch.workspaceID, kind: kind, key: key,
      title: watch.title, workspaceName: watch.workspaceName, harness: watch.harness, question: question,
      createdAt: WorkspaceDatabaseConnection.timestamp(Date()))
    wakeUps[watch.id] = record; retryAt.removeValue(forKey: watch.id); botFailures.removeValue(forKey: watch.id)
    do { try await database.saveSessionWakeUp(record) } catch { hooks.log("A wake-up could not be saved: \(error.localizedDescription)") }
    let caller = watch.callerID
    Task { await self.deliverPending(callerID: caller) }
  }

  // MARK: Delivery

  /// Delivers what is due: called after each change and on a schedule, since a
  /// conversation's own turn ending is what makes its wake-up deliverable.
  public func deliverPending(callerID: String? = nil) async {
    let callers = callerID.map { [$0] } ?? Array(Set(wakeUps.values.map(\.callerID))).sorted()
    for caller in callers {
      // One delivery at a time per caller, in order.
      let previous = chains[caller]
      let task = Task { await previous?.value; await self.deliver(caller) }
      chains[caller] = task
      await task.value
      if chains[caller] == task { chains.removeValue(forKey: caller) }
    }
  }

  private func text(_ wakeUp: SessionWakeUpRecord, last: Bool) -> String {
    SessionWakeUp.text(kind: wakeUp.kind, sessionID: wakeUp.id, title: wakeUp.title,
                       workspaceName: wakeUp.workspaceName ?? wakeUp.workspaceID, question: wakeUp.question, last: last)
  }

  private func delivery(_ wakeUp: SessionWakeUpRecord, last: Bool, attempt: Bool) -> Delivery {
    let seed = [wakeUp.callerID, wakeUp.id, wakeUp.key] + (attempt ? [String(wakeUp.attempt)] : [])
    return .init(id: Self.stableID(seed.joined(separator: ":")), callerID: wakeUp.callerID, sessionID: wakeUp.id,
                 title: wakeUp.title, harness: wakeUp.harness, text: text(wakeUp, last: last), key: wakeUp.key)
  }

  private func deliver(_ callerID: String) async {
    let now = ContinuousClock.now
    // A caller waiting on that session learns its state from the wait itself.
    let candidates = pending(callerID: callerID).filter { waiting[callerID + "\u{0}" + $0.id] == nil }
    guard !candidates.isEmpty else { return }
    let due = candidates.filter { retryAt[$0.id].map { $0 <= now } ?? true }
    switch await hooks.caller(callerID) {
    case .gone:
      for wakeUp in pending(callerID: callerID) { await dropWakeUp(wakeUp.id) }
    case .bot:
      guard !due.isEmpty else { return }
      for wakeUp in due {
        let used = (try? await database.botWakeUpCount(callerID: callerID)) ?? 0
        guard used < maximumWakeUps else { await dropWakeUp(wakeUp.id, key: wakeUp.key); continue }
        do { try await hooks.deliverToBot(delivery(wakeUp, last: used + 1 == maximumWakeUps, attempt: false)) }
        catch {
          // The bots runtime may be restarting; one that stays away drops it after 20 tries.
          let failures = (botFailures[wakeUp.id] ?? 0) + 1
          if failures >= 20 { hooks.log("A wake-up for a bot was dropped: \(error.localizedDescription)"); await dropWakeUp(wakeUp.id, key: wakeUp.key); continue }
          botFailures[wakeUp.id] = failures; retryAt[wakeUp.id] = now + retryInterval
          break
        }
        try? await database.setBotWakeUpCount(callerID: callerID, count: used + 1)
        await dropWakeUp(wakeUp.id, key: wakeUp.key)
      }
    case .conversation(let idle, let used):
      // A running caller is never woken: its next idle moment delivers, even
      // one refused earlier, without waiting out its retry.
      guard idle else { for wakeUp in candidates { retryAt.removeValue(forKey: wakeUp.id) }; return }
      guard let wakeUp = due.first else { return }
      guard used < maximumWakeUps else {
        hooks.log("Session \(callerID) had \(maximumWakeUps) wake-ups in a row; the rest are dropped until it is started another way.")
        for pending in pending(callerID: callerID) { await dropWakeUp(pending.id) }
        return
      }
      let attempt = delivery(wakeUp, last: used + 1 == maximumWakeUps, attempt: true)
      if await hooks.deliverToConversation(attempt) {
        await dropWakeUp(wakeUp.id, key: wakeUp.key)
        return
      }
      // The caller may no longer receive it at all (it lost the Sessions
      // tool): its delivery was cancelled without a reason to try later.
      // That cancelled delivery is the record; no new attempt is made.
      if let refused = try? await database.toolDelivery(id: attempt.id), refused.status == "cancelled", refused.failureCode == nil {
        hooks.log("A wake-up for session \(callerID) was refused: it can no longer be woken by the sessions it created.")
        await dropWakeUp(wakeUp.id, key: wakeUp.key)
        return
      }
      // Refused for now (it started running, or the Mac is at its session
      // limit): a new attempt, and a new delivery ID, when it is idle again,
      // or after a wait that doubles with each refusal in a row.
      guard var current = wakeUps[wakeUp.id], current.key == wakeUp.key else { return }
      current.attempt += 1
      // As on Linux, a wake-up refused this many times in a row is dropped.
      guard current.attempt < Self.maximumDeliveryAttempts else {
        hooks.log("A wake-up for session \(callerID) was refused \(Self.maximumDeliveryAttempts) times and is dropped.")
        await dropWakeUp(wakeUp.id, key: wakeUp.key)
        return
      }
      wakeUps[wakeUp.id] = current; retryAt[wakeUp.id] = now + retryDelay(attempt: current.attempt)
      try? await database.saveSessionWakeUp(current)
    }
  }

  /// Refusals in a row after which a wake-up is dropped (Linux: `maximumDeliveryAttempts`).
  nonisolated static let maximumDeliveryAttempts = 20

  /// `retryInterval` after the first refusal, doubling to eight times it.
  func retryDelay(attempt: Int) -> Duration {
    retryInterval * (1 << min(max(attempt, 1) - 1, 3))
  }

  nonisolated static func stableID(_ value: String) -> String {
    var bytes = Array(PortableSHA256.hash(data: Data("woven-session-wake-up-v1\u{0}\(value)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
  }

  // MARK: Waiting

  /// `woven_sessions_wait`: `read` returns the `woven_sessions_status` body
  /// and its state. It is read once at the start, again after each change
  /// that reaches `until` (to confirm it), and once at the timeout. The reply
  /// is that body plus `state` and `timedOut`.
  public func wait(callerID: String?, workspaceID: String, id rawID: String, until: String, timeout: Duration,
                   read: @MainActor () async throws -> (body: GatewayJSONValue, state: String)) async throws -> GatewayJSONValue {
    let id = rawID.lowercased(), clock = ContinuousClock(), deadline = clock.now + timeout
    let waitKey = callerID.map { $0 + "\u{0}" + id }
    if let waitKey { waiting[waitKey, default: 0] += 1 }
    tracked[workspaceID, default: [:]][id, default: 0] += 1
    let waiter = Waiter(workspaceID: workspaceID, id: id, until: until), key = UUID()
    waiters[key] = waiter
    defer {
      waiters.removeValue(forKey: key)
      if let count = tracked[workspaceID]?[id], count > 1 { tracked[workspaceID]?[id] = count - 1 } else { tracked[workspaceID]?.removeValue(forKey: id) }
      if let waitKey {
        if let count = waiting[waitKey], count > 1 { waiting[waitKey] = count - 1 } else { waiting.removeValue(forKey: waitKey) }
      }
      // What the wait did not already show its caller is delivered now.
      if let callerID { Task { await self.deliverPending(callerID: callerID) } }
    }
    while true {
      waiter.hinted = false
      try Task.checkCancellation()
      let current = try await read()
      if Self.reaches(current.state, until) { return Self.reply(current.body, state: current.state, timedOut: false) }
      guard clock.now < deadline else { return Self.reply(current.body, state: current.state, timedOut: true) }
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        if waiter.hinted { continuation.resume(); return }
        waiter.continuation = continuation
        Task { @MainActor [weak waiter] in
          try? await Task.sleep(until: deadline, clock: clock)
          waiter?.wake()
        }
      }
    }
  }

  nonisolated static func reply(_ body: GatewayJSONValue, state: String, timedOut: Bool) -> GatewayJSONValue {
    var value = body.objectValue ?? ["status": body]
    value["state"] = .string(state); value["timedOut"] = .bool(timedOut)
    return .object(value)
  }
}

/// One destination's `workspace` stream, reduced to the sessions kept.
/// Only kept sessions' summaries are held; the rest of each snapshot is
/// reduced to its IDs and runs. After the stream synchronizes, every item yields the
/// current snapshot of each kept session it knows, and `missing` for one the
/// destination removed or a full snapshot left out (Linux: `createRemoteSessionSource`).
public struct SessionStreamProjection: Sendable {
  private var conversations: [String: LibraryConversation] = [:]
  /// Every session's pending interactions (the whole list is small).
  private var pending: [String: [PendingInteraction]] = [:]
  /// Every session's active run and the runs last seen ending, newest last,
  /// so a watch made after its change still learns of it (`after`).
  private var runs: [String: (active: String?, ended: [String])] = [:]
  private var known: Set<String> = []
  private var removed: Set<String> = []
  private var ready = false
  private var snapshotting = false
  public init() {}

  public mutating func receive(_ payload: StreamItem.Payload, keep: Set<String>) -> [(String, SessionWakeUps.Snapshot)] {
    switch payload {
    case .conversations(let value):
      if value.snapshot { ready = false; snapshotting = true; known = []; conversations = [:] }
      for conversation in value.conversations {
        let id = conversation.id.lowercased()
        known.insert(id); removed.remove(id)
        if keep.contains(id) { conversations[id] = conversation } else { conversations.removeValue(forKey: id) }
        var run = runs[id] ?? (nil, [])
        if let active = run.active, active != conversation.activeRunID {
          run.ended = Array((run.ended.filter { $0 != active } + [active]).suffix(8))
        }
        run.active = conversation.activeRunID
        runs[id] = run
      }
      for raw in value.deletedConversationIDs ?? [] {
        let id = raw.lowercased()
        known.remove(id); conversations.removeValue(forKey: id); runs.removeValue(forKey: id); removed.insert(id)
      }
    case .pending(let value):
      pending = [:]
      for interaction in value.interactions {
        pending[interaction.conversationID.lowercased(), default: []].append(interaction)
      }
    case .synchronized:
      // A kept session the whole snapshot left out is gone from there.
      if snapshotting {
        for id in keep where !known.contains(id) { removed.insert(id) }
        runs = runs.filter { known.contains($0.key) }
      }
      snapshotting = false; ready = true
    default: return []
    }
    guard ready else { return [] }
    return keep.sorted().compactMap { id in
      if let conversation = conversations[id] { return (id, .init(conversation: conversation, pending: pending[id] ?? [])) }
      // Not kept when the snapshot came, or not seen yet: its next change says.
      return removed.contains(id) ? (id, .missing) : nil
    }
  }

  /// What the stream already said about `id` that a caller who saw it in
  /// `observed` state during run `runID` has not seen: `idle` once that run
  /// was seen ending, or `needsInput` when it asks for input in that run
  /// after the caller made it run. Nil otherwise, including while the stream
  /// has not caught up with what the caller saw (its next change says).
  public func after(_ id: String, runID: String?, observed: String) -> SessionWakeUps.Snapshot? {
    guard ready, let runID, let run = runs[id] else { return nil }
    if run.active == nil, run.ended.contains(runID) { return .init(state: "idle") }
    if observed == "running", run.active == runID, let asked = pending[id], !asked.isEmpty {
      return .init(state: "needsInput", runID: runID, pending: asked)
    }
    return nil
  }
}
