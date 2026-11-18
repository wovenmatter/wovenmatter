import SwiftUI
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore

/// The one place for provider sign-ins and API keys. Each device keeps its own; this
/// page manages the selected device's. Native harnesses keep their own sign-in on
/// their agent pages.
struct SettingsAccountsView: View {
    @Bindable var model: ApplicationModel
    /// A device ID (`SignInDevice.id`) or a chat-settings scope (`global`, `local`, a workspace UUID).
    var initialScope = SignInDevice.localID
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    var onBack: () -> Void
    @State private var connectedProvider: String?

    /// This page's own model: the device chosen here never reaches other views.
    private var agent: DefaultAgentSettingsModel { model.signInConnections }
    private var deviceBinding: Binding<String> {
        Binding(get: { agent.device }, set: { select($0) })
    }

    var body: some View {
        SettingsPage(
            title: "Subscriptions & API Keys",
            detail: SignInDevicePicker.pageDetail,
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: backTitle,
            onBack: onBack
        ) {
            SettingsRow(title: SignInDevicePicker.title) {
                SettingsPicker(SignInDevicePicker.title, selection: deviceBinding,
                               options: SignInDevicePicker.options(agent.devices, selected: agent.device)) { id in
                    SignInDevicePicker.label(id, devices: agent.devices, fallbackName: fallbackName)
                }
            }
            .disabled(agent.busy)
            SettingsSection(title: "Model providers") {
                SettingsConnectionsView(model: model, connections: agent, focus: .providers, embedded: true, onConnected: accountConnected)
                if let provider = connectedProvider, SignInDevice.kind(of: agent.device) != .mac {
                    SettingsRow(title: "Account added", detail: "Choose models if you also want to use it for chat.") {
                        Button("Choose chat models") {
                            model.pendingDefaultAgentModelProvider = provider
                            model.pendingDefaultAgentSettingsScope = agent.inherits ? "global" : agent.scope
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                    }
                }
            }
            SettingsSection(title: "Web search", detail: "Pi Durable uses the selected provider.") {
                SettingsConnectionsView(model: model, connections: agent, focus: .webSearch, embedded: true)
                if agent.inherits {
                    SettingsNote("This workspace follows the provider chosen for All workspaces. To choose here, turn off Use shared chat settings on its Pi Durable page.")
                }
            }
            SettingsSection(title: "Local model servers") {
                LocalModelServerConnections(agent: agent)
                    .id(agent.device)
            }
            SettingsHelp {
                if agent.device == SignInDevice.localID {
                    SettingsNote("Signing in saves credentials in Apple Keychain and allows automatic limit checks. Some providers do not expose limits; those accounts link to the provider’s usage dashboard.")
                }
                SettingsNote("Claude requires a native sign-in on each machine. These connections do not sign in the standalone Codex, Claude Code, Grok Build, or OpenCode harnesses.")
                SettingsNote("Exa and Firecrawl search the web and read pages. Brave returns search context; agents use the browser to read pages.")
            }
        }
        .task(id: initialScope) { select(SignInDevicePicker.device(forPage: initialScope)) }
        .onDisappear { agent.cancel(); SignInDevicePicker.leave(agent) }
    }

    /// A device the list has not loaded yet: a configured workspace's or a bots machine's name.
    private func fallbackName(_ id: String) -> String? {
        if let workspace = SignInDevice.linuxWorkspace(of: id) {
            return model.remoteWorkspaces.workspaces.first { $0.id == workspace }?.name
        }
        guard let member = SignInDevice.memberID(of: id) else { return nil }
        return model.bots.machines.first { $0.id.lowercased() == member }?.name
    }

    private func select(_ id: String) {
        connectedProvider = nil
        SignInDevicePicker.select(id, on: agent, remote: model.remoteWorkspaces.workspaces)
    }

    private func accountConnected(_ id: String) {
        connectedProvider = id
        if SignInDevice.kind(of: agent.device) != .mac {
            agent.loadCatalog(remote: SignInDevicePicker.remote(agent.device, in: model.remoteWorkspaces.workspaces), includeAllModels: false)
        }
        guard agent.device == SignInDevice.localID, let provider = ProviderKind.supportedAccounts.first(where: {
            UsageConnectionChoice.connectionTypes(for: $0).contains { $0.0 == id }
        }) else { return }
        Task { await model.enableUsageProvider(provider) }
    }
}

/// Settings → Subscriptions & API Keys' "Sign in on" picker: this Mac, the user's
/// other Macs, then remote workspaces, each by Tailnet name.
enum SignInDevicePicker {
    static let title = "Sign in on"
    static let pageDetail = "Used by Pi Durable and bots on the selected device. Codex, Claude Code, Grok Build, and OpenCode sign in on their own pages. Usage limits shows the accounts signed in on this device."
    /// Marks a device whose bots use its sign-ins.
    static let botsMark = "Bots"

