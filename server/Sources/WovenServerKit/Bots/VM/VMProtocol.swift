// Woven's Linux VM for the bots' containers runs on a Mac only (Virtualization).
#if os(macOS)
import CryptoKit
import Darwin
import Foundation

// What the server and the VM helper (`app/VMHelper`) both know about the VM.
// `scripts/build-vm-helper.sh` compiles this file into the helper too, so it
// depends on Foundation and CryptoKit only.

/// The VM's lifecycle as the helper reports it. `failed` always carries a reason.
enum WovenVMPhase: String, Codable, Sendable {
  case stopped, downloading, preparing, booting, provisioning, ready, failed
}

/// The VM's memory and the bots' disk cap. `nil` means no cap: all of the
/// Mac's memory, or a sparse disk bounded only by the volume that holds it.
struct WovenVMResources: Codable, Sendable, Equatable {
  var memoryBytes: UInt64?
  var diskBytes: UInt64?

  init(memoryBytes: UInt64? = 8 << 30, diskBytes: UInt64? = 50 << 30) {
    self.memoryBytes = memoryBytes
    self.diskBytes = diskBytes
  }

  static let minimumMemoryBytes: UInt64 = 1 << 30
  /// The guest OS and Docker Engine need room beyond what bots use.
  static let minimumDiskBytes: UInt64 = 10 << 30
}

/// Totals and live usage, in bytes.
struct WovenVMResourceReport: Codable, Sendable, Equatable {
  var hostMemoryBytes: UInt64
  var hostDiskTotalBytes: UInt64
  var hostDiskFreeBytes: UInt64
  /// Memory the running VM was booted with (the pool).
  var vmMemoryBytes: UInt64
  /// Physical memory the VM currently holds on the Mac.
  var vmMemoryFootprintBytes: UInt64?
  var guestMemoryUsedBytes: UInt64?
  var balloonTargetBytes: UInt64?
  /// The disk cap in effect inside the guest.
  var vmDiskCapBytes: UInt64
  /// Blocks the sparse disk images actually occupy on the Mac.
  var vmDiskAllocatedBytes: UInt64
  var guestDiskUsedBytes: UInt64?
  /// A pool change applies exactly when the VM next restarts, which the
  /// helper does by itself once no container is running.
  var restartPending: Bool
}

struct WovenVMGuestInfo: Codable, Sendable, Equatable {
  var os: String?
  var kernel: String?
  var docker: String?
}

struct WovenVMStatus: Codable, Sendable, Equatable {
  var phase: WovenVMPhase
  /// The current step, for example "Installing Docker Engine".
  var detail: String?
  var failure: String?
  /// 0...1 while downloading.
  var progress: Double?
  var engineSocket: String
  var resources: WovenVMResourceReport?
  var guest: WovenVMGuestInfo?
}

/// What explains a stuck or failed VM (`GET /diagnostics`).
struct WovenVMDiagnostics: Codable, Sendable, Equatable {
  var status: WovenVMStatus
  /// The end of `helper.log`.
  var helperLog: String
  /// The end of `console.log` (the guest's hvc0 console).
  var console: String
  /// The guest agent's `diagnostics`, one text per item; nil when the guest
  /// did not answer (`guestError` says why).
  var guest: [String: String]?
  var guestError: String?
}

enum WovenVMError: Error, LocalizedError, Equatable {
  case invalid(String)
  case unavailable(String)
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .invalid(let message), .unavailable(let message), .failed(let message): message
    }
  }
}

/// Every file the VM owns lives under `root` (in the server's data folder);
/// the sockets live there too unless that path is too long for a socket.
struct WovenVMPaths: Sendable, Equatable {
  let root: URL
  let socketDirectory: URL

  init(root: URL) {
    self.root = root.standardizedFileURL
    socketDirectory = Self.socketDirectory(root: self.root)
  }

