import SwiftUI
import WovenMatterCore

private enum SettingsUsageCredentialAction: Identifiable {
    case enableProvider(ProviderKind)

    var id: String {
        switch self {
        case .enableProvider(let provider): "enable-\(provider.rawValue)"
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
        }
    }
}

struct SettingsUsageView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void

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
                        ConnectionsLink(title: providerStatus(provider))
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

            ConnectionsLink(title: "Manage connection")
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
        }
    }
}
