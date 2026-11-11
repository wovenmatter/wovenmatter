import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

/// The type scale for settings. Pages use these tokens instead of literal sizes.
extension Font {
    static let settingsTitle = Font.system(size: 22, weight: .semibold)
    static let settingsSection = Font.system(size: 14, weight: .semibold)
    static let settingsRow = Font.system(size: 13, weight: .medium)
    static let settingsText = Font.system(size: 13)
    static let settingsBody = Font.system(size: 12.5)
    static let settingsSecondary = Font.system(size: 11.5)
}

enum SettingsMetrics {
    static let pageWidth: CGFloat = 720
    static let sectionSpacing: CGFloat = 28
    static let rowHeight: CGFloat = 40
    static let summaryTitleWidth: CGFloat = 148
}

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
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    if let onBack {
                        SettingsBackButton(title: backTitle, action: onBack)
                    }
                    Text(title)
                        .font(.settingsTitle)
                        .tracking(-0.35)
                    if let detail {
                        Text(detail)
                            .font(.settingsText)
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .font(.settingsText)
            .frame(maxWidth: SettingsMetrics.pageWidth, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, reservesRailControlSpace ? 76 : 28)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.never)
        .disclosureGroupStyle(SettingsDisclosureGroupStyle())
        .toggleStyle(SettingsSwitchToggleStyle())
        .environment(\.settingsFilledControls, true)
        .contentShape(Rectangle())
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}

struct SettingsBackButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DashboardLucideIcon(glyph: .arrowLeft, size: 16)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(DashboardIconButtonStyle())
        .environment(\.dashboardSidebarForeground, DashboardPalette.foreground)
        .accessibilityLabel("Back to " + title)
        .help("Back to " + title)
        .offset(x: -8)
    }
}

/// A row that opens another settings page. Its icon aligns with the page's left edge.
struct SettingsDestinationRow<Icon: View>: View {
    @Environment(\.dashboardTheme) private var theme
    let title: String
    let detail: String?
    let status: String?
    let statusTone: SettingsStatusTone
    @ViewBuilder var icon: Icon
    let action: () -> Void
    @State private var isHovering = false

    init(
        title: String,
        detail: String? = nil,
        status: String? = nil,
        statusTone: SettingsStatusTone = .neutral,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.status = status
        self.statusTone = statusTone
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
                        .font(.settingsRow)
                        .foregroundStyle(DashboardPalette.foreground)
                    if let detail {
                        Text(detail)
                            .font(.settingsSecondary)
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                if let status { SettingsStatus(status, tone: statusTone) }
                DashboardLucideIcon(glyph: .chevronDown, size: 12)
                    .rotationEffect(.degrees(-90))
                    .foregroundStyle(DashboardPalette.mutedForeground.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: SettingsMetrics.rowHeight)
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
        .padding(.horizontal, -12)
        .onHover { isHovering = $0 }
    }
}

struct SettingsDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    DashboardLucideIcon(glyph: .chevronDown, size: 12)
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .rotationEffect(.degrees(configuration.isExpanded ? 0 : -90))
                    configuration.label
                    Spacer(minLength: 0)
                }
                .font(.settingsText)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 0, minimumHeight: 30, idleFill: false))
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

            if configuration.isExpanded {
                configuration.content
                    .disclosureGroupStyle(self)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A heading, at most one sentence, then rows. Spacing separates sections.
struct SettingsSection<Content: View>: View {
    var title: String? = nil
    var detail: String? = nil
    @ViewBuilder var content: Content

    init(title: String? = nil, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || detail != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let title {
                        Text(title).font(.settingsSection)
                    }
                    if let detail {
                        Text(detail)
                            .font(.settingsBody)
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 2)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one settings row: title and optional secondary line on the left, control on the right.
/// When both cannot fit on one line, the control moves below the title so neither gets crushed.
struct SettingsRow<Accessory: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var accessory: Accessory

    init(title: String, detail: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.settingsRow)
            if let detail {
                Text(detail)
                    .font(.settingsSecondary)
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                label
                Spacer(minLength: 12)
                accessory
            }
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowHeight, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                label
                HStack(spacing: 8) { accessory }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

/// A switch on the right edge of its row, like every other settings control.
struct SettingsSwitchToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
                .font(.settingsRow)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: DashboardPalette.primary))
                .controlSize(.mini)
                .fixedSize()
                .scaleEffect(0.8)
                .frame(width: 28, height: 16)
        }
        .frame(minHeight: 32)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

