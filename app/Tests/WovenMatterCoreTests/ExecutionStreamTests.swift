// The Mac stream server terminates WebSockets with the Network framework.
#if os(macOS)
import CryptoKit
import Foundation
import Network
import Testing
import WorkspaceFixtures
import WovenMatterCore
@testable import WovenMatterDashboardStore

/// The Mac's side of `GET /v1/stream` ("Streaming" in
/// docs/architecture/WOVEN_EVERYWHERE.md): its change source, the signed
/// upgrade through the real library server, and the frames it serves.
@Suite(.serialized)
struct ExecutionStreamTests {
  // MARK: Change source

  @Test func changesAreRecordedWithTheirRowsOnlyForConversationsThisMacRuns() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let database = try await fixture.openDatabase()
    let local = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Local", ownerDeviceID: UUID())
    let paired = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Another Mac's", ownerDeviceID: UUID())
    let federated = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "A Linux host's", ownerDeviceID: UUID())
    try await database.write { connection in
      try connection.toolsExecuteUnlocked("INSERT OR REPLACE INTO paired_conversation_owners VALUES(?,?)", [paired, UUID().uuidString.lowercased()])
      try connection.toolsExecuteUnlocked("INSERT INTO execution_conversations(id,workspace_id,conversation) VALUES(?,?,?)",
        [federated, UUID().uuidString.lowercased(), "{}"])
    }
    let start = try await database.executionStreamCursor()
    #expect(start > 0, "creating a local session records it")
    let run = try await database.beginLocalACPRun(conversationID: local, input: .init(text: "Run the tests"))
    // History synchronized from the machines that run these arrives as rows.
    try await database.write { connection in
      for (conversation, text) in [(paired, "Synced from another Mac"), (federated, "Synced from Linux")] {
        try connection.toolsExecuteUnlocked("INSERT INTO dashboard_messages(id,conversation_id,role,content,created_at,updated_at) VALUES(?,?,'assistant',?,?,?)",
          [UUID().uuidString.lowercased(), conversation, text, "2026-11-12T10:00:00.000Z", "2026-11-12T10:00:00.000Z"])
        try connection.toolsExecuteUnlocked("UPDATE dashboard_conversations SET title=? WHERE id=?", [text, conversation])
      }
    }
    try await database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "All 214 tests")

    let page = try await database.executionStreamChanges(after: start)
    #expect(!page.truncated && !page.hasMore)
    #expect(Set(page.changes.map(\.conversationID)) == [local], "synchronized history is never a stream change")
    let kinds = Set(page.changes.map(\.entityKind))
    #expect(kinds.isSuperset(of: ["message", "run"]))
    #expect(page.changes.contains { $0.entityKind == "message" && $0.entityID == run.assistantMessageID })
    // Gap-free: every sequence after the cursor is present, in order.
    #expect(page.changes.map(\.sequence) == Array((start + 1)...page.latest))

    // A rolled-back write leaves no pointer and no gap.
    let before = try await database.executionStreamCursor()
    struct Abort: Error {}
    await #expect(throws: Abort.self) {
      try await database.write { connection in
        try connection.transaction {
          try connection.toolsExecuteUnlocked("UPDATE dashboard_messages SET content='discarded' WHERE id=?", [run.assistantMessageID])
          throw Abort()
        }
      }
    }
    #expect(try await database.executionStreamCursor() == before)
    try await database.appendLocalACPAssistantChunk(runID: run.runID, chunk: " pass")
    let next = try await database.executionStreamChanges(after: before)
    #expect(next.changes.first?.sequence == before + 1)
  }

  @Test func theChangeSourceKeepsTheNewestEntriesAndIsAddedToExistingDatabases() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let database = try await fixture.openDatabase()
    let local = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Local", ownerDeviceID: UUID())
    let run = try await database.beginLocalACPRun(conversationID: local, input: .init(text: "Go"))
    let total = StreamProtocol.maximumRetainedChanges + 50
    try await database.write { connection in
      // Only this fixture's own speed: the other triggers on messages are unrelated here.
      for trigger in try connection.historyRowsUnlocked("SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='dashboard_messages' AND name NOT LIKE 'execution_stream_%'", values: []) {
        try connection.executeUnlocked("DROP TRIGGER \(trigger.objectValue!["name"]!.stringValue!)")
      }
      try connection.transaction {
        for index in 0..<total {
          try connection.toolsExecuteUnlocked("UPDATE dashboard_messages SET content=? WHERE id=?", ["chunk \(index)", run.assistantMessageID])
        }
      }
    }
    let latest = try await database.executionStreamCursor()
    let counts = try await database.read { connection in
      try connection.historyRowsUnlocked("SELECT COUNT(*) AS n, MIN(sequence) AS oldest FROM execution_stream_changes", values: []).first?.objectValue
    }
    #expect(counts?["n"]?.doubleValue == Double(StreamProtocol.maximumRetainedChanges))
    #expect(counts?["oldest"]?.doubleValue == Double(latest - Int64(StreamProtocol.maximumRetainedChanges) + 1))
    // A reader whose cursor was pruned must start again from a snapshot.
    #expect(try await database.executionStreamChanges(after: 1).truncated)
    #expect(try await database.executionStreamChanges(after: latest - 10).truncated == false)

    // A database from before the change source: no table and no triggers.
    try await database.write { connection in
      let triggers = try connection.historyRowsUnlocked("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'execution_stream_%'", values: [])
      #expect(triggers.count == WorkspaceDatabaseConnection.executionStreamTables.count * 3)
      for trigger in triggers { try connection.executeUnlocked("DROP TRIGGER \(trigger.objectValue!["name"]!.stringValue!)") }
      try connection.executeUnlocked("DROP TABLE execution_stream_changes")
      try connection.executeUnlocked("DELETE FROM sqlite_sequence WHERE name='execution_stream_changes'")
    }
    try await database.appendLocalACPAssistantChunk(runID: run.runID, chunk: " unrecorded")
    let upgraded = try await WorkspaceDatabase(url: fixture.databaseURL)
    #expect(try await upgraded.executionStreamCursor() == 0)
    try await upgraded.appendLocalACPAssistantChunk(runID: run.runID, chunk: " recorded")
    let page = try await upgraded.executionStreamChanges(after: 0)
    #expect(page.changes.first?.sequence == 1 && Set(page.changes.map(\.conversationID)) == [local])
  }

  // MARK: End to end

  @Test func aSignedClientStreamsTheWorkspaceAndALiveConversationAndSendsCommands() async throws {
    var configuration = ExecutionStreamConfiguration()
    configuration.smallMessageInterval = .milliseconds(50); configuration.largeMessageInterval = .milliseconds(200)
    let mac = try await StreamMac(configuration: configuration); defer { mac.remove() }
    let conversation = try await mac.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Fix the build", ownerDeviceID: UUID())
    let run = try await mac.database.beginLocalACPRun(conversationID: conversation, input: .init(text: "Run the tests"))
    let phone = try await mac.member(.ios)

    let client = try await mac.connect(phone)
    guard case .hello(let hello) = try await client.next() else { Issue.record("hello was not first"); return }
    #expect(hello.protocol == 1 && hello.deviceID == mac.hostID && hello.workspaceID == mac.descriptor.id)
    #expect(hello.libraryID == mac.descriptor.libraryID && hello.capabilities.contains(StreamProtocol.capability))
    #expect(hello.maxFrameBytes == StreamProtocol.maximumFrameBytes)

    // Workspace: the conversations snapshot and the pending list, then synchronized.
    client.send(.subscribe(.init(id: "w", stream: .workspace)))
    let snapshot = try await client.item("w")
    guard case .conversations(let conversations) = snapshot.payload else { Issue.record("no conversations snapshot"); return }
    #expect(conversations.snapshot && conversations.conversations.map(\.id) == [conversation])
    #expect(conversations.conversations.first?.workspaceID == mac.descriptor.id)
    #expect(try await mac.api.localConversations() == conversations.conversations, "the same data as GET v1/execution/conversations")
    guard case .pending(let pending) = try await client.item("w").payload else { Issue.record("no pending"); return }
    #expect(pending.interactions.isEmpty)
    #expect(try await client.item("w").payload == .library(.init(cursor: mac.database.libraryWakeCursor())))
    #expect(try await client.item("w").payload == .synchronized)

    // Conversation: the transcript GET returns, capabilities, synchronized.
    client.send(.subscribe(.init(id: "c", stream: .conversation, params: .init(conversationID: conversation))))
    guard case .transcript(let first) = try await client.item("c").payload else { Issue.record("no transcript"); return }
    #expect(first.snapshot)
    #expect(try await first.transcript == mac.api.localTranscript(conversationID: conversation))
    guard case .capabilities(let capabilities) = try await client.item("c").payload else { Issue.record("no capabilities"); return }
    #expect(capabilities.capabilities.id == "local:codex")
    guard case .session(let session) = try await client.item("c").payload else { Issue.record("no session"); return }
    #expect(try await session.settings == mac.api.localSessionSettings(conversationID: conversation))
    #expect(try await client.item("c").payload == .synchronized)

    // Live text: each persisted chunk reaches the client as the whole message so far.
    try await mac.database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "All 214 tests")
    let update = try await client.transcript("c") { $0.messages.contains { $0.id == run.assistantMessageID && $0.content == "All 214 tests" } }
    #expect(!update.snapshot && update.transcript.activeRunID == run.runID)
    #expect(update.transcript.messages.map(\.id) == [run.assistantMessageID], "only the changed message, whole")

    // Coalescing: rapid small writes arrive at most every 50 ms, and the last state always arrives.
    var small: [ContinuousClock.Instant] = []
    let smallStart = ContinuousClock.now, smallWrites = 100
    let writer = Task {
      for index in 0..<smallWrites {
        try await mac.database.appendLocalACPAssistantChunk(runID: run.runID, chunk: " \(index)")
        try await Task.sleep(for: .milliseconds(5))
      }
      return ContinuousClock.now
    }
    var finalContent = ""
    let expected = "All 214 tests" + (0..<smallWrites).map { " \($0)" }.joined()
    while finalContent != expected {
      let item = try await client.transcript("c") { _ in true }
      small.append(.now)
      finalContent = item.transcript.messages.first { $0.id == run.assistantMessageID }?.content ?? finalContent
    }
    // Writes a busy machine slows past the interval leave nothing to coalesce:
    // the bound always holds, and the rest is checked while the writes outpaced it.
    let smallPace = (try await writer.value - smallStart) / smallWrites
    #expect(small.count >= 2)
    #expect(Self.updates(small, since: smallStart, fitWithin: .milliseconds(50)), "\(small.count) updates over \(small.last! - smallStart)")
    if smallPace < .milliseconds(25) {
      #expect(small.count < smallWrites, "\(small.count) updates for \(smallWrites) writes")
      // And small messages are not held to the large messages' interval.
      #expect(!Self.updates(small, since: smallStart, fitWithin: .milliseconds(200)), "\(small.count) updates over \(small.last! - smallStart)")
    }

    // The 8 KB guard: once a changed message is larger, at most every 200 ms.
    let large = String(repeating: "x", count: StreamProtocol.smallMessageBytes + 1)
    try await mac.database.replaceLocalACPAssistantMessage(runID: run.runID, content: large)
    _ = try await client.transcript("c") { $0.messages.contains { $0.content == large } }
    var slow: [ContinuousClock.Instant] = []
    let largeStart = ContinuousClock.now
    let largeWriter = Task {
      for index in 0..<30 {
        try await mac.database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "\(index % 10)")
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    let expectedLarge = large + (0..<30).map { "\($0 % 10)" }.joined()
    var largeContent = ""
    while largeContent != expectedLarge {
      let item = try await client.transcript("c") { _ in true }
      slow.append(.now)
      largeContent = item.transcript.messages.first { $0.id == run.assistantMessageID }?.content ?? largeContent
    }
    try await largeWriter.value
    #expect(slow.count >= 2)
    #expect(Self.updates(slow, since: largeStart, fitWithin: .milliseconds(200)), "\(slow.count) updates over \(slow.last! - largeStart)")

    // A command, a duplicate replay of it, then its receipt.
    let command = LibraryCommand(deviceID: phone.deviceID, kind: .send, conversationID: conversation, text: "Continue",
                                 libraryID: mac.descriptor.libraryID, workspaceID: mac.descriptor.id)
    client.send(.request(try .init(id: "r1", method: .executionCommand, params: StreamCommandParams(command: command))))
    let receipt = try await client.response("r1").decodeResult(LibraryCommandReceipt.self)
    #expect(receipt.commandID == command.commandID && receipt.status == .accepted && receipt.workspaceID == mac.descriptor.id)
    client.send(.request(try .init(id: "r2", method: .executionCommand, params: StreamCommandParams(command: command))))
    #expect(try await client.response("r2").decodeResult(LibraryCommandReceipt.self) == receipt)
    let executed = await mac.commands.executed
    #expect(executed.map(\.commandID) == [command.commandID], "the replay was not executed again")
    client.send(.request(try .init(id: "r3", method: .executionReceipt, params: StreamReceiptParams(commandID: command.commandID))))
    #expect(try await client.response("r3").decodeResult(LibraryCommandReceipt.self) == receipt)
    client.send(.request(try .init(id: "r4", method: .executionReceipt, params: StreamReceiptParams(commandID: UUID().uuidString.lowercased()))))
    let missing = try await client.response("r4")
    #expect(missing.error == nil && (missing.result ?? .null) == .null)
    // Another device's identity is refused.
    var forged = command; forged.commandID = UUID().uuidString.lowercased(); forged.deviceID = mac.hostID
    client.send(.request(try .init(id: "r5", method: .executionCommand, params: StreamCommandParams(command: forged))))
    #expect(try await client.response("r5").error?.code == "invalid")

    // Pending questions reach the workspace stream when in-memory state changes.
    await mac.commands.setPending([.init(id: UUID().uuidString.lowercased(), conversationID: conversation, runID: run.runID,
                                         kind: .approval, title: "Run npm test?", options: [.init(id: "allow", label: "Allow")])])
    mac.stream.liveStateChanged()
    let asked = try await client.item("w") { if case .pending(let value) = $0.payload { return !value.interactions.isEmpty }; return false }
    guard case .pending(let value) = asked.payload else { return }
    #expect(value.interactions.first?.title == "Run npm test?")

    // A conversation this Mac does not run is not found; an archived one leaves the workspace.
    client.send(.subscribe(.init(id: "elsewhere", stream: .conversation, params: .init(conversationID: UUID().uuidString.lowercased()))))
    guard case .end(let refused) = try await client.next(where: { if case .end(let end) = $0 { return end.id == "elsewhere" }; return false }) else { return }
    #expect(refused.error?.code == "not_found")
    try await mac.database.write { try $0.toolsExecuteUnlocked("UPDATE dashboard_conversations SET is_archived=1 WHERE id=?", [conversation]) }
    let removal = try await client.item("w") { if case .conversations(let value) = $0.payload { return value.deletedConversationIDs != nil }; return false }
    guard case .conversations(let removed) = removal.payload else { return }
    #expect(removed.deletedConversationIDs == [conversation] && !removed.snapshot)

    // Unknown frames are ignored, a cancelled subscription goes quiet, and the socket stays open.
    client.sendRaw(#"{"t":"futureFrame","id":"x"}"#)
    client.send(.cancel(.init(id: "c")))
    client.send(.request(try .init(id: "r6", method: .executionReceipt, params: StreamReceiptParams(commandID: UUID().uuidString.lowercased()))))
    #expect(try await client.response("r6").error == nil)
    client.close()
  }

  /// Whether `arrivals` of updates caused by writes that began at `start`
  /// could have been sent at most every `interval`. The k-th such update is
  /// sent no earlier than `start + (k - 1) * interval` and arrives later still,
  /// so the bound is measured to the last arrival from `start`, not from the
  /// first arrival: delivery delays only lengthen that span, even when a busy
  /// machine hands the client several updates at once. One interval more
  /// allows for an update the previous write left queued.
  static func updates(_ arrivals: [ContinuousClock.Instant], since start: ContinuousClock.Instant, fitWithin interval: Duration) -> Bool {
    guard let last = arrivals.last else { return true }
    return Double(arrivals.count - 1) <= ((last - start) + interval) / interval
  }

  @Test func upgradesAreRefusedBeforeTheyBegin() async throws {
    let mac = try await StreamMac(); defer { mac.remove() }
    let phone = try await mac.member(.ios)
    let target = "/wovenmatter/v1/stream?protocol=1"

    let future = try await mac.rawUpgrade(target: "/wovenmatter/v1/stream?protocol=2", signer: phone)
    #expect(future.status == 426 && future.json?["code"] as? String == "protocol_unsupported")
    #expect(future.json?["supported"] as? [Int] == [1])

    let stale = MemberRequestSignature.now() - 10 * 60 * 1_000
    let staleResponse = try await mac.rawUpgrade(target: target, signer: phone, time: stale)
    #expect(staleResponse.status == 401 && staleResponse.json?["code"] as? String == "member_time_stale")
    let serverTime = try #require(staleResponse.json?["serverTime"] as? Int64)
    #expect(abs(serverTime - MemberRequestSignature.now()) < 60_000)

    let unsigned = try await mac.rawUpgrade(target: target, signer: nil)
    #expect(unsigned.status == 401 && unsigned.json?["code"] as? String == "unauthorized")
    let stranger = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .ios, key: .init())
    #expect(try await mac.rawUpgrade(target: target, signer: stranger).status == 401)

    let browser = try await mac.rawUpgrade(target: target, signer: phone, extra: ["Origin": "https://hostile.example"])
    #expect(browser.status == 403)
    let cookie = try await mac.rawUpgrade(target: target, signer: phone, extra: ["Cookie": "session=1"])
    #expect(cookie.status == 403)

    // Every refusal repeats its code in X-Woven-Error and carries a Date:
    // URLSessionWebSocketTask exposes a refused upgrade's headers, not its body.
    for (response, code) in [(future, "protocol_unsupported"), (staleResponse, "member_time_stale"), (unsigned, "unauthorized"),
                             (browser, LibraryHTTPParser.browserRequest.code), (cookie, LibraryHTTPParser.browserRequest.code)] {
      #expect(response.headers["x-woven-error"] == code && response.json?["code"] as? String == code, "\(code)")
      let date = try #require(response.headers["date"].flatMap(Self.httpDate), "\(code) has a Date")
      #expect(abs(date.timeIntervalSinceNow) < 60)
    }

    // The same signed request is accepted.
    #expect(try await mac.rawUpgrade(target: target, signer: phone).status == 101)

    // A stopped stream answers 503 unavailable, in the header too.
    mac.stream.stop()
    try await Task.sleep(for: .milliseconds(100))
    let stopped = try await mac.rawUpgrade(target: target, signer: phone)
    #expect(stopped.status == 503 && stopped.headers["x-woven-error"] == "unavailable" && stopped.headers["date"] != nil)
  }

  static func httpDate(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: text)
  }

  // MARK: Session settings

  @Test func theConversationStreamSendsTheSessionSettingsOnSubscribeAndWhenTheyChange() async throws {
    let mac = try await StreamMac(); defer { mac.remove() }
    let conversation = try await mac.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Settings", ownerDeviceID: UUID())
    let phone = try await mac.member(.ios)
    let client = try await mac.connect(phone)
    guard case .hello = try await client.next() else { Issue.record("no hello"); return }
    client.send(.subscribe(.init(id: "c", stream: .conversation, params: .init(conversationID: conversation))))

    // On subscribe, before synchronized: what the `session` workspace read returns.
    let first = try await client.session("c")
    #expect(try await first == mac.api.localSessionSettings(conversationID: conversation))
    #expect(first.conversationID == conversation && first.model == "gpt-5.5" && first.goal == nil)
    #expect(try await client.item("c").payload == .synchronized)

    // A model change the desktop keeps in memory reaches the stream as live state.
    await mac.commands.setModel("gpt-5.5-mini")
    mac.stream.liveStateChanged(conversationIDs: [conversation])
    #expect(try await client.session("c").model == "gpt-5.5-mini")

    // A goal is written to its own table, which the change source records.
    _ = try await mac.database.mutateGoal(sessionID: conversation, mutation: .set(objective: "Ship it", tokenBudget: nil, turnBudget: nil))
    #expect(try await client.session("c") { $0.goal != nil }.goal?.objective == "Ship it")

    // Changes that leave the settings as they were send no session item.
    let run = try await mac.database.beginLocalACPRun(conversationID: conversation, input: .init(text: "Go"))
    try await mac.database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "Working")
    _ = try await client.transcript("c") { $0.messages.contains { $0.content == "Working" } }
    mac.stream.liveStateChanged(conversationIDs: [conversation])
    await #expect(throws: StreamTestError.self) {
      _ = try await client.next(timeout: .milliseconds(400)) { if case .item(let item) = $0, case .session = item.payload { return true }; return false }
    }
    client.close()
  }

  // MARK: Revocation

  @Test func removingAMemberClosesItsStreamWith4401AndItsBotsRelay() async throws {
    // The server waits for each client's answering close frame, however long a busy machine delays the late one.
    var configuration = ExecutionStreamConfiguration()
    configuration.closeTimeout = .seconds(60)
    let mac = try await StreamMac(configuration: configuration); defer { mac.remove() }
    let phone = try await mac.member(.ios), other = try await mac.member(.mac)
    let client = try await mac.connect(phone)
    guard case .hello = try await client.next() else { Issue.record("no hello"); return }
    let staying = try await mac.connect(other)
    guard case .hello = try await staying.next() else { Issue.record("no hello"); return }
    // A client busy elsewhere, which writes before it reads the close.
    let late = try #require(try await mac.rawUpgrade(target: "/wovenmatter/v1/stream?protocol=1", signer: phone, keepOpen: true).connection)
    // Each socket is kept once it is set up, which its handshake does not wait for.
    #expect(try await pollUntil(attempts: 1_000, interval: .milliseconds(10)) { await mac.registry.openSockets()[phone.deviceID] == 2 })

    // The bots relay: raw bytes to the runtime, held for the member that opened it.
    let runtime = try await EchoListener.start()
    let relay = try await mac.rawUpgrade(target: "/wovenmatter/v1/bots/ws", signer: phone, keepOpen: true, botsRuntime: runtime.port)
    #expect(relay.status == 101)
    let echoed = try await relay.connection!.roundTrip(Data("ping".utf8))
    #expect(echoed == Data("ping".utf8))
    #expect(try await pollUntil(attempts: 1_000, interval: .milliseconds(10)) { await mac.registry.openSockets()[phone.deviceID] == 3 })

    try await mac.directory.remove(phone.deviceID)
    #expect(try await client.closed() == 4401)
    #expect(try await relay.connection!.waitForClose())
    // The late client writes after the server sent its close frame, then reads:
    // the server ends the connection only on the client's answer, so nothing it
    // wrote meets a closed socket whose reset could cost the client its 4401.
    try await late.sendText(Data(#"{"t":"req","id":"late","method":"execution.receipt","params":{"commandID":"late"}}"#.utf8))
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await late.readUntil(timeout: .seconds(10)) { $0.range(of: Data([0x88, 0x02, 0x11, 0x31])) != nil }, "the late client read 4401")
    // The server is still waiting for its answer, which ends the connection.
    try await late.sendClose(code: 4401)
    #expect(try await late.waitForClose(), "its answer ends the connection")
    #expect(await mac.registry.openSockets()[phone.deviceID] == nil)
    // Another member's socket stays open.
    staying.send(.request(try .init(id: "q", method: .executionReceipt, params: StreamReceiptParams(commandID: UUID().uuidString.lowercased()))))
    #expect(try await staying.response("q").error == nil)
    staying.close(); runtime.stop()
  }

  @Test func aSocketRegisteredAfterItsMembersRemovalIsClosed() async throws {
    let mac = try await StreamMac(); defer { mac.remove() }
    let phone = try await mac.member(.ios), other = try await mac.member(.mac)
    final class Closes: @unchecked Sendable {
      private let lock = NSLock(); private var ids: [String] = []
      func add(_ id: String) { lock.withLock { ids.append(id) } }
      var all: [String] { lock.withLock { ids } }
    }
    let closes = Closes()
    // Authenticated before the removal, registered after its sweep.
    try await mac.directory.remove(phone.deviceID)
    await mac.registry.register(deviceID: phone.deviceID, kinds: [.ios]) { closes.add("phone") }
    await mac.registry.register(deviceID: other.deviceID, kinds: [.mac]) { closes.add("other") }
    #expect(closes.all == ["phone"])
    #expect(await mac.registry.openSockets() == [other.deviceID: 1])
  }

  // MARK: Backpressure and liveness

  @Test func aSubscriptionThatFallsBehindEndsWithResync() async throws {
    var configuration = ExecutionStreamConfiguration()
    configuration.maximumQueuedBytes = 1_024 * 1_024
    let mac = try await StreamMac(configuration: configuration); defer { mac.remove() }
    let conversation = try await mac.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Large", ownerDeviceID: UUID())
    let run = try await mac.database.beginLocalACPRun(conversationID: conversation, input: .init(text: "Write a lot"))
    try await mac.database.replaceLocalACPAssistantMessage(runID: run.runID, content: String(repeating: "y", count: 4 * 1_024 * 1_024))
    let phone = try await mac.member(.ios)
    // A client that stops reading after the handshake.
    let raw = try await mac.rawUpgrade(target: "/wovenmatter/v1/stream?protocol=1", signer: phone, keepOpen: true)
    #expect(raw.status == 101)
    let connection = try #require(raw.connection)
    for index in 0..<10 {
      try await connection.sendText(try StreamProtocol.encode(.subscribe(.init(id: "s\(index)", stream: .conversation,
        params: .init(conversationID: conversation)))))
    }
    // Every subscription's snapshot is 4 MiB; the queue holds at most 1 MiB beyond what the sockets buffer.
    try await Task.sleep(for: .seconds(2))
    let received = try await connection.readUntil(timeout: .seconds(30)) { $0.range(of: Data(#""code":"resync""#.utf8)) != nil }
    #expect(received, "an overflowing subscription ended with resync")
    connection.cancel()
  }

  @Test func aSocketWithoutPongsIsClosedAndOneThatAnswersStaysOpen() async throws {
    var configuration = ExecutionStreamConfiguration()
    // A pong timeout well above what a busy machine delays an answered ping.
    configuration.pingInterval = .milliseconds(100); configuration.pongTimeout = .milliseconds(1_500)
    let mac = try await StreamMac(configuration: configuration); defer { mac.remove() }
    let phone = try await mac.member(.ios)
    let answering = try await mac.connect(phone)
    guard case .hello = try await answering.next() else { Issue.record("no hello"); return }
    // The raw client never answers pings (nor reads them).
    let silent = try await mac.rawUpgrade(target: "/wovenmatter/v1/stream?protocol=1", signer: phone, keepOpen: true)
    let connection = try #require(silent.connection)
    #expect(try await connection.waitForClose(timeout: .seconds(15)))
    // Pings were answered automatically throughout: past another timeout too.
    try await Task.sleep(for: .milliseconds(1_600))
    answering.send(.request(try .init(id: "q", method: .executionReceipt, params: StreamReceiptParams(commandID: UUID().uuidString.lowercased()))))
    #expect(try await answering.response("q").error == nil)
    answering.close()
  }

  // MARK: Frames

  @Test func everySharedFixtureRoundTripsThroughTheServersEncoder() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../shared/Tests/WovenMatterSharedTests/StreamProtocolFixtures.json").standardizedFileURL
    let fixtures = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let frames = try #require(fixtures["frames"] as? [[String: Any]])
    #expect(frames.count >= 20)
    for fixture in frames {
      let source = try JSONSerialization.data(withJSONObject: fixture["frame"]!)
      let frame = try StreamProtocol.decode(source)
      let encoded = try StreamProtocol.encode(frame)
      let left = try JSONSerialization.jsonObject(with: encoded) as! NSDictionary
      let right = try JSONSerialization.jsonObject(with: source) as! NSDictionary
      #expect(left == right, "\(fixture["name"] ?? "")")
      // Merging an item with itself, as a superseding update does, changes nothing.
      if case .item(let item) = frame, let merged = StreamSession.merge(item, item) {
        let mergedData = try StreamProtocol.encode(.item(merged))
        #expect(try JSONSerialization.jsonObject(with: mergedData) as! NSDictionary == right, "\(fixture["name"] ?? "") merge")
      }
    }
  }

  @Test func supersedingUpdatesMergeEntitiesByID() throws {
    let old = StreamItem(id: "c", payload: .transcript(.init(transcript: .init(conversationID: "v", messages: [
      .init(id: "m1", conversationID: "v", role: "assistant", content: "A"), .init(id: "m2", conversationID: "v", role: "assistant", content: "B"),
    ], activeRunID: "r1"), snapshot: false)))
    let new = StreamItem(id: "c", payload: .transcript(.init(transcript: .init(conversationID: "v", messages: [
      .init(id: "m2", conversationID: "v", role: "assistant", content: "B2"), .init(id: "m3", conversationID: "v", role: "assistant", content: "C"),
    ], activeRunID: nil, removedMessageIDs: ["m1"]), snapshot: false)))
    guard case .transcript(let merged) = try #require(StreamSession.merge(old, new)).payload else { Issue.record("not a transcript"); return }
    #expect(merged.transcript.messages.map(\.id) == ["m2", "m3"] && merged.transcript.messages.first?.content == "B2")
    #expect(merged.transcript.activeRunID == nil && merged.transcript.removedMessageIDs == ["m1"])

    let a = LibraryConversation(id: "a", title: "A"), b = LibraryConversation(id: "b", title: "B")
    let listed = StreamItem(id: "w", payload: .conversations(.init(conversations: [a], snapshot: false)))
    let removed = StreamItem(id: "w", payload: .conversations(.init(conversations: [b], deletedConversationIDs: ["a"], snapshot: false)))
    guard case .conversations(let list) = try #require(StreamSession.merge(listed, removed)).payload else { return }
    #expect(list.conversations.map(\.id) == ["b"] && list.deletedConversationIDs == ["a"])
    let library = try #require(StreamSession.merge(.init(id: "w", payload: .library(.init(cursor: 3))), .init(id: "w", payload: .library(.init(cursor: 5)))))
    #expect(library.payload == .library(.init(cursor: 5)), "a newer cursor replaces a queued one")
  }

  // MARK: Library change cursor

  /// `library` items carry the phone change feed's cursor: with the snapshot,
  /// then whenever a change a phone syncs commits, at most every 300 ms.
  @Test func theWorkspaceStreamCarriesTheLibraryCursorOnSubscribeAndAtMostEvery300ms() async throws {
    let mac = try await StreamMac(); defer { mac.remove() }
    let phone = try await mac.member(.ios)
    let client = try await mac.connect(phone)
    guard case .hello = try await client.next() else { Issue.record("no hello"); return }
    client.send(.subscribe(.init(id: "w", stream: .workspace)))
    func library(timeout: Duration = .seconds(10)) async throws -> Int64 {
      let frame = try await client.next(timeout: timeout) { if case .item(let item) = $0, item.id == "w", case .library = item.payload { return true }; return false }
      guard case .item(let item) = frame, case .library(let value) = item.payload else { throw StreamTestError.closed }
      return value.cursor
    }
    let initial = try await library()
    #expect(initial == (try await mac.database.libraryWakeCursor()))
    #expect(try await client.item("w").payload == .synchronized, "the cursor comes with the snapshot")

    // One change goes out; a burst right after it waits out the window and arrives as its last cursor.
    let written = ContinuousClock.now
    _ = try await mac.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "One", ownerDeviceID: UUID())
    let first = try await library()
    #expect(first > initial)
    for index in 0..<3 { _ = try await mac.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Burst \(index)", ownerDeviceID: UUID()) }
    let last = try await mac.database.libraryWakeCursor()
    var arrivals: [(cursor: Int64, at: ContinuousClock.Instant)] = [(first, .now)]
    while arrivals.last?.cursor != last { arrivals.append((try await library(), .now)) }
    #expect(arrivals.count <= 3, "three changes coalesce: \(arrivals.map(\.cursor))")
    for (earlier, later) in zip(arrivals, arrivals.dropFirst()) { #expect(later.cursor > earlier.cursor) }
    // The k-th item is sent no earlier than (k - 1) windows after the first change,
    // and arrives later still; gaps between arrivals say nothing when a busy
    // machine hands several to the client at once.
    let span = arrivals.last!.at - written
    #expect(span >= .milliseconds(250) * (arrivals.count - 1), "at most every 300 ms: \(arrivals.count) items over \(span)")
    await #expect(throws: StreamTestError.self) { _ = try await library(timeout: .milliseconds(700)) }

    // A transcript that changes, as a running session rewrites it, wakes no phone.
    let quiet = try await mac.database.libraryWakeCursor()
    try await mac.database.write { connection in
      try connection.withLock { try connection.executeUnlocked("INSERT INTO device_sync_changes(kind, resource_id, revision, deleted) VALUES ('transcript', 'x', 1, 0)") }
    }
    #expect(try await mac.database.libraryWakeCursor() == quiet)
    await #expect(throws: StreamTestError.self) { _ = try await library(timeout: .milliseconds(700)) }
    client.close()
  }

  /// The calendar, dictation, registry and artifact tables a phone syncs
  /// outside `GET v1/changes` move the cursor too; their entries are skipped
  /// by change pages. The announcer reads once per window and only reports moves.
  @Test func wakeTablesMoveTheCursorAndTheAnnouncerCoalesces() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let database = try await fixture.openDatabase()
    func run(_ sql: String) async throws {
      try await database.write { connection in try connection.withLock { try connection.executeUnlocked(sql) } }
    }
    let before = try await database.libraryWakeCursor()
    try await run("INSERT INTO execution_workspaces(id, owner_device_id, revision, deleted, payload) VALUES ('w1', 'o', 1, 0, x'00')")
    let registry = try await database.libraryWakeCursor()
    #expect(registry > before)
    try await run("INSERT INTO device_saved_artifacts(id, revision, manifest) VALUES ('a1', 1, x'00')")
    #expect(try await database.libraryWakeCursor() > registry)
    let page = try await database.read { try $0.libraryChanges(after: before) }
    #expect(page.cursor == (try await database.libraryWakeCursor()) && page.changes.isEmpty, "wake entries advance a page and carry nothing")

    final class Sleeps: @unchecked Sendable {
      let lock = NSLock(); var waits: [Duration] = []; var gates: [CheckedContinuation<Void, Never>] = []
      func sleep(_ value: Duration) async { await withCheckedContinuation { gate in lock.withLock { waits.append(value); gates.append(gate) } } }
      func release() { for gate in lock.withLock({ defer { gates = [] }; return gates }) { gate.resume() } }
      var count: Int { lock.withLock { waits.count } }
    }
    final class Seen: @unchecked Sendable { let lock = NSLock(); var values: [Int64] = []; var all: [Int64] { lock.withLock { values } } }
    let sleeps = Sleeps(), seen = Seen()
    let announcer = LibraryChangeAnnouncer(database: database, sleep: { await sleeps.sleep($0) }) { cursor in seen.lock.withLock { seen.values.append(cursor) } }
    await announcer.start()
    let start = try await database.libraryWakeCursor()
    #expect(seen.all == [start], "announced once on start")
    // Three commits inside the window: one sleep, then one read of the latest cursor.
    for id in ["w2", "w3", "w4"] { try await run("INSERT INTO execution_workspaces(id, owner_device_id, revision, deleted, payload) VALUES ('\(id)', 'o', 1, 0, x'00')") }
    for _ in 0..<200 where sleeps.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(sleeps.count == 1)
    #expect(sleeps.waits.first.map { $0 > .zero && $0 <= StreamProtocol.libraryInterval } == true)
    #expect(seen.all == [start], "nothing before the window ends")
    sleeps.release()
    let latest = try await database.libraryWakeCursor()
    for _ in 0..<200 where seen.all.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(seen.all == [start, latest])
    // A commit that only rewrites a transcript reads once and reports nothing.
    try await run("INSERT INTO device_sync_changes(kind, resource_id, revision, deleted) VALUES ('transcript', 'x', 1, 0)")
    for _ in 0..<200 where sleeps.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    sleeps.release()
    try await Task.sleep(for: .milliseconds(50))
    #expect(seen.all == [start, latest])
    await announcer.stop()
  }

  // MARK: Attachments

  /// `GET v1/execution/attachments/<sha256>`: a message file of a session this
  /// Mac runs, with its type, signed like every execution read; nothing
  /// outside the attachment store, and nothing that no longer matches.
  @Test func attachmentsOfLocalSessionsAreServedFromTheAttachmentStoreOnly() async throws {
    let mac = try await StreamMac(); defer { mac.remove() }
    let bytes = Data("fixture image bytes".utf8)
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let blobs = mac.database.supportDirectory.appending(path: "message-attachments/blobs")
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    try bytes.write(to: blobs.appending(path: hash))
    let conversation = try await mac.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Photo", ownerDeviceID: UUID())
    _ = try await mac.database.beginLocalACPRun(conversationID: conversation, input: .init(text: "What is this?", attachments: [
      .file(.init(kind: .image, fileName: "photo.png", mimeType: "image/png", sizeBytes: Int64(bytes.count), contentHash: hash, localURL: blobs.appending(path: hash))),
    ]))
    let phone = try await mac.member(.ios)
    func get(_ path: String, signer: MemberIdentity?) async throws -> (Int, String?, Data) {
      let target = "/wovenmatter/" + path
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(mac.port)" + target)!)
      request.setValue(String(LibraryProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
      if let signer { for (key, value) in try signer.signer.headers(method: "GET", target: target, audience: mac.hostID) { request.setValue(value, forHTTPHeaderField: key) } }
      let (data, response) = try await URLSession.shared.data(for: request)
      let http = try #require(response as? HTTPURLResponse)
      return (http.statusCode, http.value(forHTTPHeaderField: "Content-Type"), data)
    }
    let read = try await get("v1/execution/attachments/\(hash)?name=photo.png", signer: phone)
    #expect(read.0 == 200 && read.1 == "image/png" && read.2 == bytes)
    #expect(try await get("v1/execution/attachments/\(hash)?name=photo.png", signer: nil).0 == 401, "unsigned")
    let stranger = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .ios, key: .init())
    #expect(try await get("v1/execution/attachments/\(hash)", signer: stranger).0 == 401, "not a member")
    // Only a digest names a file; nothing else in the support directory is reachable.
    #expect(try await get("v1/execution/attachments/..%2F..%2Fworkspace.sqlite", signer: phone).0 != 200)
    #expect(try await get("v1/execution/attachments/" + String(repeating: "a", count: 64), signer: phone).0 == 404, "no message carries it")
    // A blob replaced by a link out of the store, or edited, is refused.
    let outside = mac.database.supportDirectory.appending(path: "outside.txt")
    try bytes.write(to: outside)
    try FileManager.default.removeItem(at: blobs.appending(path: hash))
    try FileManager.default.createSymbolicLink(at: blobs.appending(path: hash), withDestinationURL: outside)
    #expect(try await get("v1/execution/attachments/\(hash)", signer: phone).0 == 404)
    try FileManager.default.removeItem(at: blobs.appending(path: hash))
    try Data("edited".utf8).write(to: blobs.appending(path: hash))
    #expect(try await get("v1/execution/attachments/\(hash)", signer: phone).0 == 409)
    try FileManager.default.removeItem(at: blobs.appending(path: hash))

    // A file read from the machine that runs its session is kept only when it matches its digest.
    let files = mac.database.libraryFiles
    #expect(throws: (any Error).self) { try files.retainMessageAttachment(Data("damaged".utf8), contentHash: hash) }
    #expect(!files.hasMessageAttachment(contentHash: hash))
    try files.retainMessageAttachment(bytes, contentHash: hash)
    #expect(files.hasMessageAttachment(contentHash: hash))
    #expect(try files.messageAttachment(contentHash: hash) == bytes)
    #expect(throws: (any Error).self) { try files.retainMessageAttachment(bytes, contentHash: "../workspace.sqlite") }
  }
}

// MARK: - Fixture

/// One Mac: its library database, member directory, execution API and the
/// real library server with the stream behind it, all on loopback.
private final class StreamMac: @unchecked Sendable {
  let fixture: PersistenceFixture
  let database: WorkspaceDatabase
  let directory: MemberDirectory
  let registry: MemberSocketRegistry
  let hostID: String
  let descriptor: ExecutionWorkspace
  let commands: StreamCommands
  let api: MacExecutionAPI
  let stream: ExecutionStreamServer
  let server: LibraryHTTPServer
  let port: UInt16
  private let botsPort = BotsPort()

  init(configuration: ExecutionStreamConfiguration = .init()) async throws {
    fixture = try PersistenceFixture()
    database = try await fixture.openDatabase()
    let identity = try await database.libraryIdentity()
    hostID = identity.hostDeviceID
    directory = MemberDirectory(database: database, identity: MemberIdentity(deviceID: hostID, kind: .mac, key: .init()), cacheLifetime: 0)
    try await directory.ensureSelf(name: "This Mac", endpoints: [])
    registry = MemberSocketRegistry(members: directory)
    descriptor = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: hostID, kind: .mac,
      name: "This Mac", endpoint: URL(string: "https://mac.fixture.ts.net:8443/wovenmatter")!,
      capabilities: ["execution.v1", "history.central.v1", StreamProtocol.capability], executionDeviceID: hostID)
    let database = database, descriptor = descriptor, directory = directory
    let authentication = try ExecutionAuthentication(fileURL: fixture.directory.appending(path: "execution-grants.json"))
    let pair = await MainActor.run {
      let commands = StreamCommands(database: database)
      return (commands, MacExecutionAPI(database: database, commands: commands, authentication: authentication,
                                        descriptor: descriptor, isActive: { true }, members: directory))
    }
    commands = pair.0; api = pair.1
    stream = ExecutionStreamServer(database: database, source: api, members: directory, registry: registry, configuration: configuration)
    try await stream.start()
    let stream = stream, api = api, registry = registry, botsPort = botsPort
    server = LibraryHTTPServer(upgradeHandler: { request in
      let path = request.target.split(separator: "?").first.map(String.init) ?? ""
      if path.hasSuffix("/v1/stream") { return await stream.upgrade(request) }
      // As LibraryHostController relays `/v1/bots/ws` for a signed member.
      guard path.hasSuffix("/v1/bots/ws"), let port = botsPort.value,
            let member = try? await directory.authenticate(request, allowing: [.mac, .ios]) else {
        return .reject(.error("unauthorized", "No.", status: 401))
      }
      return .tunnel(port: port, head: Data("relay\n".utf8),
                     options: .init(owner: .init(registry: registry, deviceID: member.deviceID, kinds: [.mac, .ios])))
    }) { request in await api.handle(request) }
    port = try await server.start()
  }

  func remove() { server.stop(); stream.stop(); fixture.remove() }

  func member(_ kind: MemberKind) async throws -> MemberIdentity {
    let identity = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: kind, key: .init())
    try await directory.add(deviceID: identity.deviceID, kind: kind, name: "\(kind)", publicKey: identity.publicKey, endpoints: [])
    return identity
  }

  func connect(_ member: MemberIdentity) async throws -> StreamClient {
    let target = "/wovenmatter/v1/stream?protocol=1"
    let headers = try member.signer.headers(method: "GET", target: target, audience: hostID)
    let client = StreamClient(port: port, target: target, headers: headers)
    try await client.connect()
    return client
  }

  struct RawResponse { let status: Int; let headers: [String: String]; let json: [String: Any]?; let connection: RawConnection? }

  func rawUpgrade(target: String, signer: MemberIdentity?, time: Int64 = MemberRequestSignature.now(),
                  extra: [String: String] = [:], keepOpen: Bool = false, botsRuntime: UInt16? = nil) async throws -> RawResponse {
    botsPort.value = botsRuntime
    var headers = ["Host": "127.0.0.1", "Upgrade": "websocket", "Connection": "Upgrade",
                   "Sec-WebSocket-Key": Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString(),
                   "Sec-WebSocket-Version": "13"]
    if let signer { headers.merge(try signer.signer.headers(method: "GET", target: target, audience: hostID, time: time)) { $1 } }
    headers.merge(extra) { $1 }
    let connection = try await RawConnection.open(port: port)
    let head = "GET \(target) HTTP/1.1\r\n" + headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
    try await connection.send(Data(head.utf8))
    let response = try await connection.readHead()
    let status = Int(response.head.split(separator: " ").dropFirst().first ?? "") ?? 0
    var responseHeaders: [String: String] = [:]
    for line in response.head.components(separatedBy: "\r\n").dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      responseHeaders[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let json: [String: Any]?
    if status != 101 {
      var body = response.rest
      while (try? JSONSerialization.jsonObject(with: body)) == nil {
        let (data, complete) = try await connection.receiveChunk()
        body.append(data)
        if complete { break }
      }
      json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    } else { json = nil }
    if !keepOpen || status != 101 { connection.cancel() }
    return .init(status: status, headers: responseHeaders, json: json, connection: keepOpen && status == 101 ? connection : nil)
  }
}

private final class BotsPort: @unchecked Sendable {
  private let lock = NSLock(); private var port: UInt16?
  var value: UInt16? { get { lock.withLock { port } } set { lock.withLock { port = newValue } } }
}

/// Commands and transcripts as the desktop's command service provides them,
/// read from the same rows (only the newest window, like `GET …/transcript`).
@MainActor private final class StreamCommands: DeviceCommandServing {
  let database: WorkspaceDatabase
  private(set) var executed: [LibraryCommand] = []
  private var receipts: [String: LibraryCommandReceipt] = [:]
  private var pending: [PendingInteraction] = []
  private var model = "gpt-5.5"
  init(database: WorkspaceDatabase) { self.database = database }
  func setPending(_ value: [PendingInteraction]) { pending = value }
  func setModel(_ value: String) { model = value }
  /// As the desktop reads them: the model from memory, the goal from its table.
  func readWorkspace(_ request: LibraryWorkspaceRead) async throws -> LibraryWorkspaceResult {
    guard case .session(let id) = request else { throw LibraryAPIError(code: "unsupported", message: "Not in this fixture.") }
    let goal = try await database.sessionGoals().first { $0.sessionID == id }
    return .session(.init(conversationID: id, model: model, thinking: "high", permission: nil, models: [.init(id: model, label: model)],
                          thinkingLevels: [.init(id: "high", label: "High")], permissions: [], availableTools: [], enabledTools: [],
                          canConfigure: true, goal: goal))
  }
  func providers() -> [HarnessCapabilities] { [.init(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: true)] }
  func pendingInteractions() async -> [PendingInteraction] { pending }
  func sessionCapabilities(conversationID: String) async throws -> HarnessCapabilities { providers()[0] }
  func transcript(conversationID: String, before: String?) async throws -> LibraryTranscript {
    let (messages, active) = try await database.read { connection in
      (try connection.historyRowsUnlocked("SELECT id,run_id,role,content,status,created_at FROM dashboard_messages WHERE conversation_id=? ORDER BY created_at,id", values: [conversationID]),
       try connection.historyRowsUnlocked("SELECT id FROM dashboard_runs WHERE conversation_id=? AND status IN ('queued','running') ORDER BY created_at DESC LIMIT 1", values: [conversationID]))
    }
    return LibraryTranscript(conversationID: conversationID, messages: messages.suffix(80).compactMap { row in
      guard let value = row.objectValue, let id = value["id"]?.stringValue else { return nil }
      return LibraryMessage(id: id, conversationID: conversationID, runID: value["run_id"]?.stringValue, role: value["role"]?.stringValue ?? "",
                            content: value["content"]?.stringValue ?? "", status: value["status"]?.stringValue, createdAt: value["created_at"]?.stringValue ?? "")
    }, activeRunID: active.first?.objectValue?["id"]?.stringValue)
  }
  func receipt(commandID: String, deviceID: String) async throws -> LibraryCommandReceipt? { receipts[deviceID + ":" + commandID] }
  func execute(_ command: LibraryCommand, deviceID: String) async throws -> LibraryCommandReceipt {
    if let receipt = receipts[deviceID + ":" + command.commandID] { return receipt }
    executed.append(command)
    let receipt = LibraryCommandReceipt(commandID: command.commandID, deviceID: deviceID, status: .accepted, conversationID: command.conversationID)
    receipts[deviceID + ":" + command.commandID] = receipt
    return receipt
  }
}

// MARK: - Clients

/// A WebSocket client built on the Network framework, as a Mac or phone client would be.
private final class StreamClient: @unchecked Sendable {
  private let connection: NWConnection
  private let lock = NSLock()
  private var frames: [StreamFrame] = []
  private var closeCode: Int?
  private var failed = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(port: UInt16, target: String, headers: [String: String]) {
    let options = NWProtocolWebSocket.Options()
    options.autoReplyPing = true
    options.maximumMessageSize = StreamProtocol.maximumFrameBytes
    options.setAdditionalHeaders(headers.map { ($0.key, $0.value) })
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
    connection = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)\(target)")!), using: parameters)
  }

  /// Opens the socket; a handshake that has not completed after `timeout` fails the test instead of hanging it.
  func connect(timeout: Duration = .seconds(30)) async throws {
    let queue = DispatchQueue(label: "stream.test.client")
    let connection = connection
    let deadline = Task { guard (try? await Task.sleep(for: timeout)) != nil else { return }; connection.cancel() }
    defer { deadline.cancel() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      final class Once: @unchecked Sendable { var done = false }
      let once = Once()
      connection.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready: if !once.done { once.done = true; continuation.resume() }
        case .failed(let error), .waiting(let error):
          if !once.done { once.done = true; continuation.resume(throwing: error) }
          self?.finish(code: nil)
        case .cancelled:
          if !once.done { once.done = true; continuation.resume(throwing: StreamTestError.closed) }
          self?.finish(code: nil)
        default: break
        }
      }
      connection.start(queue: queue)
    }
    receive()
  }

  private func receive() {
    connection.receiveMessage { [weak self] data, context, _, error in
      guard let self else { return }
      let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
      if let metadata, metadata.opcode == .close {
        let code: Int? = switch metadata.closeCode {
        case .protocolCode(let value): Int(value.rawValue)
        case .privateCode(let value), .applicationCode(let value): Int(value)
        @unknown default: nil
        }
        // Answered with the same code, as browsers, URLSession and ws do; the server then ends the connection.
        let reply = NWProtocolWebSocket.Metadata(opcode: .close)
        reply.closeCode = metadata.closeCode
        connection.send(content: nil, contentContext: .init(identifier: "close", metadata: [reply]), isComplete: true, completion: .idempotent)
        finish(code: code); return
      }
      if let data, !data.isEmpty, let frame = try? StreamProtocol.decode(data) {
        lock.withLock { frames.append(frame) }; wake()
      }
      if error != nil { finish(code: nil); return }
      receive()
    }
  }

  private func finish(code: Int?) {
    lock.withLock { if closeCode == nil { closeCode = code }; failed = true }
    wake()
  }

  private func wake() {
    let pending = lock.withLock { let value = waiters; waiters.removeAll(); return value }
    for waiter in pending { waiter.resume() }
  }

  private func waitForChange() async {
    await withCheckedContinuation { continuation in lock.withLock { waiters.append(continuation) } }
  }

  /// The next frame matching `predicate`, consuming every frame before it.
  /// A socket that ends or a timeout is recorded where the test waited.
  func next(timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation,
            where predicate: @escaping (StreamFrame) -> Bool = { _ in true }) async throws -> StreamFrame {
    let deadline = ContinuousClock.now + timeout
    while true {
      let found: StreamFrame? = lock.withLock {
        guard let index = frames.firstIndex(where: predicate) else { frames.removeAll(); return nil }
        let frame = frames[index]; frames.removeFirst(index + 1); return frame
      }
      if let found { return found }
      if let code = lock.withLock({ failed ? .some(closeCode) : nil }) {
        Issue.record("The socket closed (\(code.map(String.init) ?? "no close code")) before the frame arrived", sourceLocation: sourceLocation)
        throw StreamTestError.closed
      }
      guard ContinuousClock.now < deadline else { throw StreamTestError.timeout }
      let timer = Task { [weak self] in try? await Task.sleep(for: .milliseconds(50)); self?.wake() }
      await waitForChange()
      timer.cancel()
    }
  }

  func item(_ id: String, sourceLocation: SourceLocation = #_sourceLocation,
            where predicate: @escaping (StreamItem) -> Bool = { _ in true }) async throws -> StreamItem {
    guard case .item(let item) = try await next(sourceLocation: sourceLocation, where: { if case .item(let item) = $0 { return item.id == id && predicate(item) }; return false }) else {
      throw StreamTestError.timeout
    }
    return item
  }

  func transcript(_ id: String, sourceLocation: SourceLocation = #_sourceLocation,
                  where predicate: @escaping (LibraryTranscript) -> Bool) async throws -> StreamTranscript {
    let item = try await item(id, sourceLocation: sourceLocation) { if case .transcript(let value) = $0.payload { return predicate(value.transcript) }; return false }
    guard case .transcript(let value) = item.payload else { throw StreamTestError.timeout }
    return value
  }

  func session(_ id: String, sourceLocation: SourceLocation = #_sourceLocation,
               where predicate: @escaping (SessionSettings) -> Bool = { _ in true }) async throws -> SessionSettings {
    let item = try await item(id, sourceLocation: sourceLocation) { if case .session(let value) = $0.payload { return predicate(value.settings) }; return false }
    guard case .session(let value) = item.payload else { throw StreamTestError.timeout }
    return value.settings
  }

  func response(_ id: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> StreamResponse {
    guard case .response(let response) = try await next(sourceLocation: sourceLocation, where: { if case .response(let value) = $0 { return value.id == id }; return false }) else {
      throw StreamTestError.timeout
    }
    return response
  }

  func send(_ frame: StreamFrame) { sendRaw(String(decoding: try! StreamProtocol.encode(frame), as: UTF8.self)) }

  func sendRaw(_ text: String) {
    let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
    connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
  }

  /// Waits for the server to close the socket and returns its close code.
  func closed(timeout: Duration = .seconds(10)) async throws -> Int? {
    let deadline = ContinuousClock.now + timeout
    while !lock.withLock({ failed }) {
      guard ContinuousClock.now < deadline else { throw StreamTestError.timeout }
      let timer = Task { [weak self] in try? await Task.sleep(for: .milliseconds(50)); self?.wake() }
      await waitForChange()
      timer.cancel()
    }
    return lock.withLock { closeCode }
  }

  func close() { connection.cancel() }
}

