import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsPage<Content: View>: View {
    let title: String
    var detail: String? = nil
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    var onBack: (() -> Void)? = nil
    @ViewBuilder var content: Content

    init(
        title: String,
        detail: String? = nil,
        reservesRailControlSpace: Bool = false,
        backTitle: String = "Settings",
        onBack: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.reservesRailControlSpace = reservesRailControlSpace
        self.backTitle = backTitle
        self.onBack = onBack
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    if let onBack {
                        SettingsBackButton(title: backTitle, action: onBack)
                    }
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.35)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 13))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 4)
                content
            }
            .frame(maxWidth: 1_080, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, reservesRailControlSpace ? 76 : 28)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.never)
        .contentShape(Rectangle())
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}

struct SettingsWorkspaceSidebarVisibilityControl: View {
    let workspace: DashboardWorkspaceSidebarVisibility
    @AppStorage private var isShown: Bool

    init(_ workspace: DashboardWorkspaceSidebarVisibility) {
        self.workspace = workspace
        _isShown = AppStorage(wrappedValue: true, workspace.storageKey)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Sidebar visibility")
                .font(.system(size: 13))
                .foregroundStyle(DashboardPalette.mutedForeground)
            Button(isShown ? "Hide" : "Show") {
                isShown.toggle()
            }
            .buttonStyle(SettingsQuietButtonStyle())
            .accessibilityLabel("\(isShown ? "Hide" : "Show") \(workspace.title) in the sidebar")
            .accessibilityValue(isShown ? "Shown" : "Hidden")
            .help("Hides or shows this section. Workspaces and chats stay active.")
        }
    }
}

struct SettingsBackButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DashboardLucideIcon(glyph: .panelLeftClose, size: 16)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(DashboardIconButtonStyle())
        .environment(\.dashboardSidebarForeground, DashboardPalette.foreground)
        .accessibilityLabel("Back to " + title)
        .help("Back to " + title)
        .offset(x: -8)
    }
}

struct SettingsDestinationRow<Icon: View>: View {
    @Environment(\.dashboardTheme) private var theme
    let title: String
    let detail: String?
    @ViewBuilder var icon: Icon
    let action: () -> Void
    @State private var isHovering = false

    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon
                    .frame(width: 16, height: 16)
                    .foregroundStyle(DashboardPalette.mutedForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DashboardPalette.foreground)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DashboardPalette.mutedForeground.opacity(0.55))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isHovering ? theme.palette.themeWhisper : Color.clear)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DashboardMetrics.controlRadius,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct SettingsCard<Content: View>: View {
    @Environment(\.dashboardTheme) private var theme
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: Content

    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.workspace)
        .clipShape(DashboardShapes.card)
    }
}

