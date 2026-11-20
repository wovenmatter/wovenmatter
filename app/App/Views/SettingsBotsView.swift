import SwiftUI

/// Settings → Bots: the one machine bots run on, what they may use, and a link to
/// Settings → Updates when versions differ. The chosen machine opens its own page.
struct SettingsBotsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    let onBack: () -> Void
    let onOpenMachine: (String) -> Void
    var onOpenUpdates: () -> Void = {}

    private var bots: BotsStore { model.bots }
    /// A chosen home machine, waiting for confirmation.
    @State private var pendingHost: String?
    @State private var choosing = false

    var body: some View {
        SettingsPage(
            title: "Bots",
            detail: "Run bots on this Mac, or on another Mac or Linux machine on your tailnet.",
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: backTitle,
            onBack: onBack
        ) {
            UpdatesStatusLink(updates: model.updates, onOpen: onOpenUpdates)
            whereSection
            if host != nil {
                SettingsBotsYouAndForum(bots: bots)
                SettingsBotsAccessSection(bots: bots)
            }
        }
        .task { await bots.refresh() }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { pendingHost != nil }, set: { if !$0 { pendingHost = nil } }
        ), titleVisibility: .visible) {
            Button("Run bots there") {
                let target = pendingHost
                pendingHost = nil
                choosing = true
                Task {
                    if let target { await bots.chooseHome(target) }
                    choosing = false
                }
            }
            Button("Cancel", role: .cancel) { pendingHost = nil }
        } message: {
            Text("Bots start there.")
        }
    }

    // MARK: Where bots run

    /// The home machine, once one is chosen.
    private var host: Machine? { bots.homeMachine }

    /// This Mac, then the other Woven machines that are online.
    private var candidates: [Machine] {
        model.machines.machines.filter { $0.isThisMachine || $0.isOnline }
    }

    private var whereSection: some View {
        SettingsSection(title: "Where bots run", detail: "Bots run on one machine.") {
            if let host {
                SettingsDestinationRow(
                    title: bots.displayName,
                    detail: BotMachineText.summary(bots),
                    status: BotMachineText.state(bots),
                    statusTone: BotMachineText.tone(bots),
                    icon: { LucideIcon(glyph: host.platform == .linux ? .container : .monitor, size: 15) },
                    action: { onOpenMachine(host.id) }
                )
            } else {
                // Only while no machine is chosen: there is one set of bots.
                SettingsRow(title: "Run bots on") {
                    if choosing { ProgressView().controlSize(.small) }
                    SettingsPicker("Run bots on", selection: Binding(
                        get: { "" },
                        set: { if !$0.isEmpty { pendingHost = $0 } }
                    ), options: [""] + candidates.map(\.id)) { id in
                        id.isEmpty ? "Off" : candidates.first { $0.id == id }.map(label) ?? id
                    }
                    .disabled(choosing || bots.homeMachineID != nil)
                }
            }
            if let error = bots.loadError { SettingsError(error) }
        }
    }

    private func label(_ machine: Machine) -> String {
        machine.isThisMachine ? "This Mac" : machine.name + (machine.platform == .linux ? " (Linux)" : "")
    }

    private var confirmationTitle: String {
        guard let pendingHost else { return "" }
        let name = candidates.first { $0.id == pendingHost }.map(label) ?? "this machine"
        return "Run bots on \(name)?"
    }
}

// MARK: - One machine

/// The bots' home machine: status and maintenance, then its profiles, bots and teams, and resources.
struct SettingsBotsMachineView: View {
    @Bindable var bots: BotsStore
    let machineID: String
    var reservesRailControlSpace = false
    let onBack: () -> Void
    let onOpenSection: (PiBotSettingsSection) -> Void
    let onOpenResources: () -> Void
    var onOpenAccounts: (String) -> Void = { _ in }
    @State private var confirmingImageMove = false

    private var machine: Machine? { bots.homeMachine.flatMap { $0.id == machineID ? $0 : nil } }

    var body: some View {
        SettingsPage(
            title: machine == nil ? "Machine" : bots.displayName,
            detail: machine.map { _ in BotMachineText.summary(bots) },
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: "Bots",
            onBack: onBack
        ) {
            if let machine {
                statusSection(machine)
                if !machine.isThisMachine || bots.state != .off { contentSection(machine) }
            } else {
                SettingsEmpty(bots.loadError ?? "That machine isn't connected.")
            }
        }
        .task { await bots.refresh() }
        .confirmationDialog("Move bots to the new container image?", isPresented: $confirmingImageMove,
                            titleVisibility: .visible) {
            Button("Update bots") { Task { await bots.updateBots() }; confirmingImageMove = false }
            Button("Cancel", role: .cancel) { confirmingImageMove = false }
        } message: {
            let count = bots.botsOnOlderImage
            Text("\(count == 1 ? "1 bot moves" : "\(count) bots move") to a new container image with new tools. Their files, home folders, browser sign-ins, and the packages they installed come along, and each bot gets a report of anything that didn't. Each bot is snapshotted first and rolled back if the update fails.")
        }
    }

