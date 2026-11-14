import SwiftUI
import WovenMatterClient

/// First run on a machine: bots use the accounts in Woven's settings, so setup is
/// signing in there, then choosing Admin Bot's model, which becomes the default for
/// new bots. Every model of every signed-in provider is listed, newest first.
struct BotOnboardingView: View {
    @Bindable var bots: BotMachineSession
    let onOpenConnections: () -> Void
    @State private var state: BotSettingsState
    @State private var catalog: PiBotModelCatalog?
    @State private var selection: String?
    @State private var search = ""
    /// Open provider sections; nil until the user toggles one (the selected model's is open).
    @State private var expanded: Set<String>?

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
                        .buttonStyle(WovenPrimaryButtonStyle())
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
                Circle().fill(done || current ? WovenPalette.primary.opacity(0.12) : WovenPalette.muted)
                    .frame(width: 24, height: 24)
                if done { LucideIcon(glyph: .check, size: 12).foregroundStyle(WovenPalette.success) }
                else { Text("\(number)").font(.settingsSecondary.weight(.semibold)) }
            }.accessibilityHidden(true)
            Text(label).font(.settingsBody.weight(current ? .semibold : .regular))
        }.accessibilityLabel("\(number). \(label)\(done ? ", complete" : current ? ", current step" : "")")
    }

    /// Lists longer than this get a search field and scroll in place.
    private static let longList = 15
    private static let rowHeight: CGFloat = 28

    private var modelCard: some View {
        SettingsSection(title: (bots.onboarding?.mainModel ?? "").isEmpty ? "No model selected yet for Admin Bot"
                                                                       : "Admin Bot's model isn't signed in",
                        detail: "Choose a model to default to; you can change it anytime by asking Admin Bot or in Settings.") {
            if let catalog {
                if catalog.providers.isEmpty { SettingsEmpty("Sign in to a model provider first.") }
                else {
                    let providers = listed(catalog)
                    if catalog.providers.reduce(0, { $0 + $1.models.count }) > Self.longList {
                        WovenSearchField(text: $search, prompt: "Search models")
                    }
                    if providers.isEmpty {
                        SettingsEmpty("No models match.")
                    } else if catalog.providers.count == 1, let provider = providers.first {
                        modelList(provider)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(providers) { provider in
                                DisclosureGroup(isExpanded: isExpanded(provider.id, catalog: catalog)) {
                                    modelList(provider).padding(.leading, 4)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(provider.name).font(.settingsBody.weight(.medium))
                                        Text("\(provider.models.count)").font(.settingsSecondary)
                                            .foregroundStyle(WovenPalette.mutedForeground)
                                    }
                                }
                            }
                        }
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
                    .buttonStyle(WovenPrimaryButtonStyle())
                    // Only what's on screen: a search that hides the selection can't submit it.
                    .disabled(!providers.contains { provider in
                        provider.models.contains { "\(provider.id)/\($0.id)" == selectedModel(catalog) }
                    })
                }
            } else { SettingsEmpty("Loading…") }
        }.disabled(state.disabled)
    }

    /// Each provider's models, newest first, narrowed by the search.
    private func listed(_ catalog: PiBotModelCatalog) -> [PiBotProviderModels] {
        let terms = search.lowercased().split(separator: " ").map(String.init)
        return catalog.providers.compactMap { provider in
            let models = PiBotModelCatalog.newestFirst(provider.models).filter { model in
                terms.allSatisfy { model.name.lowercased().contains($0) || model.id.lowercased().contains($0) }
            }
            return models.isEmpty ? nil : PiBotProviderModels(id: provider.id, name: provider.name,
                                                               access: provider.access, models: models)
        }
    }

    /// Short lists show in full; long ones show about 15 rows and scroll, rows loading as they come into view.
    @ViewBuilder private func modelList(_ provider: PiBotProviderModels) -> some View {
        let rows = ForEach(provider.models) { model in
            modelRow("\(provider.id)/\(model.id)", name: model.name)
        }
        if provider.models.count > Self.longList {
            ScrollView { LazyVStack(alignment: .leading, spacing: 0) { rows } }
                .frame(height: Self.rowHeight * CGFloat(Self.longList))
                .scrollIndicators(.never)
        } else {
            VStack(alignment: .leading, spacing: 0) { rows }
        }
    }

    private func modelRow(_ ref: String, name: String) -> some View {
        let selected = selection == ref || (selection == nil && catalog.map(selectedModel) == ref)
        return Button { selection = ref } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(selected ? WovenPalette.primary : WovenPalette.mutedForeground, lineWidth: 1.5)
                    if selected { Circle().fill(WovenPalette.primary).padding(3.5) }
                }
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
                Text(name).font(.settingsBody.weight(.medium))
                Spacer(minLength: 0)
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Searching opens every section; otherwise the selected model's section starts open.
    private func isExpanded(_ id: String, catalog: PiBotModelCatalog) -> Binding<Bool> {
        let opened = { expanded ?? Set([selectedModel(catalog).split(separator: "/").first.map(String.init) ?? ""]) }
        return Binding(
            get: { !search.isEmpty || opened().contains(id) },
            set: { open in
                var next = opened()
                if open { next.insert(id) } else { next.remove(id) }
                expanded = next
            })
    }

    /// The user's pick, else Admin Bot's current model, else the newest model listed first.
    private func selectedModel(_ catalog: PiBotModelCatalog) -> String {
        if let selection { return selection }
        if let current = bots.onboarding?.mainModel, catalog.isKnown(current) { return current }
        guard let provider = catalog.providers.first,
              let model = PiBotModelCatalog.newestFirst(provider.models).first else { return "" }
        return "\(provider.id)/\(model.id)"
    }

    private func refreshStatus() async {
        await bots.refreshOnboarding(onError: { state.error = $0 })
    }
}
