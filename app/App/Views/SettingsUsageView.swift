import SwiftUI
import WovenMatterCore

private enum SettingsUsageCredentialAction: Identifiable {
    case enableProvider(ProviderKind)
    case saveOpenRouter(String)
    case deleteOpenRouter

    var id: String {
        switch self {
        case .enableProvider(let provider): "enable-\(provider.rawValue)"
        case .saveOpenRouter: "save-openrouter"
        case .deleteOpenRouter: "delete-openrouter"
        }
    }

    var purpose: String {
        switch self {
        case .enableProvider(let provider):
            "Enable \(provider.displayName) so Woven Matter can check its local sign-in and usage when Usage refreshes."
        case .saveOpenRouter:
            "Save and use the OpenRouter API key you enter in this Mac's Keychain."
        case .deleteOpenRouter:
            "Access the saved OpenRouter item so it can be removed from this Mac's Keychain."
        }
    }
}

struct SettingsUsageView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void

    @State private var openRouterAPIKey = ""
    @State private var pendingCredentialAction: SettingsUsageCredentialAction?
    @State private var range: UsageTimeRange = {
        let rawValue = UserDefaults.standard.string(
            forKey: "wovenmatter.usage.range"
        )
        return rawValue.flatMap(UsageTimeRange.init(rawValue:)) ?? .last30Days
    }()

    var body: some View {
        SettingsPage(
            title: "Usage",
            detail: "Usage collection and provider connection settings.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            if let error = model.localUsageError {
                SettingsError(error)
            }

            SettingsCard(
                title: "Providers",
                detail: "Choose which providers Woven Matter may collect and display. Disabled providers are not scanned, checked, or shown in Usage Analytics or Usage Limits."
            ) {
                ForEach(ProviderKind.supportedAccounts) { provider in
                    SettingsInset {
                        providerRow(provider)
                    }
                    if provider != ProviderKind.supportedAccounts.last {
                        Divider()
                    }
                }
            }

            SettingsNote("Provider settings are stored on this Mac. Subscription providers use their existing CLI sign-in; OpenRouter uses only the API key you enter here.")
        }
        .task {
            await model.refreshLocalUsage(
                range: range,
                refreshLimits: true,
                reason: .viewAppeared
            )
        }
        .sheet(item: $pendingCredentialAction) { action in
            CredentialAccessDisclosureView(
                purpose: action.purpose,
                onEnable: {
                    model.acknowledgeCredentialAccessDisclosure()
                    pendingCredentialAction = nil
                    performCredentialAction(action)
                },
                onCancel: { pendingCredentialAction = nil }
            )
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: ProviderKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(provider.displayName)
                            .font(.system(size: 13, weight: .medium))
                        SettingsPill(
                            providerStatus(provider),
                            tone: model.isUsageProviderEnabled(provider)
                                ? .neutral
                                : .warning
                        )
                    }
                    Text(providerDetail(provider))
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle(
                    "Enable \(provider.displayName)",
                    isOn: providerBinding(provider)
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Enable \(provider.displayName) usage")
                .help(
                    "Controls whether Woven Matter may scan, collect, and display \(provider.displayName) usage and account limits."
                )
            }

            if provider == .openRouter {
                openRouterControls
            } else if model.isUsageProviderEnabled(provider),
                      shouldOfferSignIn(provider) {
                Button(
                    model.signingInUsageProviders.contains(provider)
                        ? "Signing in…"
                        : "Sign in"
                ) {
                    model.signInUsageProvider(provider)
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(
                    model.signingInUsageProviders.contains(provider)
                        || model.isRefreshingLocalUsage
                )
                .accessibilityLabel("Sign in to \(provider.displayName)")
                .help("Uses the existing \(provider.displayName) CLI sign-in flow.")
            }
        }
    }

    private var openRouterControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                SecureField(
                    model.isOpenRouterCredentialConfigured
                        ? "Enter a replacement key"
                        : "OpenRouter API or management key",
                    text: $openRouterAPIKey
                )
                .settingsInput()
                .disabled(!model.isUsageProviderEnabled(.openRouter))
                .accessibilityLabel("OpenRouter API key")
                .help("The key is stored using Woven Matter's existing macOS Keychain credential boundary.")

                Button(
                    model.isOpenRouterCredentialConfigured
                        ? "Replace key"
                        : "Save API key"
                ) {
                    requestCredentialAction(.saveOpenRouter(openRouterAPIKey))
                }
                .buttonStyle(DashboardPrimaryButtonStyle())
                .disabled(
                    !model.isUsageProviderEnabled(.openRouter)
                        || openRouterAPIKey
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                        || model.isRefreshingLocalUsage
                )
                .help("Save this key in the existing Woven Matter Keychain item.")
            }

            if model.isOpenRouterCredentialConfigured {
                Button("Remove saved key", role: .destructive) {
                    requestCredentialAction(.deleteOpenRouter)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DashboardPalette.danger)
                .help("Remove the saved OpenRouter key from this Mac's Keychain.")
            }
        }
    }

    private func providerBinding(_ provider: ProviderKind) -> Binding<Bool> {
        Binding(
            get: { model.isUsageProviderEnabled(provider) },
            set: { isEnabled in
                if isEnabled {
                    requestCredentialAction(.enableProvider(provider))
                } else {
                    Task {
                        await model.disableUsageProvider(provider, range: range)
                    }
                }
            }
        )
    }

    private func providerStatus(_ provider: ProviderKind) -> String {
        guard model.isUsageProviderEnabled(provider) else { return "Disabled" }
        if provider == .openRouter {
            return model.isOpenRouterCredentialConfigured
                ? "API key saved"
                : "Needs API key"
        }
        guard let account = account(for: provider) else { return "Enabled" }
        switch account.status {
        case .available: return "Live"
        case .signedIn: return "Signed in"
        case .needsCredential: return "Needs sign-in"
        case .unavailable: return "Unavailable"
        case .failed: return "Needs attention"
        }
    }

    private func providerDetail(_ provider: ProviderKind) -> String {
        guard model.isUsageProviderEnabled(provider) else {
            return "Not collected or shown in Usage."
        }
        if provider == .openRouter {
            return model.isOpenRouterCredentialConfigured
                ? "Uses the saved API key for OpenRouter activity and limits. OAuth is not used."
                : "Add an API or management key to collect OpenRouter activity and limits. OAuth is not used."
        }
        if let detail = account(for: provider)?.detail {
            return detail
        }
        return switch provider {
        case .codex: "Collects Codex usage and checks the locally signed-in OpenAI account."
        case .claude: "Collects Claude usage and checks the locally signed-in Claude account."
        case .grok: "Collects Grok usage and checks the locally signed-in xAI account."
        case .cursor: "Collects Cursor usage and checks Cursor's local account session."
        case .openCodeGo: "Collects OpenCode Go cost history and checks its provider sign-in."
        case .openRouter, .unknown: ""
        }
    }

    private func account(for provider: ProviderKind) -> UsageLimitAccount? {
        model.localUsage?.limits.first { $0.provider == provider }
    }

    private func shouldOfferSignIn(_ provider: ProviderKind) -> Bool {
        guard let account = account(for: provider) else { return true }
        return account.status != .available && account.status != .signedIn
    }

    private func requestCredentialAction(
        _ action: SettingsUsageCredentialAction
    ) {
        if model.hasAcknowledgedCredentialAccessDisclosure {
            performCredentialAction(action)
        } else {
            pendingCredentialAction = action
        }
    }

    private func performCredentialAction(
        _ action: SettingsUsageCredentialAction
    ) {
        switch action {
        case .enableProvider(let provider):
            Task {
                await model.enableUsageProvider(provider, range: range)
            }
        case .saveOpenRouter(let key):
            Task {
                await model.saveOpenRouterAPIKey(key, range: range)
                if model.localUsageError == nil { openRouterAPIKey = "" }
            }
        case .deleteOpenRouter:
            Task {
                await model.deleteOpenRouterAPIKey(range: range)
                if model.localUsageError == nil { openRouterAPIKey = "" }
            }
        }
    }
}
