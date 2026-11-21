import SwiftUI

/// Settings, over the tabs, with its own navigation stack. It opens on
/// `model.settingsDestination` when another page links here, and clears it.
struct SettingsRoot: View {
    @Bindable var model: MobileModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {}
                .mobilePageSurface()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("settings-done")
                    }
                }
        }
        .onDisappear { model.settingsDestination = nil }
    }
}
