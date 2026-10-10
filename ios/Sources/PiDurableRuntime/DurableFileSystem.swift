import Foundation
import Darwin

/// Private JSONL checkpoint filesystem. Virtual paths never expose or escape the selected
/// conversation directory; native tools receive their own, separately scoped file access.
final class DurableFileSystem {
  private let directory: URL
  private var lockDescriptor: Int32 = -1
  private let manager = FileManager.default

  init(directory: URL) throws {
    self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    try manager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    #if os(iOS)
    try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: self.directory.path)
    #endif
  }
  deinit { release() }

  func acquire() throws {
    guard lockDescriptor < 0 else { return }
    let descriptor = Darwin.open(directory.appendingPathComponent(".writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw posixError() }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor)
      throw PiDurableRuntimeError.storageInUse
    }
    lockDescriptor = descriptor
  }
  func release() {
    if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); Darwin.close(lockDescriptor); lockDescriptor = -1 }
  }
  func perform(_ operation: String, arguments: [Any]) throws -> Any {
    guard lockDescriptor >= 0 else { throw PiDurableRuntimeError.closed }
    func path(_ index: Int = 0) throws -> URL {
      guard arguments.indices.contains(index), let path = arguments[index] as? String else {
        throw PiDurableRuntimeError.unavailable("Missing durable path")
      }
      return try resolve(path)
    }
    func content(_ index: Int = 1) throws -> Data {
      guard arguments.indices.contains(index) else { throw PiDurableRuntimeError.unavailable("Missing file content") }
      if let text = arguments[index] as? String { return Data(text.utf8) }
      if let bytes = arguments[index] as? [UInt8] { return Data(bytes) }
      throw PiDurableRuntimeError.unavailable("Invalid file content")
    }
    switch operation {
    case "absolutePath": return virtual(try path())
    case "joinPath":
      guard let parts = arguments.first as? [String] else { throw PiDurableRuntimeError.unavailable("Invalid joined path") }
      return virtual(try resolve(parts.joined(separator: "/")))
    case "createDir": try manager.createDirectory(at: path(), withIntermediateDirectories: true)
    case "appendFile": try write(content(), to: path(), append: true)
    case "writeFile": try write(content(), to: path(), append: false)
    case "readBinaryFile": return Array(try Data(contentsOf: path()))
    case "flushFile":
      let url = try path()
      let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
      guard descriptor >= 0 else { throw posixError() }
      defer { Darwin.close(descriptor) }
      guard fsync(descriptor) == 0 else { throw posixError() }
    case "truncateFile":
      guard arguments.count > 1, let size = arguments[1] as? Int, size >= 0 else { throw PiDurableRuntimeError.unavailable("Invalid file length") }
      let descriptor = Darwin.open(try path().path, O_WRONLY | O_NOFOLLOW)
      guard descriptor >= 0 else { throw posixError() }
      defer { Darwin.close(descriptor) }
      guard ftruncate(descriptor, off_t(size)) == 0, fsync(descriptor) == 0 else { throw posixError() }
    case "renameFile":
      guard Darwin.rename(try path().path, try path(1).path) == 0 else { throw posixError() }
      try syncDirectory()
    case "remove":
      let url = try path()
      do { try manager.removeItem(at: url); try syncDirectory() }
      catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { }
    case "listDir":
      return try manager.contentsOfDirectory(at: path(), includingPropertiesForKeys: [.isDirectoryKey,.fileSizeKey,.contentModificationDateKey]).filter { !$0.lastPathComponent.hasPrefix(".") }.map { url -> [String: Any] in
        let values = try url.resourceValues(forKeys: [.isDirectoryKey,.fileSizeKey,.contentModificationDateKey])
        return ["name": url.lastPathComponent, "path": virtual(url), "kind": values.isDirectory == true ? "directory" : "file", "size": values.fileSize ?? 0, "mtimeMs": (values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000]
      }
    default: throw PiDurableRuntimeError.unavailable("Unsupported durable filesystem operation")
    }
    return NSNull()
  }
  private func resolve(_ path: String) throws -> URL {
    let components = path.split(separator: "/").map(String.init)
    guard !components.contains(".."), !path.contains("\0") else {
      throw PiDurableRuntimeError.unavailable("Durable paths cannot escape their conversation")
    }
    let url = components.filter { $0 != "." }.reduce(directory) { $0.appendingPathComponent($1) }.standardizedFileURL
    let canonical = url.resolvingSymlinksInPath().path
    guard canonical == directory.path || canonical.hasPrefix(directory.path + "/") else {
      throw PiDurableRuntimeError.unavailable("Durable symlinks cannot escape their conversation")
    }
    return url
  }
  private func virtual(_ url: URL) -> String {
    let relative = String(url.path.dropFirst(directory.path.count))
    return relative.isEmpty ? "/" : relative
  }
  private func write(_ content: Data, to url: URL, append: Bool) throws {
    let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW | (append ? O_APPEND : O_TRUNC), S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw posixError() }
    defer { Darwin.close(descriptor) }
    try content.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw posixError() }
        offset += count
      }
    }
    guard fsync(descriptor) == 0 else { throw posixError() }
    // The marker and its parent directory must survive before a commit is published.
    try syncDirectory()
  }
  private func syncDirectory() throws {
    let descriptor = Darwin.open(directory.path, O_RDONLY)
    guard descriptor >= 0 else { throw posixError() }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else { throw posixError() }
  }
  private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
