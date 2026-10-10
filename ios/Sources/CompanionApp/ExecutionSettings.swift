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

private struct InferenceConnectionEditor: View {
  @Bindable var model: CompanionModel
  let connection: InferenceConnection?
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var provider = "openai"
  @State private var modelID = ""
  @State private var accountID = "default"
  @State private var endpoint = ""
  @State private var secret = ""
  @State private var saving = false
  @State private var problem: String?
  @State private var models: [InferenceModel] = []
  @State private var hostID = ""
  @State private var accounts: [InferenceHostAccount] = []
  @State private var loadingHost = false
  private var definition: InferenceProvider? { InferenceCatalog.providers.first { $0.id == provider } }
  var body: some View {
    NavigationStack {
      Form {
        Section("Connection") {
          TextField("Name", text: $name)
          Picker("Provider", selection: $provider) {
            ForEach(InferenceCatalog.providers) { item in Text(item.name).tag(item.id) }
          }.disabled(connection != nil)
        }
        Section("Model") {
          if !models.isEmpty {
            Picker("Model", selection: $modelID) {
              Text("Choose a model").tag("")
              ForEach(models) { item in Text(item.name).tag(item.id) }
            }
          } else {
            TextField("Model ID", text: $modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
          }
        }
        if definition?.defaultRoute == .adapter {
          Section("Inference host") {
            Picker("Host", selection: $hostID) {
              Text("Choose an authorized workspace").tag("")
              ForEach(model.executionWorkspaces.filter { $0.endpoint != nil }) { workspace in Text(workspace.name).tag(workspace.id) }
            }
            if loadingHost { ProgressView("Loading accounts and models…") }
            Picker("Account", selection: $accountID) {
              Text("Choose an account").tag("")
              ForEach(accounts.filter { $0.provider == provider && $0.connected }) { account in Text(account.label).tag(account.id) }
            }
            Button("Refresh host connections") { loadHost() }.disabled(hostID.isEmpty || loadingHost)
            Text("Uses this host’s existing subscription for inference. Device access comes from your paired central library. Pi Durable and its tools continue to run on this iPhone or iPad.")
          }
        } else {
          if provider.hasPrefix("local-server-") {
            Section("Model server") {
              TextField("Tailscale HTTPS address", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
              Text("Use a Tailscale HTTPS server with the Responses API and an API key. Only inference runs there; agents and tools stay on this device.")
            }
          }
          Section("API key") {
            SecureField(connection == nil ? "API key" : "Replace API key (optional)", text: $secret)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
            Text("Stored in this device’s Keychain. Keys are never included in library synchronization.")
          }
        }
        if let problem { Section { Text(problem).foregroundStyle(.red) } }
      }.scrollIndicators(.never).navigationTitle(connection == nil ? "Add connection" : "Edit connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
          ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") { save() }.disabled(saving || loadingHost || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || modelID.isEmpty) }
        }.task {
          if let connection {
            name = connection.name; provider = connection.provider; modelID = connection.modelID
            accountID = connection.accountID; endpoint = connection.baseURL ?? ""
          }
          if let endpoint = connection?.baseURL { hostID = model.executionWorkspaces.first { $0.endpoint?.absoluteString == endpoint }?.id ?? "" }
          updateModels()
        }.onChange(of: provider) { _, _ in modelID = ""; accountID = ""; updateModels(); if definition?.defaultRoute == .adapter { loadHost() } }
        .onChange(of: hostID) { previous, _ in
          if !previous.isEmpty { models = []; accounts = []; modelID = ""; accountID = ""; endpoint = "" }
          if !hostID.isEmpty { loadHost() }
        }
    }
  }
  private func updateModels() {
    models = definition?.defaultRoute == .adapter ? [] : (try? InferenceCatalog.models(provider: provider)) ?? []
    if definition?.defaultRoute != .adapter { accountID = "default" }
  }
  private func loadHost() {
    guard !hostID.isEmpty, !loadingHost else { return }
    let selectedHost = hostID, selectedProvider = provider
    loadingHost = true; problem = nil
    Task {
      do {
        let credential = try await model.authorizedWorkspaceCredential(selectedHost)
        let catalogID = "catalog-" + selectedHost
        try await model.executionCredentialStore.save(credential.token, connectionID: catalogID)
        let connection = InferenceConnection(id: catalogID, name: "Host catalog", provider: selectedProvider, accountID: "catalog", route: .adapter, baseURL: credential.endpoint.absoluteString, modelID: "catalog", hostScope: .init(libraryID: credential.libraryID, workspaceID: credential.workspaceID, deviceID: credential.deviceID, protocolVersion: CompanionProtocol.version))
        let catalog = try await CompanionInferenceService(connection: connection, credentials: model.executionCredentialStore).hostCatalog()
        guard hostID == selectedHost && provider == selectedProvider else { loadingHost = false; loadHost(); return }
        endpoint = credential.endpoint.absoluteString
        models = catalog.models.filter { $0.provider == selectedProvider }; accounts = catalog.accounts
      } catch { problem = error.localizedDescription }
      loadingHost = false
    }
  }
  private func save() {
    saving = true; problem = nil
    let value = InferenceConnection(id: connection?.id ?? UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      provider: provider, accountID: accountID, route: definition?.defaultRoute ?? .direct,
      baseURL: endpoint.isEmpty ? nil : endpoint, modelID: modelID)
    Task {
      do {
        var configured = value
        let valueSecret: String
        if value.route == .adapter {
          let credential = try await model.authorizedWorkspaceCredential(hostID)
          configured.baseURL = credential.endpoint.absoluteString
          configured.hostScope = .init(libraryID: credential.libraryID, workspaceID: credential.workspaceID, deviceID: credential.deviceID, protocolVersion: CompanionProtocol.version)
          valueSecret = credential.token
        } else { valueSecret = secret }
        try await model.saveInferenceConnection(configured, secret: valueSecret); secret = ""; dismiss()
      }
      catch { problem = error.localizedDescription }
      saving = false
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
