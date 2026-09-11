import SwiftUI

struct OpenCodeSettingsCard: View {
    @Environment(\.openURL) private var openURL
    @Bindable var model: OpenCodeModel
    var body: some View {
        SettingsCard(title: "OpenCode", detail: "Uses the local OpenCode v2 service. New chats use your Woven Matter workspace.") {
            HStack {
                SettingsPill(model.isConnecting ? "Connecting…" : model.isReady ? "Connected" : "Not connected", tone: model.isReady ? .neutral : .warning)
                Spacer()
                if model.isReady {
                    Button("Open in Browser") {
                        model.perform { openURL(try model.browserURL()) }
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                }
                Button("Connect") { model.perform { try await model.connectLocal() } }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(model.isConnecting || model.isReady)
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
            if !model.canConnect {
                Text("Install OpenCode v2 to connect.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsOpenCodeView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void

    var body: some View {
        SettingsPage(title: "OpenCode",
            detail: "The local OpenCode v2 service and its connection on this Mac.",
            reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            if let openCode = model.openCode { OpenCodeSettingsCard(model: openCode) }
        }
    }
}
