import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsGeneralView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void

    @Environment(\.dashboardTheme) private var theme
    @AppStorage(DashboardTheme.storageKey) private var storedTheme = DashboardTheme.green.rawValue
    @AppStorage(DashboardSidebarStyle.storageKey) private var storedSidebarStyle = DashboardSidebarStyle.defaultStyle.rawValue
    @State private var releaseUpdateState: ReleaseUpdateState = .idle
    @State private var showsCredentialDisclosure = false
    private let releaseUpdateInstaller = WovenMatterReleaseUpdateInstaller()

    private var sidebarStyleBinding: Binding<DashboardSidebarStyle> {
        Binding(
            get: {
                DashboardSidebarStyle(rawValue: storedSidebarStyle)
                    ?? .defaultStyle
            },
            set: { storedSidebarStyle = $0.rawValue }
        )
    }

    var body: some View {
        SettingsPage(
            title: "General",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            releaseUpdateCard
            sidebarLayoutCard
            appearanceCard
            backgroundExecutionCard
            credentialAccessCard
            dictationCard
            conversationTitlesCard
            if let tools = model.agentTools { WorkspaceToolDefaultsCard(tools: tools) }
        }
        .onChange(of: storedTheme) { _, _ in
            model.persistMacSurfaceProfileFromUserDefaults()
        }
        .onChange(of: storedSidebarStyle) { _, _ in
            model.persistMacSurfaceProfileFromUserDefaults()
        }
        .sheet(isPresented: $showsCredentialDisclosure) {
            CredentialAccessDisclosureView(
                purpose: "Use saved credentials across the Woven Matter features you enable.",
                onEnable: {
                    showsCredentialDisclosure = false
                    Task { await model.reconnectSavedCredentials() }
                },
                onCancel: { showsCredentialDisclosure = false }
            )
        }
    }

    private var backgroundExecutionCard: some View {
        let background = LocalBackgroundExecution.shared
        return SettingsCard(title: "Background execution",
                            detail: "Keep scheduled tasks and sessions running on this Mac while the app is closed.") {
            Toggle("Keep tasks and sessions running in the background", isOn: Binding(
                get: { background.pendingEnabled ?? background.isEnabled }, set: { background.setEnabled($0) }
            ))
            .toggleStyle(DashboardSwitchToggleStyle())
            .disabled(background.isChanging || !background.isAvailable)
            if !background.isAvailable {
                Text("Background execution is not available in this build.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let enabled = background.pendingEnabled {
                HStack {
                    Text("Restart Woven Matter to change execution ownership. Finish active runs first.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(background.isChanging ? "Restarting…" : enabled ? "Enable and restart" : "Disable and restart") {
                        Task { await background.applyPendingChange() }
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(background.isChanging)
                }
            }
            Text(background.isEnabled
                 ? "A separate backend starts at login and keeps tasks, sessions, and connections running after you quit the app. This Mac must remain awake and logged in."
                 : "Tasks and sessions run while Woven Matter is open. Background execution is off on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = background.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var credentialAccessCard: some View {
        SettingsCard(
            title: "Credential access",
            detail: "One saved permission for Woven Matter. Enabled features reuse credentials quietly."
        ) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.hasAcknowledgedCredentialAccessDisclosure ? "Enabled" : "Not enabled")
                        .font(.system(size: 13, weight: .medium))
                    Text(model.credentialAccessStatus
                         ?? "Automatic refreshes never request permission. Reconnect here if access to a saved credential changes.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(model.isReconnectingSavedCredentials ? "Reconnecting…"
                       : model.hasAcknowledgedCredentialAccessDisclosure
                         ? "Reconnect saved credentials" : "Enable credential access") {
                    if model.hasAcknowledgedCredentialAccessDisclosure {
                        Task { await model.reconnectSavedCredentials() }
                    } else {
                        showsCredentialDisclosure = true
                    }
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(model.isAuthorizingUsageCredential || model.isReconnectingSavedCredentials)
            }
        }
    }
    private var dictationCard: some View {
        @Bindable var dictation = DictationModel.shared
        return SettingsCard(title: "Dictation", detail: "Dictate into conversations and notes using your Grok subscription.") {
            Toggle("Enable dictation", isOn: $dictation.enabled)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dictation.accountLabel).font(.callout)
                    Text(dictation.availability).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ConnectionsLink()
            }
            Text("Audio is sent to Grok while recording. Transcripts are inserted for review; nothing is sent to an agent automatically. Turning this off keeps your Grok account connected.")
                .font(.caption).foregroundStyle(.secondary)
        }.task { await dictation.refreshAvailability() }
    }

    private var releaseUpdateCard: some View {
        SettingsCard(
            title: "Software updates"
        ) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(releaseUpdateState.title(currentVersion: currentVersion))
                        .font(.system(size: 13, weight: .medium))
                    if let detail = releaseUpdateState.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Button(releaseUpdateState.buttonTitle) {
                    performReleaseUpdateAction()
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(releaseUpdateState.isWorking)
            }
        }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    private func performReleaseUpdateAction() {
        switch releaseUpdateState {
        case .available(let manifest), .downloadFailed(let manifest, _):
            downloadRelease(manifest)
        case .ready(let release), .installFailed(let release, _):
            installRelease(release)
        case .idle, .current, .failed:
            checkForRelease()
        case .checking, .downloading, .installing:
            break
        }
    }

    private func checkForRelease() {
        releaseUpdateState = .checking
        Task {
            do {
                switch try await WovenMatterReleaseUpdateClient().check(
                    currentVersion: currentVersion
                ) {
                case .current:
                    releaseUpdateState = .current
                case .available(let manifest):
                    if let cached = try await releaseUpdateInstaller.cachedRelease(
                        for: manifest
                    ) {
                        releaseUpdateState = .ready(cached)
                    } else {
                        releaseUpdateState = .available(manifest)
                    }
                }
            } catch {
                releaseUpdateState = .failed(error.localizedDescription)
            }
        }
    }

    private func downloadRelease(_ manifest: WovenMatterReleaseManifest) {
        releaseUpdateState = .downloading(manifest)
        Task {
            do {
                releaseUpdateState = .ready(
                    try await releaseUpdateInstaller.download(manifest)
                )
            } catch {
                releaseUpdateState = .downloadFailed(
                    manifest,
                    error.localizedDescription
                )
            }
        }
    }

    private func installRelease(_ release: WovenMatterDownloadedRelease) {
        releaseUpdateState = .installing(release)
        Task {
            do {
                try await model.prepareBackendForUpdate()
                try await releaseUpdateInstaller.beginInstallation(of: release)
                WovenMatterLifecycleDelegate.requestTerminationAfterUpdate()
            } catch {
                var message = error.localizedDescription
                do { try await model.recoverBackendAfterFailedUpdate() }
                catch { message += " " + error.localizedDescription }
                releaseUpdateState = .installFailed(release, message)
            }
        }
    }

    private var appearanceCard: some View {
        SettingsCard(
            title: "Appearance"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(DashboardTheme.allCases) { option in
                    themeChoice(option)
                }
            }

        }
    }

    private var sidebarLayoutCard: some View {
        SettingsCard(title: "Sidebar layout") {
            DashboardSegmentedSelector(
                options: DashboardSidebarStyle.allCases,
                selection: sidebarStyleBinding
            ) { style in
                style.title
            }
            .frame(maxWidth: 520)

            Text(sidebarStyleBinding.wrappedValue.detail)
                .font(.system(size: 11))
                .foregroundStyle(DashboardPalette.mutedForeground)
        }
    }

    private func themeChoice(_ option: DashboardTheme) -> some View {
        let selected = theme == option
        return Button {
            storedTheme = option.rawValue
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                SettingsThemePreview(theme: option)
                HStack(alignment: .center, spacing: 10) {
                    Text(option.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DashboardPalette.foreground)
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DashboardPalette.primary)
                        .opacity(selected ? 1 : 0)
                }
            }
            .padding(12)
        }
        .buttonStyle(SettingsThemeChoiceButtonStyle(isSelected: selected))
        .accessibilityLabel("\(option.title) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var conversationTitlesCard: some View {
        SettingsCard(
            title: "Conversation titles",
            detail: "Uses your local Codex account to name new chats."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.titleGenerationStatus)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                    Spacer()
                    Toggle(
                        "Generate with Codex",
                        isOn: Binding(
                            get: { model.titleGenerationSettings.isEnabled },
                            set: { model.setTitleGenerationEnabled($0) }
                        )
                    )
                    .toggleStyle(DashboardSwitchToggleStyle())
                }

                if model.titleGenerationSettings.isEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 16) {
                            Text("Model")
                                .font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 12)
                            SettingsMenuPicker(
                                selection: model.titleGenerationSettings.model,
                                options: model.titleGenerationCapabilities?.models ?? []
                            ) { option in
                                model.setTitleGenerationModel(option)
                            }
                        }

                        HStack(spacing: 16) {
                            Text("Thinking level")
                                .font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 12)
                            SettingsMenuPicker(
                                selection: model.titleGenerationSettings.thinking,
                                options: model.titleGenerationCapabilities?.thinkingLevels ?? [],
                                capitalizeOptions: true
                            ) { option in
                                model.setTitleGenerationThinking(option)
                            }
                        }

                        HStack {
                            Spacer()
                            Button(
                                model.isRefreshingTitleGenerationCapabilities
                                    ? "Checking…" : "Refresh options"
                            ) {
                                model.refreshTitleGenerationCapabilitiesNow()
                            }
                            .buttonStyle(SettingsQuietButtonStyle())
                            .disabled(model.isRefreshingTitleGenerationCapabilities)
                        }
                    }
                }
            }
        }
    }
}

