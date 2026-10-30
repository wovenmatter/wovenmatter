import Foundation
import WovenMatterCore

public struct CompanionMacSSHConnection: Sendable {
    public var alias: String
    public var user: String
    public init(alias: String, user: String = "") { self.alias = alias; self.user = user }
}

/// Existing, noninteractive SSH credentials only. Every connection is pinned to
/// the current Tailscale peer, irrespective of SSH config DNS or proxy redirects.
public struct CompanionMacManagement: Sendable {
    public typealias Run = @Sendable (URL, [String], TimeInterval) async throws -> Data
    private let run: Run
    private let executableOverride: URL?
    public init(executable: URL? = nil, run: Run? = nil) {
        executableOverride = executable
        self.run = run ?? { try await CompanionProcessProbe().run(executable: $0, arguments: $1, maximumBytes: $0.lastPathComponent == "ssh" ? 65_536 : 2_097_152, timeout: $2) }
    }
    private static func tailscale() throws -> URL {
        guard let path = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw CompanionAPIError(code: "tailscale_unavailable", message: "Install and connect Tailscale to find your Macs.")
        }
        return URL(fileURLWithPath: path)
    }
    public func inventory() async throws -> [CompanionTailnetMac] {
        try await CompanionTailnetMac.decode(run(executableOverride ?? Self.tailscale(), ["status", "--json"], 10))
    }
    public func inspect(_ mac: CompanionTailnetMac, connection: CompanionMacSSHConnection) async throws -> CompanionMacInstallation {
        try await CompanionMacInstallation(data: execute(mac, connection: connection, script: CompanionMacRemoteScripts.inspect))
    }
    public func install(_ mac: CompanionTailnetMac, connection: CompanionMacSSHConnection, release: CompanionMacRelease, requirePairingSupport: Bool = false) async throws {
        try release.validate()
        guard !requirePairingSupport || release.supportsRemoteSetup else {
            throw CompanionAPIError(code: "setup_unavailable", message: "This published release does not support pairing from another Mac yet. Update or download it separately, then pair in Apple Devices on that Mac.")
        }
        _ = try await execute(mac, connection: connection, script: CompanionMacRemoteScripts.install,
            arguments: [release.downloadURL.absoluteString, release.sha256, release.version, String(release.build), try CompanionMacSetupRequest(action: .update).json(), release.minimumMacOS, requirePairingSupport ? "1" : "0"], timeout: 600)
    }
    @discardableResult public func requestPairing(_ mac: CompanionTailnetMac, connection: CompanionMacSSHConnection, central: URL) async throws -> UUID {
        guard CompanionPairingPayload.isValidEndpoint(central) else {
            throw CompanionAPIError(code: "invalid_endpoint", message: "The central database is not ready for pairing.")
        }
        let request = CompanionMacSetupRequest(action: .pair, endpoint: central)
        _ = try await execute(mac, connection: connection, script: CompanionMacRemoteScripts.pair, arguments: [try request.json()])
        return request.id
    }
    public func open(_ mac: CompanionTailnetMac, connection: CompanionMacSSHConnection) async throws {
        _ = try await execute(mac, connection: connection, script: CompanionMacRemoteScripts.open)
    }
    public func latestRelease() async throws -> CompanionMacRelease {
        let url = URL(string: "https://github.com/wovenmatter/wovenmatter/releases/latest/download/latest-mac.json")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 30
        let (bytes, response) = try await URLSession(configuration: configuration).bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= 65_536 else {
            throw CompanionAPIError(code: "release_unavailable", message: "Could not check the latest Woven Matter version. Try again.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65_536 else { throw CompanionAPIError(code: "invalid_release", message: "The release details are too large.") }
            data.append(byte)
        }
        let release = try JSONDecoder().decode(CompanionMacRelease.self, from: data)
        try release.validate()
        return release
    }
    private func execute(_ mac: CompanionTailnetMac, connection: CompanionMacSSHConnection, script: String, arguments: [String] = [], timeout: TimeInterval = 15) async throws -> Data {
        // Refresh membership before each read or mutation. Never use a stale address.
        guard let current = try await inventory().first(where: { $0.id == mac.id && $0.dnsName == mac.dnsName }), current.online else {
            throw CompanionAPIError(code: "mac_offline", message: "This Mac is offline. Connect it to Tailscale and try again.")
        }
        let executable = try executableOverride ?? Self.tailscale()
        let options = try Self.sshArguments(mac: current, connection: connection, tailscale: executable.path)
        let data: Data
        do {
            data = try await run(URL(fileURLWithPath: "/usr/bin/ssh"), options + ["/bin/bash -c " + Self.quote(script) + " -- " + arguments.map(Self.quote).joined(separator: " ")], timeout)
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw CompanionAPIError(code: "mac_management_failed", message: "The action on \(mac.name) did not complete. Check its existing SSH connection over Tailscale and try again.")
        }
        let message = String(decoding: data, as: UTF8.self)
        if message.hasPrefix("woven-error:") {
            throw CompanionAPIError(code: "mac_management_failed", message: String(message.dropFirst(12)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func sshArguments(mac: CompanionTailnetMac, connection: CompanionMacSSHConnection, tailscale: String) throws -> [String] {
        let alias = connection.alias.isEmpty ? mac.sshName : connection.alias
        guard !alias.isEmpty, alias.utf8.count <= 253, alias.first != "-", !alias.contains(".."),
              alias.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 58, 95].contains($0) }),
              connection.user.isEmpty || (connection.user.first != "-" && connection.user.utf8.count <= 64 && connection.user.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) })),
              CompanionTailnetMac.isTailnetAddress(mac.address) else {
            throw CompanionAPIError(code: "invalid_ssh", message: "Enter a valid SSH host alias and optional user name.")
        }
        return ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "RequestTTY=no",
            "-o", "ProxyCommand=exec \(quote(tailscale)) nc \(mac.address) %p", "-o", "ProxyJump=none",
            "-o", "Hostname=\(mac.address)", "-o", "HostKeyAlias=\(mac.address)", "-o", "StrictHostKeyChecking=yes",
            "-o", "CanonicalizeHostname=no", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no",
            "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no",
            "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-o", "NumberOfPasswordPrompts=0",
            connection.user.isEmpty ? alias : connection.user + "@" + alias]
    }
}
