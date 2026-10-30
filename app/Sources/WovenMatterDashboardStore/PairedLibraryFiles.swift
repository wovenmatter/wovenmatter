import CryptoKit
import Darwin
import Foundation
import WovenMatterCore

public struct PairedLibraryFile: Codable, Equatable, Sendable {
  public let store: String
  public let hash: String
  public let byteCount: Int64
  public var id: String { store + ":" + hash }
}
public struct PairedLibraryFilePage: Codable, Sendable {
  public let files: [PairedLibraryFile]
  public let cursor: String
  public let hasMore: Bool
}
public struct PairedLibraryFileRequest: Codable, Sendable {
  public let file: PairedLibraryFile
  public let offset: Int64
  public init(file: PairedLibraryFile, offset: Int64) { self.file = file; self.offset = offset }
}
public struct PairedLibraryFileChunk: Codable, Sendable {
  public let file: PairedLibraryFile
  public let offset: Int64
  public let data: Data
}

/// Content-addressed library bytes are independent of the row journal. A large
/// or disconnected file never blocks ordinary writing from being synchronized.
public actor PairedLibraryFiles {
  private let root: URL
  private let stores = ["library-files", "message-attachments/blobs", "paired-records"]
  public init(root: URL) { self.root = root }
  private var invalid: CompanionAPIError { .init(code: "peer_file", message: "A shared file failed its size, offset or content check. The local original is retained.") }
  private func validate(_ file: PairedLibraryFile) throws -> URL {
    guard stores.contains(file.store), file.hash.wholeMatch(of: /[0-9a-f]{64}/) != nil,
          file.byteCount >= 0, file.byteCount <= 256 * 1_024 * 1_024 else { throw invalid }
    return root.appending(path: file.store).appending(path: file.hash)
  }
  public func page(after cursor: String) throws -> PairedLibraryFilePage {
    var files: [PairedLibraryFile] = []
    for store in stores {
      let directory = root.appending(path: store)
      guard FileManager.default.fileExists(atPath: directory.path) else { continue }
      for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) {
        guard url.lastPathComponent.wholeMatch(of: /[0-9a-f]{64}/) != nil else { continue }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let count = values.fileSize else { continue }
        let file = PairedLibraryFile(store: store, hash: url.lastPathComponent, byteCount: Int64(count))
        if file.id > cursor { files.append(file) }
      }
    }
    files.sort { $0.id < $1.id }
    let page = Array(files.prefix(100))
    return .init(files: page, cursor: page.last?.id ?? cursor, hasMore: files.count > page.count)
  }
  public func chunk(_ request: PairedLibraryFileRequest) throws -> PairedLibraryFileChunk {
    let url = try validate(request.file)
    guard request.offset >= 0, request.offset <= request.file.byteCount else { throw invalid }
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw invalid }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == request.file.byteCount else { throw invalid }
    try handle.seek(toOffset: UInt64(request.offset))
    let data = try handle.read(upToCount: 512 * 1_024) ?? Data()
    return .init(file: request.file, offset: request.offset, data: data)
  }
  private func partial(_ file: PairedLibraryFile) -> URL { root.appending(path: "paired-file-downloads/" + file.store.replacingOccurrences(of: "/", with: "-") + "-" + file.hash) }
  public func nextOffset(_ file: PairedLibraryFile) throws -> Int64? {
    let url = try validate(file)
    if FileManager.default.fileExists(atPath: url.path) {
      let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
      guard Int64(bytes.count) == file.byteCount, Self.hash(bytes) == file.hash else { throw invalid }
      return nil
    }
    let temp = partial(file)
    guard FileManager.default.fileExists(atPath: temp.path) else { return 0 }
    let size = try temp.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
    guard size.isSymbolicLink != true, let count = size.fileSize, count <= file.byteCount else { throw invalid }
    return Int64(count)
  }
  public func receive(_ chunk: PairedLibraryFileChunk) throws {
    let destination = try validate(chunk.file)
    guard chunk.offset >= 0, chunk.data.count <= 512 * 1_024,
          chunk.offset + Int64(chunk.data.count) <= chunk.file.byteCount,
          !chunk.data.isEmpty || chunk.file.byteCount == 0 else { throw invalid }
    guard let offset = try nextOffset(chunk.file) else { return }
    // Another peer may have durably supplied this same chunk while a request
    // was in flight. Never append it twice or overwrite another byte range.
    if offset > chunk.offset { return }
    guard offset == chunk.offset else { throw invalid }
    let temp = partial(chunk.file)
    try FileManager.default.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if !FileManager.default.fileExists(atPath: temp.path) {
      guard FileManager.default.createFile(atPath: temp.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw invalid }
    }
    let handle = try FileHandle(forWritingTo: temp); defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset)); try handle.write(contentsOf: chunk.data); try handle.synchronize()
    if offset + Int64(chunk.data.count) == chunk.file.byteCount {
      let bytes = try Data(contentsOf: temp, options: .mappedIfSafe)
      guard Self.hash(bytes) == chunk.file.hash else {
        // Incomplete bytes are disposable. A bad source must not prevent a
        // later healthy peer from restarting this same content-addressed file.
        try FileManager.default.removeItem(at: temp)
        throw invalid
      }
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try FileManager.default.moveItem(at: temp, to: destination)
      try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
    }
  }
  private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
