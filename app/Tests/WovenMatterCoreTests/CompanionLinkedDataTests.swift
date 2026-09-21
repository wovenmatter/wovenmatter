import Foundation
import SQLite3
import XCTest
import WovenMatterCore
import WovenMatterDashboardStore

final class CompanionLinkedDataTests: XCTestCase {
  func testSQLitePreviewBoundsWorkCellsAndTotalResult() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: path) }
    var connection: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path.path, &connection), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE fixture(value TEXT)", nil, nil, nil), SQLITE_OK)
    sqlite3_close(connection)
    func read(_ query: String) throws -> DatabaseTabularData {
      try DatabaseLinkedData.load(from: path, preference: .sqlite, sqliteQuery: query)
    }
    let started = ProcessInfo.processInfo.systemUptime
    XCTAssertThrowsError(try read("WITH RECURSIVE t(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM t) SELECT sum(x) FROM t"))
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 4)
    XCTAssertThrowsError(try read("SELECT randomblob(\(DatabaseLinkedData.maximumSQLiteCellBytes + 1))"))
    XCTAssertThrowsError(try read("WITH RECURSIVE t(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM t WHERE x<20) SELECT quote(zeroblob(300000)) FROM t"))
    let normal = try read("SELECT 'Current' AS value, 'a' || char(0) || 'b' AS exact")
    XCTAssertEqual(normal.columns, ["value", "exact"])
    XCTAssertEqual(normal.rows, [["Current", "a\0b"]])
  }
}
