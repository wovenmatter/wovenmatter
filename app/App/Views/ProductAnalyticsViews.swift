import CompanionClient
import SwiftUI
import WovenMatterCore

struct ProductAnalyticsSettingsCard: View {
    @Bindable var analytics: ProductAnalyticsModel
    var body: some View {
        SettingsCard(
            title: "Product analytics",
            detail: "Help improve Woven Matter with limited usage statistics."
        ) {
            Toggle(
                "Share product analytics",
                isOn: Binding(
                    get: { analytics.enabled },
                    set: { value in Task { await analytics.setEnabled(value) } })
            )
            .font(.system(size: 13))
            .toggleStyle(DashboardSwitchToggleStyle())
            .disabled(analytics.preference == nil)
            Text("App opens and active use are sampled at most once every six hours. No content or action details are sent. This choice applies to your whole central library; offline devices receive changes when they reconnect.")
                .font(.system(size: 11.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            Link("Privacy policy", destination: ProductAnalyticsPolicy.url)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DashboardPalette.success)
            if let error = analytics.errorMessage {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red)
            }
        }.task { await analytics.refresh() }
    }
}
struct MobileAnalyticsSettingsCard: View {
    @Bindable var analytics: MobileAnalyticsModel
    var body: some View {
        SettingsCard(
            title: "Product analytics",
            detail: "Help improve Woven Matter with limited usage statistics."
        ) {
            Toggle(
                "Share product analytics",
                isOn: Binding(
                    get: { analytics.enabled },
                    set: { value in Task { await analytics.setEnabled(value) } })
            )
            .font(.system(size: 13))
            .toggleStyle(DashboardSwitchToggleStyle())
            Text("App opens and active use are sampled at most once every six hours. No content or action details are sent. This choice applies to your whole central library; offline devices receive changes when they reconnect.")
                .font(.system(size: 11.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            if analytics.state.pendingEnabled != nil {
                Text("Preference waiting to sync.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            Link("Privacy policy", destination: ProductAnalyticsPolicy.url)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DashboardPalette.success)
            if let error = analytics.errorMessage {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red)
            }
        }
    }
}
