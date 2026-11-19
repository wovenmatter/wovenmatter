import Foundation
import WovenProtocol

/// The write side of the library, used only on the write lane inside one
/// transaction. Everything a write must also do (stamps, the `changed`
/// counter, deletions spreading to rows that belong to the deleted one, saved
/// losers) happens here, in code. There are no triggers.
final class Writer {
  let db: Connection
  let machineID: String
  private(set) var clock: HybridClock
  private(set) var counter: Int64

  private init(db: Connection, machineID: String, clock: HybridClock, counter: Int64) {
    self.db = db
    self.machineID = machineID
    self.clock = clock
    self.counter = counter
  }

  /// Reads this machine's identity, creating it on first start, and makes
  /// sure the machine has its row.
  static func open(_ db: Connection, machineName: String) throws -> Writer {
    let existing = try db.query("SELECT * FROM this_machine LIMIT 1").first
    let machineID = existing?.text("id") ?? UUID().uuidString.lowercased()
    if existing == nil { try db.run("INSERT INTO this_machine (id) VALUES (?)", [.text(machineID)]) }
    let writer = Writer(db: db, machineID: machineID,
                        clock: HybridClock(machine: machineID, last: existing?.text("clock") ?? ""),
                        counter: existing?.integer("changed") ?? 0)
    _ = try writer.transaction { writer in
      if try writer.row("machines", machineID) == nil {
        try writer.put("machines", id: machineID, ["name": .text(machineName), "created_at": .integer(Writer.now())])
      }
    }
    return writer
  }

  static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

  /// Runs `body` in one transaction. Returns its result, the counter after,
  /// and whether the counter moved. On failure the clock and counter go back.
  func transaction<T>(_ body: (Writer) throws -> T) throws -> (T, Int64, Bool) {
    let before = (clock, counter)
    do {
      let result = try db.transaction {
        let result = try body(self)
        if clock.last != before.0.last || counter != before.1 {
          try db.run("UPDATE this_machine SET clock = ?, changed = ?", [.text(clock.last?.text ?? ""), .integer(counter)])
        }
        return result
      }
      return (result, counter, counter != before.1)
    } catch {
      (clock, counter) = before
      throw error
    }
  }

  // MARK: Local writes

  func row(_ table: String, _ id: String) throws -> Row? {
    try db.query("SELECT * FROM \(table) WHERE id = ?", [.text(id)]).first
  }

  /// Writes columns of one synced row: inserts it, or updates the columns
  /// given. Returns the row's new stamp.
  @discardableResult
  func put(_ tableName: String, id: String, _ values: [String: SQLValue]) throws -> String {
    let table = try synced(tableName)
    let current = try row(table.name, id)
    if current?.bool("deleted") == true { throw LibraryError(.notFound, "\(tableName) \(id) was deleted.") }
    if table.rule == .appendOnly, current != nil { throw LibraryError(.invalid, "\(tableName) rows are never edited.") }
    if try hasDeletedParent(table, values.merging(current?.values(excluding: []) ?? [:]) { new, _ in new }) {
      throw LibraryError(.notFound, "What this \(tableName) row belongs to was deleted.")
    }
    let declared = Set(table.columns.map(\.name))
    var columns = values.filter { declared.contains($0.key) }
    let stamp = clock.tick()
    columns["stamp"] = .text(stamp)
    columns["changed"] = .integer(nextChanged())
    if table.keepsLoser {
      // A run of writes by one machine keeps the stamp the run started from.
      if let current, let currentStamp = current.text("stamp") {
        columns["edited_from"] = Stamp.machine(of: currentStamp) == machineID ? current["edited_from"] : .text(currentStamp)
      } else {
        columns["edited_from"] = .null
      }
    }
    if current == nil {
      columns["id"] = .text(id)
      try insert(table.name, columns, replacing: false)
    } else {
      let names = Array(columns.keys)
      try db.run("UPDATE \(table.name) SET \(names.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?",
                 names.map { columns[$0]! } + [.text(id)])
    }
    return stamp
  }

  /// Deletes a synced row: it stays as a marker with its content cleared, so
  /// the deletion spreads. Rows that belong to it go too.
  func delete(_ tableName: String, id: String) throws {
    let table = try synced(tableName)
    guard let current = try row(table.name, id), !current.bool("deleted") else { return }
    try writeMarker(table, id: id, stamp: clock.tick())
    try cascade(from: table, id: id)
  }

  // MARK: Rows from other machines

  /// Applies one row received from another machine by its table's rule.
  /// Returns whether the library changed.
  @discardableResult
  func apply(_ incoming: SyncRow) throws -> Bool {
    let table = try synced(incoming.table)
    clock.observe(incoming.stamp)
    if !incoming.deleted, try hasDeletedParent(table, incoming.values) { return false }
    guard let local = try row(table.name, incoming.id) else {
      try store(table, incoming)
      if incoming.deleted { try cascade(from: table, id: incoming.id) }
      return true
    }
    let localStamp = local.text("stamp") ?? ""
    let localDeleted = local.bool("deleted")

    // A deletion is final: it beats every edit, made before or after it, and
    // the newest of two deletions wins.
    if localDeleted || incoming.deleted {
      guard incoming.deleted, !localDeleted || incoming.stamp > localStamp else { return false }
      try store(table, incoming)
      if !localDeleted { try cascade(from: table, id: incoming.id) }
      return true
    }

    switch table.rule {
    case .local, .appendOnly:
      return false
    case .newestWins:
      guard incoming.stamp > localStamp else { return false }
      try store(table, incoming)
      return true
    case .newestWinsKeepLoser(let history):
      guard incoming.stamp != localStamp else { return false }
      let mine = Version(stamp: localStamp, editedFrom: local.text("edited_from"))
      let theirs = Version(stamp: incoming.stamp, editedFrom: incoming.editedFrom)
      if incoming.stamp > localStamp {
        if !mine.isAncestor(of: theirs) {
          try saveLoser(history, of: table, id: incoming.id, stamp: localStamp, values: local.values(excluding: Table.standardColumns))
        }
        try store(table, incoming)
        return true
      }
      guard !theirs.isAncestor(of: mine) else { return false }
      return try saveLoser(history, of: table, id: incoming.id, stamp: incoming.stamp, values: incoming.values)
    }
  }

