import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

/// Waits and wake-ups on a Mac (`SessionWakeUps`), case for case with the Linux
/// server's remote/test/session-watch.test.mjs.
@Suite("Session wake-ups") @MainActor
struct SessionWakeUpsTests {
  static let workspace = "w1", workspaceName = "Workstation W"

  /// A coordinator on a fresh database, with callers the test drives.
  @MainActor final class Fixture {
    let root: URL
    let database: WorkspaceDatabase
    var wakeUps: SessionWakeUps!
    var callers: [String: SessionWakeUps.Caller] = [:]
    var delivered: [SessionWakeUps.Delivery] = []
    var bots: [SessionWakeUps.Delivery] = []
    var reconcile: [String: (conversations: [LibraryConversation], pending: [PendingInteraction])] = [:]
    /// Refuses the next send, as when the caller started running meanwhile.
    var refuseNext = false
    var refused: [SessionWakeUps.Delivery] = []

    init(root: URL? = nil) async throws {
      self.root = root ?? FileManager.default.temporaryDirectory.appending(path: "session-wake-ups-\(UUID())")
      try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
      database = try await WorkspaceDatabase(url: self.root.appending(path: "workspace.sqlite"))
      wakeUps = SessionWakeUps(database: database, hooks: .init(
        caller: { [unowned self] id in self.callers[id] ?? .gone },
        deliverToConversation: { [unowned self] delivery in
          guard case .conversation(true, let used) = self.callers[delivery.callerID] else { return false }
          if self.refuseNext { self.refuseNext = false; self.refused.append(delivery); return false }
          self.delivered.append(delivery)
          // The wake-up starts a run: the caller is busy, and one more run in a row was a wake-up's.
          self.callers[delivery.callerID] = .conversation(idle: false, wokenRunsInARow: used + 1)
          return true
        },
        deliverToBot: { [unowned self] delivery in self.bots.append(delivery) },
        reconcile: { [unowned self] id in self.reconcile[id] }))
    }

    func remember(_ id: String, caller: String) async throws {
      try await database.rememberMemberToolSession(id: id, callerID: caller, workspaceID: SessionWakeUpsTests.workspace)
    }
    func observe(_ caller: String, _ id: String, _ state: String, runID: String? = nil, title: String? = "Job", created: Bool = false) async {
      await wakeUps.observe(callerID: caller, workspaceID: SessionWakeUpsTests.workspace, workspaceName: SessionWakeUpsTests.workspaceName,
                            id: id, title: title, harness: "codex", state: state, runID: runID, created: created)
    }
    func emit(_ id: String, _ state: String, runID: String? = "remote-run", pending: [PendingInteraction] = [], title: String? = nil) async {
      await wakeUps.changed(workspaceID: SessionWakeUpsTests.workspace, id: id,
                            .init(state: state, title: title, runID: state == "idle" ? nil : runID, pending: pending))
      await settle()
      await wakeUps.deliverPending()
    }
    /// Lets the deliveries that changes schedule run.
    func settle() async { for _ in 0..<20 { await Task.yield() } }
    /// Ends the caller's (woken) turn.
    func idle(_ caller: String) {
      if case .conversation(_, let used) = callers[caller] { callers[caller] = .conversation(idle: true, wokenRunsInARow: used) }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }

  static func question(_ id: String, _ conversation: String, title: String = "Which log?") -> PendingInteraction {
    .init(id: id, conversationID: conversation, runID: "remote-run", kind: .question, title: title)
  }
  static func conversation(_ id: String, running: String? = nil, title: String = "Job") -> LibraryConversation {
    .init(id: id, title: title, providerID: "codex", runtimeKind: "codex", activeRunID: running, preview: "", updatedAt: "2026-11-12T12:00:00Z",
          libraryID: "library", workspaceID: workspace)
  }

