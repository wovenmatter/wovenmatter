#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import WovenMatterCore

/// Files under one data root (docs/architecture/WOVEN_EVERYWHERE.md, "Library host").
/// The root and every directory the host creates are private to its user.
public struct LibraryHostLayout: Sendable, Equatable {
  public let root: URL
  public init(root: URL) { self.root = root.standardizedFileURL }

  /// DashboardStore support directory: workspace.sqlite, dashboard-device-id, library files.
  public var library: URL { root.appending(path: "library", directoryHint: .isDirectory) }
  /// File-backed secrets that macOS keeps in the Keychain.
  public var secrets: URL { root.appending(path: "secrets", directoryHint: .isDirectory) }
  public var run: URL { root.appending(path: "run", directoryHint: .isDirectory) }
  public var defaultSocket: URL { run.appending(path: "library.sock") }
  public var defaultTokenFile: URL { run.appending(path: "library-api.token") }
  /// This machine's member signing key (raw Ed25519 key, base64, 0600).
  public var memberKeyFile: URL { secrets.appending(path: "member-signing.key") }
  /// Written once listeners are ready; removed on clean shutdown.
  public var endpointFile: URL { run.appending(path: "library.json") }

  public func prepare() throws {
    for directory in [root, library, secrets, run] { try Self.privateDirectory(directory) }
  }

  static func privateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
      throw LibraryHostError.unsafePath(url.path)
    }
    if info.st_mode & 0o077 != 0 { guard chmod(url.path, 0o700) == 0 else { throw LibraryHostError.unsafePath(url.path) } }
  }
}

public enum LibraryHostError: LocalizedError, Equatable {
  case usage(String)
  case unsafePath(String)
  case token(String)
  public var errorDescription: String? {
    switch self {
    case .usage(let message): message
    case .unsafePath(let path): "\(path) must be a directory or file owned by this user and private to it."
    case .token(let message): message
    }
  }
}

/// The shared secret between this host and its local Node server. The Node
/// server may write the file first; otherwise the host creates it. Either way
/// it is a 0600 regular file owned by this user, holding 43+ base64url characters.
public struct LibraryHostToken: Sendable {
  private let digest: Data

  public static func load(_ url: URL, create: Bool = true) throws -> LibraryHostToken {
    let manager = FileManager.default
    if !manager.fileExists(atPath: url.path) {
      guard create else { throw LibraryHostError.token("The library API token file is missing.") }
      try LibraryHostLayout.privateDirectory(url.deletingLastPathComponent())
      var bytes = [UInt8](repeating: 0, count: 32)
      var generator = SystemRandomNumberGenerator()
      for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
      let value = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
      let staging = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).token")
      guard manager.createFile(atPath: staging.path, contents: Data((value + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
        throw LibraryHostError.token("The library API token could not be written.")
      }
      // A concurrent writer (the Node server) wins; link fails if it exists.
      if link(staging.path, url.path) != 0 && errno != EEXIST {
        try? manager.removeItem(at: staging)
        throw LibraryHostError.token("The library API token could not be written.")
      }
      try? manager.removeItem(at: staging)
    }
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
      throw LibraryHostError.unsafePath(url.path)
    }
    let value = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.utf8.count >= 43, value.utf8.count <= 256,
          value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
      throw LibraryHostError.token("The library API token must be 43 to 256 base64url characters.")
    }
    return LibraryHostToken(digest: Data(SHA256.hash(data: Data(value.utf8))))
  }

  /// Compares digests in constant time.
  public func accepts(_ bearer: String?) -> Bool {
    guard let bearer else { return false }
    let candidate = Data(SHA256.hash(data: Data(bearer.utf8)))
    return zip(candidate, digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}
