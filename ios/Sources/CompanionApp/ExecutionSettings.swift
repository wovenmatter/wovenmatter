import SwiftUI
import CompanionInference
import CompanionClient
import WovenMatterCompanion

struct ExecutionSettingsPane: View {
  @Bindable var model: CompanionModel
  @Environment(\.dashboardTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var editing: InferenceConnection?
  @State private var adding = false
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          GroupLabel(text: "This device")
          VStack(alignment: .leading, spacing: 8) {
            Label("Pi Durable", systemImage: "iphone.gen3").font(.headline)
            Text("Agents and tools run on \(model.deviceWorkspaceName.lowercased()). Inference uses a cloud provider or a host on Tailscale. Notes and saved outputs sync with your central library.")
              .font(.subheadline).foregroundStyle(DashboardPalette.mutedForeground)
            Text("Progress is saved during execution. If iOS interrupts a run, reopen its conversation to resume.")
              .font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius))
          GroupLabel(text: "Inference connections")
          ForEach(model.inferenceConnections) { connection in
            WorkspaceRow(icon: .settings, title: connection.name, detail: connection.modelID) { editing = connection }
          }
          WorkspaceRow(icon: .plus, title: "Add inference connection") { adding = true }
          if let problem = model.inferenceProblem { Text(problem).font(.caption).foregroundStyle(DashboardPalette.mutedForeground).padding(.horizontal, 14) }
          GroupLabel(text: "Execution workspaces")
          WorkspaceRow(systemIcon: "iphone.gen3", title: model.deviceWorkspaceName, detail: "Pi Durable · on device") { dismiss(); model.newChat(); model.selectExecutionWorkspace("local") }
          if model.credential != nil {
            WorkspaceRow(systemIcon: "laptopcomputer", title: "Central Mac", detail: model.online ? "Available" : "Unavailable") { dismiss(); model.newChat(); model.selectExecutionWorkspace("central") }
          }
          ForEach(model.executionWorkspaces) { workspace in
            WorkspaceRow(systemIcon: workspace.kind == .ios ? "iphone.gen3" : "server.rack", title: workspace.name,
              detail: model.workspaceClients[workspace.id] == nil ? "Connect through your central library to authorize" : model.workspaceReachable[workspace.id] == true ? "Available over Tailscale" : "Unavailable") {
              dismiss(); model.newChat(); model.selectExecutionWorkspace(workspace.id)
            }
            if let problem = model.workspaceProblems[workspace.id] {
              Text(problem).font(.caption).foregroundStyle(DashboardPalette.mutedForeground).padding(.horizontal, 14)
              Button("Refresh device access") { Task { await model.renewWorkspaceAccess(workspace.id) } }
                .buttonStyle(DashboardQuietButtonStyle()).disabled(!model.online)
            }
          }
          Text("A workspace owns its running agents and working files. Your central Mac stores the shared app library and saved artifacts.")
            .font(.caption).foregroundStyle(DashboardPalette.mutedForeground).padding(14)
        }.padding(18)
      }.scrollIndicators(.never).navigationTitle("Agents and workspaces").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(isPresented: $adding) { InferenceConnectionEditor(model: model, connection: nil) }
        .sheet(item: $editing) { connection in InferenceConnectionEditor(model: model, connection: connection) }
    }.tint(theme.palette.themeAccent)
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
    signingIn = false; problem = nil; invalidateRequests()
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
    signingIn = false; problem = nil
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
  init(model: CompanionModel, connection: InferenceConnection?) {
    self.model = model
    _state = State(initialValue: InferenceConnectionSetupState(connection: connection))
  }
  private var setupAllowed: Bool { !model.fixture && !model.isolatedTestHost }
  private var signInName: String {
    switch state.provider { case "openai-codex": "ChatGPT"; case "claude-subscription": "Claude"; case "xai": "Grok"; default: InferenceConnectionSetupState.providerName(state.provider) }
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("Connection") {
          Picker("Provider", selection: Binding(get: { state.provider }, set: chooseProvider)) {
            ForEach(InferenceCatalog.providers) { item in Text(item.name).tag(item.id) }
          }.disabled(state.original != nil || state.saving)
          TextField("Name", text: $state.name).disabled(state.saving)
          if state.mode == .device {
            Text("Saved on this device. A Mac, paired library, and inference host are not required.")
          }
        }
        if !setupAllowed {
          Section { Text("Connection setup is available in the regular app. Preview and test modes do not access accounts or credentials.") }
        } else if state.mode == .hosted { hostedFields }
        else if state.definition?.supportsDirect != true {
          Section("Sign-in unavailable") {
            Text("This subscription does not support sign-in in this app. You can use the provider’s API-key connection on this device.")
          }
        } else if state.isOAuth { subscriptionFields }
        else { apiKeyFields }
        if state.mode == .hosted || state.definition?.supportsDirect == true { modelFields }
        Section {
          Picker("Inference location", selection: Binding(get: { state.mode }, set: chooseMode)) {
            ForEach(InferenceSetupMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
          }.disabled(state.saving)
          Text("An inference host is optional. Choose it only to use an account already configured on an authorized Tailscale workspace.")
        } header: { Text("Advanced") }
        if let problem = state.problem { Section { Text(problem).foregroundStyle(.red) } }
        if !state.saving, let hint = state.saveProblem { Section { Text(hint).foregroundStyle(DashboardPalette.mutedForeground) } }
      }.scrollIndicators(.never).navigationTitle(state.original == nil ? "Add connection" : "Edit connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancelAll(); dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button(state.saving ? "Saving…" : "Save") { save() }.disabled(!setupAllowed || state.saving || state.saveProblem != nil)
          }
        }.task { await initialize() }
        .onDisappear { cancelAll() }
        .interactiveDismissDisabled(state.saving)
    }
  }
  private var apiKeyFields: some View {
    Group {
      if state.isCustomServer {
        Section("Model server") {
          TextField("Tailscale HTTPS address", text: $state.endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
          Text("Use a Tailscale server with the Responses API and an API key. Agents and tools still run on this device.")
        }.disabled(state.saving)
      }
      Section("API key") {
        SecureField(state.storedCredentialAvailable ? "Replace API key (optional)" : "Paste API key", text: $state.secret)
          .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(state.saving)
        if state.storedCredentialAvailable { Label("API key saved on this device", systemImage: "checkmark.circle") }
        Text("Use your \(InferenceConnectionSetupState.providerName(state.provider)) API key. It stays in this device’s Keychain and is never included in library sync.")
      }
    }
  }
  private var subscriptionFields: some View {
    Section("Sign in on this device") {
      if state.authenticatedAccountID != nil || state.storedCredentialAvailable {
        Label("Signed in on this device", systemImage: "checkmark.circle")
        if !state.accountID.isEmpty { Text(state.accountID).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
      }
      if let challenge {
        if let code = challenge.userCode {
          Text("Enter this code when asked:")
          Text(code).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
        }
        Link("Open \(signInName) sign-in", destination: challenge.verificationURL)
        if challenge.kind == .authorizationCode {
          Text("Finish sign-in with \(signInName), then copy the authorization code back into this app.")
          SecureField("Paste authorization code", text: $authorizationCode).textInputAutocapitalization(.never).autocorrectionDisabled()
            .disabled(completingSignIn)
          Button(completingSignIn ? "Finishing sign-in…" : "Complete sign-in") { completeAuthorizationCode() }
            .disabled(completingSignIn || authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else { ProgressView("Waiting for you to finish sign-in…") }
        Text("This sign-in request expires \(challenge.expiresAt, style: .relative).")
        Button("Cancel sign-in") { cancelSignIn() }
      } else if state.signingIn { ProgressView("Preparing sign-in…") }
      else {
        Button(state.storedCredentialAvailable || state.authenticatedAccountID != nil ? "Sign in with another account" : "Sign in with \(signInName)") { signIn() }
          .disabled(state.saving)
      }
      Text("You complete sign-in with the provider. Credentials stay in this device’s Keychain; inference connects directly from this device.")
    }
  }
  private var hostedFields: some View {
    Section("Optional inference host") {
      Picker("Host", selection: Binding(get: { state.hostID }, set: chooseHost)) {
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
      if model.credential == nil { Text("Pair with your central library to authorize a host. Device connections above work independently of pairing.") }
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
  private func chooseMode(_ mode: InferenceSetupMode) {
    guard !state.saving else { return }
    cancelSignIn(); catalogTask?.cancel(); state.chooseMode(mode)
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
        state.problem = "Models could not be refreshed. Check your connection and try Refresh models. Any saved selection remains available."
      }
      state.loadingModels = false
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
          hostScope: .init(libraryID: credential.libraryID, workspaceID: credential.workspaceID, deviceID: credential.deviceID, protocolVersion: CompanionProtocol.version))
        let result = try await CompanionInferenceService(connection: catalog, credentials: InferenceSetupCredential(value: credential.token)).hostCatalog()
        guard !Task.isCancelled, state.catalogGeneration == generation else { return }
        state.endpoint = credential.endpoint.absoluteString
        state.accounts = result.accounts
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
    oauthSession = nil; challenge = nil; authorizationCode = ""; completingSignIn = false; state.signingIn = false
  }
  private func cancelAll() {
    catalogTask?.cancel(); saveTask?.cancel(); cancelSignIn(); state.invalidateRequests()
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
          value.hostScope = .init(libraryID: credential.libraryID, workspaceID: credential.workspaceID, deviceID: credential.deviceID, protocolVersion: CompanionProtocol.version)
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

struct ExecutionWorkspaceMenu: View {
  @Bindable var model: CompanionModel
  var body: some View {
    Menu {
      Button(model.deviceWorkspaceName) { model.selectExecutionWorkspace("local") }
      if model.credential != nil || model.fixture { Button("Central Mac") { model.selectExecutionWorkspace("central") } }
      ForEach(model.executionWorkspaces) { workspace in
        Button(workspace.name) { model.selectExecutionWorkspace(workspace.id) }
      }
      Divider()
      Button("Manage workspaces and inference") { model.executionSettingsPresented = true }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: model.selectedExecutionWorkspaceID == "local" ? "iphone.gen3" : "server.rack")
        Text(model.executionName)
        DashboardLucideIcon(glyph: .chevronDown, size: 12)
      }.font(.caption).frame(minHeight: 44)
    }.disabled(model.selectedConversationID != nil).accessibilityLabel("Execution workspace: " + model.executionName)
  }
}