private enum StreamTestError: Error { case timeout, closed }

/// A plain TCP connection, for handshakes the WebSocket client cannot make
/// (refusals, a client that stops reading or never answers pings) and the bots relay.
private final class RawConnection: @unchecked Sendable {
  let connection: NWConnection
  private let queue = DispatchQueue(label: "stream.test.raw")
  init(_ connection: NWConnection) { self.connection = connection }

  static func open(port: UInt16) async throws -> RawConnection {
    let raw = RawConnection(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp))
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      final class Once: @unchecked Sendable { var done = false }
      let once = Once()
      raw.connection.stateUpdateHandler = { state in
        switch state {
        case .ready: if !once.done { once.done = true; continuation.resume() }
        case .failed(let error): if !once.done { once.done = true; continuation.resume(throwing: error) }
        default: break
        }
      }
      raw.connection.start(queue: raw.queue)
    }
    return raw
  }

  func send(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(content: data, completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      })
    }
  }

  /// One masked client text frame.
  func sendText(_ payload: Data) async throws {
    var frame = Data([0x81])
    if payload.count < 126 { frame.append(0x80 | UInt8(payload.count)) }
    else if payload.count <= 0xffff { frame.append(0x80 | 126); frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 0xff)) }
    else { frame.append(0x80 | 127); for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((payload.count >> shift) & 0xff)) } }
    let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
    frame.append(contentsOf: mask)
    frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
    try await send(frame)
  }

  /// A masked client close frame.
  func sendClose(code: UInt16) async throws {
    let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
    let payload = [UInt8(code >> 8), UInt8(code & 0xff)]
    try await send(Data([0x88, 0x82] + mask + payload.enumerated().map { $0.element ^ mask[$0.offset] }))
  }

  func receiveChunk() async throws -> (Data, Bool) {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
        if let error, data == nil { continuation.resume(throwing: error) } else { continuation.resume(returning: (data ?? Data(), complete)) }
      }
    }
  }

  func readHead() async throws -> (head: String, rest: Data) {
    var buffer = Data()
    while true {
      let (data, complete) = try await receiveChunk()
      buffer.append(data)
      if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
        return (String(decoding: buffer[..<end.lowerBound], as: UTF8.self), Data(buffer[end.upperBound...]))
      }
      if complete { return (String(decoding: buffer, as: UTF8.self), Data()) }
    }
  }

  /// Reads until `done` accepts everything read so far, the peer closes, or `timeout`.
  func readUntil(timeout: Duration, _ done: @escaping @Sendable (Data) -> Bool) async throws -> Bool {
    let reader = Task { () -> Bool in
      var buffer = Data()
      while !Task.isCancelled {
        guard let (data, complete) = try? await receiveChunk() else { return false }
        buffer.append(data)
        if done(buffer) { return true }
        if complete { return false }
        // Only the end of the stream matters here.
        if buffer.count > 1 << 20 { buffer = buffer.suffix(1 << 16) }
      }
      return false
    }
    // Only a timeout that elapses ends the read: cancelling the timer leaves the connection open.
    let timer = Task { guard (try? await Task.sleep(for: timeout)) != nil else { return }; reader.cancel(); connection.cancel() }
    let result = await reader.value
    timer.cancel()
    return result
  }

  func roundTrip(_ data: Data) async throws -> Data {
    try await send(data)
    let (received, _) = try await receiveChunk()
    return received
  }

  /// True once the peer closed the connection (it may send data first), false after `timeout`.
  func waitForClose(timeout: Duration = .seconds(10)) async throws -> Bool {
    final class Flag: @unchecked Sendable { var value = false }
    let timedOut = Flag()
    let reader = Task { () -> Bool in
      while true {
        guard let (_, complete) = try? await receiveChunk() else { return true }
        if complete { return true }
      }
    }
    let timer = Task { guard (try? await Task.sleep(for: timeout)) != nil else { return }; timedOut.value = true; connection.cancel() }
    let closed = await reader.value
    timer.cancel()
    return closed && !timedOut.value
  }

  func cancel() { connection.cancel() }
}

