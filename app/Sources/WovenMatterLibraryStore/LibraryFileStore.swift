#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import WovenMatterCore

public struct LibraryFileStore: Sendable {
  public let supportDirectory: URL
  private var directory: URL { supportDirectory.appending(path: "library-files", directoryHint: .isDirectory) }
  private var openDirectory: URL { supportDirectory.appending(path: "library-open", directoryHint: .isDirectory) }
  private let readOnlyProjection: Bool
  public init(supportDirectory: URL, readOnlyProjection: Bool = false) {
    self.supportDirectory = supportDirectory; self.readOnlyProjection = readOnlyProjection
  }

  public func retain(_ data: Data) throws -> String {
    guard !readOnlyProjection else { throw WorkspaceDatabaseError.readOnlyProjection }
    guard data.count <= AgentMessageAttachmentLimits.maximumFileBytes else {
      throw AgentMessageAttachmentError.fileTooLarge(
        name: "File", maximumBytes: AgentMessageAttachmentLimits.maximumFileBytes)
    }
    let hash = SHA256.hash(data: data).hexString
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appending(path: hash)
    if !FileManager.default.fileExists(atPath: url.path) {
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
    }
    return hash
  }

  public func readLocal(source: String, root: URL) throws -> Data {
    guard let path = LibraryFileReference.path(source) else {
      throw AgentMessageAttachmentError.unreadableFile(source)
    }
    let expanded = (path as NSString).expandingTildeInPath
    let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appending(path: expanded)
    func canonical(_ path: String) -> String? {
      guard let pointer = realpath(path, nil) else { return nil }
      defer { free(pointer) }
      return String(cString: pointer)
    }
    let roots = [root, FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp")]
      .compactMap { canonical($0.path).map { $0 + "/" } }
    guard let resolved = canonical(url.path) else {
      throw AgentMessageAttachmentError.unreadableFile(url.lastPathComponent)
    }
    guard roots.contains(where: { resolved.hasPrefix($0) }) else {
      throw AgentMessageAttachmentError.unsupportedForAgent(
        "This file is outside its workspace. Open its source message to locate it.")
    }
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw AgentMessageAttachmentError.unreadableFile(url.lastPathComponent) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
      throw AgentMessageAttachmentError.unreadableFile(url.lastPathComponent)
    }
    // Recheck the opened file's path after open, including raced parent symlinks.
    guard let openedPath = PortablePOSIX.path(of: fd) else {
      throw AgentMessageAttachmentError.unreadableFile(url.lastPathComponent)
    }
    guard roots.contains(where: { openedPath.hasPrefix($0) }) else {
      throw AgentMessageAttachmentError.unreadableFile(url.lastPathComponent)
    }
    let maximum = AgentMessageAttachmentLimits.maximumFileBytes
    guard before.st_size <= maximum else {
      throw AgentMessageAttachmentError.fileTooLarge(name: url.lastPathComponent, maximumBytes: maximum)
    }
    let bytes = try handle.read(upToCount: Int(maximum) + 1) ?? Data()
    var after = stat()
    guard fstat(fd, &after) == 0, bytes.count == before.st_size, after.st_size == before.st_size,
      PortablePOSIX.modificationTime(after).tv_sec == PortablePOSIX.modificationTime(before).tv_sec,
      PortablePOSIX.modificationTime(after).tv_nsec == PortablePOSIX.modificationTime(before).tv_nsec
    else {
      throw AgentMessageAttachmentError.unsupportedForAgent("The file changed while being saved. Try again.")
    }
    return bytes
  }

  public func url(for item: WorkspaceLibraryItem) throws -> URL {
    if item.storage == .link, item.isWebLink, let url = URL(string: item.source) { return url }
    return try openingURL(
      contentHash: item.contentHash, title: item.title, mimeType: item.mimeType,
      source: item.source, storage: item.storage, error: item.error)
  }

  /// A message attachment's stored copy: `message-attachments/blobs/<sha256>`.
  private func messageAttachmentBlob(_ contentHash: String) throws -> URL {
    guard LibraryAttachmentReference.isDigest(contentHash) else { throw AgentMessageAttachmentError.unreadableFile("Attachment") }
    return supportDirectory.appending(path: "message-attachments/blobs/" + contentHash)
  }

