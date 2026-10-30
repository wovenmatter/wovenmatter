import Foundation
import SQLite3
import WovenMatterCore

/// The app's internal database. No SQLite handle or synchronous operation escapes
/// this facade. Each write is one worker job; reads use two query-only connections.
public final class WorkspaceDatabase: Sendable {
  private let workers: DatabaseWorkers
  private let writer: DatabaseConnectionBox<WorkspaceDatabaseConnection>?
  private let readers: [DatabaseConnectionBox<WorkspaceDatabaseConnection>]
  public let supportDirectory: URL
  public let fileURL: URL
  public let isReadOnlyProjection: Bool
  let libraryFiles: LibraryFileStore

  public init(url: URL, readOnlyProjection: Bool = false) async throws {
    self.fileURL = url.standardizedFileURL
    let workers = DatabaseWorkers.shared(url: url)
    self.workers = workers
    supportDirectory = url.deletingLastPathComponent()
    isReadOnlyProjection = readOnlyProjection
    libraryFiles = LibraryFileStore(supportDirectory: url.deletingLastPathComponent(), readOnlyProjection: readOnlyProjection)
    if readOnlyProjection { writer = nil }
    else {
      writer = try await workers.writer.perform { _ in
        DatabaseConnectionBox(worker: workers.writer, connection: try WorkspaceDatabaseConnection(url: url, workerQueue: workers.writer.queue), owner: workers)
      }
    }
    var readers: [DatabaseConnectionBox<WorkspaceDatabaseConnection>] = []
    for worker in workers.readers {
      readers.append(try await worker.perform { _ in
        DatabaseConnectionBox(worker: worker, connection: try WorkspaceDatabaseConnection(url: url, readOnlyProjection: true, workerQueue: worker.queue), owner: workers)
      })
    }
    self.readers = readers
  }

  public var workerMetrics: [DatabaseWorkerMetrics] {
    [workers.writer.metrics] + workers.readers.map(\.metrics)
  }

  func write<T: Sendable>(_ operation: @escaping @Sendable (WorkspaceDatabaseConnection) throws -> T) async throws -> T {
    guard let writer else { throw WorkspaceDatabaseError.readOnlyProjection }
    return try await writer.worker.perform { _ in try writer.use { connection in
      try connection.requireLibraryWritesAllowed()
      return try operation(connection)
    } }
  }

  /// The transfer coordinator alone can write while the ordinary mutation gate
  /// is closed. Backups, merge activation and releasing the fence share the
  /// existing serialized SQLite writer; readers never observe a partial merge.
  func transferWrite<T: Sendable>(_ operation: @escaping @Sendable (WorkspaceDatabaseConnection) throws -> T) async throws -> T {
    guard let writer else { throw WorkspaceDatabaseError.readOnlyProjection }
    return try await writer.worker.perform { _ in try writer.use(operation) }
  }

  public func fenceLibraryTransfer(_ id: String) async throws {
    try await transferWrite { connection in
      guard connection.libraryTransferID == nil || connection.libraryTransferID == id else {
        throw CompanionAPIError(code: "transfer_busy", message: "Another database transfer is already in progress.")
      }
      connection.libraryTransferID = id
    }
  }

  public func releaseLibraryTransfer(_ id: String) async throws {
    try await transferWrite { connection in
      guard connection.libraryTransferID == id else { return }
      connection.libraryTransferID = nil
    }
  }

  public func backupLibrary(to url: URL) async throws { try await transferWrite { try $0.backupLibrary(to: url) } }
  public func activateTransferredLibrary(from url: URL, transferID: String) async throws {
    try await transferWrite { connection in
      guard connection.libraryTransferID == transferID else { throw WorkspaceDatabaseError.execute("The transfer write fence is not held") }
      try connection.restoreLibrary(from: url)
    }
  }

  /// Cleanup of accepted work must survive cancellation of the task driving it.
  /// This still observes admission limits and queue deadlines.
  func finishWrite<T: Sendable>(_ operation: @escaping @Sendable (WorkspaceDatabaseConnection) throws -> T) async throws -> T {
    try await Task { try await self.write(operation) }.value
  }

  func read<T: Sendable>(timeout: TimeInterval = 30,
    _ operation: @escaping @Sendable (WorkspaceDatabaseConnection) throws -> T) async throws -> T {
    // Prefer an idle reader instead of queueing behind an expensive search.
    let reader = readers.min { $0.worker.metrics.pending < $1.worker.metrics.pending }!
    return try await reader.worker.perform(timeout: timeout, interruptible: true) { context in
      try reader.use { connection in
        try connection.readSnapshot(context: context) { try operation(connection) }
      }
    }
  }
  #if DEBUG
  /// Instrument every connection on its owning queue for SQL regression checks.
  /// Raw handles never leave the worker, including when readers run concurrently.
  func inspectConnections(_ operation: @escaping @Sendable (WorkspaceDatabaseConnection) throws -> Void) async throws {
    for box in (writer.map { [$0] } ?? []) + readers {
      try await box.worker.perform { _ in try box.use(operation) }
    }
  }
  #endif

}
