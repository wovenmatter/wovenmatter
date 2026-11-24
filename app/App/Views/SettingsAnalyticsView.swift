import SwiftUI
import WovenProtocol

/// The app's part of the privacy policy on wovenmatter.com, in its words,
/// and the one switch that turns analytics off for the library.
struct SettingsAnalyticsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    let onBack: () -> Void

    var body: some View {
        SettingsPage(
            title: "Analytics and Privacy",
            detail: "We collect analytics to estimate daily, weekly, and monthly active users and to check that our update process is working correctly. We record app opens, qualifying activity, and update progress, without collecting the details of your actions.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            SettingsSection(
                title: "Woven Matter app analytics",
                detail: "Analytics use a random ID shared by the devices connected to your library, along with basic app, system, and update version information. Creating or editing content, starting a session, or sending a message counts as active use; simply opening the app or running it in the background does not. Analytics do not include your content, messages, or credentials. Information you send to connected third-party services, including cloud inference providers, is governed by their privacy policies. App analytics are on by default. You can disable them for your library by turning off “Share product analytics” at the bottom of this page. Offline devices receive the choice when they reconnect."
            ) {}
            SettingsSection(
                title: "Approximate country only",
                detail: "PostHog receives a network IP to process an analytics request and infer approximate country. We configure it to discard stored client IP data and retain only country location fields. City, region, postal code, coordinates, and location time zone are excluded. App country reflects your Macs’ connections, which can differ from a connected device’s location. VPNs and proxies can change the reported country."
            ) {}
            SettingsSection(
                title: "Processor, retention, and contact",
                detail: "We use PostHog Cloud in the United States to process app analytics. Access within Woven Matter is restricted to authorized team members. PostHog and its service providers process the data to provide the service. The service’s reporting window and deletion behavior follow its published retention documentation; a reporting window is not a promise of automatic deletion. Turning collection off does not erase previously delivered events. For privacy questions or deletion requests, email support@wovenmatter.com."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        Link("support@wovenmatter.com", destination: AnalyticsSettings.contact)
                        Link("Privacy policy", destination: AnalyticsSettings.policy)
                    }
                    HStack(spacing: 16) {
                        Link("PostHog privacy policy", destination: URL(string: "https://posthog.com/privacy")!)
                        Link("PostHog retention documentation", destination: URL(string: "https://posthog.com/docs/data/events-retention")!)
                    }
                }
                .font(.settingsBody.weight(.medium))
                .foregroundStyle(WovenPalette.success)
            }
            SettingsSection {
                SettingsToggleRow(
                    title: "Share product analytics",
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
