import Foundation

/// Pi Bot's delivered files, inside `Contents/Resources/pi-bot`.
public struct PiBotBundle: Equatable, Sendable {
    public let directory: URL
    public let selection: PiBotSelection

    public var script: URL { directory.appending(path: "pi-bot-host.sh") }
    public var archive: URL { directory.appending(path: "pi-bot-bundle.tar.gz") }
    public var tooling: URL { directory.appending(path: "tooling", directoryHint: .isDirectory) }
    public var relay: URL { directory.appending(path: "pi-bot-relay.mjs") }

    public init(directory: URL) throws {
        self.directory = directory
        selection = try JSONDecoder().decode(PiBotSelection.self, from: Data(contentsOf: directory.appending(path: "selection.json")))
    }

    public static func bundled(in bundle: Bundle = .main) throws -> PiBotBundle {
        guard let resources = bundle.resourceURL else { throw PiBotHostError.bundleMissing }
        let directory = resources.appending(path: "pi-bot", directoryHint: .isDirectory)
        guard FileManager.default.isReadableFile(atPath: directory.appending(path: "selection.json").path),
              FileManager.default.isReadableFile(atPath: directory.appending(path: "pi-bot-bundle.tar.gz").path),
              FileManager.default.isReadableFile(atPath: directory.appending(path: "pi-bot-host.sh").path),
              FileManager.default.isReadableFile(atPath: directory.appending(path: "pi-bot-relay.mjs").path) else {
            throw PiBotHostError.bundleMissing
        }
        return try PiBotBundle(directory: directory)
    }
}

/// Tailnet device discovery for bot deployment. Unlike remote workspaces this admits
/// Macs as well as Linux, and unlike Apple Devices it never pairs libraries. Every
/// address comes from tailscaled; DNS and SSH aliases never choose the transport.
public enum PiBotTailnet {
    public static func executable() throws -> String {
        do { return try RemoteWorkspaceTailnet.executable() }
        catch { throw PiBotHostError.tailscaleUnavailable }
    }

    public static func peers() throws -> [PiBotTailnetPeer] {
        let result = try RemoteWorkspaceProcess.run(executable: try executable(), arguments: ["status", "--json"], timeLimit: 10)
        guard result.status == 0 else { throw PiBotHostError.tailscaleUnavailable }
        return try decode(result.data)
    }

