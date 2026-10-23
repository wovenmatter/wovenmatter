import AppKit
import CompanionClient
import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsGeneralView: View {
    @Bindable var model: ApplicationModel
    var clientAnalytics: MobileAnalyticsModel?
    var showsBackgroundExecution = true
    var reservesRailControlSpace = false
    var onBack: () -> Void

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dashboardTheme) private var theme
    @AppStorage(DashboardTheme.storageKey) private var storedTheme = DashboardTheme.green.rawValue
    @AppStorage(DashboardSidebarStyle.storageKey) private var storedSidebarStyle = DashboardSidebarStyle.defaultStyle.rawValue
    @State private var showsCredentialDisclosure = false
    @State private var closedLidHelperSetup: ClosedLidHelperSetup = .unavailable

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
            credentialAccessCard
            harnessSetupCard
            appearanceCard
            sidebarLayoutCard
            if let tools = model.agentTools {
                WorkspaceToolDefaultsCard(tools: tools)
                DisclosureGroup("Connected apps · Executor") { ExecutorConnectionsCard(model: model, tools: tools) }
            }
            dictationCard
            conversationTitlesCard
            if showsBackgroundExecution { backgroundExecutionCard }
            idleSleepProtectionCard
            closedLidProtectionCard
            if let clientAnalytics {
                MobileAnalyticsSettingsCard(analytics: clientAnalytics)
            } else {
                ProductAnalyticsSettingsCard(analytics: model.analytics)
            }
        }
        .task { await model.checkSavedCredentialAccess() }
        .onReceive(NotificationCenter.default.publisher(for: KeychainAccess.accessNeedsAttention).receive(on: DispatchQueue.main)) { _ in
            model.keychainAccessNeedsAttention()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !model.isReconnectingSavedCredentials { Task { await model.checkSavedCredentialAccess() } }
        }
        .onChange(of: storedTheme) { _, _ in
            model.persistMacSurfaceProfileFromUserDefaults()
        }
        .onChange(of: storedSidebarStyle) { _, _ in
            model.persistMacSurfaceProfileFromUserDefaults()
        }
        .sheet(isPresented: $showsCredentialDisclosure) {
            CredentialAccessDisclosureView(
                purpose: "Use saved credentials across the Woven Matter features you enable, including website sessions and passwords.",
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
                 ? "A separate backend starts at login and keeps tasks, sessions, and connections running after you quit the app. This Mac must remain logged in."
                 : "Tasks and sessions run while Woven Matter is open. Background execution is off on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Choose sleep protection below for work running in either mode.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = background.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var idleSleepProtectionCard: some View {
        SettingsCard(title: "Keep working when the screen sleeps",
                     detail: "Prevent automatic system sleep only while agent work is running.") {
            Toggle("When connected to external power", isOn: idleSleepBinding(externalPower: true))
                .toggleStyle(DashboardSwitchToggleStyle())
            Toggle("When running on battery", isOn: idleSleepBinding(externalPower: false))
                .toggleStyle(DashboardSwitchToggleStyle())
            Text("The screen can turn off and lock while work continues. At this level, closing the lid or choosing Sleep can still pause work.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = model.idleSleepSettingsError {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .disabled(model.isChangingIdleSleepPolicy)
    }

    private func idleSleepBinding(externalPower: Bool) -> Binding<Bool> {
        Binding(get: {
            let policy = model.activeWorkSleepPrevention.snapshot.policy
            return externalPower ? policy.externalPower : policy.batteryPower
        }, set: { enabled in
            var policy = model.activeWorkSleepPrevention.snapshot.policy
            if externalPower { policy.externalPower = enabled } else { policy.batteryPower = enabled }
            Task { await model.setIdleSleepPolicyFromSettings(policy) }
        })
    }

    private var closedLidProtectionCard: some View {
        let snapshot = model.closedLidProtection.snapshot
        return SettingsCard(title: "Keep working when the lid is closed",
                            detail: "A higher level that includes display-sleep protection while agent work is running.") {
            Toggle("When connected to external power", isOn: closedLidBinding(externalPower: true))
                .toggleStyle(DashboardSwitchToggleStyle())
            Toggle("When running on battery", isOn: closedLidBinding(externalPower: false))
                .toggleStyle(DashboardSwitchToggleStyle())
            Text("While active, this also prevents Sleep from the Apple menu. Stop the work or turn these settings off to allow sleep. The Mac stays awake internally; keep it ventilated.")
                .font(.caption).foregroundStyle(.secondary)
            if closedLidHelperSetup == .unavailable {
                Text("Closed-lid protection requires a signed Woven Matter build with its power helper.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if snapshot.policy.isEnabled {
                if closedLidHelperSetup == .approvalRequired {
                    HStack {
                        Text("Approve Woven Matter in macOS Login Items & Extensions to enable protection.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings") { ClosedLidHelperRegistration.openApprovalSettings() }
                            .buttonStyle(SettingsQuietButtonStyle())
                    }
                } else if closedLidHelperSetup == .notRegistered {
                    Button("Set up closed-lid protection") {
                        Task { await model.setClosedLidPolicyFromSettings(snapshot.policy) }
                    }.buttonStyle(SettingsQuietButtonStyle())
                } else {
                    Text(snapshot.isProtecting ? "Closed-lid protection is active."
                         : "Protection will activate during work on the selected power sources.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = model.closedLidSettingsError ?? snapshot.message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .disabled(model.isChangingClosedLidPolicy)
        .task {
            while !Task.isCancelled {
                closedLidHelperSetup = ClosedLidHelperRegistration.status
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func closedLidBinding(externalPower: Bool) -> Binding<Bool> {
        Binding(get: {
            let policy = model.closedLidProtection.snapshot.policy
            return externalPower ? policy.externalPower : policy.batteryPower
        }, set: { enabled in
            var policy = model.closedLidProtection.snapshot.policy
            if externalPower { policy.externalPower = enabled } else { policy.batteryPower = enabled }
            Task { await model.setClosedLidPolicyFromSettings(policy) }
        })
    }

    private var harnessSetupCard: some View {
        SettingsCard(
            title: "Harness setup",
            detail: "Install more harnesses or revisit Pi Durable setup."
        ) {
            Button("Set up harnesses") {
                openWindow(id: HarnessSetupPresentation.windowID)
            }
            .buttonStyle(SettingsQuietButtonStyle())
        }
    }

    private var credentialAccessCard: some View {
        SettingsCard(
            title: "Keychain access",
            detail: "Credentials are stored in Apple Keychain."
        ) {
            HStack(alignment: .center, spacing: 16) {
                SettingsPill(model.isReconnectingSavedCredentials ? "Checking…"
                    : model.keychainAccessReady == true ? "Access ready"
                    : model.keychainAccessReady == false ? "Access needs attention"
                    : model.hasAcknowledgedCredentialAccessDisclosure ? "Checking…" : "Not enabled",
                    tone: model.keychainAccessReady == false ? .warning : .neutral)
                    .help(model.credentialAccessStatus ?? "Enable access to use saved credentials.")
                Spacer(minLength: 12)
                Button(model.isReconnectingSavedCredentials ? "Checking…"
                       : model.keychainAccessReady == true ? "Check access"
                       : model.hasAcknowledgedCredentialAccessDisclosure || model.keychainAccessReady == false
                         ? "Restore Keychain access" : "Enable Keychain access") {
                    if model.keychainAccessReady == true {
                        Task { await model.checkSavedCredentialAccess() }
                    } else if model.hasAcknowledgedCredentialAccessDisclosure {
                        Task { await model.reconnectSavedCredentials() }
                    } else {
                        showsCredentialDisclosure = true
                    }
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(model.isAuthorizingUsageCredential || model.isReconnectingSavedCredentials)
            }
            if model.keychainAccessReady != true {
                SettingsNote("Choose Always Allow when macOS asks to avoid repeated prompts.")
            }
        }
    }
    private var dictationCard: some View {
        @Bindable var dictation = DictationModel.shared
        return SettingsCard(title: "Dictation", detail: "Dictate into conversations and notes with Apple on-device speech.") {
            Picker("Language", selection: $dictation.languageIdentifier) {
                Text("Automatic").tag("")
                ForEach(dictation.session.availableLanguages, id: \.self) { identifier in
                    Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
                }
            }
            .disabled(dictation.isBusy)
            Text(dictation.availability).font(.caption).foregroundStyle(.secondary)
            Text("Audio stays on this Mac. Apple may download language support the first time you dictate. Transcripts remain drafts for review. Use ⇧⌘D to start or stop in the focused editor.")
                .font(.caption).foregroundStyle(.secondary)
        }.task { await dictation.refreshAvailability() }
    }

    private var releaseUpdateCard: some View {
        let updater = DesktopUpdater.shared
        return SettingsCard(title: "Software updates") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Woven Matter v\(currentVersion)")
                        .font(.system(size: 13, weight: .medium))
                    Text(updater.errorMessage ?? "Check for the latest version of Woven Matter.")
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Check for updates") { updater.checkForUpdates() }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
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
