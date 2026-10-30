import SwiftUI
import CompanionInference
import CompanionClient
import WovenMatterCompanion
import PiDurableRuntime

struct ExecutionSettingsPane: View {
  @Bindable var model: CompanionModel
  private var connections: [InferenceConnection] { model.inferenceConnections.filter { $0.route == .direct && !$0.provider.hasPrefix("local-server-") } }
  var body: some View {
    List {
      if !connections.isEmpty {
        Section("Saved accounts") {
          ForEach(connections) { connection in
            NavigationLink(connection.name) { InferenceConnectionEditor(model: model, connection: connection) }
          }
        }
      }
      Section("Add connection") {
        ForEach(InferenceCatalog.providers.filter { provider in !provider.id.hasPrefix("local-server-") &&
          (!InferenceConnectionPolicy.isSingleSubscription(provider.id) || !model.inferenceConnections.contains(where: { $0.provider == provider.id })) }) { provider in
          NavigationLink(provider.name) { InferenceConnectionEditor(model: model, connection: nil, provider: provider.id) }
        }
      }
      Section {
        NavigationLink("Tailscale inference") { HostedInferenceSettingsPane(model: model) }
      }
    }.listStyle(.insetGrouped).scrollContentBackground(.hidden).scrollIndicators(.never).mobileNavigationPage(model.deviceConnectionsTitle)
  }
}

struct HostedInferenceSettingsPane: View {
  @Bindable var model: CompanionModel
  var body: some View {
    List {
      ForEach(model.inferenceConnections.filter { $0.route == .adapter || $0.provider.hasPrefix("local-server-") }) { connection in
        NavigationLink(connection.name) { InferenceConnectionEditor(model: model, connection: connection) }
      }
      NavigationLink("Add model server") { InferenceConnectionEditor(model: model, connection: nil, provider: "local-server-openai") }
      NavigationLink("Use a workspace account") { InferenceConnectionEditor(model: model, connection: nil, hosted: true) }
    }.listStyle(.insetGrouped).scrollContentBackground(.hidden).mobileNavigationPage("Tailscale inference")
  }
}

