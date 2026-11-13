import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore
import WovenMatterShared

/// The mobile library change feed (`device_sync_changes`, the phone's
/// `GET v1/changes`) as a live signal: every Mac's and Linux host's `workspace`
/// stream carries its cursor as `library` items, so a phone synchronizes its
/// library when it changes instead of on a timer (docs/architecture/WOVEN_EVERYWHERE.md,
/// "Streaming").
extension WorkspaceDatabaseConnection {
  /// Tables a phone synchronizes outside `GET v1/changes` (calendar,
  /// dictation, the workspace registry, saved artifacts). A change to one adds
  /// a wake-only entry to `device_sync_changes`; its kind is not a
  /// `LibraryChange.ResourceKind`, so a change page skips it and only its
  /// cursor advances. Execution journals are left out: each workspace's own
  /// stream carries them.
  static let deviceSyncWakeTables: [(table: String, kind: String, key: String)] = [
    ("calendar_items", "calendar", "id"),
    ("calendar_task_executors", "calendar", "event_id"),
    ("calendar_published_runs", "calendar", "id"),
    ("dictation_history", "dictation", "id"),
    ("execution_workspaces", "registry", "id"),
    ("device_saved_artifacts", "artifacts", "id"),
  ]

  /// Kinds that do not wake a phone: transcripts (the open chat streams, and
  /// a running session rewrites them constantly) and the agent list (the
  /// phone reads it on its own).
  static let deviceSyncQuietKinds = ["transcript", "providers"]

  /// Runs after every table it names exists.
  func migrateDeviceSyncWakes() throws {
    try transaction {
      for (table, kind, key) in Self.deviceSyncWakeTables {
        let exists = try prepareUnlocked("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
        try bind(table, at: 1, to: exists)
        let present = sqlite3_step(exists) == SQLITE_ROW
        sqlite3_finalize(exists)
        guard present else { continue }
        for operation in ["INSERT", "UPDATE", "DELETE"] {
          let row = operation == "DELETE" ? "OLD" : "NEW"
          try executeUnlocked("""
            CREATE TRIGGER IF NOT EXISTS \(table)_device_sync_wake_\(operation.lowercased())
            AFTER \(operation) ON \(table)
            BEGIN
              INSERT INTO device_sync_changes(kind, resource_id, revision, deleted)
              VALUES ('\(kind)', CAST(\(row).\(key) AS TEXT), 0, 0);
              DELETE FROM device_sync_changes WHERE cursor <=
                (SELECT COALESCE(MAX(cursor), 0) - \(LibraryProtocol.maximumReplayChanges) FROM device_sync_changes);
            END;
            """)
        }
      }
    }
  }

  /// The newest cursor a phone must synchronize to: the latest entry that is
  /// not a quiet kind. When every retained entry is quiet, anything older was
  /// pruned, so a phone behind the oldest retained entry is woken (its next
  /// page asks it to reset) and any other is not.
  func libraryWakeCursorUnlocked() throws -> Int64 {
    let quiet = Self.deviceSyncQuietKinds.map { "'\($0)'" }.joined(separator: ",")
    let latest = try prepareUnlocked("SELECT cursor FROM device_sync_changes WHERE kind NOT IN (\(quiet)) ORDER BY cursor DESC LIMIT 1")
    defer { sqlite3_finalize(latest) }
    if sqlite3_step(latest) == SQLITE_ROW { return sqlite3_column_int64(latest, 0) }
    let oldest = try prepareUnlocked("SELECT MIN(cursor) FROM device_sync_changes")
    defer { sqlite3_finalize(oldest) }
    guard sqlite3_step(oldest) == SQLITE_ROW else { throw stepError() }
    if sqlite3_column_type(oldest, 0) == SQLITE_NULL { return try libraryCursorUnlocked() }
    return max(0, sqlite3_column_int64(oldest, 0) - 1)
  }
}

extension WorkspaceDatabase {
  /// The library change cursor carried by `library` stream items.
  public func libraryWakeCursor() async throws -> Int64 {
    try await read { connection in try connection.withLock { try connection.libraryWakeCursorUnlocked() } }
  }
}

/// Announces the library change cursor: once when it starts, then after
/// commits that add to `device_sync_changes`, at most every `interval`, and
/// only when the cursor moved. The Mac's stream server sends each value to its
/// `workspace` subscriptions; a Linux library host prints it for the Node
/// server that supervises it.
public actor LibraryChangeAnnouncer {
  public typealias Sleep = @Sendable (Duration) async throws -> Void
  private let database: WorkspaceDatabase
  private let interval: Duration
  private let sleep: Sleep
  private let announce: @Sendable (Int64) async -> Void
  private var observer: UUID?
  private var last: Int64?
  private var lastAnnouncedAt: ContinuousClock.Instant?
  private var scheduled: Task<Void, Never>?
  private var stopped = false

  public init(database: WorkspaceDatabase, interval: Duration = StreamProtocol.libraryInterval,
              sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
              announce: @escaping @Sendable (Int64) async -> Void) {
    self.database = database; self.interval = interval; self.sleep = sleep; self.announce = announce
  }

  /// The latest cursor announced, if any.
  public var cursor: Int64? { last }

  public func start() async {
    guard observer == nil, !stopped else { return }
    observer = database.observeLibraryChanges { [weak self] _ in Task { await self?.changed() } }
    await read()
  }

  public func stop() {
    stopped = true
    scheduled?.cancel(); scheduled = nil
    if let observer { database.removeLibraryChangeObserver(observer) }
    observer = nil
  }

  /// A commit added to the feed. Coalesced: one read per `interval`.
  func changed() {
    guard !stopped, scheduled == nil else { return }
    let wait = lastAnnouncedAt.map { max(.zero, interval - (ContinuousClock.now - $0)) } ?? .zero
    let sleep = sleep
    scheduled = Task { [weak self] in
      if wait > .zero { do { try await sleep(wait) } catch { return } }
      await self?.fire()
    }
  }

  private func fire() async {
    scheduled = nil
    await read()
  }

  private func read() async {
    guard !stopped else { return }
    guard let value = try? await database.libraryWakeCursor() else {
      // A failed read is tried again after `interval`; the feed keeps its entries.
      lastAnnouncedAt = .now
      changed(); return
    }
    lastAnnouncedAt = .now
    guard value != last else { return }
    last = value
    await announce(value)
  }
}
