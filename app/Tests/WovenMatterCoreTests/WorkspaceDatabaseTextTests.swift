import Foundation
import SQLite3
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("SQLite text fidelity")
struct WorkspaceDatabaseTextTests {
  @Test func textBindingsAndRowsPreserveNULUnicodeEmptyAndNull() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
    let value = "before\0after 🪡 café"
    try await database.write { connection in
      try connection.executeUnlocked("CREATE TABLE text_fidelity(id TEXT PRIMARY KEY, body TEXT, optional TEXT)")
      try connection.toolsExecuteUnlocked("INSERT INTO text_fidelity VALUES(?,?,?)", ["id\0suffix", value, ""])
      try connection.toolsExecuteUnlocked("INSERT INTO text_fidelity VALUES(?,?,?)", ["id", "", nil])
    }
    try await database.read { connection in
      let query = try connection.prepareUnlocked("SELECT body,optional FROM text_fidelity WHERE id=?")
      defer { sqlite3_finalize(query) }
      try connection.bind("id\0suffix", at: 1, to: query)
      #expect(sqlite3_step(query) == SQLITE_ROW)
      #expect(try connection.text(query, column: 0) == value)
      #expect(connection.optionalText(query, column: 0) == value)
      #expect(connection.optionalText(query, column: 1) == "")
      let rows = try connection.historyRowsUnlocked("SELECT body,optional,typeof(body) AS kind FROM text_fidelity WHERE id=?", values: ["id"])
      #expect(rows.first?.objectValue?["body"]?.stringValue == "")
      #expect(rows.first?.objectValue?["optional"] == .null)
      #expect(rows.first?.objectValue?["kind"]?.stringValue == "text")
    }
  }

  @Test func deliveryRetryPreservesTextAfterNULAcrossConnections() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "workspace.sqlite")
    let database = try await WorkspaceDatabase(url: url)
    let owner = UUID()
    try await database.bindDeviceOwnership(ownerDeviceID: owner)
    let source = try await database.createLocalACPSession(runtimeKind: .codex, title: "Source", ownerDeviceID: owner)
    let target = try await database.createLocalACPSession(runtimeKind: .codex, title: "Target", ownerDeviceID: owner)
    let requestID = UUID().uuidString
    let body = "First\0second 🪡"
    let purpose = "Purpose\0suffix"
    let original = try await database.reserveToolDelivery(sourceID: source, targetID: target,
      text: body, requestID: requestID, purpose: purpose)
    let reopened = try await WorkspaceDatabase(url: url)
    let replay = try await reopened.reserveToolDelivery(sourceID: source, targetID: target,
      text: body, requestID: requestID, purpose: purpose)
    #expect(original.id == replay.id)
    #expect(replay.text == body)
    #expect(replay.purpose == purpose)
    #expect(try await reopened.sessionDeliveries(sessionID: source).count == 1)
  }
}