struct DeviceAgentSettingsPane: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: CompanionModel
  @State private var defaults = DeviceAgentDefaults()
  @State private var connectionID = ""
  @State private var selectedModelID = ""
  @State private var models: [InferenceModel] = []
  @State private var loaded = false
  @State private var loading = false
  @State private var saving = false
  @State private var failure: String?
  @State private var catalogTask: Task<Void, Never>?
  @State private var saveTask: Task<Void, Never>?
  @State private var generation = UUID()
  private var policy: PiExecutionPolicy { defaults.executionPolicy ?? .init() }
  private func policyBinding<Value>(_ path: WritableKeyPath<PiExecutionPolicy, Value>) -> Binding<Value> {
    Binding(get: { policy[keyPath: path] }, set: { value in
      var updated = policy; updated[keyPath: path] = value; defaults.executionPolicy = updated
    })
  }
  private var selectedConnection: InferenceConnection? { model.inferenceConnections.first { $0.id == connectionID } }
  private var toolDefinitions: [CompanionSelection] { CompanionModel.deviceToolAccessOptions }
  private var selectedModel: InferenceModel? { models.first { $0.id == selectedModelID } }
  private var thinkingSelection: Binding<String> {
    Binding(get: { defaults.thinking(for: selectedModel) }, set: { defaults.thinkingLevel = $0 })
  }
  var body: some View {
    Form {
      Section("New conversations") {
        Picker("Connection", selection: $connectionID) {
          Text("Choose a connection").tag("")
          ForEach(model.inferenceConnections) { connection in Text(connection.name).tag(connection.id) }
        }
        if selectedConnection != nil {
          Picker("Default Model", selection: $selectedModelID) {
            ForEach(models) { Text($0.name).tag($0.id) }
          }
          Picker("Default Think Level", selection: thinkingSelection) {
            ForEach(selectedModel?.supportedThinkingLevels ?? ["off"], id: \.self) { level in
              Text(level == "xhigh" ? "Extra High" : level.capitalized).tag(level)
            }
          }.disabled(selectedModel?.reasoning != true)
          if loading { ProgressView() }
        }
        NavigationLink(model.deviceConnectionsTitle) { ExecutionSettingsPane(model: model) }
      }
      Section("Instructions") { TextEditor(text: $defaults.instructions).frame(minHeight: 130).accessibilityLabel("Pi Durable instructions") }
      Section("Execution") {
        Stepper("Concurrent subagents: \(policy.concurrentSubagents)", value: policyBinding(\.concurrentSubagents), in: 1...16)
      }

      Section {
        ForEach(toolDefinitions, id: \.id) { tool in
          Toggle(tool.label, isOn: Binding(get: { CompanionModel.deviceToolEnabled(tool.id, selection: defaults.enabledTools) }, set: { enabled in
            var selected = Set(CompanionModel.migratedDeviceToolSelection(defaults.enabledTools) ?? toolDefinitions.map(\.id).filter { CompanionModel.deviceToolEnabled($0, selection: nil) })
            if enabled { selected.insert(tool.id) } else {
              selected.remove(tool.id)
              selected.subtract(CompanionModel.deviceMCPTools.compactMap { $0["name"] as? String }.filter { name in
                WovenMCPCatalog.tools.first { $0.name == name }?.group.map { CompanionModel.deviceToolSelectionID($0) } == tool.id
              })
            }
            defaults.enabledTools = selected.sorted()
          }))
        }
      } header: {
        VStack(alignment: .leading, spacing: 6) {
          Text("Tool Access")
          Text("Choose which Woven MCP tools are available to new chats by default.")
            .font(.subheadline).fontWeight(.regular).foregroundStyle(DashboardPalette.mutedForeground)
        }.textCase(nil)
      }
      if let failure { Section { Text(failure).foregroundStyle(DashboardPalette.danger); Button("Retry") { loadModels() } } }
    }.disabled(saving).scrollIndicators(.never).mobileNavigationPage("Pi Durable")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") { save() }.disabled(saving || loading) } }
      .onAppear {
        if !loaded {
          loaded = true; defaults = model.deviceAgentDefaults; connectionID = model.inferenceConnectionID
        } else if selectedConnection == nil { connectionID = model.inferenceConnectionID }
        loadModels(preservingSelection: true)
      }
      .onChange(of: connectionID) { loadModels() }
      .onDisappear { catalogTask?.cancel(); saveTask?.cancel(); generation = UUID() }
      .navigationBarBackButtonHidden(saving)
  }
  private func loadModels(preservingSelection: Bool = false) {
    let preferred = preservingSelection ? selectedModelID : ""
    catalogTask?.cancel(); generation = UUID(); let current = generation
    failure = nil; loading = false; models = []
    guard let connection = selectedConnection else { selectedModelID = ""; return }
    selectedModelID = connection.modelID
    if let selected = connection.selectedModel { models = [selected] }
    else { models = [.init(id: connection.modelID, name: connection.modelID, provider: connection.provider, api: "", baseUrl: "")] }
    guard !model.fixture, !model.isolatedTestHost, !connection.provider.hasPrefix("local-server-") else { return }
    loading = true
    catalogTask = Task {
      do {
        let service = CompanionInferenceService(connection: connection, credentials: model.executionCredentialStore)
        var available = try await service.catalog().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !Task.isCancelled, generation == current else { return }
        if let pinned = connection.selectedModel {
          if let index = available.firstIndex(where: { $0.id == pinned.id }) { available[index] = pinned }
          else { available.insert(pinned, at: 0) }
        }
        models = available
        if !preferred.isEmpty && available.contains(where: { $0.id == preferred }) { selectedModelID = preferred }
      } catch { if !Task.isCancelled, generation == current { failure = "Couldn’t refresh models." } }
      if generation == current { loading = false }
    }
  }
  private func save() {
    guard !saving else { return }; saving = true; failure = nil
    let defaults = defaults, id = connectionID, selected = models.first { $0.id == selectedModelID }
    var connection = selectedConnection
    if let selected { connection?.modelID = selected.id; connection?.selectedModel = selected }
    saveTask = Task {
      do {
        if let connection, let original = model.inferenceConnections.first(where: { $0.id == connection.id }), connection.modelID != original.modelID {
          try await model.saveInferenceConnection(connection, secret: "")
        }
        try Task.checkCancellation()
        try model.saveDeviceAgentDefaults(defaults, connectionID: id)
        dismiss()
      } catch { if !Task.isCancelled { failure = error.localizedDescription } }
      saving = false
    }
  }
}

