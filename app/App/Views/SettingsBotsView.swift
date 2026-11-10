import SwiftUI
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// Settings → Bots: this Mac's switch, every machine that hosts bots, installing on
/// another device, and version notices. Each machine opens its own page; what bots may
/// do through Woven MCP lives in Settings → Woven MCP.
struct SettingsBotsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    let onBack: () -> Void
    let onOpenMachine: (String) -> Void
    let onOpenWovenMCP: () -> Void

    private var bots: BotsModel { model.bots }
    @State private var mcp: WovenMCPAccessSnapshot?
    @State private var mcpUnavailable = false
    @State private var confirmation: BotsConfirmation?

    var body: some View {
        SettingsPage(
            title: "Bots",
            detail: "Run bots on this Mac, or on another Mac or Linux machine on your tailnet.",
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: backTitle,
            onBack: onBack
        ) {
            BotsVersionNotice(bots: bots)
            thisMacSection
            machinesSection
            SettingsSection {
                SettingsSummaryLink(title: "Woven MCP access", value: mcpSummary, action: onOpenWovenMCP)
            }
        }
        .task {
            await bots.refresh()
            do { mcp = try await model.controlMCPAccess(.status) } catch { mcpUnavailable = true }
        }
        .modifier(BotsConfirmationPresenter(confirmation: $confirmation, bots: bots))
    }

    // MARK: This Mac

    private var thisMacSection: some View {
        SettingsSection(title: "This Mac") {
            SettingsToggleRow(
                title: "Run bots on this Mac",
                detail: "Bots run in a virtual machine on this Mac.",
                isOn: Binding(
                    get: { bots.thisMachine.map { $0.state != .off } ?? false },
                    set: { enabled in
                        if enabled { Task { await bots.attempt(.setEnabled(true)) } }
                        else {
                            confirmation = .init(title: "Turn off bots on this Mac?", action: "Turn off",
                                message: "Running work stops and the virtual machine shuts down. Bots, their files and conversations stay.",
                                destructive: true, command: .setEnabled(false))
                        }
                    })
            )
            .disabled(bots.busy || bots.perform == nil)
        }
    }

    // MARK: Every machine

    private var listedMachines: [BotMachine] {
        bots.machines.filter { $0.kind != .thisMac || $0.state != .off }
    }

    private var machinesSection: some View {
        SettingsSection(title: "Machines", detail: "Where your bots run.") {
            if listedMachines.isEmpty {
                SettingsEmpty(bots.machines.isEmpty ? bots.loadError ?? "Loading…" : "No machine runs bots yet.")
            } else {
                VStack(spacing: 2) {
                    ForEach(listedMachines) { machine in
                        SettingsDestinationRow(
                            title: machine.displayName,
                            detail: BotMachineText.summary(machine, bots: bots),
                            status: BotMachineText.state(machine),
                            statusTone: BotMachineText.tone(machine),
                            icon: { DashboardLucideIcon(glyph: machine.kind == .linux ? .container : .monitor, size: 15) },
                            action: { onOpenMachine(machine.id) }
                        )
                    }
                }
            }
            BotsDiscoverDevicesRow(bots: bots)
        }
    }

    private var mcpSummary: String {
        guard let settings = mcp?.botSettings else { return mcpUnavailable ? "Unavailable" : "Loading…" }
        guard settings.isEnabled else { return "Off" }
        let count = WorkspaceToolGroup.configurableCases.filter { settings.groups.contains($0) }.count
        return bots.thisMachine?.paused == true ? "Paused" : "\(count) of \(WorkspaceToolGroup.configurableCases.count) tools"
    }
}

// MARK: - One machine

/// One machine's bots: status and maintenance, then its profiles, bots and teams, and resources.
struct SettingsBotsMachineView: View {
    @Bindable var bots: BotsModel
    let machineID: String
    /// Remote machines this Mac added; a machine's sign-ins live in its own scope.
    var workspaces: [RemoteWorkspaceConfiguration] = []
    var reservesRailControlSpace = false
    let onBack: () -> Void
    let onOpenSection: (PiBotSettingsSection) -> Void
    let onOpenResources: () -> Void
    var onOpenAccounts: (String) -> Void = { _ in }
    @State private var confirmation: BotsConfirmation?

    private var machine: BotMachine? { bots.machines.first { $0.id == machineID } }

    var body: some View {
        SettingsPage(
            title: machine?.displayName ?? "Machine",
            detail: machine.map { BotMachineText.summary($0, bots: bots) },
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: "Bots",
            onBack: onBack
        ) {
            if let machine {
                statusSection(machine)
                if machine.kind != .thisMac || machine.state != .off { contentSection(machine) }
            } else {
                SettingsEmpty(bots.loadError ?? "That machine isn't connected.")
            }
        }
        .task { await bots.refresh() }
        .modifier(BotsConfirmationPresenter(confirmation: $confirmation, bots: bots))
    }

