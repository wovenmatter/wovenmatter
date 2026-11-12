import Foundation
import WovenMatterShared

public protocol LibraryDictationTransport: Sendable {
  func dictationChanges(after: Int64) async throws -> DictationHistoryPage
  func publishDictation(_ record: DictationRecord) async throws -> DictationRecord
}
extension HTTPSLibraryTransport: LibraryDictationTransport {
  public func dictationChanges(after: Int64) async throws -> DictationHistoryPage { try await request("v1/dictations", query: [URLQueryItem(name: "after", value: String(after))]) }
  public func publishDictation(_ record: DictationRecord) async throws -> DictationRecord {
    try await request("v1/dictations", method: "POST", body: JSONEncoder().encode(record))
  }
}
extension MobileSyncEngine {
  func synchronizeDictations(using transport: any LibraryDictationTransport, identity: String) async throws {
    let history = store.dictations
    try await history.bindWorkspace(identity)
    for record in try await history.pending(workspaceID: identity) {
      let receipt = try await transport.publishDictation(record)
      guard receipt == record else { throw DictationHistoryError.invalidPage }
      try await history.acknowledge(receipt, workspaceID: identity)
    }
    for _ in 0..<100 {
      try Task.checkCancellation()
      let cursor = try await history.cursor()
      let page = try await transport.dictationChanges(after: cursor)
      try await history.apply(page, after: cursor)
      setLaneHasMore(.dictation, page.hasMore)
      if !page.hasMore { break }
    }
  }
}
