import Foundation
import WovenMatterCore

/// Tailscale inventory is independent of whether Woven Matter is installed or running.
public struct CompanionTailnetMac: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let dnsName: String
    public let address: String
    public let online: Bool
    public var sshName: String { dnsName.split(separator: ".").first.map(String.init) ?? address }

    public static func decode(_ data: Data) throws -> [Self] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["BackendState"] as? String == "Running" else {
            throw CompanionAPIError(code: "tailscale_unavailable", message: "Connect Tailscale to find Macs on your network.")
        }
        let local = root["Self"] as? [String: Any] ?? [:]
        let peers = root["Peer"] as? [String: Any] ?? [:]
        return peers.compactMap { key, value in
            guard let peer = value as? [String: Any], peer["Expired"] as? Bool != true,
                  ["macos", "darwin"].contains((peer["OS"] as? String ?? "").lowercased()) else { return nil }
            let rawDNS = peer["DNSName"] as? String ?? ""
            let dns = rawDNS.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let localDNS = (local["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            guard dns.isEmpty || dns != localDNS,
                  let address = (peer["TailscaleIPs"] as? [String])?.first(where: Self.isTailnetAddress) else { return nil }
            let safeDNS = dns.hasSuffix(".ts.net") && !dns.contains("..") && dns.utf8.count <= 253 &&
                dns.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) ? dns : ""
            let fallback = safeDNS.isEmpty ? address : safeDNS
            let name = peer["HostName"] as? String ?? fallback
            let safeName = name.isEmpty || name.utf8.count > 120 || name.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) ? fallback : name
            return Self(id: key, name: safeName, dnsName: safeDNS, address: address, online: peer["Online"] as? Bool == true)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isTailnetAddress(_ value: String) -> Bool {
        if value.lowercased().hasPrefix("fd7a:115c:a1e0:"), value.allSatisfy({ $0.isHexDigit || $0 == ":" }) { return true }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let a = UInt8(parts[0]), let b = UInt8(parts[1]), UInt8(parts[2]) != nil, UInt8(parts[3]) != nil else { return false }
        return a == 100 && (64...127).contains(b)
    }
}

public struct CompanionMacInstallation: Equatable, Sendable {
    public let installed: Bool
    public let version: String?
    public let build: Int?
    public let supportsSetup: Bool
    public let running: Bool
    public let architecture: String
    public let macOSVersion: String
    public let setupStatus: String?
    public let deviceID: String?

    public init(data: Data) throws {
        let fields = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        guard fields.count >= 9, fields[0] == "woven-mac-inspection-v1",
              ["installed", "missing"].contains(fields[1]),
              fields.prefix(9).allSatisfy({ $0.utf8.count <= 512 && !$0.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) }) else {
            throw CompanionAPIError(code: "invalid_response", message: "This Mac returned invalid installation details.")
        }
        installed = fields[1] == "installed"; version = fields[2].isEmpty ? nil : fields[2]
        build = Int(fields[3]); supportsSetup = fields[4] == "1"; running = fields[5] == "1"
        architecture = fields[6]; macOSVersion = fields[7]; setupStatus = fields[8].isEmpty ? nil : fields[8]
        deviceID = fields.count > 9 && UUID(uuidString: fields[9]) != nil ? fields[9] : nil
    }
}

public struct CompanionMacRelease: Decodable, Equatable, Sendable {
    public let version: String
    public let build: Int
    public let architecture: String
    public let minimumMacOS: String
    public let downloadURL: URL
    public let sha256: String
    enum CodingKeys: String, CodingKey { case version, build, architecture, minimumMacOS = "minimum_macos", downloadURL = "download_url", sha256 }

    public func validate() throws {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }), build > 0,
              architecture == "arm64", !minimumMacOS.isEmpty, minimumMacOS.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ Int($0) != nil }),
              downloadURL.absoluteString == "https://github.com/wovenmatter/wovenmatter/releases/download/v\(version)/WovenMatter_\(version)_arm64.dmg",
              sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else {
            throw CompanionAPIError(code: "invalid_release", message: "The release has invalid download or verification details.")
        }
    }
    public func isNewer(than installation: CompanionMacInstallation) -> Bool {
        guard let current = installation.version else { return true }
        let comparison = version.compare(current, options: .numeric)
        return comparison == .orderedDescending || (comparison == .orderedSame && build > (installation.build ?? 0))
    }
}