  /// Whether this library holds the attachment's bytes.
  public func hasMessageAttachment(contentHash: String) -> Bool {
    guard let url = try? messageAttachmentBlob(contentHash) else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  /// A message attachment's bytes, for `GET v1/execution/attachments/<sha256>`:
  /// only a regular file in the attachment store, opened without following a
  /// link, at most the upload limit, and only while it matches its digest.
  public func messageAttachment(contentHash: String) throws -> Data {
    let url = try messageAttachmentBlob(contentHash)
    let store = url.deletingLastPathComponent()
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw AgentMessageAttachmentError.unreadableFile("Attachment") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw AgentMessageAttachmentError.unreadableFile("Attachment") }
    let maximum = AgentMessageAttachmentLimits.maximumFileBytes
    guard info.st_size <= maximum else { throw AgentMessageAttachmentError.fileTooLarge(name: "Attachment", maximumBytes: maximum) }
    // The opened file itself, wherever a parent points, is in the store.
    guard let opened = PortablePOSIX.path(of: fd), let pointer = realpath(store.path, nil) else {
      throw AgentMessageAttachmentError.unreadableFile("Attachment")
    }
    let root = String(cString: pointer) + "/"
    free(pointer)
    guard opened.hasPrefix(root) else { throw AgentMessageAttachmentError.unreadableFile("Attachment") }
    let data = try handle.read(upToCount: Int(maximum) + 1) ?? Data()
    guard data.count <= maximum, SHA256.hash(data: data).hexString == contentHash else {
      throw AgentMessageAttachmentError.unsupportedForAgent("This attachment changed on this Mac since it was sent.")
    }
    return data
  }

  /// Keeps a message attachment read from the machine that runs its session,
  /// once its bytes match their digest, so it opens like a local one.
  public func retainMessageAttachment(_ data: Data, contentHash: String) throws {
    guard !readOnlyProjection else { throw WorkspaceDatabaseError.readOnlyProjection }
    let url = try messageAttachmentBlob(contentHash)
    guard data.count <= AgentMessageAttachmentLimits.maximumFileBytes else {
      throw AgentMessageAttachmentError.fileTooLarge(name: "Attachment", maximumBytes: AgentMessageAttachmentLimits.maximumFileBytes)
    }
    guard SHA256.hash(data: data).hexString == contentHash else {
      throw AgentMessageAttachmentError.unsupportedForAgent("The workspace returned a damaged copy of this file. Try again.")
    }
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  public func attachmentURL(contentHash: String, fileName: String, mimeType: String) throws -> URL {
    try openingURL(
      contentHash: contentHash, title: fileName, mimeType: mimeType,
      source: "", storage: .attachment, error: nil)
  }

  private func openingURL(
    contentHash: String?, title: String, mimeType: String?, source reference: String,
    storage: LibraryStorage, error: String?
  ) throws -> URL {
    guard let hash = contentHash, hash.wholeMatch(of: /[0-9a-f]{64}/) != nil else {
      throw AgentMessageAttachmentError.unsupportedForAgent(error ?? "This file has not been saved yet.")
    }
    let source =
      storage == .attachment
      ? supportDirectory.appending(path: "message-attachments/blobs/" + hash)
      : directory.appending(path: hash)
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw AgentMessageAttachmentError.unreadableFile(title)
    }
    guard !readOnlyProjection else { throw WorkspaceDatabaseError.readOnlyProjection }
    let folder = openDirectory.appending(path: hash)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let name = Self.openingFileName(title: title, source: reference, mimeType: mimeType)
    let output = folder.appending(path: name)
    if !FileManager.default.fileExists(atPath: output.path) {
      // A separate read-only opening copy preserves the exchanged original.
      try FileManager.default.copyItem(at: source, to: output)
      try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: output.path)
    }
    return output
  }

  private static func openingFileName(title: String, source: String, mimeType: String?) -> String {
    let allowed = title.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) && !"/:\\".unicodeScalars.contains($0)
    }
    var name = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespaces)
    if name.isEmpty || name == "." || name == ".." { name = "Attachment" }
    let sourceExtension = URL(string: source)?.pathExtension ?? ""
    let mimeExtension = mimeType.flatMap { PortableMIME.preferredFilenameExtension(for: $0) } ?? ""
    let ext = !sourceExtension.isEmpty ? sourceExtension : (name as NSString).pathExtension.isEmpty ? mimeExtension : ""
    if !ext.isEmpty, ext.utf8.count <= 32, (name as NSString).pathExtension.lowercased() != ext.lowercased() {
      name += "." + ext
    }
    // Filesystems limit bytes, not Swift characters. Keep the extension intact.
    let suffix = (name as NSString).pathExtension
    let ending = suffix.isEmpty || suffix.utf8.count > 32 ? "" : "." + suffix
    var stem = ending.isEmpty ? name : String(name.dropLast(ending.count))
    while stem.utf8.count + ending.utf8.count > 240 { stem.removeLast() }
    return stem + ending
  }

  public func cleanup(retained: Set<String>, visible: Set<String>) throws {
    guard !readOnlyProjection else { throw WorkspaceDatabaseError.readOnlyProjection }
    let manager = FileManager.default
    for (folder, live) in [(directory, retained), (openDirectory, visible)] {
      guard manager.fileExists(atPath: folder.path) else { continue }
      for url in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
      {
        guard url.lastPathComponent.wholeMatch(of: /[0-9a-f]{64}/) != nil, !live.contains(url.lastPathComponent) else {
          continue
        }
        // Grace covers a file written just before its database transaction commits.
        let modified =
          try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantFuture
        if modified < Date().addingTimeInterval(-3600) { try manager.removeItem(at: url) }
      }
    }
  }
}
