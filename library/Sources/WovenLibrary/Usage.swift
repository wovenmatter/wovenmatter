import Foundation
import WovenProtocol

// Reads of usage records and dictation history, summed in SQL so a reply
// covers every machine without carrying every record.

extension Library {
  /// Usage from `start` up to `end`, summed per machine, session, runtime,
  /// model and period of `periodSeconds`, with the range's totals.
  public func usage(from start: Date, to end: Date, periodSeconds: Int) async throws -> UsageReport {
    let period = Int64(max(periodSeconds, 60)) * 1000
    let range: [SQLValue] = [.integer(Self.millis(start)), .integer(Self.millis(end))]
    return try await read { db in
      let sums = """
        SUM(input_tokens) AS input, SUM(output_tokens) AS output, SUM(cache_read_tokens) AS cache_read,
        SUM(cache_write_tokens) AS cache_write, SUM(cost) AS cost, COUNT(*) AS turns
        """
      let inRange = "deleted = 0 AND recorded_at >= ? AND recorded_at < ?"
      let groups = try db.query("""
        SELECT (recorded_at / \(period)) * \(period) AS period, MAX(recorded_at) AS latest, machine_id, session_id,
          runtime, model, \(sums)
        FROM usage_records WHERE \(inRange)
        GROUP BY period, machine_id, session_id, runtime, model ORDER BY period, latest
        """, range).map { row in
        UsageGroup(period: row.date("period"), latest: row.date("latest"), machineID: row.text("machine_id") ?? "",
                   sessionID: row.text("session_id"), runtime: RuntimeKind(rawValue: row.text("runtime") ?? ""),
                   model: row.text("model") ?? "", amounts: Self.amounts(row))
      }
      let total = try db.query("SELECT \(sums), COUNT(DISTINCT session_id) AS sessions FROM usage_records WHERE \(inRange)",
                               range).first
      var newest: [String: Date] = [:]
      for row in try db.query("SELECT machine_id, MAX(recorded_at) AS newest FROM usage_records WHERE deleted = 0 GROUP BY machine_id") {
        newest[row.text("machine_id") ?? ""] = row.date("newest")
      }
      return UsageReport(groups: groups, totals: total.map(Self.amounts) ?? UsageAmounts(),
                         sessions: Int(total?.integer("sessions") ?? 0), newestByMachine: newest)
    }
  }

  private static func amounts(_ row: Row) -> UsageAmounts {
    let cost: Double = switch row["cost"] {
    case .real(let value): value
    case .integer(let value): Double(value)
    default: 0
    }
    return UsageAmounts(input: row.integer("input") ?? 0, output: row.integer("output") ?? 0,
                        cacheRead: row.integer("cache_read") ?? 0, cacheWrite: row.integer("cache_write") ?? 0,
                        cost: cost, turns: Int(row.integer("turns") ?? 0))
  }

  // MARK: Dictation history

  /// Saves a dictation made on this machine. A retried save of the same `id`
  /// changes nothing.
  public func saveDictation(id: String, text: String, recordedAt: Date) async throws {
    try await write { writer in
      guard try writer.row("dictation_history", id) == nil else { return }
      try writer.put("dictation_history", id: id, [
        "machine_id": .text(writer.machineID), "text": .text(text), "recorded_at": .integer(Self.millis(recordedAt)),
      ])
    }
  }

  /// Dictations from every machine, newest first.
  public func dictations(limit: Int, offset: Int) async throws -> [Dictation] {
    try await read { db in
      try db.query("""
        SELECT id, machine_id, text, recorded_at FROM dictation_history WHERE deleted = 0
        ORDER BY recorded_at DESC, id LIMIT ? OFFSET ?
        """, [.integer(Int64(max(limit, 0))), .integer(Int64(max(offset, 0)))]).map { row in
        Dictation(id: row.text("id") ?? "", machineID: row.text("machine_id") ?? "", text: row.text("text") ?? "",
                  recordedAt: row.date("recorded_at"))
      }
    }
  }
}
