import Foundation
import WovenMatterCore

private final class PairingRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Exact private HTTPS routes only. No redirects, cookies, credential forwarding,
/// response cache or unbounded response body is permitted during discovery.
public final class CompanionPairingNetwork: @unchecked Sendable {
  private let session: URLSession
  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 3; configuration.timeoutIntervalForResource = 5
    session = URLSession(configuration: configuration, delegate: PairingRedirectPolicy(), delegateQueue: nil)
  }
  public func request<T: Decodable & Sendable>(_ endpoint: URL, path: String, body: Data? = nil) async throws -> T {
    guard CompanionPairingPayload.isValidEndpoint(endpoint),
          ["v1/discovery", "v1/pair", "v1/pairing/request", "v1/pairing/result", "v1/pairing/invite", "v1/pairing/cancel"].contains(path) else {
      throw CompanionAPIError(code: "invalid_endpoint", message: "Use a Woven Matter Tailscale HTTPS endpoint.")
    }
    var request = URLRequest(url: endpoint.appending(path: path))
    request.httpMethod = body == nil ? "GET" : "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(String(CompanionProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw invalidResponse }
    guard response.expectedContentLength <= 65_536 else { throw invalidResponse }
    var data = Data()
    for try await byte in bytes { guard data.count < 65_536 else { throw invalidResponse }; data.append(byte) }
    guard response.statusCode == 200 else {
      if let error = try? JSONDecoder().decode(CompanionAPIError.self, from: data) { throw error }
      throw CompanionAPIError(code: "pairing_unavailable", message: "This Mac is not currently available for pairing.")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
  private var invalidResponse: CompanionAPIError { .init(code: "invalid_response", message: "The Mac returned an invalid pairing response.") }
}

public struct CompanionMacDiscovery: Sendable {
  public static let ports = [8443, 10_000, 8444, 8445]
  private let status: @Sendable () async throws -> Data
  private let probe: @Sendable (URL) async throws -> CompanionDiscoveryAdvertisement
  public init(status: (@Sendable () async throws -> Data)? = nil,
              probe: (@Sendable (URL) async throws -> CompanionDiscoveryAdvertisement)? = nil) {
    self.status = status ?? {
      guard let path = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        .first(where: FileManager.default.isExecutableFile(atPath:)) else {
        throw CompanionAPIError(code: "tailscale_unavailable", message: "Connect Tailscale to discover your Macs.")
      }
      return try await CompanionProcessProbe().run(executable: URL(fileURLWithPath: path), arguments: ["status", "--json"])
    }
    let network = CompanionPairingNetwork()
    self.probe = probe ?? { try await network.request($0, path: "v1/discovery") }
  }
  public static func candidates(status data: Data) throws -> [URL] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["BackendState"] as? String == "Running",
          let peers = root["Peer"] as? [String: Any] else {
      throw CompanionAPIError(code: "tailscale_unavailable", message: "Connect Tailscale to discover your Macs.")
    }
    var hosts = Set<String>()
    for value in peers.values {
      guard let peer = value as? [String: Any], peer["Online"] as? Bool == true,
            ["macos", "darwin"].contains((peer["OS"] as? String ?? "").lowercased()),
            let raw = peer["DNSName"] as? String else { continue }
      let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
      guard host.hasSuffix(".ts.net"), host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { continue }
      hosts.insert(host)
    }
    return hosts.sorted().flatMap { host in Self.ports.compactMap { URL(string: "https://\(host):\($0)/wovenmatter") } }
  }
  public func discover() async throws -> [CompanionDiscoveredPeer] {
    let candidates = try Self.candidates(status: await status())
    var result: [CompanionDiscoveredPeer] = []
    // Bound network concurrency without scanning addresses or arbitrary ports.
    for offset in stride(from: 0, to: candidates.count, by: 8) {
      try Task.checkCancellation()
      let batch = candidates[offset..<min(offset + 8, candidates.count)]
      result += await withTaskGroup(of: CompanionDiscoveredPeer?.self) { group in
        for endpoint in batch {
          group.addTask {
            guard let advertisement = try? await probe(endpoint), advertisement.protocolVersion == CompanionProtocol.version,
                  UUID(uuidString: advertisement.identity.deviceID) != nil,
                  advertisement.identity.metadata.kind == .mac,
                  !advertisement.identity.deviceName.isEmpty, advertisement.identity.deviceName.utf8.count <= 120,
                  [advertisement.identity.deviceName, advertisement.identity.metadata.osVersion, advertisement.identity.metadata.appVersion].compactMap({ $0 }).allSatisfy({ value in
                      value.utf8.count <= 120 && !value.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }
                  }) else { return nil }
            return .init(endpoint: endpoint, advertisement: advertisement)
          }
        }
        var peers: [CompanionDiscoveredPeer] = []
        for await peer in group { if let peer { peers.append(peer) } }
        return peers
      }
    }
    return result.sorted { $0.advertisement.identity.deviceName.localizedStandardCompare($1.advertisement.identity.deviceName) == .orderedAscending }
  }
}
