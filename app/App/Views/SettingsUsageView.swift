import SwiftUI
import WovenMatterCore
import WovenMatterDashboardStore

struct SettingsUsageView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void
    @State private var connectedProvider: String?

    var body: some View {
        SettingsPage(title: "Usage", detail: "Sign in to see account limits. Device analytics needs no account setup.",
            reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            SettingsNote("Signing in saves credentials in Apple Keychain and allows automatic limit checks. Accounts are shared with Pi Durable; chat models stay as you selected them.")
            SettingsConnectionsView(model: model, focus: .providers, embedded: true,
                onConnected: accountConnected, onBack: {})
            if let provider = connectedProvider {
                HStack {
                    SettingsNote("Account added. Choose models if you also want to use it for chat.")
                    Button("Choose chat models") {
                        model.pendingDefaultAgentModelProvider = provider
                        model.pendingDefaultAgentSettingsScope = "global"
                    }.buttonStyle(SettingsQuietButtonStyle())
                }
            }
            SettingsNote("Some providers do not expose limits. Those accounts link to the provider’s usage dashboard.")
        }
        .task { model.connections.changeScope("global"); model.connections.loadAccounts() }
        .onDisappear { model.connections.cancel() }
    }

    private func accountConnected(_ id: String) {
        connectedProvider = id
        guard let provider = ProviderKind.supportedAccounts.first(where: {
            UsageConnectionChoice.connectionTypes(for: $0).contains { $0.0 == id }
        }) else { return }
        Task { await model.enableUsageProvider(provider) }
    }
}

struct UsageSettingsLink: View {
    var body: some View {
        Button("Go to Usage settings") {
            NotificationCenter.default.post(name: .init("wovenmatter.open-usage-settings"), object: nil)
        }.buttonStyle(SettingsQuietButtonStyle())
    }
}
