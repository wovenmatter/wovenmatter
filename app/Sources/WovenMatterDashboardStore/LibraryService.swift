import Foundation
import WovenMatterClient
import WovenMatterCore

public struct LibraryLocation: Equatable, Sendable {
  public let conversationID: String
  public let name: String
  public let root: String
  public init(conversationID: String, name: String, root: String) {
    self.conversationID = conversationID; self.name = name; self.root = root
  }
}

public actor LibraryService {
  private let database: WorkspaceDatabase
  private let files: LibraryFileStore
  private let remoteFiles: RemoteLibraryFiles
  private var synchronizing = false
  private var knownLocations: [String: LibraryLocation] = [:]
  private var lastCleanup = Date.distantPast
  public init(database: WorkspaceDatabase, supportDirectory: URL, remoteFiles: RemoteLibraryFiles = .init()) {
    self.database = database; files = .init(supportDirectory: supportDirectory); self.remoteFiles = remoteFiles
  }

  public func synchronize(locations: [LibraryLocation], workspaces: [RemoteWorkspaceConfiguration]) async throws {
    guard !synchronizing else { return }
    synchronizing = true
    defer { synchronizing = false }
    for location in locations where knownLocations[location.conversationID] != location {
      try database.setLibraryLocation(conversationID: location.conversationID, workspaceName: location.name, root: location.root)
      knownLocations[location.conversationID] = location
    }
    let conversationIDs = Set(locations.map(\.conversationID))
    knownLocations = knownLocations.filter { conversationIDs.contains($0.key) }
    for _ in 0..<4 { if try database.indexLibraryMessages() < 50 { break } }
    let files = files
    for item in try database.pendingLibraryFiles() {
      try Task.checkCancellation()
      do {
        let bytes: Data
        if item.workspaceID == "local" {
          let root = try database.libraryRoot(conversationID: item.conversationID)
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".woven-matter").path
          bytes = try await Task.detached(priority: .utility) {
            try files.readLocal(source: item.source, root: URL(fileURLWithPath: root))
          }.value
        } else {
          guard let workspace = workspaces.first(where: { $0.id.uuidString.lowercased() == item.workspaceID }) else {
            throw AgentMessageAttachmentError.unsupportedForAgent("Reconnect this remote workspace to save the file.")
          }
          let root = try database.libraryRoot(conversationID: item.conversationID) ?? "/home/.woven-matter"
          bytes = try await remoteFiles.read(source: item.source, root: root, configuration: workspace)
        }
        try Task.checkCancellation()
        let hash = try files.retain(bytes)
        // A deleted message cannot be resurrected by a transfer finishing late.
        try database.finishLibraryFile(id: item.id, hash: hash, size: Int64(bytes.count))
      } catch is CancellationError { throw CancellationError() }
      catch { try database.finishLibraryFile(id: item.id, hash: nil, error: String(error.localizedDescription.prefix(512))) }
    }
    if Date().timeIntervalSince(lastCleanup) >= 300 {
      let retained = try database.retainedLibraryHashes()
      let visible = try database.visibleLibraryHashes()
      try files.cleanup(retained: retained, visible: visible)
      lastCleanup = Date()
    }
  }
  public func items(query: LibraryQuery, offset: Int = 0) throws -> [WorkspaceLibraryItem] { try database.libraryItems(query: query, limit: 101, offset: offset) }
  public func facets() throws -> [LibraryFacet] { try database.libraryFacets() }
  public func revision() throws -> Int64 { try database.dashboardRevision() }
  public func openURL(id: String) throws -> URL {
    guard let item = try database.libraryItem(id: id) else { throw WorkspaceToolError.invalid("This Library item was removed.") }
    return try files.url(for: item)
  }
  public func retry(id: String) throws { try database.retryLibraryFile(id: id) }
}
