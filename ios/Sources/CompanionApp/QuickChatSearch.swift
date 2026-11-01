import SwiftUI
import CompanionInference

extension CompanionModel {
  func performQuickChatSearch(_ arguments: [String: Any], conversationID: String, reading: Bool = false) async throws -> String {
    guard !fixture, !isolatedTestHost else { throw QuickChatSearchError.unconfigured }
    let service = QuickChatWebSearch(credentials: executionCredentialStore, sharing: dataSharingPolicy)
    let result: String
    if reading {
      guard let address = arguments["url"] as? String else { throw QuickChatSearchError.invalidURL }
      result = try await service.read(address)
    } else {
      guard let query = arguments["query"] as? String else { throw QuickChatSearchError.invalidQuery }
      result = try await service.search(query)
      quickChatSearchResults[conversationID, default: []].formUnion(QuickChatWebReadProvenance.resultURLs(result))
    }
    return try Self.toolJSON(["content": [["type": "text", "text": result]]])
  }
}

extension CompanionModel {
  /// Addresses from the user's own messages, including the pending prompt, or from this chat's searches.
  func quickChatWebReadExpected(_ address: String, conversationID: String) -> Bool {
    let userMessages = (state.transcripts[conversationID]?.messages ?? []).filter { $0.role == "user" }.map(\.content)
      + [executionRecords[conversationID]?.pendingInput].compactMap { $0 }
    return QuickChatWebReadProvenance.isExpected(address, userMessages: userMessages, searchResults: quickChatSearchResults[conversationID] ?? [])
  }
}

struct QuickChatSearchSettingsPane: View {
  @Bindable var model: CompanionModel
  @State private var key = ""
  @State private var configured = false
  @State private var saving = false
  @State private var problem: String?
  var body: some View {
    Form {
      Section("Exa") {
        Text(configured ? "Web search is configured." : "Add a search connection to use web search in Quick Chat.")
          .font(.callout).foregroundStyle(.secondary)
        SecureField(configured ? "Replacement API key" : "API key", text: $key)
          .dashboardInput().textInputAutocapitalization(.never).autocorrectionDisabled()
        Button("Save") { save(remove: false) }.disabled(saving || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if configured { Button("Remove search connection", role: .destructive) { save(remove: true) }.disabled(saving) }
      }
      Section("Permission") {
        Text(DataSharingDestination.exa.sharedData).font(.callout).foregroundStyle(.secondary)
        if model.dataSharing.permits(.exa) {
          Text("Allowed").font(.callout.weight(.medium))
          Button("Stop sharing with Exa", role: .destructive) { setSharing(false) }
        } else {
          Text("Not allowed. Quick Chat asks before its first web search or page read.").font(.callout)
          Button("Allow sharing with Exa") { setSharing(true) }.disabled(!configured)
        }
      }
      Section { Text("The key stays on this device. Results may be included in the selected model’s context. Mac and Linux workspace connections continue to use Tailscale.").font(.caption).foregroundStyle(.secondary) }
      if let problem { Text(problem).foregroundStyle(DashboardPalette.danger) }
    }.mobileNavigationPage("Web search")
      .task { do { configured = try await model.executionCredentialStore.read(connectionID: QuickChatWebSearch.credentialID) != nil } catch { problem = error.localizedDescription } }
  }
  private func setSharing(_ allowed: Bool) {
    do { try model.setDataSharing(.exa, allowed: allowed); problem = nil } catch { problem = error.localizedDescription }
  }
  private func save(remove: Bool) {
    saving = true; problem = nil
    Task {
      defer { saving = false }
      do {
        guard !model.fixture, !model.isolatedTestHost else { throw QuickChatSearchError.unconfigured }
        if remove { try await model.executionCredentialStore.remove(connectionID: QuickChatWebSearch.credentialID) }
        else { try await model.executionCredentialStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), connectionID: QuickChatWebSearch.credentialID) }
        configured = !remove; key = ""
      } catch { problem = error.localizedDescription }
    }
  }
}