/// A switch with an optional secondary line.
struct SettingsToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.settingsRow)
                if let detail {
                    Text(detail)
                        .font(.settingsSecondary)
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(minHeight: SettingsMetrics.rowHeight)
    }
}

private struct SettingsSummaryLabel: View {
    let title: String
    var detail: String? = nil
    let value: String?
    let tone: SettingsStatusTone?
    let chevronRotation: Double

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.settingsRow)
                    .foregroundStyle(DashboardPalette.foreground)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.settingsSecondary)
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minWidth: SettingsMetrics.summaryTitleWidth, alignment: .leading)
            if let value {
                HStack(spacing: 6) {
                    if let tone { SettingsStatusDot(tone: tone) }
                    Text(value)
                        .font(.settingsBody)
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            DashboardLucideIcon(glyph: .chevronDown, size: 12)
                .foregroundStyle(DashboardPalette.mutedForeground)
                .rotationEffect(.degrees(chevronRotation))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, detail == nil ? 0 : 6)
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Title, current value or a one-line description, and chevron. Details open only on request.
struct SettingsSummaryRow<Content: View>: View {
    let title: String
    var detail: String? = nil
    var value: String? = nil
    var tone: SettingsStatusTone? = nil
    @State private var isExpanded: Bool
    @ViewBuilder var content: Content

    init(
        _ title: String,
        detail: String? = nil,
        value: String? = nil,
        tone: SettingsStatusTone? = nil,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.value = value
        self.tone = tone
        _isExpanded = State(initialValue: initiallyExpanded)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                SettingsSummaryLabel(title: title, detail: detail, value: value, tone: tone, chevronRotation: isExpanded ? 0 : -90)
            }
            .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 0, minimumHeight: SettingsMetrics.rowHeight, idleFill: false))
            .padding(.horizontal, -8)
            .accessibilityLabel(title)
            .accessibilityValue((value ?? "") + (isExpanded ? ", expanded" : ", collapsed"))
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) { content }
                    .padding(.leading, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The same row as `SettingsSummaryRow`, opening another page instead of expanding.
struct SettingsSummaryLink: View {
    let title: String
    var detail: String? = nil
    var value: String? = nil
    var tone: SettingsStatusTone? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsSummaryLabel(title: title, detail: detail, value: value, tone: tone, chevronRotation: -90)
        }
        .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 0, minimumHeight: SettingsMetrics.rowHeight, idleFill: false))
        .padding(.horizontal, -8)
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "")
    }
}

/// Longer explanations stay folded until asked for.
struct SettingsHelp<Content: View>: View {
    var title = "How it works"
    @ViewBuilder var content: Content

    init(title: String = "How it works", @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) { content }
                .padding(.top, 4)
                .padding(.bottom, 6)
        } label: {
            Text(title).font(.settingsBody).foregroundStyle(DashboardPalette.mutedForeground)
        }
    }
}

struct SettingsLocalRuntimeInventoryRow: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind

    private var status: String {
        if model.checkingRuntimeKinds.contains(runtimeKind) { return "Checking" }
        guard let inventory = model.runtimeInventories[runtimeKind] else { return "Checking" }
        return inventory.isInstalled ? "Installed" : "Not installed"
    }

    var body: some View {
        SettingsRuntimeSummaryRow(
            summary: model.runtimeInventories[runtimeKind]?.summary ?? "Checking installed components…",
            status: status, tone: model.runtimeInventories[runtimeKind]?.isInstalled == true ? .good : .warning) {
            if model.runtimeInventories[runtimeKind]?.isInstalled == false {
                SettingsLocalRuntimeInstallButton(model: model, runtimeKind: runtimeKind)
            } else {
                SettingsLocalRuntimeUpdateButton(model: model, runtimeKind: runtimeKind)
            }
        }
    }
}

