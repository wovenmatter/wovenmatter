import Foundation
import Darwin

public enum InferenceRoute: String, Codable, Sendable, CaseIterable { case direct, adapter }

public struct InferenceProvider: Identifiable, Sendable {
  public let id: String
  public let name: String
  public let defaultRoute: InferenceRoute
  public let supportsDirect: Bool
  public init(id: String, name: String, defaultRoute: InferenceRoute, supportsDirect: Bool) {
    self.id = id; self.name = name; self.defaultRoute = defaultRoute; self.supportsDirect = supportsDirect
  }
}

public struct InferenceHostScope: Codable, Sendable, Equatable {
  public var libraryID: String
  public var workspaceID: String
  public var deviceID: String
  public var protocolVersion: Int
  public init(libraryID: String, workspaceID: String, deviceID: String, protocolVersion: Int) {
    self.libraryID = libraryID; self.workspaceID = workspaceID; self.deviceID = deviceID; self.protocolVersion = protocolVersion
  }
}

/// Connection metadata is safe to persist with local preferences. Credentials are deliberately absent.
public struct InferenceConnection: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  public var name: String
  public var provider: String
  public var accountID: String
  public var route: InferenceRoute
  public var baseURL: String?
  public var modelID: String
  public var hostScope: InferenceHostScope?
  public init(id: String = UUID().uuidString, name: String, provider: String, accountID: String = "default",
              route: InferenceRoute, baseURL: String? = nil, modelID: String, hostScope: InferenceHostScope? = nil) {
    self.id = id; self.name = name; self.provider = provider; self.accountID = accountID
    self.route = route; self.baseURL = baseURL; self.modelID = modelID; self.hostScope = hostScope
  }
  public func validate() throws {
    guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !accountID.isEmpty, !modelID.isEmpty, modelID.count <= 512 else { throw InferenceError.invalidConfiguration }
    if route == .adapter {
      guard let baseURL else { throw InferenceError.adapterRequired }
      _ = try InferenceURLPolicy.tailnet(baseURL)
    } else if provider.hasPrefix("local-server-") {
      guard let baseURL else { throw InferenceError.invalidEndpoint }
      _ = try InferenceURLPolicy.tailnet(baseURL)
    } else {
      guard let definition = InferenceCatalog.providers.first(where: { $0.id == provider }), definition.supportsDirect
      else { throw InferenceError.adapterRequired }
      // Custom destinations must be explicit custom-server connections, never a cloud account override.
      guard baseURL == nil || baseURL == "" else { throw InferenceError.invalidEndpoint }
    }
  }
}

public enum InferenceJSON: Codable, Sendable, Equatable {
  case object([String: InferenceJSON]), array([InferenceJSON]), string(String), number(Double), bool(Bool), null
  public init(from decoder: any Decoder) throws {
    let box = try decoder.singleValueContainer()
    if box.decodeNil() { self = .null }
    else if let value = try? box.decode(Bool.self) { self = .bool(value) }
    else if let value = try? box.decode(Double.self) { self = .number(value) }
    else if let value = try? box.decode(String.self) { self = .string(value) }
    else if let value = try? box.decode([InferenceJSON].self) { self = .array(value) }
    else { self = .object(try box.decode([String: InferenceJSON].self)) }
  }
  public func encode(to encoder: any Encoder) throws {
    var box = encoder.singleValueContainer()
    switch self {
    case .object(let value): try box.encode(value)
    case .array(let value): try box.encode(value)
    case .string(let value): try box.encode(value)
    case .number(let value): try box.encode(value)
    case .bool(let value): try box.encode(value)
    case .null: try box.encodeNil()
    }
  }
  var value: Any {
    switch self {
    case .object(let values): values.mapValues(\.value)
    case .array(let values): values.map(\.value)
    case .string(let value): value
    case .number(let value): value
    case .bool(let value): value
    case .null: NSNull()
    }
  }
}

public struct InferenceModel: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  public var name: String
  public var provider: String
  public var api: String
  public var baseUrl: String
  public var contextWindow: Int
  public var maxTokens: Int
  public var reasoning: Bool
  public var input: [String]
  public var cost: [String: Double]
  public var thinkingLevelMap: [String: String?]?
  public var metadata: [String: InferenceJSON] = [:]
  public init(id: String, name: String, provider: String, api: String, baseUrl: String,
              contextWindow: Int = 16384, maxTokens: Int = 4096, reasoning: Bool = false, input: [String] = ["text"],
              cost: [String: Double] = ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0], thinkingLevelMap: [String: String?]? = nil) {
    self.id = id; self.name = name; self.provider = provider; self.api = api; self.baseUrl = baseUrl
    self.contextWindow = contextWindow; self.maxTokens = maxTokens; self.reasoning = reasoning; self.input = input
    self.cost = cost; self.thinkingLevelMap = thinkingLevelMap
  }
  private struct Field: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
  public init(from decoder: any Decoder) throws {
    let box = try decoder.container(keyedBy: Field.self)
    id = try box.decode(String.self, forKey: Field("id")); name = try box.decode(String.self, forKey: Field("name"))
    provider = try box.decode(String.self, forKey: Field("provider")); api = try box.decode(String.self, forKey: Field("api"))
    baseUrl = try box.decode(String.self, forKey: Field("baseUrl"))
    contextWindow = try box.decode(Int.self, forKey: Field("contextWindow")); maxTokens = try box.decode(Int.self, forKey: Field("maxTokens"))
    reasoning = try box.decodeIfPresent(Bool.self, forKey: Field("reasoning")) ?? false
    input = try box.decodeIfPresent([String].self, forKey: Field("input")) ?? ["text"]
    thinkingLevelMap = try box.decodeIfPresent([String: String?].self, forKey: Field("thinkingLevelMap"))
    let rawCost = try box.decodeIfPresent([String: InferenceJSON].self, forKey: Field("cost")) ?? [:]
    cost = rawCost.compactMapValues { if case .number(let number) = $0 { return number }; return nil }
    let known: Set<String> = ["id", "name", "provider", "api", "baseUrl", "contextWindow", "maxTokens", "reasoning", "input", "thinkingLevelMap"]
    for key in box.allKeys where !known.contains(key.stringValue) { metadata[key.stringValue] = try box.decode(InferenceJSON.self, forKey: key) }
  }
  public func encode(to encoder: any Encoder) throws {
    var box = encoder.container(keyedBy: Field.self)
    for (key, value) in metadata where key != "cost" { try box.encode(value, forKey: Field(key)) }
    try box.encode(id, forKey: Field("id")); try box.encode(name, forKey: Field("name"))
    try box.encode(provider, forKey: Field("provider")); try box.encode(api, forKey: Field("api")); try box.encode(baseUrl, forKey: Field("baseUrl"))
    try box.encode(contextWindow, forKey: Field("contextWindow")); try box.encode(maxTokens, forKey: Field("maxTokens"))
    try box.encode(reasoning, forKey: Field("reasoning")); try box.encode(input, forKey: Field("input"))
    try box.encodeIfPresent(thinkingLevelMap, forKey: Field("thinkingLevelMap"))
    if let full = metadata["cost"] { try box.encode(full, forKey: Field("cost")) }
    else { try box.encode(cost, forKey: Field("cost")) }
  }
  public func descriptorJSON() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

