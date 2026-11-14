import Foundation
#if canImport(Network)
import Network
#endif
import WovenMatterCore
import WovenMatterShared

/// What one Mac's stream serves: the same data and command path as its
/// `/v1/execution/*` routes (`MacExecutionAPI`).
@MainActor public protocol ExecutionStreamSource: ExecutionConversationSource {
  var workspaceDescriptor: ExecutionWorkspace { get }
  var isServing: Bool { get }
  func localConversations() async throws -> [LibraryConversation]
  func localConversations(ids: Set<String>) async throws -> [String: LibraryConversation]
  func localPendingInteractions() async throws -> [PendingInteraction]
  func localReceipt(commandID: String, deviceID: String) async throws -> LibraryCommandReceipt?
  func executeLocal(_ command: LibraryCommand, deviceID: String,
                    authorize: @MainActor () async throws -> Void) async throws -> LibraryCommandReceipt
}

/// Stream timing and limits. Tests shorten them; the defaults are the contract's.
public struct ExecutionStreamConfiguration: Sendable {
  public var pingInterval: Duration = StreamProtocol.pingInterval
  public var pongTimeout: Duration = StreamProtocol.pongTimeout
  public var smallMessageBytes = StreamProtocol.smallMessageBytes
  public var smallMessageInterval: Duration = StreamProtocol.smallMessageInterval
  public var largeMessageInterval: Duration = StreamProtocol.largeMessageInterval
  public var maximumQueuedItems = StreamProtocol.maximumQueuedItems
  public var maximumQueuedBytes = StreamProtocol.maximumQueuedBytes
  public var maximumSubscriptions = 64
  /// Calls in progress on one socket; another is refused until one answers.
  public var maximumCalls = 64
  /// The largest frame a client may send; a larger one closes the socket with 1009.
  public var maximumClientFrameBytes = 1_024 * 1_024
  /// A subscription whose read failed without ending it reads again after
  /// this, doubling to 30 times it while reads keep failing.
  public var readRetryInterval: Duration = .seconds(1)
  /// How long a close this server starts waits for the client's answering close frame.
  public var closeTimeout: Duration = .seconds(2)
  public init() {}
}

/// Refusals of `GET /v1/stream` before the upgrade.
enum ExecutionStreamRefusal {
  private struct Body: Encodable {
    let code: String
    let message: String
    var supported: [Int]? = nil
    var serverTime: Int64? = nil
  }
  static func response(_ code: String, _ message: String, status: Int, supported: [Int]? = nil, serverTime: Int64? = nil) -> LibraryHTTPResponse {
    (try? .json(Body(code: code, message: message, supported: supported, serverTime: serverTime), status: status))
      ?? .error(code, message, status: status)
  }
}

/// Changes since a subscriber last looked, by conversation ID.
enum ExecutionStreamEvent: Sendable {
  case changes([String: Set<String>])
  /// Entries were pruned before they were read, or the tail restarted: every
  /// subscription compares again with what is stored.
  case reset
  /// In-memory state (questions, approvals, run state, capabilities) changed
  /// for these conversations, or for every conversation when empty.
  case live(Set<String>)
  /// The library change cursor moved (`LibraryChangeAnnouncer`, coalesced).
  case library(Int64)
}

