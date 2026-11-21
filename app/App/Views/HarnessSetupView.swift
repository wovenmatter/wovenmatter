import AppKit
import SwiftUI

struct HarnessSetupView: View {
    @Bindable var model: ApplicationModel
    @State private var selected: Set<AgentRuntimeKind> = []
    @State private var step = 0
    @State private var connectionFocus: ConnectionSettingsFocus?
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(WovenTheme.storageKey) private var themeRawValue = WovenTheme.green.rawValue

    private var theme: WovenTheme { WovenTheme(rawValue: themeRawValue) ?? .green }
    private var machines: MachinesStore { model.machines }
    /// Setup covers this Mac; its server installs and signs in.
    private var machineID: String { machines.thisMachine?.id ?? model.thisMachineID ?? "" }
    private var checking: Bool { machines.isCheckingHarnesses(on: machineID) }
    private var activeInstall: AgentRuntimeKind? {
        HarnessSetupPresentation.runtimes.first { machines.operation($0, on: machineID) == .install }
    }
    private var busy: Bool { checking || activeInstall != nil }
    private var maintenanceBusy: Bool { machines.isMaintainingHarnesses(on: machineID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let connectionFocus {
                        SettingsConnectionsView(model: model, focus: connectionFocus, onConnected: { provider in
                            model.navigation.pendingDefaultAgentModelProvider = provider
                            model.navigation.pendingDefaultAgentSettingsScope = "global"
                            finish()
                        })
                    } else if step == 0 {
                        harnesses
                    } else {
                        piDurable
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.never)
            footer
        }
        .frame(width: 760, height: 650)
        .foregroundStyle(WovenPalette.foreground)
        .background(theme.palette.workspace)
        .environment(\.wovenTheme, theme)
        .preferredColorScheme(theme.colorScheme)
        .toggleStyle(CompactSwitchToggleStyle())
        .task { step = 0; connectionFocus = nil; refresh() }
        .onDisappear { close() }
        .onChange(of: machines.harnesses(on: machineID).filter(\.isInstalled).map(\.runtimeKind)) { _, installed in
            selected.subtract(installed)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(connectionFocus?.title ?? (step == 0 ? "Setup Your Harnesses" : "Setup Pi Durable"))
                    .font(.system(size: 22, weight: .semibold)).tracking(-0.35)
                Spacer()
                Text("\(step + 1) of 2")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
            Text(connectionFocus?.detail ?? (step == 0
                 ? "Use the tools already on your Mac, or choose more to install."
                 : "Pi Durable is included with Woven Matter. Add connections whenever you’re ready."))
                .font(.system(size: 13)).foregroundStyle(WovenPalette.mutedForeground)
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 8)
    }