  @Test func wakeUpTextMatchesTheSharedFixturesThroughTheMacPath() async throws {
    struct Case: Decodable { let kind: SessionWakeUp.Kind; let sessionID: String; let title: String?; let workspaceName: String
      let question: String?; let last: Bool?; let text: String }
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "shared/Tests/WovenMatterSharedTests/SessionWakeUpFixtures.json")
    let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    #expect(cases.count >= 5)
    for item in cases {
      let f = try await Fixture(); defer { f.remove() }
      let caller = UUID().uuidString.lowercased()
      // The last allowed wake-up of a run says so.
      f.callers[caller] = .conversation(idle: true, wokenRunsInARow: item.last == true ? StreamProtocol.maximumWakeUpsPerRun - 1 : 0)
      try await f.remember(item.sessionID, caller: caller)
      await f.wakeUps.observe(callerID: caller, workspaceID: Self.workspace, workspaceName: item.workspaceName, id: item.sessionID,
                              title: item.title, state: "running", runID: "r1")
      if item.kind == .finished { await f.emit(item.sessionID, "idle") }
      else { await f.emit(item.sessionID, "needsInput", pending: [Self.question("q1", item.sessionID, title: item.question ?? "")]) }
      #expect(f.delivered.map(\.text) == [item.text])
    }
  }

  @Test func atMostTenWakeUpsPerCallingRunAndARunStartedAnotherWayCountsAgain() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let caller = UUID().uuidString.lowercased(), session = UUID().uuidString.lowercased()
    f.callers[caller] = .conversation(idle: true, wokenRunsInARow: 0)
    try await f.remember(session, caller: caller)
    for round in 1...(StreamProtocol.maximumWakeUpsPerRun + 2) {
      // The (woken) caller gives the session more work, then its turn ends.
      await f.observe(caller, session, "running", runID: "remote-\(round)")
      f.idle(caller)
      await f.emit(session, "idle")
    }
    #expect(f.delivered.count == StreamProtocol.maximumWakeUpsPerRun)
    #expect(!f.delivered[StreamProtocol.maximumWakeUpsPerRun - 2].text.contains("last wake-up"))
    #expect(f.delivered.last?.text.contains("This is your last wake-up") == true)
    #expect(Set(f.delivered.map(\.id)).count == f.delivered.count, "one delivery per wake-up")
    #expect(f.wakeUps.pending(callerID: caller).isEmpty, "the eleventh was dropped")

