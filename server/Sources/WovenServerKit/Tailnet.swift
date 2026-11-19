import Foundation
import Synchronization

/// A machine of the tailnet that may run a Woven server.
public struct TailnetMachine: Sendable, Hashable {
  public var name: String
  public var host: String
  public var port: Int

  public init(name: String, host: String, port: Int = wovenPort) {
    self.name = name
    self.host = host
    self.port = port
  }
}

/// The port every Woven server listens on, on its tailnet address.
public let wovenPort = 7337

/// What the server asks of the network. Tailscale is the security boundary:
/// this decides who may connect, and which machines to try.
public protocol Tailnet: Sendable {
  /// The tailnet name of the machine calling from `address`, or nil when it
  /// is not a machine of this tailnet (including one shared in from another).
  func caller(at address: String) async -> String?
  /// The other machines of the tailnet, to try for a Woven server.
  func machines() async throws -> [TailnetMachine]
  /// This machine on the tailnet: its name and the address to listen on.
  func thisMachine() async throws -> TailnetMachine
}

/// A tailnet for tests: callers from listed addresses are let in, and the
/// machine list is whatever the test sets.
public final class StandInTailnet: Tailnet {
  private let state: Mutex<(allowed: Set<String>, machines: [TailnetMachine])>
  private let this: TailnetMachine

  public init(this: TailnetMachine = TailnetMachine(name: "stand-in", host: "127.0.0.1", port: 0),
              allowed: Set<String> = ["127.0.0.1", "::1"]) {
    self.this = this
    state = Mutex((allowed, []))
  }

  public func setMachines(_ machines: [TailnetMachine]) {
    state.withLock { $0.machines = machines }
  }

  public func caller(at address: String) async -> String? {
    state.withLock { $0.allowed.contains(address) } ? address : nil
  }

  public func machines() async throws -> [TailnetMachine] {
    state.withLock { $0.machines }
  }

  public func thisMachine() async throws -> TailnetMachine { this }
}

/// The tailnet as the local Tailscale reports it, through its command line.
public struct TailscaleTailnet: Tailnet {
  public struct Unavailable: Error, CustomStringConvertible {
    public let description: String
  }

  public init() {}

  public func caller(at address: String) async -> String? {
    guard let status = try? await json(["status", "--json"]),
          let suffix = (status["CurrentTailnet"] as? [String: Any])?["MagicDNSSuffix"] as? String,
          let whois = try? await json(["whois", "--json", address]),
          let node = whois["Node"] as? [String: Any],
          let name = node["Name"] as? String else { return nil }
    // A node shared in from another tailnet has a sharer, and a name outside
    // this tailnet's domain.
    let sharer = node["Sharer"] as? Int ?? 0
    guard sharer == 0, name.lowercased().hasSuffix(".\(suffix.lowercased()).") else { return nil }
    return node["ComputedName"] as? String ?? name
  }

  public func machines() async throws -> [TailnetMachine] {
    let status = try await json(["status", "--json"])
    guard status["BackendState"] as? String == "Running" else { throw Unavailable(description: "Tailscale is not connected.") }
    let suffix = ((status["CurrentTailnet"] as? [String: Any])?["MagicDNSSuffix"] as? String ?? "").lowercased()
    let peers = (status["Peer"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
    return peers.compactMap { peer in
      let os = (peer["OS"] as? String ?? "").lowercased()
      let dns = (peer["DNSName"] as? String ?? "").lowercased()
      guard ["macos", "linux"].contains(os), peer["ShareeNode"] as? Bool != true,
            !suffix.isEmpty, dns.hasSuffix(".\(suffix)."),
            let address = (peer["TailscaleIPs"] as? [String])?.first(where: { !$0.contains(":") }) else { return nil }
      return TailnetMachine(name: peer["HostName"] as? String ?? dns, host: address)
    }.sorted { $0.name < $1.name }
  }

  public func thisMachine() async throws -> TailnetMachine {
    let status = try await json(["status", "--json"])
    guard status["BackendState"] as? String == "Running", let this = status["Self"] as? [String: Any],
          let address = (this["TailscaleIPs"] as? [String])?.first(where: { !$0.contains(":") }) else {
      throw Unavailable(description: "Tailscale is not connected.")
    }
    return TailnetMachine(name: this["HostName"] as? String ?? address, host: address)
  }

  private static let candidates = [
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    "/opt/homebrew/bin/tailscale",
    "/usr/local/bin/tailscale",
    "/usr/bin/tailscale",
  ]

  private func json(_ arguments: [String]) async throws -> [String: Any] {
    guard let executable = Self.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      throw Unavailable(description: "Tailscale is not installed.")
    }
    let data = try await run(executable, arguments)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Unavailable(description: "Tailscale did not report its status.")
    }
    return object
  }

  private func run(_ executable: String, _ arguments: [String]) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // The app-bundle binary acts as the command line only when told to.
        var environment = ProcessInfo.processInfo.environment
        environment["TAILSCALE_BE_CLI"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
          try process.run()
          let data = output.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          guard process.terminationStatus == 0 else {
            throw Unavailable(description: "tailscale \(arguments.first ?? "") failed.")
          }
          continuation.resume(returning: data)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
