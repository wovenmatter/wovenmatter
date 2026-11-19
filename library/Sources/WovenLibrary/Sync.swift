import Foundation
import WovenProtocol

extension Library {
  /// Rows of every synced table whose `changed` is above `after`, in
  /// `changed` order: what another machine asks for when it pulls.
  public func pull(after: Int64, limit: Int = 500, byteBudget: Int = 8 << 20) async throws -> SyncPage {
    let limit = max(1, limit)
    return try await read { db in
      var found: [(changed: Int64, row: SyncRow)] = []
      var tableFull = false
      for table in Schema.synced {
        let rows = try db.query("SELECT * FROM \(table.name) WHERE changed > ? ORDER BY changed LIMIT ?",
                                [.integer(after), .integer(Int64(limit))])
        if rows.count == limit { tableFull = true }
        for row in rows {
          found.append((row.integer("changed") ?? 0, SyncRow(
            table: table.name, id: row.text("id") ?? "", stamp: row.text("stamp") ?? "",
            deleted: row.bool("deleted"), editedFrom: table.keepsLoser ? row.text("edited_from") : nil,
            values: row.values(excluding: Table.standardColumns))))
        }
      }
      // Each table gave its first `limit` rows, so the first `limit` of all
      // of them together are the library's first `limit`.
      found.sort { $0.changed < $1.changed }
      var page: [SyncRow] = []
      var next = after
      var bytes = 0
      for entry in found {
        if page.count == limit || (!page.isEmpty && bytes >= byteBudget) { break }
        page.append(entry.row)
        next = entry.changed
        bytes += entry.row.approximateSize
      }
      return SyncPage(rows: page, next: next, more: page.count < found.count || tableFull)
    }
  }

  /// Applies a page pulled from `machineID` and records how far this library
  /// has received from it, in one transaction. Returns how many rows changed
  /// the library.
  @discardableResult
  public func apply(_ page: SyncPage, from machineID: String) async throws -> Int {
    try await write { writer in
      var changed = 0
      for row in page.rows where try writer.apply(row) { changed += 1 }
      try writer.setCursor(machineID, received: page.next)
      return changed
    }
  }

  /// How far this library has received `machineID`'s rows.
  public func cursor(for machineID: String) async throws -> Int64 {
    try await read { db in
      try db.query("SELECT received FROM sync_cursors WHERE machine_id = ?", [.text(machineID)]).first?.integer("received") ?? 0
    }
  }

  /// Writes columns of a synced row by its table's rule. The typed
  /// operations are built on this; areas without typed operations yet use it.
  @discardableResult
  public func put(_ table: String, id: String, _ values: [String: SQLValue]) async throws -> String {
    try await write { try $0.put(table, id: id, values) }
  }

  /// Deletes a synced row everywhere, and whatever belongs to it.
  public func delete(_ table: String, id: String) async throws {
    try await write { try $0.delete(table, id: id) }
  }

  /// A synced row as stored here, with its standard columns, or nil.
  public func row(_ table: String, id: String) async throws -> SyncRow? {
    guard let declared = Schema.byName[table], declared.synced else { throw LibraryError(.invalid, "\(table) is not synced.") }
    return try await read { db in
      try db.query("SELECT * FROM \(table) WHERE id = ?", [.text(id)]).first.map { row in
        SyncRow(table: table, id: id, stamp: row.text("stamp") ?? "", deleted: row.bool("deleted"),
                editedFrom: declared.keepsLoser ? row.text("edited_from") : nil,
                values: row.values(excluding: Table.standardColumns))
      }
    }
  }

  /// Every live row of a synced table whose `column` equals `value`.
  public func rows(_ table: String, where column: String, is value: SQLValue) async throws -> [SyncRow] {
    guard let declared = Schema.byName[table], declared.synced,
          declared.allColumns.contains(where: { $0.name == column }) else {
      throw LibraryError(.invalid, "\(table).\(column) is not a synced column.")
    }
    return try await read { db in
      try db.query("SELECT * FROM \(table) WHERE \(column) = ? AND deleted = 0 ORDER BY id", [value]).map { row in
        SyncRow(table: table, id: row.text("id") ?? "", stamp: row.text("stamp") ?? "", deleted: false,
                editedFrom: declared.keepsLoser ? row.text("edited_from") : nil,
                values: row.values(excluding: Table.standardColumns))
      }
    }
  }
}

extension SyncRow {
  var approximateSize: Int {
    values.values.reduce(id.utf8.count + stamp.utf8.count + 64) { total, value in
      switch value {
      case .text(let text): total + text.utf8.count
      case .blob(let data): total + data.count * 4 / 3
      default: total + 16
      }
    }
  }
}
