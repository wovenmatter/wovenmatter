import Foundation
import WovenMatterClient
import WovenMatterCore

public struct LibraryLocation: Equatable, Sendable {
  public let conversationID: String
  public let name: String
  public let root: String

  public init(conversationID: String, name: String, root: String) {
    self.conversationID = conversationID
    self.name = name
    self.root = root
  }
}

public actor LibraryService {
  public typealias RemoteWorkspaceLookup = @Sendable (String) async -> RemoteWorkspaceConfiguration?

  private let database: WorkspaceDatabase
  private let savedArtifacts: SavedArtifactLibraryService
  private let files: LibraryFileStore
  private let remoteFiles: RemoteLibraryFiles
  private var synchronizing = false
  private var knownLocations: [String: LibraryLocation] = [:]
  private var lastCleanup = Date.distantPast

  public init(database: WorkspaceDatabase, remoteFiles: RemoteLibraryFiles = .init()) {
    self.database = database
    savedArtifacts = SavedArtifactLibraryService(database: database)
    files = database.libraryFiles
    self.remoteFiles = remoteFiles
  }

  public func savedArtifactItems() async throws -> [SavedArtifactLibraryItem] {
    try await savedArtifacts.items()
  }

  public func openSavedArtifactURL(id: String, revision: Int64) async throws -> URL {
    try await savedArtifacts.openURL(id: id, revision: revision)
  }

  public func synchronize(locations: [LibraryLocation], remoteWorkspace: RemoteWorkspaceLookup) async throws {
    guard !database.isReadOnlyProjection else { throw WorkspaceDatabaseError.readOnlyProjection }
    guard !synchronizing else { return }
    synchronizing = true
    defer { synchronizing = false }

    for location in locations where knownLocations[location.conversationID] != location {
      try await database.setLibraryLocation(
        conversationID: location.conversationID, workspaceName: location.name, root: location.root)
      knownLocations[location.conversationID] = location
    }
    let conversationIDs = Set(locations.map(\.conversationID))
    knownLocations = knownLocations.filter { conversationIDs.contains($0.key) }

    // Drain a bounded batch each pass so a message backlog cannot monopolize the store.
    for _ in 0..<4 {
      if try await database.indexLibraryMessages() < 50 { break }
    }
    for item in try await database.pendingLibraryFiles() {
      try Task.checkCancellation()
      guard let current = try await database.libraryItem(id: item.id),
        current.storage == .pending || current.storage == .unavailable
      else { continue }
      do {
        let bytes = try await readFile(item, remoteWorkspace: remoteWorkspace)
        try Task.checkCancellation()
        let hash = try files.retain(bytes)
        // An update cannot resurrect a message deleted while the read was in flight.
        try await database.finishLibraryFile(id: item.id, hash: hash, size: Int64(bytes.count))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try await database.finishLibraryFile(id: item.id, hash: nil, error: String(error.localizedDescription.prefix(512)))
      }
    }
    if Date().timeIntervalSince(lastCleanup) >= 300 {
      try await database.cleanupLibraryFiles()
      lastCleanup = Date()
    }
  }

  private func readFile(_ item: WorkspaceLibraryItem, remoteWorkspace: RemoteWorkspaceLookup) async throws -> Data {
    if item.workspaceID == "local" {
      let root =
        try await database.libraryRoot(conversationID: item.conversationID)
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".woven-matter").path
      let files = files
      return try await Task.detached(priority: .utility) {
        try files.readLocal(source: item.source, root: URL(fileURLWithPath: root))
      }.value
    }

    guard let workspace = await remoteWorkspace(item.workspaceID) else {
      throw WorkspaceToolError.invalid("Reconnect this remote workspace to save the file.")
    }
    let root = try await database.libraryRoot(conversationID: item.conversationID) ?? "/home/.woven-matter"
    let bytes = try await remoteFiles.read(source: item.source, root: root, configuration: workspace)
    // Credentials, host configuration, or availability may change during SSH.
    guard await remoteWorkspace(item.workspaceID) == workspace else {
      throw WorkspaceToolError.invalid("The remote workspace connection changed. Reconnect and retry.")
    }
    return bytes
  }

  public func page(query: LibraryQuery, count: Int) async throws -> LibraryPage {
    try await database.libraryPage(query: query, count: count)
  }

  public func revision() async throws -> Int64 {
    try await database.libraryRevision()
  }

  public func openURL(id: String) async throws -> URL {
    guard let item = try await database.libraryItem(id: id) else {
      throw WorkspaceToolError.invalid("This Library item was removed.")
    }
    return try files.url(for: item)
  }

  public func openAttachmentURL(contentHash: String, fileName: String, mimeType: String) throws -> URL {
    try files.attachmentURL(contentHash: contentHash, fileName: fileName, mimeType: mimeType)
  }

  public func retry(id: String) async throws {
    try await database.retryLibraryFile(id: id)
  }
}
