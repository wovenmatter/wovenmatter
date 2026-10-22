import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct HarnessSetupView: View {
    @State private var setup: HarnessSetupModel
    @State private var step = 0
    @State private var showsConnections = false
    @State private var showsWebSearchFirst = false
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
                    webSearchFirst: showsWebSearchFirst, onBack: { showsConnections = false })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if step == 0 { harnesses } else { piDurable }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
                .scrollIndicators(.never)
            }
            footer
        }
        .frame(width: 760, height: 650)
        .foregroundStyle(DashboardPalette.foreground)
        .background(theme.palette.workspace)
        .environment(\.dashboardTheme, theme)
        .preferredColorScheme(theme.colorScheme)
        .toggleStyle(DashboardSwitchToggleStyle())
        .task { step = 0; showsConnections = false; setup.open() }
        .onDisappear { setup.close() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(step == 0 ? "Set up your harnesses" : "Make Pi Durable your own")
                    .font(.system(size: 22, weight: .semibold)).tracking(-0.35)
                Spacer()
                Text("\(step + 1) of 2")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            Text(step == 0
                 ? "Use the tools already on your Mac, or choose more to install."
                 : "Already included. Connect a provider and add web search whenever you’re ready.")
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                DashboardHarnessLogoIcon(logo: DashboardHarnessLogo(runtimeKind: .defaultAgent), size: 28)
                Text("Pi Durable").font(.system(size: 14, weight: .semibold))
                Spacer()
                SettingsPill("Included", tone: .neutral)
            }.padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 12) {
                SettingsCard(title: "Connect a model provider", detail: "Sign in to a subscription or add an API key. You can connect more than one provider.") {
                    Button("Open provider settings") { openConnections(webSearch: false) }.buttonStyle(SettingsQuietButtonStyle())
                }
                SettingsCard(title: "Add web search", detail: "Add an Exa API key so Pi Durable can search the web.") {
                    Button("Open web search settings") { openConnections(webSearch: true) }.buttonStyle(SettingsQuietButtonStyle())
                }
            }
            SettingsNote("Both steps are optional. Reopen this guide from Settings → General → Set up harnesses.")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(step == 0 ? "Set up later" : "Skip and finish") { finish() }
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
                    if showsConnections { showsConnections = false } else { step = 0 }
                }.buttonStyle(SettingsQuietButtonStyle())
                Button("Finish") { finish() }.buttonStyle(DashboardPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func openConnections(webSearch: Bool) { showsWebSearchFirst = webSearch; showsConnections = true }
    private func finish() { setup.close(); dismissWindow(id: HarnessSetupPresentation.windowID) }
}
