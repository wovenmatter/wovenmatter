import CryptoKit
import Darwin
import Foundation
import WovenMatterCore

public enum LibraryTransferArchive {
  public static let chunkBytes = 1_048_576
  public static let maximumFiles = 100_000
  public static let maximumBytes: Int64 = 1 << 40
  public static let assetDirectories = ["library-files", "message-attachments/blobs"]

  public static func persist<T: Encodable>(_ value: T, to file: URL) throws {
    try persist(try JSONEncoder().encode(value), to: file)
  }
  public static func persist(_ data: Data, to file: URL) throws {
    let parent = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temporary = parent.appending(path: ".transfer-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw POSIXError(.EIO) }
    let handle = try FileHandle(forWritingTo: temporary)
    do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
    catch { try? handle.close(); throw error }
    guard Darwin.rename(temporary.path, file.path) == 0 else { throw POSIXError(.EIO) }
    let fd = Darwin.open(parent.path, O_RDONLY); guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { Darwin.close(fd) }; guard Darwin.fsync(fd) == 0 else { throw POSIXError(.EIO) }
  }
  public static func hash(_ file: URL) throws -> String {
    let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
    var hash = SHA256()
    while let bytes = try input.read(upToCount: chunkBytes), !bytes.isEmpty { hash.update(data: bytes) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  public static func validPath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"), path.utf8.count <= 1024 else { return false }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
    return ["workspace.sqlite", "devices.json", "origins.json", "authority.json", "replica.json", "lineage.json"].contains(path)
      || assetDirectories.contains { path.hasPrefix($0 + "/") }
  }
  public static func validate(_ manifest: CompanionLibraryTransferManifest) throws {
    guard manifest.version == CompanionLibraryTransferManifest.version, UUID(uuidString: manifest.transferID) != nil,
          UUID(uuidString: manifest.libraryID) != nil, manifest.files.count <= maximumFiles,
          Set(manifest.files.map(\.path)).count == manifest.files.count,
          manifest.files.contains(where: { $0.path == "workspace.sqlite" }) else { throw invalid }
    var total: Int64 = 0
    for file in manifest.files {
      guard validPath(file.path), file.byteCount >= 0, file.byteCount <= maximumBytes - total,
            file.sha256.count == 64, file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw invalid }
      total += file.byteCount
    }
  }
  public static func files(in directory: URL) throws -> [CompanionLibraryTransferFile] {
    let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
    guard let enumerator = FileManager.default.enumerator(atPath: canonical.path) else { throw invalid }
    var result: [CompanionLibraryTransferFile] = []
    for case let path as String in enumerator {
      let file = canonical.appendingPathComponent(path)
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      guard values.isSymbolicLink != true else { throw invalid }
      guard values.isRegularFile == true else { continue }
      guard validPath(path) else { continue }
      result.append(.init(path: path, byteCount: Int64(values.fileSize ?? 0), sha256: try hash(file)))
    }
    return result.sorted { $0.path < $1.path }
  }
  public static func backup(database: WorkspaceDatabase, to directory: URL) async throws {
    let manager = FileManager.default
    let completed = directory.appending(path: ".backup-complete.json")
    if manager.fileExists(atPath: completed.path) { return }
    // Only an unfinished private backup may be rebuilt. A complete original is
    // immutable, including across repeated approvals, retries and process loss.
    if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let sqlite = directory.appending(path: "workspace.sqlite")
    if !manager.fileExists(atPath: sqlite.path) { try await database.backupLibrary(to: sqlite) }
    // SQLite owns saved-artifact chunks. These are the remaining content-addressed
    // library blobs; agent working directories and provider credentials stay put.
    for path in assetDirectories {
      let source = database.supportDirectory.appending(path: path), target = directory.appending(path: path)
      if manager.fileExists(atPath: source.path), !manager.fileExists(atPath: target.path) {
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.copyItem(at: source, to: target)
      }
    }
    _ = try files(in: directory) // Reject symlinks before publishing a manifest.
    try persist(true, to: completed)
  }
  public static func verify(manifest: CompanionLibraryTransferManifest, in directory: URL) throws {
    try validate(manifest)
    for file in manifest.files {
      let url = try secureFile(file.path, in: directory, createParents: false)
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
            Int64(values.fileSize ?? -1) == file.byteCount, try hash(url) == file.sha256 else {
        throw CompanionAPIError(code: "invalid_transfer", message: "The transferred file \(file.path) did not match its verified size and checksum. Both backups are retained.")
      }
    }
    try LibraryTransferSQLite.verify(directory.appending(path: "workspace.sqlite"))
  }
  public static func secureFile(_ path: String, in directory: URL, createParents: Bool) throws -> URL {
    guard validPath(path) else { throw invalid }
    let manager = FileManager.default
    if manager.fileExists(atPath: directory.path), try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw invalid }
    var current = directory
    for component in path.split(separator: "/").dropLast() {
      current.append(path: String(component))
      if manager.fileExists(atPath: current.path) {
        guard try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]).isSymbolicLink != true,
              try current.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw invalid }
      } else if createParents { try manager.createDirectory(at: current, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    }
    let file = directory.appending(path: path)
    if manager.fileExists(atPath: file.path), try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw invalid }
    return file
  }
  public static func write(_ chunk: CompanionLibraryTransferChunk, manifest: CompanionLibraryTransferManifest, in directory: URL) throws -> Int64 {
    guard let file = manifest.files.first(where: { $0.path == chunk.path }), chunk.offset >= 0,
          !chunk.data.isEmpty, chunk.data.count <= chunkBytes, chunk.offset <= file.byteCount,
          Int64(chunk.data.count) <= file.byteCount - chunk.offset else { throw invalid }
    let url = try secureFile(chunk.path, in: directory, createParents: true)
    let manager = FileManager.default
    if !manager.fileExists(atPath: url.path) {
      guard chunk.offset == 0, manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw invalid }
    }
    let handle = try FileHandle(forUpdating: url); defer { try? handle.close() }
    let size = try handle.seekToEnd()
    if UInt64(chunk.offset) < size {
      guard UInt64(chunk.offset) + UInt64(chunk.data.count) <= size else { throw invalid }
      try handle.seek(toOffset: UInt64(chunk.offset))
      guard try handle.read(upToCount: chunk.data.count) == chunk.data else { throw invalid }
      return Int64(size)
    }
    guard UInt64(chunk.offset) == size else { throw invalid }
    try handle.write(contentsOf: chunk.data); try handle.synchronize()
    return Int64(size) + Int64(chunk.data.count)
  }
  public static func installAssets(from archive: URL, to destination: URL, manifest: CompanionLibraryTransferManifest) throws {
    for file in manifest.files where assetDirectories.contains(where: { file.path.hasPrefix($0 + "/") }) {
      let source = try secureFile(file.path, in: archive, createParents: false)
      let target = try secureFile(file.path, in: destination, createParents: true)
      if FileManager.default.fileExists(atPath: target.path) {
        guard try hash(target) == file.sha256 else { throw invalid }
      } else {
        let temporary = target.deletingLastPathComponent().appending(path: ".transfer-asset-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
        guard Darwin.rename(temporary.path, target.path) == 0 else { throw POSIXError(.EIO) }
        let fd = Darwin.open(target.deletingLastPathComponent().path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }; defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw POSIXError(.EIO) }
      }
    }
  }
  private static var invalid: CompanionAPIError { .init(code: "invalid_transfer", message: "The database transfer is incomplete or its contents failed verification. Both backups have been retained.") }
}