private struct SettingsThemeChoiceButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    @State private var isHovering = false
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? theme.palette.themeStrong
                    : isSelected
                        ? (isHovering ? theme.palette.themeStrong : theme.palette.themeSoft)
                        : isHovering
                            ? theme.palette.themeSoft.opacity(0.72)
                            : theme.palette.themeWhisper
            )
            .clipShape(DashboardShapes.card)
            .overlay {
                if isSelected {
                    DashboardShapes.card
                        .stroke(theme.palette.themeRing, lineWidth: 1.5)
                }
            }
            .onHover { isHovering = $0 }
    }
}

private enum ReleaseUpdateState {
    case idle
    case checking
    case current
    case available(WovenMatterReleaseManifest)
    case downloading(WovenMatterReleaseManifest)
    case ready(WovenMatterDownloadedRelease)
    case installing(WovenMatterDownloadedRelease)
    case downloadFailed(WovenMatterReleaseManifest, String)
    case installFailed(WovenMatterDownloadedRelease, String)
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    var buttonTitle: String {
        switch self {
        case .idle, .current, .failed: "Check for updates"
        case .checking: "Checking…"
        case .available: "Download update"
        case .downloading: "Downloading…"
        case .ready: "Install update"
        case .installing: "Installing…"
        case .downloadFailed: "Retry download"
        case .installFailed: "Retry installation"
        }
    }

    func title(currentVersion: String) -> String {
        switch self {
        case .available(let manifest),
             .downloading(let manifest),
             .downloadFailed(let manifest, _):
            "Woven Matter v\(manifest.version) is available"
        case .ready(let release),
             .installing(let release),
             .installFailed(let release, _):
            "Woven Matter v\(release.manifest.version) is ready"
        default: "Woven Matter v\(currentVersion)"
        }
    }

    var detail: String? {
        switch self {
        case .idle: "Check for the latest version of Woven Matter."
        case .checking: "Checking for the latest version of Woven Matter…"
        case .current: "You’re up to date."
        case .available: "Download and verify the signed update."
        case .downloading: "Downloading the update…"
        case .ready: "Installing restarts Woven Matter."
        case .installing: "Woven Matter will restart."
        case .downloadFailed(_, let message), .installFailed(_, let message): message
        case .failed(let message): message
        }
    }
}
