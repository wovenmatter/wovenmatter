import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterLibraryStore

@Suite("History text windows")
struct WorkspaceHistoryTextWindowTests {
  @Test func NULAndUnicodeScalarWindowsRetainSuffixAndReportPagination() async throws {
    let persistence = try PersistenceFixture(); defer { persistence.remove() }
    let database = try await persistence.openDatabase()
    let owner = UUID()
    let session = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Windows", ownerDeviceID: owner)
    for value in ["\0é🪡z", "é\0🪡z", "é🪡z\0", "e\u{0301}\0🪡z"] {
      let run = try await database.beginLocalACPRun(conversationID: session, input: .init(text: value))
      try await database.completeLocalACPRun(runID: run.runID)
      let eventID = UUID().uuidString
      try await database.recordHistory(.init(id: eventID, conversationID: session,
        harness: "fixture", kind: "wire.in", payload: value))
      let scalars = Array(value.unicodeScalars)
      for command in ["message", "conversation", "event"] {
        for offset in 0...scalars.count {
          var query = WorkspaceHistoryQuery(command: command,
            id: command == "event" ? eventID : command == "message" ? run.userMessageID : session)
          query.offset = offset
          query.characters = 2
          let result = try await database.queryAgentHistory(query, callerID: session)
          let rows = result.objectValue?["rows"]?.arrayValue ?? []
          let row = try #require(command == "conversation"
            ? rows.first(where: { $0.objectValue?["id"]?.stringValue == run.userMessageID })?.objectValue
            : rows.first?.objectValue)
          let field = command == "event" ? "payload" : "content"
          let expected = String(String.UnicodeScalarView(scalars.dropFirst(offset).prefix(2)))
          #expect(row[field]?.stringValue == expected)
          #expect(row[field + "_characters"]?.intValue == scalars.count)
          // Query offsets retain the existing TEXT-bound JSON representation.
          #expect(row[field + "_offset"]?.stringValue == String(offset))
          #expect(row[field + "_has_more"]?.intValue == (offset + 2 < scalars.count ? 1 : 0))
        }
      }
    }
    let large = "\0" + String(repeating: "x", count: 9_000)
    let eventID = UUID().uuidString
    try await database.recordHistory(.init(id: eventID, conversationID: session,
      harness: "fixture", kind: "wire.in", payload: large))
    let page = try await database.queryAgentHistory(.init(command: "events", conversationID: session, harness: "fixture", kind: "wire.in"), callerID: session)
    let row = try #require(page.objectValue?["rows"]?.arrayValue?.first(where: {
      $0.objectValue?["id"]?.stringValue == eventID
    })?.objectValue)
    #expect(row["payload_characters"]?.intValue == 9_001)
    #expect(row["payload"] == .null)
  }
}
