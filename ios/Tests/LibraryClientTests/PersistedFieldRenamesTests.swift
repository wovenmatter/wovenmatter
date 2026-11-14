import XCTest
@testable import LibraryClient

/// v0.4.2 saved the library's session list and change cursor under "central"
/// names. They are read once under the new names and written only as those.
final class PersistedFieldRenamesTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  /// Rewrites a saved file's envelope `state` keys to their v0.4.2 names.
  private func saveAsV042(_ file: URL, _ keys: [String: String]) throws {
    var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var state = try XCTUnwrap(root["state"] as? [String: Any])
    for (old, new) in keys { state[old] = state.removeValue(forKey: new) }
    root["state"] = state
    try JSONSerialization.data(withJSONObject: root).write(to: file)
  }

  func testTheJournalCursorAndRevisionsMoveOnce() throws {
    let file = try directory().appendingPathComponent("journal")
    var saved = WorkspaceJournalState(); saved.libraryID = "library"
    saved.libraryCursor = 42; saved.libraryWorkspaceRevisions = ["w": 7]
    try WorkspaceJournalPersistence.persist(saved, at: file)
    try saveAsV042(file, PersistedFieldRenames.journal)
    XCTAssertNotNil(String(data: try Data(contentsOf: file), encoding: .utf8)?.range(of: "\"centralCursor\""))
    let loaded = try WorkspaceJournalPersistence.load(at: file)
    XCTAssertEqual(loaded.libraryCursor, 42)
    XCTAssertEqual(loaded.libraryWorkspaceRevisions, ["w": 7])
    try WorkspaceJournalPersistence.persist(loaded, at: file)
    let rewritten = try XCTUnwrap(String(data: try Data(contentsOf: file), encoding: .utf8))
    XCTAssertNil(rewritten.range(of: "central"), "The next save writes only the new names")
  }

  func testTheStoreSessionListsMoveOnce() throws {
    let file = try directory().appendingPathComponent("library.json")
    var saved = MobileStoreState()
    saved.libraryConversationIDs = ["a", "b"]; saved.libraryDeletedConversationIDs = ["c"]
    _ = try MobileStorePersistence.persist(saved, at: file)
    try saveAsV042(file, PersistedFieldRenames.store)
    let loaded = try MobileStorePersistence.load(from: file)
    XCTAssertEqual(loaded.libraryConversationIDs, ["a", "b"])
    XCTAssertEqual(loaded.libraryDeletedConversationIDs, ["c"])
    let current = try Data(contentsOf: file)
    XCTAssertEqual(PersistedFieldRenames.upgrade(current, renaming: [:]), current)
  }

  func testFilesWithoutOldNamesAreReadUnchanged() throws {
    let data = Data(#"{"version":2,"state":{"libraryCursor":3}}"#.utf8)
    XCTAssertEqual(PersistedFieldRenames.upgrade(data, renaming: PersistedFieldRenames.journal), data)
  }
}
