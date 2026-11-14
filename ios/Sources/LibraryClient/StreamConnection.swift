import Foundation
import WovenMatterShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One frame channel to one Woven server (docs/architecture/WOVEN_EVERYWHERE.md,
/// "Streaming"). A member-signed WebSocket (`WebSocketStreamTransport`) reaches
/// another machine; a Mac window reaches its own server over the length-prefixed
/// Unix socket (`LengthPrefixedStreamTransport`). Each value is one socket: a
/// reconnect makes a new transport.
public protocol StreamTransport: Sendable {
  /// The next frame. Throws `StreamTransportClosed` when the socket closes, or a
  /// `StreamConnectionError` when the server refused the upgrade.
  func receive() async throws -> StreamFrame
  func send(_ frame: StreamFrame) async throws
  /// Returns when the pong arrives. A transport without control frames returns at once.
  func ping() async throws
  func close(_ code: StreamProtocol.CloseCode) async
}

/// The socket closed. `code` is the WebSocket close code when there was one.
public struct StreamTransportClosed: Error, Equatable, Sendable {
  public var code: Int?
  public var reason: String?
  public init(code: Int? = nil, reason: String? = nil) { self.code = code; self.reason = reason }
}

public enum StreamConnectionError: Error, Equatable, Sendable, LocalizedError {
  /// Nothing was sent: the connection is not open.
  case notConnected
  /// The socket closed before the reply arrived. A command's outcome is unknown.
  case disconnected
  /// No reply in time. A command's outcome is unknown.
  case timedOut
  /// Close code 4401: this device is no longer a member there. No retry until the member list changes.
  case memberRemoved
  /// 401 `member_time_stale`: this device's clock is outside the signature window.
  case memberTimeStale(serverTime: Int64?)
  /// 426 `protocol_unsupported`.
  case protocolUnsupported(supported: [Int])
  /// 401 `unauthorized`: the server does not list this device yet.
  case unauthorized
  /// Any other refusal before the upgrade.
  case refused(status: Int, code: String?, message: String?)
  /// The server answered a call with an error.
  case remote(StreamError)
  /// Only private tailnet HTTPS endpoints are streamed to.
  case insecureEndpoint

  /// The request may have reached the server: a command becomes `outcomeUnknown`.
  public var outcomeUnknown: Bool { self == .disconnected || self == .timedOut }

  public var errorDescription: String? {
    switch self {
    case .notConnected: "Not connected yet. Woven Matter reconnects automatically."
    case .disconnected: "The connection closed before the reply arrived."
    case .timedOut: "The reply took too long."
    case .memberRemoved: "This device was removed from the library on that machine."
    case .memberTimeStale: "This device's clock is wrong. Set the date and time automatically, then try again."
    case .protocolUnsupported: "Update Woven Matter on every device."
    case .unauthorized: "That machine does not recognize this device yet. It does once the two synchronize their member list."
    case .refused(let status, _, let message): message ?? "The connection was refused (\(status))."
    case .remote(let error): error.message
    case .insecureEndpoint: "Other devices are reached only at private tailnet HTTPS addresses."
    }
  }

  /// Maps an HTTP refusal before the upgrade. `X-Woven-Error` (the refusal's
  /// code) is the primary signal: `URLSessionWebSocketTask` cannot read a
  /// refused upgrade's body. `body` is the JSON reply when a transport can read
  /// it. A server that sends no code is judged by its status, and a 401 whose
  /// `Date` is outside the signature window is still reported as a stale clock.
  public static func refusal(status: Int, body: Data? = nil, headers: [String: String] = [:],
                             now: Date = Date()) -> StreamConnectionError {
    struct Reply: Decodable { var code: String?; var error: String?; var message: String?; var serverTime: Int64?; var supported: [Int]? }
    let reply = body.flatMap { try? JSONDecoder().decode(Reply.self, from: $0) }
    let header = { (name: String) in headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
    let code = header("X-Woven-Error").map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
      ?? reply?.code ?? reply?.error
    let serverDate = header("Date").flatMap(Self.httpDate)
    switch code.flatMap(StreamProtocol.ErrorCode.init(rawValue:)) {
    case .memberTimeStale?: return .memberTimeStale(serverTime: reply?.serverTime ?? serverDate.map(Self.milliseconds))
    case .protocolUnsupported?: return .protocolUnsupported(supported: reply?.supported ?? [])
    case .unauthorized?: return .unauthorized
    case .unavailable?:
      return .refused(status: status, code: StreamProtocol.ErrorCode.unavailable.rawValue,
                      message: reply?.message ?? "That machine is not ready to stream yet. Woven Matter reconnects automatically.")
    default: break
    }
    switch status {
    case 426: return .protocolUnsupported(supported: reply?.supported ?? [])
    case 401:
      if code == nil, let date = serverDate,
         abs(Self.milliseconds(date) - Self.milliseconds(now)) > MemberRequestSignature.windowMilliseconds {
        return .memberTimeStale(serverTime: Self.milliseconds(date))
      }
      return .unauthorized
    default: return .refused(status: status, code: code, message: reply?.message)
    }
  }

  /// A refused upgrade's response, as `URLSessionWebSocketTask` exposes it
  /// (headers, no body); nil for `101 Switching Protocols`.
  public static func refusal(_ response: HTTPURLResponse, now: Date = Date()) -> StreamConnectionError? {
    guard response.statusCode != 101 else { return nil }
    var headers: [String: String] = [:]
    for (name, value) in response.allHeaderFields { headers[String(describing: name)] = String(describing: value) }
    return refusal(status: response.statusCode, headers: headers, now: now)
  }

  private static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
  private static func httpDate(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: text)
  }
}

/// What a subscriber did with one item.
public enum StreamItemDisposition: Sendable, Equatable {
  /// Taken. A journal `seq` advances the subscription's `after`.
  case accepted
  /// Not applied (a journal gap): subscribe again with these parameters.
  case resubscribe(StreamSubscribeParams)
}

public enum StreamSubscriptionEvent: Sendable, Equatable {
  case item(StreamItem)
  /// The server ended the subscription for good: an end with no error or a
  /// non-retryable one. The subscription is gone; nothing asks for it again.
  /// A `resync` or a retryable end is never delivered: the connection
  /// subscribes again by itself.
  case ended(StreamError?)
}

/// One subscription, stable across reconnects (its wire ID changes per socket).
public struct StreamSubscription: Hashable, Sendable {
  public let key: Int
}

/// One connection from a client to one Woven server. It owns reconnection
/// (backoff 1 s to 30 s with jitter, reset once a connection has stayed open
/// for `stableInterval`; an immediate attempt on demand; nothing after close
/// code 4401 until the member list changes), fails an attempt whose `hello`
/// does not arrive within `helloTimeout`, pings every 25 s and drops a socket
/// whose pong does not arrive within `pongTimeout`, re-sends every
/// subscription after a reconnect with its latest `after`, subscribes again
/// after a `resync` or retryable end (repeated ones back off), and correlates
/// `req` / `res`. Calls are never replayed: one in flight when the socket
/// closes fails with `disconnected`.
public actor StreamConnection {
  /// Opens one socket. Called afresh for every attempt, so a member-signed
  /// upgrade is signed again each time (a signature's nonce is single use).
  public typealias Connect = @Sendable () async throws -> any StreamTransport
  /// Items arrive in order: the next frame is read once the handler returns.
  /// A handler must not wait on a call on the same connection (its reply would
  /// wait behind the handler); start one in a separate task instead.
  public typealias Handler = @Sendable (StreamSubscriptionEvent) async -> StreamItemDisposition
  public typealias Sleep = @Sendable (Duration) async throws -> Void

  public enum State: Equatable, Sendable {
    /// Not started, or stopped.
    case idle
    case connecting
    case open(StreamHello)
    /// Between attempts; the last attempt's failure.
    case waiting(StreamConnectionError?)
    /// Close code 4401. Waits for `membersChanged()`.
    case memberRemoved
  }

  public struct Configuration: Sendable {
    public var pingInterval: Duration
    /// How long a ping may wait for its pong before the socket is treated as gone.
    public var pongTimeout: Duration
    public var requestTimeout: Duration
    /// How long a call waits for a connection that is still opening.
    public var openWait: Duration
    /// How long an attempt may take from its start (the upgrade included) to
    /// the server's `hello` before it fails and the backoff runs.
    public var helloTimeout: Duration
    /// How long a connection, or a subscription after a retried end, must
    /// last before its backoff starts again from the first step.
    public var stableInterval: Duration
    /// Waits between attempts, and before a repeated subscription retry (tests replace it).
    public var retrySleep: Sleep
    public var random: @Sendable () -> Double
    public init(pingInterval: Duration = StreamProtocol.pingInterval, pongTimeout: Duration = .seconds(20),
                requestTimeout: Duration = .seconds(30), openWait: Duration = .seconds(10),
                helloTimeout: Duration = .seconds(30), stableInterval: Duration = .seconds(30),
                retrySleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
      self.pingInterval = pingInterval; self.pongTimeout = pongTimeout; self.requestTimeout = requestTimeout
      self.openWait = openWait; self.helloTimeout = helloTimeout; self.stableInterval = stableInterval
      self.retrySleep = retrySleep; self.random = random
    }
  }

  /// Every state change, in order.
  public nonisolated let states: AsyncStream<State>
  private let stateContinuation: AsyncStream<State>.Continuation
  private let connect: Connect
  private let configuration: Configuration
  public private(set) var state = State.idle
  public private(set) var hello: StreamHello?

  private struct Subscription {
    var stream: StreamProtocol.Stream
    var params: StreamSubscribeParams
    let handler: Handler
    var wireID: String?
    /// Retried ends (`resync`, retryable errors, a subscriber's gap) in a row.
    var retries = 0
    var lastRetry: ContinuousClock.Instant?
    var retryTask: Task<Void, Never>?
  }
  private var running = false
  private var memberRemoved = false
  private var generation = 0
  private var attempt = 0
  private var transport: (any StreamTransport)?
  private var greeted = false
  private var retryTask: Task<Void, Never>?
  private var pingTask: Task<Void, Never>?
  private var helloTask: Task<Void, Never>?
  private var stableTask: Task<Void, Never>?
  /// The generation whose pong is awaited: one probe per socket at a time.
  private var probing: Int?
  private var nextKey = 0
  private var nextWireID = 0
  private var nextRequestID = 0
  private var subscriptions: [Int: Subscription] = [:]
  private var wire: [String: Int] = [:]
  private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
  private var deadlines: [String: Task<Void, Never>] = [:]
  private var openWaiters: [Int: CheckedContinuation<Void, any Error>] = [:]
  private var nextWaiter = 0

  public init(configuration: Configuration = .init(), connect: @escaping Connect) {
    self.connect = connect; self.configuration = configuration
    (states, stateContinuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .unbounded)
  }

  deinit { stateContinuation.finish() }

  public var isOpen: Bool { if case .open = state { true } else { false } }

  /// The wait before attempt `attempt + 1`: 1 s doubling to 30 s, each with
  /// ±25 % jitter, never outside 1 s to 30 s.
  public static func retryDelay(attempt: Int, random: Double) -> Duration {
    let base = min(30, pow(2, Double(min(max(attempt, 0), 5))))
    let seconds = min(30, max(1, base * (0.75 + 0.5 * min(max(random, 0), 1))))
    return .milliseconds(Int64((seconds * 1000).rounded()))
  }

  // MARK: Lifecycle

  public func start() {
    guard !running else { return }
    running = true
    guard !memberRemoved else { setState(.memberRemoved); return }
    attempt = 0
    open()
  }

  /// Closes cleanly (1000) and stays closed until `start()`. Subscriptions are kept.
  public func stop() async {
    running = false
    generation += 1
    retryTask?.cancel(); retryTask = nil
    let socket = transport
    transport = nil
    dropSocketState()
    failPending(.disconnected)
    failOpenWaiters(.notConnected)
    setState(.idle)
    await socket?.close(.normal)
  }

  /// Wake, a network path change or the app coming to the foreground: try
  /// now instead of waiting out the backoff, and check an open socket with a ping.
  public func connectNow() {
    guard running, !memberRemoved else { return }
    if transport != nil {
      if greeted { let current = generation; Task { await self.probe(current) } }
      return
    }
    if case .connecting = state { return }
    attempt = 0
    open()
  }

  /// The member list changed: a connection closed with 4401 may try again,
  /// and one waiting after a refusal tries now.
  public func membersChanged() {
    guard memberRemoved else { connectNow(); return }
    memberRemoved = false
    attempt = 0
    if running { open() } else { setState(.idle) }
  }

  private func open() {
    retryTask?.cancel(); retryTask = nil
    generation += 1
    let current = generation
    greeted = false
    setState(.connecting)
    // An upgrade or hello that never comes fails the attempt, so the backoff
    // (and `connectNow()`) is never stuck behind a hung handshake.
    let limit = configuration.helloTimeout
    helloTask?.cancel()
    helloTask = Task {
      do { try await Task.sleep(for: limit) } catch { return }
      await self.helloOverdue(generation: current)
    }
    let connect = self.connect
    Task {
      do {
        let socket = try await connect()
        await self.connected(socket, generation: current)
      } catch {
        await self.attemptFailed(error, generation: current)
      }
    }
  }

  private func connected(_ socket: any StreamTransport, generation current: Int) async {
    guard current == generation, running else { await socket.close(.normal); return }
    transport = socket
    Task { await self.receive(socket, generation: current) }
  }

  private func receive(_ socket: any StreamTransport, generation current: Int) async {
    while current == generation {
      let frame: StreamFrame
      do { frame = try await socket.receive() }
      catch { await lost(error, generation: current); return }
      guard current == generation else { return }
      await handle(frame, socket: socket, generation: current)
    }
  }

  private func attemptFailed(_ error: any Error, generation current: Int) async {
    guard current == generation, running else { return }
    transport = nil
    await settle(Self.classify(error), generation: current)
  }

  /// The open (or opening) socket is gone.
  private func lost(_ error: any Error, generation current: Int) async {
    guard current == generation, let socket = transport else { return }
    transport = nil
    await socket.close(.goingAway)
    await settle(Self.classify(error), generation: current)
  }

  /// No `hello` within `helloTimeout`: this attempt fails as a timeout. A
  /// late upgrade or frame from it is ignored (its generation is over).
  private func helloOverdue(generation current: Int) async {
    guard current == generation, running, !greeted else { return }
    let socket = transport
    transport = nil
    generation += 1
    await socket?.close(.goingAway)
    await settle(.timedOut, generation: generation)
  }

  /// What belongs to one socket: its greeting, timers and wire IDs.
  private func dropSocketState() {
    greeted = false; hello = nil; probing = nil
    pingTask?.cancel(); pingTask = nil
    helloTask?.cancel(); helloTask = nil
    stableTask?.cancel(); stableTask = nil
    wire.removeAll()
    for key in subscriptions.keys {
      subscriptions[key]?.wireID = nil
      subscriptions[key]?.retryTask?.cancel(); subscriptions[key]?.retryTask = nil
    }
  }

  private func settle(_ error: StreamConnectionError, generation current: Int) async {
    dropSocketState()
    failPending(.disconnected)
    // A call still waiting for the socket sent nothing: its outcome is known.
    failOpenWaiters(error.outcomeUnknown ? .notConnected : error)
    guard running else { setState(.idle); return }
    if error == .memberRemoved {
      memberRemoved = true
      setState(.memberRemoved)
      return
    }
    setState(.waiting(error))
    let delay = Self.retryDelay(attempt: attempt, random: configuration.random())
    attempt += 1
    let sleep = configuration.retrySleep
    retryTask = Task {
      do { try await sleep(delay) } catch { return }
      self.retry(generation: current)
    }
  }

  private func retry(generation current: Int) {
    guard current == generation, running, !memberRemoved, transport == nil else { return }
    open()
  }

  private static func classify(_ error: any Error) -> StreamConnectionError {
    if let error = error as? StreamConnectionError { return error }
    if let closed = error as? StreamTransportClosed, closed.code == StreamProtocol.CloseCode.memberRemoved.rawValue { return .memberRemoved }
    return .disconnected
  }

  /// One ping; a pong that does not arrive within `pongTimeout` drops the
  /// socket whether or not the transport's ping ever returns. One probe runs
  /// per socket: a wake while one is out does not stack another.
  private func probe(_ current: Int) async {
    guard current == generation, greeted, let socket = transport, probing != current else { return }
    probing = current
    let answered = await Self.pong(socket, within: configuration.pongTimeout)
    if probing == current { probing = nil }
    guard !answered else { return }
    await lost(StreamConnectionError.disconnected, generation: current)
  }

  /// Whether `socket` answered a ping in time. The ping runs in its own task,
  /// so a transport that never answers (a black-holed socket) cannot hold this up.
  private static func pong(_ socket: any StreamTransport, within timeout: Duration) async -> Bool {
    let outcome = ResumeOnce<Bool>()
    return await withCheckedContinuation { continuation in
      outcome.start(continuation)
      outcome.attach(Task { do { try await socket.ping(); outcome.resume(true) } catch { outcome.resume(false) } })
      outcome.attach(Task { do { try await Task.sleep(for: timeout) } catch { return }; outcome.resume(false) })
    }
  }

  // MARK: Frames

  private func handle(_ frame: StreamFrame, socket: any StreamTransport, generation current: Int) async {
    guard greeted else {
      guard case .hello(let value) = frame else {
        await lost(StreamConnectionError.refused(status: 101, code: "invalid", message: "The server did not say hello."), generation: current)
        return
      }
      guard StreamProtocol.supportedVersions.contains(value.protocol) else {
        await socket.close(.protocolViolation)
        await lost(StreamConnectionError.protocolUnsupported(supported: [value.protocol]), generation: current)
        return
      }
      greeted = true; hello = value
      helloTask?.cancel(); helloTask = nil
      setState(.open(value))
      for (_, waiter) in openWaiters { waiter.resume() }
      openWaiters.removeAll()
      startPings(generation: current)
      // A server that greets and then closes keeps backing off; the backoff
      // starts again only once a connection has lasted.
      let stable = configuration.stableInterval
      stableTask?.cancel()
      stableTask = Task {
        do { try await Task.sleep(for: stable) } catch { return }
        await self.stayedOpen(generation: current)
      }
      for key in subscriptions.keys.sorted() { await sendSubscription(key, socket: socket, generation: current) }
      return
    }
    switch frame {
    case .response(let response):
      deadlines.removeValue(forKey: response.id)?.cancel()
      guard let continuation = pending.removeValue(forKey: response.id) else { return }
      if let error = response.error { continuation.resume(throwing: StreamConnectionError.remote(error)) }
      else { continuation.resume(returning: response.result ?? .null) }
    case .item(let item):
      guard let key = wire[item.id], let subscription = subscriptions[key] else { return }
      let disposition = await subscription.handler(.item(item))
      guard current == generation, subscriptions[key]?.wireID == item.id else { return }
      switch disposition {
      case .accepted:
        if let seq = item.seq, let after = subscriptions[key]?.params.after { subscriptions[key]?.params.after = max(after, seq) }
      case .resubscribe(let params):
        await restart(key, params: params, socket: socket, generation: current)
      }
    case .end(let end):
      guard let key = wire.removeValue(forKey: end.id), let subscription = subscriptions[key] else { return }
      subscriptions[key]?.wireID = nil
      if end.error?.code == StreamProtocol.ErrorCode.resync.rawValue {
        // Behind: subscribe again from the latest `after`, at once the first time.
        await retrySubscription(key, immediately: true, generation: current)
      } else if end.error?.retryable == true {
        // A passing failure there (a store error, too many subscriptions):
        // the subscription comes back after a backoff and is not reported.
        await retrySubscription(key, immediately: false, generation: current)
      } else {
        subscriptions.removeValue(forKey: key)
        subscription.retryTask?.cancel()
        _ = await subscription.handler(.ended(end.error))
      }
    case .hello, .request, .subscribe, .cancel, .unknown:
      break
    }
  }

  private func startPings(generation current: Int) {
    pingTask?.cancel()
    let interval = configuration.pingInterval
    pingTask = Task {
      while !Task.isCancelled {
        do { try await Task.sleep(for: interval) } catch { return }
        await self.probe(current)
      }
    }
  }

  private func sendSubscription(_ key: Int, socket: any StreamTransport, generation current: Int) async {
    guard current == generation, var subscription = subscriptions[key] else { return }
    nextWireID += 1
    let id = "s\(nextWireID)"
    subscription.wireID = id
    subscriptions[key] = subscription
    wire[id] = key
    do { try await socket.send(.subscribe(.init(id: id, stream: subscription.stream, params: subscription.params))) }
    catch { await lost(error, generation: current) }
  }

  /// The subscriber asked for different parameters (a journal gap, its own
  /// cursor after a failed write): the old wire subscription is cancelled and
  /// the new one sent, at once the first time and after a backoff when it
  /// keeps happening, so a subscriber that cannot keep up does not loop.
  private func restart(_ key: Int, params: StreamSubscribeParams, socket: any StreamTransport, generation current: Int) async {
    guard subscriptions[key] != nil else { return }
    subscriptions[key]?.params = params
    if let old = subscriptions[key]?.wireID {
      wire.removeValue(forKey: old); subscriptions[key]?.wireID = nil
      do { try await socket.send(.cancel(.init(id: old))) } catch { await lost(error, generation: current); return }
    }
    await retrySubscription(key, immediately: true, generation: current)
  }

  /// Sends a subscription that is not on the wire again: now (`immediately`
  /// and the first retry in a row), or after the backoff for this many
  /// retries. A subscription that lasted `stableInterval` after its last
  /// retry was sent counts from the first again; the time is measured from
  /// the send, not from when the retry was scheduled, so a capped 30 s wait
  /// never resets the count by itself. A reconnect meanwhile sends it with
  /// every other subscription.
  private func retrySubscription(_ key: Int, immediately: Bool, generation current: Int) async {
    guard var subscription = subscriptions[key], subscription.wireID == nil else { return }
    let now = ContinuousClock.now
    if let sent = subscription.lastRetry, now - sent > configuration.stableInterval { subscription.retries = 0 }
    let count = subscription.retries
    let delay: Duration = immediately && count == 0 ? .zero
      : Self.retryDelay(attempt: immediately ? count - 1 : count, random: configuration.random())
    subscription.retries += 1; subscription.lastRetry = now + delay
    subscription.retryTask?.cancel(); subscription.retryTask = nil
    subscriptions[key] = subscription
    if immediately && count == 0 {
      guard greeted, let socket = transport else { return }
      await sendSubscription(key, socket: socket, generation: current)
      return
    }
    let sleep = configuration.retrySleep
    subscriptions[key]?.retryTask = Task {
      do { try await sleep(delay) } catch { return }
      await self.retryDue(key, generation: current)
    }
  }

  private func retryDue(_ key: Int, generation current: Int) async {
    guard current == generation, greeted, let socket = transport, subscriptions[key]?.wireID == nil else { return }
    subscriptions[key]?.retryTask = nil
    await sendSubscription(key, socket: socket, generation: current)
  }

  /// The connection lasted: the next disconnect waits from the first step again.
  private func stayedOpen(generation current: Int) {
    guard current == generation, greeted else { return }
    attempt = 0
  }

  // MARK: Subscriptions

  /// Subscribes now if open, and again after every reconnect. With `after`
  /// set, each accepted item's `seq` advances it.
  @discardableResult
  public func subscribe(_ stream: StreamProtocol.Stream, params: StreamSubscribeParams = .init(),
                        handler: @escaping Handler) async -> StreamSubscription {
    nextKey += 1
    let key = nextKey
    subscriptions[key] = .init(stream: stream, params: params, handler: handler)
    if greeted, let socket = transport { await sendSubscription(key, socket: socket, generation: generation) }
    return StreamSubscription(key: key)
  }

  /// Subscribes again with new parameters (a journal gap, a new cursor).
  public func resubscribe(_ subscription: StreamSubscription, params: StreamSubscribeParams) async {
    guard subscriptions[subscription.key] != nil else { return }
    if greeted, let socket = transport { await restart(subscription.key, params: params, socket: socket, generation: generation) }
    else { subscriptions[subscription.key]?.params = params }
  }

  public func unsubscribe(_ subscription: StreamSubscription) async {
    guard let removed = subscriptions.removeValue(forKey: subscription.key) else { return }
    removed.retryTask?.cancel()
    guard let id = removed.wireID else { return }
    wire.removeValue(forKey: id)
    if greeted, let socket = transport {
      do { try await socket.send(.cancel(.init(id: id))) } catch { await lost(error, generation: generation) }
    }
  }

  /// The parameters the next (re)subscription sends.
  public func parameters(_ subscription: StreamSubscription) -> StreamSubscribeParams? { subscriptions[subscription.key]?.params }

  // MARK: Calls

  /// One call. Waits up to `openWait` for a connection that is opening; never
  /// queued past that and never replayed.
  public func request(_ method: String, params: JSONValue = .object([:]), timeout: Duration? = nil) async throws -> JSONValue {
    let socket = try await openSocket()
    let current = generation
    nextRequestID += 1
    let id = "r\(nextRequestID)"
    let limit = timeout ?? configuration.requestTimeout
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      deadlines[id] = Task {
        do { try await Task.sleep(for: limit) } catch { return }
        await self.expire(id, generation: current)
      }
      Task {
        do { try await socket.send(.request(.init(id: id, method: method, params: params))) }
        catch { await self.lost(error, generation: current) }
      }
    }
  }

  public func request<Params: Encodable & Sendable, Result: Decodable>(_ method: StreamProtocol.Method, _ params: Params,
      as type: Result.Type, timeout: Duration? = nil) async throws -> Result {
    try await request(method.rawValue, params: JSONValue(encoding: params), timeout: timeout).decode(type)
  }

  private func openSocket() async throws -> any StreamTransport {
    if greeted, let transport { return transport }
    guard running, !memberRemoved else { throw memberRemoved ? StreamConnectionError.memberRemoved : StreamConnectionError.notConnected }
    nextWaiter += 1
    let key = nextWaiter
    let wait = configuration.openWait
    let timer = Task {
      do { try await Task.sleep(for: wait) } catch { return }
      self.failOpenWaiter(key, .notConnected)
    }
    defer { timer.cancel() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      openWaiters[key] = continuation
    }
    guard greeted, let transport else { throw StreamConnectionError.notConnected }
    return transport
  }

  private func expire(_ id: String, generation current: Int) async {
    deadlines.removeValue(forKey: id)
    guard let continuation = pending.removeValue(forKey: id) else { return }
    continuation.resume(throwing: StreamConnectionError.timedOut)
    if current == generation, greeted, let socket = transport { try? await socket.send(.cancel(.init(id: id))) }
  }

  private func failPending(_ error: StreamConnectionError) {
    let waiting = pending
    pending.removeAll()
    for (_, task) in deadlines { task.cancel() }
    deadlines.removeAll()
    for (_, continuation) in waiting { continuation.resume(throwing: error) }
  }

  private func failOpenWaiter(_ key: Int, _ error: StreamConnectionError) {
    openWaiters.removeValue(forKey: key)?.resume(throwing: error)
  }

  private func failOpenWaiters(_ error: StreamConnectionError) {
    let waiting = openWaiters
    openWaiters.removeAll()
    for (_, waiter) in waiting { waiter.resume(throwing: error) }
  }

  private func setState(_ next: State) {
    guard next != state else { return }
    state = next
    stateContinuation.yield(next)
  }
}

