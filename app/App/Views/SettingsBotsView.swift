import SwiftUI
import WovenMatterClient
import WovenMatterCore

/// Pi Bot's own settings sections, in the order it presents them.
enum PiBotSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case accounts, profiles, bots, search, github, config, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accounts: "Accounts"
        case .profiles: "Profiles"
        case .bots: "Bots and teams"
        case .search: "Search"
        case .github: "GitHub"
        case .config: "Config"
        case .general: "Build"
        }
    }
    var detail: String {
        switch self {
        case .accounts: "Provider sign-ins, API keys, and plans."
        case .profiles: "Main models, fallbacks, model pools, and thread titles."
        case .bots: "Roles, teams, memory, and deleted bots."
        case .search: "Web search keys and provider."
        case .github: "SSH key and git identity for bots."
        case .config: "config.toml, limits, and restart."
        case .general: "The running Pi Bot build."
        }
    }
    var glyph: DashboardLucideGlyph {
        switch self {
        case .accounts: .keyRound
        case .profiles: .brain
        case .bots: .bot
        case .search: .compass
        case .github: .terminal
        case .config: .settings
        case .general: .cpu
        }
    }
    var hash: String { self == .general ? "#/settings" : "#/settings/" + rawValue }
}

struct SettingsBotsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    let onBack: () -> Void
    let onOpenSection: (PiBotSettingsSection) -> Void

    private var bots: BotsModel { model.bots }
    private var runtime: PiBotRuntimeSnapshot { bots.runtime }

    @State private var devices: [PiBotTailnetPeer] = []
    @State private var searched = false
    @State private var searching = false
    @State private var deviceError: String?
    @State private var thisMacInspection: PiBotHostInspection?
    @State private var inspections: [String: PiBotHostInspection] = [:]
    @State private var inspectionErrors: [String: String] = [:]
    @State private var checking: Set<String> = []
    @State private var sshUsers: [String: String] = [:]
    @State private var error: String?
    @State private var working = false
    @State private var confirmation: BotsConfirmation?
    @State private var mcp: WovenMCPAccessSnapshot?
    @State private var mcpBusy = false

    var body: some View {
        SettingsPage(
            title: "Bots",
            detail: "Your bots, their device, and their settings. Sign-ins, models, and conversations belong to Pi Bot and stay on the device that runs it.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            deploymentCard
            devicesCard
            if runtime.phase == .ready, runtime.canEmbed {
                wovenCard
                settingsCard
            } else if runtime.phase == .ready {
                SettingsNote("Update this Pi Bot to see its settings here.")
            } else if runtime.target != nil {
                SettingsNote("Pi Bot's own settings appear here once it is running.")
            }
        }
        .task { await bots.refreshRuntime(); await refreshMCP() }
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { item in
            Button(item.action, role: item.destructive ? .destructive : nil) {
                confirmation = nil
                perform(item.command)
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { item in
            Text(item.message)
        }
    }

    // MARK: Current deployment

    private var deploymentCard: some View {
        SettingsCard(title: "Running on", detail: runtime.target == nil
            ? "Bots run on one device. Choose it below."
            : "Closing this window leaves bots running. Their data stays on the device that runs them.") {
            VStack(alignment: .leading, spacing: 10) {
                if let target = runtime.target {
                    HStack(spacing: 10) {
                        deviceIcon(target.kind == .thisMac ? .macOS : target.peer?.system ?? .linux)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.displayName).font(.system(size: 13, weight: .medium))
                            Text(deploymentSummary(target)).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                        Spacer(minLength: 8)
                        if [.installing, .starting, .reconnecting].contains(runtime.phase) { ProgressView().controlSize(.small) }
                        SettingsPill(phaseLabel, tone: [.failed, .stopped, .reconnecting].contains(runtime.phase) ? .warning : .neutral)
                    }
                    if let message = runtime.message { SettingsNote(message) }
                    if let failure = runtime.error { SettingsError(failure) }
                    if runtime.lingeringDisabled {
                        SettingsNote("This Linux account does not keep user services running after logout. Run `loginctl enable-linger` on that device to keep bots running.")
                    }
                    lifecycleControls(target)
                } else if !runtime.bundleAvailable {
                    SettingsError("This build does not include Pi Bot.")
                }
                if let error { SettingsError(error) }
            }
        }
    }

    @ViewBuilder private func lifecycleControls(_ target: PiBotDeploymentTarget) -> some View {
        HStack(spacing: 8) {
            if target.ownership == .managed {
                if runtime.phase == .stopped || runtime.phase == .failed {
                    Button("Start") { perform(runtime.installedCommit == nil ? .update : .start) }
                } else if [.ready, .reconnecting].contains(runtime.phase) {
                    Button("Restart") { perform(.restart) }
                    Button("Stop") {
                        confirmation = .init(title: "Stop Pi Bot on \(target.displayName)?", action: "Stop",
                            message: "Bots stop responding until you start Pi Bot again. Running replies resume on restart.", destructive: false, command: .stop)
                    }
                }
                if runtime.updateAvailable {
                    Button("Update Pi Bot") { perform(.update) }
                }
            }
            Spacer()
            Button("Disconnect") {
                confirmation = .init(title: "Disconnect from \(target.displayName)?", action: "Disconnect",
                    message: target.ownership == .managed
                        ? "Pi Bot stops there. Its bots, sign-ins, and history stay on that device, and you can reconnect later."
                        : "Woven Matter stops using this Pi Bot, removes its Woven MCP access, and leaves it otherwise as it was.",
                    destructive: false, command: .forget(abandon: false))
            }
            if target.kind == .tailnet, target.ownership == .managed, runtime.error != nil {
                Button("Disconnect Anyway") {
                    confirmation = .init(title: "Disconnect without stopping Pi Bot?", action: "Disconnect Anyway",
                        message: "Woven Matter could not reach \(target.displayName). Pi Bot may keep running there until you stop it on that device.",
                        destructive: true, command: .forget(abandon: true))
                }
            }
            if target.ownership == .managed {
                Button("Remove…") {
                    confirmation = .init(title: "Remove Pi Bot from \(target.displayName)?", action: "Remove and Delete Data",
                        message: "This permanently deletes the bots, their conversations, memory, and sign-ins stored on that device. This can't be undone.",
                        destructive: true, command: .remove(deleteData: true))
                }
            }
        }
        .buttonStyle(SettingsQuietButtonStyle())
        .disabled(working || runtime.busy)
    }

    private func deploymentSummary(_ target: PiBotDeploymentTarget) -> String {
        var parts: [String] = [target.ownership == .attached ? "Existing Pi Bot" : "Managed by Woven Matter"]
        if let version = runtime.health?.version { parts.append("Pi Bot " + version) }
        if let commit = runtime.installedCommit { parts.append(String(commit.prefix(8))) }
        return parts.joined(separator: " · ")
    }

    private var phaseLabel: String {
        switch runtime.phase {
        case .notConfigured: "Not set up"
        case .installing: "Installing"
        case .starting: "Starting"
        case .ready: "Running"
        case .stopped: "Stopped"
        case .reconnecting: "Reconnecting"
        case .failed: "Failed"
        }
    }

    // MARK: Devices

    private var devicesCard: some View {
        SettingsCard(title: "Devices", detail: "Choose this Mac, or any Mac or Linux box on your Tailscale network. Other devices use this Mac's existing SSH access over Tailscale, and Pi Bot stays private to them.") {
            VStack(alignment: .leading, spacing: 12) {
                deviceRow(
                    id: "this-mac", name: "This Mac", system: .macOS, online: true,
                    target: .thisMac, inspection: thisMacInspection, showsUser: false
                )
                ForEach(devices) { peer in
                    let target = PiBotDeploymentTarget(kind: .tailnet, peer: peer, sshUser: sshUsers[peer.id] ?? "")
                    deviceRow(id: peer.id, name: peer.name, system: peer.system, online: peer.online,
                              target: target, inspection: inspections[peer.id], showsUser: true)
                }
                if searched, devices.isEmpty, deviceError == nil {
                    SettingsNote("No other Macs or Linux machines are visible on your Tailscale network.")
                }
                if let deviceError { SettingsError(deviceError) }
                Button(searching ? "Searching…" : searched ? "Find devices again" : "Find devices") { discover() }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(searching)
            }
        }
    }

    private func deviceRow(id: String, name: String, system: PiBotTailnetPeer.System, online: Bool,
                           target: PiBotDeploymentTarget, inspection: PiBotHostInspection?, showsUser: Bool) -> some View {
        let isCurrent = runtime.target?.isSameDevice(as: target) == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                deviceIcon(system)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 13, weight: .medium))
                    Text(deviceSummary(system: system, online: online, inspection: inspection, id: id, isCurrent: isCurrent))
                        .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                }
                Spacer(minLength: 8)
                if checking.contains(id) { ProgressView().controlSize(.small) }
                if online, !isCurrent { deviceActions(id: id, name: name, target: target, inspection: inspection) }
            }
            if let failure = inspectionErrors[id] { SettingsError(failure) }
            if online, !isCurrent, let inspection {
                ForEach(inspection.existing) { existing in
                    HStack(spacing: 8) {
                        Text("Pi Bot \(existing.version ?? "") already runs on port \(existing.port)" + (existing.service.map { " (\($0))" } ?? ""))
                            .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                        Spacer(minLength: 8)
                        if existing.protocol == nil {
                            Text("Update it to connect").font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        } else {
                        Button("Connect") {
                            var attached = target
                            attached.ownership = .attached
                            attached.remotePort = existing.port
                            confirmation = .init(title: "Connect to the Pi Bot on \(name)?", action: "Connect",
                                message: replacementNote(leaving: runtime.target) + "Woven Matter uses this server as it is: its config, sign-ins, data, and updates stay as they are. Its bots get Woven MCP access if that is on.",
                                destructive: false, command: .attach(attached))
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                        }
                    }
                }
            }
            if showsUser, online {
                HStack(spacing: 8) {
                    TextField("SSH user (optional)", text: Binding(get: { sshUsers[id] ?? "" }, set: { sshUsers[id] = $0 }))
                        .dashboardInput()
                        .frame(maxWidth: 220)
                    Button("Check") { inspect(id: id, target: target) }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(checking.contains(id))
                }
            }
        }
        .padding(.vertical, 4)
        .disabled(working || runtime.busy)
    }

    @ViewBuilder private func deviceActions(id: String, name: String, target: PiBotDeploymentTarget, inspection: PiBotHostInspection?) -> some View {
        if id == "this-mac" || inspection != nil {
            Button(inspection?.managed.installed == true ? "Use this device" : "Install here") {
                confirmation = .init(title: "Run bots on \(name)?", action: inspection?.managed.installed == true ? "Use This Device" : "Install",
                    message: replacementNote(leaving: runtime.target) + (inspection?.managed.installed == true
                        ? "Woven Matter reconnects to the Pi Bot it installed there, with its existing bots and data."
                        : "This installs about 1.7 GB of runtime and dependencies on \(name) and starts Pi Bot there, private to that device."),
                    destructive: false, command: .deploy(target))
            }
            .buttonStyle(SettingsQuietButtonStyle())
            .disabled(!runtime.bundleAvailable)
        }
    }

    private func replacementNote(leaving current: PiBotDeploymentTarget?) -> String {
        guard let current else { return "" }
        return "This replaces \(current.displayName). Each device keeps its own bots: nothing moves between them. "
    }

    private func deviceSummary(system: PiBotTailnetPeer.System, online: Bool, inspection: PiBotHostInspection?, id: String, isCurrent: Bool) -> String {
        var parts = [system == .macOS ? "Mac" : "Linux"]
        if isCurrent { parts.append("In use") }
        if !online { parts.append("Offline") }
        if let inspection {
            if inspection.managed.installed { parts.append(inspection.managed.running ? "Pi Bot running" : "Pi Bot installed") }
            parts.append(inspection.docker ? "Docker available" : "No Docker: bots have no shell tools")
        }
        return parts.joined(separator: " · ")
    }

    private func deviceIcon(_ system: PiBotTailnetPeer.System) -> some View {
        DashboardLucideIcon(glyph: system == .macOS ? .monitor : .container, size: 15).frame(width: 24, height: 24)
    }

    // MARK: Woven MCP

    private var wovenCard: some View {
        SettingsCard(title: "Woven MCP access", detail: "Lets bots use your notes, calendar, and other Woven Matter items, and launch and manage agent sessions across your workspaces. Separate from outside-agent access.") {
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
                        SettingsNote("Goals and visual replies are included. Usage data is always read only.")
                    }
                    .padding(.leading, 38)
                }
                if runtime.health?.supports("woven.mcp") == false {
                    SettingsNote("This Pi Bot version does not support Woven MCP yet. Update it to connect.")
                } else if let woven = runtime.woven {
                    SettingsValueRow(label: "Connection", value: wovenDescription(woven))
                    if let failure = woven.error { SettingsNote(failure) }
                }
            }
            .font(.system(size: 13))
            .toggleStyle(DashboardSwitchToggleStyle())
        }
    }

    private func wovenDescription(_ status: PiBotWovenStatus) -> String {
        switch status.state {
        case "ready": status.toolCount.map { "\($0) tools available" } ?? "Connected"
        case "connecting": "Connecting…"
        case "unavailable": "Unavailable"
        default: "Off"
        }
    }

    // MARK: Pi Bot's sections

    private var settingsCard: some View {
        SettingsCard(title: "Pi Bot settings", detail: "These come directly from Pi Bot, including its own provider sign-ins.") {
            VStack(spacing: 2) {
                ForEach(PiBotSettingsSection.allCases) { section in
                    SettingsDestinationRow(
                        title: section.title,
                        detail: section.detail,
                        icon: { DashboardLucideIcon(glyph: section.glyph, size: 15) },
                        action: { onOpenSection(section) }
                    )
                }
            }
        }
    }

    // MARK: Actions

    private func perform(_ command: BotsCommand) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do { _ = try await bots.send(command) }
            catch { self.error = error.localizedDescription }
            inspections.removeAll()
            thisMacInspection = nil
        }
    }

    private func discover() {
        guard !searching else { return }
        searching = true
        deviceError = nil
        Task {
            defer { searching = false; searched = true }
            do {
                devices = try await bots.send(.discoverDevices).devices ?? []
                if thisMacInspection == nil { inspect(id: "this-mac", target: .thisMac) }
            } catch { deviceError = error.localizedDescription }
        }
    }

    private func inspect(id: String, target: PiBotDeploymentTarget) {
        guard !checking.contains(id) else { return }
        checking.insert(id)
        inspectionErrors[id] = nil
        Task {
            defer { checking.remove(id) }
            do {
                let result = try await bots.send(.inspect(target)).inspection
                if id == "this-mac" { thisMacInspection = result } else { inspections[id] = result }
            } catch {
                inspectionErrors[id] = error.localizedDescription
            }
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
            do {
                mcp = try await model.controlMCPAccess(action)
                _ = try await bots.send(.applyMCPPolicy)
            } catch { self.error = error.localizedDescription }
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

/// One Pi Bot settings section, embedded, under Woven Matter's own back navigation.
struct SettingsBotsWebPage: View {
    @Bindable var bots: BotsModel
    let section: PiBotSettingsSection
    var reservesRailControlSpace = false
    let onBack: () -> Void
    let onOpenLink: (URL) -> Void
    @Environment(\.dashboardTheme) private var theme
    /// Owned by this page: the main window and the Settings window can each show one.
    @State private var session = BotWebSession()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsBackButton(title: "Bots", action: onBack)
                Text(section.title).font(.system(size: 22, weight: .semibold)).tracking(-0.35)
            }
            .padding(.horizontal, 24)
            .padding(.top, reservesRailControlSpace ? 76 : 28)
            if bots.runtime.phase == .ready, bots.runtime.baseURL != nil, bots.runtime.canEmbed {
                BotWebView(session: session)
            } else {
                BotsUnavailableView(runtime: bots.runtime, onOpenSettings: onBack)
            }
        }
        .task(id: BotSettingsTask(base: bots.runtime.baseURL, section: section, theme: theme.rawValue)) {
            guard let base = bots.runtime.baseURL, bots.runtime.phase == .ready, bots.runtime.canEmbed else { return }
            session.onOpenExternal = onOpenLink
            session.show(base: base, hash: section.hash, theme: theme.rawValue)
        }
    }
}

private struct BotSettingsTask: Hashable {
    let base: URL?
    let section: PiBotSettingsSection
    let theme: String
}
