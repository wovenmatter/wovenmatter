import Foundation

/// Protocol policy, not an inventory. Downloaded descriptors never choose a credential destination.
public enum InferenceModelPolicy {
  static let endpoints: [String: [String: String]] = [
    "openai": ["openai-responses": "https://api.openai.com/v1"],
    "anthropic": ["anthropic-messages": "https://api.anthropic.com"],
    "openrouter": ["openai-completions": "https://openrouter.ai/api/v1", "anthropic-messages": "https://openrouter.ai/api"],
    "opencode-go": ["openai-completions": "https://opencode.ai/zen/go/v1", "openai-responses": "https://opencode.ai/zen/go/v1", "anthropic-messages": "https://opencode.ai/zen/go"],
    "xai-api": ["openai-responses": "https://api.x.ai/v1"],
  ]
  public static func validate(_ model: InferenceModel, provider: String) throws {
    guard model.provider == provider, !model.id.isEmpty, model.id.utf8.count <= 512,
          !model.name.isEmpty, model.name.utf8.count <= 512,
          !model.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          (1...100_000_000).contains(model.contextWindow), (1...100_000_000).contains(model.maxTokens),
          !model.input.isEmpty, Set(model.input).isSubset(of: ["text", "image"]), model.input.contains("text"),
          model.metadata["type"] == nil || model.metadata["type"] == .string("chat"),
          model.cost.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
          (try model.descriptorJSON()).utf8.count <= 65_536 else { throw InferenceError.malformedResponse }
    if let cost = model.metadata["cost"] {
      func validCost(_ value: InferenceJSON) -> Bool {
        switch value {
        case .number(let number): return number.isFinite && number >= 0
        case .object(let values): return values.values.allSatisfy(validCost)
        case .array(let values): return values.allSatisfy(validCost)
        default: return false
        }
      }
      guard case .object = cost, validCost(cost) else { throw InferenceError.malformedResponse }
    }
    guard let endpoint = endpoints[provider]?[model.api] else { throw InferenceError.modelUnavailable }
    guard model.baseUrl == endpoint, model.metadata["headers"] == nil else { throw InferenceError.invalidEndpoint }
  }
  static func parse(_ data: Data, provider: String) throws -> [InferenceModel] {
    guard data.count <= ProviderModelCatalog.byteLimit else { throw InferenceError.responseTooLarge }
    let value = try JSONSerialization.jsonObject(with: data)
    let entries: [Any]
    if let array = value as? [Any] { entries = array }
    else if let object = value as? [String: Any] { entries = object["models"] as? [Any] ?? Array(object.values) }
    else { throw InferenceError.malformedResponse }
    guard entries.count <= 4096 else { throw InferenceError.responseTooLarge }
    var result: [InferenceModel] = [], seen = Set<String>()
    for entry in entries {
      guard let object = entry as? [String: Any], let source = object["provider"] as? String,
            source == (provider == "xai-api" ? "xai" : provider) else { throw InferenceError.malformedResponse }
      if let type = object["type"] as? String, type != "chat" { continue }
      guard let api = object["api"] as? String else { throw InferenceError.malformedResponse }
      if endpoints[provider]?[api] == nil { continue }
      var model = try JSONDecoder().decode(InferenceModel.self, from: JSONSerialization.data(withJSONObject: object))
      model.provider = provider
      try validate(model, provider: provider)
      guard seen.insert(model.id).inserted else { throw InferenceError.malformedResponse }
      result.append(model)
    }
    guard !result.isEmpty else { throw InferenceError.modelUnavailable }
    return result
  }
}

