import Darwin
import Foundation
import WovenMatterCore

@MainActor
public protocol CompanionServingProcess: AnyObject {
  var isRunning: Bool { get }
  func terminate()
}

@MainActor
private final class NativeCompanionServeProcess: CompanionServingProcess {
  private let process: Process
  private var heartbeat: FileHandle?
  init(executable: URL, arguments: [String]) throws {
    guard let helper = Bundle.main.executableURL else {
      throw CompanionAPIError(code: "helper_unavailable", message: "The companion helper is unavailable.")
    }
    let pipe = Pipe()
    let writer = pipe.fileHandleForWriting
    _ = fcntl(writer.fileDescriptor, F_SETFD, FD_CLOEXEC)
    process = Process()
    process.executableURL = helper
    process.arguments = [CompanionServeSupervisor.argument, executable.path] + arguments
    process.standardInput = pipe
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    try? pipe.fileHandleForReading.close()
    heartbeat = writer
  }
  var isRunning: Bool { process.isRunning }
  func terminate() { try? heartbeat?.close(); heartbeat = nil }
  deinit { try? heartbeat?.close() }
}

/// Reserves an unused HTTPS port for a foreground Serve session. Terminating this
/// child removes only this session's routes; existing background/foreground routes
/// are never rewritten, reset, or stopped.
@MainActor
public final class CompanionTailscaleServe {
  public typealias Probe = @Sendable (URL, [String]) async throws -> Data
  public typealias Launch = @MainActor @Sendable (URL, [String]) throws -> any CompanionServingProcess
  private var process: (any CompanionServingProcess)?
  private var stoppingProcesses: [any CompanionServingProcess] = []
  private var generation = UUID()
  private let probe: Probe
  private let launch: Launch
  private let executableOverride: URL?
  public init(executable: URL? = nil, probe: Probe? = nil, launch: Launch? = nil) {
    executableOverride = executable
    self.probe = probe ?? { try await Self.run($0, $1) }
    self.launch = launch ?? { try NativeCompanionServeProcess(executable: $0, arguments: $1) }
  }