/// The bots runtime as a relay target: it echoes whatever reaches it after the head.
private final class EchoListener: @unchecked Sendable {
  let listener: NWListener
  let port: UInt16
  private let queue = DispatchQueue(label: "stream.test.echo")
  private init(listener: NWListener, port: UInt16) { self.listener = listener; self.port = port }

  static func start() async throws -> EchoListener {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 0)
    let listener = try NWListener(using: parameters)
    let queue = DispatchQueue(label: "stream.test.echo.listener")
    listener.newConnectionHandler = { connection in
      connection.start(queue: queue)
      @Sendable func echo(skippingHead: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
          var data = data ?? Data(), skipping = skippingHead
          if skipping, let end = data.firstIndex(of: 10) {
            data = Data(data[(end + 1)...]); skipping = false
            connection.send(content: Data("HTTP/1.1 101 Switching Protocols\r\n\r\n".utf8), completion: .idempotent)
          }
          if !skipping, !data.isEmpty { connection.send(content: data, completion: .idempotent) }
          if complete || error != nil { connection.cancel(); return }
          echo(skippingHead: skipping)
        }
      }
      echo(skippingHead: true)
    }
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      final class Once: @unchecked Sendable { var done = false }
      let once = Once()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready: if !once.done { once.done = true; continuation.resume(returning: listener.port!.rawValue) }
        case .failed(let error): if !once.done { once.done = true; continuation.resume(throwing: error) }
        default: break
        }
      }
      listener.start(queue: queue)
    }
    return EchoListener(listener: listener, port: port)
  }

  func stop() { listener.cancel() }
}
#endif
