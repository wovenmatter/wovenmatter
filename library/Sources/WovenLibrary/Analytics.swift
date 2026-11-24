import Foundation

// What anonymous usage statistics keep on this machine (`analytics`, local).
// Nothing in it syncs; the library-wide choices are ordinary settings.

extension Library {
  /// Takes a rate-limited signal's allowance: true, and the allowance is
  /// spent until `interval` has passed, when no attempt was made within
  /// `interval` before `now`. Attempts count, not deliveries, so a failed
  /// send does not make every later action try again.
  public func claimAnalyticsSignal(_ event: String, now: Date, interval: TimeInterval) async throws -> Bool {
    let key = "signal:" + event
    let time = Int64(now.timeIntervalSince1970 * 1000)
    let window = Int64(interval * 1000)
    return try await write { writer in
      let last = try writer.db.query("SELECT value FROM analytics WHERE key = ?", [.text(key)]).first?.text("value")
        .flatMap { Int64($0) }
      // A time ahead of the clock (it was set back) does not hold the signal off.
      if let last, last <= time, time - last < window { return false }
      try writer.db.run("""
        INSERT INTO analytics (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, [.text(key), .text(String(time))])
      return true
    }
  }

  /// Records `version` as the release this server runs, and returns the one
  /// recorded before it (nil the first time).
  public func exchangeAnalyticsVersion(_ version: String) async throws -> String? {
    try await write { writer in
      let previous = try writer.db.query("SELECT value FROM analytics WHERE key = 'version'").first?.text("value")
      try writer.db.run("""
        INSERT INTO analytics (key, value) VALUES ('version', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, [.text(version)])
      return previous
    }
  }
}
