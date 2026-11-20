import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Where every Unix socket for one data folder lives. A socket path holds at
// most 104 bytes on a Mac and 108 on Linux, and a data folder can be longer
// than that by itself, so the sockets live in a short per-user directory keyed
// by the data folder: /tmp/woven-<uid>/<16 hex digits>. Both levels are owner
// only. `scripts/build-vm-helper.sh` compiles this file into the VM helper
// too, so it depends on Foundation only.

/// The socket directory of one data folder.
public enum SocketFolder {
  public struct Failure: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public var errorDescription: String? { description }
  }

  /// The longest socket path that fits on both systems, without its NUL.
  public static let maximumPathBytes = 103

  /// The directory; `prepare` creates it.
  public static func directory(for dataFolder: URL) -> URL {
    // FNV-1a: stable across processes and builds, unlike Hasher.
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in dataFolder.standardizedFileURL.path.utf8 {
      hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
    return parent.appendingPathComponent(String(format: "%016llx", hash), isDirectory: true)
  }

  /// The path of socket `name` for `dataFolder`, with its directory prepared.
  public static func path(_ name: String, for dataFolder: URL) throws -> String {
    let directory = directory(for: dataFolder)
    try prepare(directory)
    let path = directory.appendingPathComponent(name).path
    try check(path)
    return path
  }

  /// Fails clearly for a socket path given from outside that cannot fit.
  public static func check(_ path: String) throws {
    guard path.utf8.count <= maximumPathBytes else {
      throw Failure(description: "The socket path \(path) is longer than \(maximumPathBytes) bytes.")
    }
  }

  /// Creates `directory` and its parent (mode 0700) when missing, then requires
  /// each to be a real directory of this user that nobody else can enter: in
  /// the shared /tmp another user could otherwise make it first and receive
  /// the connections.
  public static func prepare(_ directory: URL) throws {
    for path in [directory.deletingLastPathComponent().path, directory.path] {
      if mkdir(path, 0o700) != 0, errno != EEXIST {
        throw Failure(description: "The socket directory \(path) could not be created.")
      }
      var info = stat()
      guard lstat(path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid() else {
        throw Failure(description: "\(path) belongs to another user or is not a directory. Remove it, then start again.")
      }
      if info.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 {
        throw Failure(description: "\(path) could not be made private.")
      }
    }
  }

  /// Removes the sockets `names` of `dataFolder`, then its directory unless
  /// something else, such as another process's live socket, is still in it.
  public static func remove(_ names: [String], for dataFolder: URL) {
    let directory = directory(for: dataFolder)
    for name in names { unlink(directory.appendingPathComponent(name).path) }
    rmdir(directory.path)
  }

  private static var parent: URL { URL(fileURLWithPath: "/tmp/woven-\(getuid())", isDirectory: true) }
}
