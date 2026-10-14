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

  @Test func datasetsHaveIndependentSchemaAndOneWritableOwner() throws {
    let f = try Fixture(); defer { f.remove() }
    let first = try AgentDatabaseCatalog.create(named: "Sales / Q1", in: f.root, owner: "device:one")
    let second = try AgentDatabaseCatalog.create(named: "Research", in: f.root, owner: "device:two")
    #expect(first.id != second.id && UUID(uuidString: first.id) != nil)
    #expect(first.url.lastPathComponent == first.id + ".sqlite")
    let committed = try AgentDatabaseCatalog.execute(id: first.id,
      sql: "CREATE TABLE events(value INTEGER); INSERT INTO events VALUES(42);", in: f.root, owner: "device:one")
    #expect(committed.revision == 2)
    #expect(try AgentDatabaseCatalog.query(id: first.id, sql: "SELECT value FROM events", in: f.root).rows == [["42"]])
    #expect(throws: AgentDatabaseCatalogError.databaseUnavailable) {
      try AgentDatabaseCatalog.execute(id: first.id, sql: "DELETE FROM events", in: f.root, owner: "device:two")
    }
    #expect(throws: (any Error).self) { try AgentDatabaseCatalog.query(id: second.id, sql: "SELECT value FROM events", in: f.root) }
    #expect(throws: AgentDatabaseCatalogError.databaseAlreadyExists) {
      try AgentDatabaseCatalog.create(named: " sales / q1 ", in: f.root, owner: "device:one")
    }
  }

  @Test func failedSQLRollsBackSchemaDataAndRevision() throws {
    let f = try Fixture(); defer { f.remove() }
    let row = try AgentDatabaseCatalog.create(named: "Atomic", in: f.root, owner: "one")
    _ = try AgentDatabaseCatalog.execute(id: row.id, sql: "CREATE TABLE items(value INTEGER)", in: f.root, owner: "one")
    for sql in ["INSERT INTO items VALUES(1); INSERT INTO missing VALUES(2)",
                "CREATE TABLE transient(value); SELECT * FROM missing", "BEGIN; INSERT INTO items VALUES(3); COMMIT",
                "ATTACH '/tmp/wovenmatter-forbidden.sqlite' AS other", "PRAGMA writable_schema=ON"] {
      #expect(throws: (any Error).self) { try AgentDatabaseCatalog.execute(id: row.id, sql: sql, in: f.root, owner: "one") }
    }
    #expect(try AgentDatabaseCatalog.query(id: row.id, sql: "SELECT count(*) AS count FROM items", in: f.root).rows == [["0"]])
    #expect(try AgentDatabaseCatalog.query(id: row.id, sql: "SELECT count(*) AS count FROM sqlite_master WHERE name='transient'", in: f.root).rows == [["0"]])
    #expect(try AgentDatabaseCatalog.list(at: f.root).first?.revision == 2)
  }

  @Test func completeBackupsIncludeCommittedWALAndRejectStaleReplicas() throws {
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
  }

  @Test func copyingSnapshotCreatesIndependentIdentityAndDestinationAuthority() throws {
    let source = try Fixture(), destination = try Fixture(); defer { source.remove(); destination.remove() }
    let original = try AgentDatabaseCatalog.create(named: "Original", in: source.root, owner: "remote:one")
    _ = try AgentDatabaseCatalog.execute(id: original.id, sql: "CREATE TABLE values_table(value); INSERT INTO values_table VALUES(1)", in: source.root, owner: "remote:one")
    let snapshot = try AgentDatabaseCatalog.snapshot(id: original.id, in: source.root)
    let copy = try AgentDatabaseCatalog.importSnapshot(snapshot, in: destination.root, sourceOwner: "remote:one", copyName: "Copy", destinationOwner: "device:two")
    #expect(copy.id != original.id && copy.owner == "device:two" && copy.revision == 1)
    #expect(try AgentDatabaseCatalog.list(at: destination.root).first?.revision == 1)
    #expect(try AgentDatabaseCatalog.execute(id: copy.id, sql: "INSERT INTO values_table VALUES(2)", in: destination.root, owner: "device:two").revision == 2)
    #expect(try AgentDatabaseCatalog.query(id: original.id, sql: "SELECT value FROM values_table", in: source.root).rows == [["1"]])
    #expect(try AgentDatabaseCatalog.query(id: copy.id, sql: "SELECT value FROM values_table ORDER BY value", in: destination.root).rows == [["1"], ["2"]])
  }

  @Test func queryPreservesBinaryAndEmbeddedNullValuesAndRejectsWrites() throws {
    let f = try Fixture(); defer { f.remove() }
    let row = try AgentDatabaseCatalog.create(named: "Query values", in: f.root, owner: "one")
    let result = try AgentDatabaseCatalog.query(id: row.id, sql: "SELECT X'0001FF' AS binary, 'before'||char(0)||'after' AS text_value, NULL AS empty", in: f.root)
    #expect(result.rows == [["0001ff", "before\0after", ""]])
    for sql in ["CREATE TABLE forbidden(value)", "PRAGMA writable_schema=ON", "SELECT 1; SELECT 2", "SELECT load_extension('bad')"] {
      #expect(throws: (any Error).self) { try AgentDatabaseCatalog.query(id: row.id, sql: sql, in: f.root) }
    }
  }

  @Test func wideDatasetSchemaSurvivesCopyWhilePresentationColumnsStayBounded() throws {
    let source = try Fixture(), destination = try Fixture(); defer { source.remove(); destination.remove() }
    let row = try AgentDatabaseCatalog.create(named: "Wide dataset", in: source.root, owner: "owner")
    let columns = (0..<200).map { "column_\($0) INTEGER" }.joined(separator: ",")
    _ = try AgentDatabaseCatalog.execute(id: row.id, sql: "CREATE TABLE wide(\(columns)); INSERT INTO wide(column_0,column_199) VALUES(1,200)", in: source.root, owner: "owner")
    let snapshot = try AgentDatabaseCatalog.snapshot(id: row.id, in: source.root)
    let copy = try AgentDatabaseCatalog.importSnapshot(snapshot, in: destination.root, sourceOwner: "owner", copyName: "Copied wide dataset", destinationOwner: "destination")
    #expect(try AgentDatabaseCatalog.query(id: copy.id, sql: "SELECT column_0,column_199 FROM wide", in: destination.root).rows == [["1", "200"]])
    #expect(throws: (any Error).self) { try AgentDatabaseCatalog.query(id: copy.id, sql: "SELECT * FROM wide", in: destination.root) }
  }
}
