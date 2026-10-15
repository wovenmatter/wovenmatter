import CompanionClient
import SwiftUI
import WovenMatterCore

struct ProductAnalyticsDisclosureView: View {
    var errorMessage: String? = nil
    let onChoose: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Product analytics").font(.title2.weight(.semibold))
            Text(ProductAnalyticsPolicy.disclosure).fixedSize(horizontal: false, vertical: true)
            Link("Read our privacy policy", destination: ProductAnalyticsPolicy.url)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Turn off analytics") { onChoose(false) }.buttonStyle(
                    SettingsQuietButtonStyle())
                Spacer()
                Button("Continue") { onChoose(true) }.buttonStyle(DashboardPrimaryButtonStyle())
            }
        }.padding(28).frame(width: 520).interactiveDismissDisabled()
    }
}
struct ProductAnalyticsLogView: View {
    let entries: [ProductAnalyticsLogEntry]
    let analyticsID: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Analytics log").font(.title2.weight(.semibold))
                Text(
                    "These are recent analytics send attempts. Failed sends are dropped without replay. PostHog adds approximate country from the central Mac’s network. IP addresses and more precise location are discarded."
                ).font(.caption).foregroundStyle(.secondary)
                if entries.isEmpty {
                    Text("No analytics events recorded.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.event.name.rawValue).font(.headline)
                        Text(entry.event.timestamp.formatted() + " · " + entry.status).font(
                            .caption)
                        Text(entry.event.id).font(.caption.monospaced())
                        Text(entry.event.inspectionJSON(analyticsID: analyticsID)).font(
                            .caption.monospaced())
                    }.textSelection(.enabled)
                    Divider()
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.scrollIndicators(.never).frame(minWidth: 520, minHeight: 380)
    }
}
struct ProductAnalyticsSettingsCard: View {
    @Bindable var analytics: ProductAnalyticsModel
    @State private var showsLog = false
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
            ).toggleStyle(DashboardSwitchToggleStyle()).disabled(analytics.preference == nil)
            Text(
                "This setting applies to your whole central library. Turning it off stops collection; disconnected devices receive the choice when they reconnect."
            ).font(.caption).foregroundStyle(.secondary)
            if let id = analytics.preference?.analyticsID {
                Text("Library analytics ID: " + id).font(.caption.monospaced()).textSelection(
                    .enabled)
            }
            HStack {
                Button("View analytics log") {
                    Task {
                        await analytics.refresh()
                        showsLog = true
                    }
                }.buttonStyle(SettingsQuietButtonStyle())
                Link("Privacy policy", destination: ProductAnalyticsPolicy.url)
            }
            if let error = analytics.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }.task { await analytics.refresh() }.sheet(isPresented: $showsLog) {
            ProductAnalyticsLogView(
                entries: analytics.log,
                analyticsID: analytics.preference?.analyticsID ?? "unavailable")
        }
    }
}
struct MobileAnalyticsSettingsCard: View {
    @Bindable var analytics: MobileAnalyticsModel
    @State private var showsLog = false
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
            ).toggleStyle(DashboardSwitchToggleStyle())
            Text(
                "Library-wide choice. Collection stops here immediately when disabled; the central Mac and other devices receive an offline change after reconnection."
            ).font(.caption).foregroundStyle(.secondary)
            if let id = analytics.state.preference?.analyticsID {
                Text("Library analytics ID: " + id).font(.caption.monospaced()).textSelection(
                    .enabled)
            }
            if analytics.state.pendingEnabled != nil {
                Text("Preference waiting to sync.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("View analytics log") {
                    Task {
                        await analytics.refresh()
                        showsLog = true
                    }
                }.buttonStyle(SettingsQuietButtonStyle())
                Link("Privacy policy", destination: ProductAnalyticsPolicy.url)
            }
            if let error = analytics.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }.sheet(isPresented: $showsLog) {
            ProductAnalyticsLogView(
                entries: Array(analytics.state.log.reversed()),
                analyticsID: analytics.state.preference?.analyticsID ?? "unavailable")
        }
    }
}
