import SwiftUI
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// Settings → Bots: every machine that hosts bots, this Mac's own switch and
/// resources, discovery, updates, and what bots may do through Woven MCP.
struct SettingsBotsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    let onBack: () -> Void
    let onOpenSection: (String, PiBotSettingsSection) -> Void
    let onOpenResources: (String) -> Void
    let onOpenConnections: () -> Void

    private var bots: BotsModel { model.bots }
    @State private var mcp: WovenMCPAccessSnapshot?
    @State private var mcpBusy = false
    @State private var error: String?
    @State private var confirmation: BotsConfirmation?

    var body: some View {
        SettingsPage(
            title: "Bots",
            detail: "Bots run on your Macs and Linux machines and use the provider connections in Woven Matter. Closing this window leaves them running.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            BotsVersionNotice(bots: bots)
            thisMacCard
            machinesCard
            BotsDiscoverDevicesCard(bots: bots)
            wovenCard
            if let error { SettingsError(error) }
        }
        .task { await bots.refresh(); await refreshMCP() }
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
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

    // MARK: This Mac

    private var thisMacCard: some View {
        SettingsCard(title: "This Mac", detail: "Bots on this Mac run in Woven's own Linux virtual machine, separate from any Docker you use.") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Run bots on this Mac", isOn: Binding(
                    get: { bots.thisMachine.map { $0.state != .off } ?? false },
                    set: { enabled in
                        if enabled { Task { await bots.attempt(.setEnabled(true)) } }
                        else {
                            confirmation = .init(title: "Turn off bots on this Mac?", action: "Turn off",
                                message: "Running work stops and the virtual machine shuts down. Bots, their files and conversations stay.",
                                destructive: true, command: .setEnabled(false))
                        }
                    }))
                    .toggleStyle(DashboardSwitchToggleStyle())
                    .disabled(bots.busy || bots.perform == nil)
                if let machine = bots.thisMachine, machine.state != .off {
                    machineStatus(machine)
                    HStack(spacing: 8) {
                        Button("Resources") { onOpenResources(machine.id) }
                        Button("Restart bots") { Task { await bots.attempt(.restartRuntime) } }.disabled(bots.busy)
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                }
            }
            .font(.system(size: 13))
        }
    }

    // MARK: Every machine

    private var machinesCard: some View {
        SettingsCard(title: "Machines", detail: "Every machine whose Woven server runs bots. Each keeps its own bots; nothing moves between them.") {
            VStack(alignment: .leading, spacing: 12) {
                if bots.machines.isEmpty { SettingsEmpty(bots.loadError ?? "Loading…") }
                ForEach(bots.machines) { machine in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            DashboardLucideIcon(glyph: machine.kind == .linux ? .container : .monitor, size: 15).frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(machine.displayName).font(.system(size: 13, weight: .medium))
                                Text(summary(machine)).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                            }
                            Spacer(minLength: 8)
                            if machine.state == .starting || machine.updating { ProgressView().controlSize(.small) }
                            SettingsPill(stateLabel(machine), tone: [.ready, .off].contains(machine.state) ? .neutral : .warning)
                        }
                        if let message = machine.message, machine.kind != .thisMac { SettingsNote(message) }
                        machineActions(machine).padding(.leading, 34)
                    }
                }
            }
            .font(.system(size: 13))
            .buttonStyle(SettingsQuietButtonStyle())
        }
    }

    @ViewBuilder private func machineActions(_ machine: BotMachine) -> some View {
        let session = bots.session(for: machine.id)
        HStack(spacing: 8) {
            if machine.kind != .thisMac, machine.state != .unreachable {
                Button("Resources") { onOpenResources(machine.id) }
            }
            if let session, session.isConnected {
                ForEach(PiBotSettingsSection.allCases) { section in
                    Button(section.title) { onOpenSection(machine.id, section) }
                }
                Button(session.progress != nil ? "Updating bots…" : "Update bots") {
                    confirmation = nil
                    Task { await session.updateBots() }
                }
                .disabled(session.progress != nil)
                .help("Stops running work, snapshots each bot, updates it and rolls back on failure.")
            }
            if machine.kind == .linux, machine.state != .unreachable {
                Button("Update host") {
                    confirmation = .init(title: "Update the Woven server on \(machine.name)?", action: "Update",
                        message: "Running work there stops while the server updates.", destructive: false,
                        command: .updateLinuxHost(machineID: machine.id))
                }
            }
        }
        if let progress = session?.progress {
            SettingsNote([progress.phase.capitalized, progress.message].compactMap { $0 }.joined(separator: ": "))
        }
    }

    private func machineStatus(_ machine: BotMachine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if machine.state == .starting { ProgressView().controlSize(.small) }
                Text(summary(machine)).font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
            }
            if let message = machine.message {
                if machine.state == .failed { SettingsError(message) } else { SettingsNote(message) }
            }
        }
    }

    private func stateLabel(_ machine: BotMachine) -> String {
        switch machine.state {
        case .off: "Off"
        case .starting: "Starting"
        case .ready: machine.paused ? "Paused" : "Running"
        case .unreachable: "Unavailable"
        case .needsUpdate: "Needs update"
        case .failed: "Failed"
        }
    }

    private func summary(_ machine: BotMachine) -> String {
        var parts = [machine.kind == .linux ? "Linux" : "Mac"]
        if let count = bots.session(for: machine.id)?.bots.count, machine.state == .ready { parts.append(count == 1 ? "1 bot" : "\(count) bots") }
        if let runtime = machine.versions.runtime { parts.append("Bots \(runtime)") }
        if let app = machine.versions.app, machine.kind != .thisMac { parts.append((machine.kind == .linux ? "Server " : "Woven Matter ") + app) }
        if let resources = machine.resources {
            parts.append("RAM " + BotResourcePolicy.format(resources.poolBytes))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Woven MCP

    private var thisMacCallers: [WovenBotCaller] {
        bots.callers.filter { $0.machineID == bots.thisMachineID }
    }

    private var wovenCard: some View {
        SettingsCard(title: "Woven MCP access", detail: "Each bot on this Mac gets its own Woven MCP key, so its calls are attributed to it. Bots on other machines get theirs from that machine. Separate from outside-agent access.") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Give bots Woven MCP", isOn: Binding(get: { mcp?.botSettings.isEnabled ?? false },
                                                            set: { update(.setBotsEnabled($0)) }))
                    .disabled(mcpBusy || mcp == nil)
                if let settings = mcp?.botSettings, settings.isEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(WorkspaceToolGroup.configurableCases) { group in
                            Toggle(group.title, isOn: Binding(get: { settings.groups.contains(group) },
                                                              set: { update(.setBotsGroup(group, enabled: $0)) }))
                        }
                        .disabled(mcpBusy)
                        SettingsNote("Goals and visual replies are included. Sessions reach only your Woven workspaces, under each workspace's own permissions.")
                    }
                    .padding(.leading, 38)
                }
                Toggle("Pause Woven MCP for every bot on this Mac", isOn: Binding(
                    get: { bots.thisMachine?.paused ?? false },
                    set: { paused in Task { await bots.attempt(.setPaused(paused)) } }))
                    .disabled(bots.busy || bots.thisMachine == nil)
                if !thisMacCallers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(thisMacCallers) { caller in
                            HStack {
                                Text(caller.displayName).font(.system(size: 13))
                                if caller.revoked { SettingsPill("Revoked", tone: .warning) }
                                Spacer()
                                if caller.revoked {
                                    Button("Reinstate") { Task { await bots.attempt(.reinstateBot(callerID: caller.callerID)) } }
                                } else {
                                    Button("Revoke") {
                                        confirmation = .init(title: "Revoke \(caller.displayName)'s Woven MCP key?", action: "Revoke",
                                            message: "Its calls stop at once, and sessions it coordinates are released. Reinstate it here to give it a new key.",
                                            destructive: true, command: .revokeBot(callerID: caller.callerID))
                                    }
                                }
                            }
                        }
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                }
            }
            .font(.system(size: 13))
            .toggleStyle(DashboardSwitchToggleStyle())
        }
    }

    private func refreshMCP() async {
        mcp = try? await model.controlMCPAccess(.status)
    }

    private func update(_ action: WovenMCPAccessAction) {
        guard !mcpBusy else { return }
        mcpBusy = true
        Task {
            defer { mcpBusy = false }
            do { mcp = try await model.controlMCPAccess(action) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct BotsConfirmation {
    let title: String
    let action: String
    let message: String
    let destructive: Bool
    let command: BotsCommand
}