  var config: URL { root.appending(path: "config.json") }
  var state: URL { root.appending(path: "state.json") }
  var disk: URL { root.appending(path: "disk.img") }
  var dataDisk: URL { root.appending(path: "data.img") }
  var efiVariables: URL { root.appending(path: "efi-vars.fd") }
  var seed: URL { root.appending(path: "seed.iso") }
  var console: URL { root.appending(path: "console.log") }
  var log: URL { root.appending(path: "helper.log") }
  var downloads: URL { root.appending(path: "downloads", directoryHint: .isDirectory) }
  var engineSocket: URL { socketDirectory.appending(path: "docker.sock") }
  var controlSocket: URL { socketDirectory.appending(path: "control.sock") }

  /// sun_path holds 104 bytes on macOS. A longer root keeps its sockets in a
  /// private per-user directory keyed by the root.
  static func socketDirectory(root: URL) -> URL {
    if root.appending(path: "control.sock").path.utf8.count < 100 { return root }
    let digest = SHA256.hash(data: Data(root.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    return URL(fileURLWithPath: "/private/tmp/wovenmatter-vm-\(getuid())-\(digest)", isDirectory: true)
  }

  /// Creates `directory` (mode 0700) when missing, then requires it to be a
  /// real directory owned by this user that nobody else can enter: in the
  /// shared /private/tmp another local user could otherwise create it first
  /// and receive the engine and control connections.
  static func preparePrivateDirectory(_ directory: URL, create: Bool = true) throws {
    let path = directory.path
    if create, mkdir(path, 0o700) != 0, errno != EEXIST {
      throw WovenVMError.unavailable("The VM's socket directory could not be created.")
    }
    var info = stat()
    guard lstat(path, &info) == 0 else { throw WovenVMError.unavailable("The VM's socket directory is missing.") }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
      throw WovenVMError.invalid("\(path) belongs to another user or is not a directory. Remove it, then start the bots again.")
    }
    if info.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 {
      throw WovenVMError.invalid("\(path) could not be made private.")
    }
  }
}

/// The ports the guest agent listens on. Containers cannot open AF_VSOCK
/// sockets under Docker's default seccomp profile.
enum WovenVMGuestPort {
  static let agent: UInt32 = 2000
  static let docker: UInt32 = 2375
}

/// The helper's control API: HTTP/1.1 with JSON bodies on a 0600 Unix socket,
/// one request per connection, so `curl --unix-socket` can use it too.
enum WovenVMControlHTTP {
  struct Request: Equatable, Sendable {
    var method: String
    var path: String
    var body: Data
  }

  static let maximumBody = 1 << 20

  /// Returns nil while the request is still incomplete.
  static func parseRequest(_ data: Data) throws -> Request? {
    guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
      if data.count > 16_384 { throw WovenVMError.invalid("Request headers are too large.") }
      return nil
    }
    guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
      throw WovenVMError.invalid("Request headers are not UTF-8.")
    }
    let lines = head.components(separatedBy: "\r\n")
    let parts = lines[0].split(separator: " ")
    guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw WovenVMError.invalid("Malformed request line.") }
    var length = 0
    for line in lines.dropFirst() {
      let pair = line.split(separator: ":", maxSplits: 1)
      guard pair.count == 2 else { continue }
      let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
      let value = pair[1].trimmingCharacters(in: .whitespaces)
      if name == "content-length" {
        guard let parsed = Int(value), parsed >= 0, parsed <= maximumBody else {
          throw WovenVMError.invalid("The request body is too large.")
        }
        length = parsed
      } else if name == "transfer-encoding" {
        throw WovenVMError.invalid("Chunked requests are not supported.")
      }
    }
    let bodyStart = end.upperBound
    guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
    return Request(method: String(parts[0]), path: String(parts[1]), body: Data(data[bodyStart..<bodyStart + length]))
  }

  static func response(status: Int, body: Data) -> Data {
    let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 404: "Not Found", 409: "Conflict",
                  500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Status"
    var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
    if !body.isEmpty { head += "Content-Type: application/json\r\n" }
    return Data((head + "\r\n").utf8) + body
  }

  /// The error body every non-2xx reply carries.
  struct ErrorBody: Codable, Sendable { var error: String }
}
#endif
