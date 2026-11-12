import Foundation
import WovenMatterCore
import WovenMatterShared

/// What a `conversation` subscription reads. A member's WebSocket reads the
/// sessions this Mac runs; a window's Unix socket reads those and, through
/// this Mac's server, the sessions other machines run.
@MainActor public protocol ExecutionConversationSource: AnyObject, Sendable {
  func localTranscript(conversationID: String, before: String?) async throws -> LibraryTranscript
  func localCapabilities(conversationID: String) async throws -> HarnessCapabilities
  /// The session's settings, in the shape of the `.session` workspace read.
  func localSessionSettings(conversationID: String) async throws -> SessionSettings
  /// A window's socket only, for a session another machine runs: its
  /// questions and approvals and whether this server reaches that machine.
  /// Nil everywhere else, and no `pending` or `owner` items are sent.
  func conversationRelay(conversationID: String) async -> ExecutionConversationRelay?
  /// A subscription to this conversation opened, before its first read. A
  /// thrown error ends the subscription.
  func conversationOpened(_ conversationID: String) async throws
  /// A subscription opened with `conversationOpened` ended.
  func conversationClosed(_ conversationID: String) async
}

public extension ExecutionConversationSource {
  func conversationRelay(conversationID: String) async -> ExecutionConversationRelay? { nil }
  func conversationOpened(_ conversationID: String) async throws {}
  func conversationClosed(_ conversationID: String) async {}
}

/// The relayed state of a session another machine runs (window sockets only).
public struct ExecutionConversationRelay: Equatable, Sendable {
  public var interactions: [PendingInteraction]
  public var owner: StreamOwner
  public init(interactions: [PendingInteraction], owner: StreamOwner) { self.interactions = interactions; self.owner = owner }
}

/// The background server's `server.state` changes, which every window's
/// `server.state` subscription receives.
public actor ExecutionServerStateFeed {
  private var listeners: [UUID: @Sendable (StreamServerState) async -> Void] = [:]
  public init() {}
  public func publish(_ state: StreamServerState) async {
    for listener in listeners.values { await listener(state) }
  }
  func add(_ id: UUID, _ listener: @escaping @Sendable (StreamServerState) async -> Void) { listeners[id] = listener }
  func remove(_ id: UUID) { listeners.removeValue(forKey: id) }
  public var listenerCount: Int { listeners.count }
}

/// One socket's way out and in: a member's WebSocket or a window's
/// length-prefixed Unix socket. The session it serves is the same.
protocol ExecutionStreamWire: AnyObject, Sendable {
  /// Starts reading. Every frame and the end of the socket go to `session`.
  func start(_ session: StreamSession)
  /// Sends one encoded frame; `completion` says whether it was written.
  func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void)
  /// Whether the wire has ping and pong. One without them (a Unix socket)
  /// relies on the socket itself: a closed peer ends its read.
  var pings: Bool { get }
  /// Sends a ping and calls `pong` when it is answered.
  func ping(_ pong: @escaping @Sendable () -> Void)
  /// Closes with `code` (a WebSocket close frame), or at once when nil.
  func close(_ code: StreamProtocol.CloseCode?)
}

/// What a wire hands its session.
enum StreamWireInput: Sendable {
  case frame(StreamFrame)
  /// A control frame or any other sign of life.
  case heard
  /// The socket ended, with the close code to answer (none when it failed).
  case closed(StreamProtocol.CloseCode?)
}

/// What one stream socket is served by.
struct StreamSessionContext: Sendable {
  let configuration: ExecutionStreamConfiguration
  let conversations: any ExecutionConversationSource
  /// The `workspace` stream and the execution methods: member sockets only.
  let workspace: (any ExecutionStreamSource)?
  let members: MemberDirectory?
  let registry: MemberSocketRegistry?
  let tail: ExecutionStreamTail
  /// The `server.state` stream: window sockets only.
  let serverState: ExecutionServerStateFeed?
  let hello: @Sendable () async -> StreamHello
  let ended: @Sendable (UUID) -> Void
  /// The mobile library change cursor for `library` items on `workspace`
  /// subscriptions (member sockets only).
  var libraryCursor: (@Sendable () async -> Int64?)? = nil
}

