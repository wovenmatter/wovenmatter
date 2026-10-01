import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers
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
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(fd, F_GETPATH, &pathBuffer) == 0 else {
      throw AgentMessageAttachmentError.unreadableFile(url.lastPathComponent)
    }
    let openedPath = String(decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
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
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
    else {
      throw AgentMessageAttachmentError.unsupportedForAgent("The file changed while being saved. Try again.")
    }
    return bytes
  }

  public func url(for item: WorkspaceLibraryItem) throws -> URL {
    if item.storage == .link, item.isWebLink, let url = URL(string: item.source) { return url }
    guard let hash = item.contentHash, hash.wholeMatch(of: /[0-9a-f]{64}/) != nil else {
      throw AgentMessageAttachmentError.unsupportedForAgent(item.error ?? "This file has not been saved yet.")
    }
    let source =
      item.storage == .attachment
      ? supportDirectory.appending(path: "message-attachments/blobs/" + hash)
      : directory.appending(path: hash)
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw AgentMessageAttachmentError.unreadableFile(item.title)
    }
    guard !readOnlyProjection else { throw WorkspaceDatabaseError.readOnlyProjection }
    let folder = openDirectory.appending(path: hash)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let name = Self.openingFileName(for: item)
    let output = folder.appending(path: name)
    if !FileManager.default.fileExists(atPath: output.path) {
      // A separate read-only opening copy preserves the exchanged original.
      try FileManager.default.copyItem(at: source, to: output)
      try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: output.path)
    }
    return output
  }

  private static func openingFileName(for item: WorkspaceLibraryItem) -> String {
    let allowed = item.title.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) && !"/:\\".unicodeScalars.contains($0)
    }
    var name = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespaces)
    if name.isEmpty || name == "." || name == ".." { name = "Attachment" }
    let sourceExtension = URL(string: item.source)?.pathExtension ?? ""
    let mimeExtension = item.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? ""
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
