import Foundation
import WovenMatterCore

/// Async access to the usage tables in the same internal workspace database.
/// Its writer lane is shared with WorkspaceDatabase, including during imports.
final class AsyncUsageStore: Sendable {
  private let workers: DatabaseWorkers
  private let writer: DatabaseConnectionBox<UsageStore>
  private let readers: [DatabaseConnectionBox<UsageStore>]

  init(databaseURL: URL) async throws {
    let workers = DatabaseWorkers.shared(url: databaseURL)
    self.workers = workers
    writer = try await workers.writer.perform { _ in
      try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      return DatabaseConnectionBox(worker: workers.writer, connection: try UsageStore(databaseURL: databaseURL), owner: workers)
    }
    var readers: [DatabaseConnectionBox<UsageStore>] = []
    for worker in workers.readers {
      readers.append(try await worker.perform { _ in
        DatabaseConnectionBox(worker: worker, connection: try UsageStore(databaseURL: databaseURL, readOnly: true), owner: workers)
      })
    }
    self.readers = readers
  }

  func write<T: Sendable>(validating validate: @escaping @Sendable () throws -> Void = {}, _ operation: @escaping @Sendable (UsageStore) throws -> T) async throws -> T {
    let writer = writer
    return try await writer.worker.perform { _ in
      // Validate on the writer lane: ownership can change while this job waits.
      try validate()
      return try writer.use(operation)
    }
  }

  private func read<T: Sendable>(_ operation: @escaping @Sendable (UsageStore) throws -> T) async throws -> T {
    let reader = readers.min { $0.worker.metrics.pending < $1.worker.metrics.pending }!
    return try await reader.worker.perform(interruptible: true) { context in
      try reader.use { connection in try connection.readSnapshot(context: context) { try operation(connection) } }
    }
  }

  func source(_ id: String) async throws -> UsageStoredSource? {
    try await read { try $0.source(id) }
  }

  func samples(
    in interval: DateInterval,
    sourceID: String? = nil,
    limit: Int? = nil,
    offset: Int = 0,
    excludingDevices: Bool = false
  ) async throws -> [UsageSample] {
    try await read {
      try $0.samples(in: interval, sourceID: sourceID, limit: limit, offset: offset, excludingDevices: excludingDevices)
    }
  }

  func storedDevices() async throws -> [(identity: UsageDeviceIdentity, syncedAt: Date)] {
    try await read { try $0.storedDevices() }
  }

  func statistics(sourceIDPrefix: String, in interval: DateInterval) async throws -> UsageSourceStatistics {
    try await read { try $0.statistics(sourceIDPrefix: sourceIDPrefix, in: interval) }
  }

  func metadataDate(_ key: String) async throws -> Date? {
    try await read { try $0.metadataDate(key) }
  }
}

/// Refreshes invalidate queued writes without borrowing actor state on a database
/// worker. Once a write is admitted, its commit/rollback result remains definitive.
final class UsageRefreshOwnership: @unchecked Sendable {
  private let lock = NSLock()
  private var valid = true
  private let connectionRevision: UInt64?
  private let currentRevision: @Sendable () -> UInt64

  init(connectionRevision: UInt64? = nil, currentRevision: @escaping @Sendable () -> UInt64 = { 0 }) {
    self.connectionRevision = connectionRevision
    self.currentRevision = currentRevision
  }

  func invalidate() { lock.withLock { valid = false } }

  func check() throws {
    guard lock.withLock({ valid }),
          connectionRevision == nil || connectionRevision == currentRevision() else {
      throw CancellationError()
    }
  }
}
