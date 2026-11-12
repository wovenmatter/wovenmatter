import Foundation
#if canImport(Network)
import Network
#endif
import WovenMatterCore
import WovenMatterShared

/// What one Mac's stream serves: the same data and command path as its
/// `/v1/execution/*` routes (`MacExecutionAPI`).
@MainActor public protocol ExecutionStreamSource: AnyObject, Sendable {
  var workspaceDescriptor: ExecutionWorkspace { get }
  var isServing: Bool { get }
  func localConversations() async throws -> [LibraryConversation]
  func localConversations(ids: Set<String>) async throws -> [String: LibraryConversation]
  func localPendingInteractions() async throws -> [PendingInteraction]
  func localTranscript(conversationID: String, before: String?) async throws -> LibraryTranscript
  func localCapabilities(conversationID: String) async throws -> HarnessCapabilities
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
  public static let allowedKinds: Set<MemberKind> = [.mac, .ios, .linux]
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
    queue.sync { self.observer = observer }
    await registry.start()
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        guard listener == nil else { continuation.resume(returning: self.port ?? 0); return }
        do {
          let options = NWProtocolWebSocket.Options()
          options.autoReplyPing = true
          options.maximumMessageSize = StreamProtocol.maximumFrameBytes
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
    let registry = registry
    Task { await registry.stop() }
    queue.async { [self] in
      observer = nil
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
    let session = StreamSession(server: self, connection: connection, member: binding.member)
    sessions[session.id] = session
    connection.stateUpdateHandler = { [weak session] state in
      switch state { case .failed, .cancelled: Task { await session?.close(nil) }; default: break }
    }
    Task { await session.begin() }
  }

  func ended(_ session: StreamSession) {
    queue.async { [self] in sessions.removeValue(forKey: session.id) }
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

/// One stream socket: its subscriptions, calls and bounded outbound queue.
actor StreamSession {
  nonisolated let id = UUID()
  private let server: ExecutionStreamServer
  private let connection: NWConnection
  let member: LibraryMember
  private let configuration: ExecutionStreamConfiguration
  private var subscriptions: [String: Subscription] = [:]
  private var calls: Set<String> = []
  private var outbox: [Outgoing] = []
  private var queuedBytes = 0
  private var writing = false
  private var closed = false
  private var lastHeard = ContinuousClock.now
  private var registration: UUID?
  private var tasks: [Task<Void, Never>] = []

  init(server: ExecutionStreamServer, connection: NWConnection, member: LibraryMember) {
    self.server = server; self.connection = connection; self.member = member; configuration = server.configuration
  }

  // MARK: Lifetime

  func begin() async {
    registration = await server.registry.register(deviceID: member.deviceID, kinds: ExecutionStreamServer.allowedKinds) { [weak self] in
      Task { await self?.close(.memberRemoved) }
    }
    guard !closed else { if let registration { await server.registry.unregister(registration) }; return }
    let server = server
    await server.tail.add(id) { [weak self] event in await self?.apply(event) }
    enqueue(.hello(await server.hello))
    receive()
    tasks.append(Task { [weak self, configuration] in
      while !Task.isCancelled {
        try? await Task.sleep(for: configuration.pingInterval)
        guard !Task.isCancelled else { return }
        await self?.keepAlive()
      }
    })
  }

  /// Sends a close frame with `code` (none for a connection that already
  /// failed), then closes the connection.
  func close(_ code: WovenMatterShared.StreamProtocol.CloseCode?) async {
    guard !closed else { return }
    closed = true
    for task in tasks { task.cancel() }
    tasks.removeAll()
    for subscription in subscriptions.values { subscription.task?.cancel() }
    subscriptions.removeAll(); outbox.removeAll(); queuedBytes = 0
    await server.tail.remove(id)
    if let registration { await server.registry.unregister(registration) }
    server.ended(self)
    let connection = connection
    guard let code else { connection.cancel(); return }
    let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
    metadata.closeCode = code.rawValue < 4000 ? .protocolCode(code == .normal ? .normalClosure : .goingAway) : .privateCode(UInt16(code.rawValue))
    let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
    connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    server.queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
  }

  private func keepAlive() {
    guard !closed else { return }
    if ContinuousClock.now - lastHeard > configuration.pongTimeout {
      Task { await close(.goingAway) }
      return
    }
    let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
    metadata.setPongHandler(server.queue) { [weak self] error in
      guard error == nil else { return }
      Task { await self?.heard() }
    }
    let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
    connection.send(content: Data(), contentContext: context, isComplete: true, completion: .idempotent)
  }

  private func heard() { lastHeard = .now }

  // MARK: Receiving

  private nonisolated func receive() {
    connection.receiveMessage { [weak self] data, context, _, error in
      guard let self else { return }
      let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
      Task {
        guard error == nil else { await self.close(nil); return }
        if await self.received(data, opcode: metadata?.opcode) { self.receive() }
      }
    }
  }

  /// Handles one message; false once the socket is closing.
  private func received(_ data: Data?, opcode: NWProtocolWebSocket.Opcode?) async -> Bool {
    guard !closed else { return false }
    lastHeard = .now
    switch opcode {
    case .close?: await close(.normal); return false
    case .text?:
      guard let data else { return true }
      let frame: StreamFrame
      do { frame = try StreamProtocol.decode(data) } catch { await close(.protocolViolation); return false }
      handle(frame)
      return true
    case .binary?: await close(.protocolViolation); return false
    default: return true
    }
  }

  private func handle(_ frame: StreamFrame) {
    switch frame {
    case .request(let request): call(request)
    case .subscribe(let request): subscribe(request)
    case .cancel(let cancel):
      calls.remove(cancel.id)
      if let subscription = subscriptions.removeValue(forKey: cancel.id) {
        subscription.task?.cancel()
        drop(subscription: cancel.id)
      }
    // Frames a server sends, and frames this build does not know, are ignored.
    case .hello, .response, .item, .end, .unknown: break
    }
  }

  // MARK: Calls

  private func call(_ request: StreamRequest) {
    guard !calls.contains(request.id) else {
      enqueue(.response(.init(id: request.id, error: .init(.invalid, "This call ID is already in use on this socket."))))
      return
    }
    calls.insert(request.id)
    let source = server.source, member = member, members = server.members
    tasks.append(Task { [weak self] in
      let response: StreamResponse
      do {
        switch StreamProtocol.Method(rawValue: request.method) {
        case .executionCommand?:
          let command = try request.decodeParams(StreamCommandParams.self).command
          let receipt = try await source.executeLocal(command, deviceID: member.deviceID) {
            guard await members.member(member.deviceID) != nil else { throw MemberRequestError.unknown }
          }
          response = try .init(id: request.id, encoding: receipt)
        case .executionReceipt?:
          let params = try request.decodeParams(StreamReceiptParams.self)
          let receipt = try await source.localReceipt(commandID: params.commandID, deviceID: member.deviceID)
          response = receipt.map { (try? StreamResponse(id: request.id, encoding: $0)) ?? .init(id: request.id, result: .null) }
            ?? .init(id: request.id, result: .null)
        case nil:
          response = .init(id: request.id, error: .init(.invalid, "Unknown method \(request.method)."))
        }
      } catch { response = .init(id: request.id, error: Self.streamError(error)) }
      await self?.respond(response)
    })
  }

  private func respond(_ response: StreamResponse) {
    // A cancelled call is abandoned: the work it started is not undone, and
    // its receipt stays available through `execution.receipt`.
    guard calls.remove(response.id) != nil else { return }
    enqueue(.response(response))
  }

  static func streamError(_ error: any Error) -> StreamError {
    if let error = error as? StreamError { return error }
    if let error = error as? MemberRequestError { return .init(.unauthorized, error.message) }
    if error is DecodingError { return .init(.invalid, "This request's parameters are invalid.") }
    if let error = error as? LibraryAPIError {
      switch error.code {
      case "unauthorized": return .init(.unauthorized, error.message)
      case "not_found": return .init(.notFound, error.message)
      case "conflict", "operation_in_progress", "revision_conflict": return .init(.conflict, error.message)
      case "wrong_workspace", "unsupported", "invalid_request", "invalid": return .init(.invalid, error.message)
      default: return .init(code: error.code, message: error.message, retryable: false)
      }
    }
    return .init(.unavailable, "This Mac could not complete the request. Check its receipt before retrying.", retryable: true)
  }

  // MARK: Subscriptions

  private final class Subscription {
    enum Kind { case workspace, conversation(String) }
    let id: String
    let kind: Kind
    var task: Task<Void, Never>?
    var dirty = false
    var dirtyAgain = false
    var snapshotDone = false
    var lastSend: ContinuousClock.Instant?
    var lastLarge = false
    // What this subscriber was last sent.
    var conversations: [String: LibraryConversation] = [:]
    var pending: [PendingInteraction]?
    /// Workspace: conversations to read again, or every one after a reset.
    var changedConversations: Set<String> = []
    var reloadAll = false
    var messages: [String: LibraryMessage] = [:]
    var activities: [String: LibraryActivity] = [:]
    var activeRunID: String??
    var runs: [LibraryTranscriptRun]??
    var removedMessageIDs: [String]??
    var capabilities: HarnessCapabilities?
    init(id: String, kind: Kind) { self.id = id; self.kind = kind }
  }

  private func subscribe(_ request: StreamSubscribe) {
    guard subscriptions[request.id] == nil else {
      enqueue(.end(.init(id: request.id, error: .init(.invalid, "This subscription ID is already in use on this socket."))))
      return
    }
    guard subscriptions.count < configuration.maximumSubscriptions else {
      enqueue(.end(.init(id: request.id, error: .init(.unavailable, "Too many subscriptions on this socket.", retryable: true))))
      return
    }
    let kind: Subscription.Kind
    switch StreamProtocol.Stream(rawValue: request.stream) {
    case .workspace?: kind = .workspace
    case .conversation?:
      guard let id = request.params.conversationID, !id.isEmpty else {
        enqueue(.end(.init(id: request.id, error: .init(.invalid, "Name the conversation to subscribe to.")))); return
      }
      kind = .conversation(id)
    case .serverState?:
      enqueue(.end(.init(id: request.id, error: .init(.invalid, "server.state is served only to this Mac's own windows.")))); return
    case nil:
      enqueue(.end(.init(id: request.id, error: .init(.invalid, "Unknown stream \(request.stream).")))); return
    }
    let subscription = Subscription(id: request.id, kind: kind)
    subscriptions[request.id] = subscription
    // Registered before the snapshot is read, so a change during the read
    // makes it compare again afterwards.
    subscription.dirty = true
    subscription.task = Task { [weak self] in await self?.refresh(request.id) }
  }

  private func apply(_ event: ExecutionStreamEvent) {
    for subscription in subscriptions.values {
      switch (event, subscription.kind) {
      case (.reset, .workspace): subscription.reloadAll = true; markDirty(subscription)
      case (.reset, _): markDirty(subscription)
      case (.changes(let changes), .workspace):
        // Summaries change with the conversation row and its runs; questions
        // and approvals start and end with runs and their events.
        let relevant = changes.filter { !$0.value.isDisjoint(with: ["conversation", "run", "run_event"]) }
        guard !relevant.isEmpty else { continue }
        subscription.changedConversations.formUnion(relevant.keys)
        markDirty(subscription)
      case (.changes(let changes), .conversation(let id)): if changes[id] != nil { markDirty(subscription) }
      case (.live, .workspace): markDirty(subscription)
      case (.live(let ids), .conversation(let id)): if ids.isEmpty || ids.contains(id) { markDirty(subscription) }
      }
    }
  }

  private func markDirty(_ subscription: Subscription) {
    if subscription.task != nil { subscription.dirtyAgain = true; return }
    subscription.dirty = true
    let id = subscription.id
    let interval = subscription.lastLarge ? configuration.largeMessageInterval : configuration.smallMessageInterval
    let wait = subscription.lastSend.map { max(.zero, interval - (ContinuousClock.now - $0)) } ?? .zero
    subscription.task = Task { [weak self] in
      if wait > .zero { try? await Task.sleep(for: wait) }
      guard !Task.isCancelled else { return }
      await self?.refresh(id)
    }
  }

  /// Compares the stored state with what this subscriber holds and sends the difference.
  private func refresh(_ id: String) async {
    guard let subscription = subscriptions[id], !closed else { return }
    subscription.dirty = false; subscription.dirtyAgain = false
    do {
      switch subscription.kind {
      case .workspace: try await refreshWorkspace(subscription)
      case .conversation(let conversationID): try await refreshConversation(subscription, conversationID)
      }
    } catch is CancellationError {
      return
    } catch {
      guard subscriptions[id] === subscription else { return }
      end(subscription, error: Self.subscriptionError(error))
      return
    }
    guard subscriptions[id] === subscription else { return }
    subscription.task = nil
    if subscription.dirtyAgain { markDirty(subscription) }
  }

  static func subscriptionError(_ error: any Error) -> StreamError {
    if let error = error as? LibraryAPIError, error.code == "wrong_workspace" {
      return .init(.notFound, "This conversation is not running on this Mac.")
    }
    return streamError(error)
  }

  private func refreshWorkspace(_ subscription: Subscription) async throws {
    let source = server.source
    if !subscription.snapshotDone {
      let conversations = try await source.localConversations()
      let pending = try await source.localPendingInteractions()
      try Task.checkCancellation()
      subscription.conversations = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      subscription.pending = pending
      enqueue(.item(.init(id: subscription.id, payload: .conversations(.init(conversations: conversations, snapshot: true)))), for: subscription)
      enqueue(.item(.init(id: subscription.id, payload: .pending(.init(interactions: pending)))), for: subscription)
      // This Mac hosts the library: history moves by library sync, so there are no journal items.
      enqueue(.item(.init(id: subscription.id, payload: .synchronized)), for: subscription)
      subscription.snapshotDone = true
      subscription.lastSend = .now
      return
    }
    // Only conversations that changed are read again, except after a reset.
    let reloadAll = subscription.reloadAll, ids = subscription.changedConversations
    subscription.reloadAll = false; subscription.changedConversations = []
    let current: [String: LibraryConversation]
    if reloadAll {
      current = Dictionary(try await source.localConversations().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    } else {
      current = ids.isEmpty ? [:] : try await source.localConversations(ids: ids)
    }
    let pending = try await source.localPendingInteractions()
    try Task.checkCancellation()
    let changed = current.values.filter { subscription.conversations[$0.id] != $0 }.sorted { $0.id < $1.id }
    let candidates = reloadAll ? Set(subscription.conversations.keys) : ids
    let deleted = candidates.filter { current[$0] == nil && subscription.conversations[$0] != nil }.sorted()
    if !changed.isEmpty || !deleted.isEmpty {
      for value in changed { subscription.conversations[value.id] = value }
      for id in deleted { subscription.conversations.removeValue(forKey: id) }
      enqueue(.item(.init(id: subscription.id, payload: .conversations(.init(conversations: changed,
        deletedConversationIDs: deleted.isEmpty ? nil : deleted, snapshot: false)))), for: subscription)
      subscription.lastSend = .now
    }
    if pending != subscription.pending {
      subscription.pending = pending
      enqueue(.item(.init(id: subscription.id, payload: .pending(.init(interactions: pending)))), for: subscription)
      subscription.lastSend = .now
    }
  }

  private func refreshConversation(_ subscription: Subscription, _ conversationID: String) async throws {
    let source = server.source
    let transcript = try await source.localTranscript(conversationID: conversationID, before: nil)
    let capabilities = try? await source.localCapabilities(conversationID: conversationID)
    try Task.checkCancellation()
    let id = subscription.id
    if !subscription.snapshotDone {
      remember(transcript, in: subscription)
      enqueue(.item(.init(id: id, payload: .transcript(.init(transcript: transcript, snapshot: true)))), for: subscription)
      if let capabilities {
        subscription.capabilities = capabilities
        enqueue(.item(.init(id: id, payload: .capabilities(.init(capabilities: capabilities)))), for: subscription)
      }
      enqueue(.item(.init(id: id, payload: .synchronized)), for: subscription)
      subscription.snapshotDone = true
      subscription.lastSend = .now
      return
    }
    let messages = transcript.messages.filter { subscription.messages[$0.id] != $0 }
    let activities = transcript.activities.filter { subscription.activities[$0.id] != $0 }
    let stateChanged = subscription.activeRunID != .some(transcript.activeRunID) || subscription.runs != .some(transcript.runs)
      || subscription.removedMessageIDs != .some(transcript.removedMessageIDs)
    if !messages.isEmpty || !activities.isEmpty || stateChanged {
      remember(transcript, in: subscription)
      let update = LibraryTranscript(conversationID: conversationID, messages: messages, activities: activities,
                                     activeRunID: transcript.activeRunID, runs: transcript.runs, removedMessageIDs: transcript.removedMessageIDs)
      enqueue(.item(.init(id: id, payload: .transcript(.init(transcript: update, snapshot: false)))), for: subscription)
      subscription.lastSend = .now
      // A large message slows this conversation's updates until it is no longer changing.
      subscription.lastLarge = messages.contains { $0.content.utf8.count > configuration.smallMessageBytes }
    }
    if let capabilities, capabilities != subscription.capabilities {
      subscription.capabilities = capabilities
      enqueue(.item(.init(id: id, payload: .capabilities(.init(capabilities: capabilities)))), for: subscription)
    }
  }

  private func remember(_ transcript: LibraryTranscript, in subscription: Subscription) {
    // Only the latest window is kept: an entity that leaves it and changes again is sent whole again.
    subscription.messages = Dictionary(transcript.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    subscription.activities = Dictionary(transcript.activities.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    subscription.activeRunID = .some(transcript.activeRunID)
    subscription.runs = .some(transcript.runs)
    subscription.removedMessageIDs = .some(transcript.removedMessageIDs)
  }

  private func end(_ subscription: Subscription, error: StreamError?) {
    guard subscriptions[subscription.id] === subscription else { return }
    subscriptions.removeValue(forKey: subscription.id)
    subscription.task?.cancel()
    drop(subscription: subscription.id)
    enqueue(.end(.init(id: subscription.id, error: error)))
  }

  // MARK: Sending

  private struct Outgoing {
    var subscription: String?
    var frame: StreamFrame
    var data: Data
  }

  /// Queues a frame. An update to the same entity of the same subscription
  /// supersedes a queued one; a subscription that still overflows the queue
  /// ends with `resync`.
  private func enqueue(_ frame: StreamFrame, for subscription: Subscription? = nil) {
    guard !closed else { return }
    if let subscription, subscriptions[subscription.id] !== subscription { return }
    var frame = frame
    if let subscription, case .item(let item) = frame,
       let index = outbox.lastIndex(where: { $0.subscription == subscription.id && Self.supersedes(item, $0.frame) }),
       case .item(let queued) = outbox[index].frame, let merged = Self.merge(queued, item) {
      frame = .item(merged)
      queuedBytes -= outbox[index].data.count
      outbox.remove(at: index)
      guard let data = try? StreamProtocol.encode(frame) else { overflow(subscription); return }
      outbox.insert(.init(subscription: subscription.id, frame: frame, data: data), at: index)
      queuedBytes += data.count
    } else {
      guard let data = try? StreamProtocol.encode(frame) else {
        // One entity over the frame limit would not fit after a resubscribe either.
        if let subscription {
          end(subscription, error: .init(.unavailable, "This conversation's latest messages are too large to stream. Open its history instead."))
        }
        return
      }
      outbox.append(.init(subscription: subscription?.id, frame: frame, data: data))
      queuedBytes += data.count
    }
    if let subscription, outbox.count > configuration.maximumQueuedItems || queuedBytes > configuration.maximumQueuedBytes {
      overflow(subscription); return
    }
    pump()
  }

  private func overflow(_ subscription: Subscription) {
    end(subscription, error: .init(.resync, "This subscription fell behind. Subscribe again.", retryable: true))
  }

  private func drop(subscription id: String) {
    outbox.removeAll { item in
      guard item.subscription == id else { return false }
      queuedBytes -= item.data.count; return true
    }
  }

  private static func supersedes(_ item: StreamItem, _ queued: StreamFrame) -> Bool {
    guard case .item(let other) = queued else { return false }
    switch (item.payload, other.payload) {
    case (.transcript, .transcript), (.conversations, .conversations), (.pending, .pending), (.capabilities, .capabilities): return true
    default: return false
    }
  }

  /// `queued` with `item` applied: entities by ID, the latest whole lists and run state.
  static func merge(_ queued: StreamItem, _ item: StreamItem) -> StreamItem? {
    var result = queued
    switch (queued.payload, item.payload) {
    case (.transcript(let old), .transcript(let new)):
      var transcript = old.transcript
      let removed = Set((old.transcript.removedMessageIDs ?? []) + (new.transcript.removedMessageIDs ?? []))
      transcript.messages = upsert(old.transcript.messages, new.transcript.messages).filter { !removed.contains($0.id) }
      transcript.activities = upsert(old.transcript.activities, new.transcript.activities)
      transcript.activeRunID = new.transcript.activeRunID
      transcript.runs = new.transcript.runs ?? old.transcript.runs
      transcript.removedMessageIDs = removed.isEmpty ? nil : removed.sorted()
      result.payload = .transcript(.init(transcript: transcript, snapshot: old.snapshot || new.snapshot))
    case (.conversations(let old), .conversations(let new)):
      let deleted = Set(new.deletedConversationIDs ?? [])
      let upserted = upsert(old.conversations, new.conversations).filter { !deleted.contains($0.id) }
      let present = Set(upserted.map(\.id))
      let removals = Set((old.deletedConversationIDs ?? []) + Array(deleted)).subtracting(present)
      result.payload = .conversations(.init(conversations: upserted, deletedConversationIDs: removals.isEmpty ? nil : removals.sorted(),
                                            snapshot: old.snapshot || new.snapshot))
    case (.pending, .pending), (.capabilities, .capabilities): result.payload = item.payload
    default: return nil
    }
    return result
  }

  private static func upsert<Value: Identifiable>(_ old: [Value], _ new: [Value]) -> [Value] where Value.ID == String {
    var values = old
    var positions = Dictionary(values.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, last in last })
    for value in new {
      if let index = positions[value.id] { values[index] = value }
      else { positions[value.id] = values.count; values.append(value) }
    }
    return values
  }

  private func pump() {
    guard !writing, !closed, !outbox.isEmpty else { return }
    let next = outbox.removeFirst()
    queuedBytes -= next.data.count
    writing = true
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
    connection.send(content: next.data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
      Task { await self?.written(error) }
    })
  }

  private func written(_ error: NWError?) async {
    writing = false
    if error != nil { await close(nil); return }
    pump()
  }
}
#endif
