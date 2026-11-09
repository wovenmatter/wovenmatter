import SwiftUI
import WovenMatterClient

/// First run on a machine: bots use the provider connections in Woven's settings, so
/// setup is connecting one there, then choosing Admin Bot's model.
struct BotOnboardingView: View {
    @Bindable var bots: BotMachineSession
    let onOpenConnections: () -> Void
    @State private var state: BotSettingsState
    @State private var catalog: PiBotModelCatalog?
    @State private var selection: String?

    init(bots: BotMachineSession, onOpenConnections: @escaping () -> Void) {
        self.bots = bots; self.onOpenConnections = onOpenConnections
        _state = State(initialValue: BotSettingsState(bots: bots))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                onboardingContent
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }.scrollIndicators(.never)
        }
        .buttonStyle(SettingsQuietButtonStyle())
        .disclosureGroupStyle(SettingsDisclosureGroupStyle())
        .modifier(BotSettingsConfirmationPresenter(state: state))
        .task(id: "\(bots.connection.rawValue):\(bots.onboarding?.signedIn == true)") {
            guard bots.isConnected, bots.onboarding?.signedIn == true else { return }
            await state.load { catalog = try await $0.modelCatalog() }
        }
        // The runtime doesn't announce new connections, and another client can finish this first.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await bots.refreshOnboarding()
            }
        }
    }

    private var onboardingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            steps
            BotSettingsErrorNotice(state: state)
            if !bots.isConnected { SettingsEmpty("Bots are not connected.") }
            if bots.onboarding?.signedIn == true {
                modelCard
            } else {
                SettingsCard(title: "Connect a provider", detail: "Bots use the provider connections in Woven Matter. One is enough to start.") {
                    Button("Open Connections", action: onOpenConnections)
                        .buttonStyle(DashboardPrimaryButtonStyle())
                }
            }
        }
        .font(.system(size: 13))
    }

    private var steps: some View {
        HStack(spacing: 20) {
            step("Connect a provider", number: 1, done: bots.onboarding?.signedIn == true,
                 current: bots.onboarding?.signedIn != true)
            step("Choose a model", number: 2,
                 done: bots.onboarding?.signedIn == true && bots.onboarding?.mainModelAvailable == true,
                 current: bots.onboarding?.signedIn == true && bots.onboarding?.mainModelAvailable != true)
        }.accessibilityElement(children: .contain).accessibilityLabel("Setup steps")
    }

    private func step(_ label: String, number: Int, done: Bool, current: Bool) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(done || current ? DashboardPalette.primary.opacity(0.12) : DashboardPalette.muted)
                    .frame(width: 24, height: 24)
                if done { DashboardLucideIcon(glyph: .check, size: 12).foregroundStyle(DashboardPalette.success) }
                else { Text("\(number)").font(.system(size: 11, weight: .semibold)) }
            }.accessibilityHidden(true)
            Text(label).font(.system(size: 12.5, weight: current ? .semibold : .regular))
        }.accessibilityLabel("\(number). \(label)\(done ? ", complete" : current ? ", current step" : "")")
    }

    private var modelCard: some View {
        SettingsCard(title: "Choose Admin Bot's model", detail: "You can set up more models with Admin Bot later.") {
            if let catalog {
                if catalog.providers.isEmpty { SettingsEmpty("Connect a model provider first.") }
                else {
                    BotSettingsModelPicker(providers: catalog.providers, selection: Binding(
                        get: { selectedModel(catalog) }, set: { selection = $0 }), label: "Main model")
                    Button("Start chatting") {
                        Task {
                            await state.run { client in
                                try await client.setOnboardingMainModel(selectedModel(catalog))
                                await refreshStatus()
                                selection = nil
                            }
                        }
                    }
                    .buttonStyle(DashboardPrimaryButtonStyle())
                    .disabled(!catalog.isKnown(selectedModel(catalog)))
                }
            } else { SettingsEmpty("Loading…") }
        }.disabled(state.disabled)
    }

    private func selectedModel(_ catalog: PiBotModelCatalog) -> String {
        if let selection { return selection }
        if let current = bots.onboarding?.mainModel, catalog.isKnown(current) { return current }
        guard let provider = catalog.providers.first, let model = provider.models.first else { return "" }
        return "\(provider.id)/\(model.id)"
    }

    private func refreshStatus() async {
        await bots.refreshOnboarding(onError: { state.error = $0 })
    }
}
