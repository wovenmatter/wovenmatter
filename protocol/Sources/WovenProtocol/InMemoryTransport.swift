import Foundation

/// One end of a connection inside one process: what one end sends, the other
/// receives, in order. A device's UI talks to the server's core in the app
/// over a pair of these; tests use them too.
public final class InMemoryTransport: MessageTransport {
  public let incoming: AsyncThrowingStream<String, any Error>
  private let own: AsyncThrowingStream<String, any Error>.Continuation
  private let other: AsyncThrowingStream<String, any Error>.Continuation

  private init(incoming: AsyncThrowingStream<String, any Error>, own: AsyncThrowingStream<String, any Error>.Continuation,
               other: AsyncThrowingStream<String, any Error>.Continuation) {
    self.incoming = incoming
    self.own = own
    self.other = other
  }

  /// Two connected ends. Closing either closes both.
  public static func pair() -> (InMemoryTransport, InMemoryTransport) {
    let (first, toFirst) = AsyncThrowingStream<String, any Error>.makeStream()
    let (second, toSecond) = AsyncThrowingStream<String, any Error>.makeStream()
    return (InMemoryTransport(incoming: first, own: toFirst, other: toSecond),
            InMemoryTransport(incoming: second, own: toSecond, other: toFirst))
  }

  public func send(_ text: String) throws {
    guard case .enqueued = other.yield(text) else { throw ConnectionClosed() }
  }

  public func close() {
    own.finish()
    other.finish()
  }
}
