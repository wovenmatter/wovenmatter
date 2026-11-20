import SwiftUI

/// Settings → Bots: the one machine bots run on, installing on another device, and a
/// link to Settings → Updates when versions differ. The chosen machine opens its own
/// page; what bots may do through Woven MCP lives in Settings → Woven MCP.
struct SettingsBotsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    let onBack: () -> Void
    let onOpenMachine: (String) -> Void
    let onOpenWovenMCP: () -> Void
    var onOpenUpdates: () -> Void = {}

    private var bots: BotsStore { model.bots }
    /// A requested move, waiting for confirmation: the machine ID, or "" for off.
    @State private var pendingHost: String?
    @State private var moving = false

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
            if host != nil { SettingsBotsYouAndForum(bots: bots) }
            SettingsSection {
                SettingsSummaryLink(title: "Woven MCP access", value: mcpSummary, action: onOpenWovenMCP)
            }
        }
        .task { await bots.refresh() }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { pendingHost != nil }, set: { if !$0 { pendingHost = nil } }
        ), titleVisibility: .visible) {
            Button(pendingHost == "" ? "Turn off" : "Run bots there", role: pendingHost == "" ? .destructive : nil) {
                let target = pendingHost
                pendingHost = nil
                moving = true
                Task {
                    if let target, !target.isEmpty { await bots.transfer(to: target) } else { await bots.turnOff() }
                    moving = false
                }
            }
            Button("Cancel", role: .cancel) { pendingHost = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: Where bots run

    /// The home machine, while bots run there.
    private var host: Machine? { bots.state == .off ? nil : bots.homeMachine }

    /// This Mac, then the other Woven machines that are online, and the home machine always.
    private var candidates: [Machine] {
        model.machines.machines.filter { $0.isThisMachine || $0.isOnline || $0.id == host?.id }
    }

    private var whereSection: some View {
        SettingsSection(title: "Where bots run", detail: "Bots run on one machine. Moving them carries their files and conversations along.") {
            SettingsRow(title: "Run bots on") {
                if moving { ProgressView().controlSize(.small) }
                SettingsPicker("Run bots on", selection: Binding(
                    get: { host?.id ?? "" },
                    set: { pendingHost = $0 }
                ), options: [""] + candidates.map(\.id)) { id in
                    id.isEmpty ? "Off" : candidates.first { $0.id == id }.map(label) ?? id
                }
                .disabled(moving || bots.busy || !bots.canChangeHome)
            }
            if let host {
                SettingsDestinationRow(
                    title: bots.displayName,
                    detail: BotMachineText.summary(bots),
                    status: BotMachineText.state(bots),
                    statusTone: BotMachineText.tone(bots),
                    icon: { LucideIcon(glyph: host.platform == .linux ? .container : .monitor, size: 15) },
                    action: { onOpenMachine(host.id) }
                )
            } else if let error = bots.loadError {
                SettingsError(error)
            }
            BotsDiscoverDevicesRow(bots: bots)
        }
    }

    private func label(_ machine: Machine) -> String {
        machine.isThisMachine ? "This Mac" : machine.name + (machine.platform == .linux ? " (Linux)" : "")
    }

    private var confirmationTitle: String {
        guard let pendingHost else { return "" }
        if pendingHost.isEmpty { return "Turn off bots?" }
        let name = candidates.first { $0.id == pendingHost }.map(label) ?? "this machine"
        return host == nil ? "Run bots on \(name)?" : "Run bots on \(name) instead?"
    }

    private var confirmationMessage: String {
        if pendingHost == "" {
            return "Running work stops. Bots, their files and conversations stay."
        }
        guard host != nil else { return "Bots start there." }
        return "Bots on \(bots.displayName) stop and move there with their files and conversations. Sign-ins are made again on the new machine."
    }

    private var mcpSummary: String {
        guard let access = bots.toolAccess else { return bots.isConnected ? "Loading…" : "Unavailable" }
        guard access.isEnabled else { return "Off" }
        let count = WorkspaceToolGroup.configurableCases.filter { access.groups.contains($0) }.count
        return "\(count) of \(WorkspaceToolGroup.configurableCases.count) tools"
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
    @State private var confirmation: BotsConfirmation?
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
        .modifier(BotsConfirmationPresenter(confirmation: $confirmation))
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
                if hasActions {
                    Menu("Manage") {
                        if bots.state != .off, bots.state != .unreachable {
                            Button("Restart bots") { Task { await bots.restart() } }
                        }
                        if bots.isConnected {
                            Button(bots.updating ? "Updating bots…" : "Update bots") {
                                // Moving bots to a new image replaces their containers: ask first.
                                if bots.botsOnOlderImage > 0 { confirmingImageMove = true }
                                else { Task { await bots.updateBots() } }
                            }
                            .disabled(bots.updating)
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(bots.busy)
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

    private var hasActions: Bool {
        (bots.state != .off && bots.state != .unreachable) || bots.isConnected
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

// MARK: - Woven MCP for bots

/// Settings → Woven MCP → Bots: whether bots reach Woven MCP, with which tools, and each
/// bot's own access.
struct SettingsBotsMCPAccessSection: View {
    @Bindable var model: ApplicationModel
    @State private var busy = false
    @State private var error: String?
    @State private var confirmation: BotsConfirmation?

    private var bots: BotsStore { model.bots }

    private var enabledCount: Int {
        WorkspaceToolGroup.configurableCases.filter { bots.toolAccess?.groups.contains($0) == true }.count
    }

    var body: some View {
        SettingsSection(title: "Bots", detail: "Each bot's calls are attributed to it.") {
            SettingsToggleRow(
                title: "Give bots Woven MCP",
                isOn: Binding(get: { bots.toolAccess?.isEnabled ?? false }, set: { enabled in
                    perform { try await bots.setToolsEnabled(enabled) }
                })
            )
            .disabled(busy || bots.toolAccess == nil)
            if let access = bots.toolAccess, access.isEnabled {
                SettingsSummaryRow("Tools for bots", value: "\(enabledCount) of \(WorkspaceToolGroup.configurableCases.count)") {
                    ForEach(WorkspaceToolGroup.configurableCases) { group in
                        Toggle(group.title, isOn: Binding(get: { access.groups.contains(group) },
                                                          set: { enabled in perform { try await bots.setToolGroup(group, enabled: enabled) } }))
                    }
                    .disabled(busy)
                    SettingsNote("Goals and visual replies are included. Sessions reach only your Woven workspaces, under each workspace's own permissions.")
                }
            }
            // It reads like a bot's revoked access below: revoked, and Reinstate brings it back.
            if bots.toolsPaused {
                SettingsRow(title: "Woven MCP access is revoked for bots", detail: "Their Woven MCP calls are refused until you reinstate it. The bots themselves keep running.") {
                    Button("Reinstate") { Task { await bots.setToolsPaused(false) } }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(bots.busy)
                }
            }
            // Revoked access outlasts turning access off, so each bot stays reachable.
            if !bots.bots.isEmpty { accessRow }
            SettingsHelp {
                SettingsNote("Outside agents have their own access below.")
            }
            if let error { SettingsError(error) }
        }
        .task { await bots.refresh() }
        .modifier(BotsConfirmationPresenter(confirmation: $confirmation))
    }

    private var accessRow: some View {
        let revoked = bots.bots.filter { !bots.mayUseWovenTools($0.id) }.count
        return SettingsSummaryRow("Bot access", value: revoked == 0 ? "\(bots.bots.count) active" : "\(revoked) revoked",
                                  tone: revoked == 0 ? nil : .warning) {
            ForEach(bots.bots) { bot in
                SettingsRow(title: bot.name) {
                    if !bots.mayUseWovenTools(bot.id) {
                        SettingsStatus("Revoked", tone: .warning)
                        Button("Reinstate") { Task { await bots.setMayUseWovenTools(botID: bot.id, true) } }
                            .buttonStyle(SettingsQuietButtonStyle())
                    } else {
                        Button("Revoke") {
                            confirmation = .init(title: "Revoke \(bot.name)'s Woven MCP access?", action: "Revoke",
                                message: "Its calls stop at once, and sessions it coordinates are released. Reinstate it here to give it back.",
                                destructive: true) { await bots.setMayUseWovenTools(botID: bot.id, false) }
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                    }
                }
            }
        }
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
        case .ready: bots.toolsPaused ? "Woven MCP revoked" : "Running"
        case .unreachable: "Unavailable"
        case .needsUpdate: "Needs update"
        case .failed: "Failed"
        }
    }

    static func tone(_ bots: BotsStore) -> SettingsStatusTone {
        switch bots.state {
        case .ready: bots.toolsPaused ? .warning : .good
        case .off, .starting: .neutral
        case .unreachable, .needsUpdate, .failed: .warning
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

struct BotsConfirmation {
    let title: String
    let action: String
    let message: String
    let destructive: Bool
    let work: @MainActor () async -> Void
}

struct BotsConfirmationPresenter: ViewModifier {
    @Binding var confirmation: BotsConfirmation?

    func body(content: Content) -> some View {
        content.confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { item in
            Button(item.action, role: item.destructive ? .destructive : nil) {
                confirmation = nil
                Task { await item.work() }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { item in
            Text(item.message)
        }
    }
}