/// One stream socket: its subscriptions, calls and bounded outbound queue.
actor StreamSession {
  /// Member kinds a WebSocket may belong to, as for `/v1/execution/*`.
  static let memberKinds: Set<MemberKind> = [.mac, .ios, .linux]
  nonisolated let id = UUID()
  private let context: StreamSessionContext
  private let wire: any ExecutionStreamWire
  /// The signed member on a WebSocket; nil on a window's Unix socket.
  let member: LibraryMember?
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

  init(context: StreamSessionContext, wire: any ExecutionStreamWire, member: LibraryMember?) {
    self.context = context; self.wire = wire; self.member = member; configuration = context.configuration
  }

  // MARK: Lifetime

  func begin() async {
    if let member, let registry = context.registry {
      registration = await registry.register(deviceID: member.deviceID, kinds: Self.memberKinds) { [weak self] in
        Task { await self?.close(.memberRemoved) }
      }
    }
    guard !closed else { if let registration { await context.registry?.unregister(registration) }; return }
    await context.tail.add(id) { [weak self] event in await self?.apply(event) }
    enqueue(.hello(await context.hello()))
    wire.start(self)
    guard wire.pings else { return }
    tasks.append(Task { [weak self, configuration] in
      while !Task.isCancelled {
        try? await Task.sleep(for: configuration.pingInterval)
        guard !Task.isCancelled, let self else { return }
        guard await self.keepAlive() else { return }
      }
    })
  }

  /// Sends a close frame with `code` (none for a connection that already
  /// failed), then closes the connection.
  func close(_ code: StreamProtocol.CloseCode?) async {
    guard !closed else { return }
    closed = true
    for task in tasks { task.cancel() }
    tasks.removeAll()
    let ending = Array(subscriptions.values)
    for subscription in ending { subscription.task?.cancel() }
    subscriptions.removeAll(); outbox.removeAll(); queuedBytes = 0
    for subscription in ending { await released(subscription) }
    await context.tail.remove(id)
    if let registration { await context.registry?.unregister(registration) }
    context.ended(id)
    wire.close(code)
  }

  /// False once the socket is closing.
  private func keepAlive() -> Bool {
    guard !closed else { return false }
    if ContinuousClock.now - lastHeard > configuration.pongTimeout {
      Task { await close(.goingAway) }
      return false
    }
    wire.ping { [weak self] in Task { await self?.heard() } }
    return true
  }

  private func heard() { lastHeard = .now }

  // MARK: Receiving

  /// One input from the wire; false once the socket is closing.
  func deliver(_ input: StreamWireInput) async -> Bool {
    guard !closed else { return false }
    lastHeard = .now
    switch input {
    case .heard: return true
    case .closed(let code): await close(code); return false
    case .frame(let frame): handle(frame); return true
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
        Task { await released(subscription) }
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
    guard let source = context.workspace, let member, let members = context.members else {
      // A window sends its commands through the background service's own command call.
      enqueue(.response(.init(id: request.id, error: .init(.invalid, "Send commands through the background service."))))
      return
    }
    calls.insert(request.id)
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
    enum Kind { case workspace, conversation(String), serverState }
    let id: String
    let kind: Kind
    var task: Task<Void, Never>?
    var dirty = false
    var dirtyAgain = false
    var snapshotDone = false
    var lastSend: ContinuousClock.Instant?
    var lastLarge = false
    /// `conversationOpened` succeeded, so `conversationClosed` is owed.
    var opened = false
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
    /// Conversation: the settings were last sent, and whether to read them again.
    var session: SessionSettings?
    var sessionDirty = true
    var owner: StreamOwner?
    /// Workspace: the library cursor last sent, and the newest one announced.
    var library: Int64?
    var latestLibrary: Int64?
    /// `server.state`: where this subscription listens.
    var feed: (ExecutionServerStateFeed, UUID)?
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
    case .workspace?:
      guard context.workspace != nil else {
        enqueue(.end(.init(id: request.id, error: .init(.invalid, "A window reads its lists from its projection; follow server.state.")))); return
      }
      kind = .workspace
    case .conversation?:
      guard let id = request.params.conversationID, !id.isEmpty else {
        enqueue(.end(.init(id: request.id, error: .init(.invalid, "Name the conversation to subscribe to.")))); return
      }
      kind = .conversation(id)
    case .serverState?:
      guard let feed = context.serverState else {
        enqueue(.end(.init(id: request.id, error: .init(.invalid, "server.state is served only to this Mac's own windows.")))); return
      }
      let subscription = Subscription(id: request.id, kind: .serverState)
      subscriptions[request.id] = subscription
      let key = UUID(), subscriptionID = request.id
      subscription.task = Task { [weak self] in
        await feed.add(key) { [weak self] state in await self?.serverStateChanged(subscriptionID, state) }
        await self?.serverStateOpened(subscriptionID, feed: feed, key: key)
      }
      return
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

  /// `server.state`: from here on every change is sent. `synchronized` comes
  /// first and tells the window to read everything again from its projection.
  private func serverStateOpened(_ id: String, feed: ExecutionServerStateFeed, key: UUID) async {
    guard let subscription = subscriptions[id] else { await feed.remove(key); return }
    subscription.task = nil
    subscription.feed = (feed, key)
    subscription.snapshotDone = true
    enqueue(.item(.init(id: id, payload: .synchronized)), for: subscription)
  }

  private func serverStateChanged(_ id: String, _ state: StreamServerState) {
    guard let subscription = subscriptions[id], subscription.snapshotDone else { return }
    enqueue(.item(.init(id: id, payload: .serverState(state))), for: subscription)
  }

  /// The subscription is gone: its feed listener and its opened conversation are released.
  private func released(_ subscription: Subscription) async {
    if let (feed, key) = subscription.feed { await feed.remove(key) }
    subscription.feed = nil
    if subscription.opened, case .conversation(let id) = subscription.kind {
      subscription.opened = false
      let source = context.conversations
      await source.conversationClosed(id)
    }
  }

  private func apply(_ event: ExecutionStreamEvent) {
    for subscription in subscriptions.values {
      switch (event, subscription.kind) {
      case (_, .serverState): continue
      case (.library(let cursor), .workspace):
        subscription.latestLibrary = max(subscription.latestLibrary ?? cursor, cursor)
        if subscription.snapshotDone { sendLibrary(subscription) }
      case (.library, _): continue
      case (.reset, .workspace): subscription.reloadAll = true; markDirty(subscription)
      case (.reset, _): subscription.sessionDirty = true; markDirty(subscription)
      case (.changes(let changes), .workspace):
        // Summaries change with the conversation row and its runs; questions
        // and approvals start and end with runs and their events.
        let relevant = changes.filter { !$0.value.isDisjoint(with: ["conversation", "run", "run_event"]) }
        guard !relevant.isEmpty else { continue }
        subscription.changedConversations.formUnion(relevant.keys)
        markDirty(subscription)
      case (.changes(let changes), .conversation(let id)):
        guard let kinds = changes[id] else { continue }
        // Settings live with the session row, its runs (whether it can be
        // configured), and its goal and tool rows; not with messages.
        if !kinds.isDisjoint(with: ["conversation", "run", "session"]) { subscription.sessionDirty = true }
        markDirty(subscription)
      case (.live, .workspace): markDirty(subscription)
      case (.live(let ids), .conversation(let id)):
        guard ids.isEmpty || ids.contains(id) else { continue }
        subscription.sessionDirty = true
        markDirty(subscription)
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
      case .serverState: break
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
    guard let source = context.workspace else { return }
    if !subscription.snapshotDone {
      let conversations = try await source.localConversations()
      let pending = try await source.localPendingInteractions()
      try Task.checkCancellation()
      subscription.conversations = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      subscription.pending = pending
      enqueue(.item(.init(id: subscription.id, payload: .conversations(.init(conversations: conversations, snapshot: true)))), for: subscription)
      enqueue(.item(.init(id: subscription.id, payload: .pending(.init(interactions: pending)))), for: subscription)
      // The library cursor, so a phone knows at once whether its copy is current.
      if let cursor = await context.libraryCursor?() {
        subscription.latestLibrary = max(subscription.latestLibrary ?? cursor, cursor)
      }
      try Task.checkCancellation()
      sendLibrary(subscription)
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
    let source = context.conversations
    if !subscription.opened {
      try await source.conversationOpened(conversationID)
      // Ended while it opened: `released` already ran, so close it here.
      guard subscriptions[subscription.id] === subscription, !closed else {
        await source.conversationClosed(conversationID); throw CancellationError()
      }
      subscription.opened = true
    }
    let transcript = try await source.localTranscript(conversationID: conversationID, before: nil)
    let capabilities = try? await source.localCapabilities(conversationID: conversationID)
    let readsSession = subscription.sessionDirty
    subscription.sessionDirty = false
    let session = readsSession ? try? await source.localSessionSettings(conversationID: conversationID) : nil
    let relay = await source.conversationRelay(conversationID: conversationID)
    try Task.checkCancellation()
    let id = subscription.id
    if !subscription.snapshotDone {
      remember(transcript, in: subscription)
      enqueue(.item(.init(id: id, payload: .transcript(.init(transcript: transcript, snapshot: true)))), for: subscription)
      if let capabilities {
        subscription.capabilities = capabilities
        enqueue(.item(.init(id: id, payload: .capabilities(.init(capabilities: capabilities)))), for: subscription)
      }
      sendLiveState(session: session, relay: relay, to: subscription)
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
    sendLiveState(session: session, relay: relay, to: subscription)
  }

  /// The newest library cursor, unless this subscriber already has it.
  private func sendLibrary(_ subscription: Subscription) {
    guard let cursor = subscription.latestLibrary, cursor != subscription.library else { return }
    subscription.library = cursor
    enqueue(.item(.init(id: subscription.id, payload: .library(.init(cursor: cursor)))), for: subscription)
  }

  /// Session settings, and a relayed session's questions and owner, when they changed.
  private func sendLiveState(session: SessionSettings?, relay: ExecutionConversationRelay?, to subscription: Subscription) {
    let id = subscription.id
    if let session, session != subscription.session {
      subscription.session = session
      enqueue(.item(.init(id: id, payload: .session(.init(settings: session)))), for: subscription)
    }
    guard let relay else { return }
    if relay.interactions != subscription.pending {
      subscription.pending = relay.interactions
      enqueue(.item(.init(id: id, payload: .pending(.init(interactions: relay.interactions)))), for: subscription)
    }
    if relay.owner != subscription.owner {
      subscription.owner = relay.owner
      enqueue(.item(.init(id: id, payload: .owner(relay.owner))), for: subscription)
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
    Task { await released(subscription) }
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
    case (.transcript, .transcript), (.conversations, .conversations), (.pending, .pending), (.capabilities, .capabilities),
         (.session, .session), (.owner, .owner), (.library, .library), (.serverState, .serverState): return true
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
    case (.serverState(let old), .serverState(let new)):
      // Invalidations accumulate: the window reads each scope and conversation once.
      func union(_ first: [String], _ second: [String]) -> [String] { first + second.filter { !first.contains($0) } }
      let conversations = old.conversationIDs == nil && new.conversationIDs == nil ? nil
        : union(old.conversationIDs ?? [], new.conversationIDs ?? [])
      result.payload = .serverState(.init(scopes: union(old.scopes, new.scopes), conversationIDs: conversations))
    case (.pending, .pending), (.capabilities, .capabilities), (.session, .session), (.owner, .owner), (.library, .library):
      result.payload = item.payload
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
    wire.send(next.data) { [weak self] written in
      Task { await self?.written(written) }
    }
  }

  private func written(_ success: Bool) async {
    writing = false
    if !success { await close(nil); return }
    pump()
  }
}
