import Foundation
import WovenProtocol

extension Library {
  /// Rows of every synced table whose `changed` is above `after`, in
  /// `changed` order: what another machine asks for when it pulls. At most
  /// `limit` rows, and no more after their size reaches `byteBudget`.
  /// The synced tables with a row whose `changed` is above `after`, read
  /// through each table's `changed` index.
  public func tablesChanged(after: Int64) async throws -> [String] {
    try await read { db in
      try Schema.synced.filter { table in
        try !db.query("SELECT 1 FROM \(table.name) WHERE changed > ? LIMIT 1", [.integer(after)]).isEmpty
      }.map(\.name)
    }
  }

  public func pull(after: Int64, limit: Int = 500, byteBudget: Int = 8 << 20) async throws -> SyncPage {
    let limit = max(1, limit)
    return try await read { db in
      // Only which rows come next is read across every table, through each
      // table's `changed` index; each row is then read whole, in order,
      // until the budget is spent.
      let order = Schema.synced.map {
        "SELECT * FROM (SELECT '\($0.name)' AS name, id, changed FROM \($0.name) WHERE changed > ?1 ORDER BY changed LIMIT ?2)"
      }.joined(separator: " UNION ALL ") + " ORDER BY changed LIMIT ?2"
      let next = try db.query(order, [.integer(after), .integer(Int64(limit) + 1)])
      var page: [SyncRow] = []
      var cursor = after
      var bytes = 0
      for entry in next.prefix(limit) {
        if !page.isEmpty && bytes >= byteBudget { break }
        guard let table = Schema.byName[entry.text("name") ?? ""], let id = entry.text("id"),
              let row = try db.query("SELECT * FROM \(table.name) WHERE id = ?", [.text(id)]).first else { continue }
        let synced = SyncRow(row, table: table.name)
        page.append(synced)
        cursor = entry.integer("changed") ?? cursor
        bytes += synced.approximateSize
      }
      return SyncPage(rows: page, next: cursor, more: page.count < next.count)
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

  /// When this library last received rows from `machineID`, or nil if never.
  public func lastReceived(from machineID: String) async throws -> Date? {
    try await read { db in
      try db.query("SELECT received_at FROM sync_cursors WHERE machine_id = ?", [.text(machineID)]).first?
        .integer("received_at").map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
  }

  // MARK: Over a connection

  /// Pulls everything past this library's cursor for `machineID` from that
  /// machine's server, a page at a time, until nothing is left.
  public func pull(from client: Client, machineID: String) async throws {
    while true {
      let page = try await client.call(SyncPull(after: try await cursor(for: machineID)))
      try await apply(page, from: machineID)
      if !page.more { return }
    }
  }

  /// Hands a server this library's rows past the cursor the server keeps for
  /// it, a page at a time: how a device's rows reach a server, since nothing
  /// can connect to a device. Only a device's connection may.
  public func push(to client: Client) async throws {
    var cursor = try await client.call(SyncCursor())
    while true {
      let page = try await pull(after: cursor)
      if page.rows.isEmpty { return }
      _ = try await client.call(SyncPush(page: page))
      cursor = page.next
      if !page.more { return }
    }
  }

  /// Keeps a device's library and one server's level over the connection
  /// the device opened and said hello on, until the connection closes or
  /// this device is removed: pulls whenever the server announces a change
  /// and pushes whenever this library changes. `machineID` is the server's.
  public func follow(_ client: Client, machineID: String) async throws {
    let announced = try await client.subscribe(SubscribeLibrary())
    let changes = changes()
    try await pull(from: client, machineID: machineID)
    try await push(to: client)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for try await _ in announced.events { try await self.pull(from: client, machineID: machineID) }
      }
      group.addTask {
        for await _ in changes { try await self.push(to: client) }
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  }

  /// Writes columns of a synced row by its table's rule. The typed
  /// operations are built on this; areas without typed operations yet use it.
  @discardableResult
  public func put(_ table: String, id: String, _ values: [String: SQLValue]) async throws -> String {
    try await write { try $0.put(table, id: id, values) }
  }

  /// Deletes a synced row everywhere, and whatever belongs to it. A row of a
  /// natural-key table (a setting, a sealed secret) is unset instead: its
  /// value is cleared with a new stamp, and it can be set again.
  public func delete(_ table: String, id: String) async throws {
    try await write { try $0.delete(table, id: id) }
  }

  /// A synced row as stored here, with its standard columns, or nil.
  public func row(_ table: String, id: String) async throws -> SyncRow? {
    guard let declared = Schema.byName[table], declared.synced else { throw LibraryError(.invalid, "\(table) is not synced.") }
    return try await read { db in
      try db.query("SELECT * FROM \(table) WHERE id = ?", [.text(id)]).first.map { SyncRow($0, table: declared.name) }
    }
  }

  /// Every live row of a synced table whose `column` equals `value`.
  public func rows(_ table: String, where column: String, is value: SQLValue) async throws -> [SyncRow] {
    guard let declared = Schema.byName[table], declared.synced,
          declared.allColumns.contains(where: { $0.name == column }) else {
      throw LibraryError(.invalid, "\(table).\(column) is not a synced column.")
    }
    return try await read { db in
      try db.query("SELECT * FROM \(table) WHERE \(column) = ? AND deleted = 0 ORDER BY id", [value])
        .map { SyncRow($0, table: declared.name) }
    }
  }
}

extension SyncRow {
  /// A stored row as it travels, without the local `changed` counter.
  init(_ row: Row, table: String) {
    self.init(table: table, id: row.text("id") ?? "", stamp: row.text("stamp") ?? "", deleted: row.bool("deleted"),
              values: row.values(excluding: Table.standardColumns))
  }

  var approximateSize: Int {
    id.utf8.count + stamp.utf8.count + Writer.size(of: values)
  }
}
