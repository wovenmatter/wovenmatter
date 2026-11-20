import AppKit
import SwiftUI

struct SettingsGeneralView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void
    var onOpenCodex: () -> Void = {}
    var onOpenUpdates: () -> Void = {}
    private var updates: UpdatesStore { model.updates }

    @AppStorage(WovenTheme.storageKey) private var storedTheme = WovenTheme.green.rawValue
    @AppStorage(SidebarStyle.storageKey) private var storedSidebarStyle = SidebarStyle.defaultStyle.rawValue
    @AppStorage(PiDurableLogoStyle.storageKey) private var storedPiDurableLogoStyle =
        PiDurableLogoStyle.defaultStyle.rawValue
    @AppStorage(CodexLogoStyle.storageKey) private var storedCodexLogoStyle =
        CodexLogoStyle.defaultStyle.rawValue
    @AppStorage(WorkspaceSidebarVisibility.localWorkspace.storageKey) private var showsLocalWorkspace = true
    @AppStorage(WorkspaceSidebarVisibility.remoteWorkspaces.storageKey) private var showsRemoteWorkspaces = true

    private var themeBinding: Binding<WovenTheme> {
        Binding(
            get: { WovenTheme(rawValue: storedTheme) ?? .green },
            set: { storedTheme = $0.rawValue }
        )
    }

    private var sidebarStyleBinding: Binding<SidebarStyle> {
        Binding(
            get: {
                SidebarStyle(rawValue: storedSidebarStyle)
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
            versionSection
            appearanceSection
            SettingsConversationTitlesSection(model: model, onOpenCodex: onOpenCodex)
            ProductAnalyticsSettingsSection(settings: model.settings)
        }
        .onChange(of: storedTheme) { _, _ in
            model.settings.persistMacSurfaceProfileFromUserDefaults()
        }
        .onChange(of: storedSidebarStyle) { _, _ in
            model.settings.persistMacSurfaceProfileFromUserDefaults()
        }
    }

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance") {
            SettingsRow(title: "Theme") {
                WovenSegmentedSelector(options: WovenTheme.allCases, selection: themeBinding) { $0.title }
                    .frame(width: 300)
            }
            SettingsRow(title: "Sidebar layout", detail: sidebarStyleBinding.wrappedValue.detail) {
                WovenSegmentedSelector(options: SidebarStyle.allCases, selection: sidebarStyleBinding) { style in
                    style.title.replacingOccurrences(of: " Sidebar", with: "")
                }
                .frame(width: 300)
            }
            SettingsSummaryRow("Sidebar sections", detail: "Hide or show the workspace sections in the sidebar.") {
                Toggle(WorkspaceSidebarVisibility.localWorkspace.title, isOn: $showsLocalWorkspace)
                Toggle(WorkspaceSidebarVisibility.remoteWorkspaces.title, isOn: $showsRemoteWorkspaces)
                SettingsNote("Hides or shows these sidebar sections. Workspaces and chats stay active.")
            }
            SettingsSummaryRow("Agent icons", detail: "Choose how the Pi Durable and Codex icons look throughout the app.") {
                SettingsRow(title: "Pi Durable") {
                    SettingsPicker("Pi Durable icon", selection: Binding(
                        get: { piDurableLogoStyle }, set: { storedPiDurableLogoStyle = $0.rawValue }
                    ), options: PiDurableLogoStyle.allCases) { $0.displayName }
                }
                SettingsRow(title: "Codex") {
                    SettingsPicker("Codex icon", selection: Binding(
                        get: { codexLogoStyle }, set: { storedCodexLogoStyle = $0.rawValue }
                    ), options: CodexLogoStyle.allCases) { $0.displayName }
                }
            }
        }
    }

    private var piDurableLogoStyle: PiDurableLogoStyle {
        PiDurableLogoStyle(rawValue: storedPiDurableLogoStyle) ?? .defaultStyle
    }

    private var codexLogoStyle: CodexLogoStyle {
        CodexLogoStyle(rawValue: storedCodexLogoStyle) ?? .defaultStyle
    }

    /// The first row: this Mac's Woven Matter version. The whole row opens Settings → Updates,
    /// where this Mac and every other device are updated.
    private var versionSection: some View {
        SettingsSection {
            SettingsDestinationRow(
                title: Self.isDevelopmentBuild ? "Woven Matter development build" : "Woven Matter \(Self.appVersion)",
                detail: "Open Updates to update this Mac, your other devices, and their harnesses.",
                status: updates.running ? "Updating…" : updates.availableCount > 0 ? "Update available" : nil,
                statusTone: updates.running ? .neutral : .warning,
                icon: { LucideIcon(glyph: .rocket, size: 15) },
                action: onOpenUpdates
            )
        }
        .task { updates.loadIfNeeded() }
    }

    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    #if DEBUG
    private static let isDevelopmentBuild = true
    #else
    private static let isDevelopmentBuild = false
    #endif
}