    public static func decode(_ data: Data) throws -> [PiBotTailnetPeer] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["BackendState"] as? String == "Running" else { throw PiBotHostError.tailscaleUnavailable }
        let localDNS = dnsName(of: root["Self"] as? [String: Any] ?? [:])
        let peers = root["Peer"] as? [String: Any] ?? [:]
        return peers.compactMap { key, value -> PiBotTailnetPeer? in
            guard let peer = value as? [String: Any], peer["Expired"] as? Bool != true,
                  let system = system(of: peer) else { return nil }
            let dns = dnsName(of: peer)
            guard dns.isEmpty || dns != localDNS,
                  let address = (peer["TailscaleIPs"] as? [String])?.first(where: isTailnetAddress) else { return nil }
            let fallback = dns.isEmpty ? address : dns
            let reported = (peer["HostName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let safe = !reported.isEmpty && reported.utf8.count <= 120
                && !reported.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }
            return PiBotTailnetPeer(id: key, name: safe ? reported : fallback, dnsName: dns, address: address,
                                    system: system, online: reachable(peer))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `Online` is what the coordination server last heard, which can lag or drop while
    /// the device still answers through a relay. A live tunnel proves it is reachable.
    private static func reachable(_ peer: [String: Any], now: Date = Date()) -> Bool {
        if peer["Online"] as? Bool == true { return true }
        guard peer["Active"] as? Bool == true, let text = peer["LastHandshake"] as? String else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let handshake = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { return false }
        return now.timeIntervalSince(handshake) < 300
    }

    private static func system(of peer: [String: Any]) -> PiBotTailnetPeer.System? {
        switch (peer["OS"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "macos", "darwin": .macOS
        case "linux": .linux
        default: nil
        }
    }

    private static func dnsName(of peer: [String: Any]) -> String {
        let value = (peer["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let valid = value.hasSuffix(".ts.net") && !value.contains("..") && value.utf8.count <= 253
            && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
        return valid ? value : ""
    }

    static func isTailnetAddress(_ value: String) -> Bool {
        if value.lowercased().hasPrefix("fd7a:115c:a1e0:"), value.allSatisfy({ $0.isHexDigit || $0 == ":" }) { return true }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let a = UInt8(parts[0]), let b = UInt8(parts[1]), UInt8(parts[2]) != nil, UInt8(parts[3]) != nil else { return false }
        return a == 100 && (64...127).contains(b)
    }

    /// Noninteractive, existing SSH credentials only, pinned to this peer through tailscaled.
    public static func sshArguments(peer: PiBotTailnetPeer, user: String, tailscale: String) throws -> [String] {
        let alias = peer.sshName
        guard !alias.isEmpty, alias.first != "-", alias.utf8.count <= 253,
              alias.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 58, 95].contains($0) }),
              user.isEmpty || (user.first != "-" && user.utf8.count <= 64
                  && user.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              isTailnetAddress(peer.address) else { throw PiBotHostError.invalidConnection }
        return ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "RequestTTY=no",
                "-o", "ProxyCommand=exec \(RemoteWorkspaceExecTarget.quote(tailscale)) nc \(peer.address) %p", "-o", "ProxyJump=none",
                "-o", "Hostname=\(peer.address)", "-o", "HostKeyAlias=\(peer.address)", "-o", "StrictHostKeyChecking=yes",
                "-o", "CanonicalizeHostname=no", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no",
                "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no",
                "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-o", "NumberOfPasswordPrompts=0",
                user.isEmpty ? alias : user + "@" + alias]
    }

    /// Refresh membership before each SSH use. A stale address is never reused.
    static func current(_ peer: PiBotTailnetPeer) throws -> PiBotTailnetPeer {
        guard let found = try peers().first(where: { $0.id == peer.id }), found.online else {
            throw PiBotHostError.peerOffline(peer.name)
        }
        return found
    }
}

/// Runs `pi-bot-host.sh` on this Mac or over Tailnet SSH.
public struct PiBotHostRunner: Sendable {
    public let instance: String
    /// `<application support>/PiBot` for this Mac. Remote roots are the script's defaults.
    public let localRoot: URL
    private static let installTimeLimit: TimeInterval = 20 * 60
    private static let commandTimeLimit: TimeInterval = 120
    /// Inspection answers the window directly, within one backend RPC.
    private static let inspectTimeLimit: TimeInterval = 25

    public init(instance: String, localRoot: URL) {
        self.instance = instance
        self.localRoot = localRoot
    }

    public func inspect(_ target: PiBotDeploymentTarget, script: Data) async throws -> PiBotHostInspection {
        try JSONDecoder().decode(PiBotHostInspection.self, from: try await run(target, script: script, command: ["inspect"], timeLimit: Self.inspectTimeLimit))
    }

    public func lifecycle(_ action: String, _ target: PiBotDeploymentTarget, script: Data) async throws {
        _ = try await run(target, script: script, command: [action])
    }

    public func uninstall(_ target: PiBotDeploymentTarget, deleteData: Bool, script: Data) async throws {
        _ = try await run(target, script: script, command: deleteData ? ["uninstall", "--delete-data"] : ["uninstall"])
    }

    private func baseArguments(_ target: PiBotDeploymentTarget) -> [String] {
        var arguments = ["--instance", instance]
        if target.kind == .thisMac { arguments += ["--root", localRoot.path] }
        return arguments
    }

    private func run(_ target: PiBotDeploymentTarget, script: Data, command: [String],
                     timeLimit: TimeInterval = PiBotHostRunner.commandTimeLimit) async throws -> Data {
        let verb = command[0], rest = Array(command.dropFirst())
        let arguments = [verb] + baseArguments(target) + rest
        return try await Self.cancellable { handle in
            switch target.kind {
            case .thisMac:
                let file = FileManager.default.temporaryDirectory.appending(path: "pi-bot-host-\(UUID().uuidString).sh")
                try script.write(to: file, options: [.atomic])
                defer { try? FileManager.default.removeItem(at: file) }
                return try Self.finish(RemoteWorkspaceProcess.run(executable: "/bin/bash", arguments: [file.path] + arguments, timeLimit: timeLimit, onProcessStarted: handle.started))
            case .tailnet:
                guard let peer = target.peer else { throw PiBotHostError.invalidConnection }
                let current = try PiBotTailnet.current(peer)
                let ssh = try PiBotTailnet.sshArguments(peer: current, user: target.sshUser, tailscale: PiBotTailnet.executable())
                let remote = "bash -s -- " + arguments.map(RemoteWorkspaceExecTarget.quote).joined(separator: " ")
                return try Self.finish(RemoteWorkspaceProcess.run(executable: "/usr/bin/ssh", arguments: ssh + [remote], input: script, timeLimit: timeLimit, onProcessStarted: handle.started))
            }
        }
    }

    /// The child process stops with the task, so a cancelled install cannot finish
    /// later and write its result over a newer deployment.
    private final class ProcessHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t?
        private var cancelled = false
        private var finished = false
        var started: @Sendable (pid_t) -> Void {
            { [self] value in
                let stop = lock.withLock { () -> Bool in pid = value; return cancelled }
                if stop { terminate(value) }
            }
        }
        func cancel() {
            let value = lock.withLock { () -> pid_t? in cancelled = true; return pid }
            if let value { terminate(value) }
        }
        private func terminate(_ value: pid_t) {
            kill(value, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [self] in
                if lock.withLock({ !finished }) { kill(value, SIGKILL) }
            }
        }
        func finish() { lock.withLock { finished = true } }
    }

    private static func cancellable(_ body: @escaping @Sendable (ProcessHandle) throws -> Data) async throws -> Data {
        let handle = ProcessHandle()
        let data = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                defer { handle.finish() }
                return try body(handle)
            }.value
        } onCancel: { handle.cancel() }
        try Task.checkCancellation()
        return data
    }

    public func install(_ target: PiBotDeploymentTarget, bundle: PiBotBundle, inspection: PiBotHostInspection,
                        service: Bool, port: Int?, progress: @escaping @Sendable (String) -> Void) async throws -> PiBotInstallResult {
        guard let checksum = bundle.selection.node.sha256[inspection.nodePlatform] else {
            throw PiBotHostError.command("Pi Bot does not support \(inspection.nodePlatform) yet.")
        }
        let report: @Sendable (Data) -> Void = { data in
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) where line.hasPrefix("WM_PROGRESS ") {
                progress(Self.progressMessage(String(line.dropFirst(12))))
            }
        }
        @Sendable func arguments(archive: String, tooling: String) -> [String] {
            var values = ["install"] + baseArguments(target) + [
                "--commit", bundle.selection.commit,
                "--node-version", bundle.selection.node.version, "--node-sha256", checksum,
                "--pnpm-version", bundle.selection.pnpm,
                "--bundle", archive, "--tooling-lock-dir", tooling,
                service ? "--service" : "--no-service",
            ]
            if let port { values += ["--port", String(port)] }
            if inspection.nodePlatform == "darwin-arm64", let container = bundle.selection.container {
                values += ["--container-version", container.version, "--container-sha256", container.sha256]
            }
            return values
        }
        let output: Data = try await Self.cancellable { handle in
            switch target.kind {
            case .thisMac:
                let values = arguments(archive: bundle.archive.path, tooling: bundle.tooling.path)
                return try Self.finish(RemoteWorkspaceProcess.run(executable: "/bin/bash", arguments: [bundle.script.path] + values,
                    timeLimit: Self.installTimeLimit, onProcessStarted: handle.started, onStandardError: report))
            case .tailnet:
                guard let peer = target.peer else { throw PiBotHostError.invalidConnection }
                let current = try PiBotTailnet.current(peer)
                let ssh = try PiBotTailnet.sshArguments(peer: current, user: target.sshUser, tailscale: PiBotTailnet.executable())
                progress("Uploading Pi Bot to \(current.name)…")
                let archive = try RemoteWorkspaceProcess.run(executable: "/usr/bin/tar", arguments: [
                    "--no-xattrs", "--no-mac-metadata", "-czf", "-",
                    "-C", bundle.directory.deletingLastPathComponent().path, bundle.directory.lastPathComponent,
                ], timeLimit: 60)
                guard archive.status == 0 else { throw PiBotHostError.command("Pi Bot could not be prepared for upload.") }
                let staged = try Self.finish(RemoteWorkspaceProcess.run(executable: "/usr/bin/ssh", arguments: ssh + [
                    "umask 077 && d=$(mktemp -d) && tar -xzf - -C \"$d\" && printf '%s' \"$d\"",
                ], input: archive.data, timeLimit: 300, onProcessStarted: handle.started))
                let directory = String(decoding: staged, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard directory.hasPrefix("/"), !directory.contains("\n") else { throw PiBotHostError.response("The device did not confirm the upload.") }
                let root = directory + "/" + bundle.directory.lastPathComponent
                let install = (["bash", root + "/pi-bot-host.sh"] + arguments(archive: root + "/pi-bot-bundle.tar.gz", tooling: root + "/tooling"))
                    .map(RemoteWorkspaceExecTarget.quote).joined(separator: " ")
                let remote = install + "; code=$?; rm -rf " + RemoteWorkspaceExecTarget.quote(directory) + "; exit $code"
                return try Self.finish(RemoteWorkspaceProcess.run(executable: "/usr/bin/ssh", arguments: ssh + [remote],
                    timeLimit: Self.installTimeLimit, onProcessStarted: handle.started, onStandardError: report))
            }
        }
        return try JSONDecoder().decode(PiBotInstallResult.self, from: output)
    }

    private static func finish(_ result: RemoteWorkspaceProcess.Result) throws -> Data {
        guard result.status == 0 else { throw PiBotHostError.command(failureMessage(result.output)) }
        return result.data
    }

    /// The script's failures are one JSON object; SSH's own are plain text.
    static func failureMessage(_ output: String) -> String {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard line.hasPrefix("{"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let detail = object["detail"] as? String else { continue }
            return detail
        }
        let lines = output.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("WM_PROGRESS ") }
        let text = lines.joined(separator: "\n")
        if text.contains("remote port forwarding failed") { return "remote port forwarding failed" }
        if text.contains("Host key verification failed") {
            return "This Mac has not trusted that device's SSH host key yet. Connect once from Terminal over Tailscale, then try again."
        }
        if text.contains("Permission denied") {
            return "SSH access was refused. Check that this Mac's SSH key works for that device, and set the SSH user if it differs."
        }
        if text.contains("Connection refused") || text.contains("Connection closed") {
            return "SSH is not available on that device. Turn on Remote Login or start sshd, then try again."
        }
        return text.isEmpty ? "The command did not complete on that device." : String(text.prefix(600))
    }

    static func progressMessage(_ phase: String) -> String {
        switch phase {
        case "staging": "Verifying Pi Bot…"
        case "node": "Installing the verified Node runtime…"
        case "container": "Installing Apple's container runtime…"
        case "dependencies": "Installing Pi Bot's dependencies. This can take a few minutes…"
        case "health": "Checking the new Pi Bot…"
        case "backup": "Backing up your bots' database…"
        case "activating", "caller-supervises": "Starting Pi Bot…"
        default: "Installing Pi Bot…"
        }
    }
}

