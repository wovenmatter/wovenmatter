import SwiftUI
import WovenMatterClient

struct BotSettingsLoginPanel: View {
    let login: BotSettingsLogin
    let onOpenLink: (URL) -> Void
    let onRespond: (String, String) -> Void
    let onCancel: () -> Void
    let onClose: () -> Void
    let onRetry: (String?) -> Void
    private var progress: PiBotLoginProgress { login.progress }
    private var alternates: [PiBotAccount.LoginMethod] {
        (login.account.loginMethods ?? []).filter { $0.id != (login.method ?? login.account.loginMethods?.first?.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sign in to \(login.account.label)").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: progress.status == .running ? onCancel : onClose) {
                    DashboardLucideIcon(glyph: .close, size: 14)
                }.accessibilityLabel(progress.status == .running ? "Cancel sign-in" : "Close")
            }
            if let device = progress.deviceCode {
                HStack {
                    Text("Open")
                    BotSettingsLink(title: device.verificationUri, url: device.verificationUri, onOpenLink: onOpenLink)
                    Text("and enter:")
                }
                HStack {
                    Text(device.userCode).font(.system(size: 17, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    BotSettingsCopy(title: "Copy code", text: device.userCode)
                }
            }
            if let url = progress.authURL {
                if let instructions = progress.authInstructions { BotSettingsSteps(text: instructions) }
                HStack {
                    BotSettingsLink(title: "Open sign-in page", url: url, onOpenLink: onOpenLink)
                    BotSettingsCopy(title: "Copy link", text: url)
                }
                if progress.needsRedirectPaste {
                    SettingsNote("It ends on a localhost address that won't load. Paste that full URL below.")
                }
            }
            if let prompt = progress.openPrompt {
                if let message = progress.message, progress.authURL == nil, progress.deviceCode == nil {
                    BotSettingsSteps(text: message)
                }
                BotSettingsLoginPrompt(prompt: prompt.prompt) { onRespond(prompt.id, $0) }.id(prompt.id)
            } else if progress.status == .running {
                SettingsEmpty(progress.message ?? "Waiting for the provider…")
            }
            outcome
            if progress.status != .done, !alternates.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsNote(isFailed ? "Try instead" : "Or sign in with")
                    ForEach(alternates) { method in Button(method.label) { onRetry(method.id) } }
                }
            }
        }.padding(.vertical, 8)
    }

    private var isFailed: Bool { if case .failed = progress.status { true } else { false } }

    @ViewBuilder private var outcome: some View {
        switch progress.status {
        case .running: EmptyView()
        case .done:
            HStack {
                DashboardLucideIcon(glyph: .circleCheck, size: 16).foregroundStyle(DashboardPalette.success)
                Text("Signed in.")
            }
        case .failed(let message):
            HStack(alignment: .top) {
                DashboardLucideIcon(glyph: .alertCircle, size: 16).foregroundStyle(DashboardPalette.danger)
                SettingsError(message)
            }
        }
    }
}

private struct BotSettingsLoginPrompt: View {
    let prompt: PiBotLoginPrompt
    let onRespond: (String) -> Void
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch prompt {
            case .select(let message, let options):
                Text(message)
                ForEach(options) { option in
                    Button { onRespond(option.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.label)
                            if let description = option.description { SettingsNote(description) }
                        }
                    }
                }
            case .input(_, let message, _):
                SettingsField(message) {
                    HStack {
                        if prompt.isSecret { SecureField(prompt.placeholder ?? "", text: $value).dashboardInput() }
                        else { TextField(prompt.placeholder ?? "", text: $value).dashboardInput() }
                        Button("Continue") { submit() }
                            .buttonStyle(DashboardPrimaryButtonStyle())
                            .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.onSubmit { submit() }
                }
            }
        }.onDisappear { value = "" }
    }

    private func submit() {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onRespond(value)
    }
}

private struct BotSettingsSteps: View {
    let text: String
    var body: some View {
        let parsed = PiBotLoginSteps(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parsed.lead.enumerated()), id: \.offset) { _, line in SettingsNote(line) }
            ForEach(Array(parsed.steps.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).").font(.system(size: 12.5)).monospacedDigit()
                    SettingsNote(line)
                }
            }
        }
    }
}
