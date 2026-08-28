import SwiftUI

struct SettingsUsageView: View {
    var reservesRailControlSpace = false
    var onBack: () -> Void

    var body: some View {
        SettingsPage(
            title: "Usage",
            detail: "Usage collection and provider connection settings.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            SettingsCard(
                title: "Provider usage",
                detail: "Provider controls are not connected in this app build."
            ) {
                SettingsNote("Connecting provider accounts, usage collection, gateway configuration, and planning budgets are unavailable until they have a supported authenticated service boundary.")
            }

            SettingsCard(
                title: "Usage dashboard",
                detail: "Analytics and account allowances live outside Settings."
            ) {
                SettingsNote("Open the Usage destination in the workspace sidebar for usage analytics, limits, and usage credentials.")
            }
        }
    }
}
