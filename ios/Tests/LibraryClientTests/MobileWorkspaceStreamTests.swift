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
    XCTAssertEqual(sent.workspaceID, "linux")
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
}
