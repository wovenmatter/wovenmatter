import Foundation
import WovenLibrary
import WovenProtocol

/// Start, stop, restart and the log. A server carries these out for itself: on
/// Linux through its systemd user unit, on a Mac by ending cleanly (launchd
/// then leaves it stopped) or through its launchd job. A Mac's server carries
/// them out over SSH for a Linux machine it cannot reach, which is how a
/// stopped one is started. Both platforms write the server's log to
/// `server.log` in its data folder.
func registerServerControl(_ router: inout Router, library: Library, sessions: SessionManager, peers: PeerSync,
                           tailnet: any Tailnet, dataFolder: URL, instance: String?, install: LinuxInstall?) {
  let log = dataFolder.appendingPathComponent("server.log")

  router.on(ControlServer.self) { request, _ in
    if request.machineID == library.machineID {
      if request.action != .start, !request.confirmed, sessions.board.current.contains(where: { $0.run == .running }) {
        return ServerControlResult(confirmationRequired: true)
      }
      if request.action != .start { try controlSelf(request.action, instance: instance) }
      return ServerControlResult(confirmationRequired: false)
    }
    let (install, target) = try await linuxTarget(request.machineID, library: library, install: install)
    do {
      try await install.control(request.action, on: target)
    } catch let failure as LinuxInstall.Failure {
      throw ProtocolError(.failed, failure.description)
    }
    // Looks for it at once rather than at the next discovery.
    if request.action != .stop { _ = await peers.waitForServer(of: request.machineID, timeout: .seconds(60)) }
    return ServerControlResult(confirmationRequired: false)
  }

  router.on(ServerLog.self) { request, _ in
    if request.machineID == library.machineID { return tail(of: log) }
    let (install, target) = try await linuxTarget(request.machineID, library: library, install: install)
    do {
      return try await install.log(on: target)
    } catch let failure as LinuxInstall.Failure {
      throw ProtocolError(.failed, failure.description)
    }
  }
}

/// A Linux machine and how this machine reaches it over SSH, for a request
/// that needs both; refused when either is missing.
func linuxTarget(_ machineID: String, library: Library,
                 install: LinuxInstall?) async throws -> (LinuxInstall, LinuxInstall.Target) {
  guard let install else { throw ProtocolError(.failed, "This machine cannot reach another machine's server over SSH.") }
  guard let machine = try await library.machine(machineID), machine.platform == .linux else {
    throw ProtocolError(.notFound, "No Linux machine \(machineID).")
  }
  guard let target = try await sshTarget(of: machine.id, library: library) else {
    throw ProtocolError(.failed, "\(machine.name) was not installed from a Mac, so it cannot be reached over SSH.")
  }
  return (install, target)
}

/// The host and user given when the machine was installed, exactly, with its
/// id so the commands check they reached it. nil when it was not installed
/// from a Mac.
func sshTarget(of machineID: String, library: Library) async throws -> LinuxInstall.Target? {
  try await library.sshRoute(of: machineID).map { LinuxInstall.Target(host: $0.host, user: $0.user, machineID: machineID) }
}

/// Stops or restarts this server a moment after the reply has gone.
private func controlSelf(_ action: ServerAction, instance: String?) throws {
  #if os(macOS)
  let command: [String]
  if action == .stop {
    command = []
  } else {
    guard let label = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"], label.hasSuffix(".server") else {
      throw ProtocolError(.failed, "This server was not started by launchd, so it cannot restart itself.")
    }
    command = ["/bin/launchctl", "kickstart", "-k", "gui/\(getuid())/\(label)"]
  }
  #else
  let command = ["/usr/bin/env", "systemctl", "--user", "--no-block", action.rawValue,
                 LinuxInstall.unitName(instance: instance) + ".service"]
  #endif
  Task.detached {
    try? await Task.sleep(for: .milliseconds(300))
    if command.isEmpty {
      kill(getpid(), SIGTERM)
    } else {
      await ChildProcess.run(command[0], Array(command.dropFirst()))
    }
  }
}

/// The last 256 KB of the log, from the start of a line.
private func tail(of file: URL) -> String {
  guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
  defer { try? handle.close() }
  let size = (try? handle.seekToEnd()) ?? 0
  let start = size > 262_144 ? size - 262_144 : 0
  try? handle.seek(toOffset: start)
  let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
  guard start > 0, let newline = text.firstIndex(of: "\n") else { return text }
  return String(text[text.index(after: newline)...])
}

extension LinuxInstall {
  static func unitName(instance: String?) -> String { "woven-server" + (instance.map { "-" + $0 } ?? "") }

  /// Starts, stops or restarts the unit there.
  func control(_ action: ServerAction, on target: Target) async throws {
    _ = try await ssh(target, script: "systemctl --user \(action.rawValue) \(unit).service")
  }

  /// Whether the server can be installed there, and its storage. Changes nothing.
  func inspect(on target: Target) async throws -> HostFacts {
    let host = target.host
    let lines = try await ssh(target, script: """
      uname -m
      command -v systemctl >/dev/null && echo systemd || echo none
      df -Pk "$HOME" | tail -n 1
      """).split(separator: "\n").map(String.init)
    guard lines.count >= 3 else { throw Failure(description: "\(host) did not describe itself over SSH.") }
    let arch = lines[0].trimmingCharacters(in: .whitespaces)
    var problems: [String] = []
    if !["x86_64", "aarch64"].contains(arch) {
      problems.append("\(host) is \(arch); the server runs on x86_64 and aarch64.")
    } else if !FileManager.default.fileExists(atPath: bundle.appendingPathComponent("linux-\(arch)/woven-server.gz").path) {
      problems.append("This Mac does not carry the Linux server for \(arch).")
    }
    if lines[1] != "systemd" { problems.append("\(host) has no systemd to run the server.") }
    // df -P: filesystem, 1024-blocks, used, available, capacity, mount point.
    let df = lines[2].split(separator: " ", omittingEmptySubsequences: true)
    let blocks = df.count >= 4 ? Int64(df[1]) : nil, free = df.count >= 4 ? Int64(df[3]) : nil
    return HostFacts(architecture: arch, problems: problems,
                     storageCapacityBytes: blocks.map { $0 * 1024 }, storageAvailableBytes: free.map { $0 * 1024 })
  }

  /// The end of the server's log there.
  func log(on target: Target) async throws -> String {
    try await ssh(target, script: "tail -c 262144 \"$HOME/.local/share/\(unit)/data/server.log\" 2>/dev/null || true")
  }
}
