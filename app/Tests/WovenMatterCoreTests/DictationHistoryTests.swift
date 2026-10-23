import Foundation
import Testing
import WovenMatterCompanion
@testable import WovenMatterDashboardStore

struct DictationHistoryTests {
  @Test func historyPagesHaveStableOrderingAndBoundedResults() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    #expect(try await store.dictationHistory(limit: 21, offset: 0).isEmpty)
    var expected: [DictationRecord] = []
    for index in 0..<40 {
      // Equal timestamps exercise the ID tie-breaker across page boundaries.
      let record = DictationRecord(text: "Transcript \(index)\nFull text", createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index / 3)))
      expected.append(record)
      try await store.saveDictation(record)
    }
    expected.sort { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
    let first = try await store.dictationHistory(limit: 21, offset: 0)
    let last = try await store.dictationHistory(limit: 21, offset: 20)
    #expect(first == Array(expected.prefix(21)))
    #expect(last == Array(expected.suffix(20)), "An exact final page has no extra row and disables Next")
    #expect(Array(first.prefix(20)) + last == expected)
    #expect(try await store.dictationHistory(limit: 21, offset: 40).isEmpty)
    #expect(try await store.dictationHistory(limit: 21, offset: 0) == first, "Previous returns to the same page")
    let newest = DictationRecord(text: "A new dictation", createdAt: Date(timeIntervalSince1970: 1_800_000_100))
    try await store.saveDictation(newest)
    #expect(try await store.dictationHistory(limit: 21, offset: 0).first == newest)
    #expect(try await store.dictationHistory(limit: 21, offset: 20).count == 21)
    #expect(try await store.dictationHistory(limit: 21, offset: 40) == [expected.last!])
  }

  @Test func historyPersistsAndReplayIsIdempotentAndPagedByArrival() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "workspace.sqlite")
    let database = try await WorkspaceDatabase(url: url)
    let newest = DictationRecord(text: "Newest 🪡\nFull transcript", createdAt: Date(timeIntervalSince1970: 200))
    try await database.saveDictation(newest)
    try await database.saveDictation(newest)
    let first = try await database.dictationChanges(after: 0)
    #expect(first.records == [newest])
    #expect(!first.hasMore)
    let offline = DictationRecord(text: "Earlier offline dictation", createdAt: Date(timeIntervalSince1970: 150))
    try await database.saveDictation(offline)
    let changes = try await database.dictationChanges(after: first.cursor)
    #expect(changes.records == [offline])
    for i in 0..<101 { try await database.saveDictation(DictationRecord(text: "Dictation \(i)", createdAt: Date(timeIntervalSince1970: Double(i)))) }
    let page = try await database.dictationChanges(after: changes.cursor)
    #expect(page.records.count == 100 && page.hasMore)
    let final = try await database.dictationChanges(after: page.cursor)
    #expect(final.records.count == 1 && !final.hasMore)
    let reopened = try await WorkspaceDatabase(url: url)
    #expect(try await reopened.dictationHistory(limit: 2) == [newest, offline])
    #expect(try await reopened.dictationHistory(limit: 200).count == 103)
    var conflict = newest; conflict.text = "Changed text"
    await #expect(throws: DictationHistoryError.self) { try await reopened.saveDictation(conflict) }
    await #expect(throws: DictationHistoryError.self) { try await reopened.saveDictation(.init(text: "  ")) }
  }
}
