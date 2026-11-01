import Foundation

/// A third party that receives Quick Chat content. Permission is scoped to the
/// service, provider and the exact origin that receives the request, so a new
/// endpoint or provider needs a new decision while account or model edits on the
/// same endpoint do not ask again.
public struct DataSharingDestination: Codable, Hashable, Sendable, Identifiable {
  public enum Service: String, Codable, Sendable { case inference, webSearch }
  public var service: Service
  public var provider: String
  public var origin: String
  public var id: String { [service.rawValue, provider, origin].joined(separator: "|") }
  public init(service: Service, provider: String, origin: String) {
    self.service = service; self.provider = provider; self.origin = origin
  }
  public static let exa = DataSharingDestination(service: .webSearch, provider: "exa", origin: "https://api.exa.ai")

  /// Lowercased scheme, host and explicit port; paths and credentials never enter the scope.
  public static func origin(of url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
    let name = host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
    return scheme + "://" + name + (url.port.map { ":\($0)" } ?? "")
  }

  /// The endpoint that receives prompts, history, referenced notes and tool output for a connection.
  public static func inference(_ connection: InferenceConnection, model: InferenceModel?) -> DataSharingDestination? {
    let address: String?
    if connection.route == .adapter || connection.provider.hasPrefix("local-server-") { address = connection.baseURL }
    // Each cloud provider's reviewed endpoints share one origin.
    else { address = (model ?? connection.selectedModel)?.baseUrl ?? InferenceModelPolicy.endpoints[connection.provider]?.values.sorted().first }
    guard let address, let url = URL(string: address), let origin = origin(of: url) else { return nil }
    return .init(service: .inference, provider: connection.provider, origin: origin)
  }

  public var recipientName: String {
    if service == .webSearch { return "Exa" }
    if provider.hasPrefix("local-server-") { return "your Tailscale model server" }
    return InferenceCatalog.providers.first { $0.id == provider }?.name ?? provider
  }
  public var sharedData: String {
    switch service {
    case .inference:
      "Your messages, this conversation’s history, notes you reference or Quick Chat reads, web results and other tool output, and the instructions for this chat."
    case .webSearch:
      "Search queries and webpage addresses chosen during Quick Chat. Exa retrieves those pages and returns their text to this device."
    }
  }
}

public struct DataSharingGrant: Codable, Equatable, Sendable {
  public var destination: DataSharingDestination
  public var disclosureVersion: Int
  public var grantedAt: String
  public init(destination: DataSharingDestination, disclosureVersion: Int, grantedAt: String) {
    self.destination = destination; self.disclosureVersion = disclosureVersion; self.grantedAt = grantedAt
  }
}

/// Durable decisions saved on this device only. Absence means no permission;
/// existing accounts from earlier builds start without a grant.
public struct DataSharingPermissions: Codable, Equatable, Sendable {
  /// Raise when the disclosed categories of shared data change so users decide again.
  public static let disclosureVersion = 1
  public var grants: [DataSharingGrant] = []
  public init(grants: [DataSharingGrant] = []) { self.grants = grants }
  public func permits(_ destination: DataSharingDestination) -> Bool {
    grants.contains { $0.destination == destination && $0.disclosureVersion == Self.disclosureVersion }
  }
  public mutating func grant(_ destination: DataSharingDestination, at date: Date = Date()) {
    grants.removeAll { $0.destination == destination }
    grants.append(.init(destination: destination, disclosureVersion: Self.disclosureVersion, grantedAt: ISO8601DateFormatter().string(from: date)))
  }
  public mutating func revoke(_ destination: DataSharingDestination) { grants.removeAll { $0.destination == destination } }
  public var current: [DataSharingGrant] { grants.filter { $0.disclosureVersion == Self.disclosureVersion } }

  public static func load(from file: URL) throws -> Self {
    guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
  }
  public func save(to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(self).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
}

public enum DataSharingError: Error, LocalizedError, Sendable, Equatable {
  case permissionRequired(DataSharingDestination)
  public var errorDescription: String? {
    guard case .permissionRequired(let destination) = self else { return nil }
    return "Quick Chat needs your permission before sending content to \(destination.recipientName). Nothing was sent."
  }
}

/// Consulted immediately before a request carrying user content leaves the device.
public protocol DataSharingAuthorizing: Sendable {
  func permits(_ destination: DataSharingDestination) async -> Bool
}
public struct DataSharingPolicy: DataSharingAuthorizing {
  private let decide: @Sendable (DataSharingDestination) async -> Bool
  public init(_ decide: @escaping @Sendable (DataSharingDestination) async -> Bool) { self.decide = decide }
  public func permits(_ destination: DataSharingDestination) async -> Bool { await decide(destination) }
  /// The default: nothing is shared until the caller supplies the user's saved decision.
  public static let denied = DataSharingPolicy { _ in false }
  public static func granted(_ permissions: DataSharingPermissions) -> DataSharingPolicy { .init { permissions.permits($0) } }

  /// Throws without sending unless the request goes exactly where permission was granted.
  public static func authorize(_ request: URLRequest, as destination: DataSharingDestination, using policy: any DataSharingAuthorizing) async throws {
    guard let url = request.url, DataSharingDestination.origin(of: url) == destination.origin,
      await policy.permits(destination) else { throw DataSharingError.permissionRequired(destination) }
  }
}
