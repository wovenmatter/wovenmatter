import CryptoKit
import Foundation
import UniformTypeIdentifiers
import WovenMatterCore

public struct SavedArtifactLibraryItem: Identifiable, Equatable, Sendable {
  public let manifest: CompanionArtifactManifest
  public let workspaceName: String
  public var id: String { manifest.id }

  public init(manifest: CompanionArtifactManifest, workspaceName: String) {
    self.manifest = manifest
    self.workspaceName = workspaceName
  }
}

/// Presents committed client outputs without assigning them invented conversation identities.
/// Opening copies are disposable; only the central committed chunks are authoritative.
public actor SavedArtifactLibraryService {
  private let database: WorkspaceDatabase
  private let directory: URL
  private var opening: [String: Task<URL, any Error>] = [:]

  public init(database: WorkspaceDatabase) {
    self.database = database
    directory = database.libraryFiles.supportDirectory.appending(path: "saved-artifact-open", directoryHint: .isDirectory)
  }

  public func items() async throws -> [SavedArtifactLibraryItem] {
    let workspaces = try await database.companionExecutionWorkspaces()
    let names = Dictionary(workspaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    return try await database.companionSavedArtifacts().filter { !$0.deleted }.map {
      SavedArtifactLibraryItem(manifest: $0, workspaceName: names[$0.workspaceID] ?? "Unavailable workspace")
    }.sorted {
      let order = $0.manifest.title.localizedStandardCompare($1.manifest.title)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
  }

  public func openURL(id: String, revision: Int64) async throws -> URL {
    guard !database.isReadOnlyProjection else { throw WorkspaceDatabaseError.readOnlyProjection }
    let key = "\(id):\(revision)"
    if let task = opening[key] { return try await task.value }
    let task = Task { try await self.prepare(id: id, revision: revision) }
    opening[key] = task
    defer { opening[key] = nil }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func current(id: String, revision: Int64) async throws -> CompanionArtifactManifest {
    guard let manifest = try await database.companionSavedArtifacts().first(where: { $0.id == id }),
      !manifest.deleted, manifest.revision == revision else {
      throw WorkspaceToolError.invalid("This saved artifact changed or was removed. Refresh the Library and try again.")
    }
    return manifest
  }

  private func prepare(id: String, revision: Int64) async throws -> URL {
    let manifest = try await current(id: id, revision: revision)
    let identity = Self.digest(Data(id.utf8))
    let folder = directory.appending(path: identity, directoryHint: .isDirectory)
      .appending(path: "\(revision)-\(manifest.sha256)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let destination = folder.appending(path: Self.fileName(manifest))
    if FileManager.default.fileExists(atPath: destination.path) {
      if try verify(destination, manifest: manifest) {
        guard try await current(id: id, revision: revision) == manifest else { throw WorkspaceDatabaseError.corruptRow }
        return destination
      }
      try FileManager.default.removeItem(at: destination)
    }
    let temporary = folder.appending(path: ".\(UUID().uuidString).partial")
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
      throw WorkspaceToolError.invalid("The saved artifact opening copy could not be created.")
    }
    defer { try? FileManager.default.removeItem(at: temporary) }
    let file = try FileHandle(forWritingTo: temporary)
    defer { try? file.close() }
    var offset: Int64 = 0
    var hash = SHA256()
    while offset < manifest.byteCount {
      try Task.checkCancellation()
      let chunk = try await database.companionArtifactChunk(id: id, revision: revision, offset: offset)
      guard chunk.id == id, chunk.revision == revision, chunk.offset == offset,
        !chunk.data.isEmpty, chunk.data.count <= CompanionFederationProtocol.maximumArtifactChunkBytes,
        Int64(chunk.data.count) <= manifest.byteCount - offset else { throw WorkspaceDatabaseError.corruptRow }
      try file.write(contentsOf: chunk.data)
      hash.update(data: chunk.data)
      offset += Int64(chunk.data.count)
    }
    guard offset == manifest.byteCount, Self.hex(hash.finalize()) == manifest.sha256 else {
      throw WorkspaceToolError.invalid("This saved artifact failed its integrity check. Its opening copy was discarded.")
    }
    try Task.checkCancellation()
    guard try await current(id: id, revision: revision) == manifest else { throw WorkspaceDatabaseError.corruptRow }
    try file.synchronize()
    try file.close()
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: temporary.path)
    try FileManager.default.moveItem(at: temporary, to: destination)
    return destination
  }

  private func verify(_ url: URL, manifest: CompanionArtifactManifest) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      values.fileSize.map(Int64.init) == manifest.byteCount else { return false }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    var size: Int64 = 0
    while let bytes = try file.read(upToCount: CompanionFederationProtocol.maximumArtifactChunkBytes), !bytes.isEmpty {
      try Task.checkCancellation()
      hash.update(data: bytes)
      size += Int64(bytes.count)
      guard size <= manifest.byteCount else { return false }
    }
    return size == manifest.byteCount && Self.hex(hash.finalize()) == manifest.sha256
  }

  private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
  private static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
  private static func fileName(_ manifest: CompanionArtifactManifest) -> String {
    let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
    var name = String(String.UnicodeScalarView(manifest.title.unicodeScalars.filter { !forbidden.contains($0) }))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty || name == "." || name == ".." { name = "Saved artifact" }
    if (name as NSString).pathExtension.isEmpty, let suffix = UTType(mimeType: manifest.mediaType)?.preferredFilenameExtension {
      name += "." + suffix
    }
    let suffix = String((name as NSString).pathExtension.prefix(32))
    var base = suffix.isEmpty ? name : (name as NSString).deletingPathExtension
    let ending = suffix.isEmpty ? "" : "." + suffix
    while (base + ending).utf8.count > 240 { base.removeLast() }
    return base + ending
  }
}