  func setCursor(_ machineID: String, received: Int64) throws {
    try db.run("INSERT INTO sync_cursors (machine_id, received) VALUES (?, ?) " +
               "ON CONFLICT(machine_id) DO UPDATE SET received = excluded.received",
               [.text(machineID), .integer(received)])
  }

  // MARK: Helpers

  private func nextChanged() -> Int64 {
    counter += 1
    return counter
  }

  private func synced(_ name: String) throws -> Table {
    guard let table = Schema.byName[name], table.synced else {
      throw LibraryError(.invalid, "\(name) is not a synced table.")
    }
    return table
  }

  /// Stores a received row exactly as it came, with a new local `changed`.
  private func store(_ table: Table, _ incoming: SyncRow) throws {
    var columns: [String: SQLValue] = [
      "id": .text(incoming.id),
      "stamp": .text(incoming.stamp),
      "changed": .integer(nextChanged()),
      "deleted": .integer(incoming.deleted ? 1 : 0),
    ]
    if table.keepsLoser { columns["edited_from"] = incoming.editedFrom.map(SQLValue.text) ?? .null }
    for column in table.columns { columns[column.name] = incoming.values[column.name] ?? column.fallback ?? .null }
    try insert(table.name, columns, replacing: true)
  }

  private func insert(_ table: String, _ columns: [String: SQLValue], replacing: Bool) throws {
    let names = Array(columns.keys)
    try db.run("INSERT \(replacing ? "OR REPLACE " : "")INTO \(table) (\(names.joined(separator: ", "))) " +
               "VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))", names.map { columns[$0]! })
  }

  private func writeMarker(_ table: Table, id: String, stamp: String) throws {
    var columns: [(String, SQLValue)] = [("deleted", .integer(1)), ("stamp", .text(stamp)), ("changed", .integer(nextChanged()))]
    if table.keepsLoser { columns.append(("edited_from", .null)) }
    columns += table.columns.map { ($0.name, $0.fallback ?? .null) }
    try db.run("UPDATE \(table.name) SET \(columns.map { "\($0.0) = ?" }.joined(separator: ", ")) WHERE id = ?",
               columns.map(\.1) + [.text(id)])
  }

  /// Removes what belongs to a deleted row. Append-only rows are dropped
  /// here (and refused if they arrive later); other rows become markers.
  private func cascade(from parent: Table, id: String) throws {
    for child in Schema.synced {
      for link in child.parents where link.table == parent.name {
        let ids = try db.query("SELECT id FROM \(child.name) WHERE \(link.column) = ? AND deleted = 0", [.text(id)])
          .compactMap { $0.text("id") }
        for childID in ids {
          if child.rule == .appendOnly {
            try db.run("DELETE FROM \(child.name) WHERE id = ?", [.text(childID)])
          } else {
            try writeMarker(child, id: childID, stamp: clock.tick())
          }
          try cascade(from: child, id: childID)
        }
      }
    }
  }

  private func hasDeletedParent(_ table: Table, _ values: [String: SQLValue]) throws -> Bool {
    for link in table.parents {
      guard case .text(let parentID) = values[link.column] ?? .null else { continue }
      if try row(link.table, parentID)?.bool("deleted") == true { return true }
    }
    return false
  }

  /// Saves the losing side of two writes made apart into version history.
  /// Its id and stamp come from the loser, so every machine that resolves
  /// the same conflict saves the same row.
  @discardableResult
  private func saveLoser(_ historyName: String, of table: Table, id: String, stamp: String,
                         values: [String: SQLValue]) throws -> Bool {
    let history = try synced(historyName)
    let versionID = "\(id):\(stamp)"
    guard try row(history.name, versionID) == nil, let link = history.parents.first(where: { $0.table == table.name }) else {
      return false
    }
    var columns: [String: SQLValue] = [
      "id": .text(versionID), "stamp": .text(stamp), "changed": .integer(nextChanged()), "deleted": .integer(0),
      link.column: .text(id), "version_stamp": .text(stamp),
      "saved_at": .integer(Stamp(text: stamp)?.time ?? 0),
    ]
    for column in history.columns where columns[column.name] == nil {
      columns[column.name] = values[column.name] ?? column.fallback ?? .null
    }
    try insert(history.name, columns, replacing: false)
    return true
  }
}

/// One write of a row kept with version history, for telling whether one
/// write was made on top of another.
private struct Version {
  let stamp: String
  let editedFrom: String?

  /// `other` was written on top of this write: directly, or later in the
  /// same machine's run of writes from the same starting point.
  func isAncestor(of other: Version) -> Bool {
    if other.editedFrom == stamp { return true }
    return Stamp.machine(of: stamp) == Stamp.machine(of: other.stamp) && editedFrom == other.editedFrom && stamp < other.stamp
  }
}