struct SettingsRuntimeSummaryRow<Actions: View>: View {
    var title = "Software"
    let summary: String
    let status: String
    var tone: SettingsStatusTone = .neutral
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.settingsRow)
                Text(summary)
                    .font(.settingsSecondary)
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            SettingsStatus(status, tone: tone)
            actions
        }
        .frame(minHeight: SettingsMetrics.rowHeight)
    }
}

struct SettingsLocalRuntimeInstallButton: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind

    var body: some View {
        let inventory = model.runtimeInventories[runtimeKind]
        let installing = model.installingLocalACPRuntimeKinds.contains(runtimeKind)
            || (runtimeKind == .opencode && model.openCode?.isInstalling == true)
        Button(installing ? "Installing…" : inventory == nil ? "Checking…" : "Install") {
            model.installLocalACPRuntimeComponent(runtimeKind)
        }
        .buttonStyle(SettingsQuietButtonStyle())
        .disabled(inventory == nil || model.runtimeMaintenanceBusy(runtimeKind) || model.checkingRuntimeInventory
            || !model.installingLocalACPRuntimeKinds.isEmpty
            || model.preparedLocalACPRuntimeInstall != nil
            || model.localRuntimeMaintenanceHasActiveConversation)
        .accessibilityLabel("Install " + runtimeKind.displayName)
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
            : hasUpdate ? (retryUpdate ? "Retry update" : "Update")
            : retryCheck ? "Retry check" : "Check for updates"
        Button(label) {
            if hasUpdate { model.updateRuntime(runtimeKind) }
            else { model.checkRuntimeUpdate(runtimeKind) }
        }
        .buttonStyle(SettingsQuietButtonStyle())
        .disabled(
            checking || model.runtimeMaintenanceBusy(runtimeKind)
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
            if runtime.failureCount > 0, runtime.operation?.action == "update" { return "Retry update" }
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
        return model.remoteWorkspaces.runtimeMaintenanceError(runtimeKind, workspaceID: workspaceID)
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

/// The settings dropdown, styled and sized like a `SettingsQuietButtonStyle` button
/// so it aligns with neighboring actions. Uses a button and popover instead of
/// `Picker`: native menu styles add padding and tint the label with the accent color.
struct SettingsPicker<Value: Hashable>: View {
    @State private var isPresented = false

    let title: String
    @Binding var selection: Value
    let options: [Value]
    var popoverWidth: CGFloat = 260
    let label: (Value) -> String

    init(
        _ title: String,
        selection: Binding<Value>,
        options: [Value],
        popoverWidth: CGFloat = 260,
        label: @escaping (Value) -> String
    ) {
        self.title = title
        _selection = selection
        self.options = options
        self.popoverWidth = popoverWidth
        self.label = label
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(label(selection))
                    .font(.settingsBody.weight(.medium))
                    .foregroundStyle(DashboardPalette.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            .contentShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(SettingsQuietButtonStyle(isActive: isPresented))
        .accessibilityLabel(title)
        .accessibilityValue(label(selection))
        .accessibilityHint(isPresented ? "Options are open" : "Shows available options")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if options.isEmpty {
                        Text("No options available")
                            .font(.settingsBody)
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    ForEach(options, id: \.self) { option in
                        Button {
                            // Choosing the current value is not a change; native pickers don't report it either.
                            if option != selection { selection = option }
                            isPresented = false
                        } label: {
                            HStack {
                                Text(label(option))
                                    .font(.settingsText)
                                    .foregroundStyle(DashboardPalette.foreground)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
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
                .padding(6)
            }
            .scrollIndicators(.never)
            .frame(width: popoverWidth)
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            .onExitCommand { isPresented = false }
        }
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
                .font(.settingsBody.weight(.medium))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

enum SettingsStatusTone {
    case neutral
    case good
    case warning
}

struct SettingsStatusDot: View {
    let tone: SettingsStatusTone

    var body: some View {
        Circle()
            .fill(tone == .warning ? DashboardPalette.warning
                : tone == .good ? DashboardPalette.success : DashboardPalette.mutedForeground.opacity(0.6))
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}

/// A status dot and text. Settings use this one treatment for readiness.
struct SettingsStatus: View {
    let text: String
    let tone: SettingsStatusTone

    init(_ text: String, tone: SettingsStatusTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 6) {
            SettingsStatusDot(tone: tone)
            Text(text)
                .font(.settingsSecondary)
                .foregroundStyle(DashboardPalette.mutedForeground)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsFilledControlsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Settings pages give quiet actions a subtle resting fill so they read as controls
    /// beside plain values. Other surfaces keep their clear resting state.
    var settingsFilledControls: Bool {
        get { self[SettingsFilledControlsKey.self] }
        set { self[SettingsFilledControlsKey.self] = newValue }
    }
}

struct SettingsQuietButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 12
    var minimumHeight: CGFloat? = nil
    var isActive = false
    /// Row-wide buttons such as disclosures stay clear until hovered.
    var idleFill = true
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsFilledControls) private var filledControls
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(DashboardPalette.foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: minimumHeight ?? (filledControls ? 32 : 36))
            .background(
                theme.palette.themeSoft.opacity(
                    configuration.isPressed || isActive ? 1
                        : (isEnabled && isHovering ? 0.72 : (idleFill && filledControls ? 0.45 : 0))
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
                    Text("Enable Keychain access")
                        .font(.system(size: 17, weight: .semibold))
                    Text(purpose)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                disclosureRow(
                    "Woven Matter saves your credentials in Apple Keychain."
                )
                disclosureRow(
                    "Enabled features can reuse saved credentials. Automatic background refreshes never request permission."
                )
                disclosureRow(
                    "You still choose which providers, runtimes, and workspaces to enable."
                )
            }

            DisclosureGroup("Keychain prompts") {
                Text("macOS may ask when you use Keychain in Settings → Permissions & Access. Choose Always Allow to remember access to the requested item. Background refreshes stay silent.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .disclosureGroupStyle(SettingsDisclosureGroupStyle())

            HStack {
                Spacer()
                Button("Not now", role: .cancel, action: onCancel)
                    .buttonStyle(SettingsQuietButtonStyle())
                Button("Enable Keychain access", action: onEnable)
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

/// Shared native-harness account controls for setup and local settings: the signed-in
/// account with Remove account, or Sign in. Codex, Claude Code, and Grok Build sign in
/// inside the app; OpenCode adds keys with its own picker in Terminal.
struct SettingsHarnessSignInControl: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind
    var compact = false
    @State private var keyMethod: HarnessSignInFlow.Method?
    @State private var key = ""
    @State private var confirmsRemoval = false
    @State private var removingCredential: AgentSignInStatus.Account?

    private var signIn: HarnessSignInModel { model.harnessSignIn }
    private var status: AgentSignInStatus? { signIn.statuses[runtimeKind] }
    private var methods: [HarnessSignInFlow.Method] { HarnessSignInFlow.methods(runtimeKind) }
    private var hasCredentials: Bool {
        ["verified", "credentials_present"].contains(status?.state ?? "")
    }
    private var busy: Bool {
        model.runtimeMaintenanceBusy(runtimeKind) || signIn.opening.contains(runtimeKind)
            || signIn.removing.contains(runtimeKind) || signIn.sessions[runtimeKind]?.isActive == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if compact {
                HStack(spacing: 8) {
                    if hasCredentials {
                        Text(status?.accounts?.first?.name ?? status?.label ?? "Signed in")
                            .font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
                    } else {
                        signInButton
                    }
                }
            } else {
                if hasCredentials { accountRows } else { signedOutRow }
                if let keyMethod { keyEntry(keyMethod) }
                SettingsHarnessSignInPanel(model: model, runtimeKind: runtimeKind)
                if let message = signIn.messages[runtimeKind] { SettingsNote(message) }
            }
        }
        .frame(minHeight: compact ? nil : SettingsMetrics.rowHeight)
        .task { await model.refreshHarnessSignIn(runtimeKind) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshHarnessSignIn(runtimeKind) }
        }
        .onChange(of: signIn.sessions[runtimeKind]?.state) { _, state in
            if state == .succeeded { Task { await model.refreshHarnessSignIn(runtimeKind) } }
        }
        .confirmationDialog("Remove your \(runtimeKind.displayName) account from this Mac?", isPresented: $confirmsRemoval,
                            titleVisibility: .visible) {
            Button("Remove account", role: .destructive) {
                Task { await signIn.signOut(runtimeKind); await model.refreshHarnessSignIn(runtimeKind) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(runtimeKind.displayName) signs out on this Mac. Sign in again to use it here.")
        }
        .confirmationDialog("Remove \(removingCredential?.name ?? "this key") from OpenCode?",
                            isPresented: Binding(get: { removingCredential != nil }, set: { if !$0 { removingCredential = nil } }),
                            titleVisibility: .visible, presenting: removingCredential) { account in
            Button("Remove", role: .destructive) {
                Task { await signIn.remove(account); await model.refreshHarnessSignIn(runtimeKind) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("OpenCode stops using this saved key.")
        }
    }

    /// Each account the harness reports. Most sign in once, so Remove account signs out;
    /// OpenCode keeps several keys and removes them one at a time.
    @ViewBuilder private var accountRows: some View {
        let accounts = status?.accounts ?? []
        if accounts.isEmpty {
            SettingsRow(title: status?.label ?? "Signed in",
                        detail: "\(runtimeKind.displayName) didn't share the account name.") { removeButton }
        }
        ForEach(Array(accounts.enumerated()), id: \.offset) { index, account in
            SettingsRow(title: account.name ?? account.method, detail: account.name == nil ? nil : account.method) {
                if runtimeKind == .opencode {
                    if account.target != nil {
                        Button("Remove") { removingCredential = account }
                            .buttonStyle(SettingsQuietButtonStyle())
                            .disabled(busy)
                            .accessibilityLabel("Remove \(account.name ?? account.method)")
                    }
                } else if index == 0 {
                    removeButton
                }
            }
        }
        if runtimeKind == .opencode {
            SettingsRow(title: "Add another key", detail: "OpenCode's picker opens in Terminal.") { signInButton }
        }
    }

    private var removeButton: some View {
        Button(signIn.removing.contains(runtimeKind) ? "Removing…" : "Remove account") { confirmsRemoval = true }
            .buttonStyle(SettingsQuietButtonStyle())
            .disabled(busy)
    }

    private var signedOutRow: some View {
        SettingsRow(title: status?.state == "not_installed" ? "Not installed" : status == nil ? "Checking sign-in…" : "Not signed in",
                    detail: status.map { $0.state == "sign_in_required" ? nil : $0.detail } ?? nil) {
            signInButton
        }
    }

    @ViewBuilder private var signInButton: some View {
        if runtimeKind == .opencode {
            Button(signIn.opening.contains(runtimeKind) ? "Opening…" : "Add key…") { signIn.signIn(runtimeKind) }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(busy || status?.state == "not_installed")
                .help("Opens OpenCode's sign-in in Terminal. Return here when finished.")
        } else if methods.count == 1, let method = methods.first {
            Button(method.title) { begin(method) }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(busy || status?.state == "not_installed")
        } else {
            Menu("Sign in") {
                ForEach(methods) { method in Button(method.title) { begin(method) } }
            }
            .menuStyle(.button)
            .fixedSize()
            .buttonStyle(SettingsQuietButtonStyle())
            .disabled(busy || status?.state == "not_installed")
            .accessibilityLabel("Sign in to \(runtimeKind.displayName)")
        }
    }

    private func begin(_ method: HarnessSignInFlow.Method) {
        if case .keyBeforeStart = method.input {
            key = ""
            keyMethod = method
        } else {
            keyMethod = nil
            signIn.start(runtimeKind, method: method)
        }
    }

    private func keyEntry(_ method: HarnessSignInFlow.Method) -> some View {
        HStack(spacing: 8) {
            SecureField({ if case .keyBeforeStart(let label) = method.input { label } else { "Key" } }(), text: $key)
                .dashboardInput()
                .onSubmit { saveKey(method) }
            Button("Save key") { saveKey(method) }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") { keyMethod = nil; key = "" }
        }
        .buttonStyle(SettingsQuietButtonStyle())
    }

    private func saveKey(_ method: HarnessSignInFlow.Method) {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        signIn.start(runtimeKind, method: method, key: value)
        key = ""
        keyMethod = nil
    }
}

/// The in-app sign-in under a harness's account: the sign-in link, the one-time code,
/// and a field for the code a sign-in page shows, styled like Subscriptions & API Keys.
struct SettingsHarnessSignInPanel: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind
    @State private var code = ""

    var body: some View {
        if let session = model.harnessSignIn.sessions[runtimeKind], session.state != .succeeded {
            VStack(alignment: .leading, spacing: 8) {
                if let url = session.url {
                    HStack {
                        Link("Open sign-in page", destination: url)
                            .foregroundStyle(DashboardPalette.success)
                        Button("Copy link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    }
                    Link(destination: url) {
                        Text(url.absoluteString).font(.settingsSecondary).multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(DashboardPalette.success)
                }
                if let value = session.code {
                    HStack {
                        Text(value).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                        Button("Copy code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(value, forType: .string)
                        }
                    }
                }
                if case .codeFromPage(let label) = session.method.input, session.state == .waiting, session.url != nil {
                    HStack {
                        TextField(label, text: $code).dashboardInput()
                            .onSubmit { send() }
                        Button(session.sentCode ? "Sent" : "Continue") { send() }
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    SettingsNote("If the page shows a code instead of finishing on its own, paste it here.")
                }
                if let tail = session.outputTail {
                    Text(tail).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(DashboardPalette.mutedForeground).textSelection(.enabled)
                }
                if session.state == .failed { SettingsError(session.message) }
                else { SettingsNote(session.message) }
                if session.isActive {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(session.url == nil ? "Preparing sign-in…" : "Waiting for sign-in…").font(.settingsBody)
                        Button("Cancel") { model.harnessSignIn.cancel(runtimeKind) }
                    }
                } else {
                    Button("Done") { model.harnessSignIn.dismiss(runtimeKind) }
                }
            }
            .buttonStyle(SettingsQuietButtonStyle())
            .padding(.vertical, 4)
        }
    }

    private func send() {
        model.harnessSignIn.submit(runtimeKind, code: code)
        code = ""
    }
}

/// One workspace selector per page. Hidden when a page has only one thing to apply to.
struct SettingsWorkspacePicker: View {
    let title: String
    @Binding var scope: String
    let workspaces: [RemoteWorkspaceConfiguration]
    var sharedLabel = "All workspaces"

    private var options: [String] {
        ["global", "local"] + workspaces.map { $0.id.uuidString.lowercased() }
    }

    var body: some View {
        SettingsRow(title: title) {
            SettingsPicker(title, selection: $scope, options: options) { option in
                switch option {
                case "global": sharedLabel
                case "local": "Local workspace"
                default: workspaces.first { $0.id.uuidString.lowercased() == option }?.name ?? "Workspace"
                }
            }
        }
    }
}

struct SettingsHarnessAccountDetails: View {
    let status: AgentSignInStatus?
    let fallback: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(status?.label ?? fallback).font(.settingsSecondary)
                .foregroundStyle(DashboardPalette.mutedForeground)
            if let accounts = status?.accounts, !accounts.isEmpty {
                ForEach(Array(accounts.enumerated()), id: \.offset) { _, account in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name ?? account.method).font(.system(size: 12.5, weight: .medium))
                        Text(account.name == nil ? "\(account.method) · Name not provided by harness" : account.method)
                            .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                }
            } else if ["verified", "credentials_present"].contains(status?.state ?? "") {
                SettingsNote("Account details not provided by this harness.")
            }
        }.textSelection(.enabled)
    }
}