struct SettingsHarnessRuntimeMaintenanceView: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind
    var workspaceID: UUID?

    private var localAvailability: LocalACPRuntimeAvailability? {
        model.localACPRuntimeAvailability.first { $0.runtimeKind == runtimeKind }
    }

    private var remoteWorkspace: RemoteWorkspaceConfiguration? {
        workspaceID.flatMap { model.remoteWorkspaces.configuration(id: $0) }
    }

    private var remoteRuntime: RemoteRuntimeMaintenance? {
        guard let workspaceID else { return nil }
        return model.remoteWorkspaces.runtimeMaintenance[workspaceID]?.first {
            $0.id == runtimeKind
        }
    }

    private var remoteHarness: RemoteHarnessStatus? {
        guard let remoteWorkspace else { return nil }
        return model.remoteWorkspaces.currentHarnesses(for: remoteWorkspace).first {
            $0.id == runtimeKind
        }
    }

    var body: some View {
        SettingsCard(
            title: workspaceID == nil
                ? "Local agent workspace"
                : remoteWorkspace?.name ?? "Remote agent workspace"
        ) {
            SettingsInset {
                HStack(alignment: .center, spacing: 12) {
                    DashboardHarnessLogoIcon(
                        logo: DashboardHarnessLogo(runtimeKind: runtimeKind),
                        size: 24
                    )
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(runtimeKind.displayName)
                            .font(.system(size: 13, weight: .medium))
                        Text(runtimeDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    SettingsPill(
                        runtimeStatus,
                        tone: runtimeIsReady ? .neutral : .warning
                    )

                    if let workspaceID {
                        if let remoteWorkspace, let remoteHarness {
                            SettingsRemoteRuntimeUpdateButton(
                                model: model.remoteWorkspaces,
                                harness: remoteHarness,
                                configuration: remoteWorkspace
                            )
                        } else {
                            Button("Unavailable") {}
                                .buttonStyle(SettingsQuietButtonStyle())
                                .disabled(true)
                                .accessibilityLabel("Runtime controls unavailable for remote workspace \(workspaceID.uuidString)")
                        }
                    } else {
                        SettingsLocalRuntimeUpdateButton(model: model, runtimeKind: runtimeKind)
                    }
                }
            }

            if let error = runtimeError {
                SettingsError(error)
            }
        }
    }

    private var runtimeIsReady: Bool {
        if workspaceID != nil {
            guard let remoteWorkspace else { return false }
            return model.remoteWorkspaces.isHarnessReady(runtimeKind, in: remoteWorkspace)
        }
        if runtimeKind == .opencode {
            return model.openCode?.isInstalled == true && model.openCode?.isEnabled == true
        }
        return !model.checkingLocalACPRuntimeKinds.contains(runtimeKind)
            && localAvailability?.isReady == true
            && model.isLocalACPAgentReady(runtimeKind)
    }

    private var runtimeStatus: String {
        if let workspaceID {
            if model.remoteWorkspaces.checkingRuntimeIDs[workspaceID]?.contains(runtimeKind) == true {
                return "Checking"
            }
            guard let remoteWorkspace, let remoteRuntime else { return "Not checked" }
            if model.remoteWorkspaces.isHarnessReady(runtimeKind, in: remoteWorkspace) {
                return "Ready"
            }
            if !remoteRuntime.installed
                || model.remoteWorkspaces.isRuntimeInventoryUnavailable(
                    runtimeKind,
                    configuration: remoteWorkspace
                )
                || remoteRuntime.operation?.status == "running" {
                return "Unavailable"
            }
            if !remoteRuntime.enabled { return "Not enabled" }
            let state = remoteHarness?.state
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return state == "Ready" ? "Unavailable" : state ?? "Not checked"
        }
        if runtimeKind == .opencode {
            guard let openCode = model.openCode else { return "Checking" }
            return openCode.isEnabled ? "Enabled" : "Not enabled"
        }
        if model.checkingLocalACPRuntimeKinds.contains(runtimeKind) { return "Checking" }
        if !model.isLocalACPRuntimeCredentialAccessEnabled(runtimeKind),
           localAvailability?.executablePath != nil {
            return "Not enabled"
        }
        if localAvailability?.isReady == true,
           !model.isLocalACPAgentReady(runtimeKind) {
            return "Workspace unavailable"
        }
        guard let localAvailability else { return "Checking" }
        return switch localAvailability.state {
        case .ready: "Ready"
        case .cliMissing: "CLI required"
        case .adapterMissing: "Adapter required"
        case .adapterOutdated: "Update required"
        case .authenticationRequired: "Sign in required"
        case .executableUnavailable: "Setup required"
        }
    }

    private var runtimeDetail: String {
        if workspaceID != nil {
            guard let remoteRuntime else { return "Runtime inventory unavailable." }
            return remoteRuntime.components.map { component in
                let installed = component.installed
                    ? component.installedVersion ?? "version unavailable"
                    : "missing"
                let newer = component.availableUpdateVersion.map { " → \($0)" } ?? ""
                return "\(component.displayName) \(installed)\(newer)"
            }.joined(separator: " · ")
        }
        if let inventory = model.runtimeInventories[runtimeKind] {
            return inventory.summary
        }
        return localAvailability?.detail ?? "Checking the local runtime…"
    }

    private var runtimeError: String? {
        if let workspaceID {
            if let error = remoteRuntime?.operation?.error { return error }
            return model.remoteWorkspaces.runtimeCheckErrors[workspaceID]?[runtimeKind]
                ?? model.remoteWorkspaces.actionErrors[workspaceID]?[runtimeKind]
                ?? model.remoteWorkspaces.runtimeErrors[workspaceID]
        }
        return model.runtimeFailureDetails[runtimeKind]
    }
}

