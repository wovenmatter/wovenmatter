import Foundation
import MobileInference
import WovenProtocol

/// The device's own model and web search sign-ins. Each secret is one
/// device-only Keychain item, named by the provider (a model server by its
/// id, a search provider by its `credentialID`); none enters the library.
/// Models come from each connected provider's catalog, cached in the data
/// folder.
struct Providers: Sendable {
  /// Where a turn's inference goes: `MobileInferenceService` with the
  /// provider's credential, or a test's stand-in.
  typealias Inference = @Sendable (_ model: InferenceModel, _ request: String,
                                   _ emit: @escaping @Sendable (String) -> Void) async throws -> Void

  let credentials: any InferenceCredentialUpdating
  let catalog: ProviderModelCatalog
  let servers: ModelServers
  let oauth: InferenceOAuthCredentialResolver
  let transport: any InferenceHTTPTransport
  private let override: Inference?

  init(credentials: any InferenceCredentialUpdating, catalog: ProviderModelCatalog, servers: ModelServers,
       transport: any InferenceHTTPTransport = InferenceURLSessionTransport(),
       oauth: InferenceOAuthCredentialResolver = .shared, inference: Inference? = nil) {
    self.credentials = credentials
    self.catalog = catalog
    self.servers = servers
    self.transport = transport
    self.oauth = oauth
    self.override = inference
  }

  // MARK: The providers, named as a machine's Pi Durable names them

  static let subscriptions: [(id: String, name: String)] = [("openai-codex", "ChatGPT"), ("xai", "Grok"), ("claude-subscription", "Claude")]
  static let keyed: [(id: String, name: String)] = [
    ("openai", "OpenAI"), ("anthropic", "Anthropic"), ("openrouter", "OpenRouter"), ("opencode", "OpenCode Zen"),
    ("opencode-go", "OpenCode Go"), ("xai-api", "xAI"),
  ]
  static let search: [(provider: QuickChatSearchProvider, name: String)] = [
    (.exa, "Exa web search"), (.brave, "Brave web search"), (.firecrawl, "Firecrawl web search"),
  ]
  /// The order models are offered in when the settings list none.
  private static let preferred = ["openai-codex", "claude-subscription", "xai", "anthropic", "openai"]

  static func name(of provider: String) -> String {
    (subscriptions + keyed).first { $0.id == provider }?.name ?? provider
  }

  /// The Keychain item a provider's secret is in.
  static func credentialID(_ provider: String) -> String {
    QuickChatSearchProvider(rawValue: provider)?.credentialID ?? provider
  }

  private func has(_ credentialID: String) async -> Bool {
    ((try? await credentials.read(connectionID: credentialID)) ?? nil)?.isEmpty == false
  }

  /// Every provider, with whether this device is connected to it.
  func signIns() async -> [SignIn] {
    var list: [SignIn] = []
    for (id, name) in Self.subscriptions {
      list.append(SignIn(provider: id, name: name, kind: .subscription, connected: await has(id)))
    }
    for (id, name) in Self.keyed {
      list.append(SignIn(provider: id, name: name, kind: .apiKey, connected: await has(id)))
    }
    for (provider, name) in Self.search {
      list.append(SignIn(provider: provider.rawValue, name: name, kind: .apiKey, connected: await has(provider.credentialID)))
    }
    return list
  }

  /// The model providers this device is connected to, preferred first.
  func connected() async -> [String] {
    var ids: [String] = []
    for (id, _) in Self.subscriptions + Self.keyed where await has(id) { ids.append(id) }
    let order = { (id: String) in Self.preferred.firstIndex(of: id) ?? Self.preferred.count }
    return ids.sorted { order($0) < order($1) }
  }

  func setKey(_ provider: String, _ key: String?) async throws {
    guard !Self.subscriptions.contains(where: { $0.id == provider }) else {
      throw ProtocolError(.badRequest, "\(Self.name(of: provider)) signs in with a subscription, not a key.")
    }
    guard Self.keyed.contains(where: { $0.id == provider }) || QuickChatSearchProvider(rawValue: provider) != nil else {
      throw ProtocolError(.badRequest, "Quick Chat does not use \(provider).")
    }
    if let key, !key.isEmpty {
      try await credentials.save(key, connectionID: Self.credentialID(provider))
    } else {
      try await credentials.remove(connectionID: Self.credentialID(provider))
    }
  }

  func signOut(_ provider: String) async throws {
    try await credentials.remove(connectionID: Self.credentialID(provider))
  }

  // MARK: Models

  /// Every model of the connected providers and the model servers, from the
  /// cached catalogs, loading one that is not cached (or every one, with `refresh`).
  /// A provider whose catalog cannot be read now is left out.
  func models(refresh: Bool = false) async -> [InferenceModel] {
    var models: [InferenceModel] = []
    for provider in await connected() {
      let cached = refresh ? [] : await catalog.cached(provider: provider)
      if !cached.isEmpty {
        models += cached
      } else if let loaded = try? await catalog.load(provider: provider, force: refresh) {
        models += loaded
      }
    }
    for server in await servers.list() {
      guard await has(server.id) else { continue }
      models += server.models.map {
        InferenceModel(id: $0, name: $0, provider: server.id, api: "openai-responses", baseUrl: server.url)
      }
    }
    return models
  }

  /// The models the Pi Durable settings offer, as a machine's Pi Durable
  /// chooses them: the enabled providers' (a model server's always), those
  /// listed with the default first, or every one when none is listed.
  func offered(settings: [String: JSONValue]) async -> [InferenceModel] {
    let available = await models()
    let providers = settings["providers"]?.array.map { Set($0.compactMap(\.string)) }
    let enabled = providers.map { providers in
      available.filter { providers.contains($0.provider) || $0.provider.hasPrefix(ModelServers.prefix) }
    } ?? available
    let listed = ([settings["defaultModel"]?.string] + (settings["models"]?.array ?? []).map(\.string)).compactMap { $0 }
    guard !listed.isEmpty else { return enabled }
    var seen = Set<String>()
    let offered = listed.filter { seen.insert($0).inserted }.compactMap { reference in enabled.first { $0.reference == reference } }
    return offered.isEmpty ? enabled : offered
  }

  // MARK: Inference

  /// Streams one pi-ai request through the provider its model names.
  func stream(_ model: InferenceModel, request: String, emit: @escaping @Sendable (String) -> Void) async throws {
    if let override { return try await override(model, request, emit) }
    var connection = InferenceConnection(id: Self.credentialID(model.provider), name: Self.name(of: model.provider),
                                         provider: model.provider, modelID: model.id, selectedModel: model)
    if model.provider.hasPrefix(ModelServers.prefix) {
      connection.baseURL = model.baseUrl
    }
    if InferenceOAuthSession.supports(model.provider), let raw = try await credentials.read(connectionID: connection.id) {
      connection.accountID = try InferenceOAuthCredential.decode(raw).accountID
    }
    let service = MobileInferenceService(connection: connection, credentials: credentials, transport: transport,
                                         catalogLoader: catalog, model: model, oauthResolver: oauth)
    try await service.stream(requestJSON: request, emit: emit)
  }
}

extension InferenceModel {
  /// `provider/model`, as Pi Durable's settings and the composer name it.
  var reference: String { "\(provider)/\(id)" }
}

/// What a person sees in place of Quick Chat while no model provider is connected.
let signInFirst = "Sign in to a model provider to use Quick Chat."
