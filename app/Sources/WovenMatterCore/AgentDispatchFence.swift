import Foundation

/// One input retains the same Stop intent from app preparation through its
/// final transport write, including senders running in an unstructured task.
public final class AgentDispatchFence: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var dispatched = false

  public init() {}

  public var hasDispatched: Bool { lock.withLock { dispatched } }
  public var isCancelled: Bool { lock.withLock { cancelled } }

  /// False means a native send may already have begun; its receipt remains
  /// authoritative and cancellation must not roll back that input as unsent.
  @discardableResult
  public func cancel() -> Bool {
    lock.withLock {
      cancelled = true
      return !dispatched
    }
  }

  public func check() throws {
    try Task.checkCancellation()
    try lock.withLock {
      if cancelled { throw CancellationError() }
    }
  }

  /// Called immediately before transport I/O, after any history persistence.
  public func claimDispatch() throws {
    try Task.checkCancellation()
    try lock.withLock {
      if cancelled { throw CancellationError() }
      dispatched = true
    }
  }
}