/// Resumes a continuation once, with the first value offered, and cancels
/// the tasks racing to offer one.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Never>?
  private var finished = false
  private var tasks: [Task<Void, Never>] = []

  func start(_ continuation: CheckedContinuation<Value, Never>) { lock.withLock { self.continuation = continuation } }

  func attach(_ task: Task<Void, Never>) {
    let late = lock.withLock { () -> Bool in
      if finished { return true }
      tasks.append(task); return false
    }
    if late { task.cancel() }
  }

  func resume(_ value: Value) {
    let (continuation, tasks) = lock.withLock { () -> (CheckedContinuation<Value, Never>?, [Task<Void, Never>]) in
      guard !finished else { return (nil, []) }
      finished = true
      defer { self.continuation = nil; self.tasks = [] }
      return (self.continuation, self.tasks)
    }
    continuation?.resume(returning: value)
    for task in tasks { task.cancel() }
  }
}

// MARK: Execution methods

public extension StreamConnection {
  /// `execution.command`. A lost reply throws `disconnected` or `timedOut`.
  func command(_ command: LibraryCommand) async throws -> LibraryCommandReceipt {
    try await request(.executionCommand, StreamCommandParams(command: command), as: LibraryCommandReceipt.self)
  }

  /// `execution.receipt`: nil when the server has no record of the command.
  func receipt(_ commandID: String) async throws -> LibraryCommandReceipt? {
    try await request(.executionReceipt, StreamReceiptParams(commandID: commandID), as: LibraryCommandReceipt?.self)
  }
}