/// Tails `execution_stream_changes` after each commit that adds to it.
actor ExecutionStreamTail {
  private let database: WorkspaceDatabase
  private var cursor: Int64?
  private var reading = false
  private var again = false
  private var listeners: [UUID: @Sendable (ExecutionStreamEvent) async -> Void] = [:]
  init(database: WorkspaceDatabase) { self.database = database }

  func start() async { if cursor == nil { cursor = try? await database.executionStreamCursor() } }
  func add(_ id: UUID, _ listener: @escaping @Sendable (ExecutionStreamEvent) async -> Void) { listeners[id] = listener }
  func remove(_ id: UUID) { listeners.removeValue(forKey: id) }

  func publish(_ event: ExecutionStreamEvent) async {
    for listener in listeners.values { await listener(event) }
  }

  func poke() async {
    guard !reading else { again = true; return }
    reading = true
    defer { reading = false }
    repeat {
      again = false
      guard let start = cursor else {
        cursor = try? await database.executionStreamCursor()
        await publish(.reset)
        continue
      }
      var after = start, changed: [String: Set<String>] = [:], reset = false
      do {
        while true {
          let page = try await database.executionStreamChanges(after: after)
          if page.truncated { reset = true; after = page.latest; break }
          for change in page.changes { changed[change.conversationID, default: []].insert(change.entityKind) }
          after = page.changes.last?.sequence ?? after
          if !page.hasMore { break }
        }
      } catch {
        // A failed read is retried; nothing after `start` was consumed.
        Task { [weak self] in try? await Task.sleep(for: .seconds(1)); await self?.poke() }
        return
      }
      cursor = after
      if reset { await publish(.reset) } else if !changed.isEmpty { await publish(.changes(changed)) }
    } while again
  }
}

#if canImport(Network)
/// `GET /v1/stream?protocol=1` on this Mac. The outer library server verifies
/// the member signature, then relays the connection's bytes to this server's
/// loopback listener, which terminates the WebSocket with the Network
/// framework. That listener is never published: it accepts only connections
/// whose loopback source port the outer server bound to a verified member just
/// before sending the handshake, and only handshakes carrying this process's
/// secret.
public final class ExecutionStreamServer: @unchecked Sendable {
  public static let allowedKinds: Set<MemberKind> = StreamSession.memberKinds
  public let configuration: ExecutionStreamConfiguration
  let source: any ExecutionStreamSource
  let members: MemberDirectory
  let registry: MemberSocketRegistry
  let tail: ExecutionStreamTail
  let queue = DispatchQueue(label: "com.wovenmatter.stream")
  private let database: WorkspaceDatabase
  private let secret = (0..<4).map { _ in UUID().uuidString }.joined()
  // Confined to `queue`.
  private var listener: NWListener?
  private var port: UInt16?
  private var bindings: [UInt16: (member: LibraryMember, expires: Date)] = [:]
  private var sessions: [UUID: StreamSession] = [:]
  private var observer: UUID?
  /// `library` items: the mobile library change cursor, at most every 300 ms.
  private var library: LibraryChangeAnnouncer?

  public init(database: WorkspaceDatabase, source: any ExecutionStreamSource, members: MemberDirectory,
              registry: MemberSocketRegistry, configuration: ExecutionStreamConfiguration = .init()) {
    self.database = database; self.source = source; self.members = members; self.registry = registry
    self.configuration = configuration; tail = ExecutionStreamTail(database: database)
  }

