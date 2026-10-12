import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

public enum EmbeddedExecutionError: Error, LocalizedError {
  case unavailable(String)
  public var errorDescription: String? { if case let .unavailable(message) = self { return message }; return nil }
}

/// Files crossing the WebAssembly boundary. No host paths or symbolic links are exposed.
struct EmbeddedWorkspace {
  static let metadataDirectory = ".woven-execution"
  var files: [String: Data]
  var directories: Set<String>

  static func validate(_ path: String) throws {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0"), parts.count <= 64,
          parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
          parts.first.map({ String($0).caseInsensitiveCompare(metadataDirectory) != .orderedSame }) == true else {
      throw EmbeddedExecutionError.unavailable("Invalid workspace path: \(path)")
    }
  }

  static func read(_ rootURL: URL, maxBytes: Int, maxFiles: Int) throws -> Self {
    let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
    let fm = FileManager.default
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw EmbeddedExecutionError.unavailable("The execution workspace must be a regular directory.")
    }
    var result = Self(files: [:], directories: []), total = 0
    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: keys) else {
      throw EmbeddedExecutionError.unavailable("Cannot read the execution workspace.")
    }
    for case let url as URL in iterator {
      let entryPath = url.standardizedFileURL.path
      guard entryPath.hasPrefix(root.path + "/") else { throw EmbeddedExecutionError.unavailable("Workspace entry is outside its root.") }
      let path = String(entryPath.dropFirst(root.path.count + 1))
      if path == metadataDirectory { iterator.skipDescendants(); continue }
      try validate(path)
      let entry = try url.resourceValues(forKeys: Set(keys))
      guard entry.isSymbolicLink != true else { throw EmbeddedExecutionError.unavailable("Workspace symbolic links are unsupported: \(path)") }
      if entry.isDirectory == true { result.directories.insert(path) }
      else if entry.isRegularFile == true {
        total += entry.fileSize ?? 0
        guard total <= maxBytes, result.files.count < maxFiles else { throw EmbeddedExecutionError.unavailable("Workspace exceeds its configured resource budget.") }
        result.files[path] = try Data(contentsOf: url)
      } else { throw EmbeddedExecutionError.unavailable("Unsupported workspace entry: \(path)") }
      guard result.files.count + result.directories.count <= maxFiles else { throw EmbeddedExecutionError.unavailable("Workspace contains too many entries.") }
    }
    return result
  }

  var fingerprint: String {
    var digest = SHA256()
    for directory in directories.sorted() { digest.update(data: Data("D\(directory)\0".utf8)) }
    for path in files.keys.sorted() {
      digest.update(data: Data("F\(path)\0".utf8)); digest.update(data: Data(SHA256.hash(data: files[path]!)))
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func decode(files: [[String: Any]], directories: [String], maxBytes: Int, maxFiles: Int) throws -> Self {
    guard files.count + directories.count <= maxFiles else { throw EmbeddedExecutionError.unavailable("Workspace contains too many entries.") }
    var result = Self(files: [:], directories: []), total = 0
    for path in directories {
      try validate(path)
      guard result.directories.insert(path).inserted else { throw EmbeddedExecutionError.unavailable("Duplicate workspace directory.") }
    }
    for entry in files {
      guard let path = entry["path"] as? String, let base64 = entry["data"] as? String,
            let data = Data(base64Encoded: base64) else { throw EmbeddedExecutionError.unavailable("Invalid worker file result.") }
      try validate(path)
      guard result.files[path] == nil, !result.directories.contains(path) else { throw EmbeddedExecutionError.unavailable("Duplicate workspace path.") }
      total += data.count
      guard total <= maxBytes else { throw EmbeddedExecutionError.unavailable("Workspace exceeds its configured resource budget.") }
      result.files[path] = data
    }
    for path in Array(result.files.keys) + Array(result.directories) {
      var parent = (path as NSString).deletingLastPathComponent
      while !parent.isEmpty {
        guard result.files[parent] == nil else { throw EmbeddedExecutionError.unavailable("A workspace file cannot contain children.") }
        result.directories.insert(parent); parent = (parent as NSString).deletingLastPathComponent
      }
    }
    guard result.files.count + result.directories.count <= maxFiles else { throw EmbeddedExecutionError.unavailable("Workspace contains too many entries.") }
    // Client workspaces can later sync to case-insensitive Apple volumes. Reject
    // aliases before staging so two distinct virtual files cannot overwrite one.
    var canonicalPaths = Set<String>()
    for path in Array(result.files.keys) + Array(result.directories) {
      let canonical = path.precomposedStringWithCanonicalMapping.lowercased()
      guard canonicalPaths.insert(canonical).inserted else { throw EmbeddedExecutionError.unavailable("Workspace paths differ only by case or Unicode normalization: \(path)") }
    }
    return result
  }

  static func synchronizeFile(_ url: URL) throws {
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.synchronize()
  }

  static func synchronizeDirectory(_ url: URL) throws {
    #if canImport(Darwin)
    let descriptor = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_DIRECTORY) }
    guard descriptor >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
    #endif
  }

  /// Existing immutable job records are hard-linked into staging, avoiding recopying
  /// accumulated output. Newly written records always replace files atomically.
  static func linkMetadata(from source: URL, to destination: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at:destination,withIntermediateDirectories:true)
    for entry in try fm.contentsOfDirectory(at:source,includingPropertiesForKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey]) {
      let values = try entry.resourceValues(forKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else { throw EmbeddedExecutionError.unavailable("Invalid execution metadata entry.") }
      let target = destination.appendingPathComponent(entry.lastPathComponent)
      if values.isDirectory == true { try linkMetadata(from:entry,to:target) }
      else if values.isRegularFile == true { try fm.linkItem(at:entry,to:target) }
      else { throw EmbeddedExecutionError.unavailable("Invalid execution metadata entry.") }
    }
    try synchronizeDirectory(destination)
  }

  /// Stage all changes and the durable receipt before one atomic directory exchange.
  /// Callers serialize commands per workspace. A fresh fingerprint rejects edits made
  /// since execution began, preserving both the existing files and diagnostic output.
  func commit(to root: URL, replacing original: Self, receipt: Data, requestID: UUID, maxBytes: Int, maxFiles: Int) throws {
    let fm = FileManager.default
    let current = try Self.read(root, maxBytes: maxBytes, maxFiles: maxFiles)
    guard current.fingerprint == original.fingerprint else { throw EmbeddedExecutionError.unavailable("Workspace changed while the command was running. Results were not applied; retry against the updated files.") }
    let staging = root.deletingLastPathComponent().appendingPathComponent(".woven-stage-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: staging) }
    for directory in directories.sorted() { try fm.createDirectory(at: staging.appendingPathComponent(directory), withIntermediateDirectories: true) }
    for (path, data) in files {
      let file = staging.appendingPathComponent(path)
      try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: file, options: .atomic)
      try Self.synchronizeFile(file)
    }
    let metadata = root.appendingPathComponent(Self.metadataDirectory, isDirectory: true)
    if fm.fileExists(atPath: metadata.path) {
      guard (try metadata.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw EmbeddedExecutionError.unavailable("Invalid execution metadata directory.") }
      try Self.linkMetadata(from: metadata, to: staging.appendingPathComponent(Self.metadataDirectory))
    }
    let receiptURL = staging.appendingPathComponent(Self.metadataDirectory).appendingPathComponent(requestID.uuidString).appendingPathComponent("receipt.json")
    try fm.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try receipt.write(to: receiptURL, options: .atomic)
    try Self.synchronizeFile(receiptURL)
    try Self.synchronizeDirectory(receiptURL.deletingLastPathComponent())
    try Self.synchronizeDirectory(staging.appendingPathComponent(Self.metadataDirectory))
    for directory in directories.sorted(by: { $0.count > $1.count }) { try Self.synchronizeDirectory(staging.appendingPathComponent(directory)) }
    try Self.synchronizeDirectory(staging)
    guard try Self.read(root, maxBytes: maxBytes, maxFiles: maxFiles).fingerprint == original.fingerprint else {
      throw EmbeddedExecutionError.unavailable("Workspace changed while results were being staged. Results were not applied.")
    }
    #if canImport(Darwin)
    let status = root.withUnsafeFileSystemRepresentation { destination in
      staging.withUnsafeFileSystemRepresentation { source in renameatx_np(AT_FDCWD, source!, AT_FDCWD, destination!, UInt32(RENAME_SWAP)) }
    }
    guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    try Self.synchronizeDirectory(root.deletingLastPathComponent())
    #else
    throw EmbeddedExecutionError.unavailable("Atomic workspace exchange requires an Apple filesystem.")
    #endif
  }
}