struct SettingsLocalRuntimeUpdateButton: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind

    var body: some View {
        let inventory = model.runtimeInventories[runtimeKind]
        let updating = model.updatingRuntimeKinds.contains(runtimeKind)
        let checking = model.checkingRuntimeKinds.contains(runtimeKind)
        let retryUpdate = model.failedRuntimeUpdateKinds.contains(runtimeKind)
        let hasUpdate = inventory?.isInstalled == true
            && (inventory?.updateAvailable == true || retryUpdate)
        let retryCheck = model.checkedRuntimeKinds.contains(runtimeKind)
            && inventory?.latestUnavailable == true
        let label = updating ? "Updating…" : checking ? "Checking…"
            : hasUpdate ? (retryUpdate ? "Retry Update" : "Update")
            : retryCheck ? "Retry check" : "Check for updates"
        Button(label) {
            if hasUpdate { model.updateRuntime(runtimeKind) }
            else { model.checkRuntimeUpdate(runtimeKind) }
        }
        .buttonStyle(SettingsQuietButtonStyle())
        .disabled(
            checking || model.checkingRuntimeInventory
                || !model.installingLocalACPRuntimeKinds.isEmpty
                || model.openCode?.isInstalling == true
                || (hasUpdate && model.localRuntimeMaintenanceHasActiveConversation)
        )
        .accessibilityLabel(label + " for " + runtimeKind.displayName)
    }
}

struct SettingsRemoteRuntimeUpdateButton: View {
    @Bindable var model: RemoteWorkspacesModel
    let harness: RemoteHarnessStatus
    let configuration: RemoteWorkspaceConfiguration

    private var runtime: RemoteRuntimeMaintenance? {
        model.runtimeMaintenance[configuration.id]?.first { $0.id == harness.id }
    }

    private var preparedUpdateMatches: Bool {
        guard let prepared = model.preparedHarnessAction else { return false }
        return prepared.configuration.id == configuration.id
            && prepared.harness.id == harness.id && prepared.action == "update"
    }

