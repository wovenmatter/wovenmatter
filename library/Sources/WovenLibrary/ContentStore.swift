import Foundation
import WovenProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Large content (attachments, images, database copies) lives in `files/`
// beside the library, named by its SHA-256 digest. Synced rows carry only the
// digest; a machine fetches the bytes by digest when it needs them.

extension Library {
  private var filesFolder: URL { folder.appendingPathComponent("files", isDirectory: true) }

  private func fileURL(_ digest: String) throws -> URL {
    guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
      throw LibraryError(.invalid, "Not a content digest: \(digest)")
    }
    return filesFolder.appendingPathComponent(String(digest.prefix(2)), isDirectory: true).appendingPathComponent(digest)
  }

  public static func digest(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Stores bytes and returns their digest. Storing the same bytes twice keeps one file.
  @discardableResult
  public func storeContent(_ data: Data) async throws -> String {
    let digest = Self.digest(of: data)
    let url = try fileURL(digest)
    if !FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let partial = url.appendingPathExtension("partial-\(UUID().uuidString)")
      try data.write(to: partial)
      do { try FileManager.default.moveItem(at: partial, to: url) } catch {
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.fileExists(atPath: url.path) else { throw error }
      }
    }
    try await write { writer in
      try writer.db.run("INSERT OR IGNORE INTO files (digest, size, added_at) VALUES (?, ?, ?)",
                        [.text(digest), .integer(Int64(data.count)), .integer(Writer.now())])
    }
    return digest
  }

  /// Moves a file that is already complete into the store under its digest,
  /// without reading it into memory. The file is gone from `url` after.
  @discardableResult
  public func storeContent(movingFile file: URL) async throws -> String {
    let digest = try Self.digest(ofFile: file)
    let url = try fileURL(digest)
    let size = Int64((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0)
    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: file)
    } else {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      do { try FileManager.default.moveItem(at: file, to: url) } catch {
        guard FileManager.default.fileExists(atPath: url.path) else { throw error }
        try? FileManager.default.removeItem(at: file)
      }
    }
    try await write { writer in
      try writer.db.run("INSERT OR IGNORE INTO files (digest, size, added_at) VALUES (?, ?, ?)",
                        [.text(digest), .integer(size), .integer(Writer.now())])
    }
    return digest
  }

  /// The SHA-256 digest of a file, read in pieces.
  public static func digest(ofFile file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// The stored file for a digest on this machine, or nil when it is not held here.
  public func contentFile(_ digest: String) async throws -> URL? {
    guard try await hasContent(digest) else { return nil }
    return try fileURL(digest)
  }

  /// Where a file being received for the store is written first.
  public func incomingFile() throws -> URL {
    try FileManager.default.createDirectory(at: filesFolder, withIntermediateDirectories: true)
    return filesFolder.appendingPathComponent("incoming-\(UUID().uuidString)")
  }

  public func hasContent(_ digest: String) async throws -> Bool {
    try await read { db in
      try !db.query("SELECT digest FROM files WHERE digest = ?", [.text(digest)]).isEmpty
    }
  }

  /// Part of a stored file, or nil when this machine does not hold it.
  public func content(_ digest: String, offset: Int64 = 0, length: Int = .max) async throws -> ContentChunk? {
    guard try await hasContent(digest) else { return nil }
    let handle = try FileHandle(forReadingFrom: try fileURL(digest))
    defer { try? handle.close() }
    let size = Int64(try handle.seekToEnd())
    try handle.seek(toOffset: UInt64(max(0, min(offset, size))))
    let data = try handle.read(upToCount: max(0, min(length, Int(size - min(offset, size))))) ?? Data()
    return ContentChunk(data: data, size: size)
  }
}
