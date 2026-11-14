import SwiftUI
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore

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

    private var bots: BotsModel { model.bots }
    @State private var mcp: WovenMCPAccessSnapshot?
    @State private var mcpUnavailable = false
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
            UpdatesStatusLink(bots: bots, onOpen: onOpenUpdates)
            whereSection
            SettingsSection {
                SettingsSummaryLink(title: "Woven MCP access", value: mcpSummary, action: onOpenWovenMCP)
            }
        }
        .task {
            await bots.refresh()
            do { mcp = try await model.controlMCPAccess(.status) } catch { mcpUnavailable = true }
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { pendingHost != nil }, set: { if !$0 { pendingHost = nil } }
        ), titleVisibility: .visible) {
            Button(pendingHost == "" ? "Turn off" : "Run bots there", role: pendingHost == "" ? .destructive : nil) {
                let target = pendingHost
                pendingHost = nil
                moving = true
                Task {
                    await bots.runBots(on: target?.isEmpty == false ? target : nil)
                    moving = false
                }
            }
            Button("Cancel", role: .cancel) { pendingHost = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: Where bots run

    /// Bots run on one machine. Several running is left over from before that rule.
    private var running: [BotMachine] {
        bots.machines.filter { ![.off, .unreachable].contains($0.state) }
    }

    private var host: BotMachine? {
        running.first { $0.kind == .thisMac } ?? running.first
    }

    private var candidates: [BotMachine] {
        let others = bots.machines.filter { $0.kind != .thisMac && ($0.state != .unreachable || $0.id == host?.id) }
        return (bots.thisMachine.map { [$0] } ?? []) + others
    }

    private var whereSection: some View {
        SettingsSection(title: "Where bots run", detail: "Bots run on one machine. Their files and conversations stay on the machine they were made on.") {
            SettingsRow(title: "Run bots on") {
                if moving { ProgressView().controlSize(.small) }
                SettingsPicker("Run bots on", selection: Binding(
                    get: { host?.id ?? "" },
                    set: { pendingHost = $0 }
                ), options: [""] + candidates.map(\.id)) { id in
                    id.isEmpty ? "Off" : candidates.first { $0.id == id }.map(label) ?? id
                }
                .disabled(moving || bots.busy || bots.perform == nil)
            }
            if running.count > 1 {
                SettingsNote("Bots are running on \(PermissionNames.list(running.map(\.displayName))). Choose one machine above; the others turn off.")
            }
            if let host {
                SettingsDestinationRow(
                    title: host.displayName,
                    detail: BotMachineText.summary(host, bots: bots),
                    status: BotMachineText.state(host),
                    statusTone: BotMachineText.tone(host),
                    icon: { LucideIcon(glyph: host.kind == .linux ? .container : .monitor, size: 15) },
                    action: { onOpenMachine(host.id) }
                )
            } else if bots.machines.isEmpty, let error = bots.loadError {
                SettingsError(error)
            }
            BotsDiscoverDevicesRow(bots: bots)
        }
    }

    private func label(_ machine: BotMachine) -> String {
        machine.kind == .thisMac ? "This Mac" : machine.displayName + (machine.kind == .linux ? " (Linux)" : "")
    }

    private var confirmationTitle: String {
        guard let pendingHost else { return "" }
        if pendingHost.isEmpty { return "Turn off bots?" }
        let name = candidates.first { $0.id == pendingHost }.map(label) ?? "this machine"
        return host == nil ? "Run bots on \(name)?" : "Run bots on \(name) instead?"
    }

    private var confirmationMessage: String {
        let current = running.map(\.displayName)
        if pendingHost == "" {
            return "Running work stops. Bots, their files and conversations stay."
        }
        if current.isEmpty { return "Bots start there. Bots you made on other machines stay on them." }
        return "Bots on \(PermissionNames.list(current)) stop. Their files and conversations stay there."
    }

    private var mcpSummary: String {
        guard let settings = mcp?.botSettings else { return mcpUnavailable ? "Unavailable" : "Loading…" }
        guard settings.isEnabled else { return "Off" }
        let count = WorkspaceToolGroup.configurableCases.filter { settings.groups.contains($0) }.count
        return "\(count) of \(WorkspaceToolGroup.configurableCases.count) tools"
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
/// tools, and each bot's own key.
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
            // The pause switch is gone; a pause set before then can still be lifted.
            if bots.thisMachine?.paused == true {
                SettingsRow(title: "Bots on this Mac are paused", detail: "They can't use Woven MCP until resumed.") {
                    Button("Resume") { Task { await bots.attempt(.setPaused(false)) } }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(bots.busy)
                }
            }
            // A revoked key outlasts turning access off, so keys stay reachable.
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

    /// The operating system bots run on, and how many bots once it is ready. No versions: a
    /// machine that needs updating says so in its status and Settings → Updates.
    @MainActor
    static func summary(_ machine: BotMachine, bots: BotsModel) -> String {
        var parts = [machine.kind == .linux ? "Linux" : "Mac"]
        if let count = bots.session(for: machine.id)?.bots.count, machine.state == .ready {
            parts.append(count == 1 ? "1 bot" : "\(count) bots")
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
