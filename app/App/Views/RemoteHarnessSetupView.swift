import SwiftUI
import WovenMatterClient
import WovenMatterCore

/// Reuses the harness settings account controls and the reviewed remote
/// installer. Selecting a harness never initiates an authentication flow.
struct RemoteHarnessSetupView: View {
    @Bindable var application: ApplicationModel
    let workspace: RemoteWorkspaceConfiguration
    let onClose: () -> Void
    @AppStorage private var savedSelection: String
    @AppStorage(DashboardTheme.storageKey) private var themeRawValue = DashboardTheme.green.rawValue
    @State private var selection = RemoteHarnessSetupSelection()
    @State private var step = 0
    @State private var expanded: Set<AgentRuntimeKind> = [.defaultAgent]
    @State private var showsPiSettings = false
    @State private var installQueue: [AgentRuntimeKind] = []
    @State private var requestedStage: String?
    @State private var notice: String?
    private var model: RemoteWorkspacesModel { application.remoteWorkspaces }
    private var theme: DashboardTheme { DashboardTheme(rawValue: themeRawValue) ?? .green }
    private var busy: Bool { model.busyWorkspaceIDs.contains(workspace.id) }

    init(application: ApplicationModel, workspace: RemoteWorkspaceConfiguration, onClose: @escaping () -> Void) {
        self.application = application
        self.workspace = workspace
        self.onClose = onClose
        _savedSelection = AppStorage(wrappedValue: AgentRuntimeKind.defaultAgent.rawValue,
            "wovenmatter.remote-harness-selection.\(workspace.id.uuidString)")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set up harnesses").font(.system(size: 22, weight: .semibold))
                    Text(workspace.name).font(.system(size: 13)).foregroundStyle(DashboardPalette.mutedForeground)
                }
                Spacer()
                Button("Set up later", action: finish).buttonStyle(SettingsQuietButtonStyle())
            }.padding(24)
            if showsPiSettings {
                SettingsDefaultAgentView(model: application, initialScope: workspace.id.uuidString.lowercased(),
                    onBack: { showsPiSettings = false })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if step == 0 { choices } else { accounts }
                        if let notice { SettingsNote(notice) }
                        if let error = model.errorMessage { SettingsError(error) }
                    }.padding(.horizontal, 24).padding(.bottom, 16)
                }.scrollIndicators(.never)
                HStack {
                    if step == 1 {
                        Button("Back") { installQueue = []; requestedStage = nil; step = 0 }
                            .buttonStyle(SettingsQuietButtonStyle()).disabled(busy)
                        Button("Retry selected installs", action: beginInstalls)
                            .buttonStyle(SettingsQuietButtonStyle()).disabled(busy || !installQueue.isEmpty)
                    }
                    Spacer()
                    if step == 0 {
                        Button(selection.selected.count == 1 ? "Continue" : "Install and continue") {
                            step = 1
                            expanded = selection.selected
                            beginInstalls()
                        }.buttonStyle(DashboardPrimaryButtonStyle()).disabled(busy || model.isCreating)
                    } else {
                        Button("Done", action: finish).buttonStyle(DashboardPrimaryButtonStyle())
                    }
                }.padding(24)
            }
        }
        .frame(width: 760, height: 650)
        .foregroundStyle(DashboardPalette.foreground)
        .background(theme.palette.workspace)
        .environment(\.dashboardTheme, theme)
        .preferredColorScheme(theme.colorScheme)
        .disclosureGroupStyle(SettingsDisclosureGroupStyle())
        .modifier(RemoteHarnessInstallerConfirmation(model: model, workspaceID: workspace.id,
            onCancel: { installQueue = []; requestedStage = nil }))
        .task {
            selection.selected = Set(savedSelection.split(separator: ",").compactMap { AgentRuntimeKind(rawValue: String($0)) })
                .union([.defaultAgent])
            model.refresh(workspace)
        }
        .onChange(of: selection.selected) { _, _ in savedSelection = selection.ordered.map(\.rawValue).joined(separator: ",") }
        .onChange(of: busy) { _, busy in if !busy { advanceInstall() } }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose the harnesses to use in this workspace.").font(.system(size: 13))
            VStack(spacing: 0) {
                ForEach(AgentRuntimeKind.allCases.sorted { $0.presentationRank < $1.presentationRank }, id: \.self) { kind in
                    HStack(spacing: 12) {
                        DashboardHarnessLogoIcon(logo: DashboardHarnessLogo(runtimeKind: kind), size: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.displayName).font(.system(size: 13, weight: .medium))
                            Text(kind == .defaultAgent ? "Included" : model.runtimeMaintenance[workspace.id]?.first(where: { $0.id == kind })?.installed == true ? "Installed" : "Install in this workspace")
                                .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                        Spacer()
                        Toggle(kind.displayName, isOn: Binding(get: { selection.selected.contains(kind) },
                            set: { selection.select(kind, enabled: $0) }))
                            .labelsHidden().toggleStyle(DashboardSwitchToggleStyle()).disabled(kind == .defaultAgent)
                    }.padding(16)
                    if kind != AgentRuntimeKind.allCases.max(by: { $0.presentationRank < $1.presentationRank }) {
                        Rectangle().fill(theme.palette.border).frame(height: 1).padding(.horizontal, 16)
                    }
                }
            }.background(theme.palette.themeWhisper).clipShape(DashboardShapes.card)
            SettingsNote("Sign in after installation. You can skip any account and return later.")
        }
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !installQueue.isEmpty { SettingsNote("Setting up \(installQueue[0].displayName)… Review its installer to continue.") }
            ForEach(selection.ordered, id: \.self) { kind in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(kind) }, set: { if $0 { expanded.insert(kind) } else { expanded.remove(kind) } })) {
                    if kind == .defaultAgent {
                        Button("Open Pi Durable settings") { showsPiSettings = true }
                            .buttonStyle(SettingsQuietButtonStyle())
                    } else {
                        SettingsRemoteHarnessAccountView(model: model, runtimeKind: kind, workspace: workspace)
                        SettingsRemoteHarnessSoftware(model: model, runtimeKind: kind, workspace: workspace)
                    }
                } label: {
                    HStack(spacing: 10) {
                        DashboardHarnessLogoIcon(logo: DashboardHarnessLogo(runtimeKind: kind), size: 20)
                        Text(kind.displayName)
                    }
                }
            }
        }
    }

    private func beginInstalls() {
        notice = nil
        requestedStage = nil
        installQueue = selection.ordered.filter { $0 != .defaultAgent }
        advanceInstall()
    }

    private func advanceInstall() {
        guard !busy, model.preparedHarnessAction == nil, let kind = installQueue.first else { return }
        guard let runtime = model.runtimeMaintenance[workspace.id]?.first(where: { $0.id == kind }),
              let harness = model.currentHarnesses(for: workspace).first(where: { $0.id == kind }) else {
            notice = "Connect the workspace and retry to install the selected harnesses."
            installQueue = []; requestedStage = nil
            return
        }
        if runtime.installed {
            installQueue.removeFirst(); requestedStage = nil; advanceInstall()
        } else if requestedStage == nil {
            requestedStage = "install"
            model.prepareHarnessAction("install", harness: harness, configuration: workspace)
        } else {
            notice = "\(kind.displayName) could not finish setup. Review its status below, then retry."
            installQueue = []; requestedStage = nil
        }
    }

    private func finish() {
        installQueue = []
        requestedStage = nil
        model.cancelPreparedHarnessAction(workspaceID: workspace.id, action: "install")
        onClose()
    }
}