    // The user starts the caller again: a new count.
    f.callers[caller] = .conversation(idle: true, wokenRunsInARow: 0)
    await f.observe(caller, session, "running", runID: "remote-x")
    await f.emit(session, "idle")
    #expect(f.delivered.count == StreamProtocol.maximumWakeUpsPerRun + 1)
  }

  @Test func wakeUpsWaitForAnIdleCallerGiveWayToNewerStatesAndSurviveARestart() async throws {
    let f = try await Fixture()
    let caller = UUID().uuidString.lowercased(), session = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
    f.callers[caller] = .conversation(idle: false, wokenRunsInARow: 0)
    try await f.remember(session, caller: caller); try await f.remember(other, caller: caller)
    await f.observe(caller, session, "running", runID: "r1", title: "Index")
    await f.observe(caller, other, "running", runID: "r2", title: "Other")

    // A question while the caller runs: held. The session runs on: dropped.
    await f.emit(session, "needsInput", pending: [Self.question("q1", session)])
    #expect(f.delivered.isEmpty, "a running caller is not woken")
    #expect(f.wakeUps.pending(callerID: caller).count == 1)
    await f.emit(session, "running", runID: "r1b")
    #expect(f.wakeUps.pending(callerID: caller).isEmpty, "superseded by running again")
    // Finished while the caller runs; a status read by its caller drops it.
    await f.emit(session, "idle")
    #expect(f.wakeUps.pending(callerID: caller).first?.kind == .finished)
    await f.observe(caller, session, "idle")
    #expect(f.wakeUps.pending(callerID: caller).isEmpty, "the caller saw it finish")
    await f.observe(caller, session, "running", runID: "r1c", title: "Index")
    await f.emit(session, "idle")
    #expect(f.wakeUps.pending(callerID: caller).count == 1)
    // Only the caller that created a session watches it.
    await f.observe(UUID().uuidString.lowercased(), other, "idle")
    #expect(f.wakeUps.watched.map(\.id) == [other])

    // Restart: a new coordinator on the same database delivers what was
    // pending and compares what the workspace runs now with what it stored.
    let restarted = try await Fixture(root: f.root); defer { restarted.remove() }
    restarted.callers[caller] = .conversation(idle: true, wokenRunsInARow: 0)
    restarted.reconcile[Self.workspace] = ([Self.conversation(other, title: "Other")], [])
    await restarted.wakeUps.start()
    await restarted.wakeUps.deliverPending()
    #expect(restarted.delivered.count == 1, "the pending wake-up survived the restart")
    #expect(restarted.delivered.first?.text.hasPrefix("Your session \"Index\"") == true)
    restarted.idle(caller)
    await restarted.wakeUps.deliverPending()
    #expect(restarted.delivered.count == 2, "a session that finished meanwhile wakes its caller")
    #expect(restarted.delivered.last?.text.contains("\"Other\"") == true)
    #expect(restarted.wakeUps.watched.isEmpty, "nothing is watched once both finished")
  }

  @Test func aRefusedWakeUpIsSentAgainAtTheCallersNextIdleMomentAsANewAttempt() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let caller = UUID().uuidString.lowercased(), session = UUID().uuidString.lowercased()
    f.callers[caller] = .conversation(idle: true, wokenRunsInARow: 0)
    try await f.remember(session, caller: caller)
    await f.observe(caller, session, "running", runID: "r1")
    f.refuseNext = true
    await f.emit(session, "idle")
    #expect(f.delivered.isEmpty && f.refused.count == 1)
    // Still idle: it waits out the retry interval instead of sending again at once.
    await f.wakeUps.deliverPending()
    #expect(f.delivered.isEmpty)
    // It ran (the reason it was refused) and is idle again: sent now, as a new attempt.
    f.callers[caller] = .conversation(idle: false, wokenRunsInARow: 0)
    await f.wakeUps.deliverPending()
    f.callers[caller] = .conversation(idle: true, wokenRunsInARow: 0)
    await f.wakeUps.deliverPending()
    #expect(f.delivered.count == 1)
    #expect(f.delivered.first?.id != f.refused.first?.id && f.delivered.first?.text == f.refused.first?.text)
  }

  @Test func aBotsCountStartsAgainWhenItCreatesASession() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let caller = WovenMCPCaller.bot(machineID: UUID().uuidString.lowercased(), botID: UUID().uuidString.lowercased())
    let session = UUID().uuidString.lowercased()
    f.callers[caller] = .bot
    try await f.remember(session, caller: caller)
    for round in 0...StreamProtocol.maximumWakeUpsPerRun {
      await f.observe(caller, session, "running", runID: "r\(round)")
      await f.emit(session, "idle")
    }
    #expect(f.bots.count == StreamProtocol.maximumWakeUpsPerRun)
    #expect(f.bots.last?.text.contains("last wake-up") == true)
    await f.observe(caller, session, "running", runID: "new", created: true)
    await f.emit(session, "idle")
    #expect(f.bots.count == StreamProtocol.maximumWakeUpsPerRun + 1)
  }

  @Test func aWaitResolvesOnIdleNeedsInputAndEitherAndTimesOut() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let id = UUID().uuidString.lowercased()
    final class Reads { var count = 0; var state = "running" }
    let reads = Reads()
    let read: @MainActor () async throws -> (body: GatewayJSONValue, state: String) = {
      reads.count += 1
      return (.object(["session": .object(["id": .string(id), "state": .string(reads.state)])]), reads.state)
    }

    // Already there: one read.
    reads.state = "idle"
    var reply = try await f.wakeUps.wait(callerID: nil, workspaceID: Self.workspace, id: id, until: "idle", timeout: .seconds(5), read: read)
    #expect(reply.objectValue?["state"] == .string("idle") && reply.objectValue?["timedOut"] == .bool(false))
    #expect(reply.objectValue?["session"]?.objectValue?["id"] == .string(id), "the woven_sessions_status body")
    #expect(reads.count == 1)

    // Running until the timeout.
    reads.state = "running"; reads.count = 0
    let started = ContinuousClock.now
    reply = try await f.wakeUps.wait(callerID: nil, workspaceID: Self.workspace, id: id, until: "idle", timeout: .seconds(1), read: read)
    #expect(reply.objectValue?["state"] == .string("running") && reply.objectValue?["timedOut"] == .bool(true))
    #expect(ContinuousClock.now - started >= .milliseconds(950))
    #expect(reads.count == 2, "read at the start and at the timeout, never polled")

    // A change that reaches `until` resolves it, confirmed with one more read.
    for (until, state) in [("idle", "idle"), ("needsInput", "needsInput"), ("either", "needsInput"), ("either", "idle")] {
      reads.state = "running"; reads.count = 0
      let waiting = Task { try await f.wakeUps.wait(callerID: nil, workspaceID: Self.workspace, id: id, until: until, timeout: .seconds(10), read: read) }
      while reads.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
      // A change that does not reach it is ignored.
      await f.emit(id, "running", runID: "other-run")
      reads.state = state
      await f.emit(id, state, pending: state == "needsInput" ? [Self.question("q", id)] : [])
      reply = try await waiting.value
      #expect(reply.objectValue?["state"] == .string(state) && reply.objectValue?["timedOut"] == .bool(false), "\(until)")
      #expect(reads.count == 2, "\(until): \(reads.count) reads")
    }
  }

  @Test func aCallerWaitingOnASessionIsNotWokenForIt() async throws {
    let f = try await Fixture(); defer { f.remove() }
    let caller = WovenMCPCaller.bot(machineID: UUID().uuidString.lowercased(), botID: UUID().uuidString.lowercased())
    let session = UUID().uuidString.lowercased()
    f.callers[caller] = .bot
    try await f.remember(session, caller: caller)
    await f.observe(caller, session, "running", runID: "r1")
    final class State { var value = "running"; var reads = 0 }
    let state = State()
    let waiting = Task {
      try await f.wakeUps.wait(callerID: caller, workspaceID: Self.workspace, id: session, until: "idle", timeout: .seconds(10)) {
        // The wait's read is a status read: it observes what it shows.
        await f.observe(caller, session, state.value)
        state.reads += 1
        return (.object([:]), state.value)
      }
    }
    // The wait has begun (its first read is done) before the session finishes.
    while state.reads == 0 { try await Task.sleep(for: .milliseconds(10)) }
    state.value = "idle"
    await f.emit(session, "idle")
    #expect(try await waiting.value.objectValue?["state"] == .string("idle"))
    // Delivery runs once more after the wait (its own and this one, in order):
    // nothing is left to deliver, rather than not delivered yet.
    await f.wakeUps.deliverPending(callerID: caller)
    #expect(f.wakeUps.pending(callerID: caller).isEmpty)
    #expect(f.bots.isEmpty, "the wait already told the bot")
  }

  @Test func theStreamProjectionKeepsOnlyWatchedSessionsAndSaysWhichAreGone() {
    var projection = SessionStreamProjection()
    let kept = "a", other = "b", fresh = "c"
    // Nothing until the stream synchronized.
    #expect(projection.receive(.conversations(.init(conversations: [Self.conversation(kept, running: "r1"), Self.conversation(other)], snapshot: true)), keep: [kept]).isEmpty)
    #expect(projection.receive(.pending(.init(interactions: [Self.question("q1", kept), Self.question("q2", other)])), keep: [kept]).isEmpty)
    var changes = projection.receive(.synchronized, keep: [kept, fresh])
    #expect(changes.map(\.0) == [kept, fresh])
    #expect(changes.first?.1.state == "needsInput" && changes.first?.1.pending.map(\.id) == ["q1"])
    #expect(changes.last?.1.state == "missing", "a kept session the full snapshot left out is gone")
    // A session not yet seen (just created there) is not missing.
    changes = projection.receive(.pending(.init(interactions: [])), keep: [kept, "d"])
    #expect(changes.map(\.0) == [kept] && changes.first?.1.state == "running")
    changes = projection.receive(.conversations(.init(conversations: [Self.conversation(kept)], deletedConversationIDs: [other], snapshot: false)), keep: [kept, other])
    #expect(changes.map { "\($0.0)=\($0.1.state)" } == ["\(kept)=idle", "\(other)=missing"])
  }
}
