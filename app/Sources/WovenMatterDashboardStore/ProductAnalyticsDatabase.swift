import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  func createProductAnalyticsSchemaUnlocked() throws {
    try executeUnlocked(
      """
      CREATE TABLE IF NOT EXISTS product_analytics_preference(singleton INTEGER PRIMARY KEY CHECK(singleton=1), payload BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS product_analytics_events(id TEXT PRIMARY KEY, payload BLOB NOT NULL, status TEXT NOT NULL, created REAL NOT NULL);
      CREATE TABLE IF NOT EXISTS product_analytics_limits(name TEXT PRIMARY KEY, last_attempt REAL NOT NULL);
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
      if value.enabled != change.enabled || !change.enabled {
        value.revision += 1
        value.enabled = change.enabled
        let stmt = try prepareUnlocked(
          "UPDATE product_analytics_preference SET payload=? WHERE singleton=1")
        defer { sqlite3_finalize(stmt) }
        try bind(JSONEncoder().encode(value), at: 1, to: stmt)
        try stepDone(stmt)
      }
      return value
    }
  }
  func acceptProductAnalytics(_ events: [ProductAnalyticsEvent]) throws
    -> ProductAnalyticsAcknowledgement
  {
    try transaction {
      let preference = try productAnalyticsPreference()
      guard events.count <= 100 else {
        throw WorkspaceDatabaseError.execute("Analytics batch is too large.")
      }
      var accepted: [String] = []
      var discarded: [String] = []
      let now = Date()
      for event in events {
        guard let value = event.validated(preference: preference) else {
          discarded.append(event.id)
          continue
        }
        if value.rateLimited {
          let limit = try prepareUnlocked("SELECT last_attempt FROM product_analytics_limits WHERE name=?")
          defer { sqlite3_finalize(limit) }
          try bind(value.name.rawValue, at: 1, to: limit)
          if sqlite3_step(limit) == SQLITE_ROW,
            now.timeIntervalSince1970 - sqlite3_column_double(limit, 0) < ProductAnalyticsEvent.signalInterval {
            discarded.append(value.id)
            continue
          }
        }
        let stmt = try prepareUnlocked(
          "INSERT OR IGNORE INTO product_analytics_events(id,payload,status,created) VALUES(?,?,'attempted',?)"
        )
        defer { sqlite3_finalize(stmt) }
        try bind(value.id, at: 1, to: stmt)
        try bind(JSONEncoder().encode(value), at: 2, to: stmt)
        sqlite3_bind_double(stmt, 3, value.timestamp.timeIntervalSince1970)
        try stepDone(stmt)
        guard changedRowCountUnlocked > 0 else { discarded.append(value.id); continue }
        accepted.append(value.id)
        if value.rateLimited {
          let limit = try prepareUnlocked("INSERT OR REPLACE INTO product_analytics_limits VALUES(?,?)")
          defer { sqlite3_finalize(limit) }
          try bind(value.name.rawValue, at: 1, to: limit)
          sqlite3_bind_double(limit, 2, now.timeIntervalSince1970)
          try stepDone(limit)
        }
      }
      try executeUnlocked(
        "DELETE FROM product_analytics_events WHERE created < \(Date().addingTimeInterval(-7*86400).timeIntervalSince1970)"
      )
      try executeUnlocked(
        "DELETE FROM product_analytics_events WHERE id NOT IN (SELECT id FROM product_analytics_events ORDER BY created DESC LIMIT 500)"
      )
      // These bounded receipts deduplicate attempts; they are never replayed.
      let limits = try prepareUnlocked("SELECT name,last_attempt FROM product_analytics_limits")
      defer { sqlite3_finalize(limits) }
      var next: [String: Date] = [:]
      while sqlite3_step(limits) == SQLITE_ROW {
        next[try text(limits, column: 0)] = Date(timeIntervalSince1970:
          sqlite3_column_double(limits, 1) + ProductAnalyticsEvent.signalInterval)
      }
      return .init(acceptedEventIDs: accepted, preference: preference,
        discardedEventIDs: discarded, nextSignalAt: next)
    }
  }
  func markProductAnalytics(_ ids: [String], status: String) throws {
    try transaction {
      for id in ids {
        let stmt = try prepareUnlocked(
          "UPDATE product_analytics_events SET status=? WHERE id=?")
        defer { sqlite3_finalize(stmt) }
        try bind(status, at: 1, to: stmt)
        try bind(id, at: 2, to: stmt)
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
  public func acceptProductAnalytics(_ events: [ProductAnalyticsEvent]) async throws
    -> ProductAnalyticsAcknowledgement
  { try await write { try $0.acceptProductAnalytics(events) } }
  public func markProductAnalytics(_ ids: [String], status: String) async throws {
    try await write { try $0.markProductAnalytics(ids, status: status) }
  }
}
