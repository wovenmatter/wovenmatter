import Foundation

public struct CompanionPairingPayload: Codable, Equatable, Sendable {
  public static let currentProtocolVersion = CompanionProtocol.version
  public let endpoint: URL
  public let token: String
  public let protocolVersion: Int

  public init(endpoint: URL, token: String, protocolVersion: Int = CompanionProtocol.version) throws {
    guard Self.isValidEndpoint(endpoint), (32...256).contains(token.utf8.count),
          protocolVersion == Self.currentProtocolVersion else {
      throw CompanionAPIError(code: "invalid_pairing", message: "Use a current pairing code from Woven Matter Settings on your Mac.")
    }
    self.endpoint = endpoint
    self.token = token
    self.protocolVersion = protocolVersion
  }

  public static func isValidEndpoint(_ url: URL) -> Bool {
    guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
          value.scheme == "https", let host = value.host?.lowercased(),
          host.hasSuffix(".ts.net"), host.count > 7,
          value.user == nil, value.password == nil, value.query == nil,
          value.fragment == nil, value.path == "/wovenmatter" else { return false }
    return value.port == nil || (1...65535).contains(value.port!)
  }

  public var encodedURL: URL {
    var value = URLComponents()
    value.scheme = "wovenmatter"
    value.host = "pair"
    value.queryItems = [URLQueryItem(name: "endpoint", value: endpoint.absoluteString),
                        URLQueryItem(name: "token", value: token),
                        URLQueryItem(name: "version", value: String(protocolVersion))]
    return value.url!
  }

  public static func parseURL(_ url: URL) throws -> Self {
    guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
          value.scheme == "wovenmatter", value.host == "pair", value.path.isEmpty,
          value.user == nil, value.password == nil, value.fragment == nil,
          let items = value.queryItems,
          Set(items.map(\.name)).count == items.count,
          let endpointText = items.first(where: { $0.name == "endpoint" })?.value,
          let endpoint = URL(string: endpointText),
          let token = items.first(where: { $0.name == "token" })?.value,
          let versionText = items.first(where: { $0.name == "version" })?.value,
          let version = Int(versionText) else {
      throw CompanionAPIError(code: "invalid_pairing", message: "This is not a Woven Matter pairing code.")
    }
    return try Self(endpoint: endpoint, token: token, protocolVersion: version)
  }
}

public enum CompanionPairingPurpose {
  public static let peerMac = "library.peers.v2"
}

public struct CompanionPairRequest: Codable, Equatable, Sendable {
  public let token: String
  public let deviceID: String
  public let deviceName: String
  public let metadata: CompanionDeviceMetadata?
  public let protocolVersion: Int
  public let expectedWorkspaceID: String?
  public let requiresConfirmation: Bool?
  /// Explicit pairing purpose. Only `CompanionPairingPurpose.peerMac` can
  /// become a paired-Mac grant; device metadata never selects that role.
  public let purpose: String?
  public init(token: String, deviceID: String, deviceName: String, protocolVersion: Int = CompanionProtocol.version,
              metadata: CompanionDeviceMetadata? = nil, expectedWorkspaceID: String? = nil, requiresConfirmation: Bool? = nil,
              purpose: String? = nil) {
    self.token = token; self.deviceID = deviceID; self.deviceName = deviceName
    self.protocolVersion = protocolVersion; self.metadata = metadata
    self.expectedWorkspaceID = expectedWorkspaceID; self.requiresConfirmation = requiresConfirmation; self.purpose = purpose
  }
}

public struct CompanionPairingPreview: Codable, Equatable, Sendable {
  public let workspaceID: String
  public init(workspaceID: String) { self.workspaceID = workspaceID }
}

public struct CompanionPairResponse: Codable, Equatable, Sendable {
  public let workspaceID: String
  public let deviceID: String
  public let credential: String
  public let protocolVersion: Int
  public let confirmationRequired: Bool?
  public init(workspaceID: String, deviceID: String, credential: String, protocolVersion: Int = CompanionProtocol.version,
              confirmationRequired: Bool? = nil) {
    self.workspaceID = workspaceID; self.deviceID = deviceID; self.credential = credential; self.protocolVersion = protocolVersion
    self.confirmationRequired = confirmationRequired
  }
}

public struct CompanionAPIError: Codable, Equatable, Sendable, Error, LocalizedError {
  public let code: String
  public let message: String
  public init(code: String, message: String) { self.code = code; self.message = message }
  public var errorDescription: String? { message }
}

public struct CompanionHello: Codable, Equatable, Sendable {
  public let workspaceID: String
  public let protocolVersion: Int
  public let hostName: String
  public let capabilities: [String]
  public init(workspaceID: String, protocolVersion: Int = CompanionProtocol.version, hostName: String, capabilities: [String]) {
    self.workspaceID = workspaceID; self.protocolVersion = protocolVersion
    self.hostName = hostName; self.capabilities = capabilities
  }
}