    /// Device IDs in picker order. This Mac is always offered, and a selected device
    /// stays listed while the device list loads.
    static func options(_ devices: [SignInDevice], selected: String) -> [String] {
        var ids = SignInDevice.ordered(devices).map(\.id)
        if !ids.contains(SignInDevice.localID) { ids.insert(SignInDevice.localID, at: 0) }
        if !ids.contains(selected) { ids.append(selected) }
        return ids
    }

    static func label(_ id: String, devices: [SignInDevice], fallbackName: (String) -> String? = { _ in nil }) -> String {
        guard let device = devices.first(where: { $0.id == id }) else {
            return SignInDevice.kind(of: id) == .thisMac ? "Local workspace" : fallbackName(id) ?? "Workspace"
        }
        let name = device.kind == .thisMac ? "Local workspace (\(device.name))" : device.name
        return device.runsBots ? "\(name) · \(botsMark)" : name
    }

    /// The device a page link names: a device ID as is, a chat-settings scope as the
    /// device that holds its sign-ins (`global`/`local` → this Mac).
    static func device(forPage value: String) -> String {
        SignInDevice.kind(of: value) == .thisMac ? SignInDevice.id(forScope: value) : value
    }

    /// The device a bots machine is, from the device list or, before it has loaded,
    /// from the machine itself.
    static func device(forBotMachine machineID: String, machines: [BotMachine], devices: [SignInDevice]) -> String {
        if let id = SignInDevice.id(forBotMachine: machineID, in: devices) { return id }
        let machine = machines.first { $0.id.lowercased() == machineID.lowercased() }
        switch machine?.kind {
        case .mac: return SignInDevice.macID(machineID)
        case .linux: return machine?.workspaceID.map { SignInDevice.linuxID($0) } ?? SignInDevice.localID
        default: return SignInDevice.localID
        }
    }

    /// A Linux device this Mac configured, for its model catalog.
    static func remote(_ id: String, in workspaces: [RemoteWorkspaceConfiguration]) -> RemoteWorkspaceConfiguration? {
        SignInDevice.linuxWorkspace(of: id).flatMap { workspace in workspaces.first { $0.id == workspace } }
    }

    /// Leaving the page returns to this Mac: while another Mac is selected the
    /// connections model holds that Mac's chat settings and catalog, which this
    /// Mac's own settings views (Pi Durable, agent defaults) must never show or save.
    @MainActor static func leave(_ agent: DefaultAgentSettingsModel) {
        guard SignInDevice.kind(of: agent.device) == .mac else { return }
        agent.changeScope("global")
        agent.selectDevice(SignInDevice.localID)
    }

    /// Shows `id`'s sign-ins; every account action on the page then runs on that device.
    @MainActor static func select(_ id: String, on agent: DefaultAgentSettingsModel, remote workspaces: [RemoteWorkspaceConfiguration]) {
        // On this Mac the page edits the chat settings for All workspaces (the web search choice), as before.
        if id == SignInDevice.localID, agent.device != id || agent.scope != "global" { agent.changeScope("global") }
        agent.selectDevice(id)
        // Another Mac answers with its own catalog through its own page.
        if SignInDevice.kind(of: id) != .mac {
            agent.loadCatalog(remote: remote(id, in: workspaces), includeAllModels: false)
        }
        agent.loadDevices()
    }
}

/// Used where a screen points at the account list: this Mac's, or a bot's device's.
struct ManageAccountsLink: View {
    var device = SignInDevice.localID
    var body: some View {
        Button("Manage subscriptions and keys") {
            NotificationCenter.default.post(name: .init("wovenmatter.open-connections"), object: device)
        }.buttonStyle(SettingsQuietButtonStyle())
    }
}
