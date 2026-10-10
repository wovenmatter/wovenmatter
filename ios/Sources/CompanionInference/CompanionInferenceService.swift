import Foundation
import CryptoKit

public struct InferenceHostAccount: Codable, Sendable, Identifiable {
  public let provider: String
  public let id: String
  public let label: String
  public let connected: Bool
}
public struct InferenceHostCatalog: Codable, Sendable {
  public let models: [InferenceModel]
  public let accounts: [InferenceHostAccount]
}

public actor CompanionInferenceService {
  public let connection: InferenceConnection
  private var pinnedModel: InferenceModel?
  private let catalogLoader: ProviderModelCatalog
  private let credentials: any InferenceCredentialReading
  private let transport: any InferenceHTTPTransport
  public init(connection: InferenceConnection, credentials: any InferenceCredentialReading = InferenceCredentialStore(),
              transport: any InferenceHTTPTransport = InferenceURLSessionTransport(), catalogLoader: ProviderModelCatalog = .shared, model: InferenceModel? = nil) {
    self.connection = connection; self.credentials = credentials; self.transport = transport
    self.catalogLoader = catalogLoader; self.pinnedModel = model ?? connection.selectedModel
  }
  public func model() async throws -> InferenceModel {
    try connection.validate()
    if connection.route == .direct && connection.provider.hasPrefix("local-server-") {
      return .init(id: connection.modelID, name: connection.modelID, provider: connection.provider, api: "openai-responses", baseUrl: connection.baseURL ?? "")
    }
    if let pinnedModel { try validate(pinnedModel); return pinnedModel }
    let models: [InferenceModel]
    if connection.route == .adapter {
      let host = try await hostCatalog()
      guard host.accounts.contains(where: { $0.provider == connection.provider && $0.id == connection.accountID && $0.connected }) else { throw InferenceError.accountUnavailable }
      models = host.models
    } else if connection.provider.hasPrefix("local-server-") {
      return .init(id: connection.modelID, name: connection.modelID, provider: connection.provider, api: "openai-responses", baseUrl: connection.baseURL ?? "")
    } else {
      let cached = await catalogLoader.cached(provider: connection.provider)
      if let selected = cached.first(where: { $0.id == connection.modelID }) { models = [selected] }
      else { models = try await catalogLoader.load(provider: connection.provider) }
    }
    guard let model = models.first(where: { $0.id == connection.modelID && $0.provider == connection.provider }) else { throw InferenceError.modelUnavailable }
    try validate(model); pinnedModel = model
    return model
  }
  public func catalog() async throws -> [InferenceModel] {
    if connection.route == .adapter { return try await hostCatalog().models.filter { $0.provider == connection.provider } }
    return try await catalogLoader.load(provider: connection.provider)
  }
  public func hostCatalog() async throws -> InferenceHostCatalog {
    try connection.validate()
    var components = URLComponents(url: try adapterURL("catalog"), resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "provider", value: connection.provider)]
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(try await secret())", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    applyHostScope(to: &request)
    var data = Data()
    for try await event in try await transport.stream(request) {
      switch event {
      case .response(let status): guard (200..<300).contains(status) else { throw InferenceError.http(status) }
      case .line(let line): data.append(contentsOf: line.utf8); guard data.count <= 4 * 1024 * 1024 else { throw InferenceError.responseTooLarge }
      }
    }
    do { return try JSONDecoder().decode(InferenceHostCatalog.self, from: data) }
    catch { throw InferenceError.malformedResponse }
  }
  public func stream(requestJSON: String, emit: @escaping @Sendable (String) -> Void) async throws {
    try connection.validate(); try Task.checkCancellation()
    guard requestJSON.utf8.count <= 8 * 1024 * 1024, let data = requestJSON.data(using: .utf8),
      var input = try JSONSerialization.jsonObject(with: data) as? InferenceObject else { throw InferenceError.invalidConfiguration }
    let requested = inferenceObject(input["model"])
    guard requested["id"] as? String == connection.modelID, requested["provider"] as? String == connection.provider else { throw InferenceError.modelUnavailable }
    // Validate the pinned routing metadata before even reading the credential.
    let selected = connection.route == .direct ? try await model() : nil
    let secret = try await secret()
    if connection.route == .adapter {
      input["accountID"] = connection.accountID
      // Endpoint selection, native directories, auth and credential headers are server-owned.
      input["model"] = ["id": connection.modelID, "provider": connection.provider]
      var request = URLRequest(url: try adapterURL("stream")); request.httpMethod = "POST"
      request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
      request.httpBody = try JSONSerialization.data(withJSONObject: input)
      applyHostScope(to: &request)
      var terminal = false
      for try await event in try await transport.stream(request) {
        try Task.checkCancellation()
        switch event {
        case .response(let status): guard (200..<300).contains(status) else { throw InferenceError.http(status) }
        case .line(let line):
          if line.isEmpty { continue }
          guard !terminal, let bytes = line.data(using: .utf8), let value = try JSONSerialization.jsonObject(with: bytes) as? InferenceObject,
            let type = value["type"] as? String,
            ["start", "text_start", "text_delta", "text_end", "thinking_start", "thinking_delta", "thinking_end", "toolcall_start", "toolcall_delta", "toolcall_end", "done", "error"].contains(type)
          else { throw InferenceError.malformedResponse }
          terminal = type == "done" || type == "error"
          emit(line)
        }
      }
      guard terminal else { throw InferenceError.interrupted }
    } else {
      guard let selected else { throw InferenceError.modelUnavailable }
      // A credential replacement must not replay account-bound thinking signatures to another principal.
      var route = connection
      route.id = SHA256.hash(data: Data([connection.id, connection.provider, connection.modelID, secret].joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
      let request = try InferenceRequestBuilder(connection: route, model: selected).request(input, secret: secret)
      let decoder = InferenceStreamDecoder(model: selected, connectionID: route.id, emit: emit)
      var payload = [String]()
      for try await event in try await transport.stream(request) {
        try Task.checkCancellation()
        switch event {
        case .response(let status): guard (200..<300).contains(status) else { throw InferenceError.http(status) }
        case .line(let line):
          if line.isEmpty {
            if !payload.isEmpty { try decoder.consume(payload.joined(separator: "\n")); payload.removeAll(keepingCapacity: true) }
          } else if line.hasPrefix("data:") { payload.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        }
      }
      if !payload.isEmpty { try decoder.consume(payload.joined(separator: "\n")) }
      try decoder.finish()
    }
  }
  private func validate(_ model: InferenceModel) throws {
    guard model.id == connection.modelID, model.provider == connection.provider else { throw InferenceError.modelUnavailable }
    if connection.route == .direct && !connection.provider.hasPrefix("local-server-") {
      try InferenceModelPolicy.validate(model, provider: connection.provider)
    }
  }
  private func applyHostScope(to request: inout URLRequest) {
    guard let scope = connection.hostScope else { return }
    request.setValue(String(scope.protocolVersion), forHTTPHeaderField: "X-Woven-Protocol")
    request.setValue(scope.libraryID, forHTTPHeaderField: "X-Woven-Library")
    request.setValue(scope.workspaceID, forHTTPHeaderField: "X-Woven-Workspace")
    request.setValue(scope.deviceID, forHTTPHeaderField: "X-Woven-Device")
  }
  private func secret() async throws -> String {
    guard let value = try await credentials.read(connectionID: connection.id), !value.isEmpty else { throw InferenceError.missingCredential }
    return value
  }
  private func adapterURL(_ operation: String) throws -> URL {
    var base = try InferenceURLPolicy.tailnet(connection.baseURL ?? "")
    if base.path.hasSuffix("/v1/inference") { return base.appendingPathComponent(operation) }
    if base.path.hasSuffix("/v1") { base.deleteLastPathComponent() }
    return base.appendingPathComponent("v1/inference/\(operation)")
  }
}
