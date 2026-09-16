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
            switch provider {
            case .cursor:
                "Allow Woven Matter to read Cursor’s local account session and check usage."
            case .openRouter:
                "Allow Woven Matter to use your saved OpenRouter key to check usage."
            default:
                "Allow Woven Matter to check \(provider.displayName) usage using its local sign-in."
            }
        case .saveOpenRouter:
            "Save your OpenRouter key in this Mac’s Keychain and use it to check usage."
        case .deleteOpenRouter:
            "Remove your saved OpenRouter key from this Mac’s Keychain."
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
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            if let error = model.localUsageError {
                SettingsError(error)
            }

            SettingsCard(
                title: "Providers",
                detail: "Track usage for the accounts you enable."
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
                Toggle(
                    "Enable \(provider.displayName)",
                    isOn: providerBinding(provider)
                )
                .labelsHidden()
                .toggleStyle(DashboardSwitchToggleStyle(showsLabel: false))
                .accessibilityLabel("Enable \(provider.displayName) usage")
                .help(
                    "Allow usage tracking for \(provider.displayName)."
                )
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
                    if let detail = providerDetail(provider) {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
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
                .help("Stored in this Mac’s Keychain.")

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
                .help("Save the key in Keychain.")
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

    private func providerDetail(_ provider: ProviderKind) -> String? {
        guard model.isUsageProviderEnabled(provider) else {
            return nil
        }
        if provider == .openRouter {
            return model.isOpenRouterCredentialConfigured
                ? nil
                : "Add an API or management key to track usage."
        }
        if let detail = account(for: provider)?.detail {
            return detail
        }
        return nil
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
