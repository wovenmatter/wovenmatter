import SwiftUI
import WovenMatterClient

struct BotSettingsConfig: View {
    let state: BotSettingsState
    @State private var config: PiBotConfigDocument?
    @State private var text = ""
    @State private var edited = false
    @State private var baseRevision: String?
    @State private var validation: PiBotConfigValidation?

    var body: some View {
        Group {
            if let config {
                if let effective = config.effective {
                    BotSettingsLimits(effective: effective) { edits in
                        await state.run { client in
                            try await client.updateConfig(edits: edits)
                            state.configSaved()
                            try await refresh(client)
                        }
                    }.disabled(config.path == nil)
                }
                rawCard(config)
            } else { SettingsEmpty("Loading…") }
            SettingsCard(title: "Restart", detail: "Config changes apply when Pi Bot restarts. Running replies get a moment to finish.") {
                Button { state.restartServer() } label: {
                    BotSettingsActionLabel(title: state.restart.isRestarting ? "Restarting…" : "Restart Pi Bot", glyph: .rotate)
                }.disabled(state.disabled)
            }
        }
        .task(id: state.bots.connection) {
            guard state.bots.isConnected else { return }
            await state.load { try await refresh($0) }
        }
    }

    private func refresh(_ client: PiBotClient) async throws {
        let result = try await client.config()
        config = result
        if !edited { text = result.text; baseRevision = result.revision; validation = nil }
    }

    private func rawCard(_ config: PiBotConfigDocument) -> some View {
        SettingsCard(title: "config.toml") {
            if let path = config.path {
                SettingsNote("Everything else lives in the file itself. It's validated before saving.")
                Text(path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            } else { SettingsNote("Pi Bot was started without a config file, so it can't be edited here.") }
            DisclosureGroup("Edit the file") {
                VStack(alignment: .leading, spacing: 10) {
                    BotSettingsTextEditor(text: Binding(get: { text }, set: { text = $0; edited = true; validation = nil }),
                        label: "config.toml", height: 360, monospaced: true)
                    if let validation {
                        if validation.ok {
                            HStack {
                                DashboardLucideIcon(glyph: .check, size: 13)
                                Text("Valid").foregroundStyle(DashboardPalette.success)
                            }
                        } else { SettingsError(validation.error ?? "Invalid config.") }
                    }
                    HStack {
                        Button("Reload file") {
                            Task { await state.run { client in edited = false; try await refresh(client) } }
                        }
                        Button("Save file") { validate(save: true) }.buttonStyle(DashboardPrimaryButtonStyle())
                        Button("Validate") { validate(save: false) }
                    }
                }.padding(.top, 8)
            }.disabled(config.path == nil)
        }
    }

    private func validate(save: Bool) {
        Task {
            await state.run { client in
                let result = try await client.validateConfig(text: text)
                validation = result
                if save, result.ok {
                    try await client.saveConfig(text: text, baseRevision: baseRevision)
                    edited = false; state.configSaved()
                    try await refresh(client)
                }
            }
        }
    }
}

private struct BotSettingsLimits: View {
    let effective: PiBotEffectiveConfig
    let onSave: ([PiBotConfigEdit]) async -> Bool
    @State private var draft: PiBotLimits?
    private var initial: PiBotLimits { PiBotLimits(effective) }
    private var value: PiBotLimits { draft ?? initial }

    var body: some View {
        SettingsCard(title: "Limits & schedule", detail: "How much bots may talk to each other, and when memories are extracted.") {
            field("Bot-to-bot rounds per request", help: "1–100 replies in one exchange.", key: \.maxRounds)
            field("Bot-to-bot messages per hour", help: "Per pair of bots, 1–10000.", key: \.maxMessages)
            field("Memory extraction schedule", help: "5-field cron, e.g. 0 3 * * *.", key: \.schedule)
            field("Extraction time zone", help: "IANA name, e.g. America/New_York.", key: \.timezone)
            if !value.edits(from: initial).isEmpty {
                HStack {
                    Button("Save") {
                        Task { if await onSave(value.edits(from: initial)) { draft = nil } }
                    }.buttonStyle(DashboardPrimaryButtonStyle())
                    Button("Reset") { draft = nil }
                }
            }
        }.onChange(of: effective) { _, _ in draft = nil }
    }

    private func field(_ label: String, help: String, key: WritableKeyPath<PiBotLimits, String>) -> some View {
        SettingsField(label) {
            SettingsNote(help)
            TextField("", text: Binding(get: { value[keyPath: key] }, set: { next in
                var current = value; current[keyPath: key] = next; draft = current
            })).dashboardInput().accessibilityLabel(label)
        }
    }
}
