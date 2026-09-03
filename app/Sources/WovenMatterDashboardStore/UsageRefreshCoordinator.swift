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

  private var inFlight: InFlight?
  private var cached: (key: Key, value: Value)?

  public init() {}

  public var isRefreshing: Bool { inFlight != nil }

  public func value(
    for key: Key,
    policy: Policy,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    if let inFlight, inFlight.key == key, policy != .force {
      return try await complete(inFlight)
    }
    if policy == .reuse, let cached, cached.key == key {
      return cached.value
    }

    inFlight?.task.cancel()
    let refresh = InFlight(
      id: UUID(),
      key: key,
      task: Task(operation: operation)
    )
    inFlight = refresh
    return try await complete(refresh)
  }

  public func cancelCurrent() {
    inFlight?.task.cancel()
    inFlight = nil
  }

  private func complete(_ refresh: InFlight) async throws -> Value {
    do {
      let value = try await refresh.task.value
      if inFlight?.id == refresh.id {
        cached = (refresh.key, value)
        inFlight = nil
      }
      return value
    } catch {
      if inFlight?.id == refresh.id {
        inFlight = nil
      }
      throw error
    }
  }
}