public struct CatalogHTTPResponse: Sendable {
  public var status: Int
  public var data: Data
  public var etag: String?
  public var lastModified: String?
  public init(status: Int, data: Data = Data(), etag: String? = nil, lastModified: String? = nil) {
    self.status = status; self.data = data; self.etag = etag; self.lastModified = lastModified
  }
}
public protocol CatalogHTTPTransport: Sendable {
  func fetch(_ request: URLRequest) async throws -> CatalogHTTPResponse
}
private final class CatalogURLSessionTransport: NSObject, CatalogHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
  func fetch(_ request: URLRequest) async throws -> CatalogHTTPResponse {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
    config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw InferenceError.malformedResponse }
    guard response.expectedContentLength <= ProviderModelCatalog.byteLimit else { throw InferenceError.responseTooLarge }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < ProviderModelCatalog.byteLimit else { throw InferenceError.responseTooLarge }
      data.append(byte)
    }
    return .init(status: response.statusCode, data: data, etag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
  }
}

/// No initialization network or polling. Call cached/load only for the provider currently in use.
public actor ProviderModelCatalog {
  public static let shared = ProviderModelCatalog()
  public static let piVersion = "1.1.0"
  static let byteLimit = 4 * 1024 * 1024
  static let refreshInterval: TimeInterval = 4 * 60 * 60
  private struct Entry: Codable {
    var piVersion: String
    var models: [InferenceModel]
    var checkedAt: Date
    var etag: String?
    var lastModified: String?
  }
  private let directory: URL
  private let transport: any CatalogHTTPTransport
  private let now: @Sendable () -> Date
  private var entries: [String: Entry] = [:]
  public init(directory: URL? = nil, transport: (any CatalogHTTPTransport)? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
    self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("WovenMatter/provider-models")
    self.transport = transport ?? CatalogURLSessionTransport(); self.now = now
  }
  public func cached(provider: String) -> [InferenceModel] {
    guard InferenceModelPolicy.endpoints[provider] != nil else { return [] }
    if let entry = entries[provider] { return entry.models }
    let url = directory.appendingPathComponent(provider + ".json")
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: Self.byteLimit + 1), data.count <= Self.byteLimit,
          let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.piVersion == Self.piVersion,
          !entry.models.isEmpty, entry.models.count <= 4096, Set(entry.models.map(\.id)).count == entry.models.count,
          entry.models.allSatisfy({ (try? InferenceModelPolicy.validate($0, provider: provider)) != nil }) else { return [] }
    entries[provider] = entry
    return entry.models
  }
  public func load(provider: String, force: Bool = false) async throws -> [InferenceModel] {
    guard InferenceModelPolicy.endpoints[provider] != nil else { throw InferenceError.modelUnavailable }
    try Task.checkCancellation()
    _ = cached(provider: provider)
    let saved = entries[provider]
    if !force, let saved, (0..<Self.refreshInterval).contains(now().timeIntervalSince(saved.checkedAt)) { return saved.models }
    let source = provider == "xai-api" ? "xai" : provider
    var request = URLRequest(url: URL(string: "https://pi.dev/api/models/providers/\(source)?types=chat")!)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("pi/\(Self.piVersion)", forHTTPHeaderField: "User-Agent")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    if let saved {
      request.setValue(Self.validator(saved.etag), forHTTPHeaderField: "If-None-Match")
      request.setValue(Self.validator(saved.lastModified), forHTTPHeaderField: "If-Modified-Since")
    }
    let response = try await transport.fetch(request)
    try Task.checkCancellation()
    var entry: Entry
    if response.status == 304, let saved { entry = saved; entry.checkedAt = now() }
    else {
      guard response.status == 200 else { throw InferenceError.http(response.status) }
      entry = Entry(piVersion: Self.piVersion, models: try InferenceModelPolicy.parse(response.data, provider: provider), checkedAt: now(),
                    etag: Self.validator(response.etag), lastModified: Self.validator(response.lastModified))
    }
    let data = try JSONEncoder().encode(entry)
    guard data.count <= Self.byteLimit else { throw InferenceError.responseTooLarge }
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: directory.appendingPathComponent(provider + ".json"), options: .atomic)
    entries[provider] = entry
    return entry.models
  }
  private static func validator(_ value: String?) -> String? {
    guard let value, value.utf8.count <= 1024, !value.contains("\r"), !value.contains("\n") else { return nil }
    return value
  }
}
