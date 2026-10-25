import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct HarnessSetupView: View {
    @State private var setup: HarnessSetupModel
    @State private var step = 0
    @State private var connectionFocus: ConnectionSettingsFocus?
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(DashboardTheme.storageKey) private var themeRawValue = DashboardTheme.green.rawValue

    init(model: ApplicationModel) { _setup = State(initialValue: HarnessSetupModel(application: model)) }
    private var model: ApplicationModel { setup.application }
    private var theme: DashboardTheme { DashboardTheme(rawValue: themeRawValue) ?? .green }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let connectionFocus {
                        SettingsConnectionsView(model: model, focus: connectionFocus, onConnected: { provider in
                            model.pendingDefaultAgentModelProvider = provider
                            model.pendingDefaultAgentSettingsScope = "global"
                            finish()
                        }, onBack: { self.connectionFocus = nil })
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
        .foregroundStyle(DashboardPalette.foreground)
        .background(theme.palette.workspace)
        .environment(\.dashboardTheme, theme)
        .preferredColorScheme(theme.colorScheme)
        .toggleStyle(DashboardSwitchToggleStyle())
        .task { step = 0; connectionFocus = nil; setup.open() }
        .onDisappear { setup.close() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(connectionFocus?.title ?? (step == 0 ? "Setup Your Harnesses" : "Setup Pi Durable"))
                    .font(.system(size: 22, weight: .semibold)).tracking(-0.35)
                Spacer()
                Text("\(step + 1) of 2")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            Text(connectionFocus?.detail ?? (step == 0
                 ? "Use the tools already on your Mac, or choose more to install."
                 : "Pi Durable is included with Woven Matter. Add connections whenever you’re ready."))
                .font(.system(size: 13)).foregroundStyle(DashboardPalette.mutedForeground)
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 8)
    }

    private var harnesses: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("On this Mac").font(.system(size: 13, weight: .semibold))
                Spacer()
                if setup.checking { ProgressView().controlSize(.small) }
                Button(setup.checking ? "Checking…" : "Check again") { setup.refresh() }
                    .buttonStyle(SettingsQuietButtonStyle(minimumHeight: 28))
                    .disabled(setup.busy || setup.maintenanceBusy)
            }
            VStack(spacing: 0) {
                ForEach(Array(HarnessOnboarding.runtimes.enumerated()), id: \.element) { index, kind in
                    if index > 0 { Rectangle().fill(theme.palette.border).frame(height: 1).padding(.horizontal, 16) }
                    harnessRow(kind)
                }
            }
            .background(theme.palette.themeWhisper)
            .clipShape(DashboardShapes.card)
            if let notice = setup.notice { SettingsNote(notice) }
            if model.localRuntimeMaintenanceHasActiveConversation {
                SettingsNote("Finish active local chats before installing or updating harnesses.")
            }
            SettingsNote("Installed harnesses appear in your sidebar automatically. Sign in opens the harness’s own flow in Terminal; return here when you’re done.")
        }
    }

    private func harnessRow(_ kind: AgentRuntimeKind) -> some View {
        let inventory = model.runtimeInventories[kind]
        let installed = inventory?.isInstalled == true
        let busy = model.runtimeMaintenanceBusy(kind) || setup.activeInstall == kind
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                DashboardHarnessLogoIcon(logo: DashboardHarnessLogo(runtimeKind: kind), size: 24)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.displayName).font(.system(size: 13, weight: .medium))
                    Text(busy ? (model.updatingRuntimeKinds.contains(kind) ? "Updating…" : "Installing…") : installationLabel(inventory))
                        .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                }
                Spacer(minLength: 8)
                if busy {
                    ProgressView().controlSize(.small).frame(width: 28)
                } else if installed {
                    if inventory?.updateAvailable == true || model.failedRuntimeUpdateKinds.contains(kind) {
                        SettingsLocalRuntimeUpdateButton(model: model, runtimeKind: kind)
                    }
                    SettingsHarnessSignInControl(model: model, runtimeKind: kind, compact: true)
                        .frame(minWidth: 72, alignment: .trailing)
                } else {
                    Toggle("Install", isOn: Binding(
                        get: { setup.selected.contains(kind) },
                        set: { if $0 { setup.selected.insert(kind) } else { setup.selected.remove(kind) } }
                    ))
                    .font(.system(size: 12.5))
                    .accessibilityLabel("Install \(kind.displayName)")
                    .disabled(setup.activeInstall != nil || inventory == nil)
                }
            }
            .frame(minHeight: 44)
            if let message = model.harnessSignIn.messages[kind] { SettingsNote(message) }
            if let error = setup.errors[kind] ?? model.runtimeFailureDetails[kind] { SettingsError(error) }
            if setup.activeInstall == kind, let prepared = model.preparedLocalACPRuntimeInstall,
               prepared.definition.runtimeKind == kind {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsNote("Download from \(prepared.preview.source.absoluteString). The installer is verified before it runs.")
                    HStack {
                        Button("Skip this harness") { setup.resolveInstaller(install: false) }
                            .buttonStyle(SettingsQuietButtonStyle())
                        Spacer()
                        Button("Install \(kind.displayName)") { setup.resolveInstaller(install: true) }
                            .buttonStyle(DashboardPrimaryButtonStyle())
                    }.disabled(setup.resolvingInstaller)
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func installationLabel(_ inventory: RuntimeInventory?) -> String {
        guard let inventory else { return "Checking installation…" }
        if inventory.isInstalled {
            let version = inventory.components.first(where: { $0.name.hasSuffix("(sign-in CLI)") })?.installed
                ?? inventory.components.first?.installed
            let suffix = inventory.updateAvailable ? " · Update available" : ""
            return (version.map { "Installed · \($0)" } ?? "Installed") + suffix
        }
        return inventory.components.contains(where: \.present) ? "Finish installation" : "Not installed"
    }

    private var piDurable: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                DashboardHarnessLogoIcon(logo: .defaultAgent, size: 20)
                Text("Pi Durable").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Included").font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
            }
            .frame(minHeight: 28)
            VStack(spacing: 0) {
                piSetupRow(.providers, action: "Open provider settings")
                Rectangle().fill(theme.palette.border).frame(height: 1).padding(.horizontal, 16)
                piSetupRow(.webSearch, action: "Open web search settings")
            }
            .background(theme.palette.themeWhisper)
            .clipShape(DashboardShapes.card)
            SettingsNote("Both steps are optional. Reopen this guide from Settings → General → Set up harnesses. Provider connections and web search are also available in Settings → Pi Durable.")
        }
    }

    private func piSetupRow(_ destination: ConnectionSettingsFocus, action: String) -> some View {
        HStack(spacing: 12) {
            DashboardLucideIcon(glyph: destination == .providers ? .plug : .searchControl, size: 22)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(destination.title).font(.system(size: 13, weight: .medium))
                Text(destination.detail)
                    .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
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
                if !setup.selected.isEmpty {
                    Button("Install selected (\(setup.selected.count))") { setup.installSelected() }
                        .buttonStyle(DashboardPrimaryButtonStyle())
                        .disabled(setup.busy || setup.maintenanceBusy || model.localRuntimeMaintenanceHasActiveConversation)
                    Button("Continue") { step = 1 }.buttonStyle(SettingsQuietButtonStyle())
                        .disabled(setup.activeInstall != nil)
                } else {
                    Button("Continue") { step = 1 }.buttonStyle(DashboardPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Button("Back") {
                    if connectionFocus != nil { connectionFocus = nil } else { step = 0 }
                }.buttonStyle(SettingsQuietButtonStyle())
                Button(connectionFocus != nil ? "Done" : "Finish") {
                    if connectionFocus != nil { connectionFocus = nil } else { finish() }
                }.buttonStyle(DashboardPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func finish() { setup.close(); dismissWindow(id: HarnessSetupPresentation.windowID) }
}
