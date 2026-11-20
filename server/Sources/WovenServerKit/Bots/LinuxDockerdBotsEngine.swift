import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import WovenProtocol

/// Bots on Linux run in a dockerd of Woven's own, installed once with sudo by
/// `bots/engine/bots-engine.py`: its own socket, data root, bridge, nftables
/// table and systemd units, apart from any Docker the person runs. The server
/// never needs root afterwards: the socket belongs to the person's group, and
/// a changed pool or disk cap is a request file that a root path unit applies.
struct LinuxDockerdBotsEngine: BotsEngine {
  /// The names `bots-engine.py` derives from its instance name.
  let instance: String
  var kind: String { "linux-dockerd" }

  init(instance: String = "wovenmatter") {
    self.instance = instance
  }

  var socket: String { "/run/\(instance)/docker.sock" }
  private var config: String { "/etc/\(instance)-bots/instance.json" }
  private var root: String { "/var/lib/\(instance)-bots" }
  private var requests: String { root + "/requests" }
  private var state: String { root + "/state/state.json" }
  private var data: String { root + "/docker" }

  /// What the installer stored: the account, pool and disk cap in effect.
  private struct Installed: Decodable {
    var user: String
    var poolBytes: Int64?
    var diskBytes: Int64?
  }

  private struct State: Decodable {
    var appliedRevision: String?
    var requestError: String?
    var requestDetail: String?
  }

  func prepare(_ resources: BotsResources) async throws -> String {
    guard let installed = read(Installed.self, config) else {
      let installer = Resources.root.appending(path: "bots/engine/bots-engine.py").path
      throw RuntimeError.failed("""
        The bots' container engine is not installed on this machine. Install it once with: \
        sudo python3 \(Self.quoted(installer)) install --user \(Self.quoted(NSUserName()))
        """)
    }
    guard installed.user == NSUserName() else {
      throw RuntimeError.failed("The bots' container engine on this machine belongs to the account \(installed.user).")
    }
    let clock = ContinuousClock(), deadline = clock.now + .seconds(60)
    while !(await UnixHTTP.dockerAnswers(socket)) {
      guard clock.now < deadline else {
        throw RuntimeError.failed("The bots' container engine is not running. Start it with: sudo systemctl start \(instance)-docker.service")
      }
      try await Task.sleep(for: .seconds(1))
    }
    if installed.poolBytes != resources.poolBytes || installed.diskBytes != resources.diskBytes {
      try await apply(resources)
    }
    return socket
  }

  /// Asks the engine's root unit to apply the pool (the engine's systemd
  /// slice) and the disk cap (its storage image). A lower disk cap stops at
  /// what the bots already store.
  func apply(_ resources: BotsResources) async throws {
    let revision = UUID().uuidString.lowercased()
    var request: [String: Any] = ["revision": revision]
    request["poolBytes"] = resources.poolBytes ?? NSNull()
    request["diskBytes"] = resources.diskBytes ?? NSNull()
    let body = try JSONSerialization.data(withJSONObject: request)
    let temporary = requests + "/.settings-\(revision).json"
    // Renamed into place, so the engine's unit never reads half a request.
    guard (try? body.write(to: URL(fileURLWithPath: temporary))) != nil,
          rename(temporary, requests + "/settings.json") == 0 else {
      unlink(temporary)
      throw RuntimeError.failed("The bots' limits could not be passed to the container engine in \(requests).")
    }
    // Most changes apply in a moment; resizing storage can take longer and
    // goes on by itself.
    let clock = ContinuousClock(), deadline = clock.now + .seconds(15)
    while clock.now < deadline {
      if let state = read(State.self, state), state.appliedRevision == revision {
        if state.requestError != nil {
          throw RuntimeError.failed(state.requestDetail ?? "The container engine refused the bots' limits.")
        }
        return
      }
      try await Task.sleep(for: .milliseconds(500))
    }
  }

  func capacity() async -> BotsCapacity? {
    guard let memory = Self.memoryTotal(), let host = Self.filesystem(root) else { return nil }
    var used: Int64?
    // The bots' storage is its own mounted image: what it holds is theirs.
    if let disk = Self.filesystem(data), disk.device != host.device { used = disk.used }
    return BotsCapacity(memoryBytes: memory, diskTotalBytes: host.total, diskFreeBytes: host.free, diskUsedByBotsBytes: used)
  }

  /// The engine is the machine's own service; the runtime stops its containers.
  func stop() async {}

  // MARK: -

  private func read<Value: Decodable>(_ type: Value.Type, _ path: String) -> Value? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(Value.self, from: data)
  }

  static func memoryTotal() -> Int64? {
    guard let text = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") where line.hasPrefix("MemTotal:") {
      let fields = line.split(separator: " ")
      if fields.count >= 2, let kilobytes = Int64(fields[1]) { return kilobytes * 1024 }
    }
    return nil
  }

  static func filesystem(_ path: String) -> (total: Int64, free: Int64, used: Int64, device: UInt64)? {
    var info = statvfs()
    var file = stat()
    guard statvfs(path, &info) == 0, stat(path, &file) == 0 else { return nil }
    let unit = Int64(info.f_frsize)
    let total = Int64(info.f_blocks) * unit
    return (total, Int64(info.f_bavail) * unit, total - Int64(info.f_bfree) * unit, UInt64(file.st_dev))
  }

  private static func quoted(_ text: String) -> String {
    text.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) } ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
