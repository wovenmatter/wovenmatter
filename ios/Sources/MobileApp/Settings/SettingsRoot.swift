import SwiftUI

/// Settings, over the tabs, with its own navigation stack: a landing list
/// whose rows open each page. It opens on `model.settingsDestination` when
/// another page links here, and clears it.
struct SettingsRoot: View {
    @Bindable var model: MobileModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WovenTheme.storageKey) private var storedTheme = WovenTheme.green.rawValue
    @State private var path: [SettingsPage] = []
    @State private var connector = MachineConnector()

    private var app: ApplicationModel { model.app }
    private var machines: MachinesStore { app.machines }

    var body: some View {
        NavigationStack(path: $path) {
            landing
                .navigationDestination(for: SettingsPage.self, destination: page)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("settings-done")
                    }
                }
        }
        .presentationSizing(.form)
        .scrollIndicators(.never)
        .onChange(of: model.settingsDestination, initial: true) { _, destination in
            guard let destination else { return }
            model.settingsDestination = nil
            open(destination)
        }
        .task(id: model.deviceID) {
            // Quick Chat's settings are this device's own.
            guard let deviceID = model.deviceID else { return }
            if app.connections.scope != deviceID { app.connections.changeScope(deviceID) }
            app.connections.loadAccounts(on: deviceID)
        }
        .onDisappear {
            model.settingsDestination = nil
            connector.cancel()
        }
    }

    private var landing: some View {
        List {
            Section {
                SettingsLinkRow(title: "Machines", glyph: .monitor, value: machinesSummary.text, tone: machinesSummary.tone,
                                page: .machines)
                    .accessibilityIdentifier("settings-machines")
                if let deviceID = model.deviceID {
                    SettingsLinkRow(title: "This \(ThisDevice.kind)", glyph: ThisDevice.glyph,
                                    value: app.devices.device(id: deviceID)?.device.name, page: .device)
                        .accessibilityIdentifier("settings-device")
                    SettingsLinkRow(title: "Quick Chat", glyph: .messageSquare, value: quickChatSummary.text,
                                    tone: quickChatSummary.tone, page: .quickChat)
                        .accessibilityIdentifier("settings-quick-chat")
                }
                SettingsLinkRow(title: "Appearance", glyph: .sparkles, value: WovenTheme(rawValue: storedTheme)?.title,
                                page: .appearance)
                    .accessibilityIdentifier("settings-appearance")
                SettingsLinkRow(title: "Dictation", glyph: .mic, page: .dictation)
                    .accessibilityIdentifier("settings-dictation")
            }
            Section {
                SettingsControlRow(title: "Woven Matter") {
                    Text(ThisDevice.appVersion).font(.subheadline).foregroundStyle(WovenPalette.mutedForeground)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings-version")
                if machines.releaseMismatch {
                    SettingsLinkRow(title: "Versions don’t match", page: .machines)
                }
            } header: {
                SettingsHeader(title: "About")
            }
        }
        .settingsPage("Settings")
    }

    @ViewBuilder private func page(_ page: SettingsPage) -> some View {
        let deviceID = model.deviceID ?? ""
        switch page {
        case .machines: MachinesPage(model: model, connector: connector)
        case .connect: ConnectPage(model: model, connector: connector)
        case .device: DevicePage(model: model, deviceID: deviceID)
        case .quickChat: QuickChatPage(model: model, deviceID: deviceID)
        case .providers: ProvidersPage(model: model, deviceID: deviceID)
        case .provider(let id):
            if let row = ProviderRow.row(id) { ProviderPage(model: model, deviceID: deviceID, row: row) }
        case .modelServer(let id): ModelServerPage(model: model, deviceID: deviceID, serverID: id)
        case .defaultModel: DefaultModelPage(model: model, deviceID: deviceID)
        case .composerModels: ComposerModelsPage(model: model)
        case .appearance: AppearancePage()
        case .dictation: DictationPage(model: model)
        }
    }

    /// Opens the page another part of the app links to, from the landing list.
    private func open(_ destination: SettingsDestination) {
        switch destination {
        case .modelProviders:
            path = [.quickChat, .providers]
        case .webSearch:
            path = [.quickChat, .providers, .provider(app.connections.configuration.searchProvider)]
        case .connectMachine:
            path = machines.isConnected ? [.machines, .connect] : [.machines]
        case .connect(let code):
            path = machines.isConnected ? [.machines, .connect] : [.machines]
            connector.connect(code, model: model) { [machines] in
                // Connecting again from its own page returns to the machines.
                if path.last == .connect, machines.isConnected { path.removeLast() }
            }
        }
    }

    private var machinesSummary: (text: String, tone: SettingsTone?) {
        guard machines.isConnected else { return ("Not connected", nil) }
        if machines.releaseMismatch { return ("Update needed", .warning) }
        let count = machines.machines.count
        return (count == 1 ? "1 machine" : "\(count) machines", .good)
    }

    private var quickChatSummary: (text: String, tone: SettingsTone) {
        let ready = model.deviceID.map { !app.connections.connections(on: $0).availableModelProviderIDs.isEmpty } ?? false
        return ready ? ("Ready", .good) : ("Not set up", .warning)
    }
}