/// Durable commands over a stream, with a `WorkspaceJournal` command journal:
/// the caller remembers the command first; a reply lost to a disconnect or a
/// timeout records `outcomeUnknown`, which is resolved with `execution.receipt`
/// after reconnecting. Nothing is resent automatically.
public enum StreamCommands {
  /// Sends a remembered command. `retrying`: the journal already held it, so
  /// its receipt is asked for first.
  public static func deliver(_ command: LibraryCommand, retrying: Bool, workspaceID: String, journal: WorkspaceJournal,
                             connection: StreamConnection) async throws -> LibraryCommandReceipt {
    if retrying, let existing = try await connection.receipt(command.commandID) { return existing }
    return try await send(command, workspaceID: workspaceID, journal: journal, connection: connection)
  }

  /// `execution.command` for a remembered command; a lost reply records `outcomeUnknown`.
  public static func send(_ command: LibraryCommand, workspaceID: String, journal: WorkspaceJournal,
                          connection: StreamConnection) async throws -> LibraryCommandReceipt {
    do { return try await connection.command(command) }
    catch let error as StreamConnectionError where error.outcomeUnknown {
      try? await journal.rememberReceipt(.init(commandID: command.commandID, deviceID: command.deviceID, status: .outcomeUnknown,
        conversationID: command.conversationID, runID: command.runID, message: error.localizedDescription,
        libraryID: command.libraryID, workspaceID: workspaceID), workspaceID: workspaceID)
      throw error
    }
  }