/// Conversation titles use the Codex account on this Mac, so the section shows that
/// account and links to the Codex page, where it signs in.
private struct SettingsConversationTitlesSection: View {
    @Bindable var model: ApplicationModel
    let onOpenCodex: () -> Void

    private var store: SettingsStore { model.settings }
    private var settings: ConversationTitleGenerationSettings { store.titleGenerationSettings }
    private var codex: AgentSignInStatus? { model.thisMachineID.flatMap { model.machines.signInStatus(.codex, on: $0) } }
    private var signedIn: Bool { codex?.hasCredentials == true }
    private var checking: Bool { model.thisMachineID.map { model.machines.isCheckingSignIn(.codex, on: $0) } ?? false }

    private var accountValue: String {
        if signedIn { return codex?.accounts.first?.name ?? "Signed in" }
        if codex == nil || checking { return "Checking…" }
        return codex?.state == .notInstalled ? "Codex isn't installed" : "Not signed in"
    }

    var body: some View {
        SettingsSection(title: "Conversation titles", detail: "Names new chats from their first message using your Codex account on this Mac.") {
            SettingsToggleRow(
                title: "Generate titles",
                detail: settings.isEnabled ? store.titleGenerationStatus : nil,
                isOn: Binding(get: { settings.isEnabled }, set: { store.setTitleGenerationEnabled($0) })
            )
            SettingsSummaryLink(title: "Codex account", value: accountValue,
                                tone: codex == nil ? nil : signedIn ? .good : .warning, action: onOpenCodex)
            if settings.isEnabled {
                if signedIn {
                    SettingsRow(title: "Model") {
                        SettingsPicker(
                            "Title model",
                            selection: Binding(get: { settings.model }, set: { store.setTitleGenerationModel($0) }),
                            options: options(store.titleGenerationCapabilities?.models, selected: settings.model)
                        ) { $0 }
                    }
                    SettingsRow(title: "Thinking level") {
                        SettingsPicker(
                            "Title thinking level",
                            selection: Binding(get: { settings.thinking }, set: { store.setTitleGenerationThinking($0) }),
                            options: options(store.titleGenerationCapabilities?.thinkingLevels, selected: settings.thinking)
                        ) { $0.capitalized }
                    }
                    Button(store.isRefreshingTitleGenerationCapabilities ? "Checking…" : "Refresh options") {
                        store.refreshTitleGenerationCapabilities()
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(store.isRefreshingTitleGenerationCapabilities)
                } else {
                    SettingsNote("Sign in to Codex to choose a model and thinking level.")
                }
            }
        }
        .task {
            if store.titleGenerationCapabilities == nil { store.refreshTitleGenerationCapabilities() }
            guard let thisMachineID = model.thisMachineID else { return }
            await model.machines.refreshSignIn(.codex, on: thisMachineID)
        }
    }

    private func options(_ available: [String]?, selected: String) -> [String] {
        let available = available ?? []
        return available.contains(selected) ? available : [selected] + available
    }
}
