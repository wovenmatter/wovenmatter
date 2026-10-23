import Darwin
import Foundation
import SQLite3
import Testing
import WovenMatterCore
@testable import WovenMatterClient

@Suite("Managed datasets")
struct ManagedDatabaseCatalogTests {
  private struct Fixture {
    let root: URL
    init() throws {
      let parent = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
      defer { free(parent) }
      root = URL(fileURLWithPath: String(cString: parent)).appending(path: "managed-datasets-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }

  @Test func backupsPreserveCommittedWALAndSeparateReplicaFromCopyAuthority() throws {
    let source = try Fixture(), replica = try Fixture(); defer { source.remove(); replica.remove() }
    let row = try AgentDatabaseCatalog.create(named: "Events", in: source.root, owner: "remote:owner")
    var writer: OpaquePointer?
    try #require(sqlite3_open(row.url.path, &writer) == SQLITE_OK)
    defer { sqlite3_close(writer) }
    try #require(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; CREATE TABLE events(value); INSERT INTO events VALUES(42)", nil, nil, nil) == SQLITE_OK)
    #expect(FileManager.default.fileExists(atPath: row.url.path + "-wal"))
    let older = try AgentDatabaseCatalog.snapshot(id: row.id, in: source.root)
    _ = try AgentDatabaseCatalog.importSnapshot(older, in: replica.root, sourceOwner: "remote:owner")
    #expect(try AgentDatabaseCatalog.query(id: row.id, sql: "SELECT value FROM events", in: replica.root).rows == [["42"]])
    _ = try AgentDatabaseCatalog.execute(id: row.id, sql: "ALTER TABLE events ADD COLUMN label; INSERT INTO events VALUES(43,'new')", in: source.root, owner: "remote:owner")
    let newer = try AgentDatabaseCatalog.snapshot(id: row.id, in: source.root)
    _ = try AgentDatabaseCatalog.importSnapshot(newer, in: replica.root, sourceOwner: "remote:owner")
    let retained = try AgentDatabaseCatalog.importSnapshot(older, in: replica.root, sourceOwner: "remote:owner")
    #expect(retained.revision == newer.database.revision)
    #expect(try AgentDatabaseCatalog.query(id: row.id, sql: "SELECT value,label FROM events ORDER BY value", in: replica.root).rows == [["42", ""], ["43", "new"]])
    #expect(throws: AgentDatabaseCatalogError.unsupportedManifest) {
      try AgentDatabaseCatalog.importSnapshot(newer, in: replica.root, sourceOwner: "other")
    }
    #expect(throws: AgentDatabaseCatalogError.unsupportedManifest) {
      try AgentDatabaseCatalog.importSnapshot(newer, in: replica.root, sourceOwner: "remote:owner", destinationOwner: "device:viewer")
    }
    #expect(throws: AgentDatabaseCatalogError.databaseUnavailable) {
      try AgentDatabaseCatalog.execute(id: row.id, sql: "DELETE FROM events", in: replica.root, owner: "device:viewer")
    }
      let copy = try AgentDatabaseCatalog.importSnapshot(newer, in: replica.root, sourceOwner: "remote:owner", copyName: "Copy", destinationOwner: "device:viewer")
    #expect(copy.id != row.id && copy.owner == "device:viewer" && copy.revision == 1)
    #expect(try AgentDatabaseCatalog.list(at: replica.root).first { $0.id == copy.id }?.revision == 1)
    #expect(try AgentDatabaseCatalog.execute(id: copy.id, sql: "INSERT INTO events VALUES(44,'copy')", in: replica.root, owner: "device:viewer").revision == 2)
    #expect(try AgentDatabaseCatalog.query(id: row.id, sql: "SELECT value FROM events ORDER BY value", in: source.root).rows == [["42"], ["43"]])
    #expect(try AgentDatabaseCatalog.query(id: copy.id, sql: "SELECT value FROM events ORDER BY value", in: replica.root).rows == [["42"], ["43"], ["44"]])
  }

}