  /// Starts the loopback listener and the change tail.
  public func start() async throws {
    await tail.start()
    let tail = tail
    let observer = database.observeExecutionStreamChanges { _ in Task { await tail.poke() } }
    let library = LibraryChangeAnnouncer(database: database) { cursor in await tail.publish(.library(cursor)) }
    queue.sync { self.observer = observer; self.library = library }
    await library.start()
    await registry.start()
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        guard listener == nil else { continuation.resume(returning: self.port ?? 0); return }
        do {
          let options = NWProtocolWebSocket.Options()
          options.autoReplyPing = true
          // A client's frames are far smaller than the server's (contract: 1 MiB, close 1009).
          options.maximumMessageSize = configuration.maximumClientFrameBytes
          let secret = secret
          options.setClientRequestHandler(queue) { _, headers in
            let authorized = headers.contains { $0.name.lowercased() == "authorization" && $0.value == "Bearer " + secret }
            return .init(status: authorized ? .accept : .reject, subprotocol: nil)
          }
          let parameters = NWParameters.tcp
          parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
          parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 0)
          let next = try NWListener(using: parameters)
          listener = next
          final class Once: @unchecked Sendable { var done = false }
          let resumed = Once()
          next.stateUpdateHandler = { [weak self] state in
            guard !resumed.done else { return }
            switch state {
            case .ready:
              resumed.done = true
              let value = next.port?.rawValue ?? 0
              self?.port = value
              continuation.resume(returning: value)
            case .failed(let error): resumed.done = true; continuation.resume(throwing: error)
            case .cancelled: resumed.done = true; continuation.resume(throwing: CancellationError())
            default: break
            }
          }
          next.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
          next.start(queue: queue)
        } catch { continuation.resume(throwing: error) }
      }
    }
    guard port != 0 else { throw LibraryAPIError(code: "unavailable", message: "The stream listener could not start.") }
  }

  /// Closes every stream socket with 1001 and stops listening.
  public func stop() {
    if let observer = queue.sync(execute: { self.observer }) { database.removeExecutionStreamObserver(observer) }
    if let library = queue.sync(execute: { self.library }) { Task { await library.stop() } }
    let registry = registry
    Task { await registry.stop() }
    queue.async { [self] in
      observer = nil; library = nil
      listener?.cancel(); listener = nil; port = nil; bindings.removeAll()
      for session in sessions.values { Task { await session.close(.goingAway) } }
      sessions.removeAll()
    }
  }

  /// In-memory state changed: pending questions and approvals, run state or
  /// capabilities, for `conversationIDs` (every conversation when empty).
  public func liveStateChanged(conversationIDs: Set<String> = []) {
    let tail = tail
    Task { await tail.publish(.live(conversationIDs)) }
  }

  /// Open stream sockets, for diagnostics and tests.
  public func openSessionCount() -> Int { queue.sync { sessions.count } }

  /// The tasks each open socket holds (its ping loop and calls in progress), for tests.
  func retainedTaskCounts() async -> [Int] {
    var counts: [Int] = []
    for session in queue.sync(execute: { Array(sessions.values) }) { counts.append(await session.retainedTaskCount) }
    return counts
  }

  /// The outer server's decision for `GET /v1/stream`: every refusal happens
  /// here, before the upgrade, as a JSON HTTP error.
  public func upgrade(_ request: LibraryHTTPRequest) async -> WebSocketUpgradeDecision {
    let components = URLComponents(string: "http://localhost" + request.target)
    let versions = components?.queryItems?.filter { $0.name == "protocol" }.compactMap { $0.value.flatMap(Int.init) } ?? []
    guard versions.count == 1, StreamProtocol.supportedVersions.contains(versions[0]) else {
      return .reject(ExecutionStreamRefusal.response(StreamProtocol.ErrorCode.protocolUnsupported.rawValue,
        "Update this app: this server streams protocol \(StreamProtocol.version).", status: 426, supported: StreamProtocol.supportedVersions))
    }
    guard request.headers["origin"] == nil, request.headers["cookie"] == nil else {
      return .reject(.error(LibraryHTTPParser.browserRequest.code, LibraryHTTPParser.browserRequest.message, status: 403))
    }
    guard MemberRequestVerifier.isSigned(request.headers) else {
      return .reject(.error("unauthorized", MemberRequestError.missing.message, status: 401))
    }
    let member: LibraryMember
    do { member = try await members.authenticate(request, allowing: Self.allowedKinds) }
    catch let error as MemberRequestError {
      if error == .clock {
        return .reject(ExecutionStreamRefusal.response(StreamProtocol.ErrorCode.memberTimeStale.rawValue, error.message,
                                                       status: 401, serverTime: MemberRequestSignature.now()))
      }
      return .reject(.error(error == .kind ? error.code : "unauthorized", error.message, status: error == .kind ? 403 : 401))
    } catch { return .reject(.error("unauthorized", error.localizedDescription, status: 401)) }
    guard await source.isServing, let port = queue.sync(execute: { self.port }),
          let head = WebSocketUpgradeDecision.webSocketHead(for: request, port: port, path: "/v1/stream", bearer: secret) else {
      return .reject(.error("unavailable", "This Mac's stream is starting.", status: 503))
    }
    let queue = queue
    return .tunnel(port: port, head: head, options: .init(bind: { [weak self] sourcePort in
      // Synchronously, so the binding exists before the handshake is sent.
      queue.sync { self?.bindings[sourcePort] = (member, Date().addingTimeInterval(30)) }
    }))
  }

  private func accept(_ connection: NWConnection) {
    // The outer server bound this source port before sending the handshake,
    // so by the time the handshake completes the binding is present.
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { connection.cancel(); return }
      switch state {
      case .ready: self.ready(connection)
      case .failed, .cancelled: connection.stateUpdateHandler = nil
      default: break
      }
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 15) {
      if case .ready = connection.state { return }
      connection.cancel()
    }
  }

  private func ready(_ connection: NWConnection) {
    let now = Date()
    bindings = bindings.filter { $0.value.expires > now }
    guard case .hostPort(_, let remote) = connection.endpoint, let binding = bindings.removeValue(forKey: remote.rawValue) else {
      connection.cancel(); return
    }
    let session = StreamSession(context: sessionContext(),
                                wire: WebSocketStreamWire(connection: connection, queue: queue, closeTimeout: configuration.closeTimeout,
                                                          maximumFrameBytes: configuration.maximumClientFrameBytes),
                                member: binding.member)
    sessions[session.id] = session
    connection.stateUpdateHandler = { [weak session] state in
      switch state { case .failed, .cancelled: Task { await session?.close(nil) }; default: break }
    }
    Task { await session.begin() }
  }

  private func sessionContext() -> StreamSessionContext {
    let database = database
    return .init(configuration: configuration, conversations: source, workspace: source, members: members,
          registry: registry,
          tail: tail, serverState: nil, hello: { [weak self] in
            await self?.hello ?? StreamHello(deviceID: "", libraryID: "", workspaceID: "", serverTime: MemberRequestSignature.now())
          }, ended: { [weak self] id in self?.ended(id) }, libraryCursor: { try? await database.libraryWakeCursor() })
  }

  func ended(_ id: UUID) {
    queue.async { [self] in sessions.removeValue(forKey: id) }
  }

  var hello: StreamHello {
    get async {
      let descriptor = await source.workspaceDescriptor
      var capabilities = descriptor.capabilities
      if !capabilities.contains(StreamProtocol.capability) { capabilities.append(StreamProtocol.capability) }
      return StreamHello(deviceID: members.identity.deviceID, libraryID: descriptor.libraryID, workspaceID: descriptor.id,
                         serverTime: MemberRequestSignature.now(), capabilities: capabilities.sorted())
    }
  }
}

