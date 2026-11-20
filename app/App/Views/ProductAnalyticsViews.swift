import SwiftUI

struct ProductAnalyticsSettingsSection: View {
    @Bindable var settings: SettingsStore
    var body: some View {
        SettingsSection(title: "Privacy") {
            SettingsToggleRow(
                title: "Share product analytics",
                detail: "Limited usage statistics. No content is sent.",
                isOn: Binding(
                    get: { settings.analyticsEnabled },
                    set: { value in Task { await settings.setAnalyticsEnabled(value) } })
            )
            .disabled(settings.analyticsPreference == nil)
            if let error = settings.analyticsError {
                SettingsError(error)
            }
            SettingsHelp {
                SettingsNote("App opens and active use are sampled at most once every six hours. No content or action details are sent. This choice applies to all of your devices; offline devices get it when they reconnect.")
                Link("Privacy policy", destination: ProductAnalyticsPolicy.url)
                    .font(.settingsBody.weight(.medium))
                    .foregroundStyle(WovenPalette.success)
            }
        }.task { await settings.refreshAnalytics() }
    }
}
