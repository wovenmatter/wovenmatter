import Foundation
import WovenProtocol
#if canImport(Glibc)
import Glibc
#endif

/// Installs, updates and uninstalls the Linux server on another machine over
/// SSH, with the person's own SSH setup. The server runs there as a systemd
/// user unit, `woven-server` (a development instance appends its name), with
/// everything under ~/.local/share/<unit>: the release (the static binary and
/// the resources its child processes need: Pi Durable, the bots runtime, the
/// harness catalog and adapters), Node, and the data folder, which an update keeps.
///
/// The release is put together at install from this Mac: the static
/// `woven-server` for the target's architecture, which the app carries in
/// `bundle` (`linux-<arch>/woven-server.tar.xz`), and this Mac's own copy of
/// the resources, without its Node and npm. The target downloads the official
/// Linux Node that `bundle/node.json` names from nodejs.org and checks it
/// against the SHA-256 recorded there.
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
  /// Where Pi Durable, the bots runtime and the harness files come from.
  var resources: URL = Resources.root

  var unit: String { Self.unitName(instance: instance) }

  /// A machine reached over SSH: the host and user exactly as the person
  /// gave them at install, so their own SSH settings for that host apply
  /// unchanged, and, for a machine already installed there, its id. Every
  /// command on an installed machine first checks that the server there is
  /// that machine, so a host that now names another machine is never changed.
  struct Target: Sendable, Equatable {
    var host: String
    var user: String?
    var machineID: String?
  }

  /// The release this Mac carries for each architecture, from the app's resources.
  static var standardBundle: URL {
    if let path = ProcessInfo.processInfo.environment["WOVEN_LINUX_SERVER"] { return URL(fileURLWithPath: path, isDirectory: true) }
    return Resources.root.appendingPathComponent("linux-server", isDirectory: true)
  }

  /// Copies the release there and (re)starts the unit. The data folder stays.
  /// Returns the id of the machine the server there runs as.
  @discardableResult
  func install(on target: Target) async throws -> String {
    let host = target.host
    let facts = try await ssh(target, script: """
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
    let reported = facts[3...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    // It goes into the unit file, so only a plain one-line PATH is used.
    let path = reported.contains(where: { $0.isNewline || $0 == "%" || $0 == "\\" }) ? "" : reported

    // The Linux Node release and its SHA-256 for this architecture.
    guard let record = try? Data(contentsOf: bundle.appendingPathComponent("node.json")),
          let node = try? JSONDecoder().decode([String: String].self, from: record),
          let nodeVersion = node["version"], let nodeSHA256 = node[arch],
          !nodeVersion.isEmpty, Self.isPlain(nodeVersion, extra: "."), nodeSHA256.count == 64, Self.isPlain(nodeSHA256, extra: "") else {
      throw Failure(description: "This Mac does not carry the Linux server for \(arch).")
    }
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent("woven-install-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let upload = try await payload(arch: arch, in: staging)

    let root = "$HOME/.local/share/\(unit)"
    let nodeFolder = "node/v\(nodeVersion)"
    let nodeName = "node-v\(nodeVersion)-linux-\(arch == "x86_64" ? "x64" : "arm64")"
    var arguments = ["%h/.local/share/\(unit)/data", "--port", String(port), "--app-version", appVersion]
    // A development instance keeps its new folders with its data, not in ~/Woven Matter.
    if let instance { arguments += ["--instance", instance, "--folders", "%h/.local/share/\(unit)/folders"] }
    if standIn { arguments.append("--stand-in-runtime") }
    let resourcesFolder = "%h/.local/share/\(unit)/release/resources"
    let unitText = """
      [Unit]
      Description=Woven Matter server\(instance.map { " (\($0))" } ?? "")
      After=network-online.target

      [Service]
      ExecStart=%h/.local/share/\(unit)/release/woven-server \(arguments.joined(separator: " "))
      Environment=WOVEN_RESOURCES=\(resourcesFolder)
      Environment=WOVEN_NODE=%h/.local/share/\(unit)/\(nodeFolder)/bin/node
      Environment=PATH=\(path.isEmpty ? "/usr/local/bin:/usr/bin:/bin" : path):%h/.local/share/\(unit)/\(nodeFolder)/bin
      StandardOutput=append:%h/.local/share/\(unit)/data/server.log
      StandardError=append:%h/.local/share/\(unit)/data/server.log
      Restart=on-failure
      RestartSec=5
      # Another machine removed this one: stay stopped.
      RestartPreventExitStatus=3

      [Install]
      WantedBy=default.target
      """
    let installed = try await ssh(target, input: upload, script: """
      set -eu
      root="\(root)"
      mkdir -p "$root/data" "$HOME/.config/systemd/user"
      rm -rf "$root/release.next"
      mkdir -p "$root/release.next/resources"
      tar -xzf - -C "$root/release.next/resources"
      mv "$root/release.next/resources/woven-server" "$root/release.next/woven-server"
      chmod 0755 "$root/release.next/woven-server"
      # Node from nodejs.org, checked against the SHA-256 this Mac carries.
      node="$root/\(nodeFolder)"
      if [ ! -x "$node/bin/node" ]; then
        rm -rf "$root/node.next"
        mkdir -p "$root/node.next" "$root/node"
        url="https://nodejs.org/dist/v\(nodeVersion)/\(nodeName).tar.gz"
        if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 -o "$root/node.next/node.tar.gz" "$url"
        elif command -v wget >/dev/null 2>&1; then wget -q -O "$root/node.next/node.tar.gz" "$url"
        else echo "Downloading Node needs curl or wget." >&2; exit 1
        fi
        [ "$(sha256sum "$root/node.next/node.tar.gz" | cut -d ' ' -f 1)" = "\(nodeSHA256)" ] \\
          || { echo "The Node download from nodejs.org does not match its SHA-256." >&2; exit 1; }
        tar -xzf "$root/node.next/node.tar.gz" --strip-components=1 -C "$root/node.next" \\
          "\(nodeName)/bin" "\(nodeName)/lib" "\(nodeName)/LICENSE"
        rm "$root/node.next/node.tar.gz"
        rm -rf "$node"
        mv "$root/node.next" "$node"
      fi
      # Node must run here (a bare system can lack a library it needs) before the running server is replaced.
      "$node/bin/node" --version >/dev/null
      # Resources.npm finds Node's npm beside the resources.
      ln -s "$node" "$root/release.next/resources/node"
      systemctl --user stop \(unit).service 2>/dev/null || true
      rm -rf "$root/release"
      mv "$root/release.next" "$root/release"
      for other in "$root/node"/*; do [ "$other" = "$node" ] || rm -rf "$other"; done
      cat > "$HOME/.config/systemd/user/\(unit).service" <<'WOVEN_UNIT'
      \(unitText)
      WOVEN_UNIT
      systemctl --user daemon-reload
      systemctl --user enable \(unit).service >/dev/null 2>&1
      systemctl --user restart \(unit).service
      # The server names its machine once it has started.
      i=0
      while [ ! -s "$root/data/machine-id" ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
      cat "$root/data/machine-id"
      """)
    if linger == "no" {
      // Without lingering the unit stops when the person logs out there.
      _ = try? await ssh(target, script: "loginctl enable-linger \"$(id -un)\"")
    }
    let machineID = installed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !machineID.isEmpty else { throw Failure(description: "The server on \(host) did not start.") }
    return machineID
  }

  /// One gzip tar for SSH's standard input, unpacked there into the release's
  /// resources: `woven-server` for `arch` and, from `resources`, Pi Durable
  /// without this Mac's Node and npm, the bots runtime and the harness files.
  /// No Claude engine package and no tests, so a source checkout sends the same.
  func payload(arch: String, in staging: URL) async throws -> URL {
    let server = bundle.appendingPathComponent("linux-\(arch)/woven-server.tar.xz")
    guard FileManager.default.fileExists(atPath: server.path) else {
      throw Failure(description: "This Mac does not carry the Linux server for \(arch).")
    }
    let unpacked = await ChildProcess.run("/usr/bin/tar", ["-xf", server.path, "-C", staging.path, "woven-server"])
    guard unpacked.status == 0 else { throw Failure(description: "Could not unpack the Linux server: \(unpacked.output)") }
    let upload = staging.appendingPathComponent("release.tar.gz")
    // `^` anchors at the top, so the packages' own lib, bin and test folders stay.
    let excluded = ["^default-agent/bin", "^default-agent/lib", "^default-agent/test", "^bots/test",
                    "@anthropic-ai/claude-agent-sdk-*-*", ".DS_Store"]
    let packed = await ChildProcess.run("/usr/bin/tar", ["-czf", upload.path, "--no-mac-metadata", "--no-xattrs"]
                                          + excluded.flatMap { ["--exclude", $0] }
                                          + ["-C", staging.path, "woven-server", "-C", resources.path, "default-agent", "bots", "harnesses"],
                                        timeout: .seconds(600))
    guard packed.status == 0 else { throw Failure(description: "Could not pack the Linux server: \(packed.output)") }
    return upload
  }

  /// Stops and disables the unit and deletes everything it had there, its
  /// socket directory under /tmp included.
  func uninstall(on target: Target) async throws {
    _ = try await ssh(target, script: """
      systemctl --user disable --now \(unit).service >/dev/null 2>&1 || true
      sockets="$("$HOME/.local/share/\(unit)/release/woven-server" --socket-folder "$HOME/.local/share/\(unit)/data" 2>/dev/null)" || true
      case "$sockets" in "/tmp/woven-$(id -u)/"?*) rm -rf "$sockets" ;; esac
      rm -f "$HOME/.config/systemd/user/\(unit).service"
      systemctl --user daemon-reload || true
      systemctl --user reset-failed \(unit).service >/dev/null 2>&1 || true
      rm -rf "$HOME/.local/share/\(unit)"
      """)
  }

  /// Runs `script` with `sh` there and returns its standard output. Every
  /// SSH use goes through here; the unit's name goes into shell lines and the
  /// unit file, so it must be plain.
  func ssh(_ target: Target, input: URL? = nil, script: String) async throws -> String {
    guard Self.isPlain(instance ?? "", extra: "._-") else { throw Failure(description: "\(unit) is not a plain unit name.") }
    let arguments = try sshArguments(target, script: script)
    let result = await ChildProcess.run("/usr/bin/ssh", arguments, mergeErrors: false, input: input, timeout: .seconds(600))
    guard result.status == 0 else {
      let detail = result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
      throw Failure(description: "SSH to \(target.host) failed\(detail.isEmpty ? "" : ": " + String(detail.suffix(600)))")
    }
    return result.output
  }

  /// SSH's arguments for running `script` there: the host and user as given,
  /// and nothing that overrides the person's SSH settings. The host must be an
  /// IP address or a plain DNS name, the user a plain login name and the
  /// machine id plain, so none can be read as an option or shell.
  func sshArguments(_ target: Target, script: String) throws -> [String] {
    guard Self.isPlainHost(target.host) else { throw Failure(description: "\(target.host) is not an IP address or a DNS name.") }
    if let user = target.user, !user.isEmpty, !Self.isPlain(user, extra: "._-") {
      throw Failure(description: "\(user) is not a plain user name.")
    }
    var script = script
    if let machineID = target.machineID {
      guard !machineID.isEmpty, Self.isPlain(machineID, extra: "-") else { throw Failure(description: "\(machineID) is not a machine id.") }
      script = """
        if [ "$(cat "$HOME/.local/share/\(unit)/data/machine-id" 2>/dev/null)" != "\(machineID)" ]; then
          echo "\(target.host) is not this machine: its Woven server (\(unit)) is another machine's or is not installed there." >&2
          exit 97
        fi
        """ + "\n" + script
    }
    var arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15"]
    if let user = target.user, !user.isEmpty { arguments += ["-l", user] }
    // SSH joins its arguments into one command line for the remote shell.
    return arguments + ["--", target.host, "sh -c " + Self.quoted(script)]
  }

  static func quoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Letters, digits and `extra`, not starting with `-`. Empty is plain.
  private static func isPlain(_ text: String, extra: String) -> Bool {
    !text.hasPrefix("-") && text.unicodeScalars.allSatisfy {
      ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || extra.unicodeScalars.contains($0)
    }
  }

  /// An IPv4 or IPv6 address, or a DNS name of letters, digits, hyphens and dots.
  static func isPlainHost(_ host: String) -> Bool {
    var v4 = in_addr(), v6 = in6_addr()
    if inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 { return true }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    return !host.isEmpty && host.count <= 253 && labels.allSatisfy { label in
      !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
        && isPlain(String(label), extra: "-")
    }
  }
}