    var body: some View {
        let checking = model.checkingRuntimeIDs[configuration.id]?.contains(harness.id) == true
        let running = runtime?.operation?.status == "running"
        let unavailable = model.isRuntimeInventoryUnavailable(harness.id, configuration: configuration)
        let checkUnavailable = unavailable
            || model.runtimeCheckErrors[configuration.id]?[harness.id] != nil
            || runtime?.versionCheckAvailable == false
        let busy = model.busyWorkspaceIDs.contains(configuration.id) || running || checking
        let label = updateButtonTitle(checking: checking, running: running, checkUnavailable: checkUnavailable)
        Button(label) {
            if let runtime, runtime.installed,
               runtime.updateAvailable || (runtime.failureCount > 0 && runtime.operation?.action == "update"),
               !checkUnavailable {
                model.prepareHarnessAction("update", harness: harness, configuration: configuration)
            } else {
                model.checkRuntimeUpdates(harness.id, configuration: configuration)
            }
        }
        .buttonStyle(SettingsQuietButtonStyle())
        .disabled(busy)
        .accessibilityLabel(label + " for " + harness.displayName)
        .confirmationDialog(
            "Confirm harness update?",
            isPresented: Binding(
                get: { preparedUpdateMatches },
                set: { if !$0 { cancelMatchingUpdate() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Confirm Update") {
                model.confirmPreparedHarnessAction(
                    workspaceID: configuration.id, harnessID: harness.id, action: "update"
                )
            }
            Button("Cancel", role: .cancel) { cancelMatchingUpdate() }
        } message: {
            if preparedUpdateMatches, let prepared = model.preparedHarnessAction {
                if let sha256 = prepared.preview.sha256 {
                    Text("Source: \(prepared.preview.source)\nSHA-256: \(sha256)\nThe service will download the source again and refuse to run it if this digest changes.")
                } else {
                    Text("Source: \(prepared.preview.source)\nPackage-manager integrity verification applies.\nCommand: \(prepared.preview.command)")
                }
            }
        }
    }

    private func updateButtonTitle(checking: Bool, running: Bool, checkUnavailable: Bool) -> String {
        if checking { return "Checking…" }
        if running, runtime?.operation?.action == "update" { return "Updating…" }
        if checkUnavailable && !running { return "Retry check" }
        if let runtime {
            if runtime.failureCount > 0, runtime.operation?.action == "update" { return "Retry Update" }
            if runtime.updateAvailable { return "Update" }
        }
        return "Check for updates"
    }

    private func cancelMatchingUpdate() {
        model.cancelPreparedHarnessAction(
            workspaceID: configuration.id, harnessID: harness.id, action: "update"
        )
    }
}

struct SettingsRuntimeMaintenanceErrorView: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind
    var workspaceID: UUID?

    private var message: String? {
        guard let workspaceID else { return model.runtimeFailureDetails[runtimeKind] }
        let runtime = model.remoteWorkspaces.runtimeMaintenance[workspaceID]?.first {
            $0.id == runtimeKind
        }
        return runtime?.operation?.error
            ?? model.remoteWorkspaces.runtimeCheckErrors[workspaceID]?[runtimeKind]
            ?? model.remoteWorkspaces.actionErrors[workspaceID]?[runtimeKind]
            ?? model.remoteWorkspaces.runtimeErrors[workspaceID]
    }

    @ViewBuilder
    var body: some View {
        if let message, !message.isEmpty {
            SettingsError(message)
        }
    }
}

struct SettingsField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.25)
                .foregroundStyle(DashboardPalette.mutedForeground)
            content
        }
    }
}

struct SettingsInset<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(DashboardPalette.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Dropdown picker

/// Compact dropdown styled and sized exactly like a SettingsQuietButtonStyle
/// button so it aligns with neighboring action buttons. Uses a Button +
/// popover instead of Menu/Picker: native menu styles add internal padding
/// that breaks edge alignment and tint the label with the accent color.
struct SettingsMenuPicker: View {
    @State private var isPresented = false

    let selection: String
    let options: [String]
    var capitalizeOptions: Bool = false
    var width: CGFloat = 180
    let onSelect: (String) -> Void

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(selection.isEmpty ? "Select…" : label(for: selection))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DashboardPalette.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: 36, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 0, isActive: isPresented))
        .accessibilityValue(selection.isEmpty ? "No selection" : label(for: selection))
        .accessibilityHint(isPresented ? "Options are open" : "Shows available options")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if options.isEmpty {
                    Text("No options available")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                } else {
                    ForEach(options, id: \.self) { option in
                        Button {
                            onSelect(option)
                            isPresented = false
                        } label: {
                            HStack {
                                Text(label(for: option))
                                    .font(.system(size: 13))
                                    .foregroundStyle(DashboardPalette.foreground)
                                Spacer()
                                if option == selection {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(DashboardPalette.primary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SettingsMenuOptionButtonStyle())
                        .accessibilityAddTraits(option == selection ? .isSelected : [])
                    }
                }
            }
            .padding(6)
            .frame(minWidth: width)
            .onExitCommand { isPresented = false }
        }
    }

    private func label(for option: String) -> String {
        capitalizeOptions ? option.capitalized : option
    }
}

struct SettingsMenuOptionButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                isEnabled && (configuration.isPressed || isHovering)
                    ? (configuration.isPressed
                        ? theme.palette.themeSoft
                        : theme.palette.themeWhisper)
                    : .clear
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DashboardMetrics.controlRadius - 4,
                    style: .continuous
                )
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
    }
}

