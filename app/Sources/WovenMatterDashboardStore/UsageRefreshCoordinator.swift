import Foundation

public actor UsageRefreshCoordinator<Key: Hashable & Sendable, Value: Sendable> {
  public enum Policy: Equatable, Sendable {
    case reuse
    case refresh
    case force
  }

  private struct InFlight: Sendable {
    let id: UUID
    let key: Key
    let task: Task<Value, any Error>
  }

  // Kept after completion so every coalesced waiter can validate the same generation.
  private var currentGeneration: UUID?
  private var inFlight: InFlight?
  private var cached: (key: Key, value: Value)?

  public init() {}

  public var isRefreshing: Bool { inFlight != nil }

  public func value(
    for key: Key,
    policy: Policy,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    if let inFlight, inFlight.key == key, policy != .force {
      return try await complete(inFlight)
    }
    if policy == .reuse, let cached, cached.key == key {
      if inFlight != nil { cancelCurrent() }
      return cached.value
    }

    inFlight?.task.cancel()
    let refresh = InFlight(
      id: UUID(),
      key: key,
      task: Task(operation: operation)
    )
    currentGeneration = refresh.id
    inFlight = refresh
    return try await complete(refresh)
  }

  public func cancelCurrent() {
    currentGeneration = nil
    inFlight?.task.cancel()
    inFlight = nil
  }

  private func complete(_ refresh: InFlight) async throws -> Value {
    do {
      let value = try await refresh.task.value
      guard currentGeneration == refresh.id, !refresh.task.isCancelled else {
        throw CancellationError()
      }
      if inFlight?.id == refresh.id {
        cached = (refresh.key, value)
        inFlight = nil
      }
      try Task.checkCancellation()
      return value
    } catch {
      guard currentGeneration == refresh.id else { throw CancellationError() }
      if inFlight?.id == refresh.id {
        inFlight = nil
      }
      if Task.isCancelled || refresh.task.isCancelled { throw CancellationError() }
      throw error
    }
  }
}
