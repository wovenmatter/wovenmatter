import Foundation

/// The only network transport for remote workspace SSH, including stdio agents,
/// attachments, lifecycle commands, and port forwarding. Never consult DNS or an
/// SSH alias to choose a transport address: select a peer from tailscaled itself.
public enum RemoteWorkspaceTailnet {
    /// Tailscale's app-bundle binary is both its GUI and its CLI. It acts as the
    /// CLI only when it finds a shell's environment (such as `TERM` or `SHLVL`)
    /// or this variable, which Tailscale documents for scripts. An app opened
    /// from Finder or launchd has none of them: the binary then prints "The
    /// Tailscale GUI failed to start" and exits 0. Call once at process start,
    /// before the app starts any thread or child, so every child inherits it.
    public static func selectCommandLineInterface() {
        setenv("TAILSCALE_BE_CLI", "1", 1)
    }

    /// The object `status --json` printed, or nil when Tailscale printed something else.
    public static func statusObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// What each node is called on the tailnet as people read it (`HostName`, such
    /// as "James's Mac mini"), by its DNS name, and this Mac's (`Self`).
    public struct HostNames: Sendable, Equatable {
        public var this: String?
        public var byDNSName: [String: String] = [:]
        public init(this: String? = nil, byDNSName: [String: String] = [:]) { self.this = this; self.byDNSName = byDNSName }
        /// The host name of the node whose DNS name is `host` (`name.tailnet.ts.net`).
        public func name(forHost host: String?) -> String? {
            host.flatMap { byDNSName[$0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))] }
        }
    }
    public static func hostNames(status: Data) -> HostNames {
        guard let root = statusObject(status) else { return .init() }
        func entry(_ node: [String: Any]?) -> (String, String)? {
            guard let name = (node?["HostName"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let dns = (node?["DNSName"] as? String)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return nil }
            return (dns, name)
        }
        var names = HostNames(this: entry(root["Self"] as? [String: Any])?.1)
        for node in [root["Self"]] + ((root["Peer"] as? [String: Any]) ?? [:]).values.map({ Optional($0) }) {
            if let (dns, name) = entry(node as? [String: Any]) { names.byDNSName[dns] = name }
        }
        return names
    }
    /// This Mac's view of the tailnet's host names; empty when Tailscale is unavailable.
    public static func hostNames() -> HostNames {
        guard let path = try? executable(),
              let result = try? RemoteWorkspaceProcess.run(executable: path, arguments: ["status", "--json"], timeLimit: 10),
              result.status == 0 else { return .init() }
        return hostNames(status: result.data)
    }

    /// Tailscale answered, but not with its status. Not the same as disconnected.
    public static let statusUnreadable = "Tailscale did not report its status. Check that Tailscale is running and up to date, then try again."

    static func executable() throws -> String {
        guard let path = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw RemoteWorkspaceClientError.commandFailed("Install and connect Tailscale before using remote workspaces.")
        }
        return path
    }

    public static func sshOptions(destination: String) throws -> [String] {
        let path = try executable()
        let result = try RemoteWorkspaceProcess.run(executable: path, arguments: ["status", "--json"], timeLimit: 10)
        guard result.status == 0 else {
            throw RemoteWorkspaceClientError.commandFailed("Tailscale status is unavailable. Connect Tailscale before using remote workspaces.")
        }
        return try sshOptions(destination: destination, executable: path, status: result.data)
    }

    static func sshOptions(destination: String, executable: String, status: Data) throws -> [String] {
        let host = String(destination.split(separator: "@").last ?? "").lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let root = statusObject(status) else { throw RemoteWorkspaceClientError.commandFailed(statusUnreadable) }
        guard root["BackendState"] as? String == "Running",
              let peers = root["Peer"] as? [String: Any] else {
            throw RemoteWorkspaceClientError.commandFailed("Connect Tailscale before using remote workspaces.")
        }
        let matches = peers.values.compactMap { $0 as? [String: Any] }.filter { peer in
            let names = [peer["HostName"] as? String, peer["DNSName"] as? String].compactMap { $0 }
                .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            return names.contains(host) || (peer["TailscaleIPs"] as? [String] ?? []).contains(host)
        }
        guard matches.count == 1, let peer = matches.first, peer["Online"] as? Bool == true,
              peer["Expired"] as? Bool != true,
              let address = (peer["TailscaleIPs"] as? [String])?.first(where: isTailnetAddress) else {
            throw RemoteWorkspaceClientError.commandFailed("Select an online Tailscale machine by its Tailnet name or Tailscale IP address.")
        }
        guard isLinuxPeer(peer) else {
            throw RemoteWorkspaceClientError.commandFailed("Remote workspaces require a Linux machine. Use Apple Devices to connect Macs, iPhones, and iPads.")
        }
        // Explicit options override ~/.ssh/config transport redirects and prevent
        // reuse of an existing multiplexed connection established outside Tailscale.
        // nc uses tailscaled's DialTCP, so losing Tailscale cannot fall back to LAN.
        return [
            "-o", "ProxyCommand=exec \(RemoteWorkspaceExecTarget.quote(executable)) nc \(address) %p",
            "-o", "ProxyJump=none", "-o", "Hostname=\(address)",
            "-o", "CanonicalizeHostname=no", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "ControlPersist=no", "-o", "Compression=no", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
            "-o", "PermitLocalCommand=no", "-o", "StrictHostKeyChecking=yes",
        ]
    }

    static func isLinuxPeer(_ peer: [String: Any]) -> Bool {
        (peer["OS"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "linux"
    }

    private static func isTailnetAddress(_ value: String) -> Bool {
        if value.lowercased().hasPrefix("fd7a:115c:a1e0:"),
           value.allSatisfy({ $0.isHexDigit || $0 == ":" }) { return true }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let a = UInt8(parts[0]), let b = UInt8(parts[1]), UInt8(parts[2]) != nil, UInt8(parts[3]) != nil else { return false }
        return a == 100 && (64...127).contains(b)
    }
}