    private func statusSection(_ machine: Machine) -> some View {
        SettingsSection {
            SettingsRow(title: "Status") {
                if bots.state == .starting || bots.updating { ProgressView().controlSize(.small) }
                SettingsStatus(BotMachineText.state(bots), tone: BotMachineText.tone(bots))
                if bots.isConnected {
                    Menu("Manage") {
                        Button(bots.updating ? "Updating bots…" : "Update bots") {
                            // Moving bots to a new image replaces their containers: ask first.
                            if bots.botsOnOlderImage > 0 { confirmingImageMove = true }
                            else { Task { await bots.updateBots() } }
                        }
                        .disabled(bots.updating)
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .buttonStyle(SettingsQuietButtonStyle())
                }
            }
            if let message = bots.message {
                if bots.state == .failed { SettingsError(message) } else { SettingsNote(message) }
            }
            if let progress = bots.progress {
                let bot = progress.botID.flatMap { id in bots.bots.first { $0.id == id }?.name }
                SettingsNote([bot, progress.text].compactMap { $0 }.joined(separator: ": "))
            }
            if bots.isConnected {
                SettingsNote("Update bots stops running work, snapshots each bot, moves it to the current container image if it is on an older one, updates it, and rolls back on failure.")
            }
        }
    }

    @ViewBuilder private func contentSection(_ machine: Machine) -> some View {
        SettingsSection {
            if bots.isConnected {
                SettingsSummaryLink(title: PiBotSettingsSection.profiles.title, value: "Models, fallbacks, and thread titles") {
                    onOpenSection(.profiles)
                }
                SettingsSummaryLink(title: PiBotSettingsSection.bots.title,
                                    value: bots.bots.count == 1 ? "1 bot" : "\(bots.bots.count) bots") {
                    onOpenSection(.bots)
                }
            }
            if bots.state != .unreachable {
                SettingsSummaryLink(title: "Resources", value: BotMachineText.resources(bots), action: onOpenResources)
            }
            // Bots use the subscriptions and API keys of the machine they run on.
            SettingsSummaryLink(title: "Subscriptions & API Keys",
                                detail: machine.isThisMachine ? "The sign-ins your bots use." : "Sign in for your bots on \(machine.name).") {
                onOpenAccounts(machine.id)
            }
        }
    }
}

// MARK: - Bot access

/// Settings → Bots → Bot access: which bots may use the Woven tools, and one switch that pauses
/// them for every bot.
struct SettingsBotsAccessSection: View {
    @Bindable var bots: BotsStore
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        SettingsSection(title: "Bot access") {
            SettingsToggleRow(
                title: "Pause Woven tools for every bot",
                isOn: Binding(get: { bots.toolsPaused }, set: { paused in perform { try await bots.setToolsPaused(paused) } })
            )
            if !bots.bots.isEmpty {
                let allowed = bots.bots.filter { bots.mayUseWovenTools($0.id) }.count
                SettingsSummaryRow("May use Woven tools", value: "\(allowed) of \(bots.bots.count)") {
                    ForEach(bots.bots) { bot in
                        SettingsToggleRow(title: bot.name, isOn: Binding(get: { bots.mayUseWovenTools(bot.id) }, set: { allowed in
                            perform { try await bots.setMayUseWovenTools(botID: bot.id, allowed) }
                        }))
                    }
                }
            }
            if let error { SettingsError(error) }
        }
        .disabled(busy)
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await work() } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Shared

/// How Settings names the bots' state, contents, and resources.
@MainActor
enum BotMachineText {
    static func state(_ bots: BotsStore) -> String {
        switch bots.state {
        case .off: "Off"
        case .starting: "Starting"
        case .ready: "Running"
        case .unreachable: "Unavailable"
        case .failed: "Failed"
        }
    }

    static func tone(_ bots: BotsStore) -> SettingsStatusTone {
        switch bots.state {
        case .ready: .good
        case .off, .starting: .neutral
        case .unreachable, .failed: .warning
        }
    }

    /// The operating system bots run on, and how many bots once it is ready. No versions: a
    /// machine that needs updating says so in its status and Settings → Updates.
    static func summary(_ bots: BotsStore) -> String {
        var parts = [bots.homeMachine?.platform.displayName ?? "Mac"]
        if bots.state == .ready, bots.hasLoadedBots {
            parts.append(bots.bots.count == 1 ? "1 bot" : "\(bots.bots.count) bots")
        }
        return parts.joined(separator: " · ")
    }

    static func resources(_ bots: BotsStore) -> String {
        guard let resources = bots.resources else { return bots.capacity == nil ? "Loading…" : "Defaults" }
        func amount(_ bytes: Int64?, _ name: String) -> String {
            bytes == nil ? "No \(name) cap" : BotResourcePolicy.format(bytes) + " " + name
        }
        return amount(resources.poolBytes, "memory") + " · " + amount(resources.diskBytes, "disk")
    }
}