    private func statusSection(_ machine: BotMachine) -> some View {
        let session = bots.session(for: machine.id)
        return SettingsSection {
            SettingsRow(title: "Status") {
                if machine.state == .starting || session?.updating == true { ProgressView().controlSize(.small) }
                SettingsStatus(BotMachineText.state(machine), tone: BotMachineText.tone(machine))
                if hasActions(machine) {
                    Menu("Manage") {
                        if machine.kind == .thisMac, machine.state != .off {
                            Button("Restart bots") { Task { await bots.attempt(.restartRuntime) } }
                        }
                        if let session, session.isConnected {
                            Button(session.updating ? "Updating bots…" : "Update bots") {
                                Task { await session.updateBots() }
                            }
                            .disabled(session.updating)
                        }
                        if machine.kind == .linux, machine.state != .unreachable {
                            Button("Update server…") {
                                confirmation = .init(title: "Update the Woven server on \(machine.name)?", action: "Update",
                                    message: "Running work there stops while the server updates.", destructive: false,
                                    command: .updateLinuxHost(machineID: machine.id))
                            }
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(bots.busy)
                }
            }
            if let message = machine.message {
                if machine.state == .failed { SettingsError(message) } else { SettingsNote(message) }
            }
            if let progress = session?.progress {
                let bot = progress.botId.flatMap { id in session?.bots.first { $0.id == id }?.name }
                SettingsNote([bot, progress.text].compactMap { $0 }.joined(separator: ": "))
            }
            if session?.isConnected == true {
                SettingsNote("Update bots stops running work, snapshots each bot, updates it, and rolls back on failure.")
            }
        }
    }

    private func hasActions(_ machine: BotMachine) -> Bool {
        (machine.kind == .thisMac && machine.state != .off)
            || bots.session(for: machine.id)?.isConnected == true
            || (machine.kind == .linux && machine.state != .unreachable)
    }

    @ViewBuilder private func contentSection(_ machine: BotMachine) -> some View {
        let session = bots.session(for: machine.id)
        SettingsSection {
            if let session, session.isConnected {
                SettingsSummaryLink(title: PiBotSettingsSection.profiles.title, value: "Models, fallbacks, and thread titles") {
                    onOpenSection(.profiles)
                }
                SettingsSummaryLink(title: PiBotSettingsSection.bots.title,
                                    value: session.bots.count == 1 ? "1 bot" : "\(session.bots.count) bots") {
                    onOpenSection(.bots)
                }
            }
            if machine.state != .unreachable {
                SettingsSummaryLink(title: "Resources", value: BotMachineText.resources(machine), action: onOpenResources)
            }
            accountsLink(machine)
        }
    }

    /// Bots use the subscriptions and API keys of the machine they run on. Bots on
    /// another machine sign in there, through that machine's scope.
    @ViewBuilder private func accountsLink(_ machine: BotMachine) -> some View {
        if machine.kind == .thisMac {
            SettingsSummaryLink(title: "Subscriptions & API Keys", detail: "The sign-ins bots on this Mac use.") {
                onOpenAccounts("global")
            }
        } else if let workspace = workspaces.first(where: {
            $0.name.caseInsensitiveCompare(machine.name) == .orderedSame
                || $0.hostName.caseInsensitiveCompare(machine.name) == .orderedSame
        }) {
            SettingsSummaryLink(title: "Subscriptions & API Keys",
                                detail: "Sign in for bots on \(machine.displayName). Claude signs in on that machine.") {
                onOpenAccounts(workspace.id.uuidString.lowercased())
            }
        } else {
            SettingsNote("Bots on \(machine.displayName) use the sign-ins set up from the Mac that added it.")
        }
    }
}

// MARK: - Woven MCP for bots

/// Settings → Woven MCP → Bots: whether bots on this Mac reach Woven MCP, with which
/// tools, a pause for all of them, and each bot's own key.
struct SettingsBotsMCPAccessSection: View {
    @Bindable var model: ApplicationModel
    @State private var snapshot: WovenMCPAccessSnapshot?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmation: BotsConfirmation?

    private var bots: BotsModel { model.bots }
    private var callers: [WovenBotCaller] { bots.callers.filter { $0.machineID == bots.thisMachineID } }

    private var enabledCount: Int {
        WorkspaceToolGroup.configurableCases.filter { snapshot?.botSettings.groups.contains($0) == true }.count
    }

    var body: some View {
        SettingsSection(title: "Bots", detail: "Each bot on this Mac gets its own key, so its calls are attributed to it.") {
            SettingsToggleRow(
                title: "Give bots Woven MCP",
                isOn: Binding(get: { snapshot?.botSettings.isEnabled ?? false }, set: { update(.setBotsEnabled($0)) })
            )
            .disabled(busy || snapshot == nil)
            if let settings = snapshot?.botSettings, settings.isEnabled {
                SettingsSummaryRow("Tools for bots", value: "\(enabledCount) of \(WorkspaceToolGroup.configurableCases.count)") {
                    ForEach(WorkspaceToolGroup.configurableCases) { group in
                        Toggle(group.title, isOn: Binding(get: { settings.groups.contains(group) },
                                                          set: { update(.setBotsGroup(group, enabled: $0)) }))
                    }
                    .disabled(busy)
                    SettingsNote("Goals and visual replies are included. Sessions reach only your Woven workspaces, under each workspace's own permissions.")
                }
            }
            // A pause or a revoked key outlasts turning access off, so both stay reachable.
            if snapshot?.botSettings.isEnabled == true || bots.thisMachine?.paused == true {
                SettingsToggleRow(
                    title: "Pause for every bot on this Mac",
                    isOn: Binding(get: { bots.thisMachine?.paused ?? false },
                                  set: { paused in Task { await bots.attempt(.setPaused(paused)) } })
                )
                .disabled(bots.busy || bots.thisMachine == nil)
            }
            if !callers.isEmpty { keysRow }
            SettingsHelp {
                SettingsNote("Bots on other machines get their keys from that machine. Outside agents have their own access below.")
            }
            if let error { SettingsError(error) }
        }
        .task {
            await bots.refresh()
            await perform(.status)
        }
        .modifier(BotsConfirmationPresenter(confirmation: $confirmation, bots: bots))
    }

    private var keysRow: some View {
        let revoked = callers.filter(\.revoked).count
        return SettingsSummaryRow("Bot keys", value: revoked == 0 ? "\(callers.count) active" : "\(revoked) revoked",
                                  tone: revoked == 0 ? nil : .warning) {
            ForEach(callers) { caller in
                SettingsRow(title: caller.displayName) {
                    if caller.revoked {
                        SettingsStatus("Revoked", tone: .warning)
                        Button("Reinstate") { Task { await bots.attempt(.reinstateBot(callerID: caller.callerID)) } }
                            .buttonStyle(SettingsQuietButtonStyle())
                    } else {
                        Button("Revoke") {
                            confirmation = .init(title: "Revoke \(caller.displayName)'s Woven MCP key?", action: "Revoke",
                                message: "Its calls stop at once, and sessions it coordinates are released. Reinstate it here to give it a new key.",
                                destructive: true, command: .revokeBot(callerID: caller.callerID))
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                    }
                }
            }
        }
    }

    private func update(_ action: WovenMCPAccessAction) {
        Task { await perform(action) }
    }

    @MainActor
    private func perform(_ action: WovenMCPAccessAction) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { snapshot = try await model.controlMCPAccess(action) }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - Shared

/// How Settings names a machine's state, contents, and resources.
enum BotMachineText {
    static func state(_ machine: BotMachine) -> String {
        switch machine.state {
        case .off: "Off"
        case .starting: "Starting"
        case .ready: machine.paused ? "Paused" : "Running"
        case .unreachable: "Unavailable"
        case .needsUpdate: "Needs update"
        case .failed: "Failed"
        }
    }

    static func tone(_ machine: BotMachine) -> SettingsStatusTone {
        switch machine.state {
        case .ready: machine.paused ? .warning : .good
        case .off, .starting: .neutral
        case .unreachable, .needsUpdate, .failed: .warning
        }
    }

    @MainActor
    static func summary(_ machine: BotMachine, bots: BotsModel) -> String {
        var parts = [machine.kind == .linux ? "Linux" : "Mac"]
        if let count = bots.session(for: machine.id)?.bots.count, machine.state == .ready {
            parts.append(count == 1 ? "1 bot" : "\(count) bots")
        }
        if let runtime = machine.versions.runtime { parts.append("Bots \(runtime)") }
        if let app = machine.versions.app, machine.kind != .thisMac {
            parts.append((machine.kind == .linux ? "Server " : "Woven Matter ") + app)
        }
        return parts.joined(separator: " · ")
    }

    static func resources(_ machine: BotMachine) -> String {
        guard let resources = machine.resources else { return machine.capacity == nil ? "Loading…" : "Defaults" }
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
    let command: BotsCommand
}

struct BotsConfirmationPresenter: ViewModifier {
    @Binding var confirmation: BotsConfirmation?
    let bots: BotsModel

    func body(content: Content) -> some View {
        content.confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { item in
            Button(item.action, role: item.destructive ? .destructive : nil) {
                confirmation = nil
                Task { await bots.attempt(item.command) }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { item in
            Text(item.message)
        }
    }
}