  public func start(loopbackPort: UInt16, preferredHTTPSPort: Int? = nil) async throws -> URL {
    guard process == nil else { throw failure("Companion sharing is already running.") }
    generation = UUID()
    let attempt = generation
    // Closing the heartbeat starts asynchronous helper cleanup. Retain only our
    // own children until they exit before inspecting their former foreground port.
    let stopDeadline = ProcessInfo.processInfo.systemUptime + 3
    while stoppingProcesses.contains(where: \.isRunning) {
      guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
      guard ProcessInfo.processInfo.systemUptime < stopDeadline else {
        throw failure("The previous companion sharing process is still stopping. Retry shortly; existing routes were preserved.")
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    stoppingProcesses.removeAll()
    guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
    let executable = try executableOverride ?? Self.executableURL()
    let statusData = try await probe(executable, ["status", "--json"])
    guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
    guard let status = try JSONSerialization.jsonObject(with: statusData) as? [String: Any],
          status["BackendState"] as? String == "Running",
          let node = status["Self"] as? [String: Any],
          let rawHost = node["DNSName"] as? String else {
      throw failure("Connect Tailscale on this Mac, then start companion sharing.")
    }
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    guard host.hasSuffix(".ts.net"), host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else {
      throw failure("Tailscale did not provide a valid HTTPS name for this Mac.")
    }
    let before = try await probe(executable, ["serve", "status", "--json"])
    guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
    let used = try Self.occupiedPorts(in: before)
    let candidates = preferredHTTPSPort.map { [$0] } ?? [8443, 10_000, 8444, 8445]
    guard let httpsPort = candidates.first(where: { (1...65535).contains($0) && !used.contains($0) }) else {
      throw failure("The paired companion HTTPS port is in use by another Tailscale Serve route. Stop that route or retry after this app finishes stopping; existing routes were preserved.")
    }
    let child = try launch(executable, ["serve", "--https=\(httpsPort)", "--set-path=/wovenmatter", "http://127.0.0.1:\(loopbackPort)"])
    process = child
    do {
      for _ in 0..<40 {
        try await Task.sleep(for: .milliseconds(250))
        guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
        guard child.isRunning else { throw failure("Tailscale Serve could not start. Enable HTTPS certificates for this tailnet in the Tailscale admin console.") }
        let live = try await probe(executable, ["serve", "status", "--json"])
        guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
        if try Self.containsProxy(in: live, port: httpsPort, target: "http://127.0.0.1:\(loopbackPort)") {
          guard let endpoint = URL(string: "https://\(host):\(httpsPort)/wovenmatter") else { throw failure("Invalid companion endpoint.") }
          return endpoint
        }
      }
      throw failure("Tailscale sharing did not become ready. Check that HTTPS is enabled for this tailnet.")
    } catch {
      stopOwnedProcess(child)
      if process === child { process = nil }
      throw error
    }
  }

  public var isRunning: Bool { process?.isRunning == true }
  /// A host can create a new serving attempt without losing ownership of the
  /// previous attempt's asynchronous supervisor cleanup.
  public func waitUntilStopped() async throws {
    guard process == nil else { throw failure("Companion sharing is still running.") }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while stoppingProcesses.contains(where: \.isRunning) {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw failure("The previous companion sharing process is still stopping. Retry shortly; existing routes were preserved.")
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    stoppingProcesses.removeAll()
  }

  public func stop() {
    generation = UUID()
    if let process { stopOwnedProcess(process) }
    process = nil
  }

  private func stopOwnedProcess(_ child: any CompanionServingProcess) {
    stoppingProcesses.removeAll(where: { !$0.isRunning })
    guard child.isRunning, !stoppingProcesses.contains(where: { $0 === child }) else { return }
    child.terminate()
    if child.isRunning { stoppingProcesses.append(child) }
  }

  public static func occupiedPorts(in data: Data) throws -> Set<Int> {
    let root = try JSONSerialization.jsonObject(with: data)
    var ports = Set<Int>()
    func visit(_ value: Any) {
      if let dictionary = value as? [String: Any] {
        if let tcp = dictionary["TCP"] as? [String: Any] { ports.formUnion(tcp.keys.compactMap(Int.init)) }
        for child in dictionary.values { visit(child) }
      } else if let array = value as? [Any] { array.forEach(visit) }
    }
    visit(root)
    return ports
  }

  private static func containsProxy(in data: Data, port: Int, target: String) throws -> Bool {
    let root = try JSONSerialization.jsonObject(with: data)
    func visit(_ value: Any) -> Bool {
      guard let dictionary = value as? [String: Any] else { return false }
      if let web = dictionary["Web"] as? [String: Any] {
        for (address, configuration) in web where address.hasSuffix(":\(port)") {
          if let configuration = configuration as? [String: Any],
             let handlers = configuration["Handlers"] as? [String: Any],
             let handler = (handlers["/wovenmatter"] ?? handlers["/wovenmatter/"]) as? [String: Any],
             handler["Proxy"] as? String == target { return true }
        }
      }
      return dictionary.values.contains(where: visit)
    }
    return visit(root)
  }

  private static func executableURL() throws -> URL {
    let paths = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
    guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
      throw CompanionAPIError(code: "tailscale_unavailable", message: "Install and connect Tailscale on both the Mac and iPhone to pair them.")
    }
    return URL(fileURLWithPath: path)
  }

  private static func run(_ executable: URL, _ arguments: [String]) async throws -> Data {
    try await CompanionProcessProbe().run(executable: executable, arguments: arguments)
  }
  private func failure(_ message: String) -> CompanionAPIError { CompanionAPIError(code: "tailscale_unavailable", message: message) }
}
