import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct HarnessSetupView: View {
    @State private var setup: HarnessSetupModel
    @State private var step = 0
    @State private var showsConnections = false
    @State private var showsWebSearchFirst = false
    @State private var pendingEnable: AgentRuntimeKind?
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(DashboardTheme.storageKey) private var themeRawValue = DashboardTheme.green.rawValue

    init(model: ApplicationModel) { _setup = State(initialValue: HarnessSetupModel(application: model)) }
    private var model: ApplicationModel { setup.application }
    private var theme: DashboardTheme { DashboardTheme(rawValue: themeRawValue) ?? .green }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showsConnections {
                SettingsConnectionsView(model: model, initialScope: "global", backTitle: "Setup",
                                        webSearchFirst: showsWebSearchFirst,
                                        onBack: { showsConnections = false })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if step == 0 { harnesses } else { piDurable }
                    }.padding(24)
                }
                .scrollIndicators(.never)
            }
            Divider()
            footer
        }
        .frame(width: 740, height: 640)
        .foregroundStyle(DashboardPalette.foreground)
        .background(theme.palette.workspace)
        .environment(\.dashboardTheme, theme)
        .preferredColorScheme(theme.colorScheme)
        .toggleStyle(DashboardSwitchToggleStyle())
        .task { step = 0; showsConnections = false; setup.open() }
        .onDisappear { setup.close() }
        .sheet(isPresented: Binding(get: { pendingEnable != nil }, set: { if !$0 { pendingEnable = nil } })) {
            if let kind = pendingEnable {
                CredentialAccessDisclosureView(
                    purpose: "Use \(kind.displayName) on this Mac with its existing credentials.",
                    onEnable: {
                        model.acknowledgeCredentialAccessDisclosure()
                        model.enableLocalACPRuntimeCredentialAccess(kind)
                        pendingEnable = nil
                    }, onCancel: { pendingEnable = nil })
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(step == 0 ? "Welcome to Woven Matter" : "Pi Durable is already included")
                    .font(.system(size: 24, weight: .semibold))
                Spacer()
                Text("\(step + 1) of 2").font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
            }
            Text(step == 0
                 ? "Choose the harnesses you’d like to use. Install any that are missing, then connect your accounts."
                 : "Connect a model provider and add web search whenever you’re ready.")
                .font(.system(size: 13))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 8)
    }

    private var harnesses: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("On this Mac").font(.system(size: 14, weight: .semibold))
                Spacer()
                if setup.checking { ProgressView().controlSize(.small) }
                Button(setup.checking ? "Checking…" : "Check again") { setup.refresh() }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(setup.busy || setup.maintenanceBusy)
            }
            ForEach(HarnessOnboarding.runtimes, id: \.self) { kind in harnessRow(kind) }
            if let notice = setup.notice { SettingsNote(notice) }
            if model.localRuntimeMaintenanceHasActiveConversation {
                SettingsNote("Finish active local chats before installing or updating harnesses.")
            }
            Text("Checks use your installed tools’ version and sign-in status commands. Nothing is downloaded until you choose Install.")
                .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func harnessRow(_ kind: AgentRuntimeKind) -> some View {
        let inventory = model.runtimeInventories[kind]
        let installed = inventory?.isInstalled == true
        let status = setup.signInStatuses[kind]
        let installing = setup.activeInstall == kind
        return SettingsInset {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 12) {
                    DashboardHarnessLogoIcon(logo: DashboardHarnessLogo(runtimeKind: kind), size: 28)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(kind.displayName).font(.system(size: 14, weight: .semibold))
                            Text(installing ? (setup.updating ? "Updating…" : "Installing…") : installationLabel(inventory))
                                .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                        Text(status?.label ?? (setup.checking ? "Checking sign-in…" : "Sign-in not checked"))
                            .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    Spacer(minLength: 8)
                    if installing { ProgressView().controlSize(.small) }
                    else if !installed {
                        Toggle("Install", isOn: Binding(
                            get: { setup.selected.contains(kind) },
                            set: { if $0 { setup.selected.insert(kind) } else { setup.selected.remove(kind) } }
                        ))
                        .accessibilityLabel("Install \(kind.displayName)")
                        .disabled(setup.busy || setup.maintenanceBusy || inventory == nil)
                    } else {
                        installedActions(kind, inventory: inventory)
                    }
                }
                if let status, status.state != "not_installed" {
                    Text(status.detail).font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let inventory, inventory.latestUnavailable, model.checkedRuntimeKinds.contains(kind) {
                    Text("Update check unavailable. You can try again later.")
                        .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                }
                if let error = setup.errors[kind] ?? model.runtimeFailureDetails[kind] { SettingsError(error) }
                if setup.activeInstall == kind, let prepared = model.preparedLocalACPRuntimeInstall,
                   prepared.definition.runtimeKind == kind {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Download from \(prepared.preview.source.absoluteString). The installer is verified before it runs.")
                            .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Skip this harness") { setup.resolveInstaller(install: false) }
                                .buttonStyle(SettingsQuietButtonStyle())
                            Spacer()
                            Button("Install \(kind.displayName)") { setup.resolveInstaller(install: true) }
                                .buttonStyle(DashboardPrimaryButtonStyle())
                        }.disabled(setup.resolvingInstaller)
                    }
                }
            }
        }
    }

    private func installedActions(_ kind: AgentRuntimeKind, inventory: RuntimeInventory?) -> some View {
        HStack(spacing: 8) {
            if inventory?.updateAvailable == true || model.failedRuntimeUpdateKinds.contains(kind) {
                Button("Update") { setup.update(kind) }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(setup.busy || setup.maintenanceBusy || model.localRuntimeMaintenanceHasActiveConversation)
            }
            let enabled = kind == .opencode ? model.openCode?.isEnabled == true
                : model.isLocalACPRuntimeCredentialAccessEnabled(kind)
            if !enabled {
                Button("Enable") {
                    if kind == .opencode {
                        model.openCode?.perform { try await model.openCode?.connectLocal() }
                    } else if model.hasAcknowledgedCredentialAccessDisclosure {
                        model.enableLocalACPRuntimeCredentialAccess(kind)
                    } else { pendingEnable = kind }
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(setup.busy || setup.maintenanceBusy || model.openCode?.isConnecting == true)
                .accessibilityLabel("Enable \(kind.displayName) in Woven Matter")
            } else {
                Text("Enabled").font(.system(size: 11.5)).foregroundStyle(DashboardPalette.success)
            }
        }
    }

    private func installationLabel(_ inventory: RuntimeInventory?) -> String {
        guard let inventory else { return "Checking installation…" }
        if inventory.isInstalled {
            let version = inventory.components.first(where: { $0.name.hasSuffix("(sign-in CLI)") })?.installed
                ?? inventory.components.first?.installed
            return version.map { "Installed · \($0)" } ?? "Installed"
        }
        if inventory.components.contains(where: { $0.name.hasSuffix("(sign-in CLI)") && $0.present }) {
            return "Installed · finish setup"
        }
        return inventory.components.contains(where: \.present) ? "Finish setup" : "Not installed"
    }

    private var piDurable: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                DashboardHarnessLogoIcon(logo: DashboardHarnessLogo(runtimeKind: .defaultAgent), size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No download needed").font(.system(size: 16, weight: .semibold))
                    Text("Pi Durable comes with Woven Matter. Both steps below are optional.")
                        .font(.system(size: 13)).foregroundStyle(DashboardPalette.mutedForeground)
                }
            }.padding(.bottom, 8)
            SettingsCard(title: "Connect a model provider", detail: "Sign in to a supported subscription or add an API key. You can connect more than one provider in Settings → Connections.") {
                Button("Open provider settings") { openConnections(webSearch: false) }.buttonStyle(SettingsQuietButtonStyle())
            }
            SettingsCard(title: "Add web search", detail: "Add an Exa API key in Settings → Connections → Web search to let Pi Durable search the web. You can skip this and add it later.") {
                Button("Open web search settings") { openConnections(webSearch: true) }.buttonStyle(SettingsQuietButtonStyle())
            }
            SettingsNote("You can reopen this guide anytime from Settings → Set up harnesses.")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(step == 0 ? "Set up later" : "Skip and finish") { finish() }
                .buttonStyle(SettingsQuietButtonStyle()).keyboardShortcut(.cancelAction)
            if setup.activeInstall != nil {
                Text("The current install will finish if you close setup.")
                    .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
            }
            Spacer()
            if step == 0 {
                if !setup.selected.isEmpty {
                    Button("Install selected (\(setup.selected.count))") { setup.installSelected() }
                        .buttonStyle(DashboardPrimaryButtonStyle())
                        .disabled(setup.busy || setup.maintenanceBusy || model.localRuntimeMaintenanceHasActiveConversation)
                }
                Button("Continue") { step = 1 }
                    .buttonStyle(SettingsQuietButtonStyle()).disabled(setup.activeInstall != nil)
            } else {
                Button("Back") {
                    if showsConnections { showsConnections = false } else { step = 0 }
                }.buttonStyle(SettingsQuietButtonStyle())
                Button("Finish") { finish() }.buttonStyle(DashboardPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }.padding(20)
    }

    private func openConnections(webSearch: Bool) {
        showsWebSearchFirst = webSearch
        showsConnections = true
    }

    private func finish() {
        setup.close()
        dismissWindow(id: HarnessSetupPresentation.windowID)
    }
}
