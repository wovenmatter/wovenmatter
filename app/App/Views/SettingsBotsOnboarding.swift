import SwiftUI
import WovenMatterClient

/// First run on a machine: bots use the accounts in Woven's settings, so setup is
/// signing in there, then choosing Admin Bot's model, which becomes the default for
/// new bots. Nothing is chosen for the user: a suggestion is only preselected.
struct BotOnboardingView: View {
    @Bindable var bots: BotMachineSession
    let onOpenConnections: () -> Void
    @State private var state: BotSettingsState
    @State private var catalog: PiBotModelCatalog?
    @State private var selection: String?
    @State private var showsAllModels = false

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
                SettingsSection(title: "Sign in to get started",
                                detail: "Admin Bot needs a subscription or API key from Subscriptions & API Keys; one is enough.") {
                    Button("Open Subscriptions & API Keys", action: onOpenConnections)
                        .buttonStyle(DashboardPrimaryButtonStyle())
                }
            }
        }
        .font(.settingsText)
    }

    private var steps: some View {
        HStack(spacing: 20) {
            step("Sign in", number: 1, done: bots.onboarding?.signedIn == true,
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
                else { Text("\(number)").font(.settingsSecondary.weight(.semibold)) }
            }.accessibilityHidden(true)
            Text(label).font(.settingsBody.weight(current ? .semibold : .regular))
        }.accessibilityLabel("\(number). \(label)\(done ? ", complete" : current ? ", current step" : "")")
    }

    private var modelCard: some View {
        SettingsSection(title: "No model selected yet for Admin Bot",
                        detail: "Choose a model to default to; you can change it anytime by asking Admin Bot or in Settings.") {
            if let catalog {
                if catalog.providers.isEmpty { SettingsEmpty("Sign in to a model provider first.") }
                else {
                    let suggestions = catalog.suggestions
                    if !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(suggestions) { suggestion in
                                suggestionRow(suggestion.ref, model: suggestion.model.name,
                                              provider: suggestion.provider.name, catalog: catalog)
                            }
                        }
                    }
                    if suggestions.isEmpty || showsAllModels {
                        SettingsRow(title: suggestions.isEmpty ? "Model" : "Another model") {
                            BotSettingsModelPicker(providers: catalog.providers, selection: Binding(
                                get: { selectedModel(catalog) }, set: { selection = $0 }), label: "Model")
                        }
                    } else {
                        Button("Show all models") { showsAllModels = true }
                    }
                    Button("Use this model") {
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

    private func suggestionRow(_ ref: String, model: String, provider: String, catalog: PiBotModelCatalog) -> some View {
        let selected = selectedModel(catalog) == ref
        return Button { selection = ref } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? DashboardPalette.primary : DashboardPalette.mutedForeground)
                    .accessibilityHidden(true)
                Text(model).font(.settingsBody.weight(.medium))
                Text(provider).font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model), \(provider)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The user's pick, else Admin Bot's current model, else the best suggestion. Only preselected.
    private func selectedModel(_ catalog: PiBotModelCatalog) -> String {
        if let selection { return selection }
        if let current = bots.onboarding?.mainModel, catalog.isKnown(current) { return current }
        if let suggested = catalog.suggestions.first { return suggested.ref }
        guard let provider = catalog.providers.first, let model = provider.models.first else { return "" }
        return "\(provider.id)/\(model.id)"
    }

    private func refreshStatus() async {
        await bots.refreshOnboarding(onError: { state.error = $0 })
    }
}
