#if canImport(Network)
import Network
import XCTest
import WovenMatterShared
@testable import LibraryClient

/// The stream client on a real WebSocket over loopback: the close code it
/// puts on the wire when a server breaks the protocol.
final class StreamSocketCloseTests: XCTestCase {
  /// A loopback WebSocket server for one client. It sends `messages` as soon
  /// as the client connects and reports the close code the client answers with.
  private final class Server: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var started = false
    private var closed: NWProtocolWebSocket.CloseCode??
    private var waiter: CheckedContinuation<NWProtocolWebSocket.CloseCode?, Never>?

    init(sending messages: [(Data, NWProtocolWebSocket.Opcode)]) throws {
      let parameters = NWParameters.tcp
      parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
      parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
      listener = try NWListener(using: parameters)
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else { return }
        self.lock.withLock { self.connections.append(connection) }
        connection.start(queue: .global())
        for (data, opcode) in messages {
          let context = NWConnection.ContentContext(identifier: "frame", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
          connection.send(content: data, contentContext: context, completion: .contentProcessed { _ in })
        }
        self.receive(connection)
      }
    }

    /// The port, once the listener is ready.
    func start() async throws -> UInt16 {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
        listener.stateUpdateHandler = { [self] state in
          let result: Result<UInt16, any Error>?
          switch state {
          case .ready: result = listener.port.map { .success($0.rawValue) } ?? .failure(StreamTransportClosed())
          case .failed(let error): result = .failure(error)
          case .cancelled: result = .failure(StreamTransportClosed())
          default: result = nil
          }
          guard let result, lock.withLock({ if started { return false }; started = true; return true }) else { return }
          continuation.resume(with: result)
        }
        listener.start(queue: .global())
      }
    }

    private func receive(_ connection: NWConnection) {
      connection.receiveMessage { [weak self] _, context, _, error in
        guard let self else { return }
        if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
           metadata.opcode == .close {
          self.finish(metadata.closeCode); return
        }
        if error != nil { self.finish(nil); return }
        self.receive(connection)
      }
    }

    private func finish(_ code: NWProtocolWebSocket.CloseCode?) {
      let waiting = lock.withLock { () -> CheckedContinuation<NWProtocolWebSocket.CloseCode?, Never>? in
        guard closed == nil else { return nil }
        closed = .some(code)
        defer { waiter = nil }
        return waiter
      }
      waiting?.resume(returning: code)
    }

    /// The close code the client sent, or nil when the socket ended without one.
    func closeCode() async -> NWProtocolWebSocket.CloseCode? {
      await withCheckedContinuation { continuation in
        let known = lock.withLock { () -> NWProtocolWebSocket.CloseCode?? in
          if let closed { return closed }
          waiter = continuation; return nil
        }
        if let known { continuation.resume(returning: known) }
      }
    }

    func stop() {
      listener.cancel()
      for connection in lock.withLock({ connections }) { connection.cancel() }
    }
  }

  private static func transport(port: UInt16) -> WebSocketStreamTransport {
    let task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/stream")!)
    task.maximumMessageSize = StreamProtocol.maximumFrameBytes
    task.resume()
    return WebSocketStreamTransport(task: task)
  }

  private func helloText() throws -> Data {
    try StreamProtocol.encode(.hello(.init(deviceID: "mac", libraryID: "library", workspaceID: "mac", serverTime: 1)))
  }

  /// What the transport throws and what the server then sees on the wire.
  private func refusal(of messages: [(Data, NWProtocolWebSocket.Opcode)], after frames: Int = 0,
                       file: StaticString = #filePath, line: UInt = #line) async throws -> (thrown: Int?, wire: NWProtocolWebSocket.CloseCode?) {
    let server = try Server(sending: messages)
    defer { server.stop() }
    let transport = Self.transport(port: try await server.start())
    for _ in 0..<frames { _ = try await transport.receive() }
    do { _ = try await transport.receive(); XCTFail("The message was accepted as a frame", file: file, line: line); return (nil, nil) }
    catch let closed as StreamTransportClosed { return (closed.code, await server.closeCode()) }
  }

  func testABinaryMessageClosesWith4400() async throws {
    let outcome = try await refusal(of: [(try helloText(), .text), (try helloText(), .binary)], after: 1)
    XCTAssertEqual(outcome.thrown, 4400)
    XCTAssertEqual(outcome.wire, .privateCode(4400))
  }

  func testAnUndefinedFrameTypeAndAnUndefinedItemKindCloseWith4400() async throws {
    for text in [#"{"t":"undefinedFrame","id":"x1"}"#, #"{"t":"item","id":"s1","kind":"undefinedKind","data":{}}"#] {
      let outcome = try await refusal(of: [(try helloText(), .text), (Data(text.utf8), .text)], after: 1)
      XCTAssertEqual(outcome.thrown, 4400, text)
      XCTAssertEqual(outcome.wire, .privateCode(4400), text)
    }
  }

  func testAFrameOverTheLimitClosesWith1009() async throws {
    let oversized = Data((#"{"t":"cancel","id":""# + String(repeating: "a", count: StreamProtocol.maximumFrameBytes) + #""}"#).utf8)
    let outcome = try await refusal(of: [(oversized, .text)])
    XCTAssertEqual(outcome.thrown, 1009)
    XCTAssertEqual(outcome.wire, .protocolCode(.messageTooBig))
  }

  /// Through the connection itself: a server whose first frame is not `hello`.
  func testAFirstFrameThatIsNotHelloClosesWith4400OnTheWire() async throws {
    let item = try StreamProtocol.encode(.item(.init(id: "s1", payload: .synchronized)))
    let server = try Server(sending: [(item, .text), (try helloText(), .text)])
    defer { server.stop() }
    let port = try await server.start()
    let connection = StreamConnection(configuration: .init(retrySleep: { _ in try await Task.sleep(for: .seconds(3600)) })) {
      Self.transport(port: port)
    }
    await connection.start()
    let code = await server.closeCode()
    XCTAssertEqual(code, .privateCode(4400))
    let open = await connection.isOpen
    XCTAssertFalse(open, "The hello that followed is not used")
    await connection.stop()
  }
}
#endif
