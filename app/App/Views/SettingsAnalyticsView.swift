import SwiftUI
import WovenProtocol

/// What the anonymous usage analytics are, a short form of the privacy
/// policy, and the one switch that turns them off for every machine.
struct SettingsAnalyticsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    let onBack: () -> Void

    var body: some View {
        SettingsPage(
            title: "Analytics",
            detail: "Woven Matter sends anonymous usage analytics so we can count how many people use it and see whether updates work.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            SettingsSection(
                title: "What is sent",
                detail: "When the app opens, when you use it, and each step of an update, with the Woven Matter version, Mac or Linux, the macOS version, and the versions an update is from and to."
            ) {}
            SettingsSection(
                title: "What counts as use",
                detail: "Starting or steering a chat, editing in the Library, adding a folder or schedule, saving a dictation, or messaging your bots. Opening and browsing alone do not count."
            ) {}
            SettingsSection(
                title: "One person, every machine",
                detail: "Your Macs and Linux machines share one random ID, so together they count as one person. Each machine reports opens and use at most once every six hours."
            ) {}
            SettingsSection(
                title: "What is never sent",
                detail: "Your content, messages, file and folder names, accounts, credentials, or which action you took."
            ) {}
            SettingsSection(
                title: "Where it goes",
                detail: "PostHog Cloud in the United States receives it and keeps only your approximate country, from your Mac's connection, never your IP address."
            ) {}
            SettingsSection(title: "Questions") {
                HStack(spacing: 16) {
                    Link("privacy@wovenmatter.com", destination: AnalyticsSettings.contact)
                    Link("Privacy policy", destination: AnalyticsSettings.policy)
                }
                .font(.settingsBody.weight(.medium))
                .foregroundStyle(WovenPalette.success)
            }
            SettingsSection {
                SettingsToggleRow(
                    title: "Share anonymous usage analytics",
                    detail: "Applies to all your machines. Turning it off stops sending; what was already sent is kept.",
                    isOn: Binding(
                        get: { model.settings.analyticsEnabled },
                        set: { value in Task { await model.settings.setAnalyticsEnabled(value) } })
                )
                .disabled(!model.settings.isLoaded)
                if let error = model.settings.analyticsError {
                    SettingsError(error)
                }
            }
        }
    }
}