    private var harnesses: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("On this Mac").font(.system(size: 13, weight: .semibold))
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button(checking ? "Checking…" : "Check again") { refresh() }
                    .buttonStyle(SettingsQuietButtonStyle(minimumHeight: 28))
                    .disabled(busy || maintenanceBusy)
            }
            VStack(spacing: 0) {
                ForEach(Array(HarnessSetupPresentation.runtimes.enumerated()), id: \.element) { index, kind in
                    if index > 0 { Rectangle().fill(theme.palette.border).frame(height: 1).padding(.horizontal, 16) }
                    harnessRow(kind)
                }
            }
            .background(theme.palette.themeWhisper)
            .clipShape(DesktopShapes.card)
            SettingsNote("Installed harnesses appear in your sidebar automatically. Sign in opens the harness’s own flow in Terminal; return here when you’re done.")
        }
    }

    private func harnessRow(_ kind: AgentRuntimeKind) -> some View {
        let inventory = machines.harness(kind, on: machineID)
        let installed = inventory?.isInstalled == true
        let operation = machines.operation(kind, on: machineID)
        let busy = operation != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HarnessLogoIcon(logo: HarnessLogo(runtimeKind: kind), size: 24)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.displayName).font(.system(size: 13, weight: .medium))
                    Text(busy ? (operation == .update ? "Updating…" : "Installing…") : installationLabel(inventory))
                        .font(.system(size: 11.5)).foregroundStyle(WovenPalette.mutedForeground)
                }
                Spacer(minLength: 8)
                if busy {
                    ProgressView().controlSize(.small).frame(width: 28)
                } else if installed {
                    if inventory?.updateAvailable == true || (inventory?.failureCount ?? 0) > 0 {
                        SettingsHarnessUpdateButton(model: machines, runtimeKind: kind, machineID: machineID)
                    }
                    SettingsHarnessSignInControl(model: model, runtimeKind: kind, compact: true)
                        .frame(minWidth: 72, alignment: .trailing)
                } else {
                    Toggle("Install", isOn: Binding(
                        get: { selected.contains(kind) },
                        set: { if $0 { selected.insert(kind) } else { selected.remove(kind) } }
                    ))
                    .font(.system(size: 12.5))
                    .accessibilityLabel("Install \(kind.displayName)")
                    .disabled(activeInstall != nil || inventory == nil)
                }
            }
            .frame(minHeight: 44)
            SettingsHarnessSignInPanel(model: model, runtimeKind: kind)
            if let message = machines.signInMessage(kind, on: machineID) { SettingsNote(message) }
            if let error = machines.harnessError(kind, on: machineID) { SettingsError(error) }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func installationLabel(_ inventory: HarnessInstallation?) -> String {
        guard let inventory else { return "Checking installation…" }
        if inventory.isInstalled {
            let suffix = inventory.updateAvailable ? " · Update available" : ""
            return (inventory.installedVersion.map { "Installed · \($0)" } ?? "Installed") + suffix
        }
        return inventory.components.contains(where: \.isInstalled) ? "Finish installation" : "Not installed"
    }

    private var piDurable: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HarnessLogoIcon(logo: .defaultAgent, size: 20)
                Text("Pi Durable").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Included").font(.system(size: 11.5)).foregroundStyle(WovenPalette.mutedForeground)
            }
            .frame(minHeight: 28)
            VStack(spacing: 0) {
                piSetupRow(.providers, action: "Open provider settings")
                Rectangle().fill(theme.palette.border).frame(height: 1).padding(.horizontal, 16)
                piSetupRow(.webSearch, action: "Open web search settings")
            }
            .background(theme.palette.themeWhisper)
            .clipShape(DesktopShapes.card)
            SettingsNote("Both steps are optional. Reopen this guide from Settings → Agents. Provider connections and web search are also available in Settings → Subscriptions & API Keys.")
        }
    }

    private func piSetupRow(_ destination: ConnectionSettingsFocus, action: String) -> some View {
        HStack(spacing: 12) {
            LucideIcon(glyph: destination == .providers ? .plug : .searchControl, size: 22)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(destination.title).font(.system(size: 13, weight: .medium))
                Text(destination.detail)
                    .font(.system(size: 11.5)).foregroundStyle(WovenPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(action) { connectionFocus = destination }
                .buttonStyle(SettingsQuietButtonStyle())
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(connectionFocus != nil ? "Skip for now" : step == 0 ? "Set up later" : "Skip and finish") {
                if connectionFocus != nil { connectionFocus = nil } else { finish() }
            }
                .buttonStyle(SettingsQuietButtonStyle()).keyboardShortcut(.cancelAction)
            Spacer()
            if step == 0 {
                if !selected.isEmpty {
                    Button("Install selected (\(selected.count))") { installSelected() }
                        .buttonStyle(WovenPrimaryButtonStyle())
                        .disabled(busy || maintenanceBusy)
                    Button("Continue") { step = 1 }.buttonStyle(SettingsQuietButtonStyle())
                        .disabled(activeInstall != nil)
                } else {
                    Button("Continue") { step = 1 }.buttonStyle(WovenPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Button("Back") {
                    if connectionFocus != nil { connectionFocus = nil } else { step = 0 }
                }.buttonStyle(SettingsQuietButtonStyle())
                Button(connectionFocus != nil ? "Done" : "Finish") {
                    if connectionFocus != nil { connectionFocus = nil } else { finish() }
                }.buttonStyle(WovenPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func refresh() {
        guard !busy, !maintenanceBusy else { return }
        machines.refreshHarnesses(on: machineID)
        Task { for kind in HarnessSetupPresentation.runtimes { await machines.refreshSignIn(kind, on: machineID) } }
    }

    /// This Mac's server installs them in order; installed ones leave the selection.
    private func installSelected() {
        let kinds = HarnessSetupPresentation.runtimes.filter { selected.contains($0) }
        guard !kinds.isEmpty, !busy, !maintenanceBusy else { return }
        machines.installHarnesses(kinds, on: machineID)
    }

    /// An install already running finishes.
    private func close() {
        HarnessSetupPresentation.shared.dismiss()
    }

    private func finish() { close(); dismissWindow(id: HarnessSetupPresentation.windowID) }
}