/// A member's WebSocket, terminated by the Network framework: JSON text
/// frames, ping and pong control frames, and WebSocket close codes.
///
/// A close this server starts is a closing handshake (RFC 6455 §7.1): its
/// close frame goes out, and the connection ends once the client answers with
/// its own close frame (or fails, or after `closeTimeout`), as the Linux
/// server's `ws` does. Ending it as soon as the frame was written lets the
/// client's answer, or anything it was still sending, meet a closed socket.
/// The reset that follows can reach a client before it has read the close
/// frame; one whose stack reports the reset first sees an abnormal close
/// instead of `4401` and retries a removal it should honour.
final class WebSocketStreamWire: ExecutionStreamWire, @unchecked Sendable {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let closeTimeout: Duration
  private let maximumFrameBytes: Int
  private let lock = NSLock()
  /// The client sent a frame over `maximumFrameBytes`: the close says 1009.
  private var tooLarge = false
  /// This side's close frame was written.
  private var closeSent = false
  /// The client sent its close frame, or the connection ended.
  private var peerClosed = false
  /// This side is closing: frames from the client are no longer delivered.
  private var closing = false

  init(connection: NWConnection, queue: DispatchQueue, closeTimeout: Duration, maximumFrameBytes: Int = 1_024 * 1_024) {
    self.connection = connection; self.queue = queue; self.closeTimeout = closeTimeout; self.maximumFrameBytes = maximumFrameBytes
  }

