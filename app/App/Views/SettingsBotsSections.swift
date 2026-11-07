import SwiftUI
import Observation
import WovenMatterClient

/// One of Pi Bot's settings sections, native over its protocol.
struct SettingsBotsSectionPage: View {
    @Bindable var bots: BotsModel
    let section: PiBotSettingsSection
    var reservesRailControlSpace = false
    let onBack: () -> Void
    let onOpenLink: (URL) -> Void
    @State private var state: BotSettingsState

    init(bots: BotsModel, section: PiBotSettingsSection, reservesRailControlSpace: Bool = false,
         onBack: @escaping () -> Void, onOpenLink: @escaping (URL) -> Void) {
        self.bots = bots; self.section = section
        self.reservesRailControlSpace = reservesRailControlSpace
        self.onBack = onBack; self.onOpenLink = onOpenLink
        _state = State(initialValue: BotSettingsState(bots: bots))
    }

    var body: some View {
        SettingsPage(title: section.title, detail: section.detail,
                     reservesRailControlSpace: reservesRailControlSpace, backTitle: "Bots", onBack: onBack) {
            BotSettingsErrorNotice(state: state)
            BotSettingsRestartNotice(state: state)
            if !bots.isConnected { SettingsEmpty("Bots are not connected.") }
            sectionBody
                .disabled(state.disabled)
        }
        .font(.system(size: 13))
        .buttonStyle(SettingsQuietButtonStyle())
        .modifier(BotSettingsConfirmationPresenter(state: state))
        .task(id: bots.connection) {
            state.connectionChanged()
            await state.refreshRestartRequired()
        }
    }

    @ViewBuilder private var sectionBody: some View {
        switch section {
        case .accounts:
            BotSettingsAccounts(state: state, onOpenLink: onOpenLink)
        case .profiles:
            BotSettingsProfiles(state: state)
        case .bots:
            BotSettingsBots(state: state)
        case .search:
            BotSettingsSearch(state: state, onOpenLink: onOpenLink)
        case .github:
            BotSettingsGitHub(state: state, onOpenLink: onOpenLink)
        case .config:
            BotSettingsConfig(state: state)
        case .general:
            SettingsCard(title: "Build") {
                SettingsValueRow(label: "Pi Bot", value: bots.runtime.health?.version ?? "Development build")
            }
        }
    }
}

@MainActor @Observable
final class BotSettingsState {
    let bots: BotsModel
    var error: String?
    var confirmation: BotSettingsConfirmation?
    var restartRequired = false
    private(set) var restart = PiBotRestartProgress()
    private(set) var pending = 0
    @ObservationIgnored private var restartTimer: Task<Void, Never>?
    var disabled: Bool { !bots.isConnected || pending > 0 || restart.isRestarting }

    init(bots: BotsModel) { self.bots = bots }

    /// Reads don't disable anything, so a background refresh never takes focus from a field.
    @discardableResult
    func load(_ work: @MainActor (PiBotClient) async throws -> Void) async -> Bool {
        guard let client = bots.connectedClient else { return false }
        do {
            try await work(client)
            return true
        } catch is CancellationError {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// A change: the section's controls wait until it finishes.
    @discardableResult
    func run(_ work: @MainActor (PiBotClient) async throws -> Void) async -> Bool {
        guard let client = bots.connectedClient else { error = "Bots are not connected."; return false }
        error = nil
        pending += 1
        defer { pending -= 1 }
        do {
            try await work(client)
            return true
        } catch is CancellationError {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func confirm(_ title: String, action: String, destructive: Bool = true,
                 work: @escaping @MainActor () -> Void) {
        confirmation = BotSettingsConfirmation(title: title, action: action, destructive: destructive, work: work)
    }

    func configSaved() { restartRequired = true }

    func refreshRestartRequired() async {
        guard let client = bots.connectedClient else { return }
        do {
            let document = try await client.config()
            if document.restartRequired { restartRequired = true }
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    func restartServer() {
        guard !disabled else { return }
        Task {
            await run { client in
                let result = try await client.restartServer()
                bots.expectRestart()
                restart = PiBotRestartProgress(activeWork: result.activeWork, mode: result.mode)
                connectionChanged()
                startRestartTimer()
            }
        }
    }

    func connectionChanged() {
        let wasRestarting = restart.isRestarting
        restart.connectionChanged(connected: bots.isConnected)
        if wasRestarting, restart.phase == .back {
            restartRequired = false
            startRestartTimer()
        }
    }

    private func startRestartTimer() {
        restartTimer?.cancel()
        let phase = restart.phase
        guard phase == .restarting || phase == .back else { return }
        restartTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(phase == .restarting ? 90 : 10)) }
            catch { return }
            guard let self else { return }
            if phase == .restarting { restart.timedOut() }
            else { restart = PiBotRestartProgress() }
        }
    }
}

struct BotSettingsConfirmation {
    let title: String
    let action: String
    let destructive: Bool
    let work: @MainActor () -> Void
}

struct BotSettingsConfirmationPresenter: ViewModifier {
    @Bindable var state: BotSettingsState

    func body(content: Content) -> some View {
        content.confirmationDialog(state.confirmation?.title ?? "", isPresented: Binding(
            get: { state.confirmation != nil }, set: { if !$0 { state.confirmation = nil } }
        ), titleVisibility: .visible, presenting: state.confirmation) { item in
            Button(item.action, role: item.destructive ? .destructive : nil) {
                state.confirmation = nil
                item.work()
            }
            .disabled(state.disabled)
            Button("Cancel", role: .cancel) { state.confirmation = nil }
        }
    }
}

struct BotSettingsErrorNotice: View {
    @Bindable var state: BotSettingsState
    var body: some View {
        if let error = state.error {
            BotDismissibleError(text: error) { state.error = nil }
        }
    }
}

struct BotSettingsRestartNotice: View {
    let state: BotSettingsState

    private var tint: Color {
        switch state.restart.phase {
        case .back: DashboardPalette.success
        case .failed: DashboardPalette.danger
        case .restarting: DashboardPalette.primary
        case .idle: DashboardPalette.warning
        }
    }

    var body: some View {
        if let message = state.restart.message(show: state.restartRequired) {
            HStack(spacing: 10) {
                DashboardLucideIcon(glyph: .rotate, size: 15)
                Text(message)
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if state.restart.phase == .idle || state.restart.phase == .failed {
                    Button("Restart and apply") { state.restartServer() }
                        .buttonStyle(DashboardPrimaryButtonStyle())
                        .disabled(state.disabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
        }
    }
}
