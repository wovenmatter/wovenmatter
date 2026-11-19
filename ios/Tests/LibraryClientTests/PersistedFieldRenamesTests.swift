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
  /// Rewrites a saved index as v0.4.2 saved it: the `state` keys under their
  /// earlier names, and the numbers that release wrote beside them.
  private func saveAsV042(_ file: URL, _ keys: [String: String]) throws {
    var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var state = try XCTUnwrap(root["state"] as? [String: Any])
    for (old, new) in keys { state[old] = state.removeValue(forKey: new) }
    state["formatVersion"] = 1
    root["state"] = state; root["version"] = 2
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
    for text in [#"{"version":2,"state":{"libraryCursor":3}}"#, #"{"state":{"libraryCursor":3}}"#] {
      let data = Data(text.utf8)
      XCTAssertEqual(PersistedFieldRenames.upgrade(data, renaming: PersistedFieldRenames.journal), data)
    }
  }

  /// The saved index is recognised by its `state` object, with or without the
  /// number an earlier release wrote beside it. Nothing else is touched.
  func testOldNamesMoveInsideAnyStateAndNowhereElse() throws {
    func upgraded(_ text: String) throws -> [String: Any] {
      let data = PersistedFieldRenames.upgrade(Data(text.utf8), renaming: PersistedFieldRenames.journal)
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    for text in [#"{"version":2,"state":{"centralCursor":3}}"#, #"{"state":{"centralCursor":3}}"#] {
      let state = try XCTUnwrap(try upgraded(text)["state"] as? [String: Any])
      XCTAssertEqual(state["libraryCursor"] as? Int, 3); XCTAssertNil(state["centralCursor"])
    }
    let other = Data(#"{"centralCursor":3}"#.utf8)
    XCTAssertEqual(PersistedFieldRenames.upgrade(other, renaming: PersistedFieldRenames.journal), other)
  }
}