  func start(_ session: StreamSession) { receive(session) }

  private static func metadata(_ context: NWConnection.ContentContext?) -> NWProtocolWebSocket.Metadata? {
    context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
  }

  private func receive(_ session: StreamSession) {
    connection.receiveMessage { [weak self, weak session] data, context, _, error in
      guard let self else { return }
      let metadata = Self.metadata(context)
      let ended = error != nil || metadata?.opcode == .close
      if self.lock.withLock({ closing }) { if ended { self.peerFinished() } else { self.drain() }; return }
      guard let session else { self.connection.cancel(); return }
      // The listener reads at most `maximumFrameBytes` of one message; a larger one fails the read.
      let tooLarge = (data?.count ?? 0) > self.maximumFrameBytes || Self.isTooLarge(error)
      if tooLarge { self.lock.withLock { self.tooLarge = true } }
      Task {
        let input: StreamWireInput
        if tooLarge { input = .closed(.protocolViolation) }
        else if error != nil { input = .closed(nil) }
        else {
          switch metadata?.opcode {
          case .close?: input = .closed(.normal)
          case .text?:
            if let data {
              do { input = .frame(try StreamProtocol.decode(data)) } catch { input = .closed(.protocolViolation) }
            } else { input = .heard }
          case .binary?: input = .closed(.protocolViolation)
          default: input = .heard
          }
        }
        if await session.deliver(input) { self.receive(session) }
        // The session is closing: wait for the client's close frame.
        else if ended { self.peerFinished() } else { self.drain() }
      }
    }
  }

  private static func isTooLarge(_ error: NWError?) -> Bool {
    if case .posix(let code)? = error { return code == .EMSGSIZE }
    return false
  }

  /// Reads (and drops) what the client sends until its close frame.
  private func drain() {
    connection.receiveMessage { [weak self] _, context, _, error in
      guard let self else { return }
      if error != nil || Self.metadata(context)?.opcode == .close { self.peerFinished() } else { self.drain() }
    }
  }

  private func peerFinished() {
    let done = lock.withLock { peerClosed = true; return closeSent }
    if done { connection.cancel() }
  }

  func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
    connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
      completion(error == nil)
    })
  }

  var pings: Bool { true }

  func ping(_ pong: @escaping @Sendable () -> Void) {
    let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
    metadata.setPongHandler(queue) { error in if error == nil { pong() } }
    let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
    connection.send(content: Data(), contentContext: context, isComplete: true, completion: .idempotent)
  }

  func close(_ code: WovenMatterShared.StreamProtocol.CloseCode?) {
    let connection = connection
    lock.withLock { closing = true }
    guard let code else { connection.cancel(); return }
    let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
    metadata.closeCode = lock.withLock({ tooLarge }) ? .protocolCode(.messageTooBig)
      : code.rawValue < 4000 ? .protocolCode(code == .normal ? .normalClosure : .goingAway) : .privateCode(UInt16(code.rawValue))
    let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
    connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
      guard let self, error == nil else { connection.cancel(); return }
      // Ends now when the client already closed (it started the close); otherwise on its answer.
      if self.lock.withLock({ self.closeSent = true; return self.peerClosed }) { connection.cancel() }
    })
    // The session lets go of this wire as it closes; the wait keeps it, and so
    // its reads of the answer, alive. A client that never answers is not waited for.
    Task { [self] in try? await Task.sleep(for: closeTimeout); connection.cancel() }
  }
}

#endif
