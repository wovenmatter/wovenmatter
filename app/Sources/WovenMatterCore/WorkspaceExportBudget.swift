import Foundation

public enum WorkspaceExportError: LocalizedError, Equatable, Sendable {
  case tooLarge

  public var errorDescription: String? {
    "This export is too large to prepare safely. Nothing was saved."
  }
}

/// Export snapshots are complete or rejected, never silently truncated. Charge
/// every retained string and row before materializing/encoding the whole export.
public struct WorkspaceExportBudget: Sendable {
  public static let maximumStoredBytes = 16 * 1_024 * 1_024
  public static let maximumItems = 20_000
  public static let maximumEncodedBytes = 64 * 1_024 * 1_024
  public private(set) var remainingBytes: Int
  public private(set) var remainingItems: Int

  public init(maximumBytes: Int = Self.maximumStoredBytes, maximumItems: Int = Self.maximumItems) {
    remainingBytes = max(0, min(maximumBytes, Self.maximumStoredBytes))
    remainingItems = max(0, min(maximumItems, Self.maximumItems))
  }

  public mutating func consume(bytes: Int = 0, items: Int = 0) throws {
    guard bytes >= 0, items >= 0, bytes <= remainingBytes, items <= remainingItems else {
      throw WorkspaceExportError.tooLarge
    }
    remainingBytes -= bytes
    remainingItems -= items
  }

  public mutating func consume(_ value: String?) throws {
    if let value { try consume(bytes: value.utf8.count) }
  }

  public static func checked(_ data: Data) throws -> Data {
    guard data.count <= maximumEncodedBytes else { throw WorkspaceExportError.tooLarge }
    return data
  }
}

/// Once an atomic file write starts, it runs to its definitive outcome. A
/// cancellation while still queued must not create or replace a destination.
public enum WorkspaceExportFileIO {
  public static func perform(_ operation: @escaping @Sendable () throws -> Void) async throws {
    let cancellation = ExportCancellation()
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            try cancellation.check()
            try operation()
            continuation.resume()
          } catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: { cancellation.cancel() }
  }
}

private final class ExportCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  func check() throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw CancellationError() }
  }
}
