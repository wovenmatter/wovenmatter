import Foundation
import WovenLibrary
import WovenProtocol

/// Who is on the other end of a connection.
public struct Caller: Sendable {
  public enum Origin: Sendable {
    /// The Unix socket: the UI on this machine.
    case local
    /// A machine of the tailnet, by its tailnet name.
    case tailnet(name: String)
  }

  public var origin: Origin
  public var hello: Hello
}

/// Handlers by method. Adding a request is one `on` call.
struct Router: Sendable {
  /// Encoded events of one subscription. The connection pulls them only as
  /// fast as it can send them; whoever produces them bounds what waits.
  typealias Events = AsyncThrowingStream<JSONValue, any Error>

  enum Outcome: Sendable {
    case reply(JSONValue)
    case subscription(JSONValue, Events)
  }

  typealias Handler = @Sendable (JSONValue, Caller) async throws -> Outcome
  private var handlers: [String: Handler] = [:]

  mutating func on<R: Request>(_ type: R.Type, _ handle: @escaping @Sendable (R, Caller) async throws -> R.Reply) {
    handlers[R.method] = { params, caller in
      .reply(try JSONValue(encoding: try await handle(try Self.decode(R.self, params), caller)))
    }
  }

  mutating func subscription<S: Subscription>(
    _ type: S.Type, _ handle: @escaping @Sendable (S, Caller) async throws -> (S.Reply, AsyncThrowingStream<S.Event, any Error>)
  ) {
    handlers[S.method] = { params, caller in
      let (reply, events) = try await handle(try Self.decode(S.self, params), caller)
      let box = IteratorBox(events.makeAsyncIterator())
      let encoded = Events(unfolding: { try await box.next().map { try JSONValue(encoding: $0) } })
      return .subscription(try JSONValue(encoding: reply), encoded)
    }
  }

  func handle(_ method: String, _ params: JSONValue, _ caller: Caller) async throws -> Outcome {
    guard let handler = handlers[method] else { throw ProtocolError(.unknownMethod, "No method \(method).") }
    return try await handler(params, caller)
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ params: JSONValue) throws -> T {
    do { return try params.decode(type) } catch {
      throw ProtocolError(.badRequest, "Could not read the request: \(error)")
    }
  }
}

/// Lets one consumer pull from a stream's iterator through a `@Sendable` closure.
private final class IteratorBox<Element: Sendable>: @unchecked Sendable {
  private var iterator: AsyncThrowingStream<Element, any Error>.Iterator
  init(_ iterator: AsyncThrowingStream<Element, any Error>.Iterator) { self.iterator = iterator }
  func next() async throws -> Element? { try await iterator.next() }
}

extension AsyncStream where Element: Sendable {
  /// The same events as a stream that never fails.
  var throwing: AsyncThrowingStream<Element, any Error> {
    let box = PlainIteratorBox(makeAsyncIterator())
    return AsyncThrowingStream(unfolding: { await box.next() })
  }
}

private final class PlainIteratorBox<Element: Sendable>: @unchecked Sendable {
  private var iterator: AsyncStream<Element>.Iterator
  init(_ iterator: AsyncStream<Element>.Iterator) { self.iterator = iterator }
  func next() async -> Element? { await iterator.next() }
}

extension ProtocolError {
  /// Any error as the protocol reports it.
  init(_ error: any Error) {
    switch error {
    case let error as ProtocolError:
      self = error
    case let error as LibraryError:
      switch error.kind {
      case .notFound: self.init(.notFound, error.description)
      case .notOwner(let machineID): self.init(.notOwner, error.description, machineID: machineID)
      case .invalid: self.init(.badRequest, error.description)
      case .closed: self.init(.failed, error.description)
      }
    case let error as SubscriberTooSlow:
      self.init(.tooSlow, error.description)
    default:
      self.init(.failed, String(describing: error))
    }
  }
}

/// The server's side of one connection: waits for the hello, answers it, then
/// serves requests concurrently and forwards subscription events, each only
/// as fast as the connection takes them.
actor ServerConnection {
  /// How long a new connection may take to say hello.
  static let helloLimit = Duration.seconds(10)

  private let transport: any MessageTransport
  private let router: Router
  private let origin: Caller.Origin
  private let hello: Hello
  private var caller: Caller?
  private var tasks: [String: Task<Void, Never>] = [:]

  init(transport: any MessageTransport, router: Router, origin: Caller.Origin, hello: Hello) {
    self.transport = transport
    self.router = router
    self.origin = origin
    self.hello = hello
  }

  /// Serves until the connection closes.
  func run() async {
    let transport = transport
    let timer = Task {
      try await Task.sleep(for: Self.helloLimit)
      transport.close()
    }
    do {
      for try await text in transport.incoming {
        guard let message = try? Message(text: text) else { continue }
        guard let caller else {
          guard case .hello(let remote) = message else { break }
          timer.cancel()
          caller = Caller(origin: origin, hello: remote)
          try transport.send(Message.hello(hello).text())
          continue
        }
        guard case .request(let id, let method, let params) = message else { continue }
        if method == Unsubscribe.method {
          if let request = try? params.decode(Unsubscribe.self) { tasks.removeValue(forKey: request.subscription)?.cancel() }
          reply(id, .success(try JSONValue(encoding: Done())))
          continue
        }
        guard tasks[id] == nil else {
          reply(id, .failure(ProtocolError(.badRequest, "Request id \(id) is already in use on this connection.")))
          continue
        }
        tasks[id] = Task { await self.serve(id, method, params, caller) }
      }
    } catch {}
    timer.cancel()
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
    transport.close()
  }

  private func serve(_ id: String, _ method: String, _ params: JSONValue, _ caller: Caller) async {
    do {
      switch try await router.handle(method, params, caller) {
      case .reply(let value):
        reply(id, .success(value))
      case .subscription(let value, let events):
        reply(id, .success(value))
        do {
          for try await event in events {
            try await transport.sendWhenWritten(try Message.event(subscription: id, data: event).text())
          }
          if !Task.isCancelled { send(.end(subscription: id, error: nil)) }
        } catch {
          if !Task.isCancelled { send(.end(subscription: id, error: ProtocolError(error))) }
        }
      }
    } catch {
      reply(id, .failure(ProtocolError(error)))
    }
    tasks[id] = nil
  }

  private func reply(_ id: String, _ result: Result<JSONValue, ProtocolError>) {
    send(.reply(id: id, result: result))
  }

  private func send(_ message: Message) {
    if let text = try? message.text() { try? transport.send(text) }
  }
}
