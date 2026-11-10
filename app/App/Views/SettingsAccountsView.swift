import SwiftUI
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// The one place for provider sign-ins and API keys. Pi Durable chats and usage limits
/// both read these accounts; native harnesses keep their own sign-in on their agent pages.
struct SettingsAccountsView: View {
    @Bindable var model: ApplicationModel
    var initialScope = "global"
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    var onBack: () -> Void
    @State private var scope = "global"
    @State private var connectedProvider: String?

    private var agent: DefaultAgentSettingsModel { model.connections }
    private var workspaces: [RemoteWorkspaceConfiguration] { model.remoteWorkspaces.workspaces }
    private var remote: RemoteWorkspaceConfiguration? {
        workspaces.first { $0.id.uuidString.lowercased() == scope }
    }
    private var scopeBinding: Binding<String> {
        Binding(get: { scope }, set: { scope = $0; selectScope($0) })
    }

    var body: some View {
        SettingsPage(
            title: "Subscriptions & API Keys",
            detail: "Used by Pi Durable and for usage limits. Codex, Claude Code, Grok Build, and OpenCode sign in on their own agent pages.",
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: backTitle,
            onBack: onBack
        ) {
            VStack(alignment: .leading, spacing: 2) {
                SettingsWorkspacePicker(title: "Accounts for", scope: scopeBinding, workspaces: workspaces)
                    .disabled(agent.busy)
                if scope != "global" {
                    SettingsNote("Accounts saved here take priority for each provider. Shared accounts fill in when none are saved here.")
                }
            }
            SettingsSection(title: "Model providers") {
                SettingsConnectionsView(model: model, focus: .providers, embedded: true,
                    onConnected: accountConnected, onManageShared: manageSharedAccounts)
                if let provider = connectedProvider {
                    SettingsRow(title: "Account added", detail: "Choose models if you also want to use it for chat.") {
                        Button("Choose chat models") {
                            model.pendingDefaultAgentModelProvider = provider
                            model.pendingDefaultAgentSettingsScope = agent.inherits ? "global" : scope
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                    }
                }
            }
            SettingsSection(title: "Web search", detail: "Pi Durable uses the selected provider.") {
                SettingsConnectionsView(model: model, focus: .webSearch, embedded: true, onManageShared: manageSharedAccounts)
                if agent.inherits {
                    SettingsNote("This workspace follows the provider chosen for All workspaces. To choose here, turn off Use shared chat settings on its Pi Durable page.")
                }
            }
            SettingsSection(title: "Local model servers") {
                LocalModelServerConnections(agent: agent)
            }
            SettingsHelp {
                SettingsNote("Signing in saves credentials in Apple Keychain and allows automatic limit checks. Some providers do not expose limits; those accounts link to the provider’s usage dashboard.")
                SettingsNote("API keys and Pi Durable’s ChatGPT and Grok sign-ins can be shared across workspaces. Claude requires a native sign-in on each machine. These connections do not sign in the standalone Codex, Claude Code, Grok Build, or OpenCode harnesses.")
                SettingsNote("Offline workspaces receive shared account changes when they reconnect.")
                SettingsNote("Exa and Firecrawl search the web and read pages. Brave returns search context; agents use the browser to read pages.")
            }
        }
        .task(id: initialScope) {
            scope = initialScope
            selectScope(initialScope)
        }
        .onDisappear { agent.cancel() }
    }

    private func selectScope(_ scope: String) {
        connectedProvider = nil
        agent.changeScope(scope)
        agent.loadAccounts()
        agent.loadCatalog(remote: remote, includeAllModels: false)
    }

    private func manageSharedAccounts() {
        scope = "global"
        selectScope("global")
    }

    private func accountConnected(_ id: String) {
        connectedProvider = id
        agent.loadCatalog(remote: remote, includeAllModels: false)
        guard scope == "global", let provider = ProviderKind.supportedAccounts.first(where: {
            UsageConnectionChoice.connectionTypes(for: $0).contains { $0.0 == id }
        }) else { return }
        Task { await model.enableUsageProvider(provider) }
    }
}

/// Used where a screen points at the single account list.
struct ManageAccountsLink: View {
    var body: some View {
        Button("Manage subscriptions and keys") {
            NotificationCenter.default.post(name: .init("wovenmatter.open-connections"), object: "global")
        }.buttonStyle(SettingsQuietButtonStyle())
    }
}
