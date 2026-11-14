import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// The app's internal database. No SQLite handle or synchronous operation escapes
/// this facade. Each write is one worker job; reads use two query-only connections.
public final class WorkspaceDatabase: Sendable {
  let workers: DatabaseWorkers
  private let writer: DatabaseConnectionBox<WorkspaceDatabaseConnection>?
  private let readers: [DatabaseConnectionBox<WorkspaceDatabaseConnection>]
  public let supportDirectory: URL
  public let fileURL: URL
  public let isReadOnlyProjection: Bool
  let libraryFiles: LibraryFileStore
  private let changes = PeerChangeObservers()

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

  func write<T: Sendable>(_ operation: @escaping @Sendable (WorkspaceDatabaseConnection) throws -> T) async throws -> T {
    guard let writer else { throw WorkspaceDatabaseError.readOnlyProjection }
    let changes = changes, streamChanges = workers.streamChanges, libraryChanges = workers.libraryChanges
    return try await writer.worker.perform { _ in
      try writer.use { connection in
        defer {
          if changes.isObserved { changes.check(connection) }
          if streamChanges.isObserved { streamChanges.check(connection) }
          if libraryChanges.isObserved { libraryChanges.check(connection) }
        }
        return try operation(connection)
      }
    }
  }

  /// Calls `handler` (on the writer's queue; keep it short) after any write
  /// that recorded a new peer-sync version, so synchronization is change-driven.
  @discardableResult
  public func observePeerChanges(_ handler: @escaping @Sendable (Int64) -> Void) -> UUID { changes.add(handler) }
  public func removePeerChangeObserver(_ id: UUID) { changes.remove(id) }

  /// Calls `handler` (on the writer's queue; keep it short) after any write,
  /// through any handle on this database file, that committed new
  /// `execution_stream_changes` entries: the stream server's wake.
  @discardableResult
  public func observeExecutionStreamChanges(_ handler: @escaping @Sendable (Int64) -> Void) -> UUID { workers.streamChanges.add(handler) }
  public func removeExecutionStreamObserver(_ id: UUID) { workers.streamChanges.remove(id) }

  /// Calls `handler` (on the writer's queue; keep it short) after any write,
  /// through any handle on this database file, that committed new
  /// `device_sync_changes` entries: the wake of `library` stream items.
  @discardableResult
  public func observeLibraryChanges(_ handler: @escaping @Sendable (Int64) -> Void) -> UUID { workers.libraryChanges.add(handler) }
  public func removeLibraryChangeObserver(_ id: UUID) { workers.libraryChanges.remove(id) }

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

/// Tracks a sequence's high-water mark on the writer connection. One
/// indexed read of `sqlite_sequence` per write, only while observed.
final class PeerChangeObservers: @unchecked Sendable {
  private let table: String
  init(table: String = "peer_sync_versions") { self.table = table }
  private let lock = NSLock()
  private var handlers: [UUID: @Sendable (Int64) -> Void] = [:]
  private var last: Int64?
  var isObserved: Bool { lock.withLock { !handlers.isEmpty } }
  func add(_ handler: @escaping @Sendable (Int64) -> Void) -> UUID {
    let id = UUID(); lock.withLock { handlers[id] = handler }; return id
  }
  func remove(_ id: UUID) { lock.withLock { _ = handlers.removeValue(forKey: id) } }
  func check(_ connection: WorkspaceDatabaseConnection) {
    guard let value = try? connection.historyRowsUnlocked("SELECT seq FROM sqlite_sequence WHERE name=?", values: [table])
      .first?.objectValue?["seq"]?.doubleValue.map({ Int64($0) }) else { return }
    let notify: [@Sendable (Int64) -> Void] = lock.withLock {
      defer { last = value }
      // The first observed write may follow an unseen change; a spurious
      // announcement is harmless, a missed one is not.
      if let last, value <= last { return [] }
      return Array(handlers.values)
    }
    for handler in notify { handler(value) }
  }
}
