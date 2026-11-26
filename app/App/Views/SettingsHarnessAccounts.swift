import AppKit
import SwiftUI

/// One harness's account, then its software and diagnostics, on each machine in scope.
/// This is the only place these controls live; machine pages show status and link here.
struct SettingsHarnessAccounts: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind
    let scope: String

    private var machines: MachinesStore { model.machines }
    private var inScope: [Machine] { machines.machines(inScope: scope) }
    private var others: [Machine] { inScope.filter { !$0.isThisMachine } }
    private var thisMachine: Machine? { inScope.first(where: \.isThisMachine) }

    var body: some View {
        SettingsSection(title: "\(runtimeKind.displayName) account") {
            if thisMachine != nil {
                localLabel
                SettingsHarnessSignInControl(model: model, runtimeKind: runtimeKind)
            }
            ForEach(others) { machine in
                perMachine(machine) {
                    SettingsRemoteHarnessAccountView(model: machines,
                        runtimeKind: runtimeKind, machine: machine, embedded: true)
                }
                .task { machines.refreshHarnessesIfStale(on: machine.id) }
            }
            if scope != "global", inScope.isEmpty {
                SettingsEmpty("This workspace is no longer configured.")
            }
            SettingsHelp {
                SettingsNote("Sign-in belongs to this harness on the selected workspace. Sharing chat settings does not change it.")
                SettingsNote(sharingDetail)
            }
        }
        if !inScope.isEmpty {
            SettingsSection(title: "Software") {
                if let thisMachine {
                    localLabel
                    SettingsRemoteHarnessSoftware(model: machines, runtimeKind: runtimeKind, machine: thisMachine)
                        .task { machines.refreshHarnessesIfStale(on: thisMachine.id) }
                }
                ForEach(others) { machine in
                    perMachine(machine) {
                        SettingsRemoteHarnessSoftware(model: machines, runtimeKind: runtimeKind, machine: machine)
                    }
                }
            }
        }
    }

    /// With other machines listed too, this Mac's part gets a label.
    @ViewBuilder private var localLabel: some View {
        if scope == "global" && !others.isEmpty {
            Text("Local workspace")
                .font(.settingsBody)
                .foregroundStyle(WovenPalette.mutedForeground)
        }
    }

    /// Each other machine folds into a row when several are listed.
    @ViewBuilder private func perMachine<Content: View>(
        _ machine: Machine, @ViewBuilder content: () -> Content
    ) -> some View {
        if scope == "global" {
            SettingsSummaryRow(machine.name) { content() }
        } else {
            content()
        }
    }

    private var sharingDetail: String {
        switch runtimeKind {
        case .codex:
            "Codex uses its own ChatGPT sign-in or OpenAI API key. An OpenAI API key can also be used in Pi Durable, but Woven Matter does not automatically copy it into Codex or sync Codex sign-ins between machines."
        case .claudeCode:
            "Claude Code uses Claude’s credentials on this machine. Pi Durable manages separate Claude profiles; both require native sign-in on each machine. Anthropic API keys are reusable, but are not automatically synced into Claude Code."
        case .grokBuild:
            "Grok Build uses its own Grok sign-in on each machine. Pi Durable’s Grok account sharing does not sign in Grok Build."
        case .opencode:
            "OpenCode manages accounts and API keys in its own service. Workspaces connected to the same service use that service’s accounts; separate services need their own setup. Pi Durable’s OpenCode API key is not automatically synced into OpenCode."
        default:
            "Accounts are managed by this harness on each workspace."
        }
    }
}

/// A harness's installed components on one machine, with install, update and diagnostics.
struct SettingsRemoteHarnessSoftware: View {
    @Bindable var model: MachinesStore
    let runtimeKind: AgentRuntimeKind
    let machine: Machine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let harness = model.harness(runtimeKind, on: machine.id)
            let installing = model.operation(runtimeKind, on: machine.id) == .install
            let busy = model.isMaintaining(runtimeKind, on: machine.id) || model.isCheckingHarness(runtimeKind, on: machine.id)
            let unavailable = model.harnessInventoryUnavailable.contains(machine.id)
            if harness != nil || !unavailable {
                SettingsRuntimeSummaryRow(
                    summary: harness?.summary ?? "Checking installed components…",
                    status: harness.map { $0.isInstalled ? "Installed" : $0.needsAdapter ? $0.state.displayName : "Not installed" }
                        ?? "Checking",
                    tone: harness?.isInstalled == true ? .good : harness == nil || harness?.state == .settingUp ? .neutral : .warning
                ) {
                    if let harness, !harness.isInstalled {
                        // Installing again also installs a missing adapter.
                        Button(installing ? "Installing…" : (harness.failureCount > 0 ? "Retry install" : "Install")) {
                            model.install(runtimeKind, on: machine.id)
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(busy || harness.state == .settingUp)
                        .accessibilityLabel("Install " + runtimeKind.displayName)
                    } else if harness?.isSystemInstall != true {
                        SettingsHarnessUpdateButton(model: model, runtimeKind: runtimeKind, machineID: machine.id)
                    } else {
                        Text("Managed on the machine").font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
                    }
                }
                .help(harness?.components.compactMap(\.path).joined(separator: "\n") ?? "")
                if let harness {
                    ForEach(harness.components) { component in
                        if component.isSystemInstall, let path = component.path {
                            SettingsNote("Using \(path) (installed on the machine)")
                        }
                    }
                    if !harness.versionCheckAvailable {
                        SettingsNote("Couldn’t check for updates.")
                    }
                    if harness.failureCount >= 2, let diagnostic = harness.diagnostic {
                        Button("Copy diagnostic") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(diagnostic, forType: .string)
                        }.buttonStyle(SettingsQuietButtonStyle())
                    }
                }
                if let error = model.harnessError(runtimeKind, on: machine.id) { SettingsError(error) }
            } else { SettingsEmpty("Connect this workspace to manage software.") }
        }
    }
}

/// Check for updates, or update when one is available, for a harness on one machine.
struct SettingsHarnessUpdateButton: View {
    @Bindable var model: MachinesStore
    let runtimeKind: AgentRuntimeKind
    let machineID: String

    var body: some View {
        let harness = model.harness(runtimeKind, on: machineID)
        let checking = model.isCheckingHarness(runtimeKind, on: machineID)
        let updating = model.operation(runtimeKind, on: machineID) == .update
        let failedUpdate = harness.map { $0.failureCount > 0 && $0.isInstalled } == true
        let hasUpdate = harness?.isInstalled == true && (harness?.updateAvailable == true || failedUpdate)
        let retryCheck = harness?.versionCheckAvailable == false
        let label = checking ? "Checking…" : updating ? "Updating…"
            : hasUpdate ? (failedUpdate ? "Retry update" : "Update")
            : retryCheck ? "Retry check" : "Check for updates"
        Button(label) {
            if hasUpdate { model.update(runtimeKind, on: machineID) }
            else { model.checkForUpdates(runtimeKind, on: machineID) }
        }
        .buttonStyle(SettingsQuietButtonStyle())
        .disabled(checking || model.isMaintaining(runtimeKind, on: machineID))
        .accessibilityLabel(label + " for " + runtimeKind.displayName)
    }
}

