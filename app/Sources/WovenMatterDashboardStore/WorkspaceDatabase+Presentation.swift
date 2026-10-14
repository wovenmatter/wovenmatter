import Foundation
import WovenMatterClient
import WovenMatterCore

// Presentation projections use the async database facade's reader snapshot, so
// related rows share one committed revision without UI-thread SQL or N awaits.
extension WorkspaceDatabase {
  public func sessionNativeWorkingDirectories(ids: [String]) async throws -> [String: String] {
    try await read { connection in
      var result: [String: String] = [:]
      for id in ids { result[id] = (try? connection.sessionExecutionRoot(id: id))?.rootPath }
      return result
    }
  }
}
