import SwiftUI
import Observation
import WovenMatterClient

/// Bot settings that belong to one machine's runtime: profiles, bots and teams.
/// Provider connections, search and sign-ins are Woven's own, in Settings → Connections.
enum PiBotSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case profiles, bots
    var id: String { rawValue }
    var title: String {
        switch self {
        case .profiles: "Profiles"
        case .bots: "Bots and teams"
        }
    }
    var detail: String {
        switch self {
        case .profiles: "Main models, fallbacks, model pools, and thread titles."
        case .bots: "Roles, teams, memory, rebuilds, and deleted bots."
        }
    }
    var glyph: DashboardLucideGlyph {
        switch self {
        case .profiles: .brain
        case .bots: .bot
        }
    }
}

/// One settings section of one machine's runtime, native over its protocol.
struct SettingsBotsSectionPage: View {
    @Bindable var bots: BotMachineSession
    let section: PiBotSettingsSection
    var reservesRailControlSpace = false
    let onBack: () -> Void
    @State private var state: BotSettingsState

    init(bots: BotMachineSession, section: PiBotSettingsSection, reservesRailControlSpace: Bool = false,
         onBack: @escaping () -> Void) {
        self.bots = bots; self.section = section
        self.reservesRailControlSpace = reservesRailControlSpace
        self.onBack = onBack
        _state = State(initialValue: BotSettingsState(bots: bots))
    }

    var body: some View {
        SettingsPage(title: section.title, detail: section.detail + " On \(bots.displayName).",
                     reservesRailControlSpace: reservesRailControlSpace, backTitle: "Bots", onBack: onBack) {
            BotSettingsErrorNotice(state: state)
            if !bots.isConnected { SettingsEmpty("Bots on \(bots.displayName) are not connected.") }
            sectionBody
                .disabled(state.disabled)
        }
        .font(.system(size: 13))
        .buttonStyle(SettingsQuietButtonStyle())
        .modifier(BotSettingsConfirmationPresenter(state: state))
    }

    @ViewBuilder private var sectionBody: some View {
        switch section {
        case .profiles: BotSettingsProfiles(state: state)
        case .bots: BotSettingsBots(state: state)
        }
    }
}

@MainActor @Observable
final class BotSettingsState {
    let bots: BotMachineSession
    var error: String?
    var confirmation: BotSettingsConfirmation?
    private(set) var pending = 0
    var disabled: Bool { !bots.isConnected || pending > 0 }

    init(bots: BotMachineSession) { self.bots = bots }

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
