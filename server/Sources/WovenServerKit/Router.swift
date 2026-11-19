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
  enum Outcome: Sendable {
    case reply(JSONValue)
    case subscription(JSONValue, AsyncStream<JSONValue>)
  }

  typealias Handler = @Sendable (JSONValue, Caller) async throws -> Outcome
  private var handlers: [String: Handler] = [:]

  mutating func on<R: Request>(_ type: R.Type, _ handle: @escaping @Sendable (R, Caller) async throws -> R.Reply) {
    handlers[R.method] = { params, caller in
      .reply(try JSONValue(encoding: try await handle(try Self.decode(R.self, params), caller)))
    }
  }

  mutating func subscription<S: Subscription>(
    _ type: S.Type, _ handle: @escaping @Sendable (S, Caller) async throws -> (S.Reply, AsyncStream<S.Event>)
  ) {
    handlers[S.method] = { params, caller in
      let (reply, events) = try await handle(try Self.decode(S.self, params), caller)
      let (encoded, continuation) = AsyncStream<JSONValue>.makeStream()
      let forward = Task {
        for await event in events {
          if let value = try? JSONValue(encoding: event) { continuation.yield(value) }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in forward.cancel() }
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
    default:
      self.init(.failed, String(describing: error))
    }
  }
}

/// The server's side of one connection: waits for the hello, answers it, then
/// serves requests concurrently and forwards subscription events.
actor ServerConnection {
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
    do {
      for try await text in transport.incoming {
        guard let message = try? Message(text: text) else { continue }
        guard let caller else {
          guard case .hello(let remote) = message else { break }
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
        tasks[id] = Task { await self.serve(id, method, params, caller) }
      }
    } catch {}
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
        for await event in events { send(.event(subscription: id, data: event)) }
        if !Task.isCancelled { send(.end(subscription: id, error: nil)) }
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
