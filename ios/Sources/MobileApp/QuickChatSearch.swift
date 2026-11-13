import SwiftUI
import MobileInference

extension MobileModel {
  func performQuickChatSearch(_ arguments: [String: Any], conversationID: String, reading: Bool = false) async throws -> String {
    guard !fixture, !isolatedTestHost else { throw QuickChatSearchError.unconfigured }
    let service = try await QuickChatWebSearch.service(reading: reading, credentials: executionCredentialStore,
      preferred: deviceAgentDefaults.webSearchProvider, transport: searchTransport)
    let result: String
    if reading {
      guard let address = arguments["url"] as? String else { throw QuickChatSearchError.invalidURL }
      result = try await service.read(address)
    } else {
      guard let query = arguments["query"] as? String else { throw QuickChatSearchError.invalidQuery }
      let limit = (arguments["numResults"] as? NSNumber)?.intValue ?? 5
      result = try await service.search(query, limit: limit)
      quickChatSearchResults[conversationID, default: []].formUnion(QuickChatWebReadProvenance.resultURLs(result))
    }
    return try Self.toolJSON(["content": [["type": "text", "text": result]]])
  }
}

extension MobileModel {
  /// Addresses from the user's own messages, including the pending prompt, or from this chat's searches.
  func quickChatWebReadExpected(_ address: String, conversationID: String) -> Bool {
    let userMessages = (state.transcripts[conversationID]?.messages ?? []).filter { $0.role == "user" }.map(\.content)
      + [executionRecords[conversationID]?.pendingInput].compactMap { $0 }
    return QuickChatWebReadProvenance.isExpected(address, userMessages: userMessages, searchResults: quickChatSearchResults[conversationID] ?? [])
  }
}

/// Web search connections on this device. Keys are device-only Keychain items,
/// saved like the model connections; adding one is the user's choice to use it.
struct QuickChatSearchSettingsPane: View {
  @Bindable var model: MobileModel
  @State private var connected: Set<QuickChatSearchProvider> = []
  @State private var problem: String?
  private var preferred: Binding<String> {
    Binding(get: { model.deviceAgentDefaults.webSearchProvider ?? QuickChatSearchProvider.allCases.first(where: connected.contains)?.rawValue ?? "" },
      set: { value in
        var defaults = model.deviceAgentDefaults; defaults.webSearchProvider = value
        do { try model.saveDeviceAgentDefaults(defaults, connectionID: model.inferenceConnectionID); problem = nil }
        catch { problem = error.localizedDescription }
      })
  }
  var body: some View {
    List {
      Section {
        ForEach(QuickChatSearchProvider.allCases) { provider in
          NavigationLink { QuickChatSearchKeyEditor(model: model, provider: provider) { connected = await load() } } label: {
            HStack {
              Text(provider.name)
              Spacer()
              Text(connected.contains(provider) ? "Connected" : "Not connected").font(.callout).foregroundStyle(WovenPalette.mutedForeground)
            }
          }.accessibilityIdentifier("search-provider-" + provider.rawValue)
        }
      } footer: {
        Text("Quick Chat searches the web with a connected provider. Brave Search can search but not read webpages.")
      }
      if connected.count > 1 {
        Section {
          Picker("Use for web search", selection: preferred) {
            ForEach(QuickChatSearchProvider.allCases.filter(connected.contains)) { Text($0.name).tag($0.rawValue) }
          }
        }
      }
      if let problem { Section { Text(problem).foregroundStyle(WovenPalette.danger) } }
    }.listStyle(.insetGrouped).scrollContentBackground(.hidden).scrollIndicators(.never).mobileNavigationPage("Web search")
      .task { connected = await load() }
  }
  private func load() async -> Set<QuickChatSearchProvider> {
    guard !model.fixture, !model.isolatedTestHost else { return [] }
    return Set(await QuickChatWebSearch.connected(credentials: model.executionCredentialStore))
  }
}

private struct QuickChatSearchKeyEditor: View {
  @Bindable var model: MobileModel
  let provider: QuickChatSearchProvider
  let changed: () async -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var key = ""
  @State private var configured = false
  @State private var saving = false
  @State private var problem: String?
  private var setupAllowed: Bool { !model.fixture && !model.isolatedTestHost }
  var body: some View {
    Form {
      if !setupAllowed { Section { Text("Account setup is disabled in this test build.") } }
      else {
        Section {
          SecureField(configured ? "Replace API key" : "API key", text: $key)
            .wovenInput().textInputAutocapitalization(.never).autocorrectionDisabled().disabled(saving)
        } footer: {
          Text(provider.canRead ? "The key stays on this device." : "The key stays on this device. Brave Search can search but not read webpages.")
        }
        if configured { Section { Button("Remove \(provider.name)", role: .destructive) { save(remove: true) }.disabled(saving) } }
      }
      if let problem { Section { Text(problem).foregroundStyle(WovenPalette.danger) } }
    }.scrollIndicators(.never).mobileNavigationPage(provider.name)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(saving ? "Saving…" : "Save") { save(remove: false) }
            .disabled(!setupAllowed || saving || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .task {
        guard setupAllowed else { return }
        do { configured = try await model.executionCredentialStore.read(connectionID: provider.credentialID) != nil }
        catch { problem = "This device’s saved key could not be opened. Enter it again to replace it." }
      }
      .navigationBarBackButtonHidden(saving)
  }
  private func save(remove: Bool) {
    guard setupAllowed, !saving else { return }
    saving = true; problem = nil
    Task {
      defer { saving = false }
      do {
        if remove { try await model.executionCredentialStore.remove(connectionID: provider.credentialID) }
        else { try await model.executionCredentialStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), connectionID: provider.credentialID) }
        key = ""; configured = !remove
        await changed()
        dismiss()
      } catch { problem = error.localizedDescription }
    }
  }
}
