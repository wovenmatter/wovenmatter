import SwiftUI
import WovenMatterCore

struct ProductAnalyticsSettingsSection: View {
    @Bindable var analytics: ProductAnalyticsModel
    var body: some View {
        SettingsSection(title: "Privacy") {
            SettingsToggleRow(
                title: "Share product analytics",
                detail: "Limited usage statistics. No content is sent.",
                isOn: Binding(
                    get: { analytics.enabled },
                    set: { value in Task { await analytics.setEnabled(value) } })
            )
            .disabled(analytics.preference == nil)
            if let error = analytics.errorMessage {
                SettingsError(error)
            }
            SettingsHelp {
                SettingsNote("App opens and active use are sampled at most once every six hours. No content or action details are sent. This choice applies to all of your devices; offline devices get it when they reconnect.")
                Link("Privacy policy", destination: ProductAnalyticsPolicy.url)
                    .font(.settingsBody.weight(.medium))
                    .foregroundStyle(DashboardPalette.success)
            }
        }.task { await analytics.refresh() }
    }
}
