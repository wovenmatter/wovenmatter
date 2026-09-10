import SwiftUI

struct OpenCodeSettingsCard: View {
    @Bindable var model: OpenCodeModel
    var body: some View {
        SettingsCard(title: "OpenCode", detail: "Uses the local OpenCode v2 service. New chats use your Woven Matter workspace.") {
            HStack {
                Text(model.isConnecting ? "Connecting…" : model.isReady ? "Connected" : "Not connected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Connect") { model.perform { try await model.connectLocal() } }
                    .disabled(model.isConnecting || model.isReady)
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
            if !model.canConnect {
                Text("Install OpenCode v2 to connect.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