struct SettingsEmpty: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(DashboardPalette.mutedForeground)
            .padding(.vertical, 4)
    }
}

struct SettingsError: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DashboardPalette.danger)
            .textSelection(.enabled)
    }
}

struct SettingsValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

enum SettingsPillTone {
    case neutral
    case warning
}

struct SettingsPill: View {
    @Environment(\.dashboardTheme) private var theme
    let text: String
    let tone: SettingsPillTone

    init(_ text: String, tone: SettingsPillTone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tone == .warning ? DashboardPalette.warning : DashboardPalette.mutedForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tone == .warning ? DashboardPalette.warning.opacity(0.1) : theme.palette.themeSoft)
            .clipShape(Capsule())
    }
}

struct SettingsThemePreview: View {
    let theme: DashboardTheme

    private var railFill: Color {
        theme == .green
            ? .hex(0x004225, opacity: 0.16)
            : .hex(0xFFFFFF, opacity: 0.96)
    }

    var body: some View {
        HStack(spacing: 8) {
            previewRail
            VStack(alignment: .leading, spacing: 5) {
                Spacer()
                Capsule()
                    .fill(DashboardPalette.primary)
                    .frame(width: 32, height: 6)
                Capsule()
                    .fill(Color.black.opacity(0.06))
                    .frame(height: 6)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background {
                theme.palette.workspace
                    .overlay(theme.palette.themeWhisper)
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DashboardMetrics.controlRadius,
                    style: .continuous
                )
            )
            previewRail
        }
        .padding(8)
        .frame(height: 80)
        .background(theme.palette.workspace)
        .clipShape(DashboardShapes.card)
        .shadow(color: .hex(0x0A1F16, opacity: 0.07), radius: 6, y: 2)
    }

    private var previewRail: some View {
        RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous)
            .fill(railFill)
            .frame(width: 32)
            .shadow(
                color: theme == .cognac ? Color.hex(0x4D2D15, opacity: 0.08) : .clear,
                radius: 7,
                y: 3
            )
    }
}

struct SettingsInputModifier: ViewModifier {
    @Environment(\.dashboardTheme) private var theme
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($focused)
            .background(theme.palette.workspace)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DashboardMetrics.controlRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: DashboardMetrics.controlRadius,
                    style: .continuous
                )
                .stroke(
                    focused ? theme.palette.themeRing : DashboardPalette.mutedForeground.opacity(0.3),
                    lineWidth: focused ? 1.5 : 1
                )
            }
    }
}

extension View {
    func settingsInput() -> some View {
        modifier(SettingsInputModifier())
    }
}

struct SettingsQuietButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 12
    var minimumHeight: CGFloat = 36
    var isActive = false
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(DashboardPalette.foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: minimumHeight)
            .background(
                theme.palette.themeSoft.opacity(
                    configuration.isPressed || isActive ? 1 : (isEnabled && isHovering ? 0.72 : 0)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
    }
}

struct CredentialAccessDisclosureView: View {
    let purpose: String
    let onEnable: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(DashboardPalette.primary)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle().fill(DashboardPalette.primary.opacity(0.1))
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow credential access")
                        .font(.system(size: 17, weight: .semibold))
                    Text(purpose)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                disclosureRow(
                    "Woven Matter may ask macOS Keychain for credentials that you have chosen to use."
                )
                disclosureRow(
                    "Provider CLIs may check their own signed-in accounts and credential stores."
                )
                disclosureRow(
                    "Cursor usage can read Cursor's local account session only after you enable Cursor usage tracking."
                )
            }

            DisclosureGroup("Keychain prompts") {
                Text("macOS controls its password prompt. Choosing Always Allow normally prevents repeat prompts while the app's signing identity remains unchanged.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }

            HStack {
                Spacer()
                Button("Not now", role: .cancel, action: onCancel)
                    .buttonStyle(SettingsQuietButtonStyle())
                Button("Continue", action: onEnable)
                    .buttonStyle(DashboardPrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(DashboardPalette.background)
    }

    private func disclosureRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DashboardPalette.primary)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