public enum InferenceCatalog {
  public static let providers: [InferenceProvider] = [
    .init(id: "openai-codex", name: "OpenAI · ChatGPT subscription", defaultRoute: .adapter, supportsDirect: false),
    .init(id: "openai", name: "OpenAI · API key", defaultRoute: .direct, supportsDirect: true),
    .init(id: "openrouter", name: "OpenRouter", defaultRoute: .direct, supportsDirect: true),
    .init(id: "opencode-go", name: "OpenCode Go", defaultRoute: .direct, supportsDirect: true),
    .init(id: "xai", name: "Grok subscription", defaultRoute: .adapter, supportsDirect: false),
    .init(id: "xai-api", name: "xAI · API key", defaultRoute: .direct, supportsDirect: true),
    .init(id: "claude-subscription", name: "Claude · Subscription", defaultRoute: .adapter, supportsDirect: false),
    .init(id: "anthropic", name: "Claude · API key", defaultRoute: .direct, supportsDirect: true),
    .init(id: "local-server-openai", name: "Tailscale model server", defaultRoute: .direct, supportsDirect: true),
  ]
  public static func models(provider: String) throws -> [InferenceModel] {
    guard let url = Bundle.module.url(forResource: "models", withExtension: "json") else { throw InferenceError.modelUnavailable }
    return try JSONDecoder().decode([InferenceModel].self, from: Data(contentsOf: url)).filter { $0.provider == provider }
  }
}

public enum InferenceError: Error, LocalizedError, Sendable, Equatable {
  case invalidConfiguration, invalidEndpoint, adapterRequired, missingCredential, modelUnavailable, accountUnavailable
  case malformedResponse, interrupted, responseTooLarge, http(Int), connectionFailed, unsupportedToolImages
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "Choose a connection, account, and model before starting this agent."
    case .invalidEndpoint: "Use the inference host's Tailscale address without embedded credentials, query parameters, or fragments."
    case .adapterRequired: "This subscription uses an inference adapter on an authorized Tailscale host. The agent and its tools still run on this device."
    case .missingCredential: "This connection needs an API key or an authorized inference-host credential in Settings."
    case .modelUnavailable: "The selected model is unavailable on this connection. Choose a model explicitly; no fallback was attempted."
    case .accountUnavailable: "The selected account is unavailable on this inference host. No account fallback was attempted."
    case .malformedResponse: "The inference endpoint returned an unsupported response."
    case .unsupportedToolImages: "This direct connection does not support images returned by tools yet. Continue with a text-only tool result or choose a compatible connection explicitly. No request was sent."
    case .interrupted: "Inference was interrupted before a complete response was received. Saved agent work remains on this device."
    case .responseTooLarge: "The inference response exceeded this device's request limit."
    case .http(let status) where status == 401 || status == 403: "The inference endpoint rejected this connection's credentials. Check its account and permissions in Settings."
    case .http(let status) where status == 402 || status == 429: "The inference connection has reached a usage or rate limit. Retry later or choose another connection explicitly."
    case .http(let status): "The inference endpoint returned HTTP \(status)."
    case .connectionFailed: "The inference endpoint could not be reached. Check connectivity and, for a private host, Tailscale."
    }
  }
}

public enum InferenceURLPolicy {
  public static func tailnet(_ string: String) throws -> URL {
    guard let url = URL(string: string), let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme),
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw InferenceError.invalidEndpoint }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    let parts = labels.compactMap { Int($0) }
    var v4 = in_addr(), v6 = in6_addr()
    let ipv4 = labels.count == 4 && inet_pton(AF_INET, host, &v4) == 1 && parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1]) && parts.allSatisfy { (0...255).contains($0) }
    let v6Host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let ipv6 = inet_pton(AF_INET6, v6Host, &v6) == 1 && v6Host.hasPrefix("fd7a:115c:a1e0:")
    guard ipv4 || ipv6 || (host.hasSuffix(".ts.net") && host.count > 7) else { throw InferenceError.invalidEndpoint }
    return url
  }
}