  /// Asks for the receipt of every command whose outcome is not yet known and
  /// records the ones the server has. Returns the receipts it learned.
  @discardableResult
  public static func resolveUnknown(workspaceID: String, journal: WorkspaceJournal, connection: StreamConnection) async throws -> [LibraryCommandReceipt] {
    var learned: [LibraryCommandReceipt] = []
    for record in await journal.commandRecords(workspaceID: workspaceID)
    where record.receipt == nil || record.receipt?.status == .outcomeUnknown {
      // A receipt in a state a newer server added cannot be read here. That
      // command stays unresolved; the others are still asked about.
      let answer: LibraryCommandReceipt?
      do { answer = try await connection.receipt(record.command.commandID) } catch is DecodingError { continue }
      guard let receipt = answer,
            receipt.commandID == record.command.commandID, receipt.deviceID == record.command.deviceID,
            receipt.status != .outcomeUnknown else { continue }
      try await journal.rememberReceipt(receipt, workspaceID: workspaceID)
      learned.append(receipt)
    }
    return learned
  }
}

// MARK: Transcripts

public extension LibraryTranscript {
  /// Applies one `conversation` stream `transcript` item: a snapshot replaces
  /// the transcript; an update replaces its messages, activities and runs by
  /// ID and sets the run state. An update without `olderCursor` keeps this one's.
  func applying(_ update: StreamTranscript) -> LibraryTranscript {
    guard !update.snapshot else { return update.transcript }
    let change = update.transcript
    var next = self
    let userIDs = Set((next.messages + change.messages).filter { $0.role == "user" }.map(\.id))
    let removed = Set(change.removedMessageIDs ?? []).subtracting(userIDs)
    if !removed.isEmpty {
      next.messages.removeAll { removed.contains($0.id) }
      next.removedMessageIDs = Array(Set(next.removedMessageIDs ?? []).union(removed)).sorted()
    }
    for message in change.messages where !removed.contains(message.id) {
      if let index = next.messages.firstIndex(where: { $0.id == message.id }) { next.messages[index] = message }
      else { next.messages.append(message) }
    }
    for activity in change.activities {
      if let index = next.activities.firstIndex(where: { $0.id == activity.id }) { next.activities[index] = activity }
      else { next.activities.append(activity) }
    }
    next.messages = next.messages.enumerated().sorted {
      let left = $0.element.sequence ?? Int64.max, right = $1.element.sequence ?? Int64.max
      return left == right ? $0.offset < $1.offset : left < right
    }.map(\.element)
    if let runs = change.runs {
      var merged = next.runs ?? []
      for run in runs {
        if let index = merged.firstIndex(where: { $0.id == run.id }) { merged[index] = run } else { merged.append(run) }
      }
      next.runs = merged
    }
    next.activeRunID = change.activeRunID
    if let cursor = change.olderCursor { next.olderCursor = cursor }
    return next
  }
}
