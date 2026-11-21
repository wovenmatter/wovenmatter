import Foundation

/// A connection that carries whole text messages, such as a WebSocket. The
/// protocol does not care which; the server and each client supply one.
public protocol MessageTransport: Sendable {
  /// Messages as they arrive. Finishes when the connection closes.
  var incoming: AsyncThrowingStream<String, any Error> { get }
  /// Queues a message for sending, in order.
  func send(_ text: String) throws
  /// Sends a message and returns once it has been written, so a sender that
  /// waits on this never queues more than the connection takes.
  func sendWhenWritten(_ text: String) async throws
  func close()
}

extension MessageTransport {
  public func sendWhenWritten(_ text: String) async throws { try send(text) }
}

/// The connection closed before the reply arrived.
public struct ConnectionClosed: Error, Sendable {
  public init() {}
}

/// No reply arrived within the call's time limit. The other side may still
/// have carried the request out.
public struct CallTimedOut: Error, Sendable {
  public init() {}
}

/// A live subscription: the reply, then events until it ends.
public struct ClientSubscription<S: Subscription>: Sendable {
  public let id: String
  public let reply: S.Reply
  public let events: AsyncThrowingStream<S.Event, any Error>
}

/// The calling side of a connection: sends a hello, then requests, and routes
/// replies and events back to whoever asked.
public actor Client {
  private struct Sink: Sendable {
    let yield: @Sendable (JSONValue) -> Void
    let finish: @Sendable ((any Error)?) -> Void
  }

  private let transport: any MessageTransport
  private var nextID = 0
  private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
  private var sinks: [String: Sink] = [:]
  private var helloWaiter: CheckedContinuation<Hello, any Error>?
  private var reader: Task<Void, Never>?
  private var failure: (any Error)?
  /// The other side's hello, once it has arrived.
  public private(set) var remote: Hello?

  public init(transport: any MessageTransport) {
    self.transport = transport
  }

  /// Says hello and waits for the other side's.
  public func open(_ hello: Hello) async throws -> Hello {
    let incoming = transport.incoming
    reader = Task { [weak self] in
      do {
        for try await text in incoming { await self?.receive(text) }
        await self?.closed(ConnectionClosed())
      } catch {
        await self?.closed(error)
      }
    }
    try transport.send(Message.hello(hello).text())
    if let remote { return remote }
    return try await withCheckedThrowingContinuation { continuation in
      if let failure { continuation.resume(throwing: failure) } else { helloWaiter = continuation }
    }
  }

  /// Sends a request and waits for its reply; with `timeout`, for at most that long.
  public func call<R: Request>(_ request: R, timeout: Duration? = nil) async throws -> R.Reply {
    try await send(R.method, JSONValue(encoding: request), sink: nil, timeout: timeout).value.decode(R.Reply.self)
  }

  /// Opens a subscription. Events that arrive with or right after the reply
  /// are kept for the stream, so none is missed.
  public func subscribe<S: Subscription>(_ request: S) async throws -> ClientSubscription<S> {
    let (events, continuation) = AsyncThrowingStream<S.Event, any Error>.makeStream()
    let sink = Sink(
      yield: { value in
        do { continuation.yield(try value.decode(S.Event.self)) } catch { continuation.finish(throwing: error) }
      },
      finish: { error in continuation.finish(throwing: error) })
    let (id, value) = try await send(S.method, JSONValue(encoding: request), sink: sink)
    return ClientSubscription(id: id, reply: try value.decode(S.Reply.self), events: events)
  }

  public func unsubscribe(_ id: String) async throws {
    sinks.removeValue(forKey: id)?.finish(nil)
    _ = try await call(Unsubscribe(subscription: id))
  }

  public func close() {
    transport.close()
    closed(ConnectionClosed())
  }

  private func send(_ method: String, _ params: JSONValue, sink: Sink?,
                    timeout: Duration? = nil) async throws -> (id: String, value: JSONValue) {
    if let failure { throw failure }
    nextID += 1
    let id = String(nextID)
    if let sink { sinks[id] = sink }
    let timer = timeout.map { limit in
      Task { [weak self] in
        try await Task.sleep(for: limit)
        await self?.expire(id)
      }
    }
    defer { timer?.cancel() }
    do {
      let value = try await withCheckedThrowingContinuation { continuation in
        pending[id] = continuation
        do {
          try transport.send(Message.request(id: id, method: method, params: params).text())
        } catch {
          pending[id] = nil
          continuation.resume(throwing: error)
        }
      }
      return (id, value)
    } catch {
      sinks[id] = nil
      throw error
    }
  }

  private func expire(_ id: String) {
    pending.removeValue(forKey: id)?.resume(throwing: CallTimedOut())
  }

  private func receive(_ text: String) {
    guard let message = try? Message(text: text) else { return }
    switch message {
    case .hello(let hello):
      remote = hello
      helloWaiter?.resume(returning: hello)
      helloWaiter = nil
    case .reply(let id, let result):
      guard let continuation = pending.removeValue(forKey: id) else { return }
      switch result {
      case .success(let value): continuation.resume(returning: value)
      case .failure(let error): continuation.resume(throwing: error)
      }
    case .event(let subscription, let data):
      sinks[subscription]?.yield(data)
    case .end(let subscription, let error):
      sinks.removeValue(forKey: subscription)?.finish(error)
    case .request:
      // Servers never ask clients anything yet.
      break
    }
  }

  private func closed(_ error: any Error) {
    if failure == nil { failure = error }
    helloWaiter?.resume(throwing: error)
    helloWaiter = nil
    for continuation in pending.values { continuation.resume(throwing: error) }
    pending.removeAll()
    for sink in sinks.values { sink.finish(error) }
    sinks.removeAll()
  }
}
