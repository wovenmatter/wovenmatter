import CryptoKit
import XCTest
import WovenMatterShared
@testable import LibraryClient

/// The phone's stream to one listed workspace.
final class MobileWorkspaceStreamTests: XCTestCase {
  private let workspace = ExecutionWorkspace(id: "linux", libraryID: "library", ownerDeviceID: "mac", kind: .linux, name: "Server",
                                             capabilities: [StreamProtocol.capability])

  private final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MobileWorkspaceStream.Update] = []
    var all: [MobileWorkspaceStream.Update] { lock.withLock { values } }
    func append(_ value: MobileWorkspaceStream.Update) { lock.withLock { values.append(value) } }
  }

  private func make() async throws -> (MobileStore, FakeStreamServer, MobileWorkspaceStream, Updates) {
    let store = try MobileStore(file: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json"))
    try await store.journal.upsertWorkspace(workspace, pending: false)
    let server = FakeStreamServer(), updates = Updates()
    let stream = MobileWorkspaceStream(workspace: workspace, store: store, connection: server.connection()) { updates.append($0) }
    return (store, server, stream, updates)
  }

  private func open(_ server: FakeStreamServer, _ stream: MobileWorkspaceStream, socket index: Int = 0) async -> FakeStreamSocket {
    await eventually("socket \(index)") { server.sockets.count > index }
    let socket = server.sockets[index]
    await socket.push(.hello(.init(deviceID: "mac", libraryID: "library", workspaceID: "linux", serverTime: 0)))
    await eventually("open") { await stream.connection.isOpen }
    return socket
  }

  func testJournalPendingAndTheOpenChatReachTheStore() async throws {
    let (store, server, stream, updates) = try await make()
    await stream.start()
    let socket = await open(server, stream)
    await eventually("workspace subscription") { await socket.subscriptions.count == 1 }
    let workspaceSub = await socket.subscriptions[0]
    XCTAssertEqual(workspaceSub.params.after, 0)

    await socket.push(journalItem(workspaceSub.id, 1))
    let interaction = PendingInteraction(id: "q1", conversationID: "chat", runID: "run", kind: .approval, title: "Run npm test?")
    await socket.push(.item(.init(id: workspaceSub.id, payload: .pending(.init(interactions: [interaction])))))
    await eventually("pending") { updates.all.contains(.pending([interaction])) }
    let cursor = await store.journal.snapshot().directCursors["linux"]
    XCTAssertEqual(cursor, 1)
    let title = await store.snapshot().conversations["chat"]?.title
    XCTAssertEqual(title, "Version 1")
    XCTAssertTrue(updates.all.contains(.history))

    await stream.open(conversationID: "chat")
    await eventually("conversation subscription") { await socket.subscriptions.count == 2 }
    let chat = await socket.subscriptions[1]
    XCTAssertEqual(chat.params.conversationID, "chat")
    await socket.push(.item(.init(id: chat.id, payload: .transcript(.init(transcript: .init(conversationID: "chat", messages: [
      .init(id: "m1", conversationID: "chat", role: "user", content: "Run the tests"),
      .init(id: "m2", conversationID: "chat", role: "assistant", content: "Running", status: "streaming"),
    ], activeRunID: "run", olderCursor: "c-20"), snapshot: true)))))
    await socket.push(.item(.init(id: chat.id, payload: .transcript(.init(transcript: .init(conversationID: "chat", messages: [
      .init(id: "m2", conversationID: "chat", role: "assistant", content: "Done."),
    ], activeRunID: nil), snapshot: false)))))
    await eventually("merged transcript") { await store.snapshot().transcripts["chat"]?.messages.last?.content == "Done." }
    let transcript = await store.snapshot().transcripts["chat"]
    XCTAssertEqual(transcript?.messages.map(\.id), ["m1", "m2"])
    XCTAssertNil(transcript?.activeRunID)
    XCTAssertEqual(transcript?.olderCursor, "c-20")

    // Another chat opens: the first one's subscription ends.
    await stream.open(conversationID: "other")
    await eventually("cancel") { await socket.cancels == [chat.id] }

    // Background: closed cleanly. Foreground: the journal resumes after its cursor.
    await stream.stop()
    let closed = await socket.closedWith
    XCTAssertEqual(closed, .normal)
    await stream.start()
    let resumed = await open(server, stream, socket: 1)
    await eventually("resubscribed") { await resumed.subscriptions.count == 2 }
    let again = await resumed.subscriptions
    XCTAssertEqual(again.first { $0.stream == "workspace" }?.params.after, 1)
    XCTAssertEqual(again.first { $0.stream == "conversation" }?.params.conversationID, "other")
  }

  func testCommandsGoOverTheStreamAndALostReplyIsResolvedOnReconnect() async throws {
    let (store, server, stream, updates) = try await make()
    final class NoHTTP: ExecutionWorkspaceTransport, @unchecked Sendable {
      func identity() throws -> ExecutionWorkspace { throw MobileConnectionError.offline }
      func providers() -> [HarnessCapabilities] { [] }
      func pending() -> [PendingInteraction] { [] }
      func command(_ command: LibraryCommand) throws -> LibraryCommandReceipt { throw MobileConnectionError.offline }
      func receipt(_ id: String) throws -> LibraryCommandReceipt? { throw MobileConnectionError.offline }
      func events(after: Int64) throws -> ExecutionJournalPage { throw MobileConnectionError.offline }
      func conversations() -> [LibraryConversation] { [] }
      func transcript(_ id: String) throws -> LibraryTranscript { throw MobileConnectionError.offline }
    }
    let client = WorkspaceClient(store: store, workspaceID: "linux", transport: NoHTTP())
    await client.setStream(stream.connection)
    await stream.start()
    let first = await open(server, stream)
    let command = LibraryCommand(deviceID: "phone", kind: .send, conversationID: "chat", text: "Run the tests")
    let submit = Task { try await client.submit(command) }
    await eventually("command") { await first.requests.count == 1 }
    let sent = try await first.requests[0].decodeParams(StreamCommandParams.self).command
    // The same identity `POST v1/execution/commands` carries in its body,
    // which a Mac checks against the socket's scope: this workspace and its library.
    XCTAssertEqual(sent.workspaceID, "linux")
    XCTAssertEqual(sent.libraryID, "library")
    XCTAssertEqual(sent.deviceID, "phone")
    await first.serverClose(code: 1006)
    do { _ = try await submit.value; XCTFail("Expected a lost reply") }
    catch { XCTAssertEqual(error as? StreamConnectionError, .disconnected) }
    let unknown = await store.journal.commandRecords(workspaceID: "linux").first?.receipt?.status
    XCTAssertEqual(unknown, .outcomeUnknown)

    let second = await open(server, stream, socket: 1)
    await eventually("receipt request") { await second.requests.count == 1 }
    let ask = await second.requests[0]
    XCTAssertEqual(ask.method, "execution.receipt")
    let accepted = LibraryCommandReceipt(commandID: command.commandID, deviceID: "phone", status: .accepted, conversationID: "chat")
    await second.push(.response(try .init(id: ask.id, encoding: accepted)))
    await eventually("receipts") { updates.all.contains(.receipts([accepted])) }
    let resolved = await store.journal.commandRecords(workspaceID: "linux").first?.receipt
    XCTAssertEqual(resolved, accepted)

    // A retry of the same command asks for its receipt and is not sent again.
    let retry = Task { try await client.submit(command) }
    await eventually("retry receipt request") { await second.requests.count == 2 }
    let retryAsk = await second.requests[1]
    XCTAssertEqual(retryAsk.method, "execution.receipt")
    await second.push(.response(try .init(id: retryAsk.id, encoding: accepted)))
    let receipt = try await retry.value
    XCTAssertEqual(receipt, accepted)
    let methods = await second.requests.map(\.method)
    XCTAssertEqual(methods, ["execution.receipt", "execution.receipt"])
  }

  /// The library host's stream carries the central route: its own sessions,
  /// which its library holds unassigned. A pushed summary keeps that identity
  /// (so the chat never moves to another route), a deleted chat stays deleted,
  /// and an open central chat is followed live like any other.
  func testTheLibraryHostsStreamCarriesCentralChatsWithTheLibrarysIdentity() async throws {
    let store = try MobileStore(file: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json"))
    let host = ExecutionWorkspace(id: "studio", libraryID: "library", ownerDeviceID: "mac", kind: .mac, name: "Studio",
                                  capabilities: ["history.central.v1", StreamProtocol.capability])
    try await store.journal.upsertWorkspace(host, pending: false)
    try await store.apply(LibrarySnapshot(workspaceID: "library", cursor: 1, folders: [], notes: [], conversations: [
      .init(id: "central-chat", title: "Plan", providerID: "local:codex", runtimeKind: "codex"),
      .init(id: "trashed", title: "Trashed later", providerID: "local:codex", runtimeKind: "codex"),
    ]))
    try await store.apply(LibraryChangePage(workspaceID: "library", cursor: 2, changes: [
      .init(cursor: 2, resourceKind: .conversation, resourceID: "trashed", operation: .delete, revision: 1),
    ]))
    let server = FakeStreamServer(), updates = Updates()
    let stream = MobileWorkspaceStream(workspace: host, store: store, connection: server.connection()) { updates.append($0) }
    await stream.setLibraryHost(true)
    await stream.start()
    await eventually("socket") { server.sockets.count == 1 }
    let socket = server.sockets[0]
    await socket.push(.hello(.init(deviceID: "mac", libraryID: "library", workspaceID: "studio", serverTime: 0)))
    await eventually("open") { await stream.connection.isOpen }
    await eventually("workspace subscription") { await socket.subscriptions.count == 1 }
    let workspaceSub = await socket.subscriptions[0]
    XCTAssertEqual(workspaceSub.stream, "workspace")

    // The host's execution API names its sessions as its workspace's.
    let pushed = LibraryConversation(id: "central-chat", title: "Plan, running", providerID: "local:codex", runtimeKind: "codex",
                                     activeRunID: "run", libraryID: "library", workspaceID: "studio")
    let brandNew = LibraryConversation(id: "new-central-chat", title: "Started on the Mac", providerID: "local:codex", runtimeKind: "codex",
                                       libraryID: "library", workspaceID: "studio")
    let trashed = LibraryConversation(id: "trashed", title: "Deleted in the library", providerID: "local:codex", workspaceID: "studio")
    await socket.push(.item(.init(id: workspaceSub.id, payload: .conversations(.init(conversations: [pushed, brandNew, trashed], snapshot: true)))))
    await eventually("summary") { await store.snapshot().conversations["central-chat"]?.title == "Plan, running" }
    let conversations = await store.snapshot().conversations
    XCTAssertNil(conversations["central-chat"]?.workspaceID, "Still the central route")
    XCTAssertNil(conversations["central-chat"]?.libraryID)
    XCTAssertEqual(conversations["central-chat"]?.activeRunID, "run")
    XCTAssertNil(conversations["new-central-chat"]?.workspaceID)
    XCTAssertNil(conversations["trashed"], "A chat the library deleted is not brought back")

    // The open central chat streams: its transcript (with activity projections and run state) and capabilities.
    await stream.open(conversationID: "central-chat")
    await eventually("conversation subscription") { await socket.subscriptions.count == 2 }
    let chat = await socket.subscriptions[1]
    XCTAssertEqual(chat.stream, "conversation")
    XCTAssertEqual(chat.params.conversationID, "central-chat")
    await socket.push(.item(.init(id: chat.id, payload: .transcript(.init(transcript: .init(conversationID: "central-chat", messages: [
      .init(id: "m1", conversationID: "central-chat", runID: "run", role: "user", content: "Plan the release",
            attachments: [.init(id: "sha", name: "plan.md", mimeType: "text/markdown", byteCount: 12)]),
    ], activities: [.init(id: "a1", runID: "run", title: "Read file", status: "running", projectionJSON: #"{"id":"a1","kind":"tool"}"#)],
      activeRunID: "run", runs: [.init(id: "run", status: "running")]), snapshot: true)))))
    let capabilities = HarnessCapabilities(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: true, canSteer: true)
    await socket.push(.item(.init(id: chat.id, payload: .capabilities(.init(capabilities: capabilities)))))
    await eventually("capabilities") { updates.all.contains(.capabilities(conversationID: "central-chat", capabilities)) }
    let transcript = await store.snapshot().transcripts["central-chat"]
    XCTAssertEqual(transcript?.activeRunID, "run")
    XCTAssertEqual(transcript?.runs?.first?.status, "running")
    XCTAssertEqual(transcript?.activities.first?.projectionJSON, #"{"id":"a1","kind":"tool"}"#, "Activity projections arrive whole")
    XCTAssertEqual(transcript?.messages.first?.attachments?.first?.name, "plan.md")
    XCTAssertTrue(updates.all.contains(.transcript(conversationID: "central-chat")))

    // Another Mac's stream (not the host) names its sessions as its own.
    await stream.setLibraryHost(false)
    var other = brandNew; other.title = "Renamed"
    await socket.push(.item(.init(id: workspaceSub.id, payload: .conversations(.init(conversations: [other], snapshot: false)))))
    await eventually("renamed") { await store.snapshot().conversations["new-central-chat"]?.title == "Renamed" }
    let moved = await store.snapshot().conversations["new-central-chat"]?.workspaceID
    XCTAssertEqual(moved, "studio")
  }

  /// Overlapping opens (the selection changing while a subscription is sent)
  /// leave one subscription, for the latest chat.
  /// `library` items carry the server's library change cursor, named by the
  /// member device ID its `hello` gave, for the model to compare with its own.
  func testLibraryItemsReportTheServersCursor() async throws {
    let (_, server, stream, updates) = try await make()
    await stream.start()
    let socket = await open(server, stream)
    await eventually("workspace subscription") { await socket.subscriptions.count == 1 }
    let workspaceSub = await socket.subscriptions[0]
    await socket.push(.item(.init(id: workspaceSub.id, payload: .library(.init(cursor: 12)))))
    await socket.push(.item(.init(id: workspaceSub.id, payload: .library(.init(cursor: 15)))))
    await eventually("cursors") { updates.all.filter { if case .library = $0 { true } else { false } }.count == 2 }
    XCTAssertEqual(updates.all.filter { if case .library = $0 { true } else { false } },
                   [.library(cursor: 12, serverDeviceID: "mac"), .library(cursor: 15, serverDeviceID: "mac")])
  }

  /// A message file is read from its workspace and checked against its digest.
  func testAttachmentsAreReadFromTheWorkspaceAndCheckedAgainstTheirDigest() async throws {
    let bytes = Data("fixture image bytes".utf8)
    let digest = SHA256.hash(data: bytes).hexString
    let http = AttachmentHTTP(bytes: bytes)
    let credential = DirectWorkspaceCredential(endpoint: URL(string: "https://linux.tail1.ts.net/wovenmatter-execution/linux")!,
                                               libraryID: "library", workspaceID: "linux", deviceID: "phone", token: "test-token")
    let transport = try HTTPSExecutionWorkspaceTransport(credential: credential, performer: http)
    let reference = LibraryAttachmentReference(id: digest, name: "photo.png", mimeType: "image/png")
    let read = try await transport.attachment(reference)
    XCTAssertEqual(read, bytes)
    XCTAssertEqual(http.requests.first?.url?.path, "/wovenmatter-execution/linux/v1/execution/attachments/" + digest)
    XCTAssertEqual(http.requests.first?.url?.query, "name=photo.png")
    XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    // Bytes that do not match the digest are refused; a name that is not a digest is never requested.
    http.bytes = Data("damaged".utf8)
    do { _ = try await transport.attachment(reference); XCTFail("Accepted damaged bytes") } catch {}
    do { _ = try await transport.attachment(.init(id: "../secret", name: "x", mimeType: "text/plain")); XCTFail("Read a non-digest") } catch {}
    XCTAssertEqual(http.requests.count, 2)
  }

  private final class AttachmentHTTP: MobileHTTPPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes: Data
    private var recorded: [URLRequest] = []
    init(bytes: Data) { _bytes = bytes }
    var bytes: Data { get { lock.withLock { _bytes } } set { lock.withLock { _bytes = newValue } } }
    var requests: [URLRequest] { lock.withLock { recorded } }
    func perform(_ request: URLRequest, maximumBytes: Int, longLived: Bool) async throws -> (Data, HTTPURLResponse) {
      lock.withLock { recorded.append(request) }
      return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!)
    }
  }

  func testOverlappingOpensLeaveOneSubscriptionForTheLatestChat() async throws {
    let (_, server, stream, _) = try await make()
    await stream.start()
    let socket = await open(server, stream)
    await eventually("workspace subscription") { await socket.subscriptions.count == 1 }
    // Each subscription takes a while to send, so the later calls overlap the first.
    await socket.setReplies { _ in [] }
    let first = Task { await stream.open(conversationID: "a") }
    await eventually("first chat being sent") { await socket.subscriptions.count == 2 }
    await stream.open(conversationID: "a")
    await stream.open(conversationID: "b")
    await first.value
    await eventually("settled") { await stream.conversationID == "b" }
    try await Task.sleep(for: .milliseconds(30))
    let subscriptions = await socket.subscriptions.filter { $0.stream == "conversation" }
    let cancels = await socket.cancels
    let open = subscriptions.filter { !cancels.contains($0.id) }
    XCTAssertEqual(open.map(\.params.conversationID), ["b"], "\(subscriptions.map(\.params.conversationID))")
  }

  /// A chat the server does not stream (it ended the subscription) is
  /// reported once and not asked for again on that connection, so a refusal
  /// never loops; the next connection may ask again.
  func testAnEndedChatIsReportedAndNotResubscribedOnTheSameConnection() async throws {
    let (_, server, stream, updates) = try await make()
    await stream.start()
    let socket = await open(server, stream)
    await stream.open(conversationID: "legacy")
    await eventually("conversation subscription") { await socket.subscriptions.count == 2 }
    let chat = await socket.subscriptions[1]
    await socket.push(.end(.init(id: chat.id, error: .init(.notFound, "This endpoint can only control agents executing on this Mac."))))
    await eventually("ended") { updates.all.contains { if case .conversationEnded("legacy", _) = $0 { true } else { false } } }
    await stream.open(conversationID: "legacy")
    try await Task.sleep(for: .milliseconds(30))
    let count = await socket.subscriptions.count
    XCTAssertEqual(count, 2, "Not resubscribed on the same connection")
    await socket.serverClose(code: 1001)
    let next = await open(server, stream, socket: 1)
    await eventually("workspace resubscribed") { await next.subscriptions.count == 1 }
    await stream.open(conversationID: "legacy")
    await eventually("asked again on the new connection") { await next.subscriptions.count == 2 }
  }

  /// A replay of many journal entries is one journal write and one
  /// projection restore, not one per entry.
  func testAJournalBurstIsWrittenOnce() async throws {
    let (store, server, stream, updates) = try await make()
    await stream.start()
    let socket = await open(server, stream)
    await eventually("workspace subscription") { await socket.subscriptions.count == 1 }
    let id = await socket.subscriptions[0].id
    for sequence in 1...40 { await socket.push(journalItem(id, Int64(sequence), conversation: "chat-\(sequence)")) }
    await socket.push(.item(.init(id: id, payload: .synchronized)))
    await eventually("written") { updates.all.contains(.history) }
    let cursor = await store.journal.snapshot().directCursors["linux"]
    XCTAssertEqual(cursor, 40)
    try await Task.sleep(for: .milliseconds(100))
    let writes = await stream.journalWrites
    XCTAssertEqual(writes, 1, "One write and one restore for the whole replay")
    XCTAssertEqual(updates.all.filter { $0 == .history }.count, 1)
    let conversations = await store.snapshot().conversations
    XCTAssertEqual(conversations["chat-40"]?.title, "Version 40")

    // Live entries after it are written shortly after they arrive, also together.
    await socket.push(journalItem(id, 41, conversation: "chat-41"))
    await socket.push(journalItem(id, 42, conversation: "chat-42"))
    await eventually("live entries") { await store.journal.snapshot().directCursors["linux"] == 42 }
    let after = await stream.journalWrites
    XCTAssertLessThanOrEqual(after, 3)
  }

  /// A write that fails (here an entry the journal refuses) is not taken:
  /// the subscription asks again from the saved cursor, and keeps it on
  /// later reconnects, so journal delivery never turns off.
  func testAFailedWriteResubscribesFromTheSavedCursor() async throws {
    let (store, server, stream, _) = try await make()
    await stream.start()
    let socket = await open(server, stream)
    await eventually("workspace subscription") { await socket.subscriptions.count == 1 }
    let id = await socket.subscriptions[0].id
    await socket.push(journalItem(id, 1))
    await socket.push(journalItem(id, 2))
    await socket.push(.item(.init(id: id, payload: .synchronized)))
    await eventually("written") { await store.journal.snapshot().directCursors["linux"] == 2 }
    let huge = ExecutionJournalEntry(eventID: "event-3", workspaceID: "linux", originSequence: 3, conversationID: "chat", kind: .conversation,
      conversation: .init(id: "chat", title: String(repeating: "x", count: FederationProtocol.maximumEntryBytes + 1)))
    await socket.push(.item(.init(id: id, seq: 3, payload: .journal(.init(entry: huge)))))
    await socket.push(.item(.init(id: id, payload: .synchronized)))
    await eventually("subscribed again") { await socket.subscriptions.count == 2 }
    let again = await socket.subscriptions[1]
    XCTAssertEqual(again.params.after, 2, "From the saved cursor, never without one")
    await socket.serverClose(code: 1006)
    let next = await open(server, stream, socket: 1)
    await eventually("reconnected") { await next.subscriptions.count == 1 }
    let resumed = await next.subscriptions[0].params.after
    XCTAssertEqual(resumed, 2)
  }

  /// A retryable end is restored by the connection without a report; a
  /// terminal end is reported, not asked for again on that connection, and
  /// the next connection subscribes again.
  func testATerminalWorkspaceEndIsReportedAndTheNextConnectionSubscribesAgain() async throws {
    let (_, server, stream, updates) = try await make()
    await stream.start()
    let socket = await open(server, stream)
    await eventually("workspace subscription") { await socket.subscriptions.count == 1 }
    let first = await socket.subscriptions[0].id
    await socket.push(.end(.init(id: first, error: .init(.unavailable, "Busy.", retryable: true))))
    await eventually("restored") { await socket.subscriptions.count == 2 }
    XCTAssertFalse(updates.all.contains { if case .workspaceEnded = $0 { true } else { false } })

    let second = await socket.subscriptions[1].id
    await socket.push(.end(.init(id: second, error: .init(.invalid, "No workspace here."))))
    await eventually("reported") { updates.all.contains(.workspaceEnded(.init(.invalid, "No workspace here."))) }
    await stream.start()
    try await Task.sleep(for: .milliseconds(30))
    let count = await socket.subscriptions.count
    XCTAssertEqual(count, 2, "Not asked for again on the same connection")

    await socket.serverClose(code: 1001)
    let next = await open(server, stream, socket: 1)
    await eventually("subscribed on the next connection") { await next.subscriptions.count == 1 }
    let stream2 = await next.subscriptions[0].stream
    XCTAssertEqual(stream2, "workspace")
  }

  /// A server that answers a chat's subscription before `subscribe` returns:
  /// its first snapshot is kept.
  func testAFirstSnapshotThatArrivesWhileSubscribingIsKept() async throws {
    let (store, server, stream, _) = try await make()
    await stream.start()
    let socket = await open(server, stream)
    await eventually("workspace subscription") { await socket.subscriptions.count == 1 }
    await socket.setReplies { subscription in
      guard subscription.stream == "conversation" else { return [] }
      return [.item(.init(id: subscription.id, payload: .transcript(.init(transcript: .init(conversationID: "chat", messages: [
        .init(id: "m1", conversationID: "chat", role: "user", content: "Hello"),
      ]), snapshot: true))))]
    }
    await stream.open(conversationID: "chat")
    await eventually("snapshot kept") { await store.snapshot().transcripts["chat"]?.messages.map(\.id) == ["m1"] }
  }

  /// Lifecycle of one workspace's stream: a stale clock is reported as such;
  /// a 4401 close (member removed) stops every retry, on wake and on
  /// foreground too, until the member list changes; the background closes
  /// the socket cleanly.
  func testStaleClockMemberRemovedAndBackgroundClose() async throws {
    let (_, server, stream, updates) = try await make()
    server.refuse(StreamConnectionError.memberTimeStale(serverTime: 1))
    await stream.start()
    await eventually("stale clock") { updates.all.contains(.state(.waiting(.memberTimeStale(serverTime: 1)))) }
    let socket = await open(server, stream)
    await socket.serverClose(code: StreamProtocol.CloseCode.memberRemoved.rawValue)
    await eventually("member removed") { updates.all.contains(.state(.memberRemoved)) }
    await stream.connection.connectNow()
    await stream.stop(); await stream.start()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(server.attempts, 2, "No retry after 4401: not on wake, not on foreground")
    await stream.connection.membersChanged()
    let again = await open(server, stream, socket: 1)
    XCTAssertEqual(server.attempts, 3)
    await stream.stop()
    let closed = await again.closedWith
    XCTAssertEqual(closed, .normal, "The background closes with 1000")
  }
}