enum InferenceSetupMode: String, CaseIterable {
  case device = "On this device", hosted = "Use an inference host"
}

@MainActor @Observable final class InferenceConnectionSetupState {
  let original: InferenceConnection?
  var mode: InferenceSetupMode
  var provider: String
  var name: String
  var modelID: String
  var accountID: String
  var endpoint: String
  var secret = ""
  var storedCredentialAvailable = false
  var authenticatedAccountID: String?
  var models: [InferenceModel]
  var accounts: [InferenceHostAccount] = []
  var hostID = ""
  var loadingModels = false
  var saving = false
  var signingIn = false
  var pendingSignInSave = false
  var problem: String?
  var catalogGeneration = UUID()
  var authenticationGeneration = UUID()

  init(connection: InferenceConnection? = nil, provider: String = "openai-codex") {
    original = connection
    let selectedProvider = connection?.provider ?? provider
    self.provider = selectedProvider
    mode = connection?.route == .adapter ? .hosted : .device
    name = connection?.name ?? Self.providerName(selectedProvider)
    modelID = connection?.modelID ?? ""
    accountID = connection?.accountID ?? "default"
    endpoint = connection?.baseURL ?? ""
    models = connection?.selectedModel.map { [$0] } ?? []
  }
  static func providerName(_ id: String) -> String { InferenceCatalog.providers.first { $0.id == id }?.name ?? id }
  var definition: InferenceProvider? { InferenceCatalog.providers.first { $0.id == provider } }
  var isOAuth: Bool { mode == .device && definition?.supportsOAuth == true }
  var isCustomServer: Bool { provider.hasPrefix("local-server-") }
  var trimmedSecret: String { secret.trimmingCharacters(in: .whitespacesAndNewlines) }
  var hasSavedHost: Bool { original?.route == .adapter && original?.hostScope != nil && !(original?.baseURL ?? "").isEmpty }
  var saveProblem: String? {
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this connection a name." }
    if loadingModels { return "Loading the provider’s models…" }
    if signingIn { return "Complete sign-in before saving this connection." }
    if mode == .device && definition?.supportsDirect != true { return "This provider does not offer sign-in for this app. Choose its API-key connection instead." }
    if modelID.isEmpty { return "Choose a model to use with this connection." }
    if mode == .hosted {
      if hostID.isEmpty && !hasSavedHost { return "Choose an authorized host for this optional hosted connection." }
      if accountID.isEmpty { return "Choose an account from this host." }
    } else {
      if isCustomServer && endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter the model server’s Tailscale address." }
      if trimmedSecret.isEmpty && !storedCredentialAvailable { return isOAuth ? "Sign in on this device before saving." : "Enter an API key before saving." }
    }
    return nil
  }
  func chooseProvider(_ id: String) {
    let oldName = Self.providerName(provider)
    provider = id
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == oldName { name = Self.providerName(id) }
    resetCredentials()
    endpoint = ""; hostID = ""; models = []; accounts = []; modelID = ""
    accountID = mode == .device ? "default" : ""
  }
  func chooseMode(_ value: InferenceSetupMode) {
    guard mode != value else { return }
    mode = value; resetCredentials(); models = []; accounts = []; modelID = ""
    endpoint = ""; hostID = ""; accountID = value == .device ? "default" : ""
  }
  func resetCredentials() {
    secret = ""; storedCredentialAvailable = false; authenticatedAccountID = nil
    signingIn = false; pendingSignInSave = false; problem = nil; invalidateRequests()
  }
  func invalidateRequests() {
    catalogGeneration = UUID(); authenticationGeneration = UUID(); loadingModels = false
  }
  func beginCatalog() -> UUID { catalogGeneration = UUID(); loadingModels = true; problem = nil; return catalogGeneration }
  @discardableResult func receiveModels(_ fetched: [InferenceModel], generation: UUID) -> Bool {
    guard catalogGeneration == generation else { return false }
    models = fetched.filter { $0.provider == provider }.sorted {
      if $0.name == $1.name { return $0.id.localizedStandardCompare($1.id) == .orderedAscending }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    if let selected = original?.selectedModel, original?.provider == provider, selected.id == modelID {
      if let index = models.firstIndex(where: { $0.id == selected.id }) { models[index] = selected }
      else { models.insert(selected, at: 0) }
    }
    if !modelID.isEmpty && !models.contains(where: { $0.id == modelID }) { modelID = "" }
    if modelID.isEmpty {
      let preferred = models.first { $0.metadata["default"] == .bool(true) || $0.metadata["recommended"] == .bool(true) }
      modelID = (preferred ?? models.first)?.id ?? ""
    }
    return true
  }
  @discardableResult func receiveCredential(_ value: String, accountID: String, generation: UUID) -> Bool {
    guard authenticationGeneration == generation, isOAuth else { return false }
    secret = value; self.accountID = accountID; authenticatedAccountID = accountID
    signingIn = false; pendingSignInSave = true; problem = nil
    return true
  }
  func configuredConnection() throws -> InferenceConnection {
    if let saveProblem { throw DeviceExecutionError.unavailable(saveProblem) }
    let route: InferenceRoute = mode == .hosted ? .adapter : .direct
    return .init(id: original?.id ?? UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      provider: provider, accountID: mode == .device && !isOAuth ? "default" : accountID, route: route,
      baseURL: route == .adapter || isCustomServer ? endpoint.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
      modelID: modelID, hostScope: route == .adapter ? original?.hostScope : nil,
      selectedModel: models.first { $0.id == modelID && $0.provider == provider })
  }
}

private struct InferenceConnectionEditor: View {
  @Bindable var model: CompanionModel
  @Environment(\.dismiss) private var dismiss
  @State private var state: InferenceConnectionSetupState
  @State private var catalogTask: Task<Void, Never>?
  @State private var authenticationTask: Task<Void, Never>?
  @State private var saveTask: Task<Void, Never>?
  @State private var oauthSession: InferenceOAuthSession?
  @State private var challenge: InferenceOAuthChallenge?
  @State private var authorizationCode = ""
  @State private var completingSignIn = false
  @State private var loaded = false
  init(model: CompanionModel, connection: InferenceConnection?, provider: String = "openai-codex", hosted: Bool = false) {
    self.model = model
    let state = InferenceConnectionSetupState(connection: connection, provider: provider)
    if hosted { state.chooseMode(.hosted) }
    _state = State(initialValue: state)
  }
  private var setupAllowed: Bool { !model.fixture && !model.isolatedTestHost }
  private var signInName: String {
    switch state.provider { case "openai-codex": "ChatGPT"; case "claude-subscription": "Claude"; case "xai": "Grok"; default: InferenceConnectionSetupState.providerName(state.provider) }
  }
  var body: some View {
    Form {
      if !setupAllowed { Section { Text("Account setup is disabled in this test build.") } }
      else if state.mode == .hosted {
        Section {
          Picker("Provider", selection: Binding(get: { state.provider }, set: { chooseProvider($0) })) {
            ForEach(InferenceCatalog.providers.filter { provider in !provider.id.hasPrefix("local-server-") &&
              (!InferenceConnectionPolicy.isSingleSubscription(provider.id) || !model.inferenceConnections.contains(where: { $0.provider == provider.id && $0.id != state.original?.id })) }) { Text($0.name).tag($0.id) }
          }.disabled(state.original != nil)
        }
        hostedFields
        modelFields
      } else if state.isCustomServer {
        Section {
          TextField("Tailscale HTTPS address", text: $state.endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
          TextField("Model ID", text: $state.modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        apiKeyFields
      } else if state.isOAuth { subscriptionFields }
      else { apiKeyFields }
      if state.saving || state.pendingSignInSave && state.loadingModels { Section { ProgressView("Saving…") } }
      else if state.loadingModels && !state.isOAuth { Section { ProgressView() } }
      if let problem = state.problem {
        Section {
          Text(problem).foregroundStyle(DashboardPalette.danger)
          if state.modelID.isEmpty || state.pendingSignInSave {
            Button("Retry") { if state.modelID.isEmpty { loadModels(force: true) } else { save() } }.disabled(state.saving)
          }
        }
      }
    }.scrollIndicators(.never).mobileNavigationPage(state.mode == .hosted ? "Workspace account" : InferenceConnectionSetupState.providerName(state.provider))
      .toolbar {
        if !state.isOAuth {
          ToolbarItem(placement: .confirmationAction) {
            Button(state.saving ? "Saving…" : "Save") { save() }.disabled(!setupAllowed || state.saving || state.saveProblem != nil)
          }
        }
      }.task { await initialize() }
      .onDisappear { cancelAll() }
      .navigationBarBackButtonHidden(state.saving)
  }
  private var apiKeyFields: some View {
    Section {
      SecureField(state.storedCredentialAvailable ? "Replace API key" : "API key", text: $state.secret)
        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(state.saving)
    }
  }
  private var subscriptionFields: some View {
    Section {
      if let challenge {
        if let code = challenge.userCode { Text(code).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled) }
        Link("Open \(signInName) sign-in", destination: challenge.verificationURL)
        if challenge.kind == .authorizationCode {
          SecureField("Paste authorization code", text: $authorizationCode).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(completingSignIn)
          Button(completingSignIn ? "Finishing…" : "Complete sign-in") { completeAuthorizationCode() }
            .disabled(completingSignIn || authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else { ProgressView("Waiting for sign-in…") }
        Button("Cancel sign-in") { cancelSignIn() }
      } else if state.signingIn { ProgressView("Preparing sign-in…") }
      else if !state.pendingSignInSave {
        Button("Sign in with \(signInName)") { signIn() }.disabled(state.saving)
      }
    }
  }
  private var hostedFields: some View {
    Section("Workspace") {
      Picker("Host", selection: Binding(get: { state.hostID }, set: { chooseHost($0) })) {
        Text(state.hasSavedHost ? "Saved host" : "Choose an authorized workspace").tag("")
        ForEach(model.executionWorkspaces.filter { $0.endpoint != nil }) { Text($0.name).tag($0.id) }
      }
      if state.hostID.isEmpty && state.hasSavedHost { Text(state.endpoint).font(.caption).textSelection(.enabled) }
      Picker("Account", selection: $state.accountID) {
        Text("Choose an account").tag("")
        if !state.accountID.isEmpty && !state.accounts.contains(where: { $0.id == state.accountID && $0.provider == state.provider && $0.connected }) { Text(state.accountID).tag(state.accountID) }
        ForEach(state.accounts.filter { $0.provider == state.provider && $0.connected }) { Text($0.label).tag($0.id) }
      }
      Button("Refresh host connections") { loadHost() }.disabled(state.hostID.isEmpty || state.loadingModels)
    }.disabled(state.saving)
  }
  private var modelFields: some View {
    Section("Model") {
      if state.loadingModels { ProgressView(state.mode == .hosted ? "Loading host models and accounts…" : "Loading provider models…") }
      if !state.models.isEmpty {
        Picker("Model", selection: $state.modelID) {
          Text("Choose a model").tag("")
          ForEach(state.models) { Text($0.name).tag($0.id) }
        }
      } else if state.isCustomServer {
        TextField("Model ID", text: $state.modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
      } else if !state.loadingModels { Text("No models are loaded. Refresh the catalog to choose one.") }
      if state.mode == .device && !state.isCustomServer {
        Button("Refresh models") { loadModels(force: true) }.disabled(state.loadingModels)
      }
      if !state.modelID.isEmpty { Text(state.modelID).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
    }.disabled(!setupAllowed || state.saving)
  }
  private func initialize() async {
    guard !loaded else { return }; loaded = true
    guard setupAllowed else { return }
    if let original = state.original {
      let generation = state.authenticationGeneration
      do {
        let present = try await model.executionCredentialStore.read(connectionID: original.id) != nil
        guard !Task.isCancelled, state.authenticationGeneration == generation else { return }
        state.storedCredentialAvailable = present
      } catch { state.problem = "This device’s saved credential could not be opened. Enter it again to replace it." }
      if let scope = original.hostScope, model.executionWorkspaces.contains(where: { $0.id == scope.workspaceID }) { state.hostID = scope.workspaceID }
    }
    if state.mode == .device { loadModels() }
    else if !state.hostID.isEmpty && model.workspaceReachable[state.hostID] == true { loadHost() }
  }
  private func chooseProvider(_ id: String) {
    guard !state.saving else { return }
    cancelSignIn(); catalogTask?.cancel(); state.chooseProvider(id)
    loadModels()
  }
  private func chooseHost(_ id: String) {
    guard !state.saving else { return }
    catalogTask?.cancel(); state.hostID = id; state.models = []; state.accounts = []; state.modelID = ""; state.accountID = ""; state.endpoint = ""
    loadHost()
  }
  private func loadModels(force: Bool = false) {
    catalogTask?.cancel()
    guard setupAllowed else { return }
    if state.mode == .hosted { if !state.hostID.isEmpty { loadHost() }; return }
    guard state.definition?.supportsDirect == true, !state.isCustomServer else { state.loadingModels = false; return }
    let provider = state.provider, generation = state.beginCatalog()
    catalogTask = Task {
      let cached = await ProviderModelCatalog.shared.cached(provider: provider)
      guard !Task.isCancelled, state.catalogGeneration == generation else { return }
      if !cached.isEmpty { state.receiveModels(cached, generation: generation) }
      do {
        let fetched = try await ProviderModelCatalog.shared.load(provider: provider, force: force)
        guard !Task.isCancelled, state.catalogGeneration == generation else { return }
        state.receiveModels(fetched, generation: generation)
      } catch {
        guard !Task.isCancelled, state.catalogGeneration == generation else { return }
        state.problem = "Couldn’t refresh models."
      }
      state.loadingModels = false
      saveSignedInAccountWhenReady()
    }
  }
  private func loadHost() {
    catalogTask?.cancel()
    guard setupAllowed, state.mode == .hosted, !state.hostID.isEmpty else { state.loadingModels = false; return }
    let selectedHost = state.hostID, provider = state.provider, generation = state.beginCatalog()
    catalogTask = Task {
      do {
        let credential = try await model.authorizedWorkspaceCredential(selectedHost)
        let catalog = InferenceConnection(name: "Host catalog", provider: provider, accountID: "catalog", route: .adapter,
          baseURL: credential.endpoint.absoluteString, modelID: "catalog",
          hostScope: .init(libraryID: credential.executionLibraryID ?? credential.libraryID, workspaceID: credential.workspaceID, deviceID: credential.deviceID, protocolVersion: CompanionProtocol.version))
        let result = try await CompanionInferenceService(connection: catalog, credentials: InferenceSetupCredential(value: credential.token)).hostCatalog()
        guard !Task.isCancelled, state.catalogGeneration == generation else { return }
        state.endpoint = credential.endpoint.absoluteString
        // Older hosts may still advertise backup subscription accounts.
        state.accounts = InferenceConnectionPolicy.isSingleSubscription(provider)
          ? Array(result.accounts.filter { $0.provider == provider }.prefix(1)) : result.accounts
        state.receiveModels(result.models, generation: generation)
        let accounts = state.accounts.filter { $0.provider == provider && $0.connected }
        if !accounts.contains(where: { $0.id == state.accountID }) { state.accountID = accounts.count == 1 ? accounts[0].id : "" }
      } catch {
        guard !Task.isCancelled, state.catalogGeneration == generation else { return }
        state.problem = error.localizedDescription
      }
      state.loadingModels = false
    }
  }
  private func signIn() {
    guard setupAllowed, state.isOAuth, !state.saving else { return }
    cancelSignIn()
    let session = InferenceOAuthSession(), provider = state.provider
    let generation = state.authenticationGeneration
    oauthSession = session; state.signingIn = true; state.problem = nil
    authenticationTask = Task {
      do {
        let value = try await session.start(provider: provider)
        guard !Task.isCancelled, state.authenticationGeneration == generation else { await session.cancel(); return }
        challenge = value
        if value.kind == .authorizationCode { return }
        let credential = try await session.poll()
        guard !Task.isCancelled, state.authenticationGeneration == generation else { return }
        state.receiveCredential(try credential.serialized(), accountID: credential.accountID, generation: generation)
        challenge = nil; oauthSession = nil
        saveSignedInAccountWhenReady()
      } catch {
        guard !Task.isCancelled, state.authenticationGeneration == generation else { return }
        state.signingIn = false; challenge = nil; oauthSession = nil; state.problem = error.localizedDescription
      }
    }
  }
  private func completeAuthorizationCode() {
    guard setupAllowed, challenge?.kind == .authorizationCode, let session = oauthSession, !completingSignIn else { return }
    let code = authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines), generation = state.authenticationGeneration
    guard !code.isEmpty else { return }
    completingSignIn = true; state.problem = nil
    authenticationTask = Task {
      do {
        let credential = try await session.complete(code: code)
        guard !Task.isCancelled, state.authenticationGeneration == generation else { return }
        state.receiveCredential(try credential.serialized(), accountID: credential.accountID, generation: generation)
        authorizationCode = ""; challenge = nil; oauthSession = nil
        saveSignedInAccountWhenReady()
      } catch {
        guard !Task.isCancelled, state.authenticationGeneration == generation else { return }
        // The OAuth session consumes this challenge even if code exchange fails.
        // Clear it so a retry starts a fresh request instead of reusing a spent code.
        await session.cancel()
        guard !Task.isCancelled, state.authenticationGeneration == generation else { return }
        authorizationCode = ""; challenge = nil; oauthSession = nil; state.signingIn = false
        state.problem = error.localizedDescription
      }
      completingSignIn = false
    }
  }
  private func cancelSignIn() {
    state.authenticationGeneration = UUID(); authenticationTask?.cancel(); authenticationTask = nil
    if let session = oauthSession { Task { await session.cancel() } }
    oauthSession = nil; challenge = nil; authorizationCode = ""; completingSignIn = false; state.signingIn = false; state.pendingSignInSave = false
  }
  private func cancelAll() {
    catalogTask?.cancel(); saveTask?.cancel(); cancelSignIn(); state.invalidateRequests()
  }
  private func saveSignedInAccountWhenReady() {
    guard state.pendingSignInSave, !state.loadingModels, !state.saving else { return }
    guard !state.modelID.isEmpty else { state.problem = "Couldn’t load models."; return }
    save()
  }
  private func save() {
    guard setupAllowed, !state.saving else { return }
    let configured: InferenceConnection
    do { configured = try state.configuredConnection() }
    catch { state.problem = error.localizedDescription; return }
    let hostID = state.hostID, suppliedSecret = state.trimmedSecret
    state.saving = true; state.problem = nil
    saveTask = Task {
      do {
        var value = configured, secret = suppliedSecret
        if value.route == .adapter, !hostID.isEmpty {
          let credential = try await model.authorizedWorkspaceCredential(hostID)
          value.baseURL = credential.endpoint.absoluteString
          value.hostScope = .init(libraryID: credential.executionLibraryID ?? credential.libraryID, workspaceID: credential.workspaceID, deviceID: credential.deviceID, protocolVersion: CompanionProtocol.version)
          secret = credential.token
        }
        try Task.checkCancellation()
        try await model.saveInferenceConnection(value, secret: secret)
        guard !Task.isCancelled else { return }
        state.secret = ""; dismiss()
      } catch {
        guard !Task.isCancelled else { return }
        state.problem = error.localizedDescription
      }
      state.saving = false
    }
  }
}
