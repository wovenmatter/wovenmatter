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

  func write<T: Sendable>(_ operation: @escaping @Sendable (UsageStore) throws -> T) async throws -> T {
    let writer = writer
    return try await writer.worker.perform { _ in try writer.use(operation) }
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

  func runtimeSyncState(endpoint: String) async throws -> UsageRuntimeSyncState? {
    try await read { try $0.runtimeSyncState(endpoint: endpoint) }
  }

  func ingest(
    page: UsageIngestionPage,
    endpoint: String,
    importedAt: Date
  ) async throws {
    try await write { try $0.ingest(page: page, endpoint: endpoint, importedAt: importedAt) }
  }

  func replace(
    sourceID: String,
    sourceName: String,
    location: String,
    provider: ProviderKind,
    harness: String?,
    fingerprint: String,
    samples: [UsageSample],
    importedAt: Date,
    indexedAfter: Date? = nil,
    transactional: Bool = true
  ) async throws {
    try await write { try $0.replace(sourceID: sourceID, sourceName: sourceName, location: location, provider: provider, harness: harness, fingerprint: fingerprint, samples: samples, importedAt: importedAt, indexedAfter: indexedAfter, transactional: transactional) }
  }

  func samples(in interval: DateInterval, sourceID: String? = nil, limit: Int? = nil, offset: Int = 0) async throws -> [UsageSample] {
    try await read { try $0.samples(in: interval, sourceID: sourceID, limit: limit, offset: offset) }
  }

  func statistics(sourceID: String, in interval: DateInterval) async throws -> UsageSourceStatistics {
    try await read { try $0.statistics(sourceID: sourceID, in: interval) }
  }

  func statistics(sourceIDPrefix: String, in interval: DateInterval) async throws -> UsageSourceStatistics {
    try await read { try $0.statistics(sourceIDPrefix: sourceIDPrefix, in: interval) }
  }

  func metadataDate(_ key: String) async throws -> Date? {
    try await read { try $0.metadataDate(key) }
  }

  func setMetadataDate(_ value: Date, for key: String) async throws {
    try await write { try $0.setMetadataDate(value, for: key) }
  }

  func usageLimitAccounts(
    providers: Set<ProviderKind>,
    accountScopes: [ProviderKind: String] = [:]
  ) async throws -> [UsageLimitAccount] {
    try await read { try $0.usageLimitAccounts(providers: providers, accountScopes: accountScopes) }
  }

  func saveUsageLimitAccounts(_ accounts: [UsageLimitAccount], storedAt: Date) async throws {
    try await write { try $0.saveUsageLimitAccounts(accounts, storedAt: storedAt) }
  }

  func prune(before cutoff: Date) async throws {
    try await write { try $0.prune(before: cutoff) }
  }
}
