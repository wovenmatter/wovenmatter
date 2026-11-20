import SwiftUI

/// The one place for provider sign-ins and API keys. Each machine keeps its own; this
/// page manages the selected machine's. Native harnesses keep their own sign-in on
/// their agent pages.
struct SettingsAccountsView: View {
    @Bindable var model: ApplicationModel
    /// A machine ID, or "global" for this Mac.
    var initialScope = "global"
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    var onBack: () -> Void
    @State private var machineID: String?
    @State private var connectedProvider: String?

    private var agent: AgentSettingsStore { model.connections }
    private var machine: Machine? { machineID.flatMap { model.machines.machine(id: $0) } }
    /// The chat-settings scope whose web search choice this page edits: this Mac's
    /// is the one for every machine; another machine's is its own.
    private var searchScope: String {
        guard let machineID, machineID != model.thisMachineID else { return "global" }
        return machineID
    }

    var body: some View {
        SettingsPage(
            title: "Subscriptions & API Keys",
            detail: SignInMachinePicker.pageDetail,
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: backTitle,
            onBack: onBack
        ) {
            SettingsRow(title: SignInMachinePicker.title) {
                SettingsPicker(SignInMachinePicker.title,
                               selection: Binding(get: { machineID ?? "" }, set: { select($0) }),
                               options: SignInMachinePicker.options(model.machines.machines, selected: machineID)) { id in
                    SignInMachinePicker.label(id, machines: model.machines.machines, botsHome: model.bots.homeMachineID)
                }
            }
            .disabled(agent.busy)
            SettingsSection(title: "Model providers") {
                SettingsConnectionsView(model: model, machineID: machineID, focus: .providers, embedded: true,
                                        onConnected: accountConnected)
                if let provider = connectedProvider {
                    SettingsRow(title: "Account added", detail: "Choose models if you also want to use it for chat.") {
                        Button("Choose chat models") {
                            model.navigation.pendingDefaultAgentModelProvider = provider
                            model.navigation.pendingDefaultAgentSettingsScope = agent.inherits ? "global" : agent.scope
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                    }
                }
            }
            SettingsSection(title: "Web search", detail: "Pi Durable uses the selected provider.") {
                SettingsConnectionsView(model: model, machineID: machineID, focus: .webSearch, embedded: true)
                if agent.inherits {
                    SettingsNote("This workspace follows the provider chosen for All workspaces. To choose here, turn off Use shared chat settings on its Pi Durable page.")
                }
            }
            SettingsSection(title: "Local model servers") {
                LocalModelServerConnections(agent: agent, machineID: machineID)
                    .id(machineID)
            }
            SettingsHelp {
                if machine?.platform == .mac {
                    SettingsNote("Signing in saves credentials in Apple Keychain and allows automatic limit checks. Some providers do not expose limits; those accounts link to the provider’s usage dashboard.")
                }
                SettingsNote("Claude requires a native sign-in on each machine. These connections do not sign in the standalone Codex, Claude Code, Grok Build, or OpenCode harnesses.")
                SettingsNote("Exa and Firecrawl search the web and read pages. Brave returns search context; agents use the browser to read pages.")
            }
        }
        .task(id: initialScope) { select(initialScope == "global" ? model.thisMachineID ?? "" : initialScope) }
        .onDisappear { agent.cancel() }
    }

    private func select(_ id: String) {
        connectedProvider = nil
        machineID = id.isEmpty ? nil : id
        agent.changeScope(searchScope)
        agent.loadAccounts(on: machineID)
    }

    private func accountConnected(_ id: String) {
        connectedProvider = id
        agent.loadCatalog(includeAllModels: false)
    }
}

/// Settings → Subscriptions & API Keys' "Sign in on" picker: this Mac, then the
/// other machines, each by name.
enum SignInMachinePicker {
    static let title = "Sign in on"
    static let pageDetail = "Used by Pi Durable and bots on the selected device. Codex, Claude Code, Grok Build, and OpenCode sign in on their own pages. Usage limits shows the accounts signed in on this device."
    /// Marks the machine whose bots use its sign-ins.
    static let botsMark = "Bots"

    /// Machine IDs in picker order. A selected machine stays listed while the list loads.
    static func options(_ machines: [Machine], selected: String?) -> [String] {
        var ids = machines.map(\.id)
        if let selected, !ids.contains(selected) { ids.append(selected) }
        return ids.isEmpty ? [""] : ids
    }

    static func label(_ id: String, machines: [Machine], botsHome: String?) -> String {
        guard let machine = machines.first(where: { $0.id == id }) else { return "Local workspace" }
        let name = machine.isThisMachine ? "Local workspace (\(machine.name))" : machine.name
        return machine.id == botsHome ? "\(name) · \(botsMark)" : name
    }
}

/// Used where a screen points at the account list: this Mac's, or another machine's.
struct ManageAccountsLink: View {
    /// nil is this Mac.
    var machineID: String? = nil
    var body: some View {
        Button("Manage subscriptions and keys") {
            NotificationCenter.default.post(name: .init("wovenmatter.open-connections"), object: machineID ?? "global")
        }.buttonStyle(SettingsQuietButtonStyle())
    }
}
