import Foundation

public struct PairingPayload: Codable, Equatable, Sendable {
  public static let currentProtocolVersion = LibraryProtocol.version
  public let endpoint: URL
  public let token: String
  public let protocolVersion: Int

  public init(endpoint: URL, token: String, protocolVersion: Int = LibraryProtocol.version) throws {
    guard Self.isValidEndpoint(endpoint), (32...256).contains(token.utf8.count),
          protocolVersion == Self.currentProtocolVersion else {
      throw LibraryAPIError(code: "invalid_pairing", message: "Use a current pairing code from Woven Matter Settings on your Mac.")
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

  /// An execution workspace's address: `/wovenmatter`, or for a Linux host also its
  /// per-workspace `/wovenmatter-execution/<id>` route. Same tailnet HTTPS rules.
  public static func isValidExecutionEndpoint(_ url: URL, linux: Bool) -> Bool {
    if isValidEndpoint(url) { return true }
    guard linux else { return false }
    guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false),
          value.scheme == "https", let host = value.host?.lowercased(),
          host.hasSuffix(".ts.net"), host.count > 7,
          value.user == nil, value.password == nil, value.query == nil, value.fragment == nil else { return false }
    let prefix = "/wovenmatter-execution/"
    guard value.path.hasPrefix(prefix) else { return false }
    let id = value.path.dropFirst(prefix.count)
    guard (1...64).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }),
          id != ".", id != ".." else { return false }
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
      throw LibraryAPIError(code: "invalid_pairing", message: "This is not a Woven Matter pairing code.")
    }
    return try Self(endpoint: endpoint, token: token, protocolVersion: version)
  }
}

public enum PairingPurpose {
  public static let peerMac = "library.peers.v2"
}

public struct PairRequest: Codable, Equatable, Sendable {
  public let token: String
  public let deviceID: String
  public let deviceName: String
  public let metadata: DeviceMetadata?
  public let protocolVersion: Int
  public let expectedWorkspaceID: String?
  public let requiresConfirmation: Bool?
  /// Explicit pairing purpose. Only `PairingPurpose.peerMac` can
  /// become a paired-Mac grant; device metadata never selects that role.
  public let purpose: String?
  /// The device's raw 32-byte Ed25519 member key. When present, the Mac
  /// that accepts the pairing signs a member entry for it, so the device
  /// then signs its requests to every Mac and Linux member.
  public var memberPublicKey: Data? = nil
  public init(token: String, deviceID: String, deviceName: String, protocolVersion: Int = LibraryProtocol.version,
              metadata: DeviceMetadata? = nil, expectedWorkspaceID: String? = nil, requiresConfirmation: Bool? = nil,
              purpose: String? = nil) {
    self.token = token; self.deviceID = deviceID; self.deviceName = deviceName
    self.protocolVersion = protocolVersion; self.metadata = metadata
    self.expectedWorkspaceID = expectedWorkspaceID; self.requiresConfirmation = requiresConfirmation; self.purpose = purpose
  }
}

public struct PairingPreview: Codable, Equatable, Sendable {
  public let workspaceID: String
  public init(workspaceID: String) { self.workspaceID = workspaceID }
}

public struct PairResponse: Codable, Equatable, Sendable {
  public let workspaceID: String
  public let deviceID: String
  public let credential: String
  public let protocolVersion: Int
  public let confirmationRequired: Bool?
  /// The pairing Mac's member device ID: the audience of the phone's signed
  /// requests to it. Absent from Macs that predate member requests.
  public var hostDeviceID: String?
  /// The libraries in the pairing Mac's workspace registry, for a phone that
  /// sent a member key: a phone already holding one of them keeps its copy.
  public var libraryIDs: [String]?
  public init(workspaceID: String, deviceID: String, credential: String, protocolVersion: Int = LibraryProtocol.version,
              confirmationRequired: Bool? = nil, hostDeviceID: String? = nil) {
    self.workspaceID = workspaceID; self.deviceID = deviceID; self.credential = credential; self.protocolVersion = protocolVersion
    self.confirmationRequired = confirmationRequired; self.hostDeviceID = hostDeviceID
  }
}

public struct LibraryAPIError: Codable, Equatable, Sendable, Error, LocalizedError {
  public let code: String
  public let message: String
  public init(code: String, message: String) { self.code = code; self.message = message }
  public var errorDescription: String? { message }
}

public struct LibraryHello: Codable, Equatable, Sendable {
  public let workspaceID: String
  public let protocolVersion: Int
  public let hostName: String
  public let capabilities: [String]
  public init(workspaceID: String, protocolVersion: Int = LibraryProtocol.version, hostName: String, capabilities: [String]) {
    self.workspaceID = workspaceID; self.protocolVersion = protocolVersion
    self.hostName = hostName; self.capabilities = capabilities
  }
}
