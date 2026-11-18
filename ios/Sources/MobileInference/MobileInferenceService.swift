import Foundation
import CryptoKit

public actor MobileInferenceService {
  public let connection: InferenceConnection
  private var pinnedModel: InferenceModel?
  private let catalogLoader: ProviderModelCatalog
  private let credentials: any InferenceCredentialReading
  private let transport: any InferenceHTTPTransport
  private let oauthResolver: InferenceOAuthCredentialResolver
  public init(connection: InferenceConnection, credentials: any InferenceCredentialReading = InferenceCredentialStore(),
              transport: any InferenceHTTPTransport = InferenceURLSessionTransport(), catalogLoader: ProviderModelCatalog = .shared, model: InferenceModel? = nil, oauthResolver: InferenceOAuthCredentialResolver = .shared) {
    self.connection = connection; self.credentials = credentials; self.transport = transport
    self.catalogLoader = catalogLoader; self.pinnedModel = model ?? connection.selectedModel; self.oauthResolver = oauthResolver
  }
  public func model() async throws -> InferenceModel {
    try connection.validate()
    if connection.provider.hasPrefix("local-server-") {
      return .init(id: connection.modelID, name: connection.modelID, provider: connection.provider, api: "openai-responses", baseUrl: connection.baseURL ?? "")
    }
    if let pinnedModel { try validate(pinnedModel); return pinnedModel }
    let models: [InferenceModel]
    let cached = await catalogLoader.cached(provider: connection.provider)
    if let selected = cached.first(where: { $0.id == connection.modelID }) { models = [selected] }
    else { models = try await catalogLoader.load(provider: connection.provider) }
    guard let model = models.first(where: { $0.id == connection.modelID && $0.provider == connection.provider }) else { throw InferenceError.modelUnavailable }
    try validate(model); pinnedModel = model
    return model
  }
  public func catalog() async throws -> [InferenceModel] {
    try await catalogLoader.load(provider: connection.provider)
  }
  public func stream(requestJSON: String, emit: @escaping @Sendable (String) -> Void) async throws {
    try connection.validate(); try Task.checkCancellation()
    guard requestJSON.utf8.count <= 8 * 1024 * 1024, let data = requestJSON.data(using: .utf8),
      let input = try JSONSerialization.jsonObject(with: data) as? InferenceObject else { throw InferenceError.invalidConfiguration }
    let requested = inferenceObject(input["model"])
    guard requested["id"] as? String == connection.modelID, requested["provider"] as? String == connection.provider else { throw InferenceError.modelUnavailable }
    // Validate the pinned routing metadata before even reading the credential.
    let selected = try await model()
    let oauth = InferenceOAuthSession.supports(connection.provider)
      ? try await oauthResolver.resolve(connection: connection, credentials: credentials) : nil
    let secret: String
    if let oauth { secret = oauth.access } else { secret = try await self.secret() }
    // A credential replacement must not replay account-bound thinking signatures to another principal.
    var route = connection
    route.id = SHA256.hash(data: Data([connection.id, connection.provider, connection.modelID, oauth?.bindingID ?? secret].joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
    let request = try InferenceRequestBuilder(connection: route, model: selected).request(input, secret: secret, accountID: oauth?.accountID)
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
  private func validate(_ model: InferenceModel) throws {
    guard model.id == connection.modelID, model.provider == connection.provider else { throw InferenceError.modelUnavailable }
    if !connection.provider.hasPrefix("local-server-") { try InferenceModelPolicy.validate(model, provider: connection.provider) }
  }
  private func secret() async throws -> String {
    guard let value = try await credentials.read(connectionID: connection.id), !value.isEmpty else { throw InferenceError.missingCredential }
    return value
  }
}
