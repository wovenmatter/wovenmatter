import Foundation
import Testing
import WovenMatterCompanion
@testable import WovenMatterDashboardStore

struct DictationHistoryTests {
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
