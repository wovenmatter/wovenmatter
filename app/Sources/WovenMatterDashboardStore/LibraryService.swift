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
  /// Reads an agent's file from a Linux host's server (`POST
  /// v1/execution/library-file`): workspace ID, conversation ID, the path as
  /// the agent wrote it (the host resolves a relative one in the chat's own
  /// directory), and the same path under this library's root for the chat,
  /// for history the host does not run.
  public typealias RemoteFileReader = @Sendable (_ workspaceID: String, _ conversationID: String, _ path: String, _ underRoot: String) async throws -> Data

  private let database: WorkspaceDatabase
  private let savedArtifacts: SavedArtifactLibraryService
  private let files: LibraryFileStore
  private var remoteFiles: RemoteFileReader?
  private var synchronizing = false
  private var waitingPasses: [CheckedContinuation<Void, Never>] = []
  private var knownLocations: [String: LibraryLocation] = [:]
  private var lastCleanup = Date.distantPast

  public init(database: WorkspaceDatabase, remoteFiles: RemoteFileReader? = nil) {
    self.database = database
    savedArtifacts = SavedArtifactLibraryService(database: database)
    files = database.libraryFiles
    self.remoteFiles = remoteFiles
  }

  /// Set once the app can sign for its Linux hosts.
  public func setRemoteFileReader(_ reader: @escaping RemoteFileReader) { remoteFiles = reader }

  /// Where a shared link points on a Linux host: absolute, relative to the
  /// chat's root, or `~/` (expanded by the host for its own user).
  public static func remotePath(source: String, root: String) throws -> String {
    guard let path = LibraryFileReference.path(source) else {
      throw RemoteWorkspaceClientError.invalidResponse("The file link does not name a file in this workspace.")
    }
    guard !path.contains("\u{0}"), path.utf8.count <= 8192 else {
      throw RemoteWorkspaceClientError.invalidResponse("The file path is invalid.")
    }
    if path.hasPrefix("~/") || path.hasPrefix("/") { return path }
    return root + "/" + path
  }

  public func savedArtifactItems() async throws -> [SavedArtifactLibraryItem] {
    try await savedArtifacts.items()
  }

  public func openSavedArtifactURL(id: String, revision: Int64) async throws -> URL {
    try await savedArtifacts.openURL(id: id, revision: revision)
  }

  public func synchronize(locations: [LibraryLocation], remoteWorkspace: RemoteWorkspaceLookup) async throws {
    guard !database.isReadOnlyProjection else { throw WorkspaceDatabaseError.readOnlyProjection }
    // Passes are serialized, never dropped: a caller arriving during another
    // pass runs its own pass, with its locations, once that one finishes.
    while synchronizing { await withCheckedContinuation { waitingPasses.append($0) } }
    synchronizing = true
    defer {
      synchronizing = false
      if !waitingPasses.isEmpty { waitingPasses.removeFirst().resume() }
    }
    try Task.checkCancellation()

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
    let storedRoot = try await database.libraryRoot(conversationID: item.conversationID)
    guard let root = storedRoot ?? workspace.workspaceRoot else {
      throw WorkspaceToolError.invalid("Reconnect this host workspace to discover its files directory.")
    }
    guard let remoteFiles else { throw WorkspaceToolError.invalid("Reconnect this remote workspace to save the file.") }
    guard let written = LibraryFileReference.path(item.source) else {
      throw RemoteWorkspaceClientError.invalidResponse("The file link does not name a file in this workspace.")
    }
    let bytes = try await remoteFiles(item.workspaceID, item.conversationID, written, Self.remotePath(source: item.source, root: root))
    guard bytes.count <= AgentMessageAttachmentLimits.maximumFileBytes else {
      throw RemoteWorkspaceClientError.invalidResponse("The file exceeds the 25 MB retention limit.")
    }
    // The host configuration may change during the read.
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

  /// A message file that this library may not hold yet (a session another
  /// machine runs): `fetch` reads it from that machine once, and it is kept
  /// here after its bytes match their digest, then opened like a local one.
  public func openAttachmentURL(contentHash: String, fileName: String, mimeType: String,
                                fetch: @Sendable () async throws -> Data) async throws -> URL {
    if !files.hasMessageAttachment(contentHash: contentHash) {
      try files.retainMessageAttachment(try await fetch(), contentHash: contentHash)
    }
    return try files.attachmentURL(contentHash: contentHash, fileName: fileName, mimeType: mimeType)
  }

  public func retry(id: String) async throws {
    try await database.retryLibraryFile(id: id)
  }
}
