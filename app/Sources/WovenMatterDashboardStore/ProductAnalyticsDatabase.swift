import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  func createProductAnalyticsSchemaUnlocked() throws {
    try executeUnlocked(
      """
      CREATE TABLE IF NOT EXISTS product_analytics_preference(singleton INTEGER PRIMARY KEY CHECK(singleton=1), payload BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS product_analytics_events(id TEXT PRIMARY KEY, payload BLOB NOT NULL, status TEXT NOT NULL DEFAULT 'pending', created REAL NOT NULL);
      CREATE INDEX IF NOT EXISTS product_analytics_pending ON product_analytics_events(status,created);
      """)
    let insert = try prepareUnlocked(
      "INSERT OR IGNORE INTO product_analytics_preference VALUES(1,?)")
    defer { sqlite3_finalize(insert) }
    try bind(
      JSONEncoder().encode(ProductAnalyticsPreference(analyticsID: UUID().uuidString.lowercased())),
      at: 1, to: insert)
    try stepDone(insert)
  }
  func productAnalyticsPreference() throws -> ProductAnalyticsPreference {
    try withLock {
      let stmt = try prepareUnlocked(
        "SELECT payload FROM product_analytics_preference WHERE singleton=1")
      defer { sqlite3_finalize(stmt) }
      guard sqlite3_step(stmt) == SQLITE_ROW else { throw WorkspaceDatabaseError.corruptRow }
      return try JSONDecoder().decode(ProductAnalyticsPreference.self, from: blob(stmt, column: 0))
    }
  }
  func setProductAnalyticsPreference(_ change: ProductAnalyticsPreferenceChange) throws
    -> ProductAnalyticsPreference
  {
    try transaction {
      var value = try productAnalyticsPreference()
      // Offline opt-out always wins; stale opt-in cannot overwrite a newer choice.
      guard !change.enabled || change.expectedRevision == value.revision else {
        throw WorkspaceDatabaseError.execute(
          "Analytics preference changed. Refresh before enabling it.")
      }
      // Reaffirming opt-out is a newer choice too: invalidate any queued opt-in,
      // even when the library was already disabled when this request arrived.
      if value.enabled != change.enabled || !change.enabled
        || (change.acknowledgeDisclosure && value.disclosedAt == nil)
      {
        value.revision += 1
        value.enabled = change.enabled
        value.disclosedAt = change.acknowledgeDisclosure || value.disclosedAt != nil ? Date() : nil
        let stmt = try prepareUnlocked(
          "UPDATE product_analytics_preference SET payload=? WHERE singleton=1")
        defer { sqlite3_finalize(stmt) }
        try bind(JSONEncoder().encode(value), at: 1, to: stmt)
        try stepDone(stmt)
        // Clear unsent events on both transitions. No disabled-period backfill.
        try executeUnlocked("DELETE FROM product_analytics_events WHERE status='pending'")
      }
      return value
    }
  }
  func enqueueProductAnalytics(_ events: [ProductAnalyticsEvent]) throws
    -> ProductAnalyticsAcknowledgement
  {
    try transaction {
      let preference = try productAnalyticsPreference()
      guard events.count <= 100 else {
        throw WorkspaceDatabaseError.execute("Analytics batch is too large.")
      }
      var accepted: [String] = []
      var discarded: [String] = []
      for event in events {
        guard let value = event.validated(preference: preference) else {
          discarded.append(event.id)
          continue
        }
        accepted.append(event.id)
        let stmt = try prepareUnlocked(
          "INSERT OR IGNORE INTO product_analytics_events(id,payload,status,created) VALUES(?,?,'pending',?)"
        )
        defer { sqlite3_finalize(stmt) }
        try bind(value.id, at: 1, to: stmt)
        try bind(JSONEncoder().encode(value), at: 2, to: stmt)
        sqlite3_bind_double(stmt, 3, value.timestamp.timeIntervalSince1970)
        try stepDone(stmt)
      }
      try executeUnlocked(
        "DELETE FROM product_analytics_events WHERE created < \(Date().addingTimeInterval(-7*86400).timeIntervalSince1970)"
      )
      try executeUnlocked(
        "DELETE FROM product_analytics_events WHERE id NOT IN (SELECT id FROM product_analytics_events ORDER BY created DESC LIMIT 1000)"
      )
      // Consume rejected epochs too, without reporting them as accepted.
      return .init(acceptedEventIDs: accepted, preference: preference, discardedEventIDs: discarded)
    }
  }
  func productAnalyticsLog(limit: Int = 500) throws -> [ProductAnalyticsLogEntry] {
    try withLock {
      let stmt = try prepareUnlocked(
        "SELECT payload,status FROM product_analytics_events ORDER BY created DESC LIMIT ?")
      defer { sqlite3_finalize(stmt) }
      sqlite3_bind_int(stmt, 1, Int32(max(1, min(1000, limit))))
      var rows: [ProductAnalyticsLogEntry] = []
      while sqlite3_step(stmt) == SQLITE_ROW {
        rows.append(
          .init(
            event: try JSONDecoder().decode(
              ProductAnalyticsEvent.self, from: blob(stmt, column: 0)),
            status: try text(stmt, column: 1)))
      }
      return rows
    }
  }
  func markProductAnalyticsDelivered(_ ids: [String]) throws {
    try transaction {
      for id in ids {
        let stmt = try prepareUnlocked(
          "UPDATE product_analytics_events SET status='delivered' WHERE id=?")
        defer { sqlite3_finalize(stmt) }
        try bind(id, at: 1, to: stmt)
        try stepDone(stmt)
      }
    }
  }
}
extension WorkspaceDatabase {
  public func productAnalyticsPreference() async throws -> ProductAnalyticsPreference {
    try await read { try $0.productAnalyticsPreference() }
  }
  public func setProductAnalyticsPreference(_ change: ProductAnalyticsPreferenceChange) async throws
    -> ProductAnalyticsPreference
  { try await write { try $0.setProductAnalyticsPreference(change) } }
  public func enqueueProductAnalytics(_ events: [ProductAnalyticsEvent]) async throws
    -> ProductAnalyticsAcknowledgement
  { try await write { try $0.enqueueProductAnalytics(events) } }
  public func productAnalyticsLog(limit: Int = 500) async throws -> [ProductAnalyticsLogEntry] {
    try await read { try $0.productAnalyticsLog(limit: limit) }
  }
  public func markProductAnalyticsDelivered(_ ids: [String]) async throws {
    try await write { try $0.markProductAnalyticsDelivered(ids) }
  }
}
