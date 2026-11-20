import Foundation
import WovenProtocol

// Typed reads and writes for the `databases` rows. A row belongs to its
// owning machine, and only that machine's server writes it: it creates the
// row, records each copy it publishes, and deletes it.

extension Library {
  public func databases() async throws -> [Database] {
    try await read { db in
      try db.query("SELECT * FROM databases WHERE deleted = 0 ORDER BY name COLLATE NOCASE, id").map(Self.database)
    }
  }

  public func database(_ id: String) async throws -> Database? {
    try await read { db in
      try db.query("SELECT * FROM databases WHERE id = ? AND deleted = 0", [.text(id)]).first.map(Self.database)
    }
  }

  /// A database name with surrounding space removed, or an error when it is
  /// not 1–128 characters or holds a NUL.
  public static func databaseName(_ name: String) throws -> String {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= DatabaseLimits.maximumNameLength, !name.contains("\0") else {
      throw LibraryError(.invalid, "A database name must be 1 to \(DatabaseLimits.maximumNameLength) characters.")
    }
    return name
  }

  /// Records a new database on this machine with its first published copy.
  /// Its name must differ, ignoring case, from this machine's other databases.
  public func createDatabase(id: String, name: String, description: String, copy: ContentRef) async throws -> Database {
    let name = try Self.databaseName(name)
    let machineID = machineID
    let database = Database(id: id, machineID: machineID, name: name, description: description, copyDigest: copy.digest,
                            copySize: copy.size, copiedAt: Self.now(), createdAt: Self.now())
    try await write { writer in
      let taken = try writer.db.query("SELECT name FROM databases WHERE machine_id = ? AND deleted = 0", [.text(machineID)])
        .contains { ($0.text("name") ?? "").caseInsensitiveCompare(name) == .orderedSame }
      guard !taken else { throw LibraryError(.invalid, "This machine already has a database named \(name).") }
      try writer.put("databases", id: id, [
        "machine_id": .text(machineID), "name": .text(name), "description": .text(description),
        "copy_digest": .text(copy.digest), "copy_size": .integer(copy.size),
        "copied_at": .integer(Self.millis(database.copiedAt!)), "created_at": .integer(Self.millis(database.createdAt)),
      ])
    }
    return database
  }

  /// Records the copy this machine published after a write to its database.
  public func recordDatabaseCopy(_ id: String, _ copy: ContentRef) async throws -> Database {
    let machineID = machineID
    try await write { writer in
      guard let row = try writer.row("databases", id), !row.bool("deleted") else { throw LibraryError(.notFound, "No database \(id).") }
      guard row.text("machine_id") == machineID else {
        throw LibraryError(.notOwner(machineID: row.text("machine_id") ?? ""), "Another machine owns this database.")
      }
      try writer.put("databases", id: id, [
        "copy_digest": .text(copy.digest), "copy_size": .integer(copy.size), "copied_at": .integer(Writer.now()),
      ])
    }
    guard let database = try await database(id) else { throw LibraryError(.notFound, "No database \(id).") }
    return database
  }

  /// Deletes a database row in every library.
  public func deleteDatabase(_ id: String) async throws {
    try await delete("databases", id: id)
  }

  private static func database(_ row: Row) -> Database {
    Database(id: row.text("id") ?? "", machineID: row.text("machine_id") ?? "", name: row.text("name") ?? "",
             description: row.text("description") ?? "", copyDigest: row.text("copy_digest"), copySize: row.integer("copy_size"),
             copiedAt: row.integer("copied_at").map { Date(timeIntervalSince1970: Double($0) / 1000) },
             createdAt: row.date("created_at"))
  }
}