/// The transport to a remote Pi Bot: one SSH command running `pi-bot-relay.mjs`, which
/// carries the UI and control socket to this Mac, and a loopback port on the device back
/// to this Mac's MCP endpoint. Like remote workspaces, it needs only SSH command execution,
/// so it works on servers that turn off port forwarding.
public actor PiBotTunnel {
    public struct Forward: Equatable, Sendable {
        public let localPort: Int
        public let remotePort: Int
        /// The device-side port to prefer; the relay reports the one it got.
        public let mcpRemotePort: Int?
        public let mcpLocalPort: Int?
        public init(localPort: Int, remotePort: Int, mcpRemotePort: Int? = nil, mcpLocalPort: Int? = nil) {
            self.localPort = localPort; self.remotePort = remotePort
            self.mcpRemotePort = mcpRemotePort; self.mcpLocalPort = mcpLocalPort
        }
    }

    private var relay: PiBotRelay?
    private var errorLog: URL?
    public init() {}

    public var isRunning: Bool { relay?.isRunning == true }

    /// Finds the Node that runs Pi Bot, because this has to work before anything else does.
    /// An attached server's Node is whichever one the account can reach.
    static let launcher = #"""
    instance="$1"; source="$2"; shift 2
    case "$(uname -s)" in
      Darwin) root="$HOME/Library/Application Support/Woven Matter Pi Bot/$instance" ;;
      *) root="$HOME/.local/share/wovenmatter/pi-bot/$instance" ;;
    esac
    node=""
    if [ -r "$root/current/.node-version" ]; then node="$root/node/$(cat "$root/current/.node-version")/bin/node"; fi
    if [ ! -x "$node" ]; then node="$(command -v node 2>/dev/null || true)"; fi
    if [ ! -x "$node" ]; then node="$(bash -lc 'command -v node' 2>/dev/null | tail -n 1 || true)"; fi
    if [ ! -x "$node" ]; then
      for candidate in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
        if [ -x "$candidate" ]; then node="$candidate"; break; fi
      done
    fi
    if [ ! -x "$node" ]; then echo 'No Node runtime was found on that device.' >&2; exit 69; fi
    exec "$node" --input-type=module -e "$source" -- "$@"
    """#

    static func remoteCommand(instance: String, relaySource: String, forward: Forward) -> String {
        var values = [instance, relaySource, String(forward.remotePort)]
        if forward.mcpLocalPort != nil { values.append(String(forward.mcpRemotePort ?? 0)) } else { values.append("none") }
        return "exec bash -c " + RemoteWorkspaceExecTarget.quote(launcher) + " -- "
            + values.map(RemoteWorkspaceExecTarget.quote).joined(separator: " ")
    }

    static func arguments(ssh: [String], remoteCommand: String) -> [String] {
        // The destination stays last in `ssh`; ssh accepts options before it only.
        Array(ssh.dropLast()) + ["-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", ssh[ssh.count - 1], remoteCommand]
    }

    public func start(peer: PiBotTailnetPeer, user: String, forward: Forward, instance: String, relaySource: String) throws {
        stop()
        let current = try PiBotTailnet.current(peer)
        let ssh = try PiBotTailnet.sshArguments(peer: current, user: user, tailscale: PiBotTailnet.executable())
        let log = FileManager.default.temporaryDirectory.appending(path: "pi-bot-tunnel-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let relay = PiBotRelay(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: Self.arguments(ssh: ssh, remoteCommand: Self.remoteCommand(instance: instance, relaySource: relaySource, forward: forward)),
            errorLog: try FileHandle(forWritingTo: log), localPort: forward.localPort, reverseTargetPort: forward.mcpLocalPort)
        errorLog = log
        try relay.start()
        self.relay = relay
    }

    /// The device-side MCP port, once the device is listening. Polls so that cancelling
    /// the caller never leaves it waiting on a device that does not answer.
    public func ready(seconds: Int = 30) async throws -> Int? {
        for _ in 0..<(seconds * 10) {
            try Task.checkCancellation()
            guard let relay else { break }
            if let hello = relay.hello { return hello.reversePort }
            if !relay.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PiBotHostError.command(failureDetail() ?? "The device did not answer.")
    }

    /// What SSH or the relay reported, once it has exited.
    public func failureDetail() -> String? {
        guard relay?.isRunning != true, let errorLog,
              let text = try? String(contentsOf: errorLog, encoding: .utf8) else { return nil }
        return PiBotHostRunner.failureMessage(text)
    }

    public func stop() {
        relay?.stop()
        relay = nil
        if let errorLog { try? FileManager.default.removeItem(at: errorLog) }
        errorLog = nil
    }
}

/// A free loopback TCP port, for a forward's local end.
public enum PiBotLoopback {
    public static func freePort(preferred: Int? = nil) -> Int? {
        if let preferred, bind(port: preferred) != nil { return preferred }
        return bind(port: 0)
    }

    private static func bind(port: Int) -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return named == 0 ? Int(in_port_t(bigEndian: address.sin_port)) : nil
    }
}

public enum PiBotHealthProbe {
    public static func check(_ baseURL: URL, timeout: TimeInterval = 2) async -> PiBotHealth? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: baseURL.appending(path: "health")),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try? JSONDecoder().decode(PiBotHealth.self, from: data), health.ok else { return nil }
        return health
    }
}
