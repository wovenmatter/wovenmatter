import Foundation
import WovenProtocol

/// Installs, updates and uninstalls the Linux server on another computer over
/// SSH, with the person's own SSH setup. The server runs there as a systemd
/// user unit, `woven-server` (a development instance appends its name), with
/// everything under ~/.local/share/<unit>: the release (the static binary and
/// the resources its child processes need: Node, Pi Durable, the harness
/// catalog and adapters) and the data folder, which an update keeps.
///
/// The release comes from `bundle`: `linux-<arch>/woven-server.gz` and
/// `linux-<arch>/resources.tar.gz`, which the Mac app carries, so nothing is
/// downloaded on the target.
struct LinuxInstall: Sendable {
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  var bundle: URL
  var instance: String?
  var port: Int
  var appVersion: String
  /// A development instance offers the stand-in runtime there too.
  var standIn: Bool

  var unit: String { "woven-server" + (instance.map { "-" + $0 } ?? "") }

  /// The release this Mac carries for each architecture, from the app's resources.
  static var standardBundle: URL {
    if let path = ProcessInfo.processInfo.environment["WOVEN_LINUX_SERVER"] { return URL(fileURLWithPath: path, isDirectory: true) }
    return Resources.root.appendingPathComponent("linux-server", isDirectory: true)
  }

  /// Copies the release there and (re)starts the unit. The data folder stays.
  func install(host: String, user: String?) async throws {
    let facts = try await ssh(host, user, script: """
      uname -m
      command -v systemctl >/dev/null && echo systemd || echo none
      loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || echo unknown
      "${SHELL:-/bin/sh}" -lc 'printf %s "$PATH"' 2>/dev/null </dev/null || printf %s "$PATH"
      """).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard facts.count >= 4 else { throw Failure(description: "\(host) did not describe itself over SSH.") }
    let arch = facts[0].trimmingCharacters(in: .whitespaces)
    guard ["x86_64", "aarch64"].contains(arch) else { throw Failure(description: "\(host) is \(arch); the server runs on x86_64 and aarch64.") }
    guard facts[1] == "systemd" else { throw Failure(description: "\(host) has no systemd to run the server.") }
    let linger = facts[2].trimmingCharacters(in: .whitespaces)
    let path = facts[3...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

    let release = bundle.appendingPathComponent("linux-\(arch)", isDirectory: true)
    for file in ["woven-server.gz", "resources.tar.gz"] where !FileManager.default.fileExists(atPath: release.appendingPathComponent(file).path) {
      throw Failure(description: "This Mac does not carry the Linux server for \(arch).")
    }
    // One tar on SSH's standard input: the two files, unpacked there.
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent("woven-install-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let upload = staging.appendingPathComponent("release.tar")
    let packed = await ChildProcess.run("/usr/bin/tar", ["-cf", upload.path, "-C", release.path, "woven-server.gz", "resources.tar.gz"])
    guard packed.status == 0 else { throw Failure(description: "Could not pack the Linux server: \(packed.output)") }

    let root = "$HOME/.local/share/\(unit)"
    var arguments = ["%h/.local/share/\(unit)/data", "--port", String(port), "--app-version", appVersion]
    // A development instance keeps its new folders with its data, not in ~/Woven Matter.
    if let instance { arguments += ["--instance", instance, "--folders", "%h/.local/share/\(unit)/folders"] }
    if standIn { arguments.append("--stand-in-runtime") }
    let resources = "%h/.local/share/\(unit)/release/resources"
    let unitText = """
      [Unit]
      Description=Woven Matter server\(instance.map { " (\($0))" } ?? "")
      After=network-online.target

      [Service]
      ExecStart=%h/.local/share/\(unit)/release/woven-server \(arguments.joined(separator: " "))
      Environment=WOVEN_RESOURCES=\(resources)
      Environment=WOVEN_NODE=\(resources)/node/bin/node
      Environment=PATH=\(path.isEmpty ? "/usr/local/bin:/usr/bin:/bin" : path):\(resources)/node/bin
      Restart=on-failure
      RestartSec=5
      # Another machine removed this one: stay stopped.
      RestartPreventExitStatus=3

      [Install]
      WantedBy=default.target
      """
    _ = try await ssh(host, user, input: upload, script: """
      set -eu
      root="\(root)"
      mkdir -p "$root/data" "$HOME/.config/systemd/user"
      rm -rf "$root/release.next"
      mkdir -p "$root/release.next/resources"
      cd "$root/release.next"
      tar -xf -
      gunzip woven-server.gz
      chmod 0755 woven-server
      tar -xzf resources.tar.gz -C resources
      rm resources.tar.gz
      systemctl --user stop \(unit).service 2>/dev/null || true
      rm -rf "$root/release"
      mv "$root/release.next" "$root/release"
      cat > "$HOME/.config/systemd/user/\(unit).service" <<'WOVEN_UNIT'
      \(unitText)
      WOVEN_UNIT
      systemctl --user daemon-reload
      systemctl --user enable \(unit).service >/dev/null 2>&1
      systemctl --user restart \(unit).service
      """)
    if linger == "no" {
      // Without lingering the unit stops when the person logs out there.
      _ = try? await ssh(host, user, script: "loginctl enable-linger \"$(id -un)\"")
    }
  }

  /// Stops and disables the unit and deletes everything it had there.
  func uninstall(host: String, user: String?) async throws {
    _ = try await ssh(host, user, script: """
      systemctl --user disable --now \(unit).service >/dev/null 2>&1 || true
      rm -f "$HOME/.config/systemd/user/\(unit).service"
      systemctl --user daemon-reload || true
      systemctl --user reset-failed \(unit).service >/dev/null 2>&1 || true
      rm -rf "$HOME/.local/share/\(unit)"
      """)
  }

  /// Runs `script` with `sh` there and returns its standard output.
  private func ssh(_ host: String, _ user: String?, input: URL? = nil, script: String) async throws -> String {
    var arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15"]
    if let user, !user.isEmpty { arguments += ["-l", user] }
    // SSH joins its arguments into one command line for the remote shell.
    arguments += [host, "sh -c " + Self.quoted(script)]
    let result = try await Self.run("/usr/bin/ssh", arguments, input: input, timeout: .seconds(600))
    guard result.status == 0 else {
      let detail = result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
      throw Failure(description: "SSH to \(host) failed\(detail.isEmpty ? "" : ": " + String(detail.suffix(600)))")
    }
    return result.output
  }

  static func quoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Runs a command with an optional file as its standard input; output and
  /// errors are kept apart.
  private static func run(_ executable: String, _ arguments: [String], input: URL?,
                          timeout: Duration) async throws -> (status: Int32, output: String, errors: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = try input.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
    try process.run()
    let watchdog = Task {
      try await Task.sleep(for: timeout)
      process.terminate()
    }
    async let out = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
    async let err = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
    let (outData, errData) = await (out, err)
    await Task.detached { process.waitUntilExit() }.value
    watchdog.cancel()
    return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
  }
}
